import type { ReduceContext } from "@cmux/ownership"
import { ServerNetworkReservation, ServerRevoke, type Host } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { decodeParams, reject, ServerNetworkConfirmedParams } from "./common.ts"
import { appendAudit } from "./team-audit.ts"
import type { TeamState } from "./team.ts"
import type { RowReader, RowWrite } from "@cmux/ownership"
import { can, hostByInstall, hostDelete, hostOf, hostUpsert, memberOf } from "./team-members.ts"
import { PAIRING_TTL_MS } from "./pairing.ts"

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
export const mayEnrollServer = (state: TeamState, user: string | undefined, rows?: RowReader): boolean => can(state, rows, user, "team.manage")

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

/**
 * The pairing that made a server: its 8-symbol code and the invite it came through. Kept only
 * while that code's or invite's object can still answer (both end within PAIRING_TTL_MS of the
 * approval), so a revoke can spend them: pair-invite-routes.ts revokeServerPairing.
 */
export interface ServerPairing {
  readonly code: string
  readonly invite: string | null
  readonly at: number
}

/** How long a server's pairing is kept for its revoke: past the life of its code and its invite. */
export const SERVER_PAIRING_KEEP_MS = 2 * PAIRING_TTL_MS

const livePairings = (state: TeamState, now: number): Record<string, ServerPairing> =>
  Object.fromEntries(Object.entries(state.server_pairings ?? {}).filter(([, p]) => p.at > now - SERVER_PAIRING_KEEP_MS))

/** The pairing that made `host` (if still live), and the kept set without it. */
const takePairing = (state: TeamState, host: string, now: number): { pairing: { code: string; invite: string | null } | undefined; rest: Record<string, ServerPairing> } => {
  const { [host]: taken, ...rest } = livePairings(state, now)
  return { pairing: taken ? { code: taken.code, invite: taken.invite } : undefined, rest }
}

const validPairing = (p: unknown): p is { code: string; invite: string | null } => {
  const v = p as { code?: unknown; invite?: unknown } | null
  return typeof v?.code === "string" && /^[0-9A-Z]{8}$/.test(v.code) && (v.invite === null || (typeof v.invite === "string" && /^[0-9A-Z]{10}$/.test(v.invite)))
}

/**
 * TeamDO.enrollServer, right after `server.enrolled` added the host: keep the pairing that made it
 * (pair-routes.ts passes it). Only for the live server host of that install; a malformed pairing
 * is ignored. Its own op, so `server.enrolled`'s params (and their replays) stay as they were.
 */
export const reduceServerPairingRecorded = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const v = params as { host?: unknown; install?: unknown; code?: unknown; invite?: unknown }
  if (typeof v.host !== "string" || typeof v.install !== "string" || !validPairing(v)) return reject("validation.invalid", "invalid server pairing")
  if (!serverPlacementActive(state, ctx.rows, v.host, v.install)) return { ok: true, state, value: { host: v.host, recorded: false }, changed: false }
  const pairings = livePairings(state, ctx.now)
  pairings[v.host] = { code: v.code, invite: v.invite, at: ctx.now }
  return { ok: true, state: { ...state, server_pairings: pairings }, value: { host: v.host, recorded: true } }
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
  const v = params as { install: string; name: string; platform: typeof Host.Type["platform"]; wg_public_key: string; owner_user: string; approved_by: string; network?: unknown }
  // One host per install: a replayed or repeated approval of the same install keeps the host id.
  const existing = hostByInstall(state, ctx.rows, v.install)
  if (existing && existing.kind !== "server") return reject("validation.invalid", "this install is already a device host")
  if (!mayEnrollServer(state, v.approved_by, ctx.rows)) {
    // A host already exists: an earlier commit decided this enrollment; server.revoke owns that host.
    if (existing) return reject("auth.forbidden", ENROLL_REFUSED)
    return refuseEnrollment(state, ctx, v)
  }
  if (!memberOf(state, ctx.rows, v.owner_user)) return reject("auth.forbidden", "the server owner is not a member of this team")
  let network: typeof ServerNetworkReservation.Type | undefined
  if (v.network !== undefined) {
    const decoded = Schema.decodeUnknownExit(ServerNetworkReservation)(v.network)
    if (Exit.isFailure(decoded)) return reject("validation.invalid", "invalid network reservation")
    network = decoded.value
  }
  if (existing?.network && (!network || !sameServerNetwork(network, existing.network) || existing.wg_public_key !== v.wg_public_key)) return reject("validation.invalid", "the existing server network binding cannot be retargeted")
  const persistedNetwork = existing?.network ?? network
  const host: typeof Host.Type = {
    id: existing?.id ?? ctx.newId("host"),
    name: v.name,
    platform: v.platform,
    owner_user: v.owner_user,
    enrolled_by: v.install,
    enrolled_at: existing?.enrolled_at ?? ctx.now,
    kind: "server",
    wg_public_key: v.wg_public_key,
    tags: [SERVER_TAG],
    ...(persistedNetwork ? { network: persistedNetwork } : {})
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

export const sameServerNetwork = (a: { tenant: string; mesh: string; device: string }, b: typeof Host.Type["network"]): boolean =>
  Boolean(b && a.tenant === b.tenant && a.mesh === b.mesh && a.device === b.device)

/** Only the verified external path calls this; recheck the current host after its awaits. */
export const reduceServerNetworkConfirmed = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const decoded = Schema.decodeUnknownExit(ServerNetworkConfirmedParams)(params)
  if (Exit.isFailure(decoded)) return reject("validation.invalid", "invalid network binding")
  const v = decoded.value
  const host = hostOf(state, ctx.rows, v.host)
  if (!state.team || state.team.deleted_at !== undefined || !host?.network || !serverPlacementActive(state, ctx.rows, v.host, v.install)
    || host.owner_user !== v.owner_user || !can(state, ctx.rows, v.owner_user, "team.resources") || host.wg_public_key !== v.wg_public_key || !sameServerNetwork(v.network, host.network)) return reject("auth.forbidden", "the approved server identity changed")
  if (host.network.state === "confirmed") return { ok: true, state, value: { host: host.id, network: host.network }, changed: false }
  const network = { ...v.network, state: "confirmed" as const, confirmed_at: ctx.now }
  const next = { ...host, network }
  return withWrites(audited(state, ctx, "server.network.confirm", { host: host.id, network },
    { kind: "host.upsert", entity: host.id, payload: { ...next, team: state.team.id } }, `server ${host.name} network identity confirmed`,
    { host: host.id, install: v.install, owner_user: v.owner_user, network }), hostUpsert(next))
}

/** Removes a server host; the Worker then revokes its install key in the owner's UserDO. */
export const reduceServerRevoke = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const p = ctx.principal
  if (p.kind !== "session" || p.agent) return reject("auth.forbidden", "only a signed-in user may revoke a server")
  const d = decodeParams<typeof ServerRevoke.params.Type>(ServerRevoke, params)
  if (!d.ok) return d
  const host = hostOf(state, ctx.rows, d.value.host)
  if (!host || host.kind !== "server") return reject("selector.not_found", "server not found")
  // The owner is the person who approved its pairing; for a server that came through an invite that is
  // always the inviter (PairingDO.claim lets only `invited_by` approve), so the inviter may revoke it.
  if (host.owner_user !== p.user && !can(state, ctx.rows, p.user, "team.manage")) return reject("auth.forbidden", "only the server owner or a team admin may revoke it")
  const legacy = state.hosts?.[host.id] ? (({ [host.id]: _gone, ...rest }) => ({ hosts: rest }))(state.hosts) : {}
  // The install revocation commits here as a pending item; TeamDO pushes it to the owner's UserDO and retries until confirmed.
  const pending: ServerRevocation = { install: host.enrolled_by, owner_user: host.owner_user, by: p.user!, at: ctx.now }
  // The pairing that made it, while its code and invite still live: the Worker spends both (http.ts).
  const { pairing, rest: pairings } = takePairing(state, host.id, ctx.now)
  const next = { ...state, ...legacy, host_count: Math.max(0, (state.host_count ?? 1) - 1), server_revocations: { ...(state.server_revocations ?? {}), [host.enrolled_by]: pending }, server_pairings: pairings }
  return withWrites(
    audited(next, ctx, "server.revoke", { host: host.id, install: host.enrolled_by, owner_user: host.owner_user, ...(pairing ? { pairing } : {}) }, { kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }, `server ${host.name} revoked`, {
      host: host.id,
      install: host.enrolled_by,
      by: p.user
    }),
    hostDelete(host)
  )
}

/**
 * The server's own install signed itself out (`install.sign_out`, which UserDO already committed:
 * `cmux server unpair` on the box). Its host leaves the directory, as a revoke would, and no
 * install revocation is queued (the install is revoked already). Keyed by the install, so a
 * repeat finds no host and changes nothing.
 */
export const reduceServerSignedOut = (state: TeamState, params: unknown, ctx: ReduceContext): Out => {
  const install = (params as { install?: unknown } | null)?.install
  if (typeof install !== "string") return reject("validation.invalid", "install required")
  const host = hostByInstall(state, ctx.rows, install)
  if (!host || host.kind !== "server") return { ok: true, state, value: { host: null, install }, changed: false }
  const legacy = state.hosts?.[host.id] ? (({ [host.id]: _gone, ...rest }) => ({ hosts: rest }))(state.hosts) : {}
  const { pairing, rest: pairings } = takePairing(state, host.id, ctx.now)
  const next = { ...state, ...legacy, host_count: Math.max(0, (state.host_count ?? 1) - 1), server_pairings: pairings }
  return withWrites(
    audited(next, ctx, "server.signed_out", { host: host.id, install, owner_user: host.owner_user, ...(pairing ? { pairing } : {}) }, { kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }, `server ${host.name} unpaired itself`, {
      host: host.id,
      install
    }),
    hostDelete(host)
  )
}
