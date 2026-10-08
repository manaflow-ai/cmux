import { guestOf } from "./team-guests.ts"
import type { ReduceContext } from "@cmux/ownership"
import { ServerRevoke, type Host } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { appendAudit } from "./team-audit.ts"
import type { TeamState } from "./team.ts"
import type { RowReader, RowWrite } from "@cmux/ownership"
import { hostByInstall, hostDelete, hostOf, hostUpsert, memberOf, roleOf } from "./team-members.ts"

/**
 * Servers in the team directory (plans/cmux-next/server.md 6). A server is a
 * host of kind `server` with the tag `tag:server`, owned by the user who
 * approved its pairing. TeamDO is the single writer; the Worker's approve
 * route reaches `server.enrolled` only through `TeamDO.enrollServer`.
 * `server.enrolled` checks the approver's role in the same commit as its
 * outcome: the host, or (role lost after the Worker registered the install)
 * a refusal plus the pending revocation of that install.
 */

type Row = { kind: string; entity: string; payload: unknown }
type Out = ReturnType<typeof reject> | { ok: true; state: TeamState; value: unknown; changed?: boolean; outbox?: Array<Row>; writes?: ReadonlyArray<RowWrite> }

/** Commits the change, its projection row and one audit record together (spec/enterprise.md 6). */
const audited = (state: TeamState, ctx: ReduceContext, op: string, value: unknown, row: Row, summary: string, detail: unknown): Out => {
  const a = appendAudit(state, state.team!.id, ctx, op, summary, detail)
  return { ok: true, state: a.state, value, outbox: [row, a.outbox] }
}

/** Who may add a server to this team: its owners and admins (team policy `servers.memberEnroll` comes later). */
export const mayEnrollServer = (state: TeamState, user: string | undefined, rows?: RowReader): boolean => {
  const role = roleOf(state, rows, user)
  return role === "owner" || role === "admin"
}

/** An ok result plus row writes (members and hosts are rows, team-members.ts). */
const withWrites = (out: Out, writes: ReadonlyArray<RowWrite>): Out => (out.ok ? { ...out, writes: [...(out.writes ?? []), ...writes] } : out)

export const SERVER_TAG = "tag:server"

/** A removed server's install that its owner's UserDO must still revoke. */
export interface ServerRevocation {
  readonly install: string
  readonly owner_user: string
  readonly by: string
  readonly at: number
}

/** UserDO confirmed the revocation: drop it from the retry set. */
export const reduceServerInstallRevoked = (state: TeamState, params: unknown): Out => {
  const install = (params as { install: string }).install
  if (!state.server_revocations?.[install]) return { ok: true, state, value: { install }, changed: false }
  const { [install]: _done, ...rest } = state.server_revocations
  return { ok: true, state: { ...state, server_revocations: rest }, value: { install } }
}

/** What `server.enrolled` answers when the approver may no longer add servers (TeamDO.enrollServer reads it). */
export interface ServerEnrollRefused {
  readonly refused: true
  readonly install: string
  readonly message: string
}

const ENROLL_REFUSED = "only team owners and admins may add a server"

export const reduceServerEnrolled = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  if (!state.team) return reject("validation.invalid", "team not initialized")
  const v = params as { install: string; name: string; platform: typeof Host.Type["platform"]; wg_public_key: string; owner_user: string; approved_by: string }
  // One host per install: a replayed or repeated approval of the same install keeps the host id.
  const existing = hostByInstall(state, ctx.rows, v.install)
  if (existing && existing.kind !== "server") return reject("validation.invalid", "this install is already a device host")
  if (!mayEnrollServer(state, v.approved_by, ctx.rows)) {
    // A host already exists: an earlier commit decided this enrollment; server.revoke owns that host.
    if (existing) return reject("auth.forbidden", ENROLL_REFUSED)
    return refuseEnrollment(state, ctx, v)
  }
  if (!memberOf(state, ctx.rows, v.owner_user)) return reject("auth.forbidden", "the server owner is not a member of this team")
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
  const next = { ...state, host_count: (state.host_count ?? 0) + (existing ? 0 : 1) }
  return withWrites(
    audited(next, ctx, "server.enrolled", host, { kind: "host.upsert", entity: host.id, payload: { ...host, team: state.team.id } }, `server ${host.name} paired`, {
      host: host.id,
      install: v.install,
      owner_user: v.owner_user,
      approved_by: v.approved_by
    }),
    hostUpsert(host)
  )
}

/**
 * The approver lost the right to add servers between the Worker's role check
 * and this commit, after UserDO registered the server's install. The refusal
 * and a pending revocation of that install commit together, so no install is
 * left without a host: TeamDO pushes `install.revoke_by_team` and retries until
 * UserDO confirms. The result is a committed refusal, so a retry with the same
 * idempotency key replays it and can never add a host for the revoked install.
 */
const refuseEnrollment = (state: TeamState, ctx: ReduceContext, v: { install: string; name: string; owner_user: string; approved_by: string }): Out => {
  const value: ServerEnrollRefused = { refused: true, install: v.install, message: ENROLL_REFUSED }
  if (state.server_revocations?.[v.install]) return { ok: true, state, value, changed: false }
  const pending: ServerRevocation = { install: v.install, owner_user: v.owner_user, by: v.approved_by, at: ctx.now }
  const next = { ...state, server_revocations: { ...(state.server_revocations ?? {}), [v.install]: pending } }
  const a = appendAudit(next, state.team!.id, ctx, "server.enroll_refused", `server ${v.name} not paired: the approver may no longer add servers`, {
    install: v.install,
    approved_by: v.approved_by,
    refused: true
  })
  return { ok: true, state: a.state, value, outbox: [a.outbox] }
}

/** Is `install` still this team's server for `host`, with no revocation pending? TeamDO decides before UserDO hears of a revoke. */
export const serverPlacementActive = (state: TeamState, rows: RowReader | undefined, host: string, install: string): boolean => {
  const h = hostOf(state, rows, host)
  return h?.kind === "server" && h.enrolled_by === install && !h.orphaned && !state.server_revocations?.[install]
}

/** A HostDO control socket's role (b1-control-do.md 2), resolved from this team's directory. */
export interface HostAccess {
  readonly role: "host" | "device"
  readonly host: { readonly id: string; readonly name: string; readonly platform: string; readonly owner_user: string; readonly enrolled_by: string }
}

/**
 * `host` for the install that enrolled the host (never a session or a chief token), `device` for
 * any member of this team (a personal team has only its user: same account), null otherwise.
 */
export const hostAccessFor = (state: TeamState, rows: RowReader | undefined, host: string, p: { user?: string; install?: string; kind?: string; agent?: string }): HostAccess | null => {
  const h = hostOf(state, rows, host)
  if (!h || !p.user || state.server_revocations?.[h.enrolled_by]) return null
  const summary = { id: h.id, name: h.name, platform: h.platform, owner_user: h.owner_user, enrolled_by: h.enrolled_by }
  // A guest device the host owner accepted (b6-pairing.md 4.2): admitted as a device, never as a chief.
  const guest = guestOf(state, host, p.install)
  if (!memberOf(state, rows, p.user)) return guest && guest.user === p.user && p.kind === "install" && !p.agent ? { role: "device", host: summary } : null
  if (p.kind === "install" && !p.agent && p.install === h.enrolled_by) return { role: "host", host: summary }
  return p.agent ? null : { role: "device", host: summary }
}

type HostPrincipal = { user?: string; install?: string; kind?: string; agent?: string; install_kind?: string }
type CloudHostAccess = (role: "host" | "device") => Promise<HostAccess | null>

/** Resolves ordinary hosts locally and delegates VM hosts to CloudDO. */
export const teamHostAccess = async (state: TeamState, rows: RowReader | undefined, host: string, p: HostPrincipal, cloud: CloudHostAccess): Promise<HostAccess | null> => {
  if (p.install_kind === "vm") return p.agent === undefined ? cloud("host") : null
  const ordinary = hostAccessFor(state, rows, host, p)
  if (ordinary) return ordinary
  return p.user && p.agent === undefined && memberOf(state, rows, p.user) ? cloud("device") : null
}

/** Removes a server host; the Worker then revokes its install key in the owner's UserDO. */
export const reduceServerRevoke = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const p = ctx.principal
  if (p.kind !== "session" || p.agent) return reject("auth.forbidden", "only a signed-in user may revoke a server")
  const d = decodeParams<typeof ServerRevoke.params.Type>(ServerRevoke, params)
  if (!d.ok) return d
  const host = hostOf(state, ctx.rows, d.value.host)
  if (!host || host.kind !== "server") return reject("selector.not_found", "server not found")
  const role = roleOf(state, ctx.rows, p.user)
  if (host.owner_user !== p.user && role !== "owner" && role !== "admin") return reject("auth.forbidden", "only the server owner or a team admin may revoke it")
  const legacy = state.hosts?.[host.id] ? (({ [host.id]: _gone, ...rest }) => ({ hosts: rest }))(state.hosts) : {}
  // The install revocation commits here as a pending item; TeamDO pushes it to the owner's UserDO and retries until confirmed.
  const pending: ServerRevocation = { install: host.enrolled_by, owner_user: host.owner_user, by: p.user!, at: ctx.now }
  const next = { ...state, ...legacy, host_count: Math.max(0, (state.host_count ?? 1) - 1), server_revocations: { ...(state.server_revocations ?? {}), [host.enrolled_by]: pending } }
  return withWrites(
    audited(next, ctx, "server.revoke", { host: host.id, install: host.enrolled_by, owner_user: host.owner_user }, { kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }, `server ${host.name} revoked`, {
      host: host.id,
      install: host.enrolled_by,
      by: p.user
    }),
    hostDelete(host)
  )
}
