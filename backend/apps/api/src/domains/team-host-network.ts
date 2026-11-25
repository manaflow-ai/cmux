import type { ReduceContext } from "@cmux/ownership"
import { Exit, Schema } from "effect"
import { reject } from "./common.ts"
import { HostNetworkBoundParams } from "./host-network-params.ts"
import { appendAudit } from "./team-audit.ts"
import { can, hostOf, hostUpsert } from "./team-members.ts"
import type { TeamState } from "./team.ts"

export const reduceHostNetworkBound = (state: TeamState, params: unknown, ctx: ReduceContext) => {
  const decoded = Schema.decodeUnknownExit(HostNetworkBoundParams)(params)
  if (Exit.isFailure(decoded)) return reject("validation.invalid", "invalid host network binding")
  const v = decoded.value, host = hostOf(state, ctx.rows, v.host)
  if (!state.team || state.team.deleted_at !== undefined || !host || host.kind === "server" || host.orphaned
    || host.enrolled_by !== v.install || host.owner_user !== v.owner_user || !can(state, ctx.rows, v.owner_user, "team.resources")
    || (host.network && (host.network.tenant !== v.network.tenant || host.network.mesh !== v.network.mesh || host.network.device !== v.network.device))) return reject("auth.forbidden", "the host identity changed")
  // A retry of a confirmed binding under the same key and grant changes nothing; one under a new
  // grant (or a binding confirmed before the grant was kept) records the grant Native dials check.
  if (host.network?.state === "confirmed" && host.wg_public_key === v.wg_public_key && host.network.install_grant === v.grant)
    return { ok: true as const, state, value: { host: host.id, network: host.network }, changed: false }
  const network = { ...v.network, state: "confirmed" as const, confirmed_at: ctx.now, ...(v.grant ? { install_grant: v.grant } : {}) }
  const next = { ...host, wg_public_key: v.wg_public_key, network }
  const actor = { ...ctx, principal: { kind: "install" as const, identity: v.install, install: v.install, user: v.owner_user, team: state.team.id } }
  const audit = appendAudit(state, state.team.id, actor, "host.network.bind", `host ${host.name} network identity verified`, { host: host.id, install: v.install, owner_user: v.owner_user, network })
  return {
    ok: true as const, state: audit.state, value: { host: host.id, network }, writes: hostUpsert(next),
    outbox: [{ kind: "host.upsert", entity: host.id, payload: { ...next, team: state.team.id } }, audit.outbox]
  }
}
