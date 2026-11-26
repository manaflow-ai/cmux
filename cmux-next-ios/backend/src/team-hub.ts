import { DurableObject } from "cloudflare:workers"
import { primaryProject, type Caller } from "./auth.ts"
import type { CachedIce } from "./ice.ts"
import type { Env } from "./env.ts"
import { MAILBOX_HOLD_BYTES, MAILBOX_HOLD_LIMIT, MAILBOX_PAGE, MAILBOX_PENDING_LIMIT, MAILBOX_TTL_MS } from "./push.ts"
import { userTeams } from "./stack.ts"
import { locationHintOf, relayPlacement, relayRoomName } from "./placement.ts"
import { FIRST_GRANT, MIB, MibBucket, newTicket, RELAY_CLOSE, ticketsMatch, userMibPerMinute, type BudgetAnswer, type MibBucketState } from "./relay-access.ts"

/** Per-socket identity, set by the Worker after auth and device checks (never by the client). */
export interface Attachment {
  userId: string
  /** The Stack project of `userId`; identity is the pair. */
  projectId: string
  deviceId: string
  kind: "mac" | "phone"
  name: string
  /**
   * The team (or personal space) the socket was opened for: the team its device is registered in. It picks
   * which of the user's Macs this socket hears about (hello, presence); it never widens who can be reached.
   */
  teamId: string
  /** Set before the hub closes a socket that a newer connection of the same device replaced. */
  replaced?: boolean
  /** When the socket was accepted (ms): proof the device was awake then, before its first ping. */
  connectedAt?: number
  /** Where the socket's upgrade entered Cloudflare (set by the Worker from `req.cf`; link_stat log lines). */
  ingress?: Ingress
}

/** Cloudflare's codes for where a request entered: colo (`SJC`), country (`US`), continent (`NA`). */
export interface Ingress {
  colo: string | null
  country: string | null
  continent: string | null
  /** Cloudflare's geolocation of the client, rounded to 0.1 degree (about 11 km); relay placement only. */
  lat?: number | null
  lon?: number | null
  /** The client's own netcheck, round-trip ms per Durable Object region (`placement.ts` parseNetcheck). */
  rtt?: Partial<Record<string, number>>
}

/** The most a `link_stat` frame may be (PROTOCOL.md "Link stats"; the phone's are under 768 bytes). */
export const MAX_LINK_STAT_FRAME = 2048
/** A socket's stats closer together than this are dropped silently (the phone sends one a minute). */
export const LINK_STAT_MIN_GAP_MS = 5000
const LINK_STAT_TRANSPORTS = new Set(["wireguard", "webrtc"])
const LINK_STAT_PATHS = new Set(["direct", "turn", "turn-tls", "https-relay", "none"])
const LINK_STAT_REASONS = new Set(["first", "periodic", "path", "end"])
const LINK_STAT_ENDS = new Set(["app", "keepalive", "transport", "other"])
const LINK_STAT_NETS = new Set(["cellular", "other"])
// How the link left the device: through a proxy, or one that inspects TLS (absent: direct).
const LINK_STAT_EGRESS = new Set(["proxy", "inspected"])
/** Which protocol mapped the Mac's endpoint (PROTOCOL.md "Mapped endpoints"). */
const LINK_STAT_PORTMAP = new Set(["pcp", "nat-pmp", "upnp", "unknown"])
const LINK_STAT_MARKS = new Set([
  "signaling_open",
  "signaling_reused",
  "dial_start",
  "offer_sent",
  "answer_received",
  "wg_init_sent",
  "wg_resp_received",
  "endpoints_gathered",
  "ice_connected",
  "dtls_connected",
  "channel_open",
  "alive",
  "link_ready",
  "first_pong"
])
const LINK_STAT_MAX_MS = 600_000
/** The most slow keys a `link_stat` carries (`cmux-mobile-link` `key_echo::MAX_SPIKES`). */
const LINK_STAT_MAX_SPIKES = 6
const LIB_VERSION = /^[0-9A-Za-z.+-]{1,32}$/

/**
 * The one log line of a phone's `link_stat` frame (PROTOCOL.md "Link stats"), or null for a malformed frame.
 * Every field is checked against a fixed set or clamped, so the line has a bounded size and only fixed words
 * and numbers from the client; nothing names a user, device, session or address.
 */
export function linkStatLine(f: Record<string, unknown>, kind: Attachment["kind"], ingress: Ingress | undefined, hubColo: string | null): Record<string, unknown> | null {
  const word = (v: unknown, allowed: Set<string>) => (typeof v === "string" && allowed.has(v) ? v : undefined)
  const num = (v: unknown, max: number) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.min(Math.round(v), max) : undefined)
  if (f.v !== 1) return null
  const transport = word(f.transport, LINK_STAT_TRANSPORTS)
  const path = word(f.path, LINK_STAT_PATHS)
  const reason = word(f.reason, LINK_STAT_REASONS)
  const pings = num(f.pings, 100_000)
  const lost = num(f.lost, 100_000)
  if (!transport || !path || !reason || pings === undefined || lost === undefined) return null
  const line: Record<string, unknown> = { event: "link_stat", v: 1, kind, transport, path, reason, pings, lost }
  const setupMs = num(f.setupMs, LINK_STAT_MAX_MS)
  if (setupMs !== undefined) line.setupMs = setupMs
  if (typeof f.marks === "object" && f.marks !== null && !Array.isArray(f.marks)) {
    const marks: Record<string, number> = {}
    for (const [name, at] of Object.entries(f.marks as Record<string, unknown>)) {
      const ms = num(at, LINK_STAT_MAX_MS)
      if (LINK_STAT_MARKS.has(name) && ms !== undefined) marks[name] = ms
    }
    if (Object.keys(marks).length) line.marks = marks
  }
  if (typeof f.rtt === "object" && f.rtt !== null) {
    const r = f.rtt as Record<string, unknown>
    const n = num(r.n, 100_000)
    const p50 = num(r.p50, LINK_STAT_MAX_MS)
    const p95 = num(r.p95, LINK_STAT_MAX_MS)
    const max = num(r.max, LINK_STAT_MAX_MS)
    if (n && p50 !== undefined && p95 !== undefined && max !== undefined) Object.assign(line, { rttN: n, rttP50: p50, rttP95: p95, rttMax: max })
  }
  const switches = num(f.switches, 10_000)
  if (switches !== undefined) line.switches = switches
  const net = word(f.net, LINK_STAT_NETS)
  if (net) line.net = net
  const egress = word(f.egress, LINK_STAT_EGRESS)
  if (egress) line.egress = egress
  const upS = num(f.upS, 30 * 86_400)
  if (upS !== undefined) line.upS = upS
  const end = reason === "end" ? word(f.end, LINK_STAT_ENDS) : undefined
  if (end) line.end = end
  if (typeof f.lib === "string" && LIB_VERSION.test(f.lib)) line.lib = f.lib
  if (typeof f.portmap === "object" && f.portmap !== null) {
    const p = f.portmap as Record<string, unknown>
    const by = word(p.by, LINK_STAT_PORTMAP)
    if (by && typeof p.used === "boolean") Object.assign(line, { portmapBy: by, portmapUsed: p.used })
  }
  // Keystroke round trips (PROTOCOL.md "Link stats", `echo`, `ack`, `spikes`): flattened as `rtt` is.
  for (const [field, prefix] of [["echo", "echo"], ["ack", "ack"]] as const) {
    const k = f[field]
    if (typeof k !== "object" || k === null || Array.isArray(k)) continue
    const r = k as Record<string, unknown>
    const n = num(r.n, 100_000)
    const p50 = num(r.p50, LINK_STAT_MAX_MS)
    const p95 = num(r.p95, LINK_STAT_MAX_MS)
    const p99 = num(r.p99, LINK_STAT_MAX_MS)
    const max = num(r.max, LINK_STAT_MAX_MS)
    if (n && p50 !== undefined && p95 !== undefined && p99 !== undefined && max !== undefined) {
      Object.assign(line, { [`${prefix}N`]: n, [`${prefix}P50`]: p50, [`${prefix}P95`]: p95, [`${prefix}P99`]: p99, [`${prefix}Max`]: max })
    }
  }
  const spikeCount = num(f.spikeCount, 100_000)
  if (spikeCount) line.spikeCount = spikeCount
  if (Array.isArray(f.spikes)) {
    // [seconds since up, ack ms (-1: none yet), echo ms], at most LINK_STAT_MAX_SPIKES.
    const spikes: number[][] = []
    for (const s of f.spikes.slice(0, LINK_STAT_MAX_SPIKES)) {
      if (!Array.isArray(s) || s.length !== 3) continue
      const at = num(s[0], 30 * 86_400)
      const ack = s[1] === -1 ? -1 : num(s[1], LINK_STAT_MAX_MS)
      const echo = num(s[2], LINK_STAT_MAX_MS)
      if (at !== undefined && ack !== undefined && echo !== undefined) spikes.push([at, ack, echo])
    }
    if (spikes.length) line.spikes = spikes
  }
  Object.assign(line, { ingressColo: ingress?.colo ?? null, country: ingress?.country ?? null, continent: ingress?.continent ?? null, hubColo })
  return line
}

/**
 * The application ping a signaling client sends beside its WebSocket pings (PROTOCOL.md "Signaling
 * WebSocket"), answered by the runtime without waking the hub. Its time is how the hub knows a device is
 * awake: a Mac that sleeps keeps its socket half open (and so "online") but stops pinging.
 */
export const APP_PING = "ping"
export const APP_PONG = "pong"

/** Whether a Mac's signaling socket is open, and its last application ping that can speak for a moment. */
export interface MacLiveness {
  readonly connected: boolean
  /**
   * The last application ping (ms) of the socket that was open at the asked moment: the current socket when
   * it connected before that moment, else the last ping recorded when an earlier socket closed or was
   * replaced (a Mac that wakes from sleep reconnects, and its new pings say nothing about the sleep). Null
   * when that socket never pinged.
   */
  readonly lastPingAt: number | null
  /** Whether this Mac's host sends application pings at all (one that predates them never does). */
  readonly pings: boolean
  /** When the Mac's current signaling socket connected (ms), if connected: a host that restarted reconnects. */
  readonly connectedAt?: number | null
  /** The Mac's last signaling connects (ms, oldest first, at most 8): restarts inside a window, judged late. */
  readonly connects?: ReadonlyArray<number>
}

/** A sealed reply for a Mac (PROTOCOL.md "Reply mailbox"): the hub never holds a key that opens it. */
export interface MailboxItem {
  id: string
  mac: string
  from: string
  sealed: string
}

/** `seq` and `expiresAt` (ms) since API 0.18.0 ("Store and forward"): a phone that gets no `seq` talks to an older hub. */
export type MailboxPost = { queued: true; delivered: boolean; seq: number; expiresAt: number } | { error: "conflict" | "full" }
type MailboxWhen = { seq?: number; expiresAt?: number }
/** `sig`: the Mac's identity signature over the outcome (PROTOCOL.md), which the phone checks; absent from an older Mac. */
export type MailboxState =
  | ({ state: "queued" | "expired" } & MailboxWhen)
  | ({ state: "applied"; sig?: string } & MailboxWhen)
  | ({ state: "rejected"; reason: string; sig?: string } & MailboxWhen)

const MAX_ACK_RESULTS = 64
const ACK_REASON = /^[a-z_]{1,32}$/
const ACK_SIG = /^[0-9a-f]{128}$/

export interface MacPresence {
  deviceId: string
  name: string
  teamId: string
  online: boolean
  lastSeenAt: string | null
  ownerUserId: string
  /** Which computer the Mac runs on (PROTOCOL.md "Devices"); null when it never said. */
  machineId: string | null
  /**
   * How long ago (ms) the hub last heard the Mac's open socket: its connect or its last application ping
   * (PROTOCOL.md "Mac freshness"). Only while `online`. A Mac that pings every 15 s is under FRESH_MS; a
   * Mac that slept keeps its socket half open, so it stays `online` while this grows.
   */
  quietMs?: number
}

/**
 * A Mac heard within this is awake (PROTOCOL.md "Mac freshness"): one 15 s ping interval plus room for a slow
 * round trip, as the link's own FRESH_WITHIN (cmux-mobile-link `signaling.rs`). The phone decides; the hub
 * only reports `quietMs`.
 */
export const FRESH_MS = 18_000

/**
 * A Mac's socket the hub has not heard for this long is gone (cmux#52200): its network was cut or it slept, and
 * no close reached the hub (a silent drop leaves the socket half open forever). Six missed 15 s pings, and past
 * the Mac's own 40 s give-up (`KEEPALIVE_TIMEOUT` in cmux-mobile-link `signaling.rs`), so a Mac that is alive but
 * overloaded still reads "not responding" (`quietMs`) first. The hub closes the socket and phones hear the Mac
 * offline, last seen when it was last heard.
 */
export const GONE_MS = 90_000

/** A device registration as the Worker hands it to the hub (POST /v1/devices). */
export interface HubDevice {
  deviceId: string
  /** The owner key of src/index.ts (`<sub>` or `<projectId>:<sub>`): must be this hub's owner. */
  ownerKey: string
  /** The build space of the registration ("" for stable): must be this hub's space. */
  space?: string
  kind: "mac" | "phone"
  name: string
  teamId: string
  userId: string
  projectId: string
  /** The Mac's machine id after the registration (null: none). */
  machineId?: string | null
  /** Other builds on the same Mac that have its machine id in the database (claimed now or earlier). */
  claimed?: ReadonlyArray<string>
}

/** A Mac from the database, to seed a new hub's presence list (offline until it connects). */
export interface SeedMac {
  deviceId: string
  name: string
  teamId: string
  lastSeenAt: string | null
  machineId?: string | null
}

// `wg-relay` (0.17.0): a side joined the session's WebSocket relay and asks its peer to join too (PROTOCOL.md
// "WebSocket relay"); forwarded like any signal of the session, and carrying nothing else.
const SIGNAL_KINDS = new Set(["webrtc-offer", "webrtc-answer", "webrtc-ice", "wg-init", "wg-resp", "wg-endpoints", "wg-relay", "bye"])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MEMBER_TTL_MS = 60_000
const NON_MEMBER_TTL_MS = 15_000
const SESSION_TTL_MS = 24 * 3600_000
const MAX_TEXT_FRAME = 64 * 1024
/**
 * The WireGuard relay frames (`[16 sessionId][16 to][datagram]`) are retired (PROTOCOL.md): WireGuard without a
 * UDP path uses TURN over TLS. An older client still sends them until its route is confirmed; each is dropped,
 * and its sender hears `relay_retired` at most once per socket and session in this interval. The error always
 * names the frame's session: a sessionless error would fail every dial that client has in progress.
 */
export const RELAY_ERROR_INTERVAL_MS = 5000

/** At most this many prewarmed session ids are remembered per hub instance; past it the set starts over. */
const PREWARMED_MAX = 1024

/**
 * Token buckets per socket, in memory only: text (signaling), and binary (an older client's retired relay
 * frames), which bounds how often a flood of them costs a refusal check; excess frames are dropped silently.
 */
export const BUCKETS = { text: { rate: 20, burst: 60 }, binary: { rate: 12000, burst: 24000 } } as const

/**
 * The Durable Object name of a user's hub: `user:` and the owner key (src/index.ts), never a client value. In a
 * dev build space (src/index.ts `spaceOf`) the space comes first, `dev:<slug>|user:<owner key>`, so each dev
 * build gets its own hub; stable and nightly (space "") keep the names their hubs always had. A space never
 * contains `|` and an owner key never starts with `dev:`, so two (space, owner) pairs never share a name.
 */
export const userHubName = (ownerKey: string, space = "") => (space ? `${space}|user:${ownerKey}` : `user:${ownerKey}`)

/**
 * Who a hub call is for: the owner key and the build space. A bare string is the owner key in the stable
 * space (""), the only form before build spaces. The hub accepts it only when (space, owner) names this very
 * object, so a call that leaves out a dev space is refused by a dev hub rather than served there.
 */
export type HubOwner = string | { readonly ownerKey: string; readonly space: string }
const ownerOf = (o: HubOwner): { ownerKey: string; space: string } => (typeof o === "string" ? { ownerKey: o, space: "" } : o)

/** A signaling session: its two devices, and each one's relay ticket (null for a session opened before tickets). */
interface SessionRow {
  initiator: string
  responder: string
  initiatorTicket: string | null
  responderTicket: string | null
  /** When the session's first signal was admitted (ms): a session lives `SESSION_TTL_MS`. */
  createdAt: number
}

/** Thrown when a call names a device of another owner than the hub's: a Worker bug, never served. */
export class WrongHubError extends Error {}

export const uuidToBytes = (id: string): Uint8Array => {
  const hex = id.replace(/-/g, "")
  const out = new Uint8Array(16)
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

export const bytesToUuid = (b: Uint8Array): string => {
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/**
 * One per user and build space (idFromName(userHubName(ownerKey, space)), PROTOCOL.md "Signaling WebSocket" and
 * "Build spaces"): signaling (introductions, `wg-endpoints`) and Mac presence among one user's own devices of
 * one build, on hibernating WebSockets.
 * The class keeps its old name so no Durable Object migration is needed; only the name it is reached by
 * changed (it was the team id). A hub only ever holds the devices of its owner: the first call binds the
 * owner key in storage and every later call naming another owner throws `WrongHubError`, so a routing bug
 * cannot mix two users' devices. SQLite holds Mac presence rows, registered devices and link sessions so a
 * hibernation wake keeps the admission state; the membership cache and rate buckets are memory only.
 */
export class TeamHub extends DurableObject<Env> {
  private readonly sql: SqlStorage
  private readonly members = new Map<string, { ok: boolean; at: number }>()
  private readonly buckets = new WeakMap<WebSocket, { text: { t: number; at: number }; binary: { t: number; at: number } }>()
  private readonly sessions = new Map<string, SessionRow>()
  /** The owner's relay budget (`relayBudget`), loaded from storage after a wake, so a wake grants no fresh minute. */
  private relayBucket: MibBucket | undefined
  /** Budget requests this instance answered (`relayBudgetCalls`: tests and diagnostics). */
  private relayBudgetAsked = 0
  /** Deserialized attachments: read on every frame, and deserializing each time is the costly part. */
  private readonly attachments = new WeakMap<WebSocket, Attachment>()
  private colo: string | null | undefined
  private readonly relayErrors = new WeakMap<WebSocket, Map<string, number>>()
  /** When each socket's last `link_stat` was logged (memory only; a wake forgets, which costs one extra line). */
  private readonly linkStats = new WeakMap<WebSocket, number>()
  /** The open socket of each device, so a signal needs no socket scan (rebuilt lazily after hibernation). */
  private readonly live = new Map<string, WebSocket>()
  /** Sessions whose relay this instance prewarmed (`prewarmRelay`), in memory only. */
  private readonly prewarmed = new Set<string>()
  private ownerKey: string | null | undefined

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.schema()
    // Answered by the runtime, without waking the hub; getWebSocketAutoResponseTimestamp records it.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(APP_PING, APP_PONG))
  }

  /** The tables (again after `retireTeamHub` deleted them: the constructor does not rerun while the object stays in memory). */
  private schema() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS macs (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_user_id TEXT NOT NULL, last_seen_at INTEGER)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, owner_key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, initiator TEXT NOT NULL, responder TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    // Columns added after the tables first shipped (a hub created by older code has the tables without them).
    const addColumn = (table: string, column: string, type: "TEXT" | "INTEGER" = "TEXT") => {
      if (!this.sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().some((c) => c.name === column)) this.sql.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`)
    }
    addColumn("macs", "owner_project_id")
    addColumn("macs", "team_id")
    addColumn("devices", "team_id")
    addColumn("macs", "machine_id")
    // The last application ping of a Mac's closed or replaced socket (connectivity alerts, `macLiveness`).
    addColumn("macs", "last_ping_at")
    // The Mac's last signaling connects, JSON ms (connectivity alerts: a host that restarted).
    addColumn("macs", "connects")
    // Devices deleted here, so a database read that raced the deletion cannot seed them back.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS forgotten (device_id TEXT PRIMARY KEY)`)
    // The last turn-ending push per Mac and session (`turnPushAllowed`); rows older than the window go.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS turn_pushes (key TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
    // Sealed replies for a Mac (`mailboxPost`): queued until the Mac acknowledges one or it expires; a settled
    // row keeps only its state (the blob is cleared) until `keep_until`, so the phone can read the outcome.
    this.sql.exec(
      `CREATE TABLE IF NOT EXISTS mailbox (id TEXT PRIMARY KEY, mac TEXT NOT NULL, from_device TEXT NOT NULL, sealed TEXT NOT NULL,
        at INTEGER NOT NULL, expires_at INTEGER NOT NULL, keep_until INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT)`
    )
    addColumn("mailbox", "sig")
    // Store and forward (PROTOCOL.md, API 0.18.0): the item's place in its (Mac, phone) order, and the Mac socket
    // (its `connectedAt`) it was last sent on, so a page goes once per socket. `mailbox_seq` keeps the last seq of a
    // pair after its items are gone, so a seq is never reused.
    addColumn("mailbox", "seq", "INTEGER")
    addColumn("mailbox", "sent_conn", "INTEGER")
    this.sql.exec(`CREATE TABLE IF NOT EXISTS mailbox_seq (mac TEXT NOT NULL, from_device TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (mac, from_device))`)
    // Each party's relay ticket (PROTOCOL.md "WebSocket relay"), made when the session opens.
    addColumn("sessions", "initiator_ticket")
    addColumn("sessions", "responder_ticket")
    // Sessions whose relay object has had a join: their live relay sockets close when the session ends.
    this.sql.exec(`CREATE TABLE IF NOT EXISTS relay_sessions (session_id TEXT PRIMARY KEY)`)
  }

  // ---- RPC from the Worker -------------------------------------------------------------------

  // Used only on the reserved TURN cache object. Out-of-order writes from
  // different Worker isolates must keep the newer mint.
  async readIce(): Promise<CachedIce | undefined> {
    const entry = await this.ctx.storage.get<CachedIce>("turn-credentials")
    return entry && Date.now() < entry.usableUntil ? entry : undefined
  }

  async writeIce(entry: CachedIce): Promise<void> {
    await this.ctx.storage.transaction(async (tx) => {
      const current = await tx.get<CachedIce>("turn-credentials")
      if (entry.usableUntil <= Date.now() || (current && current.issuedAt > entry.issuedAt)) return
      await tx.put("turn-credentials", entry)
      await tx.setAlarm(entry.usableUntil)
    })
  }

  async alarm(): Promise<void> {
    let iceUntil: number | undefined
    await this.ctx.storage.transaction(async (tx) => {
      const entry = await tx.get<CachedIce>("turn-credentials")
      if (!entry) return
      if (Date.now() < entry.usableUntil) iceUntil = entry.usableUntil
      else await tx.delete("turn-credentials")
    })
    const reapAt = this.reapSilentMacs(Date.now())
    const next = Math.min(iceUntil ?? Infinity, reapAt ?? Infinity)
    if (Number.isFinite(next)) await this.ctx.storage.setAlarm(next)
  }

  /**
   * Closes every Mac socket not heard for ``GONE_MS`` as gone (cmux#52200), and returns when the next open Mac
   * socket would be (undefined: none open). Only a socket of a host that pings: one that predates application
   * pings is never heard after its connect, and stays as before.
   */
  private reapSilentMacs(now: number): number | undefined {
    let next: number | undefined
    for (const ws of this.ctx.getWebSockets()) {
      const att = this.attach(ws)
      if (!att || att.kind !== "mac" || att.replaced || ws.readyState !== WebSocket.OPEN) continue
      const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime()
      const heard = Math.max(att.connectedAt ?? 0, pinged ?? 0)
      if (!heard) continue
      if (pinged === undefined && this.recordedPing(att.deviceId) === null) {
        // No ping yet, none on record: a new host before its first ping (15 s), or one that predates them. Look again
        // when it would be due, so an alarm that came first does not end the chain and leave it never reaped.
        if (now - heard < GONE_MS) next = Math.min(next ?? Infinity, heard + GONE_MS)
        continue
      }
      if (now - heard < GONE_MS) {
        next = Math.min(next ?? Infinity, heard + GONE_MS)
        continue
      }
      this.recordPing(ws, att.deviceId)
      // Marked replaced first, so its close event (if one ever comes) does not announce it a second time.
      this.setAttach(ws, { ...att, replaced: true })
      try {
        ws.close(4002, "silent")
      } catch {}
      if (this.live.get(att.deviceId) === ws) this.live.delete(att.deviceId)
      if (this.open(att.deviceId)) continue
      this.sql.exec(`UPDATE macs SET last_seen_at = ? WHERE device_id = ?`, heard, att.deviceId)
      const mac = this.macRow(att.deviceId)
      console.log(JSON.stringify({ event: "mac_silent_closed", deviceId: att.deviceId, quietMs: now - heard }))
      if (mac) this.broadcast(mac.team_id, JSON.stringify({ type: "presence", mac: this.presenceOf(att.deviceId) }), ws)
    }
    return next
  }

  /** Makes sure an alarm comes by `at` (a Mac socket's reap deadline), keeping an earlier one. */
  private async armReap(at: number) {
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > at) await this.ctx.storage.setAlarm(at)
  }

  /** Team membership through Stack, cached 60 s (15 s for a refusal) per team. Throws when Stack fails. */
  async isMember(teamId: string, caller: Caller, owner: HubOwner): Promise<boolean> {
    this.bind(owner)
    const hit = this.members.get(teamId)
    const now = Date.now()
    if (hit && now - hit.at < (hit.ok ? MEMBER_TTL_MS : NON_MEMBER_TTL_MS)) return hit.ok
    const ok = (await userTeams(this.env, caller)).includes(teamId)
    this.members.set(teamId, { ok, at: now })
    return ok
  }

  /**
   * A device registered (POST /v1/devices): admits its signal socket here later without a database round trip.
   * A Mac that changed team has its socket closed with 4001 `moved` (it reconnects for its new team) and the
   * sockets of its old team hear it `removed`. A phone's open socket stays, as with team hubs: its links keep
   * signaling (admission is by user), and it hears its old team's presence until it reconnects. A Mac that is
   * new, renamed or moved is announced to the sockets of its team.
   */
  async register(d: HubDevice): Promise<void> {
    this.bind({ ownerKey: d.ownerKey, space: d.space ?? "" })
    this.sql.exec(`DELETE FROM forgotten WHERE device_id = ?`, d.deviceId)
    const prevTeam = this.sql.exec<{ team_id: string | null }>(`SELECT team_id FROM devices WHERE device_id = ?`, d.deviceId).toArray()[0]?.team_id ?? null
    const prevMac = this.macRow(d.deviceId)
    const oldTeam = prevTeam ?? prevMac?.team_id ?? null
    this.sql.exec(
      `INSERT INTO devices (device_id, owner_key, kind, name, team_id) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET owner_key = excluded.owner_key, kind = excluded.kind, name = excluded.name, team_id = excluded.team_id`,
      d.deviceId,
      d.ownerKey,
      d.kind,
      d.name,
      d.teamId
    )
    const moved = oldTeam !== null && oldTeam !== d.teamId
    if (moved && d.kind === "mac") {
      for (const ws of this.ctx.getWebSockets(d.deviceId)) {
        this.setAttach(ws, { ...this.attach(ws), replaced: true })
        try {
          ws.close(4001, "moved")
        } catch {}
      }
      this.live.delete(d.deviceId)
      if (prevMac) this.broadcast(oldTeam, JSON.stringify({ type: "presence", mac: { ...this.presenceOf(d.deviceId), removed: true } }))
    }
    if (d.kind !== "mac") {
      // A Mac re-registered as a phone (not a real flow): it no longer appears in presence.
      if (prevMac) this.sql.exec(`DELETE FROM macs WHERE device_id = ?`, d.deviceId)
      return
    }
    const machineId = d.machineId ?? null
    this.sql.exec(
      `INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, team_id, last_seen_at, machine_id) VALUES (?, ?, ?, ?, ?, NULL, ?)
       ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id, owner_project_id = excluded.owner_project_id, team_id = excluded.team_id, machine_id = excluded.machine_id`,
      d.deviceId,
      d.name,
      d.userId,
      d.projectId,
      d.teamId,
      machineId
    )
    if (!prevMac || prevMac.name !== d.name || moved || prevMac.team_id !== d.teamId || (prevMac.machine_id ?? null) !== machineId)
      this.broadcast(d.teamId, JSON.stringify({ type: "presence", mac: this.presenceOf(d.deviceId) }))
    // Older builds on the same Mac now listed as that computer's: their sockets' phones hear it.
    for (const id of d.claimed ?? []) {
      const sibling = this.macRow(id)
      // A row that has a machine id keeps it (the database never replaces one either).
      if (!sibling || sibling.machine_id) continue
      this.sql.exec(`UPDATE macs SET machine_id = ? WHERE device_id = ?`, machineId, id)
      this.broadcast(sibling.team_id, JSON.stringify({ type: "presence", mac: this.presenceOf(id) }))
    }
  }

  /**
   * The owner's Macs from the database, once per hub: a new hub (every user's first after the move from team
   * hubs) would otherwise list no offline Mac in `hello` until each registers again. Rows the hub already has
   * win, and a device deleted here since (the database read may have raced the deletion) is not brought back.
   */
  async seed(hubOwner: HubOwner, owner: { userId: string; projectId: string }, macs: ReadonlyArray<SeedMac>): Promise<void> {
    this.bind(hubOwner)
    if (this.seeded()) return
    for (const m of macs)
      this.sql.exec(
        `INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, team_id, last_seen_at, machine_id)
         SELECT ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM forgotten WHERE device_id = ?) ON CONFLICT(device_id) DO NOTHING`,
        m.deviceId,
        m.name,
        owner.userId,
        owner.projectId,
        m.teamId,
        m.lastSeenAt ? Date.parse(m.lastSeenAt) : null,
        m.machineId ?? null,
        m.deviceId
      )
    this.sql.exec(`INSERT INTO meta (key, value) VALUES ('seeded', '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
  }

  /**
   * A device was deleted (PROTOCOL.md `DELETE /v1/devices/:deviceId`): drop a Mac from presence with a last
   * `removed` frame, close the device's socket with 4002 `removed`, and end its signaling sessions.
   */
  async forgetDevice(owner: HubOwner, deviceId: string): Promise<void> {
    this.bind(owner)
    this.sql.exec(`DELETE FROM devices WHERE device_id = ?`, deviceId)
    this.sql.exec(`INSERT INTO forgotten (device_id) VALUES (?) ON CONFLICT(device_id) DO NOTHING`, deviceId)
    const mac = this.macRow(deviceId)
    if (mac) {
      this.sql.exec(`DELETE FROM macs WHERE device_id = ?`, deviceId)
      const lastSeenAt = mac.last_seen_at ? new Date(mac.last_seen_at).toISOString() : null
      this.broadcast(mac.team_id, JSON.stringify({ type: "presence", mac: { deviceId, name: mac.name, online: false, lastSeenAt, removed: true } }))
    }
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(4002, "removed")
      } catch {}
    }
    this.live.delete(deviceId)
    for (const r of this.sql.exec<{ session_id: string }>(`SELECT session_id FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId).toArray()) {
      this.sessions.delete(r.session_id)
      this.closeRelay(r.session_id, RELAY_CLOSE.removed, "removed")
    }
    this.sql.exec(`DELETE FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId)
    // A removed phone's replies never reach a Mac, and a removed Mac's queue goes with it.
    this.sql.exec(`DELETE FROM mailbox WHERE mac = ? OR from_device = ?`, deviceId, deviceId)
    this.sql.exec(`DELETE FROM mailbox_seq WHERE mac = ? OR from_device = ?`, deviceId, deviceId)
  }

  /**
   * Push coalescing (PROTOCOL.md notify): whether a turn-ending push under `key` (src/push.ts `turnPushKey`) may
   * go now, at most one per `windowMs`. Here and not in a Workers rate limit, which counts per location and lags:
   * a burst passed it whole in the 2026-10-21 check.
   */
  async turnPushAllowed(owner: HubOwner, key: string, windowMs: number): Promise<boolean> {
    this.bind(owner)
    const now = Date.now()
    this.sql.exec(`DELETE FROM turn_pushes WHERE at <= ?`, now - windowMs)
    if (this.sql.exec(`SELECT 1 FROM turn_pushes WHERE key = ?`, key).toArray().length > 0) return false
    this.sql.exec(`INSERT INTO turn_pushes (key, at) VALUES (?, ?)`, key, now)
    return true
  }

  /** Account data deletion (`DELETE /v1/me`): close every socket with 4002 `removed` and wipe this hub. */
  async purge(owner: HubOwner): Promise<void> {
    this.bind(owner)
    for (const ws of this.ctx.getWebSockets()) {
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(4002, "removed")
      } catch {}
    }
    this.live.clear()
    this.sessions.clear()
    this.members.clear()
    // Before `meta` (the owner key names the relay objects) goes.
    for (const r of this.sql.exec<{ session_id: string }>(`SELECT session_id FROM relay_sessions`).toArray())
      this.closeRelay(r.session_id, RELAY_CLOSE.removed, "removed")
    for (const t of ["macs", "devices", "sessions", "meta", "forgotten", "turn_pushes", "mailbox", "mailbox_seq", "relay_sessions"]) this.sql.exec(`DELETE FROM ${t}`)
    this.ownerKey = null
  }

  /**
   * Migration from team hubs (PROTOCOL.md 0.10.0): called on a hub by its old name (the team id). Hibernated
   * sockets survive a deploy, so a Mac could stay in its team hub while its phone reconnects into the user hub
   * and finds it offline. This closes every socket here with 1012 (clients reconnect, now into their user hub)
   * and deletes the stored rows, which mixed the team's users. A user hub is never touched: only one whose own
   * id is the id of `user:<its owner>` counts as one (an older Worker could have written an owner into a team hub).
   */
  async retireTeamHub(): Promise<{ closed: number }> {
    const owner = this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = 'owner'`).toArray()[0]?.value
    if (owner !== undefined && this.isUserHubOf(owner, this.boundSpace())) return { closed: 0 }
    const open = this.ctx.getWebSockets().filter((ws) => !this.attach(ws)?.replaced)
    // Already retired and nothing parked since (the sweep's common case): no writes.
    if (open.length === 0 && this.sql.exec(`SELECT 1 FROM meta WHERE key = 'retired'`).toArray().length > 0) return { closed: 0 }
    let closed = 0
    for (const ws of this.ctx.getWebSockets()) {
      if (this.attach(ws)?.replaced) continue
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(1012, "moved to the user hub")
        closed++
      } catch {}
    }
    this.live.clear()
    this.sessions.clear()
    this.ownerKey = undefined
    await this.ctx.storage.deleteAll()
    this.schema()
    this.sql.exec(`INSERT INTO meta (key, value) VALUES ('retired', '1')`)
    return { closed }
  }

  /**
   * The other party of link session `sessionId` when `deviceId` is one of its two (PROTOCOL.md "WebSocket relay"):
   * the devices its first admitted signal bound, while the session lives (24 h, or until `bye` or the device's
   * removal ends it). Null for anyone else, so only the phone and the Mac of one session can join its relay.
   */
  async relayPeer(owner: HubOwner, sessionId: string, deviceId: string, ticket?: string | null): Promise<{ peer: string; ingress: Ingress | null } | null> {
    this.bind(owner)
    const s = this.session(sessionId)
    if (!s) return null
    // The device must present its own ticket: the one stamped on the signals sent to its own socket.
    const peer = s.initiator === deviceId ? s.responder : s.responder === deviceId ? s.initiator : null
    if (!peer || !ticketsMatch(ticket, this.ticketOf(sessionId, s, deviceId))) return null
    this.sql.exec(`INSERT INTO relay_sessions (session_id) VALUES (?) ON CONFLICT(session_id) DO NOTHING`, sessionId)
    // Where the peer's signal socket entered Cloudflare (and its netcheck): the relay's other end, for placement.
    const sock = this.ctx.getWebSockets(peer).find((ws) => !this.attach(ws)?.replaced)
    return { peer, ingress: (sock && this.attach(sock)?.ingress) ?? null }
  }

  /**
   * The relay's per-user budget (PROTOCOL.md "WebSocket relay"): whether the owner may relay `mib` more MiB now,
   * across every session of this hub. LinkRelay asks for grants of 64 KiB doubling to a MiB, so this is a few
   * calls a second at most per busy socket.
   */
  async relayBudget(owner: HubOwner, mib: number): Promise<BudgetAnswer> {
    this.bind(owner)
    this.relayBudgetAsked += 1
    // Test only: a hub that sheds load (the relay must fail closed, test/link-relay.test.ts).
    if (this.env.ENVIRONMENT === "test" && this.env.LINK_RELAY_TEST_BUDGET_ERROR === "1") throw new Error("test: the hub is overloaded")
    if (!this.relayBucket) {
      const row = this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = 'relay_budget'`).toArray()[0]
      const stored = row ? (JSON.parse(row.value) as MibBucketState) : undefined
      this.relayBucket = new MibBucket(userMibPerMinute(this.env.LINK_RELAY_USER_MIB_PER_MIN), stored)
    }
    const granted = this.relayBucket.take(mib)
    this.sql.exec(
      `INSERT INTO meta (key, value) VALUES ('relay_budget', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      JSON.stringify(this.relayBucket.state())
    )
    return { granted, retryAfterMs: granted ? 0 : this.relayBucket.msUntil(Math.min(mib, FIRST_GRANT / MIB)) }
  }

  /** How many budget requests this hub answered since it last woke (tests and diagnostics). */
  async relayBudgetCalls(owner: HubOwner): Promise<number> {
    this.bind(owner)
    return this.relayBudgetAsked
  }

  /**
   * The kind of `deviceId` when it is one of this owner's registered devices, as this hub knows it (null when the
   * hub has not seen it, or it was removed): the three-way hub admits only the owner's own devices (PROTOCOL.md
   * "Three-way hub"). The Worker falls back to the database on null.
   */
  async hubDevice(owner: HubOwner, deviceId: string): Promise<"mac" | "phone" | null> {
    this.bind(owner)
    if (this.sql.exec(`SELECT 1 FROM forgotten WHERE device_id = ?`, deviceId).toArray().length > 0) return null
    const row = this.sql.exec<{ owner_key: string; kind: string }>(`SELECT owner_key, kind FROM devices WHERE device_id = ?`, deviceId).toArray()[0]
    if (!row || row.owner_key !== ownerOf(owner).ownerKey) return null
    return row.kind === "mac" ? "mac" : "phone"
  }

  /** The colo this hub runs in (diagnostics: a hub stays where it was first created). */
  async placement(owner: HubOwner): Promise<{ colo: string | null }> {
    this.bind(owner)
    return { colo: await this.hubColo() }
  }

  /** This hub's colo, looked up once per instance (a failed lookup is retried next time). */
  private async hubColo(): Promise<string | null> {
    if (this.env.ENVIRONMENT === "test") return null
    if (this.colo === undefined) {
      try {
        const trace = await (await fetch("https://www.cloudflare.com/cdn-cgi/trace")).text()
        this.colo = /^colo=(\w+)$/m.exec(trace)?.[1] ?? null
      } catch {
        return null
      }
    }
    return this.colo
  }

  /**
   * A phone's `link_stat` (PROTOCOL.md "Link stats"): one structured log line, never an answer. A malformed or
   * too frequent stat is dropped silently: an error frame without a session would fail the phone's dials.
   */
  private async linkStat(ws: WebSocket, att: Attachment, f: Record<string, unknown>) {
    if (att.kind !== "phone") return
    const now = Date.now()
    const last = this.linkStats.get(ws)
    if (last !== undefined && now - last < LINK_STAT_MIN_GAP_MS && f.reason !== "end") return
    const line = linkStatLine(f, att.kind, att.ingress, await this.hubColo())
    if (!line) return
    this.linkStats.set(ws, now)
    console.log(JSON.stringify(line))
  }

  /** The owner's Macs with presence; only one team's when `teamId` is given. */
  async macs(owner: HubOwner, teamId?: string): Promise<Array<MacPresence>> {
    this.bind(owner)
    return this.macList(teamId)
  }

  /**
   * Whether one of the owner's Macs is connected, and the last application ping that speaks for the moment
   * `at` (ms; connectivity alerts judge an incident at the time the phone saw it, not when its report came).
   */
  async macLiveness(owner: HubOwner, deviceId: string, at: number = Date.now()): Promise<MacLiveness> {
    this.bind(owner)
    const recorded = this.recordedPing(deviceId)
    const connects = this.connectsOf(deviceId)
    const ws = this.open(deviceId)
    if (!ws || this.attach(ws).kind !== "mac") return { connected: false, lastPingAt: recorded, pings: recorded !== null, connectedAt: null, connects }
    const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? null
    const connectedAt = this.attach(ws).connectedAt ?? 0
    // A socket opened after the moment cannot speak for it: the last socket before it does.
    const lastPingAt = connectedAt > at ? recorded : pinged
    return { connected: true, lastPingAt, pings: pinged !== null || recorded !== null, connectedAt: connectedAt || null, connects }
  }

  /** A Mac's last signaling connects (ms, oldest first). */
  private connectsOf(deviceId: string): Array<number> {
    const row = this.sql.exec<{ connects: string | null }>(`SELECT connects FROM macs WHERE device_id = ?`, deviceId).toArray()[0]
    try {
      const list = JSON.parse(row?.connects ?? "[]") as unknown
      return Array.isArray(list) ? list.filter((n): n is number => typeof n === "number") : []
    } catch {
      return []
    }
  }

  /** The last application ping recorded for a Mac when one of its sockets closed or was replaced. */
  private recordedPing(deviceId: string): number | null {
    const row = this.sql.exec<{ last_ping_at: string | null }>(`SELECT last_ping_at FROM macs WHERE device_id = ?`, deviceId).toArray()[0]
    const value = row?.last_ping_at == null ? NaN : Number(row.last_ping_at)
    return Number.isFinite(value) ? value : null
  }

  /** Keeps a closing or replaced Mac socket's last application ping (the newest one wins). */
  private recordPing(ws: WebSocket, deviceId: string) {
    const at = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime()
    if (at === undefined) return
    const known = this.recordedPing(deviceId)
    if (known !== null && known >= at) return
    this.sql.exec(`UPDATE macs SET last_ping_at = ? WHERE device_id = ?`, String(at), deviceId)
  }

  // ---- Reply mailbox (PROTOCOL.md "Sealed pushes and the reply mailbox") ------------------------------

  /** Drops rows past `keep_until` (lazily, on every mailbox call and Mac connect). */
  private mailboxSweep(now: number) {
    this.sql.exec(`DELETE FROM mailbox WHERE keep_until <= ?`, now)
  }

  /**
   * Queues a sealed reply for `item.mac` (the Worker checked that the caller owns both devices): delivered at
   * once when the Mac's socket is open, else right after its next `hello`. The same id with the same blob is
   * the same item (a retried request, answered its first `seq`); with another blob it is a conflict. An item held
   * at most MAILBOX_TTL_MS counts against MAILBOX_PENDING_LIMIT per Mac; a longer hold ("Store and forward") counts
   * per (Mac, phone) against MAILBOX_HOLD_LIMIT items and MAILBOX_HOLD_BYTES sealed characters. `ttlMs` is the
   * phone's `hold` (MAILBOX_TTL_MS when it sent none).
   */
  async mailboxPost(owner: HubOwner, item: MailboxItem, ttlMs: number = MAILBOX_TTL_MS): Promise<MailboxPost> {
    this.bind(owner)
    const now = Date.now()
    this.mailboxSweep(now)
    const existing = this.sql
      .exec<{ mac: string; from_device: string; sealed: string; state: string; seq: number | null; expires_at: number }>(
        `SELECT mac, from_device, sealed, state, seq, expires_at FROM mailbox WHERE id = ?`,
        item.id
      )
      .toArray()[0]
    if (existing) {
      if (existing.mac !== item.mac || existing.from_device !== item.from || (existing.state === "queued" && existing.sealed !== item.sealed)) return { error: "conflict" }
      return { queued: true, delivered: false, seq: existing.seq ?? 0, expiresAt: existing.expires_at }
    }
    if (ttlMs <= MAILBOX_TTL_MS) {
      const pending = this.sql
        .exec<{ n: number }>(`SELECT COUNT(*) AS n FROM mailbox WHERE mac = ? AND state = 'queued' AND expires_at > ? AND expires_at - at <= ?`, item.mac, now, MAILBOX_TTL_MS)
        .toArray()[0]?.n ?? 0
      if (pending >= MAILBOX_PENDING_LIMIT) return { error: "full" }
    } else {
      const held = this.sql
        .exec<{ n: number; bytes: number | null }>(
          `SELECT COUNT(*) AS n, SUM(LENGTH(sealed)) AS bytes FROM mailbox WHERE mac = ? AND from_device = ? AND state = 'queued' AND expires_at > ? AND expires_at - at > ?`,
          item.mac,
          item.from,
          now,
          MAILBOX_TTL_MS
        )
        .toArray()[0]
      if ((held?.n ?? 0) >= MAILBOX_HOLD_LIMIT || (held?.bytes ?? 0) + item.sealed.length > MAILBOX_HOLD_BYTES) return { error: "full" }
    }
    const last = this.sql.exec<{ seq: number }>(`SELECT seq FROM mailbox_seq WHERE mac = ? AND from_device = ?`, item.mac, item.from).toArray()[0]?.seq ?? 0
    const seq = last + 1
    this.sql.exec(
      `INSERT INTO mailbox_seq (mac, from_device, seq) VALUES (?, ?, ?) ON CONFLICT(mac, from_device) DO UPDATE SET seq = excluded.seq`,
      item.mac,
      item.from,
      seq
    )
    const expiresAt = now + ttlMs
    this.sql.exec(
      `INSERT INTO mailbox (id, mac, from_device, sealed, at, expires_at, keep_until, state, seq) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?)`,
      item.id,
      item.mac,
      item.from,
      item.sealed,
      now,
      expiresAt,
      // The outcome stays readable for one more full window, whatever this item's own time to live.
      expiresAt + MAILBOX_TTL_MS,
      seq
    )
    const ws = this.open(item.mac)
    const delivered = ws ? this.deliverMailbox(ws, item.mac).includes(item.id) : false
    return { queued: true, delivered, seq, expiresAt }
  }

  /** The outcome of one item of `mac`, or null when there is none (never posted, or long gone). */
  async mailboxState(owner: HubOwner, mac: string, id: string): Promise<MailboxState | null> {
    this.bind(owner)
    const now = Date.now()
    this.mailboxSweep(now)
    const row = this.sql.exec<{ state: string; reason: string | null; expires_at: number; sig: string | null; seq: number | null }>(
      `SELECT state, reason, expires_at, sig, seq FROM mailbox WHERE id = ? AND mac = ?`,
      id,
      mac
    ).toArray()[0]
    if (!row) return null
    const sig = row.sig ? { sig: row.sig } : {}
    const when = row.seq ? { seq: row.seq, expiresAt: row.expires_at } : {}
    if (row.state === "applied") return { state: "applied", ...sig, ...when }
    if (row.state === "rejected") return { state: "rejected", reason: row.reason ?? "refused", ...sig, ...when }
    return row.expires_at <= now ? { state: "expired", ...when } : { state: "queued", ...when }
  }

  /**
   * Sends the Mac's next page of queued, unexpired items on `ws` (after `hello`, a post, and each `mailbox_ack`):
   * ordered by phone, then `seq`, each once per socket, at most MAILBOX_PAGE per frame and MAILBOX_PAGE per phone
   * waiting for their ack on it at a time.
   * Answers the ids it sent.
   */
  private deliverMailbox(ws: WebSocket, mac: string): string[] {
    // Frames of at most MAILBOX_PAGE (an older Mac's cap) until nothing more fits: a second phone's items go in
    // the next frame instead of waiting for the next ack. Each pass sends at least one item or stops.
    const sent: string[] = []
    for (;;) {
      const page = this.deliverMailboxPage(ws, mac)
      if (!page.length) return sent
      sent.push(...page)
    }
  }

  private deliverMailboxPage(ws: WebSocket, mac: string): string[] {
    const now = Date.now()
    this.mailboxSweep(now)
    const conn = this.attach(ws).connectedAt ?? 0
    // Counted per phone: one phone's items held on the Mac (unacked) never take another phone's room.
    const outstanding = new Map<string, number>()
    for (const r of this.sql.exec<{ from_device: string; n: number }>(
      `SELECT from_device, COUNT(*) AS n FROM mailbox WHERE mac = ? AND state = 'queued' AND expires_at > ? AND sent_conn = ? GROUP BY from_device`,
      mac,
      now,
      conn
    ))
      outstanding.set(r.from_device, r.n)
    const items: Array<{ id: string; from_device: string; sealed: string; at: number; seq: number | null }> = []
    for (const r of this.sql.exec<{ id: string; from_device: string; sealed: string; at: number; seq: number | null }>(
      `SELECT id, from_device, sealed, at, seq FROM mailbox WHERE mac = ? AND state = 'queued' AND expires_at > ? AND (sent_conn IS NULL OR sent_conn != ?)
       ORDER BY from_device, COALESCE(seq, 0), at`,
      mac,
      now,
      conn
    )) {
      const sent = outstanding.get(r.from_device) ?? 0
      if (sent >= MAILBOX_PAGE) continue
      outstanding.set(r.from_device, sent + 1)
      items.push(r)
      if (items.length >= MAILBOX_PAGE) break
    }
    if (!items.length) return []
    try {
      ws.send(JSON.stringify({ type: "mailbox", items: items.map((r) => ({ id: r.id, from: r.from_device, sealed: r.sealed, at: r.at, ...(r.seq ? { seq: r.seq } : {}) })) }))
    } catch {
      return []
    }
    for (const r of items) this.sql.exec(`UPDATE mailbox SET sent_conn = ? WHERE id = ?`, conn, r.id)
    return items.map((r) => r.id)
  }

  /** `mailbox_ack` from a Mac socket: settles that Mac's own queued items; anything else is ignored or refused. */
  private mailboxAck(ws: WebSocket, att: Attachment, results: unknown) {
    if (att.kind !== "mac") return this.error(ws, "bad_request", "only a Mac acknowledges mailbox items")
    if (!Array.isArray(results) || results.length > MAX_ACK_RESULTS) return this.error(ws, "bad_request", "results must be a list of at most 64 {id, applied, reason?}")
    for (const r of results) {
      if (typeof r !== "object" || r === null) continue
      const { id, applied, reason, sig } = r as { id?: unknown; applied?: unknown; reason?: unknown; sig?: unknown }
      if (typeof id !== "string" || !UUID.test(id) || typeof applied !== "boolean") continue
      const why = applied ? null : typeof reason === "string" && ACK_REASON.test(reason) ? reason : "refused"
      // Kept as sent: the phone checks it against the Mac's pinned key (the hub can't make one up).
      const signature = typeof sig === "string" && ACK_SIG.test(sig) ? sig : null
      this.sql.exec(
        `UPDATE mailbox SET state = ?, reason = ?, sig = ?, sealed = '' WHERE id = ? AND mac = ? AND state = 'queued'`,
        applied ? "applied" : "rejected",
        why,
        signature,
        id,
        att.deviceId
      )
    }
    // The next page, if more wait (PROTOCOL.md "Store and forward").
    this.deliverMailbox(ws, att.deviceId)
  }

  // ---- WebSocket -------------------------------------------------------------------------------

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 })
    let att = JSON.parse(req.headers.get("x-cmux-mobile-attachment") ?? "null") as Attachment | null
    // The Worker's fast path: only the caller's identity, device id and team; the device row is this hub's.
    const claim = JSON.parse(req.headers.get("x-cmux-mobile-claim") ?? "null") as { userId: string; projectId: string; deviceId: string; ownerKey: string; teamId: string; space?: string } | null
    const ownerKey = claim?.ownerKey ?? req.headers.get("x-cmux-mobile-owner-key")
    if (!ownerKey) return new Response("missing owner", { status: 400 })
    // The build space the Worker resolved ("" for stable): a dev hub refuses a request without its own.
    const space = claim ? (claim.space ?? "") : (req.headers.get("x-cmux-mobile-space") ?? "")
    try {
      this.bind({ ownerKey, space })
    } catch {
      return new Response("wrong hub", { status: 500 })
    }
    if (!att && claim) {
      // Not seeded yet: let the Worker's slow path seed the owner's Macs from the database first.
      if (!this.seeded()) return new Response("not seeded", { status: 409 })
      const row = this.sql
        .exec<{ owner_key: string; kind: string; name: string; team_id: string | null }>(`SELECT owner_key, kind, name, team_id FROM devices WHERE device_id = ?`, claim.deviceId)
        .toArray()[0]
      if (!row) return new Response("unknown device", { status: 409 })
      if (row.owner_key !== claim.ownerKey) return new Response("not owner", { status: 403 })
      // Registered in another team as far as this hub knows: the database decides (wrong_team or a newer row).
      if (row.team_id !== claim.teamId) return new Response("other team", { status: 409 })
      att = { userId: claim.userId, projectId: claim.projectId, deviceId: claim.deviceId, kind: row.kind === "mac" ? "mac" : "phone", name: row.name, teamId: claim.teamId }
    }
    if (!att) return new Response("missing identity", { status: 400 })
    const ingress = JSON.parse(req.headers.get("x-cmux-mobile-ingress") ?? "null") as Ingress | null
    if (ingress) att = { ...att, ingress }
    if (!claim) {
      // The slow path checked the database: remember the device for next time.
      this.sql.exec(
        `INSERT INTO devices (device_id, owner_key, kind, name, team_id) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET owner_key = excluded.owner_key, kind = excluded.kind, name = excluded.name, team_id = excluded.team_id`,
        att.deviceId,
        ownerKey,
        att.kind,
        att.name,
        att.teamId
      )
    }
    // One live socket per device: a reconnect replaces the old socket without an offline blip.
    for (const old of this.ctx.getWebSockets(att.deviceId)) {
      if (att.kind === "mac") this.recordPing(old, att.deviceId)
      this.setAttach(old, { ...this.attach(old), replaced: true })
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [att.deviceId])
    this.setAttach(server, { ...att, connectedAt: Date.now() })
    this.live.set(att.deviceId, server)
    if (att.kind === "mac") await this.armReap(Date.now() + GONE_MS)
    if (att.kind === "mac") {
      this.sql.exec(
        `INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, team_id, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id, owner_project_id = excluded.owner_project_id, team_id = excluded.team_id, last_seen_at = excluded.last_seen_at`,
        att.deviceId,
        att.name,
        att.userId,
        att.projectId,
        att.teamId,
        Date.now()
      )
      const connects = [...this.connectsOf(att.deviceId), Date.now()].slice(-8)
      this.sql.exec(`UPDATE macs SET connects = ? WHERE device_id = ?`, JSON.stringify(connects), att.deviceId)
    }

    server.send(
      JSON.stringify({
        type: "hello",
        you: att.deviceId,
        macs: this.macList(att.teamId).map(({ teamId: _t, machineId, ...m }) => ({ ...m, ...(machineId ? { machineId } : {}) }))
      })
    )
    if (att.kind === "mac") {
      this.deliverMailbox(server, att.deviceId)
      this.broadcast(att.teamId, JSON.stringify({ type: "presence", mac: this.presenceOf(att.deviceId) }), server)
    }
    const proto = req.headers.get("x-cmux-mobile-subprotocol")
    return new Response(null, { status: 101, webSocket: client, ...(proto ? { headers: { "sec-websocket-protocol": proto } } : {}) })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = this.attach(ws)
    if (att.replaced) return
    if (typeof message === "string") {
      if (!this.take(ws, "text")) return this.error(ws, "rate_limited", "too many signaling frames")
      if (message.length > MAX_TEXT_FRAME) return this.error(ws, "bad_request", "frame too large")
      let f: { type?: unknown; to?: unknown; from?: unknown; sessionId?: unknown; payload?: { kind?: unknown }; results?: unknown }
      try {
        f = JSON.parse(message)
      } catch {
        return this.error(ws, "bad_request", "invalid JSON")
      }
      if (f.type === "mailbox_ack") return this.mailboxAck(ws, att, f.results)
      if (f.type === "link_stat") return message.length > MAX_LINK_STAT_FRAME ? undefined : this.linkStat(ws, att, f as Record<string, unknown>)
      if (f.type !== "signal") return this.error(ws, "bad_request", "unknown frame type")
      if (typeof f.to !== "string" || !UUID.test(f.to)) return this.error(ws, "bad_request", "to must be a deviceId")
      if (f.from !== undefined && f.from !== att.deviceId) return this.error(ws, "bad_request", "from must be your deviceId")
      if (typeof f.sessionId !== "string" || !UUID.test(f.sessionId)) return this.error(ws, "bad_request", "sessionId must be a UUID")
      // Named by session: a refused signal of one session must not fail the client's other dials.
      if (typeof f.payload !== "object" || f.payload === null || typeof f.payload.kind !== "string" || !SIGNAL_KINDS.has(f.payload.kind))
        return this.error(ws, "bad_request", "unknown payload kind", f.sessionId)
      if (!this.admit(att, f.to, f.sessionId)) return this.error(ws, "not_owner", "not allowed to signal this device", f.sessionId)
      const target = this.open(f.to)
      if (!target) {
        // A bye still ends the session (and its relay) when the peer cannot hear it.
        if (f.payload.kind === "bye") this.endSession(f.sessionId)
        return this.error(ws, "offline", "device is offline", f.sessionId)
      }
      // fromUserId is always the verified sender (PROTOCOL.md); any client value is dropped. A WireGuard signal
      // also carries the recipient's own relay ticket (PROTOCOL.md "WebSocket relay"), never a client's.
      const relayTicket = f.payload.kind.startsWith("wg-") ? this.ticketFor(f.sessionId, f.to) : undefined
      target.send(JSON.stringify({ type: "signal", to: f.to, from: att.deviceId, fromUserId: att.userId, sessionId: f.sessionId, payload: f.payload, ...(relayTicket ? { relayTicket } : {}) }))
      if (f.payload.kind === "wg-init") {
        // PROTOCOL.md "Early relay ticket": a dialer with no path but the relay asks for its own ticket now, so its
        // join runs while the Mac gathers and answers. Only the service sends `wg-ticket`; a client's is refused above.
        const early = (f.payload as { ticketEarly?: unknown }).ticketEarly === true ? this.ticketFor(f.sessionId, att.deviceId) : null
        if (early) ws.send(JSON.stringify({ type: "signal", to: att.deviceId, from: f.to, fromUserId: att.userId, sessionId: f.sessionId, payload: { kind: "wg-ticket" }, relayTicket: early }))
        this.prewarmRelay(f.sessionId, att, target)
      }
      if (f.payload.kind === "bye") this.endSession(f.sessionId)
      return
    }
    // A retired relay frame from an older client: [16 sessionId][16 to][datagram]. Never forwarded.
    if (!this.take(ws, "binary")) return
    if (message.byteLength < 16) return
    const sessionId = bytesToUuid(new Uint8Array(message, 0, 16))
    this.relayError(ws, "relay_retired", "WireGuard relay frames are retired; this app version needs an update to connect without UDP", sessionId)
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  // ---- internals -------------------------------------------------------------------------------

  /** Rows and attachments from before multi-project support carry no project: they are the primary project's. */
  private get primary(): string {
    return primaryProject(this.env).id
  }

  /** Whether this object is the hub named `userHubName(ownerKey, space)` (its id derives from its name). */
  private isUserHubOf(ownerKey: string, space: string): boolean {
    return this.env.TEAM_HUB.idFromName(userHubName(ownerKey, space)).equals(this.ctx.id)
  }

  /**
   * The build space this hub was bound in ("" for stable, and for every hub bound before build spaces). Kept in
   * storage because `ctx.id.name` is not always set: a hub reached by id rather than by name (as on some wakes)
   * has none (test/build-space.test.ts).
   */
  private boundSpace(): string {
    return this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = 'space'`).toArray()[0]?.value ?? ""
  }

  /**
   * Binds this hub to its owner and build space: the pair must name this very object (`userHubName`), so
   * neither a routing bug, a call that left out its dev space, nor an older Worker calling a team hub can bind
   * one, and once bound any other owner is refused. A dev hub records its space; a stable hub records none, so
   * hubs bound before build spaces read as stable.
   */
  private bind(o: unknown) {
    const owner = typeof o === "string" || (typeof o === "object" && o !== null) ? ownerOf(o as HubOwner) : undefined
    if (!owner || typeof owner.ownerKey !== "string" || !owner.ownerKey || typeof owner.space !== "string" || !this.isUserHubOf(owner.ownerKey, owner.space))
      throw new WrongHubError("not this user's hub")
    const { ownerKey, space } = owner
    if (this.boundOwner() === null) {
      this.sql.exec(`INSERT INTO meta (key, value) VALUES ('owner', ?)`, ownerKey)
      if (space) this.sql.exec(`INSERT INTO meta (key, value) VALUES ('space', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, space)
      this.ownerKey = ownerKey
      return
    }
    if (this.ownerKey !== ownerKey) throw new WrongHubError("this hub belongs to another user")
  }

  private seeded(): boolean {
    return this.sql.exec(`SELECT 1 FROM meta WHERE key = 'seeded'`).toArray().length > 0
  }

  private attach(ws: WebSocket): Attachment {
    let att = this.attachments.get(ws)
    if (!att) {
      att = ws.deserializeAttachment() as Attachment
      if (att) this.attachments.set(ws, att)
    }
    return att
  }

  private setAttach(ws: WebSocket, att: Attachment) {
    ws.serializeAttachment(att)
    this.attachments.set(ws, att)
  }

  private gone(ws: WebSocket) {
    const att = this.attach(ws)
    try {
      ws.close(1000, "bye")
    } catch {}
    if (!att || att.replaced || att.kind !== "mac") return
    this.recordPing(ws, att.deviceId)
    if (this.open(att.deviceId, ws)) return
    this.sql.exec(`UPDATE macs SET last_seen_at = ? WHERE device_id = ?`, Date.now(), att.deviceId)
    const mac = this.macRow(att.deviceId)
    if (mac) this.broadcast(mac.team_id, JSON.stringify({ type: "presence", mac: this.presenceOf(att.deviceId) }), ws)
  }

  /** The open, non-replaced socket of a device (excluding `except`). */
  private open(deviceId: string, except?: WebSocket): WebSocket | undefined {
    const usable = (w: WebSocket) => w !== except && w.readyState === WebSocket.OPEN && !this.attach(w).replaced
    const hit = this.live.get(deviceId)
    if (hit && usable(hit)) return hit
    const found = this.ctx.getWebSockets(deviceId).find(usable)
    if (found) this.live.set(deviceId, found)
    else if (hit && hit !== except) this.live.delete(deviceId)
    return found
  }

  /**
   * PROTOCOL.md admission: `to` is a Mac of this hub's user (the same sub in the same Stack project as the
   * sender; this opens or continues the session), or the sender is the Mac answering an existing session. A
   * sessionId is bound to its first two parties; reusing it for anyone else is refused. Every device here is
   * the hub owner's, so another user's device can never be reached; the owner check below is defense in depth.
   * The team does not scope admission: a user's phone may dial any of the user's own Macs.
   */
  private admit(att: Attachment, to: string, sessionId: string): boolean {
    if (to === att.deviceId) return false
    const s = this.session(sessionId)
    if (s) return (s.initiator === att.deviceId && s.responder === to) || (s.initiator === to && s.responder === att.deviceId)
    const mac = this.macRow(to)
    if (!mac || mac.owner_user_id !== att.userId || (mac.owner_project_id ?? this.primary) !== (att.projectId ?? this.primary)) return false
    const now = Date.now()
    // Expired sessions go, and so do their relays (review of #53240: a pruned session's relay stayed open, and a
    // later device delete no longer found it).
    for (const r of this.sql.exec<{ session_id: string }>(`SELECT session_id FROM sessions WHERE created_at < ?`, now - SESSION_TTL_MS).toArray())
      this.expireSession(r.session_id)
    const row: SessionRow = { initiator: att.deviceId, responder: to, initiatorTicket: newTicket(), responderTicket: newTicket(), createdAt: now }
    this.sql.exec(
      `INSERT INTO sessions (session_id, initiator, responder, created_at, initiator_ticket, responder_ticket) VALUES (?, ?, ?, ?, ?, ?)`,
      sessionId,
      att.deviceId,
      to,
      now,
      row.initiatorTicket,
      row.responderTicket
    )
    this.sessions.set(sessionId, row)
    return true
  }

  /**
   * Creates and places link session `sessionId`'s relay (RFD 0142 C4, PROTOCOL.md "Relay placement") while the
   * session's `wg-init` is forwarded, so a fallback to the relay later finds the object made instead of paying
   * for its creation, placement and cold start on the critical path. A Durable Object stays where it is first
   * created, so this placement is the session's: from both ends' signal sockets (each one's ingress and
   * netcheck), else the sender's own region. The same name as the Worker's relay route (`relayRoomName` of this
   * hub's owner key, its build space and the lowercase session id). Once per session and instance (a retried
   * `wg-init` does not fetch again; a wake forgets, and a second prewarm is harmless). Never awaited: the signal
   * is already on its way, and a failed prewarm only leaves the first join to create the object, as before.
   */
  private prewarmRelay(sessionId: string, from: Attachment, target: WebSocket) {
    if (this.env.LINK_RELAY_MODE === "off") return
    const id = sessionId.toLowerCase()
    if (this.prewarmed.has(id)) return
    const owner = this.boundOwner()
    if (!owner) return
    if (this.prewarmed.size >= PREWARMED_MAX) this.prewarmed.clear()
    this.prewarmed.add(id)
    const placed = relayPlacement(from.ingress, this.attach(target)?.ingress, locationHintOf(from.ingress))
    const room = this.env.LINK_RELAY.get(this.env.LINK_RELAY.idFromName(relayRoomName(owner, this.boundSpace(), id)), placed.hint ? { locationHint: placed.hint } : undefined)
    this.ctx.waitUntil(
      room.fetch("https://link-relay/prewarm", { method: "POST" }).then(
        (r) => r.body?.cancel(),
        () => {}
      )
    )
  }

  /** The owner key this hub was bound to (null before its first bind). */
  private boundOwner(): string | null {
    if (this.ownerKey === undefined)
      this.ownerKey = this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = 'owner'`).toArray()[0]?.value ?? null
    return this.ownerKey
  }

  private session(id: string): SessionRow | undefined {
    const hit = this.sessions.get(id)
    if (hit) {
      if (Date.now() - hit.createdAt <= SESSION_TTL_MS) return hit
      this.expireSession(id)
      return undefined
    }
    const r = this.sql
      .exec<{ initiator: string; responder: string; created_at: number; initiator_ticket: string | null; responder_ticket: string | null }>(
        `SELECT initiator, responder, created_at, initiator_ticket, responder_ticket FROM sessions WHERE session_id = ?`,
        id
      )
      .toArray()[0]
    if (!r) return undefined
    if (Date.now() - r.created_at > SESSION_TTL_MS) {
      this.expireSession(id)
      return undefined
    }
    const s: SessionRow = { initiator: r.initiator, responder: r.responder, initiatorTicket: r.initiator_ticket, responderTicket: r.responder_ticket, createdAt: r.created_at }
    this.sessions.set(id, s)
    return s
  }

  /** `deviceId`'s relay ticket of session `s`, made now for a session opened before tickets existed. */
  private ticketOf(id: string, s: SessionRow, deviceId: string): string | null {
    const initiator = s.initiator === deviceId
    if (!initiator && s.responder !== deviceId) return null
    const stored = initiator ? s.initiatorTicket : s.responderTicket
    if (stored) return stored
    const made = newTicket()
    this.sql.exec(`UPDATE sessions SET ${initiator ? "initiator_ticket" : "responder_ticket"} = ? WHERE session_id = ?`, made, id)
    if (initiator) s.initiatorTicket = made
    else s.responderTicket = made
    return made
  }

  /** The ticket to stamp on a signal of session `id` sent to `to` (synchronous, so signals keep their order). */
  private ticketFor(id: string, to: string): string | null {
    const s = this.session(id)
    return s ? this.ticketOf(id, s, to) : null
  }

  private endSession(id: string) {
    this.sessions.delete(id)
    this.sql.exec(`DELETE FROM sessions WHERE session_id = ?`, id)
    this.closeRelay(id, RELAY_CLOSE.ended, "ended")
  }

  /** A session past its 24 h: gone, like an ended one, its relay sockets closed. */
  private expireSession(id: string) {
    this.sessions.delete(id)
    this.sql.exec(`DELETE FROM sessions WHERE session_id = ?`, id)
    this.closeRelay(id, RELAY_CLOSE.ended, "expired")
  }

  /**
   * Close the live relay sockets of session `id` (PROTOCOL.md "WebSocket relay"), when its relay object ever had
   * a join: a session's end, a device's removal and an account's deletion stop what is already relaying, not only
   * new joins. Never awaited by the caller: it must not hold up signaling.
   */
  private closeRelay(id: string, code: number, reason: string) {
    if (this.sql.exec(`SELECT 1 FROM relay_sessions WHERE session_id = ?`, id).toArray().length === 0) return
    this.sql.exec(`DELETE FROM relay_sessions WHERE session_id = ?`, id)
    const owner = this.boundOwner()
    if (!owner) return
    const room = this.env.LINK_RELAY.get(this.env.LINK_RELAY.idFromName(relayRoomName(owner, this.boundSpace(), id)))
    this.ctx.waitUntil(
      room.closeAll(code, reason).catch((e: unknown) => console.log(JSON.stringify({ msg: "relay close failed", error: String(e) })))
    )
  }

  private macRow(deviceId: string) {
    return this.sql
      .exec<{ name: string; owner_user_id: string; owner_project_id: string | null; team_id: string | null; last_seen_at: number | null; machine_id: string | null }>(
        `SELECT name, owner_user_id, owner_project_id, team_id, last_seen_at, machine_id FROM macs WHERE device_id = ?`,
        deviceId
      )
      .toArray()[0]
  }

  private macList(teamId?: string): Array<MacPresence> {
    const rows = teamId === undefined
      ? this.sql.exec<{ device_id: string }>(`SELECT device_id FROM macs ORDER BY name`).toArray()
      : this.sql.exec<{ device_id: string }>(`SELECT device_id FROM macs WHERE team_id = ? ORDER BY name`, teamId).toArray()
    return rows.map((r) => this.presence(r.device_id)!)
  }

  private presence(deviceId: string): MacPresence | undefined {
    const r = this.macRow(deviceId)
    if (!r) return undefined
    const ws = this.open(deviceId)
    const quietMs = ws ? this.quietMs(ws, Date.now()) : undefined
    return {
      deviceId,
      name: r.name,
      teamId: r.team_id ?? "",
      online: !!ws,
      lastSeenAt: r.last_seen_at ? new Date(r.last_seen_at).toISOString() : null,
      ownerUserId: r.owner_user_id,
      machineId: r.machine_id ?? null,
      ...(quietMs !== undefined ? { quietMs } : {})
    }
  }

  /**
   * Ms since the hub last heard this open socket: its connect or its last application ping (answered by the
   * runtime without waking the hub, which keeps its time). Undefined when it knows neither (a socket accepted
   * before `connectedAt` existed that never pinged).
   */
  private quietMs(ws: WebSocket, now: number): number | undefined {
    const heard = Math.max(this.attach(ws).connectedAt ?? 0, this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0)
    return heard > 0 ? Math.max(0, now - heard) : undefined
  }

  /** The presence frame body: PROTOCOL.md `{deviceId, name, online, lastSeenAt, machineId, quietMs}`. */
  private presenceOf(deviceId: string) {
    const p = this.presence(deviceId)!
    return {
      deviceId: p.deviceId,
      name: p.name,
      online: p.online,
      lastSeenAt: p.lastSeenAt,
      ...(p.machineId ? { machineId: p.machineId } : {}),
      ...(p.quietMs !== undefined ? { quietMs: p.quietMs } : {})
    }
  }

  /** To the sockets opened for `teamId` (the only team whose Macs they list). */
  private broadcast(teamId: string | null, text: string, except?: WebSocket) {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || ws.readyState !== WebSocket.OPEN) continue
      const att = this.attach(ws)
      if (!att || att.replaced || att.teamId !== teamId) continue
      try {
        ws.send(text)
      } catch {}
    }
  }

  private error(ws: WebSocket, code: string, message: string, sessionId?: string) {
    try {
      ws.send(JSON.stringify({ type: "error", code, message, ...(sessionId ? { sessionId } : {}) }))
    } catch {}
  }

  private relayError(ws: WebSocket, code: string, message: string, sessionId: string) {
    let sent = this.relayErrors.get(ws)
    if (!sent) {
      sent = new Map()
      this.relayErrors.set(ws, sent)
    }
    const now = Date.now()
    const last = sent.get(sessionId)
    if (last !== undefined && now - last < RELAY_ERROR_INTERVAL_MS) return
    if (sent.size >= 256) sent.clear()
    sent.set(sessionId, now)
    this.error(ws, code, message, sessionId)
  }

  private take(ws: WebSocket, kind: "text" | "binary"): boolean {
    const now = Date.now()
    let b = this.buckets.get(ws)
    if (!b) {
      b = { text: { t: BUCKETS.text.burst, at: now }, binary: { t: BUCKETS.binary.burst, at: now } }
      this.buckets.set(ws, b)
    }
    const s = b[kind]
    s.t = Math.min(BUCKETS[kind].burst, s.t + ((now - s.at) / 1000) * BUCKETS[kind].rate)
    s.at = now
    if (s.t < 1) return false
    s.t -= 1
    return true
  }
}
