import type { Principal } from "@cmux/ownership"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/** TeamDO: membership cache and the account directory of hosts (U2). */
export class TeamDO extends OwnerDO<TeamState> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, teamDomain, "team")
  }

  protected read(state: TeamState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!principal.user || !state.members[principal.user]) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    if (op !== "team.directory") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { team: state.team?.id, members: Object.values(state.members), hosts: Object.values(state.hosts) }, revision: "" }
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
