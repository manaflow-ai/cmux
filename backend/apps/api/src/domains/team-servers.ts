import type { ReduceContext } from "@cmux/ownership"
import { ServerRevoke, type Host } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { appendAudit } from "./team-audit.ts"
import type { TeamState } from "./team.ts"

/**
 * Servers in the team directory (plans/cmux-next/server.md 6). A server is a
 * host of kind `server` with the tag `tag:server`, owned by the user who
 * approved its pairing. TeamDO is the single writer; the Worker's approve
 * route reaches `server.enrolled` only through `TeamDO.enrollServer`, which
 * checks the approver's role first.
 */

type Row = { kind: string; entity: string; payload: unknown }
type Out = ReturnType<typeof reject> | { ok: true; state: TeamState; value: unknown; changed?: boolean; outbox?: Array<Row> }

/** Commits the change, its projection row and one audit record together (spec/enterprise.md 6). */
const audited = (state: TeamState, ctx: ReduceContext, op: string, value: unknown, row: Row, summary: string, detail: unknown): Out => {
  const a = appendAudit(state, state.team!.id, ctx, op, summary, detail)
  return { ok: true, state: a.state, value, outbox: [row, a.outbox] }
}

/** Who may add a server to this team: its owners and admins (team policy `servers.memberEnroll` comes later). */
export const mayEnrollServer = (state: TeamState, user: string | undefined): boolean => {
  const role = user ? state.members[user]?.role : undefined
  return role === "owner" || role === "admin"
}

export const SERVER_TAG = "tag:server"

export const reduceServerEnrolled = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  if (!state.team) return reject("validation.invalid", "team not initialized")
  const v = params as { install: string; name: string; platform: typeof Host.Type["platform"]; wg_public_key: string; owner_user: string; approved_by: string }
  if (!state.members[v.owner_user]) return reject("auth.forbidden", "the server owner is not a member of this team")
  // One host per install: a replayed or repeated approval of the same install keeps the host id.
  const existing = Object.values(state.hosts).find((h) => h.enrolled_by === v.install)
  if (existing && existing.kind !== "server") return reject("validation.invalid", "this install is already a device host")
  const host: typeof Host.Type = {
    id: existing?.id ?? ctx.newId("host"),
    name: v.name,
    platform: v.platform,
    owner_user: v.owner_user,
    enrolled_by: v.install,
    enrolled_at: existing?.enrolled_at ?? ctx.now,
    kind: "server",
    wg_public_key: v.wg_public_key,
    tags: [SERVER_TAG]
  }
  if (existing && JSON.stringify(existing) === JSON.stringify(host)) return { ok: true, state, value: host, changed: false }
  const next = { ...state, hosts: { ...state.hosts, [host.id]: host } }
  return audited(next, ctx, "server.enrolled", host, { kind: "host.upsert", entity: host.id, payload: { ...host, team: state.team.id } }, `server ${host.name} paired`, {
    host: host.id,
    install: v.install,
    owner_user: v.owner_user,
    approved_by: v.approved_by
  })
}

/** Removes a server host; the Worker then revokes its install key in the owner's UserDO. */
export const reduceServerRevoke = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const p = ctx.principal
  if (p.kind !== "session" || p.agent) return reject("auth.forbidden", "only a signed-in user may revoke a server")
  const d = decodeParams<typeof ServerRevoke.params.Type>(ServerRevoke, params)
  if (!d.ok) return d
  const host = state.hosts[d.value.host]
  if (!host || host.kind !== "server") return reject("selector.not_found", "server not found")
  const role = p.user ? state.members[p.user]?.role : undefined
  if (host.owner_user !== p.user && role !== "owner" && role !== "admin") return reject("auth.forbidden", "only the server owner or a team admin may revoke it")
  const { [host.id]: _gone, ...rest } = state.hosts
  return audited({ ...state, hosts: rest }, ctx, "server.revoke", { host: host.id, install: host.enrolled_by, owner_user: host.owner_user }, { kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }, `server ${host.name} revoked`, {
    host: host.id,
    install: host.enrolled_by,
    by: p.user
  })
}
