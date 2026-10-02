import type { Principal } from "@cmux/ownership"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { policyAt } from "./domains/team-policy.ts"

/** TeamDO: membership cache and the account directory of hosts (U2). */
export class TeamDO extends OwnerDO<TeamState> {
  constructor(ctx: DurableObjectState, env: Env) {
    // Members see each other's public ids and display name in events, never email,
    // Stack id, grant or token data.
    super(ctx, env, teamDomain, "team", (p) => ({
      identity: p.install ?? `user:${p.user}`,
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.team ? { team: p.team } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.display_name ? { display_name: p.display_name } : {})
    }))
  }

  protected read(state: TeamState, op: string, params: unknown, principal: Principal): ReadResult {
    const member = principal.user ? state.members[principal.user] : undefined
    if (!member) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    const p = (params ?? {}) as { version?: unknown; limit?: unknown }
    switch (op) {
      case "team.directory":
        return { ok: true, value: { team: state.team?.id, members: Object.values(state.members), hosts: Object.values(state.hosts) }, revision: "" }
      case "team.policy.get": {
        if (p.version !== undefined && (typeof p.version !== "number" || !Number.isInteger(p.version))) return { ok: false, code: "validation.invalid", message: "version must be an integer" }
        const policy = policyAt(state, p.version as number | undefined)
        if (!policy) return { ok: false, code: "selector.not_found", message: `policy version ${String(p.version)} is not retained` }
        return { ok: true, value: { team: state.team?.id, policy }, revision: "" }
      }
      case "team.policy.history": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may read policy history" }
        const limit = typeof p.limit === "number" && Number.isInteger(p.limit) ? Math.min(Math.max(p.limit, 1), 100) : 20
        return { ok: true, value: { team: state.team?.id, versions: (state.policy_history ?? []).slice(0, limit) }, revision: "" }
      }
      default:
        return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    }
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
