import { authenticate, bearerOf, primaryProject, stackProjects, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { cachedIceServers, hopServers } from "./ice.ts"
import { createTeam, sendTeamInvite, userEmail, userTeams } from "./stack.ts"
import { audienceOf, judgedAt, parseReport, ReportError } from "./connectivity-alerts.ts"
import {
  apnsConfig,
  apnsTopics,
  clean,
  isSealedText,
  MAX_MAILBOX_SEALED,
  notifyFailures,
  notifyLimitKey,
  parseNotify,
  pushTargets,
  sendApns,
  TURN_PUSH_WINDOW_MS,
  turnPushKey,
  wantedKinds,
  notifyTargets,
  MAILBOX_MAX_HOLD_MS,
  MAILBOX_TTL_MS,
} from "./push.ts";
import { hasIcon, mergePrefs, openStore, PUSH_KINDS, type Device, type Prefs, type PushKind, type Store } from "./store.ts"
import { StoreSchemaError } from "./store-mysql.ts"
import { userHubName, type Attachment, type HubOwner, type Ingress } from "./team-hub.ts"
import { RELAY_SUBPROTOCOL, RELAY_TICKET_HEADER } from "./link-relay.ts";
import { CHUNK_BATCH_MAX_BODY_BYTES, CHUNK_ID, CHUNK_MAX_BYTES, chunkPairName } from "./chunk-cache.ts"
import { CACHE_VIEWER_HEADER, relayCacheRoomName } from "./relay-cache.ts"
import { HUB_SUBPROTOCOL, hubRoomName } from "./hub-relay.ts"
import {
  isRegion,
  netcheckRoomName,
  parseNetcheck,
  relayPlacement,
  locationHintFor,
  relayRoomName,
} from "./placement.ts";
import { Timing, timingFor } from "./timing.ts"
import { WorkerEntrypoint } from "cloudflare:workers"

export { TeamHub } from "./team-hub.ts"
export { LinkRelay } from "./link-relay.ts"
export { ChunkCache } from "./chunk-cache.ts"
export { HubRelay } from "./hub-relay.ts"
export { locationHintFor } from "./placement.ts"
export { ConnectivityAlertDesk } from "./connectivity-alerts.ts"

const CLOUD_MACHINE = /^vm_[a-z0-9]{20}$/
const CLOUD_ID = /^[A-Za-z0-9._:-]{1,128}$/
const CLOUD_KINDS = new Set(["question", "permission", "done"])

/** Private service-binding entrypoint used by cmux-platform; it has no public HTTP route. */
export class CloudAttentionPush extends WorkerEntrypoint<Env> {
  async sendAttention(event: {
    recipient: string
    kind: "question" | "permission" | "done"
    event_id: string
    team_id: string
    machine_id: string
    session_id: string
    deep_link: string
  }): Promise<{ accepted: boolean; correlation_id?: string }> {
    if (!CLOUD_ID.test(event.recipient) || !CLOUD_ID.test(event.event_id) || !CLOUD_ID.test(event.team_id) || !CLOUD_ID.test(event.session_id) || !CLOUD_MACHINE.test(event.machine_id) || !CLOUD_KINDS.has(event.kind))
      throw new Error("invalid cloud attention identity")
    if (event.deep_link !== `cmux://cloud/chat/${encodeURIComponent(event.machine_id)}/${encodeURIComponent(event.session_id)}`)
      throw new Error("invalid cloud attention deep link")
    const owner = event.recipient
    const config = apnsConfig(this.env)
    if (!config) return { accepted: false }
    const store = await openStore(this.env)
    try {
      const wanted = event.kind === "done" ? "completed" : event.kind
      // Cloud pushes go to the stable app's phones only: a dev build's space never receives them.
      const targets = (await store.listOwnerPush("", owner)).filter((target) => target.kinds.includes(wanted as PushKind))
      if (targets.length === 0) return { accepted: true, correlation_id: `no-targets:${event.event_id}` }
      const { sendCloudAttention } = await import("./push.ts")
      const results = await sendCloudAttention(config, targets, event, Date.now())
      const dropped = results.filter((r) => r.outcome === "drop_target").map((r) => r.token)
      if (dropped.length) await store.dropPushTokens("", dropped)
      const sent = results.find((r) => r.outcome === "sent" && r.status === 200 && !!r.apns_id)
      return { accepted: !!sent, ...(sent ? { correlation_id: `apns:${sent.apns_id}` } : {}) }
    } finally {
      await store.close().catch(() => {})
    }
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/** A path segment, decoded; a malformed % escape is the caller's 400, never a 500. */
const pathSegment = (raw: string): string => {
  try {
    return decodeURIComponent(raw)
  } catch {
    throw new HttpError(400, "bad_request", "malformed path")
  }
}
const TEAM_ID = /^[A-Za-z0-9_-]{1,128}$/
const PERSONAL = "personal-"
/**
 * The personal space of a user. Keyed by `sub` alone so the wire format stays `personal-<sub>`: Stack
 * subs are random v4 UUIDs, so dev and prod users never share one in practice, and every owner check
 * behind it (device ownership, link admission) compares (project, sub), so even a shared sub could not
 * reach the other project's Macs.
 */
export const personalTeamId = (userId: string) => `${PERSONAL}${userId}`
const COLOR = /^#[0-9A-Fa-f]{6}$/
const WG_KEY = /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/
/** A Mac's machine id (PROTOCOL.md "Devices"): 128 bits of a keyed hash, lowercase hex. */
const MACHINE_ID = /^[0-9a-f]{32}$/
/** `{machineId}` when the Mac has one, else nothing: a Mac that never sent one keeps its older wire shape. */
const machineOf = (d: { machineId: string | null }) => (d.machineId ? { machineId: d.machineId } : {})
/** A Mac's `quietMs` from its hub (PROTOCOL.md "Mac freshness"): only for an online Mac; an older hub sends none. */
const quietOf = (p: { online: boolean; quietMs?: number } | undefined) => (p?.online && p.quietMs !== undefined ? { quietMs: p.quietMs } : {})
/** Other builds' device ids one registration may name (`siblingDeviceIds`). */
const MAX_SIBLINGS = 16
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,255}$/
const APNS_TOKEN = /^[0-9a-f]{64,200}$/

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const fail = (status: number, code: string, message: string) => {
  const res = json({ error: { code, message } }, status)
  // Rate limits use one-minute windows.
  if (status === 429) res.headers.set("retry-after", "60")
  return res
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

/**
 * Build spaces (PROTOCOL.md "Build spaces"): a dev build of the app or the Mac host sends
 * `X-Cmux-Build-Space: dev:<slug>` (its dev tag's slug, the same slug and 64-character cap as
 * scripts/lib/mobile-attach.sh), and stable and nightly builds send nothing (space ""). Each space sees only
 * its own devices, hubs, pushes and prefs.
 */
export const BUILD_SPACE_HEADER = "x-cmux-build-space"
/** The `ENVIRONMENT` values (wrangler.jsonc vars, vitest.config.ts) whose Worker serves dev spaces. */
const DEV_SPACE_ENVIRONMENTS: ReadonlySet<string> = new Set(["dev", "test", "local"])
const BUILD_SPACE = /^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/
/**
 * The caller's build space. An absent header is the stable space (""). A malformed value is refused (400),
 * never read as stable: a dev build with a broken tag must not land in stable data. `dev:default` is refused
 * too: the mobile-attach scripts reserve the `default` tag for the stable instance.
 *
 * Only the environments in `DEV_SPACE_ENVIRONMENTS` serve dev spaces; every other Worker, production included,
 * refuses them (403 `build_space.not_allowed`) instead of serving them or dropping the header. It is an allow-list
 * so a missing or misspelled `ENVIRONMENT` refuses too: production holds only stable data, and a dev build pointed
 * at it by mistake then fails on its first request, before auth or any read, rather than reading or writing a
 * person's real devices. Dev builds use the dev Worker (or a local one), where their spaces live.
 */
export const spaceOf = (req: Request, env: Pick<Env, "ENVIRONMENT">): string => {
  const value = req.headers.get(BUILD_SPACE_HEADER)
  if (value === null) return ""
  if (!BUILD_SPACE.test(value) || value === "dev:default")
    throw new HttpError(400, "build_space.invalid", `${BUILD_SPACE_HEADER} must be dev:<slug> (lowercase letters, digits and inner dashes, at most 64)`)
  if (!DEV_SPACE_ENVIRONMENTS.has(env.ENVIRONMENT)) throw new HttpError(403, "build_space.not_allowed", "dev build spaces are not served by the production API; use the dev API")
  return value
}

/** Workers rate limiting (PROTOCOL.md): a missing binding (tests, local) never limits. */
const limit = async (binding: RateLimit | undefined, key: string, what: string) => {
  if (!binding) return
  const { success } = await binding.limit({ key })
  if (!success) throw new HttpError(429, "rate_limited", `too many ${what}; try again in a minute`)
}

const readJson = async (req: Request): Promise<Record<string, unknown>> => {
  try {
    const v = await req.json()
    if (typeof v === "object" && v !== null && !Array.isArray(v)) return v as Record<string, unknown>
  } catch {}
  throw new HttpError(400, "bad_request", "body must be a JSON object")
}

const readBodyAtMost = async (req: Request, maxBytes: number): Promise<ArrayBuffer | null> => {
  const declared = Number(req.headers.get("content-length"))
  if (Number.isFinite(declared) && declared > maxBytes) return null
  if (!req.body) return new ArrayBuffer(0)
  const reader = req.body.getReader()
  const parts: Uint8Array[] = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel()
      return null
    }
    parts.push(value)
  }
  const body = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    body.set(part, offset)
    offset += part.byteLength
  }
  return body.buffer
}

/**
 * Per-project namespacing. The primary project keeps its bare names (existing hubs and rows stay where
 * they are); every other project's hubs and prefs rows are prefixed with its project id, so a team id or
 * personal space id that appeared in two projects would still be two separate spaces.
 */
const scoped = (env: Env, caller: Caller, key: string) => (caller.projectId === primaryProject(env).id ? key : `${caller.projectId}:${key}`)
/** The caller's identity, build space (`spaceOf`), and where a hub created by this request should live. */
type Ctx = Caller & { readonly space: string; readonly hint?: DurableObjectLocationHint; readonly t: Timing }
/**
 * The caller's own hub (PROTOCOL.md "Signaling WebSocket"): one per user, named by the owner key derived from
 * the verified token, never from a path or body value. Every hub call passes that key again, and the hub
 * refuses one that is not its owner's.
 */
const userHub = (env: Env, caller: Ctx) =>
  env.TEAM_HUB.get(env.TEAM_HUB.idFromName(userHubName(ownerKey(env, caller), caller.space)), caller.hint ? { locationHint: caller.hint } : undefined)
/** What every call into the caller's hub names: the owner key and build space, which must be the hub's own. */
const hubOwner = (env: Env, caller: Ctx): HubOwner => ({ ownerKey: ownerKey(env, caller), space: caller.space })
/**
 * Migration from team hubs (PROTOCOL.md 0.10.0). Hibernated sockets survive a deploy, so a socket can stay
 * parked in its old team hub (named by the team, `scoped(teamId)`) while its peers are in the user hub. Two
 * paths retire team hubs: the minute cron (`retireAllTeamHubs`, every team in the database), and lazily, the
 * first time an isolate serves a team after a membership check. A retire that failed (around a deploy the RPC
 * can reach a hub still on the previous class) is retried: only a success is remembered. Remove both once no
 * team hub holds sockets.
 */
const retireMemo = new Map<string, { done: boolean; until: number }>()
/**
 * After a deploy a Durable Object keeps running the previous class until it is evicted, and steady traffic (a
 * phone polling, these very retries) keeps it warm for minutes (seen live on 2026-10-20). The previous class has
 * no `retireTeamHub` ("The RPC receiver does not implement the method"), but every version has `forgetMac`, which
 * closes one device's sockets with 4001 `moved`; clients reconnect on 4001, now into their user hub. So a hub on
 * the previous class has the team's devices (from the database) moved out one by one, and is retired for good
 * once it runs the new class.
 */
const retireOnce = async (env: Env, name: string, via: string, deviceIds: ReadonlyArray<string>): Promise<number> => {
  const hit = retireMemo.get(name)
  // The sweep ignores a request's backoff: it carries every device of the team, a request only some.
  if (hit && (hit.done || (via !== "sweep" && Date.now() < hit.until))) return 0
  const configured = Number(env.TEAM_HUB_RETIRE_RETRY_MS)
  const retryMs = Number.isFinite(configured) && configured >= 0 ? configured : 10_000
  retireMemo.set(name, { done: false, until: Date.now() + retryMs })
  const stub = env.TEAM_HUB.get(env.TEAM_HUB.idFromName(name))
  try {
    const { closed } = await stub.retireTeamHub()
    retireMemo.set(name, { done: true, until: 0 })
    if (closed) console.log(JSON.stringify({ msg: "team hub retired", via, closed }))
    return closed
  } catch (e) {
    if (!String(e).includes("does not implement")) {
      console.log(JSON.stringify({ msg: "team hub retire failed", via, error: String(e) }))
      throw e
    }
    const previous = stub as unknown as { forgetMac(deviceId: string): Promise<void> }
    const moved = (await Promise.all(deviceIds.map((id) => previous.forgetMac(id).then(() => 1, () => 0)))).reduce<number>((a, b) => a + b, 0)
    console.log(JSON.stringify({ msg: "team hub on the previous class; devices moved", via, devices: deviceIds.length, moved }))
    return 0
  }
}
const retireTeamHub = (env: Env, ctx: ExecutionContext, caller: Ctx, teamId: string, deviceIds: ReadonlyArray<string> = []) => {
  // Only stable builds ever used the team hubs; a dev build's request never wakes or closes them.
  if (caller.space) return
  const name = scoped(env, caller, teamId)
  const hit = retireMemo.get(name)
  if (hit?.done) return
  ctx.waitUntil(retireOnce(env, name, "request", deviceIds).catch(() => {}))
}

/**
 * Retires the old hub of every team the database knows (devices and team prefs, both projects' naming), a few
 * at a time. Run by the minute cron; each hub remembers its retirement, so later sweeps cost one wake per team.
 */
export const retireAllTeamHubs = async (env: Env): Promise<{ teams: number; closed: number; failed: number }> => {
  const store = await openStore(env)
  let scopes: Array<{ project: string | null; teamId: string; deviceIds: Array<string> }>
  try {
    scopes = await store.listTeamScopes()
  } finally {
    await store.close().catch(() => {})
  }
  // Only teams with devices: a team known only from prefs never had a socket (and would create a hub).
  const byName = new Map(scopes.filter((s) => s.deviceIds.length).map((s) => [s.project ? `${s.project}:${s.teamId}` : s.teamId, s.deviceIds]))
  const names = [...byName.keys()]
  let closed = 0
  let failed = 0
  for (let i = 0; i < names.length; i += 16)
    await Promise.all(
      names.slice(i, i + 16).map((n) =>
        retireOnce(env, n, "sweep", byName.get(n)!).then(
          (c) => void (closed += c),
          () => void failed++
        )
      )
    )
  // One line a minute: the migration's progress (`retired` = hubs confirmed on the new class and empty).
  const retired = names.filter((n) => retireMemo.get(n)?.done).length
  console.log(JSON.stringify({ msg: "team hub sweep", teams: names.length, retired, closed, failed }))
  return { teams: names.length, closed, failed }
}
/**
 * The caller's identity in stored rows (devices.owner_user_id, team_prefs.user_id): the bare sub for the
 * primary project, `<projectId>:<sub>` otherwise. This records the project without a schema change, and the
 * existing ownership checks on owner_user_id then compare (project, sub). Stack subs are UUIDs (no ":").
 */
const ownerKey = (env: Env, caller: Caller) => scoped(env, caller, caller.userId)
const splitOwner = (env: Env, key: string): { projectId: string; userId: string } => {
  const i = key.indexOf(":")
  return i < 0 ? { projectId: primaryProject(env).id, userId: key } : { projectId: key.slice(0, i), userId: key.slice(i + 1) }
}

const requireMember = async (env: Env, teamId: string, caller: Ctx) => {
  if (!TEAM_ID.test(teamId)) throw new HttpError(400, "bad_request", "invalid teamId")
  // Personal space (PROTOCOL.md): `personal-<userId>` belongs to that user alone; no Stack call.
  if (teamId.startsWith(PERSONAL)) {
    if (teamId !== personalTeamId(caller.userId)) throw new HttpError(403, "not_member", "not a member of this team")
    return
  }
  let ok: boolean
  try {
    ok = await caller.t.span("member", userHub(env, caller).isMember(teamId, { userId: caller.userId, projectId: caller.projectId, token: caller.token }, hubOwner(env, caller)))
  } catch (e) {
    console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
    throw new HttpError(502, "membership_unavailable", "could not check team membership")
  }
  if (!ok) throw new HttpError(403, "not_member", "not a member of this team")
}

const withStore = async <T>(env: Env, ctx: ExecutionContext, f: (s: Store) => Promise<T>): Promise<T> => {
  const t = timingFor(ctx)
  const store = await t.span("db_connect", openStore(env)).catch((e: unknown) => {
    // A Worker deployed before its migration: one clear answer instead of a SQL error from each statement.
    if (e instanceof StoreSchemaError) throw new HttpError(503, "store.schema_outdated", e.message)
    throw e
  })
  try {
    return await t.span("db", f(store))
  } finally {
    ctx.waitUntil(store.close().catch(() => {}))
  }
}

/**
 * The PROTOCOL.md device object: `ownerUserId` is the bare sub (the project is recorded, not returned), and the
 * build space is the caller's own, so it is not returned either.
 */
const publicDevice = (env: Env, { machineId, space: _space, ...d }: Device) => ({
  ...d,
  ownerUserId: splitOwner(env, d.ownerUserId).userId,
  ...machineOf({ machineId })
})

const colo = (req: Request): string | null => {
  const c = (req as Request & { cf?: { colo?: unknown } }).cf?.colo
  return typeof c === "string" ? c : null
}

/** Where a request entered Cloudflare: colo, country and continent codes (`req.cf`), each null when unknown. */
const ingressOf = (req: Request): Ingress => {
  const cf = (req as Request & { cf?: { colo?: unknown; country?: unknown; continent?: unknown; latitude?: unknown; longitude?: unknown; asn?: unknown } }).cf
  const code = (v: unknown) => (typeof v === "string" && /^[A-Z0-9]{2,4}$/.test(v) ? v : null)
  // Rounded to 0.1 degree (about 11 km): enough to place a relay, never a street.
  const deg = (v: unknown, max: number) => {
    const n = typeof v === "string" ? Number.parseFloat(v) : typeof v === "number" ? v : Number.NaN
    return Number.isFinite(n) && Math.abs(n) <= max ? Math.round(n * 10) / 10 : null
  }
  const out: Ingress = { colo: code(cf?.colo), country: code(cf?.country), continent: code(cf?.continent), lat: deg(cf?.latitude, 90), lon: deg(cf?.longitude, 180) }
  // Its network's AS number: the hub's central region pick keys a user's network pair on it (region-pick.ts).
  if (typeof cf?.asn === "number" && Number.isInteger(cf.asn) && cf.asn > 0 && cf.asn < 2 ** 32) out.asn = cf.asn
  // The client's netcheck (`?netcheck=wnam:31,enam:72`, PROTOCOL.md "Relay placement"), when it sent one.
  const rtt = parseNetcheck(new URL(req.url).searchParams.get("netcheck"))
  if (rtt) out.rtt = rtt
  return out
}

const later = (a: string | null, b: string | null) => (!a ? b : !b ? a : a > b ? a : b)

/**
 * Per-isolate caches for the launch path (Server-Timing showed each costs a round trip to Stack or
 * Cloudflare's TURN API on every request):
 * - the caller's Stack teams for /me/macs, for a minute, one fetch in flight per user;
 * - TURN credentials, for a tenth of their lifetime, one fetch in flight.
 * (Signal sockets need no device cache: the caller's hub keeps the devices registered to the caller.)
 */
const TEAMS_TTL_MS = 60_000
const teamsCache = new Map<string, { at: number; teams: Promise<ReadonlyArray<string>> }>()
const cachedUserTeams = (env: Env, caller: Caller): Promise<ReadonlyArray<string>> => {
  const key = `${caller.projectId}\u0000${caller.userId}`
  const hit = teamsCache.get(key)
  if (hit && Date.now() - hit.at < TEAMS_TTL_MS) return hit.teams
  const teams = userTeams(env, caller)
  teamsCache.set(key, { at: Date.now(), teams })
  teams.catch(() => teamsCache.delete(key))
  return teams
}

const routes = async (req: Request, env: Env, ctx: ExecutionContext): Promise<Response> => {
  const url = new URL(req.url)
  const path = url.pathname.replace(/\/+$/, "") || "/"
  const method = req.method

  // Before auth and every route: a malformed space, or a dev space on production, is refused outright.
  const space = spaceOf(req, env)

  if (path === "/v1/health" && method === "GET")
    return json({ ok: true, version: env.API_VERSION, capabilities: ["sealed-chunk-cache-v1"], stackProjects: stackProjects(env).map((p) => p.id), colo: colo(req) })

  const bearer = bearerOf(req)
  if (!bearer) return fail(401, "unauthorized", "missing or invalid Stack access token")
  const t = timingFor(ctx)
  const auth = await t.span("auth", authenticate(env, bearer.token))
  // The reason (expired, restricted, unknown_key, ...) names why without echoing the token.
  if (!("caller" in auth)) return fail(401, "unauthorized", `missing or invalid Stack access token (${auth.rejection})`)
  const caller: Ctx = { ...auth.caller, space, t, hint: locationHintFor((req as { cf?: { continent?: unknown; longitude?: unknown; country?: unknown } }).cf) }
  const me = ownerKey(env, caller)
  const who = hubOwner(env, caller)
  await t.span("limit", limit(env.USER_LIMIT, me, "requests"))

  if (path === "/v1/ice" && method === "GET") {
    await limit(env.ICE_LIMIT, me, "ICE requests")
    const { iceServers: list, ttl, turn } = await t.span("turn", cachedIceServers(env, ctx))
    return json({ iceServers: list, hopServers: await hopServers(env, ttl), ttl, turn })
  }

  const probe = path.match(/^\/v1\/netcheck\/([a-z]+)$/)
  if (probe && method === "GET") {
    // A netcheck target (PROTOCOL.md "Relay placement"): a WebSocket to one Durable Object per region, created
    // with that region's hint, that answers `ping` with `pong` without waking. The client times a few pings to
    // each region and sends the result with its signal socket, so a relay is placed by measured round trips.
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    if (env.LINK_RELAY_MODE === "off") return fail(503, "relay_off", "the cmux relay is turned off")
    const region = probe[1]!
    if (!isRegion(region)) throw new HttpError(404, "unknown_region", "no such netcheck region")
    const room = env.LINK_RELAY.get(env.LINK_RELAY.idFromName(netcheckRoomName(space, region)), { locationHint: region })
    const headers = new Headers({ upgrade: "websocket" })
    if ((req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === RELAY_SUBPROTOCOL)) headers.set("x-cmux-relay-subprotocol", "1")
    return t.span("relay", room.fetch("https://link-relay/netcheck", { headers }))
  }

  const relay = path.match(/^\/v1\/relay\/([^/]+)$/)
  if (relay && method === "GET") {
    // The link's WebSocket relay (PROTOCOL.md "WebSocket relay"): only the two devices the caller's hub bound to
    // this session can join, each with its own socket, and only after direct UDP and TURN failed them.
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    if (env.LINK_RELAY_MODE === "off") return fail(503, "relay_off", "the cmux relay is turned off")
    const sessionId = pathSegment(relay[1]!).toLowerCase()
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    if (!UUID.test(sessionId) || !UUID.test(deviceId)) throw new HttpError(400, "bad_request", "sessionId and deviceId must be UUIDs")
    // The device's own ticket, which the hub stamped on the signals it sent to that device's socket.
    const ticket = req.headers.get(RELAY_TICKET_HEADER)
    const bound = await t.span("hub", userHub(env, caller).relayPeer(who, sessionId, deviceId, ticket))
    if (!bound) throw new HttpError(403, "not_in_session", "this device is not a party of that link session")
    const peer = bound.peer
    // Placed from both ends (placement.ts): only the first join creates the object, later hints are ignored.
    const placed = relayPlacement(ingressOf(req), bound.ingress, caller.hint)
    const room = env.LINK_RELAY.get(env.LINK_RELAY.idFromName(relayRoomName(me, space, sessionId)), placed.hint ? { locationHint: placed.hint } : undefined)
    const headers = new Headers({ upgrade: "websocket", "x-cmux-relay-device": deviceId, "x-cmux-relay-peer": peer, "x-cmux-relay-owner": me, "x-cmux-relay-space": space })
    // Echo only cmux-relay.v1; the bearer subprotocol is never selected (it would echo the token back).
    if ((req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === RELAY_SUBPROTOCOL)) headers.set("x-cmux-relay-subprotocol", "1")
    return t.span("relay", room.fetch("https://link-relay/join", { headers }))
  }

  const chunk = path.match(/^\/v1\/chunks\/(have|get|[0-9a-fA-F]{64})$/)
  if (chunk && (method === "PUT" || method === "GET" || method === "POST")) {
    if ((method === "PUT" || method === "GET") && (chunk[1] === "have" || chunk[1] === "get")) throw new HttpError(405, "method_not_allowed", "method not allowed")
    if (method === "POST" && chunk[1] !== "have" && chunk[1] !== "get") throw new HttpError(405, "method_not_allowed", "method not allowed")
    if (env.LINK_RELAY_MODE === "off") return fail(503, "relay_off", "the sealed chunk cache is turned off")
    const sessionId = (url.searchParams.get("sessionId") ?? req.headers.get("x-cmux-chunk-session") ?? "").toLowerCase()
    const deviceId = (url.searchParams.get("deviceId") ?? req.headers.get("x-cmux-chunk-device") ?? "").toLowerCase()
    if (!UUID.test(sessionId) || !UUID.test(deviceId)) throw new HttpError(400, "bad_request", "sessionId and deviceId must be UUIDs")
    // The device's own relay ticket, as for the relay: another device of the same user cannot pass this one's id.
    const ticket = req.headers.get(RELAY_TICKET_HEADER)
    const bound = await t.span("hub", userHub(env, caller).relayPeer(who, sessionId, deviceId, ticket))
    if (!bound) throw new HttpError(403, "not_in_session", "this device is not a party of that link session")
    const peer = bound.peer
    if (chunk[1] !== "have" && chunk[1] !== "get" && (!CHUNK_ID.test(chunk[1]!) || chunk[1] !== chunk[1]!.toLowerCase())) throw new HttpError(400, "bad_request", "chunk id must be 64 lowercase hexadecimal characters")
    const cache = env.CHUNK_CACHE.get(env.CHUNK_CACHE.idFromName(chunkPairName(me, space, deviceId, peer)), caller.hint ? { locationHint: caller.hint } : undefined)
    const target = chunk[1] === "have" ? "/have" : chunk[1] === "get" ? "/get" : `/${chunk[1]!.toLowerCase()}`
    const headers = new Headers(req.headers)
    headers.set("x-cmux-chunk-device", deviceId)
    headers.delete("authorization")
    headers.delete("cookie")
    const body = method === "PUT" || method === "POST" ? await readBodyAtMost(req, method === "PUT" ? CHUNK_MAX_BYTES : CHUNK_BATCH_MAX_BODY_BYTES) : undefined
    if (body === null) return fail(413, "payload_too_large", "chunk request body is too large")
    return t.span("chunks", cache.fetch(`https://chunk-cache${target}`, { method, headers, body }))
  }

  const cachePath = path.match(/^\/v1\/relay-cache\/([^/]+)\/(snapshot|delta|catch-up|ack)$/)
  if (cachePath) {
    // The relay's sealed snapshot cache and delta catch-up (RFD 0142 R2 and R9, PROTOCOL.md "Relay snapshot seal",
    // "Relay delta catch-up"): one LinkRelay room per source Mac, so a phone's cold open reads it with no link
    // session and the Mac asleep. The Mac writes for a named viewer (`?viewer=`); a viewer reads only its own.
    // The relay sees only each envelope's clear header (relay-cache.ts `peek`), never the plaintext.
    if (env.LINK_RELAY_MODE === "off") return fail(503, "relay_off", "the cmux relay is turned off")
    if (env.LINK_RELAY_CACHE !== "on") return fail(503, "relay_cache_off", "the relay cache is turned off")
    const source = pathSegment(cachePath[1]!).toLowerCase()
    const what = cachePath[2]!
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    if (!UUID.test(source) || !UUID.test(deviceId)) throw new HttpError(400, "bad_request", "sourceDeviceId and deviceId must be UUIDs")
    const kindOf = async (id: string) => {
      const kind = await t.span("hub", userHub(env, caller).hubDevice(who, id))
      if (kind) return kind
      const device = await withStore(env, ctx, (s) => s.getDevice(space, id))
      return device && device.ownerUserId === me ? (device.kind === "mac" ? "mac" : "phone") : null
    }
    const writes = (what === "snapshot" && method === "PUT") || (what === "delta" && method === "POST")
    let viewer = deviceId
    if (writes) {
      // Only the source itself writes, and only for one of the owner's own devices.
      if (deviceId !== source) throw new HttpError(403, "not_the_source", "only the source device writes its cache")
      viewer = (url.searchParams.get("viewer") ?? "").toLowerCase()
      if (!UUID.test(viewer)) throw new HttpError(400, "bad_request", "viewer must be a UUID")
      const [sourceKind, viewerKind] = await Promise.all([kindOf(source), kindOf(viewer)])
      if (sourceKind !== "mac") throw new HttpError(403, "not_a_source", "only a Mac or VM device has a relay cache")
      if (!viewerKind) throw new HttpError(403, "not_owner", "the viewer is not one of your devices")
    } else {
      const [sourceKind, viewerKind] = await Promise.all([kindOf(source), kindOf(deviceId)])
      if (sourceKind !== "mac" || !viewerKind) throw new HttpError(403, "not_owner", "register this device first")
    }
    const room = env.LINK_RELAY.get(env.LINK_RELAY.idFromName(relayCacheRoomName(me, space, source)), caller.hint ? { locationHint: caller.hint } : undefined)
    const target = new URL(`https://link-relay/cache/${what}`)
    const stream = url.searchParams.get("stream")
    if (stream !== null) target.searchParams.set("stream", stream)
    const headers = new Headers({ [CACHE_VIEWER_HEADER]: viewer })
    const type = req.headers.get("content-type")
    if (type) headers.set("content-type", type)
    const length = req.headers.get("content-length")
    if (length) headers.set("content-length", length)
    return t.span("relay", room.fetch(target.toString(), { method, headers, body: method === "GET" ? undefined : req.body }))
  }

  const hubPath = path.match(/^\/v1\/hub\/([^/]+)$/)
  if (hubPath && method === "GET") {
    // The three-way hub (RFD 0142 R6, PROTOCOL.md "Three-way hub"): the session's sources (the owner's Mac and VM,
    // both registered as kind mac) upload, the owner's viewers download the newest copy once. Only the owner's own
    // registered devices join; everything past the clear header is sealed end to end, so the room is per owner.
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    if (env.HUB_RELAY_MODE === "off") return fail(503, "hub_off", "the cmux hub is turned off")
    const sessionId = decodeURIComponent(hubPath[1]!).toLowerCase()
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    const role = url.searchParams.get("role") ?? ""
    if (!UUID.test(sessionId) || !UUID.test(deviceId)) throw new HttpError(400, "bad_request", "sessionId and deviceId must be UUIDs")
    if (role !== "mac" && role !== "vm" && role !== "viewer") throw new HttpError(400, "bad_request", "role must be mac, vm or viewer")
    let kind = await t.span("hub", userHub(env, caller).hubDevice(who, deviceId))
    if (!kind) {
      const device = await withStore(env, ctx, (s) => s.getDevice(space, deviceId))
      if (device && device.ownerUserId === me) kind = device.kind === "mac" ? "mac" : "phone"
    }
    if (!kind) throw new HttpError(403, "not_owner", "register this device first")
    if (role !== "viewer" && kind !== "mac") throw new HttpError(403, "not_a_source", "only a Mac or VM device can be a hub source")
    const room = env.HUB_RELAY.get(env.HUB_RELAY.idFromName(hubRoomName(me, space, sessionId)), caller.hint ? { locationHint: caller.hint } : undefined)
    const headers = new Headers({ upgrade: "websocket", "x-cmux-hub-device": deviceId, "x-cmux-hub-role": role, "x-cmux-hub-session": sessionId })
    // The capability handshake: a hub client offers cmux-hub.v1 and this relay echoes it (never the bearer entry).
    if ((req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === HUB_SUBPROTOCOL)) headers.set("x-cmux-hub-subprotocol", "1")
    return t.span("relay", room.fetch("https://hub-relay/join", { headers }))
  }

  if (path === "/v1/me/bootstrap" && method === "POST") {
    // The phone's launch in one round trip (PROTOCOL.md): register its devices in `teamId`, and return
    // that team's Macs, the caller's own Macs everywhere, and ICE servers. Each part runs the same route
    // as its own call, all at once; a part that fails carries its error instead of failing the rest.
    const b = await readJson(req)
    if (typeof b.teamId !== "string") throw new HttpError(400, "bad_request", "teamId is required")
    const list = Array.isArray(b.devices) ? (b.devices as Array<Record<string, unknown>>).slice(0, 4) : []
    // Each part runs in the caller's build space.
    const headers: Record<string, string> = {
      authorization: req.headers.get("authorization") ?? `Bearer ${bearer.token}`,
      "content-type": "application/json",
      ...(space ? { [BUILD_SPACE_HEADER]: space } : {})
    }
    const part = async (method: string, path: string, body?: unknown) => {
      const sub = new Request(new URL(path, url), { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
      let res: Response
      try {
        res = await routes(sub, env, ctx)
      } catch (e) {
        res = e instanceof HttpError ? fail(e.status, e.code, e.message) : fail(500, "internal", "internal error")
      }
      return (await res.json()) as Record<string, unknown>
    }
    const team = encodeURIComponent(b.teamId)
    const [devices, macs, myMacs, ice] = await Promise.all([
      Promise.all(list.map((d) => part("POST", "/v1/devices", { ...d, teamId: b.teamId }))),
      part("GET", `/v1/teams/${team}/macs`),
      part("GET", "/v1/me/macs"),
      part("GET", "/v1/ice")
    ])
    return json({ devices, macs, myMacs, ice })
  }

  if (path === "/v1/diagnostics/connectivity-incidents" && method === "POST") {
    // A team member's phone reports a major connectivity incident (PROTOCOL.md "Connectivity incidents").
    // Who it is comes from Stack, not the body: only a verified team email is heard, and agent accounts and
    // simulators go to the test route.
    await limit(env.INCIDENT_LIMIT, me, "connectivity reports")
    let report
    try {
      report = parseReport(await readJson(req))
    } catch (e) {
      if (e instanceof ReportError) throw new HttpError(400, "bad_request", e.message)
      throw e
    }
    let reporter
    try {
      reporter = await t.span("stack_user", userEmail(env, caller))
    } catch (e) {
      console.log(JSON.stringify({ msg: "connectivity report: user lookup failed", error: String(e) }))
      throw new HttpError(502, "user_unavailable", "could not look up the account; retry later")
    }
    const audience = audienceOf(reporter.email, reporter.verified, { ...report.app, ...(report.simulations ? { simulations: report.simulations } : {}) }, env.CONNECTIVITY_ALERT_EXCLUDED_EMAILS)
    if (audience.route === "refuse") return fail(403, audience.why === "unverified" ? "email_unverified" : "not_team", "connectivity reports are for the cmux team")
    // Whether the Mac is awake: its socket lives in the caller's own hub (v1 links only reach the caller's
    // own Macs), so another user's Mac id finds nothing there.
    const liveness = await t
      .span("hub", userHub(env, caller).macLiveness(who, report.mac.id.toLowerCase(), judgedAt(report, Date.now())))
      .catch((e) => {
        console.log(JSON.stringify({ msg: "connectivity report: liveness unavailable", error: String(e) }))
        return null
      })
    const desk = env.CONNECTIVITY_ALERT_DESK.get(env.CONNECTIVITY_ALERT_DESK.idFromName("desk"))
    const r = await t.span(
      "desk",
      // A dev build's reports are their own reporter, so they never share a stable report's thread or cap.
      desk.report(report, { key: space ? `${space}|${me}` : me, email: reporter.email! }, audience.route === "test" ? { route: "test", why: audience.why } : { route: "team" }, { liveness })
    )
    if (!r.accepted) return fail(409, "conflict", "this incident id belongs to another account")
    return json({ accepted: true, route: audience.route, ...(r.note ? { note: r.note } : {}) }, 202)
  }

  if (path === "/v1/me/devices" && method === "GET") {
    const [rows, presence] = await Promise.all([withStore(env, ctx, (s) => s.listOwnerDevices(space, me)), t.span("hub", userHub(env, caller).macs(who))])
    // Presence for Macs from the caller's own hub.
    const live = new Map(presence.map((m) => [m.deviceId, m.online]))
    return json({
      devices: rows.map((d) => ({
        deviceId: d.deviceId,
        kind: d.kind,
        name: d.name,
        teamId: d.teamId,
        createdAt: d.createdAt,
        updatedAt: d.updatedAt,
        lastSeenAt: d.lastSeenAt,
        online: d.kind === "mac" ? (live.get(d.deviceId) ?? false) : null,
        ...machineOf(d),
        push: d.push
      }))
    })
  }

  if (path === "/v1/me" && method === "DELETE") {
    // Account deletion (PROTOCOL.md): purge everything stored for the caller and evict their sockets. The
    // stable app's deletion takes every build space with it (it is the person's account); a dev build's
    // purges only its own space, never stable data.
    const gone = await withStore(env, ctx, (s) => s.deleteOwner(me, space ? { space } : "all"))
    const spaces = new Set([space, ...gone.map((d) => d.space)])
    await Promise.all([...spaces].map((sp) => userHub(env, { ...caller, space: sp }).purge(hubOwner(env, { ...caller, space: sp }))))
    console.log(JSON.stringify({ msg: "account data deleted", devices: gone.length }))
    return json({ deleted: { devices: gone.length } })
  }

  const dev = path.match(/^\/v1\/devices\/([^/]+)(?:\/(push|notify|mailbox)(?:\/([^/]+))?)?$/)
  if (dev) {
    const deviceId = pathSegment(dev[1]!).toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    const sub = dev[2]
    const itemId = dev[3] === undefined ? undefined : pathSegment(dev[3]).toLowerCase()
    if (itemId !== undefined && sub !== "mailbox") return fail(404, "not_found", "not found")
    if (sub === "mailbox") {
      // PROTOCOL.md "Reply mailbox": a phone's sealed reply for its own Mac. The Worker never opens it.
      const mac = await withStore(env, ctx, (s) => s.getDevice(space, deviceId))
      if (!mac) throw new HttpError(404, "not_found", "no such device")
      if (mac.ownerUserId !== me || mac.kind !== "mac") throw new HttpError(403, "not_owner", "replies go to your own Mac")
      if (itemId !== undefined && method === "GET") {
        if (!UUID.test(itemId)) throw new HttpError(400, "bad_request", "the item id must be a UUID")
        const state = await userHub(env, caller).mailboxState(who, deviceId, itemId)
        if (!state) throw new HttpError(404, "not_found", "no such item")
        return json(state)
      }
      if (itemId !== undefined || method !== "POST") return fail(405, "method_not_allowed", "method not allowed")
      const b = await readJson(req)
      const id = typeof b.id === "string" ? b.id.toLowerCase() : ""
      const from = typeof b.from === "string" ? b.from.toLowerCase() : ""
      if (!UUID.test(id)) throw new HttpError(400, "bad_request", "id must be a UUID")
      if (!UUID.test(from)) throw new HttpError(400, "bad_request", "from must be your phone's device id")
      if (!isSealedText(b.sealed, MAX_MAILBOX_SEALED)) throw new HttpError(400, "bad_request", `sealed must be base64url of at most ${MAX_MAILBOX_SEALED} characters`)
      const phone = await withStore(env, ctx, (s) => s.getDevice(space, from))
      if (!phone || phone.ownerUserId !== me || phone.kind !== "phone") throw new HttpError(403, "not_owner", "replies come from your own phone")
      // `hold` (seconds, API 0.18.0 "Store and forward"): how long the item waits for a Mac that sleeps.
      if (b.hold !== undefined && !(Number.isInteger(b.hold) && (b.hold as number) >= 1 && (b.hold as number) * 1000 <= MAILBOX_MAX_HOLD_MS))
        throw new HttpError(400, "bad_request", `hold must be whole seconds from 1 to ${MAILBOX_MAX_HOLD_MS / 1000}`)
      await limit(env.MAILBOX_LIMIT, me, "replies")
      const ttl = b.hold === undefined ? MAILBOX_TTL_MS : (b.hold as number) * 1000
      const r = await userHub(env, caller).mailboxPost(who, { id, mac: deviceId, from, sealed: b.sealed }, ttl)
      if ("error" in r) {
        if (r.error === "full") throw new HttpError(429, "rate_limited", "this Mac has too many replies waiting; try again later")
        throw new HttpError(409, "conflict", "another reply already has this id")
      }
      return json(r)
    }
    if (!sub && method === "DELETE") {
      const r = await withStore(env, ctx, (s) => s.deleteDevice(space, deviceId, me))
      if (r === "not_owner") throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (!r) throw new HttpError(404, "not_found", "no such device")
      await userHub(env, caller).forgetDevice(who, deviceId)
      return json({ deleted: true, deviceId })
    }
    if (sub === "push" && (method === "PUT" || method === "DELETE")) {
      const device = await withStore(env, ctx, (s) => s.getDevice(space, deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me) throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (method === "DELETE") {
        await withStore(env, ctx, (s) => s.deletePush(space, deviceId))
        return json({ deleted: true })
      }
      if (device.kind !== "phone") throw new HttpError(400, "bad_request", "only a phone takes push notifications")
      const b = await readJson(req)
      const token = typeof b.token === "string" ? b.token.toLowerCase() : ""
      if (!APNS_TOKEN.test(token)) throw new HttpError(400, "bad_request", "token must be the APNs device token in hex")
      if (b.environment !== "sandbox" && b.environment !== "production") throw new HttpError(400, "bad_request", "environment must be sandbox or production")
      if (typeof b.topic !== "string" || !apnsTopics(env).has(b.topic)) throw new HttpError(400, "bad_request", "topic is not an app this service pushes to")
      let kinds: Array<PushKind> = [...PUSH_KINDS]
      if (b.kinds !== undefined) {
        if (!Array.isArray(b.kinds) || b.kinds.some((k) => !(PUSH_KINDS as ReadonlyArray<unknown>).includes(k)))
          throw new HttpError(400, "bad_request", `kinds must be a list of ${PUSH_KINDS.join(", ")}`)
        kinds = [...new Set(b.kinds as Array<PushKind>)]
      }
      let mutedMacs: Array<string> = []
      if (b.mutedMacs !== undefined && b.mutedMacs !== null) {
        if (!Array.isArray(b.mutedMacs) || b.mutedMacs.length > 64 || b.mutedMacs.some((m) => typeof m !== "string" || !UUID.test(m.toLowerCase())))
          throw new HttpError(400, "bad_request", "mutedMacs must be at most 64 Mac device ids")
        mutedMacs = [...new Set((b.mutedMacs as Array<string>).map((m) => m.toLowerCase()))]
      }
      if (b.previews !== undefined && b.previews !== null && typeof b.previews !== "boolean") throw new HttpError(400, "bad_request", "previews must be true or false")
      const previews = b.previews !== false
      const r = await withStore(env, ctx, (s) =>
        s.setPush({ deviceId, space, ownerUserId: me, token, environment: b.environment as "sandbox" | "production", topic: b.topic as string, kinds, mutedMacs, previews })
      )
      return json({ push: { environment: r.environment, topic: r.topic, kinds: r.kinds, mutedMacs: r.mutedMacs, previews: r.previews, updatedAt: r.updatedAt } })
    }
    if (sub === "notify" && method === "POST") {
      const parsed = parseNotify(await readJson(req))
      if (typeof parsed === "string") throw new HttpError(400, "bad_request", parsed)
      const device = await withStore(env, ctx, (s) => s.getDevice(space, deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me || device.kind !== "mac") throw new HttpError(403, "not_owner", "notify from your own Mac")
      await limit(env.NOTIFY_LIMIT, notifyLimitKey(deviceId, parsed.kind, parsed.batch), "notifications")
      const config = apnsConfig(env)
      const kind = parsed.kind
      const regs = await withStore(env, ctx, (s) => s.listOwnerPush(space, me))
      // The kinds some phone that has not muted this Mac wants: the Mac skips the rest (terminal, say).
      const wants = wantedKinds(regs, deviceId)
      // Every phone that wants it, however many: a Mac with more than MAX_SEALED_PHONES boxes splits one
      // event into a lead and batches, and each phone is a target of exactly one of them.
      const wanting = config ? pushTargets(regs, deviceId, kind) : []
      if (!config || wanting.length === 0) return json({ configured: !!config, sent: 0, failed: 0, dropped: 0, wants })
      // A burst of turn ends from one session is one notification (a Mac on an older host sends every one).
      // Checked only once some phone wants this kind, so an unwanted kind never uses up the window; a batch
      // follows a lead that passed it (the Mac sends no batch after a coalesced lead).
      const key = parsed.batch ? undefined : turnPushKey(deviceId, parsed)
      if (key && !(await userHub(env, caller).turnPushAllowed(who, key, TURN_PUSH_WINDOW_MS)))
        return json({ configured: true, sent: 0, failed: 0, dropped: 0, coalesced: true, wants })
      const targets = notifyTargets(wanting, parsed)
      // `batches`: this Worker sends each phone one push across a lead and its batches (API 0.16.0), so the Mac
      // may send the batches; an older Worker ignores `batch` and would push them to everyone again.
      if (targets.length === 0) return json({ configured: true, sent: 0, failed: 0, dropped: 0, wants, batches: true })
      const results = await sendApns(config, targets, { ...parsed, macId: deviceId, macName: clean(device.name, 40) }, Date.now())
      const drop = results.filter((r) => r.outcome === "drop_target").map((r) => r.token)
      if (drop.length) await withStore(env, ctx, (s) => s.dropPushTokens(space, drop))
      const failed = results.filter((r) => r.outcome === "failed")
      if (failed.length) console.log(JSON.stringify({ msg: "apns failed", results: failed.map((r) => ({ environment: r.environment, status: r.status, reason: r.reason })) }))
      // Why APNs refused, so the Mac (and whoever reads its log) can see it without the Worker's logs.
      const failures = notifyFailures(results)
      // Not sent: APNs refused the key or topic for another send to the same environment and topic.
      const skipped = results.filter((r) => r.outcome === "skipped").length
      return json({
        configured: true,
        sent: results.filter((r) => r.outcome === "sent").length,
        failed: failed.length,
        dropped: drop.length,
        ...(skipped ? { skipped } : {}),
        wants,
        batches: true,
        ...(failures.length ? { failures } : {})
      })
    }
    return fail(405, "method_not_allowed", "method not allowed")
  }

  if (path === "/v1/devices" && method === "POST") {
    const b = await readJson(req)
    const { deviceId, kind, name, teamId, wgPublicKey, machineId, siblingDeviceIds } = b
    if (typeof deviceId !== "string" || !UUID.test(deviceId.toLowerCase())) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    if (kind !== "mac" && kind !== "phone") throw new HttpError(400, "bad_request", "kind must be mac or phone")
    if (typeof name !== "string" || !name.trim() || name.length > 100) throw new HttpError(400, "bad_request", "name must be 1-100 characters")
    if (typeof teamId !== "string") throw new HttpError(400, "bad_request", "teamId is required")
    if (wgPublicKey !== undefined && wgPublicKey !== null && (typeof wgPublicKey !== "string" || !WG_KEY.test(wgPublicKey)))
      throw new HttpError(400, "bad_request", "wgPublicKey must be a base64 Curve25519 key")
    // A Mac's machine id: which computer it runs on, so the phone lists two builds on one Mac as one Mac. A
    // name never says that (several Macs can share one), and only a Mac has one.
    if (machineId !== undefined && (kind !== "mac" || typeof machineId !== "string" || !MACHINE_ID.test(machineId)))
      throw new HttpError(400, "bad_request", "machineId must be 32 lowercase hex digits, for a Mac")
    if (
      siblingDeviceIds !== undefined &&
      (machineId === undefined ||
        !Array.isArray(siblingDeviceIds) ||
        siblingDeviceIds.length > MAX_SIBLINGS ||
        siblingDeviceIds.some((id) => typeof id !== "string" || !UUID.test(id.toLowerCase())))
    )
      throw new HttpError(400, "bad_request", `siblingDeviceIds must be at most ${MAX_SIBLINGS} device ids, with a machineId`)
    await requireMember(env, teamId, caller)
    const id = deviceId.toLowerCase()
    const siblings = [...new Set(((siblingDeviceIds ?? []) as Array<string>).map((s) => s.toLowerCase()))].filter((s) => s !== id)
    const owner = ownerKey(env, caller)
    const r = await withStore(env, ctx, async (s) => {
      const up = await s.upsertDevice({
        deviceId: id,
        space,
        ownerUserId: owner,
        teamId,
        kind,
        name: name.trim(),
        wgPublicKey: (wgPublicKey as string | null | undefined) ?? null,
        ...(machineId === undefined ? {} : { machineId: machineId as string })
      })
      if (typeof up === "string") return up
      // Other builds on this Mac (a deleted build's record that will never register again): this Mac's machine
      // id, only for the caller's own Macs that have none. Never another owner's device, never a phone.
      const claimed = typeof machineId === "string" && siblings.length ? await s.claimSiblings(space, owner, machineId, siblings) : []
      return { ...up, claimed }
    })
    if (r === "not_owner") throw new HttpError(403, "not_owner", "this deviceId belongs to another user")
    if (r === "other_space") throw new HttpError(409, "build_space.device_conflict", "this deviceId is registered by another user's build of the app")
    // The caller's device moved here from another build space (Store.upsertDevice): that space's hub lets it go
    // (presence `removed`, its old socket closed with 4002), so it is never listed or dialed there again.
    if (r.movedFrom !== null) {
      const from = r.movedFrom
      await t
        .span("hub_moved", env.TEAM_HUB.get(env.TEAM_HUB.idFromName(userHubName(owner, from))).forgetDevice({ ownerKey: owner, space: from }, r.device.deviceId))
        .catch((e: unknown) => console.log(JSON.stringify({ msg: "moved device: old hub unavailable", error: String(e) })))
    }
    // The caller's hub notes the device (and its team; a team move closes its socket with 4001 `moved`).
    await t.span(
      "hub",
      userHub(env, caller).register({
        deviceId: r.device.deviceId,
        ownerKey: r.device.ownerUserId,
        space,
        kind: r.device.kind,
        name: r.device.name,
        teamId,
        userId: caller.userId,
        projectId: caller.projectId,
        machineId: r.device.machineId,
        claimed: r.claimed
      })
    )
    return json({ device: publicDevice(env, r.device) })
  }

  if (path === "/v1/me/macs" && method === "GET") {
    // The caller's own Macs in every space they can reach (PROTOCOL.md): a phone finds its Mac whatever
    // team either side has selected. Only Macs the caller registered (the v1 admission rule), only teams
    // the caller still belongs to, presence from each team's hub.
    const rows = await withStore(env, ctx, (s) => s.listOwnerMacs(space, me))
    const teamIds = [...new Set(rows.map((d) => d.teamId))]
    let stackTeams: ReadonlySet<string> = new Set()
    if (teamIds.some((t) => !t.startsWith(PERSONAL))) {
      try {
        stackTeams = new Set(await t.span("stack", cachedUserTeams(env, caller)))
      } catch (e) {
        console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
        throw new HttpError(502, "membership_unavailable", "could not check team membership")
      }
    }
    const reachable = new Set(teamIds.filter((t) => (t.startsWith(PERSONAL) ? t === personalTeamId(caller.userId) : stackTeams.has(t))))
    for (const team of reachable) retireTeamHub(env, ctx, caller, team, rows.filter((d) => d.teamId === team).map((d) => d.deviceId))
    const presence = new Map((await t.span("hub", userHub(env, caller).macs(who))).map((m) => [m.deviceId, m]))
    return json({
      macs: rows.flatMap((d) => {
        if (!reachable.has(d.teamId)) return []
        const p = presence.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, teamId: d.teamId, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: caller.userId, ...machineOf(d), ...quietOf(p) }]
      })
    })
  }

  if (path === "/v1/teams" && method === "POST") {
    // Create team (PROTOCOL.md): Stack's client API refuses it, so the Worker creates the team with the
    // caller's project server key and the caller as its creator and first member, then grants the caller
    // team_admin (rolled back by deleting the team when the grant fails; see createTeam).
    const b = await readJson(req)
    const name = typeof b.name === "string" ? b.name.trim() : ""
    if (!name || name.length > 64 || /\p{Cc}/u.test(name)) throw new HttpError(400, "bad_request", "name must be 1 to 64 characters, no control characters")
    await limit(env.TEAM_LIMIT, me, "team creations")
    const r = await createTeam(env, caller, name)
    if (!r.ok) {
      if (r.code === "team_creation_unavailable") return fail(503, r.code, "this service can't create teams for your account yet")
      return fail(r.status === 401 || r.status === 403 ? 403 : 502, "team_create_failed", `Stack refused the team (${r.code})`)
    }
    // The caller's cached memberships predate the new team.
    teamsCache.delete(`${caller.projectId}\u0000${caller.userId}`)
    return json({ team: { id: r.id, name: r.name } })
  }

  const team = path.match(/^\/v1\/teams\/([^/]+)\/(macs|prefs|invites|signal|hub)$/)
  if (!team) return fail(404, "not_found", "no such route")
  const teamId = pathSegment(team[1]!)
  const action = team[2]!

  if (action === "signal" && method === "GET") {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    await requireMember(env, teamId, caller)
    retireTeamHub(env, ctx, caller, teamId, [deviceId])
    // Echo only cmux-mobile.v1; the bearer subprotocol is never selected (it would echo the token back).
    const subprotocol = bearer?.viaSubprotocol || (req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === "cmux-mobile.v1")
    const hub = userHub(env, caller)
    // Fast path: the caller's hub knows the devices registered to the caller, so no database round trip.
    const claim = { userId: caller.userId, projectId: caller.projectId, deviceId, ownerKey: me, teamId, space }
    // Where the phone entered Cloudflare (its link_stat log lines, PROTOCOL.md "Link stats"); no address.
    const ingress = JSON.stringify(ingressOf(req))
    const fast = new Headers({ upgrade: "websocket", "x-cmux-mobile-claim": JSON.stringify(claim), "x-cmux-mobile-ingress": ingress })
    if (subprotocol) fast.set("x-cmux-mobile-subprotocol", "cmux-mobile.v1")
    const res = await t.span("hub", hub.fetch("https://team-hub/signal", { headers: fast }))
    if (res.status === 101) return res
    if (res.status === 403) throw new HttpError(403, "not_owner", "register this device first")
    if (res.status !== 409) throw new HttpError(502, "hub_unavailable", "signaling is unavailable")
    // The hub has not seen this device, or has no Macs from the database yet (a new hub): check the database.
    // A 409 can also mean the device moved team since the hub saw it: the database decides.
    const [device, macs] = await withStore(env, ctx, (s) => Promise.all([s.getDevice(space, deviceId), s.listOwnerMacs(space, me)]))
    if (!device || device.ownerUserId !== me) throw new HttpError(403, "not_owner", "register this device first")
    if (device.teamId !== teamId) throw new HttpError(403, "wrong_team", "device is registered in another team")
    await t.span("hub", hub.seed(who, { userId: caller.userId, projectId: caller.projectId }, macs.map((m) => ({ deviceId: m.deviceId, name: m.name, teamId: m.teamId, lastSeenAt: m.lastSeenAt, machineId: m.machineId }))))
    const att: Attachment = { userId: caller.userId, projectId: caller.projectId, deviceId, kind: device.kind, name: device.name, teamId }
    const headers = new Headers({ upgrade: "websocket", "x-cmux-mobile-attachment": JSON.stringify(att), "x-cmux-mobile-owner-key": me, "x-cmux-mobile-space": space, "x-cmux-mobile-ingress": ingress })
    if (subprotocol) headers.set("x-cmux-mobile-subprotocol", "cmux-mobile.v1")
    return t.span("hub", hub.fetch("https://team-hub/signal", { headers }))
  }

  if (action === "hub" && method === "GET") {
    // Diagnostics (PROTOCOL.md): where this request entered Cloudflare and where the caller's hub runs.
    await requireMember(env, teamId, caller)
    const placed = await userHub(env, caller).placement(who)
    return json({ ingressColo: colo(req), hubColo: placed.colo, locationHint: caller.hint ?? null })
  }

  if (action === "macs" && method === "GET") {
    await requireMember(env, teamId, caller)
    // Only the caller's own Macs in this team (PROTOCOL.md): a teammate's Macs are never listed.
    const [rows, live] = await Promise.all([withStore(env, ctx, (s) => s.listOwnerMacs(space, me)), t.span("hub", userHub(env, caller).macs(who, teamId))])
    retireTeamHub(env, ctx, caller, teamId, rows.filter((d) => d.teamId === teamId).map((d) => d.deviceId))
    const byId = new Map(live.map((m) => [m.deviceId, m]))
    return json({
      macs: rows.flatMap((d) => {
        if (d.teamId !== teamId || d.ownerUserId !== me) return []
        const p = byId.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: caller.userId, ...machineOf(d), ...quietOf(p) }]
      })
    })
  }

  if (action === "prefs" && method === "GET") {
    await requireMember(env, teamId, caller)
    return json(await withStore(env, ctx, (s) => s.getPrefs(space, me, teamId)))
  }

  if (action === "prefs" && method === "PUT") {
    const b = await readJson(req)
    const patch: Partial<Prefs> = {}
    if (b.color !== undefined) {
      if (b.color !== null && (typeof b.color !== "string" || !COLOR.test(b.color))) throw new HttpError(400, "bad_request", "color must be #RRGGBB")
      patch.color = b.color === null ? null : (b.color as string).toUpperCase()
    }
    if (b.emoji !== undefined) {
      // null = automatic (first letter), "" = none (color only), else one grapheme.
      if (b.emoji !== null && (typeof b.emoji !== "string" || (b.emoji !== "" && ([...new Intl.Segmenter().segment(b.emoji)].length !== 1 || b.emoji.length > 32 || !b.emoji.trim()))))
        throw new HttpError(400, "bad_request", "emoji must be one grapheme, empty, or null")
      patch.emoji = b.emoji as string | null
    }
    if (b.transparent !== undefined) {
      if (typeof b.transparent !== "boolean") throw new HttpError(400, "bad_request", "transparent must be a boolean")
      patch.transparent = b.transparent
    }
    await requireMember(env, teamId, caller)
    const owner = ownerKey(env, caller)
    return json(
      await withStore(env, ctx, async (s) => {
        const next = mergePrefs(await s.getPrefs(space, owner, teamId), patch)
        // Transparent only with an icon: the team must keep an icon or a color.
        if (patch.transparent && !next.transparent) throw new HttpError(400, "bad_request", "transparent needs an icon (a one-grapheme emoji)")
        // Writes only the requested fields, plus the flag when this PUT decides it (sets it, picks a color, or
        // removes the icon, so a later icon never brings it back), so a concurrent PUT of other fields keeps its edit.
        const decides = patch.transparent !== undefined || patch.color !== undefined || (patch.emoji !== undefined && !hasIcon(patch.emoji))
        return s.putPrefs(space, owner, teamId, decides ? { ...patch, transparent: next.transparent } : patch)
      })
    )
  }

  if (action === "invites" && method === "POST") {
    const b = await readJson(req)
    if (typeof b.email !== "string" || !EMAIL.test(b.email)) throw new HttpError(400, "bad_request", "email is required")
    await limit(env.INVITE_LIMIT, me, "invitations")
    await requireMember(env, teamId, caller)
    if (teamId.startsWith(PERSONAL)) throw new HttpError(400, "bad_request", "personal space has no members")
    const r = await sendTeamInvite(env, caller, teamId, b.email)
    if (!r.ok) return fail(r.status === 401 || r.status === 403 ? 403 : 502, "invite_failed", `Stack refused the invitation (${r.code})`)
    return json({ url: r.url, sent: true })
  }

  return fail(405, "method_not_allowed", "method not allowed")
}

export default {
  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    await retireAllTeamHubs(env).catch((e) => console.log(JSON.stringify({ msg: "team hub sweep failed", error: String(e) })))
  },
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const t = timingFor(ctx)
    let res: Response
    try {
      res = await routes(req, env, ctx)
    } catch (e) {
      if (e instanceof HttpError) res = fail(e.status, e.code, e.message)
      else {
        console.log(JSON.stringify({ msg: "unhandled", error: String(e) }))
        res = fail(500, "internal", "internal error")
      }
    }
    const route = new URL(req.url).pathname.replace(/[0-9a-f-]{36}|personal-[0-9a-f-]+|teams\/[^/]+/g, (m) => (m.startsWith("teams/") ? "teams/:id" : ":id"))
    if (t.totalMs > 250) console.log(JSON.stringify({ msg: "timing", route, status: res.status, colo: colo(req), ...t.record() }))
    // Server-Timing on every response; a WebSocket upgrade's headers are rebuilt around its socket.
    if (res.status === 101 && res.webSocket) {
      const headers = new Headers(res.headers)
      headers.set("server-timing", t.header())
      return new Response(null, { status: 101, webSocket: res.webSocket, headers })
    }
    try {
      res.headers.set("server-timing", t.header())
      return res
    } catch {
      const headers = new Headers(res.headers)
      headers.set("server-timing", t.header())
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers })
    }
  }
} satisfies ExportedHandler<Env>
