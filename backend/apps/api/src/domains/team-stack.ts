import type { ReduceContext } from "@cmux/ownership"
import type { TeamMemberProvisionParams, TeamStackMirrorParams } from "@cmux/protocol"
import { decodeParams, internalOps, reject } from "./common.ts"
import { memberOf, memberUpsert, teamIndexItem, type Member } from "./team-members.ts"
import type { TeamState } from "./team.ts"
import { appendAudit } from "./team-audit.ts"
import { usesSeat } from "./team-roles.ts"

/**
 * Shared (Stack) teams in TeamDO (cx-3bi.43). TeamDO asks Stack for the current team and
 * membership on every Stack webhook (team-stack-sync.ts) and commits the answer here, so a
 * delivery out of order or a retry converges on Stack's state instead of replaying a stale event.
 * A deleted team is a tombstone for good (Stack never reuses a team id): its members leave
 * through team.member.remove and every later delivery changes nothing.
 */

const ownSubmit = (ctx: ReduceContext) => ctx.principal.kind === "system" && ctx.principal.identity === "system:team"

/** A Stack team that Stack deleted: no member may act in it, and it is never mirrored again. */
export const teamDeleted = (state: TeamState) => state.team?.deleted_at !== undefined

export const reduceStackMirror = (state: TeamState, params: unknown, ctx: ReduceContext) => {
  if (!ownSubmit(ctx)) return reject("auth.forbidden", "internal op")
  const d = decodeParams<typeof TeamStackMirrorParams.Type>(internalOps.get("team.stack_mirror")!, params)
  if (!d.ok) return d
  const v = d.value
  if (state.team && (state.team.id !== v.team || state.team.kind !== "stack")) return reject("auth.forbidden", "not this team")
  if (state.team && teamDeleted(state)) return { ok: true as const, state, value: { team: v.team, deleted: true }, changed: false }
  if (v.deleted) {
    const team = { id: v.team, kind: "stack" as const, display_name: state.team?.display_name ?? "Deleted team", stack_team: v.stack_team, deleted_at: ctx.now }
    const a = appendAudit({ ...state, team }, v.team, ctx, "team.stack_mirror", "team deleted in Stack: members are removed", { stack_team: v.stack_team })
    return { ok: true as const, state: a.state, value: { team: v.team, deleted: true }, outbox: [a.outbox] }
  }
  const team = { id: v.team, kind: "stack" as const, display_name: v.display_name ?? state.team?.display_name ?? "Team", stack_team: v.stack_team }
  if (JSON.stringify(state.team) === JSON.stringify(team)) return { ok: true as const, state, value: { team: v.team, deleted: false }, changed: false }
  return {
    ok: true as const,
    state: { ...state, team },
    value: { team: v.team, deleted: false },
    outbox: [{ kind: "team.upsert", entity: team.id, payload: { id: team.id, kind: team.kind, display_name: team.display_name } }]
  }
}

/** Paid seats in use: every member but guests (spec H12). A head from before cx-3bi.4 had only seat roles, so its member count is its seat count. */
export const seatsOf = (state: TeamState) => state.seat_count ?? state.member_count ?? 0

export const reduceMemberProvision = (state: TeamState, params: unknown, ctx: ReduceContext) => {
  if (!ownSubmit(ctx)) return reject("auth.forbidden", "internal op")
  const d = decodeParams<typeof TeamMemberProvisionParams.Type>(internalOps.get("team.member.provision")!, params)
  if (!d.ok) return d
  const v = d.value
  if (!state.team || state.team.kind !== "stack") return reject("validation.invalid", "only a Stack team takes provisioned members")
  if (teamDeleted(state)) return { ok: true as const, state, value: { user: v.user, added: false }, changed: false }
  const prior = memberOf(state, ctx.rows, v.user)
  // An existing member keeps their name; their role follows Stack's permissions as read now (cx-3bi.4), so a demotion in Stack demotes here.
  if (prior && prior.role === v.role) return { ok: true as const, state, value: { user: v.user, added: false }, changed: false }
  const member: Member = prior ? { ...prior, role: v.role } : { user: v.user, role: v.role, display_name: v.display_name }
  const seats = seatsOf(state)
  const seatCount = seats - (prior && usesSeat(prior.role) ? 1 : 0) + (usesSeat(member.role) ? 1 : 0)
  const next: TeamState = { ...state, member_count: (state.member_count ?? 0) + (prior ? 0 : 1), seat_count: seatCount }
  const summary = prior ? `role of ${v.user} changed in Stack: ${prior.role} -> ${member.role}` : `${v.user} joined from Stack as ${member.role}`
  const a = appendAudit(next, state.team.id, ctx, "team.member.provision", summary, { user: v.user, role: member.role, ...(prior ? { previous_role: prior.role } : {}), seats_before: seats, seats_after: seatCount, source: "stack" }, seats === seatCount ? "admin" : "billing")
  return {
    ok: true as const,
    state: a.state,
    writes: [memberUpsert(member)],
    value: { user: v.user, added: !prior, role: member.role },
    outbox: [
      { kind: "membership.upsert", entity: `${state.team.id}:${v.user}`, payload: { team: state.team.id, ...member } },
      teamIndexItem(state.team, v.user, member.role, ctx.tx),
      a.outbox
    ]
  }
}
