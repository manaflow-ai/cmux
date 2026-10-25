import { DurableObject } from "cloudflare:workers"
import { primaryProject, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { MAILBOX_PENDING_LIMIT, MAILBOX_TTL_MS } from "./push.ts"
import { userTeams } from "./stack.ts"

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
}

/** A sealed reply for a Mac (PROTOCOL.md "Reply mailbox"): the hub never holds a key that opens it. */
export interface MailboxItem {
  id: string
  mac: string
  from: string
  sealed: string
}

export type MailboxPost = { queued: true; delivered: boolean } | { error: "conflict" | "full" }
/** `sig`: the Mac's identity signature over the outcome (PROTOCOL.md), which the phone checks; absent from an older Mac. */
export type MailboxState = { state: "queued" | "expired" } | { state: "applied"; sig?: string } | { state: "rejected"; reason: string; sig?: string }

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
}

/** A device registration as the Worker hands it to the hub (POST /v1/devices). */
export interface HubDevice {
  deviceId: string
  /** The owner key of src/index.ts (`<sub>` or `<projectId>:<sub>`): must be this hub's owner. */
  ownerKey: string
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

const SIGNAL_KINDS = new Set(["webrtc-offer", "webrtc-answer", "webrtc-ice", "wg-init", "wg-resp", "wg-endpoints", "bye"])
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

/**
 * Token buckets per socket, in memory only: text (signaling), and binary (an older client's retired relay
 * frames), which bounds how often a flood of them costs a refusal check; excess frames are dropped silently.
 */
export const BUCKETS = { text: { rate: 20, burst: 60 }, binary: { rate: 12000, burst: 24000 } } as const

/** The Durable Object name of a user's hub: `user:` and the owner key (src/index.ts), never a client value. */
export const userHubName = (ownerKey: string) => `user:${ownerKey}`

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
 * One per user (idFromName(userHubName(ownerKey)), PROTOCOL.md "Signaling WebSocket"): signaling
 * (introductions, `wg-endpoints`) and Mac presence among one user's own devices, on hibernating WebSockets.
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
  private readonly sessions = new Map<string, { initiator: string; responder: string }>()
  /** Deserialized attachments: read on every frame, and deserializing each time is the costly part. */
  private readonly attachments = new WeakMap<WebSocket, Attachment>()
  private colo: string | null | undefined
  private readonly relayErrors = new WeakMap<WebSocket, Map<string, number>>()
  /** The open socket of each device, so a signal needs no socket scan (rebuilt lazily after hibernation). */
  private readonly live = new Map<string, WebSocket>()
  private ownerKey: string | null | undefined

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.schema()
  }

  /** The tables (again after `retireTeamHub` deleted them: the constructor does not rerun while the object stays in memory). */
  private schema() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS macs (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_user_id TEXT NOT NULL, last_seen_at INTEGER)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, owner_key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, initiator TEXT NOT NULL, responder TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    // Columns added after the tables first shipped (a hub created by older code has the tables without them).
    const addColumn = (table: string, column: string) => {
      if (!this.sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().some((c) => c.name === column)) this.sql.exec(`ALTER TABLE ${table} ADD COLUMN ${column} TEXT`)
    }
    addColumn("macs", "owner_project_id")
    addColumn("macs", "team_id")
    addColumn("devices", "team_id")
    addColumn("macs", "machine_id")
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
  }

  // ---- RPC from the Worker -------------------------------------------------------------------

  /** Team membership through Stack, cached 60 s (15 s for a refusal) per team. Throws when Stack fails. */
  async isMember(teamId: string, caller: Caller, ownerKey: string): Promise<boolean> {
    this.bind(ownerKey)
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
    this.bind(d.ownerKey)
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
  async seed(ownerKey: string, owner: { userId: string; projectId: string }, macs: ReadonlyArray<SeedMac>): Promise<void> {
    this.bind(ownerKey)
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
  async forgetDevice(ownerKey: string, deviceId: string): Promise<void> {
    this.bind(ownerKey)
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
    for (const r of this.sql.exec<{ session_id: string }>(`SELECT session_id FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId).toArray())
      this.sessions.delete(r.session_id)
    this.sql.exec(`DELETE FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId)
    // A removed phone's replies never reach a Mac, and a removed Mac's queue goes with it.
    this.sql.exec(`DELETE FROM mailbox WHERE mac = ? OR from_device = ?`, deviceId, deviceId)
  }

  /**
   * Push coalescing (PROTOCOL.md notify): whether a turn-ending push under `key` (src/push.ts `turnPushKey`) may
   * go now, at most one per `windowMs`. Here and not in a Workers rate limit, which counts per location and lags:
   * a burst passed it whole in the 2026-10-21 check.
   */
  async turnPushAllowed(ownerKey: string, key: string, windowMs: number): Promise<boolean> {
    this.bind(ownerKey)
    const now = Date.now()
    this.sql.exec(`DELETE FROM turn_pushes WHERE at <= ?`, now - windowMs)
    if (this.sql.exec(`SELECT 1 FROM turn_pushes WHERE key = ?`, key).toArray().length > 0) return false
    this.sql.exec(`INSERT INTO turn_pushes (key, at) VALUES (?, ?)`, key, now)
    return true
  }

  /** Account data deletion (`DELETE /v1/me`): close every socket with 4002 `removed` and wipe this hub. */
  async purge(ownerKey: string): Promise<void> {
    this.bind(ownerKey)
    for (const ws of this.ctx.getWebSockets()) {
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(4002, "removed")
      } catch {}
    }
    this.live.clear()
    this.sessions.clear()
    this.members.clear()
    for (const t of ["macs", "devices", "sessions", "meta", "forgotten", "turn_pushes", "mailbox"]) this.sql.exec(`DELETE FROM ${t}`)
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
    if (owner !== undefined && this.isUserHubOf(owner)) return { closed: 0 }
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

  /** The colo this hub runs in (diagnostics: a hub stays where it was first created). */
  async placement(ownerKey: string): Promise<{ colo: string | null }> {
    this.bind(ownerKey)
    if (this.env.ENVIRONMENT === "test") return { colo: null }
    if (this.colo === undefined) {
      try {
        const trace = await (await fetch("https://www.cloudflare.com/cdn-cgi/trace")).text()
        this.colo = /^colo=(\w+)$/m.exec(trace)?.[1] ?? null
      } catch {
        return { colo: null }
      }
    }
    return { colo: this.colo }
  }

  /** The owner's Macs with presence; only one team's when `teamId` is given. */
  async macs(ownerKey: string, teamId?: string): Promise<Array<MacPresence>> {
    this.bind(ownerKey)
    return this.macList(teamId)
  }

  // ---- Reply mailbox (PROTOCOL.md "Sealed pushes and the reply mailbox") ------------------------------

  /** Drops rows past `keep_until` (lazily, on every mailbox call and Mac connect). */
  private mailboxSweep(now: number) {
    this.sql.exec(`DELETE FROM mailbox WHERE keep_until <= ?`, now)
  }

  /**
   * Queues a sealed reply for `item.mac` (the Worker checked that the caller owns both devices): delivered at
   * once when the Mac's socket is open, else right after its next `hello`. The same id with the same blob is
   * the same item (a retried request); with another blob it is a conflict. At most MAILBOX_PENDING_LIMIT wait
   * per Mac. `ttlMs` is MAILBOX_TTL_MS outside tests.
   */
  async mailboxPost(ownerKey: string, item: MailboxItem, ttlMs: number = MAILBOX_TTL_MS): Promise<MailboxPost> {
    this.bind(ownerKey)
    const now = Date.now()
    this.mailboxSweep(now)
    const existing = this.sql.exec<{ mac: string; from_device: string; sealed: string; state: string }>(`SELECT mac, from_device, sealed, state FROM mailbox WHERE id = ?`, item.id).toArray()[0]
    if (existing) {
      if (existing.mac !== item.mac || existing.from_device !== item.from || (existing.state === "queued" && existing.sealed !== item.sealed)) return { error: "conflict" }
      return { queued: true, delivered: false }
    }
    const pending = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM mailbox WHERE mac = ? AND state = 'queued' AND expires_at > ?`, item.mac, now).toArray()[0]?.n ?? 0
    if (pending >= MAILBOX_PENDING_LIMIT) return { error: "full" }
    const expiresAt = now + ttlMs
    this.sql.exec(
      `INSERT INTO mailbox (id, mac, from_device, sealed, at, expires_at, keep_until, state) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued')`,
      item.id,
      item.mac,
      item.from,
      item.sealed,
      now,
      expiresAt,
      // The outcome stays readable for one more full window, whatever this item's own time to live.
      expiresAt + MAILBOX_TTL_MS
    )
    const ws = this.open(item.mac)
    if (!ws) return { queued: true, delivered: false }
    try {
      ws.send(JSON.stringify({ type: "mailbox", items: [{ id: item.id, from: item.from, sealed: item.sealed, at: now }] }))
      return { queued: true, delivered: true }
    } catch {
      return { queued: true, delivered: false }
    }
  }

  /** The outcome of one item of `mac`, or null when there is none (never posted, or long gone). */
  async mailboxState(ownerKey: string, mac: string, id: string): Promise<MailboxState | null> {
    this.bind(ownerKey)
    const now = Date.now()
    this.mailboxSweep(now)
    const row = this.sql.exec<{ state: string; reason: string | null; expires_at: number; sig: string | null }>(
      `SELECT state, reason, expires_at, sig FROM mailbox WHERE id = ? AND mac = ?`,
      id,
      mac
    ).toArray()[0]
    if (!row) return null
    const sig = row.sig ? { sig: row.sig } : {}
    if (row.state === "applied") return { state: "applied", ...sig }
    if (row.state === "rejected") return { state: "rejected", reason: row.reason ?? "refused", ...sig }
    return row.expires_at <= now ? { state: "expired" } : { state: "queued" }
  }

  /** The Mac's queued, unexpired items, oldest first, sent on its socket after `hello`. */
  private deliverMailbox(ws: WebSocket, mac: string) {
    const now = Date.now()
    this.mailboxSweep(now)
    const items = this.sql
      .exec<{ id: string; from_device: string; sealed: string; at: number }>(
        `SELECT id, from_device, sealed, at FROM mailbox WHERE mac = ? AND state = 'queued' AND expires_at > ? ORDER BY at`,
        mac,
        now
      )
      .toArray()
      .map((r) => ({ id: r.id, from: r.from_device, sealed: r.sealed, at: r.at }))
    if (items.length) ws.send(JSON.stringify({ type: "mailbox", items }))
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
  }

  // ---- WebSocket -------------------------------------------------------------------------------

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 })
    let att = JSON.parse(req.headers.get("x-cmux-mobile-attachment") ?? "null") as Attachment | null
    // The Worker's fast path: only the caller's identity, device id and team; the device row is this hub's.
    const claim = JSON.parse(req.headers.get("x-cmux-mobile-claim") ?? "null") as { userId: string; projectId: string; deviceId: string; ownerKey: string; teamId: string } | null
    const ownerKey = claim?.ownerKey ?? req.headers.get("x-cmux-mobile-owner-key")
    if (!ownerKey) return new Response("missing owner", { status: 400 })
    try {
      this.bind(ownerKey)
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
      this.setAttach(old, { ...this.attach(old), replaced: true })
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [att.deviceId])
    this.setAttach(server, att)
    this.live.set(att.deviceId, server)
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
      if (f.type !== "signal") return this.error(ws, "bad_request", "unknown frame type")
      if (typeof f.to !== "string" || !UUID.test(f.to)) return this.error(ws, "bad_request", "to must be a deviceId")
      if (f.from !== undefined && f.from !== att.deviceId) return this.error(ws, "bad_request", "from must be your deviceId")
      if (typeof f.sessionId !== "string" || !UUID.test(f.sessionId)) return this.error(ws, "bad_request", "sessionId must be a UUID")
      // Named by session: a refused signal of one session must not fail the client's other dials.
      if (typeof f.payload !== "object" || f.payload === null || typeof f.payload.kind !== "string" || !SIGNAL_KINDS.has(f.payload.kind))
        return this.error(ws, "bad_request", "unknown payload kind", f.sessionId)
      if (!this.admit(att, f.to, f.sessionId)) return this.error(ws, "not_owner", "not allowed to signal this device", f.sessionId)
      const target = this.open(f.to)
      if (!target) return this.error(ws, "offline", "device is offline", f.sessionId)
      // fromUserId is always the verified sender (PROTOCOL.md); any client value is dropped.
      target.send(JSON.stringify({ type: "signal", to: f.to, from: att.deviceId, fromUserId: att.userId, sessionId: f.sessionId, payload: f.payload }))
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

  /** Whether this object is the hub named `user:<ownerKey>` (its id derives from its name). */
  private isUserHubOf(ownerKey: string): boolean {
    return this.env.TEAM_HUB.idFromName(userHubName(ownerKey)).equals(this.ctx.id)
  }

  /**
   * Binds this hub to its owner: the key must name this very object (`user:<ownerKey>`), so neither a routing bug
   * nor an older Worker calling a team hub can bind one, and once bound any other owner is refused.
   */
  private bind(ownerKey: unknown) {
    if (typeof ownerKey !== "string" || !ownerKey || !this.isUserHubOf(ownerKey)) throw new WrongHubError("not this user's hub")
    if (this.ownerKey === undefined)
      this.ownerKey = this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = 'owner'`).toArray()[0]?.value ?? null
    if (this.ownerKey === null) {
      this.sql.exec(`INSERT INTO meta (key, value) VALUES ('owner', ?)`, ownerKey)
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
    this.sql.exec(`DELETE FROM sessions WHERE created_at < ?`, now - SESSION_TTL_MS)
    this.sql.exec(`INSERT INTO sessions (session_id, initiator, responder, created_at) VALUES (?, ?, ?, ?)`, sessionId, att.deviceId, to, now)
    this.sessions.set(sessionId, { initiator: att.deviceId, responder: to })
    return true
  }

  private session(id: string): { initiator: string; responder: string } | undefined {
    const hit = this.sessions.get(id)
    if (hit) return hit
    const r = this.sql.exec<{ initiator: string; responder: string; created_at: number }>(`SELECT initiator, responder, created_at FROM sessions WHERE session_id = ?`, id).toArray()[0]
    if (!r || Date.now() - r.created_at > SESSION_TTL_MS) return undefined
    const s = { initiator: r.initiator, responder: r.responder }
    this.sessions.set(id, s)
    return s
  }

  private endSession(id: string) {
    this.sessions.delete(id)
    this.sql.exec(`DELETE FROM sessions WHERE session_id = ?`, id)
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
    return {
      deviceId,
      name: r.name,
      teamId: r.team_id ?? "",
      online: !!this.open(deviceId),
      lastSeenAt: r.last_seen_at ? new Date(r.last_seen_at).toISOString() : null,
      ownerUserId: r.owner_user_id,
      machineId: r.machine_id ?? null
    }
  }

  /** The presence frame body: PROTOCOL.md `{deviceId, name, online, lastSeenAt, machineId}`. */
  private presenceOf(deviceId: string) {
    const p = this.presence(deviceId)!
    return { deviceId: p.deviceId, name: p.name, online: p.online, lastSeenAt: p.lastSeenAt, ...(p.machineId ? { machineId: p.machineId } : {}) }
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
