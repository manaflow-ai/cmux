import { authenticate, bearerOf, primaryProject, stackProjects, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { iceServers } from "./ice.ts"
import { createTeam, sendTeamInvite, userTeams } from "./stack.ts"
import { apnsConfig, apnsTopics, clean, isSealedText, MAX_MAILBOX_SEALED, notifyLimitKey, parseNotify, pushTargets, sendApns, TURN_PUSH_WINDOW_MS, turnPushKey, wantedKinds } from "./push.ts"
import { hasIcon, mergePrefs, openStore, PUSH_KINDS, type Device, type Prefs, type PushKind, type Store } from "./store.ts"
import { userHubName, type Attachment } from "./team-hub.ts"
import { Timing, timingFor } from "./timing.ts"
import { WorkerEntrypoint } from "cloudflare:workers"

export { TeamHub } from "./team-hub.ts"

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
      const targets = (await store.listOwnerPush(owner)).filter((target) => target.kinds.includes(wanted as PushKind))
      if (targets.length === 0) return { accepted: true, correlation_id: `no-targets:${event.event_id}` }
      const { sendCloudAttention } = await import("./push.ts")
      const results = await sendCloudAttention(config, targets, event, Date.now())
      const dropped = results.filter((r) => r.outcome === "drop_target").map((r) => r.token)
      if (dropped.length) await store.dropPushTokens(dropped)
      const sent = results.find((r) => r.outcome === "sent" && r.status === 200 && !!r.apns_id)
      return { accepted: !!sent, ...(sent ? { correlation_id: `apns:${sent.apns_id}` } : {}) }
    } finally {
      await store.close().catch(() => {})
    }
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
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

/**
 * Per-project namespacing. The primary project keeps its bare names (existing hubs and rows stay where
 * they are); every other project's hubs and prefs rows are prefixed with its project id, so a team id or
 * personal space id that appeared in two projects would still be two separate spaces.
 */
const scoped = (env: Env, caller: Caller, key: string) => (caller.projectId === primaryProject(env).id ? key : `${caller.projectId}:${key}`)
/**
 * Where a new TeamHub should live: the region of the caller's own location (Cloudflare's geolocation of the
 * client), not of the colo that received the request. A Durable Object stays where it is first created, and
 * free-plan traffic is sometimes received far away (a California client was served from Paris on 2026-10-13),
 * so creating hubs next to the ingress colo stranded them across an ocean. Only affects a hub's creation.
 */
export const locationHintFor = (cf: { continent?: unknown; longitude?: unknown; country?: unknown } | undefined): DurableObjectLocationHint | undefined => {
  if (!cf || typeof cf.continent !== "string") return undefined
  const lon = typeof cf.longitude === "string" ? Number.parseFloat(cf.longitude) : typeof cf.longitude === "number" ? cf.longitude : Number.NaN
  switch (cf.continent) {
    case "NA":
      return Number.isFinite(lon) && lon < -100 ? "wnam" : "enam"
    case "SA":
      return "sam"
    case "EU":
      return Number.isFinite(lon) && lon > 20 ? "eeur" : "weur"
    case "AF":
      return "afr"
    case "OC":
      return "oc"
    case "AS":
      return ["AE", "BH", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "QA", "SA", "SY", "YE"].includes(String(cf.country)) ? "me" : "apac"
    default:
      return undefined
  }
}

/** The caller's identity plus where a hub created by this request should live. */
type Ctx = Caller & { readonly hint?: DurableObjectLocationHint; readonly t: Timing }
/**
 * The caller's own hub (PROTOCOL.md "Signaling WebSocket"): one per user, named by the owner key derived from
 * the verified token, never from a path or body value. Every hub call passes that key again, and the hub
 * refuses one that is not its owner's.
 */
const userHub = (env: Env, caller: Ctx) =>
  env.TEAM_HUB.get(env.TEAM_HUB.idFromName(userHubName(ownerKey(env, caller))), caller.hint ? { locationHint: caller.hint } : undefined)
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
    ok = await caller.t.span("member", userHub(env, caller).isMember(teamId, { userId: caller.userId, projectId: caller.projectId, token: caller.token }, ownerKey(env, caller)))
  } catch (e) {
    console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
    throw new HttpError(502, "membership_unavailable", "could not check team membership")
  }
  if (!ok) throw new HttpError(403, "not_member", "not a member of this team")
}

const withStore = async <T>(env: Env, ctx: ExecutionContext, f: (s: Store) => Promise<T>): Promise<T> => {
  const t = timingFor(ctx)
  const store = await t.span("db_connect", openStore(env))
  try {
    return await t.span("db", f(store))
  } finally {
    ctx.waitUntil(store.close().catch(() => {}))
  }
}

/** The PROTOCOL.md device object: `ownerUserId` is the bare sub (the project is recorded, not returned). */
const publicDevice = (env: Env, { machineId, ...d }: Device) => ({
  ...d,
  ownerUserId: splitOwner(env, d.ownerUserId).userId,
  ...machineOf({ machineId })
})

const colo = (req: Request): string | null => {
  const c = (req as Request & { cf?: { colo?: unknown } }).cf?.colo
  return typeof c === "string" ? c : null
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

let iceCache: { at: number; ttl: number; value: Promise<Awaited<ReturnType<typeof iceServers>>> } | undefined
const cachedIceServers = (env: Env): Promise<Awaited<ReturnType<typeof iceServers>>> => {
  const now = Date.now()
  if (iceCache && now - iceCache.at < (iceCache.ttl * 1000) / 10) return iceCache.value
  const value = iceServers(env)
  const entry = { at: now, ttl: 300, value }
  iceCache = entry
  value.then(
    (v) => {
      // Only a TURN answer is worth keeping; STUN-only means TURN failed, so ask again next time.
      if (v.turn) entry.ttl = v.ttl
      else if (iceCache === entry) iceCache = undefined
    },
    () => {
      if (iceCache === entry) iceCache = undefined
    }
  )
  return value
}

const routes = async (req: Request, env: Env, ctx: ExecutionContext): Promise<Response> => {
  const url = new URL(req.url)
  const path = url.pathname.replace(/\/+$/, "") || "/"
  const method = req.method

  if (path === "/v1/health" && method === "GET")
    return json({ ok: true, version: env.API_VERSION, stackProjects: stackProjects(env).map((p) => p.id), colo: colo(req) })

  const bearer = bearerOf(req)
  if (!bearer) return fail(401, "unauthorized", "missing or invalid Stack access token")
  const t = timingFor(ctx)
  const auth = await t.span("auth", authenticate(env, bearer.token))
  // The reason (expired, restricted, unknown_key, ...) names why without echoing the token.
  if (!("caller" in auth)) return fail(401, "unauthorized", `missing or invalid Stack access token (${auth.rejection})`)
  const caller: Ctx = { ...auth.caller, t, hint: locationHintFor((req as { cf?: { continent?: unknown; longitude?: unknown; country?: unknown } }).cf) }
  const me = ownerKey(env, caller)
  await t.span("limit", limit(env.USER_LIMIT, me, "requests"))

  if (path === "/v1/ice" && method === "GET") {
    await limit(env.ICE_LIMIT, me, "ICE requests")
    const { iceServers: list, ttl, turn } = await t.span("turn", cachedIceServers(env))
    return json({ iceServers: list, ttl, turn })
  }

  if (path === "/v1/me/bootstrap" && method === "POST") {
    // The phone's launch in one round trip (PROTOCOL.md): register its devices in `teamId`, and return
    // that team's Macs, the caller's own Macs everywhere, and ICE servers. Each part runs the same route
    // as its own call, all at once; a part that fails carries its error instead of failing the rest.
    const b = await readJson(req)
    if (typeof b.teamId !== "string") throw new HttpError(400, "bad_request", "teamId is required")
    const list = Array.isArray(b.devices) ? (b.devices as Array<Record<string, unknown>>).slice(0, 4) : []
    const headers = { authorization: req.headers.get("authorization") ?? `Bearer ${bearer.token}`, "content-type": "application/json" }
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

  if (path === "/v1/me/devices" && method === "GET") {
    const [rows, presence] = await Promise.all([withStore(env, ctx, (s) => s.listOwnerDevices(me)), t.span("hub", userHub(env, caller).macs(me))])
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
    // Account deletion (PROTOCOL.md): purge everything stored for the caller and evict their sockets.
    const gone = await withStore(env, ctx, (s) => s.deleteOwner(me))
    await userHub(env, caller).purge(me)
    console.log(JSON.stringify({ msg: "account data deleted", devices: gone.length }))
    return json({ deleted: { devices: gone.length } })
  }

  const dev = path.match(/^\/v1\/devices\/([^/]+)(?:\/(push|notify|mailbox)(?:\/([^/]+))?)?$/)
  if (dev) {
    const deviceId = decodeURIComponent(dev[1]!).toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    const sub = dev[2]
    const itemId = dev[3] === undefined ? undefined : decodeURIComponent(dev[3]).toLowerCase()
    if (itemId !== undefined && sub !== "mailbox") return fail(404, "not_found", "not found")
    if (sub === "mailbox") {
      // PROTOCOL.md "Reply mailbox": a phone's sealed reply for its own Mac. The Worker never opens it.
      const mac = await withStore(env, ctx, (s) => s.getDevice(deviceId))
      if (!mac) throw new HttpError(404, "not_found", "no such device")
      if (mac.ownerUserId !== me || mac.kind !== "mac") throw new HttpError(403, "not_owner", "replies go to your own Mac")
      if (itemId !== undefined && method === "GET") {
        if (!UUID.test(itemId)) throw new HttpError(400, "bad_request", "the item id must be a UUID")
        const state = await userHub(env, caller).mailboxState(me, deviceId, itemId)
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
      const phone = await withStore(env, ctx, (s) => s.getDevice(from))
      if (!phone || phone.ownerUserId !== me || phone.kind !== "phone") throw new HttpError(403, "not_owner", "replies come from your own phone")
      await limit(env.MAILBOX_LIMIT, me, "replies")
      const r = await userHub(env, caller).mailboxPost(me, { id, mac: deviceId, from, sealed: b.sealed })
      if ("error" in r) {
        if (r.error === "full") throw new HttpError(429, "rate_limited", "this Mac has too many replies waiting; try again later")
        throw new HttpError(409, "conflict", "another reply already has this id")
      }
      return json(r)
    }
    if (!sub && method === "DELETE") {
      const r = await withStore(env, ctx, (s) => s.deleteDevice(deviceId, me))
      if (r === "not_owner") throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (!r) throw new HttpError(404, "not_found", "no such device")
      await userHub(env, caller).forgetDevice(me, deviceId)
      return json({ deleted: true, deviceId })
    }
    if (sub === "push" && (method === "PUT" || method === "DELETE")) {
      const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me) throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (method === "DELETE") {
        await withStore(env, ctx, (s) => s.deletePush(deviceId))
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
        s.setPush({ deviceId, ownerUserId: me, token, environment: b.environment as "sandbox" | "production", topic: b.topic as string, kinds, mutedMacs, previews })
      )
      return json({ push: { environment: r.environment, topic: r.topic, kinds: r.kinds, mutedMacs: r.mutedMacs, previews: r.previews, updatedAt: r.updatedAt } })
    }
    if (sub === "notify" && method === "POST") {
      const parsed = parseNotify(await readJson(req))
      if (typeof parsed === "string") throw new HttpError(400, "bad_request", parsed)
      const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me || device.kind !== "mac") throw new HttpError(403, "not_owner", "notify from your own Mac")
      await limit(env.NOTIFY_LIMIT, notifyLimitKey(deviceId, parsed.kind), "notifications")
      const config = apnsConfig(env)
      const kind = parsed.kind
      const regs = await withStore(env, ctx, (s) => s.listOwnerPush(me))
      // The kinds some phone that has not muted this Mac wants: the Mac skips the rest (terminal, say).
      const wants = wantedKinds(regs, deviceId)
      const targets = config ? pushTargets(regs, deviceId, kind).slice(0, 20) : []
      if (!config || targets.length === 0) return json({ configured: !!config, sent: 0, failed: 0, dropped: 0, wants })
      // A burst of turn ends from one session is one notification (a Mac on an older host sends every one).
      // Checked only once some phone wants this kind, so an unwanted kind never uses up the window.
      const key = turnPushKey(deviceId, parsed)
      if (key && !(await userHub(env, caller).turnPushAllowed(me, key, TURN_PUSH_WINDOW_MS)))
        return json({ configured: true, sent: 0, failed: 0, dropped: 0, coalesced: true, wants })
      const results = await sendApns(config, targets, { ...parsed, macId: deviceId, macName: clean(device.name, 40) }, Date.now())
      const drop = results.filter((r) => r.outcome === "drop_target").map((r) => r.token)
      if (drop.length) await withStore(env, ctx, (s) => s.dropPushTokens(drop))
      const failed = results.filter((r) => r.outcome === "failed")
      if (failed.length) console.log(JSON.stringify({ msg: "apns failed", results: failed.map((r) => ({ status: r.status, reason: r.reason })) }))
      return json({ configured: true, sent: results.filter((r) => r.outcome === "sent").length, failed: failed.length, dropped: drop.length, wants })
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
        ownerUserId: owner,
        teamId,
        kind,
        name: name.trim(),
        wgPublicKey: (wgPublicKey as string | null | undefined) ?? null,
        ...(machineId === undefined ? {} : { machineId: machineId as string })
      })
      if (up === "not_owner") return up
      // Other builds on this Mac (a deleted build's record that will never register again): this Mac's machine
      // id, only for the caller's own Macs that have none. Never another owner's device, never a phone.
      const claimed = typeof machineId === "string" && siblings.length ? await s.claimSiblings(owner, machineId, siblings) : []
      return { ...up, claimed }
    })
    if (r === "not_owner") throw new HttpError(403, "not_owner", "this deviceId belongs to another user")
    // The caller's hub notes the device (and its team; a team move closes its socket with 4001 `moved`).
    await t.span(
      "hub",
      userHub(env, caller).register({
        deviceId: r.device.deviceId,
        ownerKey: r.device.ownerUserId,
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
    const rows = await withStore(env, ctx, (s) => s.listOwnerMacs(ownerKey(env, caller)))
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
    const presence = new Map((await t.span("hub", userHub(env, caller).macs(me))).map((m) => [m.deviceId, m]))
    return json({
      macs: rows.flatMap((d) => {
        if (!reachable.has(d.teamId)) return []
        const p = presence.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, teamId: d.teamId, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: caller.userId, ...machineOf(d) }]
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
  const teamId = decodeURIComponent(team[1]!)
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
    const claim = { userId: caller.userId, projectId: caller.projectId, deviceId, ownerKey: me, teamId }
    const fast = new Headers({ upgrade: "websocket", "x-cmux-mobile-claim": JSON.stringify(claim) })
    if (subprotocol) fast.set("x-cmux-mobile-subprotocol", "cmux-mobile.v1")
    const res = await t.span("hub", hub.fetch("https://team-hub/signal", { headers: fast }))
    if (res.status === 101) return res
    if (res.status === 403) throw new HttpError(403, "not_owner", "register this device first")
    if (res.status !== 409) throw new HttpError(502, "hub_unavailable", "signaling is unavailable")
    // The hub has not seen this device, or has no Macs from the database yet (a new hub): check the database.
    // A 409 can also mean the device moved team since the hub saw it: the database decides.
    const [device, macs] = await withStore(env, ctx, (s) => Promise.all([s.getDevice(deviceId), s.listOwnerMacs(me)]))
    if (!device || device.ownerUserId !== me) throw new HttpError(403, "not_owner", "register this device first")
    if (device.teamId !== teamId) throw new HttpError(403, "wrong_team", "device is registered in another team")
    await t.span("hub", hub.seed(me, { userId: caller.userId, projectId: caller.projectId }, macs.map((m) => ({ deviceId: m.deviceId, name: m.name, teamId: m.teamId, lastSeenAt: m.lastSeenAt, machineId: m.machineId }))))
    const att: Attachment = { userId: caller.userId, projectId: caller.projectId, deviceId, kind: device.kind, name: device.name, teamId }
    const headers = new Headers({ upgrade: "websocket", "x-cmux-mobile-attachment": JSON.stringify(att), "x-cmux-mobile-owner-key": me })
    if (subprotocol) headers.set("x-cmux-mobile-subprotocol", "cmux-mobile.v1")
    return t.span("hub", hub.fetch("https://team-hub/signal", { headers }))
  }

  if (action === "hub" && method === "GET") {
    // Diagnostics (PROTOCOL.md): where this request entered Cloudflare and where the caller's hub runs.
    await requireMember(env, teamId, caller)
    const placed = await userHub(env, caller).placement(me)
    return json({ ingressColo: colo(req), hubColo: placed.colo, locationHint: caller.hint ?? null })
  }

  if (action === "macs" && method === "GET") {
    await requireMember(env, teamId, caller)
    // Only the caller's own Macs in this team (PROTOCOL.md): a teammate's Macs are never listed.
    const [rows, live] = await Promise.all([withStore(env, ctx, (s) => s.listOwnerMacs(me)), t.span("hub", userHub(env, caller).macs(me, teamId))])
    retireTeamHub(env, ctx, caller, teamId, rows.filter((d) => d.teamId === teamId).map((d) => d.deviceId))
    const byId = new Map(live.map((m) => [m.deviceId, m]))
    return json({
      macs: rows.flatMap((d) => {
        if (d.teamId !== teamId || d.ownerUserId !== me) return []
        const p = byId.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: caller.userId, ...machineOf(d) }]
      })
    })
  }

  if (action === "prefs" && method === "GET") {
    await requireMember(env, teamId, caller)
    return json(await withStore(env, ctx, (s) => s.getPrefs(ownerKey(env, caller), teamId)))
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
        const next = mergePrefs(await s.getPrefs(owner, teamId), patch)
        // Transparent only with an icon: the team must keep an icon or a color.
        if (patch.transparent && !next.transparent) throw new HttpError(400, "bad_request", "transparent needs an icon (a one-grapheme emoji)")
        // Writes only the requested fields, plus the flag when this PUT decides it (sets it, picks a color, or
        // removes the icon, so a later icon never brings it back), so a concurrent PUT of other fields keeps its edit.
        const decides = patch.transparent !== undefined || patch.color !== undefined || (patch.emoji !== undefined && !hasIcon(patch.emoji))
        return s.putPrefs(owner, teamId, decides ? { ...patch, transparent: next.transparent } : patch)
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
