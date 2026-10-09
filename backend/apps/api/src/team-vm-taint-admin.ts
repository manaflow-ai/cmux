import type { OwnerFrame, Principal, RowReader } from "@cmux/ownership"
import { TeamVmRebuild, TeamVmRetiredDelete, TeamVmTaintAccept } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { memberOf, roleOf } from "./domains/team-members.ts"
import type { TeamState } from "./domains/team.ts"
import type { DomainReply } from "./team-domain-external.ts"
import type { AdminReply, AdminRequest } from "./team-vm-taint-run.ts"

/**
 * The owner actions on a tainted team VM (cx-q4f3): team_vm.taint.accept, team_vm.rebuild and
 * team_vm.retired.delete. TeamDO holds the roles and the audit chain, so the request comes here
 * first: an owner or admin in a person's session only, then TeamVmDO acts, then TeamDO audits the
 * outcome in its chain.
 */
export interface VmAdminDeps {
  readonly state: () => TeamState
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  readonly teamVm: { adminAction(entity: string, req: AdminRequest): Promise<AdminReply> }
}

const defs = { "team_vm.taint.accept": TeamVmTaintAccept, "team_vm.rebuild": TeamVmRebuild, "team_vm.retired.delete": TeamVmRetiredDelete } as const

export const vmAdminExternal = async (deps: VmAdminDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const state = deps.state()
  if (p.team !== deps.team || !p.user || !memberOf(state, deps.rows, p.user)) return fail("auth.forbidden", "not a member of this team")
  const role = roleOf(state, deps.rows, p.user)
  if (p.kind !== "session" || p.agent || (role !== "owner" && role !== "admin")) return fail("auth.forbidden", "only team owners and admins act on the team VM, in a person's session")
  const def = Object.hasOwn(defs, frame.op) ? defs[frame.op as keyof typeof defs] : null
  if (!def) return fail("validation.invalid", `unknown op ${frame.op}`)
  // A rebuild does not carry /srv/team (no journal replay yet): only the owner's word that the files were copied off deletes the paused VM (cx-zr9i).
  if (frame.op === "team_vm.retired.delete" && (frame.params as { files_copied?: unknown } | null)?.files_copied !== true) {
    return fail("team_vm.retired_files_unconfirmed", "copy the team files (/srv/team) off the paused VM first, then delete it with files_copied: true")
  }
  const d = decodeParams<{ epoch?: number; vm?: string; users?: ReadonlyArray<string> }>(def, frame.params)
  if (!d.ok) return fail(d.code, d.message)
  // The caller's identity scopes the key, so two owners' requests never share a replay.
  const key = `${p.identity}|${frame.idempotency_key}`
  const req: AdminRequest =
    frame.op === "team_vm.retired.delete"
      ? { action: "delete", by: p.user, vm: d.value.vm!, key }
      : frame.op === "team_vm.rebuild"
        ? { action: "rebuild", by: p.user, epoch: d.value.epoch!, key }
        : { action: "accept", by: p.user, epoch: d.value.epoch!, users: d.value.users ?? [], key }
  let r: AdminReply
  try {
    r = await deps.teamVm.adminAction(deps.team, req)
  } catch {
    return fail("owner.unreachable", "the team VM record did not answer; try again", true)
  }
  if (!r.ok) return fail(r.code, r.message, r.code === "owner.unreachable")
  const action = req.action === "accept" ? "taint_accepted" : req.action === "rebuild" ? "rebuild" : "retired_deleted"
  const audit = { action, by: p.user, epoch: r.epoch, tainted_by: r.tainted_by, ...(req.action === "delete" ? { vm: req.vm } : {}) }
  const rej = deps.submitSystem("team_vm.taint_audit", audit, `taint-admin:${action}:${key}`).frames.find((f) => f.t === "reject")
  // The action happened; a failed audit is logged loudly rather than reported as a failed action.
  if (rej) console.error(JSON.stringify({ msg: "team vm taint audit refused", team: deps.team, action, code: rej.t === "reject" ? rej.code : "" }))
  return { ...base, ok: true, value: r.value }
}
