import type { OwnerFrame, Principal, RowReader } from "@cmux/ownership"
import { TeamMembersRemove } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { memberOf } from "./domains/team-members.ts"
import { removeGrantFor, roleHas, stackRole } from "./domains/team-roles.ts"
import type { TeamState } from "./domains/team.ts"
import { userIdFor } from "./domains/user.ts"
import type { DomainReply } from "./team-domain-external.ts"
import type { StackServer } from "./stack-server.ts"

/**
 * `team.members.remove` (cx-3bi.4, spec H12 c): a person removes a member of a shared team.
 * TeamDO holds the roles, so the check runs here: owners remove anyone but an owner; admins
 * remove members, guests and billing members, never an admin. Stack is the membership source,
 * so a Stack team's member is removed in Stack first (else the next sync would add them back),
 * then TeamDO commits team.member.remove (certificates, sockets, team VM taint, audit). An owner
 * is never removed here: their owner permission goes in Stack first.
 */
export interface MemberAdminDeps {
  readonly state: () => TeamState
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly stackProjectId: string
  readonly stack: StackServer | undefined
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const memberAdminExternal = async (deps: MemberAdminDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const state = deps.state()
  const actor = p.team === deps.team ? memberOf(state, deps.rows, p.user) : undefined
  if (!actor || !p.user) return fail("auth.forbidden", "not a member of this team")
  if (p.kind !== "session" || p.agent) return fail("auth.forbidden", "members are removed by a person, in their own session")
  const d = decodeParams<typeof TeamMembersRemove.params.Type>(TeamMembersRemove, frame.params)
  if (!d.ok) return fail(d.code, d.message)
  const user = d.value.user
  const target = memberOf(state, deps.rows, user)
  if (!target) return { ...base, ok: true, value: { user, removed: false } }
  const need = removeGrantFor(target.role)
  if (need === null) return fail("auth.forbidden", "an owner is not removed here: remove their owner permission in Stack first")
  if (!roleHas(actor.role, need)) return fail("auth.forbidden", need === "members.remove_admin" ? "only an owner removes an admin" : `the ${actor.role} role may not remove members`)
  const stackTeam = state.team?.kind === "stack" ? state.team.stack_team : undefined
  if (!stackTeam) return fail("validation.invalid", "only a shared team's members are removed")
  if (!deps.stack) return fail("owner.unreachable", "Stack is not configured here; try again later", true)
  try {
    const listed = await deps.stack.listTeamMembers(stackTeam)
    if (listed === "team_gone") return fail("selector.not_found", "Stack no longer has this team")
    // cmux user ids are derived from Stack's (userIdFor); the Stack ids are found by Stack's own list.
    const entry = (u: string) => listed.find((m) => userIdFor(deps.stackProjectId, UUID.test(m.user_id) ? m.user_id.toLowerCase() : m.user_id) === u)
    const inStack = entry(user)
    // Review P2-1: TeamDO's roles may lag Stack (a late or dead-lettered webhook). The roles Stack gives
    // now, from this same live read, must allow the removal too, before anything is deleted in Stack.
    const liveActor = entry(p.user)
    if (!liveActor) return fail("auth.forbidden", "Stack no longer lists you in this team")
    const liveNeed = inStack ? removeGrantFor(stackRole(inStack.permissions)) : need
    if (liveNeed === null || !roleHas(stackRole(liveActor.permissions), liveNeed)) return fail("auth.forbidden", "Stack's current roles do not allow this removal")
    if (inStack && (await deps.stack.removeTeamMember(stackTeam, inStack.user_id)) === "team_gone") return fail("selector.not_found", "Stack no longer has this team")
  } catch (e) {
    console.error(JSON.stringify({ msg: "stack member removal failed", team: deps.team, error: String(e).slice(0, 200) }))
    return fail("owner.unreachable", "Stack did not answer; try again", true)
  }
  // Without from_stack, with `by`: the reducer checks the person's grant and the member's role again in the commit (review P3-1).
  const res = deps.submitSystem("team.member.remove", { user, by: p.user }, `members-remove:${p.identity}|${frame.idempotency_key}`)
  const rej = res.frames.find((f) => f.t === "reject")
  if (rej && rej.t === "reject") return fail(rej.code, rej.message)
  const done = res.frames.find((f) => f.t === "result") as { value?: { removed?: boolean } } | undefined
  return { ...base, ok: true, value: { user, removed: done?.value?.removed === true } }
}
