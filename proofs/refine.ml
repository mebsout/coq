(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Sigma.Notations
open Proofview.Notations
open Context.Named.Declaration

module NamedDecl = Context.Named.Declaration

let extract_prefix env info =
  let ctx1 = List.rev (Environ.named_context env) in
  let ctx2 = List.rev (Evd.evar_context info) in
  let rec share l1 l2 accu = match l1, l2 with
  | d1 :: l1, d2 :: l2 ->
    if d1 == d2 then share l1 l2 (d1 :: accu)
    else (accu, d2 :: l2)
  | _ -> (accu, l2)
  in
  share ctx1 ctx2 []

let typecheck_evar ev env sigma =
  let info = Evd.find sigma ev in
  (** Typecheck the hypotheses. *)
  let type_hyp (sigma, env) decl =
    let t = NamedDecl.get_type decl in
    let evdref = ref sigma in
    let _ = Typing.e_sort_of env evdref t in
    let () = match decl with
    | LocalAssum _ -> ()
    | LocalDef (_,body,_) -> Typing.e_check env evdref body t
    in
    (!evdref, Environ.push_named decl env)
  in
  let (common, changed) = extract_prefix env info in
  let env = Environ.reset_with_named_context (Environ.val_of_named_context common) env in
  let (sigma, env) = List.fold_left type_hyp (sigma, env) changed in
  (** Typecheck the conclusion *)
  let evdref = ref sigma in
  let _ = Typing.e_sort_of env evdref (Evd.evar_concl info) in
  !evdref

let typecheck_proof c concl env sigma =
  let evdref = ref sigma in
  let () = Typing.e_check env evdref c concl in
  !evdref

let (pr_constrv,pr_constr) =
  Hook.make ~default:(fun _env _sigma _c -> Pp.str"<constr>") ()

let refine ?(unsafe = true) f = Proofview.Goal.enter { enter = begin fun gl ->
  let gl = Proofview.Goal.assume gl in
  let sigma = Proofview.Goal.sigma gl in
  let sigma = Sigma.to_evar_map sigma in
  let env = Proofview.Goal.env gl in
  let concl = Proofview.Goal.concl gl in
  (** Save the [future_goals] state to restore them after the
      refinement. *)
  let prev_future_goals = Evd.future_goals sigma in
  let prev_principal_goal = Evd.principal_future_goal sigma in
  (** Create the refinement term *)
  let (c, sigma) = Sigma.run (Evd.reset_future_goals sigma) f in
  let evs = Evd.future_goals sigma in
  let evkmain = Evd.principal_future_goal sigma in
  (** Check that the introduced evars are well-typed *)
  let fold accu ev = typecheck_evar ev env accu in
  let sigma = if unsafe then sigma else CList.fold_left fold sigma evs in
  (** Check that the refined term is typesafe *)
  let sigma = if unsafe then sigma else typecheck_proof c concl env sigma in
  (** Check that the goal itself does not appear in the refined term *)
  let self = Proofview.Goal.goal gl in
  let _ =
    if not (Evarutil.occur_evar_upto sigma self c) then ()
    else Pretype_errors.error_occur_check env sigma self c
  in
  (** Proceed to the refinement *)
  let sigma = match evkmain with
    | None -> Evd.define self c sigma
    | Some evk ->
        let id = Evd.evar_ident self sigma in
        let sigma = Evd.define self c sigma in
        match id with
        | None -> sigma
        | Some id -> Evd.rename evk id sigma
  in
  (** Restore the [future goals] state. *)
  let sigma = Evd.restore_future_goals sigma prev_future_goals prev_principal_goal in
  (** Select the goals *)
  let comb = CList.map_filter (Proofview.Unsafe.advance sigma) (CList.rev evs) in
  let sigma = CList.fold_left Proofview.Unsafe.mark_as_goal sigma comb in
  let trace () = Pp.(hov 2 (str"simple refine"++spc()++ Hook.get pr_constrv env sigma c)) in
  Proofview.Trace.name_tactic trace (Proofview.tclUNIT ()) >>= fun () ->
  Proofview.Unsafe.tclEVARS sigma >>= fun () ->
  Proofview.Unsafe.tclSETGOALS comb
end }

(** Useful definitions *)

let with_type env evd c t =
  let my_type = Retyping.get_type_of env evd c in
  let j = Environ.make_judge c my_type in
  let (evd,j') =
    Coercion.inh_conv_coerce_to true (Loc.ghost) env evd j t
  in
  evd , j'.Environ.uj_val

let refine_casted ?unsafe f = Proofview.Goal.enter { enter = begin fun gl ->
  let gl = Proofview.Goal.assume gl in
  let concl = Proofview.Goal.concl gl in
  let env = Proofview.Goal.env gl in
  let f = { run = fun h ->
    let Sigma (c, h, p) = f.run h in
    let sigma, c = with_type env (Sigma.to_evar_map h) c concl in
    Sigma (c, Sigma.Unsafe.of_evar_map sigma, p)
  } in
  refine ?unsafe f
end }
