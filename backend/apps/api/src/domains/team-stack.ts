import type { ReduceContext } from "@cmux/ownership"
import type { TeamMemberProvisionParams, TeamStackMirrorParams } from "@cmux/protocol"
import { decodeParams, internalOps, reject } from "./common.ts"
import { memberOf, memberUpsert, teamIndexItem, type Member } from "./team-members.ts"
import type { TeamState } from "./team.ts"
import { appendAudit } from "./team-audit.ts"

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

export const reduceMemberProvision = (state: TeamState, params: unknown, ctx: ReduceContext) => {
  if (!ownSubmit(ctx)) return reject("auth.forbidden", "internal op")
  const d = decodeParams<typeof TeamMemberProvisionParams.Type>(internalOps.get("team.member.provision")!, params)
  if (!d.ok) return d
  const v = d.value
  if (!state.team || state.team.kind !== "stack") return reject("validation.invalid", "only a Stack team takes provisioned members")
  if (teamDeleted(state)) return { ok: true as const, state, value: { user: v.user, added: false }, changed: false }
  // An existing member keeps their role and name: role changes are team roles (cx-3bi.4), not Stack's membership.
  if (memberOf(state, ctx.rows, v.user)) return { ok: true as const, state, value: { user: v.user, added: false }, changed: false }
  const member: Member = { user: v.user, role: v.role, display_name: v.display_name }
  return {
    ok: true as const,
    state: { ...state, member_count: (state.member_count ?? 0) + 1 },
    writes: [memberUpsert(member)],
    value: { user: v.user, added: true },
    outbox: [
      { kind: "membership.upsert", entity: `${state.team.id}:${v.user}`, payload: { team: state.team.id, ...member } },
      teamIndexItem(state.team, v.user, member.role, ctx.tx)
    ]
  }
}
