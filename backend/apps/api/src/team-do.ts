import type { Principal } from "@cmux/ownership"
import { resolveAppRelease } from "./app-do.ts"
import { appsView } from "./domains/app-installs.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

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

  protected read(state: TeamState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!principal.user || !state.members[principal.user]) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    if (op === "app.list") return { ok: true, value: appsView(state.apps, Date.now(), "team"), revision: "" }
    if (op !== "team.directory") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { team: state.team?.id, members: Object.values(state.members), hosts: Object.values(state.hosts) }, revision: "" }
  }

  /** Team installs, updates and approvals decide against the release AppDO resolves now. */
  protected override resolve(_entity: string, state: TeamState, op: string, params: unknown): Promise<unknown> {
    return resolveAppRelease(this.env, "team", state.apps, op, params)
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
