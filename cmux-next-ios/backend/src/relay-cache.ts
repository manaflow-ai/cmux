/**
 * The relay's sealed snapshot cache and delta log (RFD 0142 R2 and R9; PROTOCOL.md "Relay snapshot seal" and "Relay
 * delta catch-up"), off unless `LINK_RELAY_SNAPSHOT=on`.
 *
 * A source (the Mac's hostd) seals its current state to each viewer's key (`cmux-relay-snapshot-v1`, the Rust crate
 * `cmux-tui/crates/cmux-relay-snapshot`) and puts it here; a viewer that cold-opens reads it from the edge while its
 * live link dials, so first content does not wait for the Mac (or for it to wake). The source also appends each
 * delta, sealed the same way on the stream `<stream>/delta`, and a viewer that resumes after sleep asks for every
 * delta after the position it holds, so it catches up from the edge without waking the Mac.
 *
 * One object per source device (`relayCacheRoomName`), so the cache outlives link sessions: a cold open has no session
 * yet. The relay holds ciphertext only and opens nothing: it reads the envelope's clear header (version, epoch, seq,
 * source key id, lengths) to order and bound what it keeps, exactly as `cmux_relay_snapshot::peek` does, and the
 * delta log keeps the rules of `cmux_relay_snapshot::delta::DeltaLog` (the Rust crate is the one implementation of
 * the seal; this file is its relay half, which runs in the Worker). A viewer checks the signature and refuses a stale
 * or out-of-order envelope, so a relay (or a forged put) can withhold state but never make a viewer accept an older
 * or a forged one.
 *
 * What the relay sees: per viewer and stream, the envelopes' sizes, positions and times, and which position a viewer
 * resumes after. Bounded: one snapshot per viewer and stream ([`SNAPSHOT_TTL_MS`]), at most [`DELTA_MAX_ENTRIES`]
 * deltas and [`DELTA_MAX_BYTES`] per log, each delta expiring [`DELTA_TTL_MS`] after it arrived, and at most
 * [`MAX_SLOTS`] viewer-and-stream slots per source.
 */

/** The envelope version byte (`cmux-relay-snapshot-v1`). */
const VERSION = 1
const KEY_ID_LEN = 32
const POINT_LEN = 65
const NONCE_LEN = 12
const TAG_LEN = 16
const SIGNATURE_LEN = 64
export const HEADER_LEN = 1 + 8 + 8 + KEY_ID_LEN + POINT_LEN + NONCE_LEN
const FIXED_LEN = HEADER_LEN + 4 + TAG_LEN + SIGNATURE_LEN

/** The seal's plaintext bound (`MAX_PLAINTEXT`, 256 KiB) plus the envelope's fixed bytes. */
export const ENVELOPE_MAX = 256 * 1024 + FIXED_LEN
/** The delta log's bounds and expiry (`delta::MAX_ENTRIES`, `MAX_LOG_BYTES`, `TTL_MS`). */
export const DELTA_MAX_ENTRIES = 512
export const DELTA_MAX_BYTES = 1024 * 1024
export const DELTA_TTL_MS = 10 * 60 * 1000
/** A snapshot is served for a day after its last put: a Mac asleep overnight still gives first content, "as of". */
export const SNAPSHOT_TTL_MS = 24 * 60 * 60 * 1000
/** Viewer-and-stream slots one source may fill (each holds one snapshot and one delta log). */
export const MAX_SLOTS = 32

const STREAM = /^[A-Za-z0-9._/-]{1,96}$/

export const validStream = (s: string): boolean => STREAM.test(s)

export interface Position {
  readonly epoch: bigint
  readonly seq: bigint
}

export interface Header {
  readonly position: Position
  /** Lowercase hex of the source identity key id. */
  readonly sourceKeyId: string
}

const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")

/** The clear header of a `cmux-relay-snapshot-v1` envelope, or null when it is malformed (`peek`'s checks). */
export const peek = (bytes: Uint8Array): Header | null => {
  if (bytes.length < FIXED_LEN || bytes[0] !== VERSION) return null
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const epoch = view.getBigUint64(1)
  const seq = view.getBigUint64(9)
  const ephemeralStart = 17 + KEY_ID_LEN
  const lengthStart = ephemeralStart + POINT_LEN + NONCE_LEN
  const length = view.getUint32(lengthStart)
  if (length < TAG_LEN || bytes.length !== lengthStart + 4 + length + SIGNATURE_LEN || bytes[ephemeralStart] !== 4) return null
  return { position: { epoch, seq }, sourceKeyId: hex(bytes.subarray(17, 17 + KEY_ID_LEN)) }
}

const cmp = (a: Position, b: Position): number => (a.epoch !== b.epoch ? (a.epoch < b.epoch ? -1 : 1) : a.seq === b.seq ? 0 : a.seq < b.seq ? -1 : 1)
const U64_MAX = (1n << 64n) - 1n
const next = (p: Position): Position | null => (p.seq === U64_MAX ? null : { epoch: p.epoch, seq: p.seq + 1n })

/** Positions as stored (bigint is not structured-cloneable in every runtime; decimal strings are). */
type StoredPos = readonly [string, string]
const store = (p: Position): StoredPos => [p.epoch.toString(), p.seq.toString()]
const load = (p: StoredPos): Position => ({ epoch: BigInt(p[0]), seq: BigInt(p[1]) })

interface StoredSnapshot {
  readonly pos: StoredPos
  readonly key: string
  readonly at: number
  readonly env: Uint8Array
}

interface LogEntry {
  readonly pos: StoredPos
  readonly at: number
  readonly len: number
}

interface StoredLog {
  readonly key: string | null
  readonly head: StoredPos | null
  readonly entries: readonly LogEntry[]
}

export type PutAnswer =
  | { readonly ok: true; readonly outcome: "stored" | "stale" | "added" | "restarted" | "duplicate"; readonly evicted?: number }
  | { readonly ok: false; readonly code: "malformed" | "too_large" | "wrong_source" | "full" }

export type CatchUp = { readonly type: "deltas"; readonly envelopes: Uint8Array[] } | { readonly type: "gap" }

/** A u64 as JSON: a number while it is exact, else its decimal string. */
type JsonU64 = number | string
const jsonU64 = (v: bigint): JsonU64 => (v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v.toString())

export interface CatchUpReply {
  readonly fromRelay: true
  readonly surfaces: { readonly surface: string; readonly sealed: string[]; readonly head: { readonly epoch: JsonU64; readonly seq: JsonU64 } }[]
  readonly cut: string[]
}

const b64url = (b: Uint8Array): string => {
  let s = ""
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000))
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** A position from JSON (`{epoch, seq}`, each a non-negative integer or its decimal string), or null. */
export const parsePosition = (v: unknown): Position | null => {
  if (!v || typeof v !== "object") return null
  const o = v as Record<string, unknown>
  const u64 = (x: unknown): bigint | null => {
    if (typeof x === "number" && Number.isSafeInteger(x) && x >= 0) return BigInt(x)
    if (typeof x === "string" && /^\d{1,20}$/.test(x)) {
      const n = BigInt(x)
      return n <= U64_MAX ? n : null
    }
    return null
  }
  const epoch = u64(o.epoch)
  const seq = u64(o.seq)
  return epoch === null || seq === null ? null : { epoch, seq }
}

const slot = (viewer: string, stream: string) => `${viewer}:${stream}`
const snapKey = (s: string) => `snap:${s}`
const logKey = (s: string) => `dlog:${s}`
const entryKey = (s: string, p: StoredPos) => `dent:${s}:${BigInt(p[0]).toString(16).padStart(16, "0")}:${BigInt(p[1]).toString(16).padStart(16, "0")}`
const SLOTS_KEY = "cacheslots"

/** The cache over one source's LinkRelay storage (a room named by `relayCacheRoomName`). */
export class RelayCache {
  constructor(private readonly storage: DurableObjectStorage) {}

  private async claim(s: string): Promise<boolean> {
    const slots = (await this.storage.get<string[]>(SLOTS_KEY)) ?? []
    if (slots.includes(s)) return true
    if (slots.length >= MAX_SLOTS) return false
    await this.storage.put(SLOTS_KEY, [...slots, s])
    return true
  }

  /** Keep `env` as `viewer`'s snapshot of `stream` if it is newer than the one held (a source re-key replaces it). */
  async putSnapshot(viewer: string, stream: string, env: Uint8Array, now: number): Promise<PutAnswer> {
    if (env.length > ENVELOPE_MAX) return { ok: false, code: "too_large" }
    const header = peek(env)
    if (!header) return { ok: false, code: "malformed" }
    const s = slot(viewer, stream)
    if (!(await this.claim(s))) return { ok: false, code: "full" }
    const held = await this.storage.get<StoredSnapshot>(snapKey(s))
    if (held && held.key === header.sourceKeyId && held.at + SNAPSHOT_TTL_MS > now && cmp(header.position, load(held.pos)) <= 0) {
      return { ok: true, outcome: "stale" }
    }
    const value: StoredSnapshot = { pos: store(header.position), key: header.sourceKeyId, at: now, env }
    await this.storage.put(snapKey(s), value)
    await this.arm(now + SNAPSHOT_TTL_MS)
    return { ok: true, outcome: "stored" }
  }

  /** `viewer`'s snapshot of `stream`, unexpired, with when it was put. */
  async snapshot(viewer: string, stream: string, now: number): Promise<{ env: Uint8Array; at: number } | null> {
    const held = await this.storage.get<StoredSnapshot>(snapKey(slot(viewer, stream)))
    if (!held || held.at + SNAPSHOT_TTL_MS <= now) return null
    return { env: held.env, at: held.at }
  }

  private async log(s: string): Promise<StoredLog> {
    return (await this.storage.get<StoredLog>(logKey(s))) ?? { key: null, head: null, entries: [] }
  }

  /** Drop entries that expired; returns the kept entries and the keys to delete. */
  private expire(entries: readonly LogEntry[], s: string, now: number): { kept: LogEntry[]; dead: string[] } {
    // Oldest first in the log's order: `DeltaLog::expire` stops at the first unexpired entry.
    let cut = entries.findIndex((e) => now - e.at < DELTA_TTL_MS)
    if (cut < 0) cut = entries.length
    return { kept: entries.slice(cut), dead: entries.slice(0, cut).map((e) => entryKey(s, e.pos)) }
  }

  private async deleteAll(keys: string[]) {
    for (let i = 0; i < keys.length; i += 128) await this.storage.delete(keys.slice(i, i + 128))
  }

  /** `DeltaLog::append`: add after the head, restart on a hole or a new epoch, ignore a retry. */
  async appendDelta(viewer: string, stream: string, env: Uint8Array, now: number): Promise<PutAnswer> {
    if (env.length > ENVELOPE_MAX) return { ok: false, code: "too_large" }
    const header = peek(env)
    if (!header) return { ok: false, code: "malformed" }
    const s = slot(viewer, stream)
    if (!(await this.claim(s))) return { ok: false, code: "full" }
    const log = await this.log(s)
    if (log.key !== null && log.key !== header.sourceKeyId) return { ok: false, code: "wrong_source" }
    const { kept, dead } = this.expire(log.entries, s, now)
    const head = log.head ? load(log.head) : null
    if (head && cmp(header.position, head) <= 0) {
      if (dead.length) {
        await this.deleteAll(dead)
        await this.storage.put(logKey(s), { ...log, entries: kept })
      }
      return { ok: true, outcome: "duplicate" }
    }
    const after = head ? next(head) : null
    const contiguous = after !== null && cmp(after, header.position) === 0
    let entries = kept
    let restarted: number | undefined
    if (head && !contiguous) {
      restarted = entries.length
      dead.push(...entries.map((e) => entryKey(s, e.pos)))
      entries = []
    }
    const pos = store(header.position)
    entries.push({ pos, at: now, len: env.length })
    let bytes = entries.reduce((n, e) => n + e.len, 0)
    let evicted = 0
    while (entries.length > DELTA_MAX_ENTRIES || bytes > DELTA_MAX_BYTES) {
      const old = entries.shift()
      if (!old) break
      bytes -= old.len
      dead.push(entryKey(s, old.pos))
      evicted += 1
    }
    const value: StoredLog = { key: header.sourceKeyId, head: pos, entries }
    const stillHeld = entries.some((e) => e.pos === pos)
    await this.storage.put(stillHeld ? { [logKey(s)]: value, [entryKey(s, pos)]: env } : { [logKey(s)]: value })
    await this.deleteAll(dead.filter((k) => k !== entryKey(s, pos) || !stillHeld))
    await this.arm(now + DELTA_TTL_MS)
    return restarted !== undefined ? { ok: true, outcome: "restarted", evicted: restarted } : { ok: true, outcome: "added", evicted }
  }

  /** `DeltaLog::catch_up`: every delta after `after`, contiguously, or a gap. Never a partial run. */
  async catchUp(viewer: string, stream: string, after: Position, now: number): Promise<CatchUp> {
    const s = slot(viewer, stream)
    const log = await this.log(s)
    if (!log.head) return { type: "gap" }
    const head = load(log.head)
    if (cmp(after, head) === 0) return { type: "deltas", envelopes: [] }
    if (cmp(after, head) > 0 || after.epoch !== head.epoch) return { type: "gap" }
    const first = next(after)
    if (!first) return { type: "gap" }
    const { kept } = this.expire(log.entries, s, now)
    const start = kept.findIndex((e) => cmp(load(e.pos), first) === 0)
    if (start < 0) return { type: "gap" }
    const keys = kept.slice(start).map((e) => entryKey(s, e.pos))
    const envelopes: Uint8Array[] = []
    for (let i = 0; i < keys.length; i += 128) {
      const got = await this.storage.get<Uint8Array>(keys.slice(i, i + 128))
      for (const k of keys.slice(i, i + 128)) {
        const env = got.get(k)
        // An entry the log lists but storage lost: serve nothing rather than a run with a hole.
        if (!env) return { type: "gap" }
        envelopes.push(env)
      }
    }
    return { type: "deltas", envelopes }
  }

  /**
   * The phone's catch-up in one request (the reply `cmux-mobile-core::catch_up` reads with `fromRelay`): for each
   * surface, every delta after the position the viewer holds, and the head they reach; a gap or a surface the relay
   * holds nothing for goes in `cut` (the phone asks the Mac for those on wake). `budgetBytes` cuts whole surfaces in
   * the order asked, never part of one.
   */
  async catchUpMany(viewer: string, asks: readonly { surface: string; after: Position }[], budgetBytes: number, now: number): Promise<CatchUpReply> {
    const surfaces: CatchUpReply["surfaces"][number][] = []
    const cut: string[] = []
    let left = budgetBytes
    for (const ask of asks) {
      const got = await this.catchUp(viewer, ask.surface, ask.after, now)
      if (got.type === "gap") {
        cut.push(ask.surface)
        continue
      }
      const size = got.envelopes.reduce((n, e) => n + e.length, 0)
      if (size > left) {
        cut.push(ask.surface)
        continue
      }
      left -= size
      const head = got.envelopes.length ? (peek(got.envelopes[got.envelopes.length - 1]!)?.position ?? ask.after) : ask.after
      surfaces.push({ surface: ask.surface, sealed: got.envelopes.map(b64url), head: { epoch: jsonU64(head.epoch), seq: jsonU64(head.seq) } })
    }
    return { fromRelay: true, surfaces, cut }
  }

  /** `DeltaLog::drain_through`: the viewer acknowledged every delta through `through`. */
  async drainThrough(viewer: string, stream: string, through: Position): Promise<number> {
    const s = slot(viewer, stream)
    const log = await this.log(s)
    const cut = log.entries.findIndex((e) => cmp(load(e.pos), through) > 0)
    const n = cut < 0 ? log.entries.length : cut
    if (n === 0) return 0
    await this.deleteAll(log.entries.slice(0, n).map((e) => entryKey(s, e.pos)))
    await this.storage.put(logKey(s), { ...log, entries: log.entries.slice(n) })
    return n
  }

  /** Delete expired snapshots and deltas; returns the next expiry, if any. */
  async purge(now: number): Promise<number | undefined> {
    let next: number | undefined
    const slots = (await this.storage.get<string[]>(SLOTS_KEY)) ?? []
    const live: string[] = []
    for (const s of slots) {
      let used = false
      const snap = await this.storage.get<StoredSnapshot>(snapKey(s))
      if (snap) {
        if (snap.at + SNAPSHOT_TTL_MS <= now) await this.storage.delete(snapKey(s))
        else {
          used = true
          next = Math.min(next ?? Infinity, snap.at + SNAPSHOT_TTL_MS)
        }
      }
      const log = await this.storage.get<StoredLog>(logKey(s))
      if (log) {
        const { kept, dead } = this.expire(log.entries, s, now)
        if (dead.length) {
          await this.deleteAll(dead)
          await this.storage.put(logKey(s), { ...log, entries: kept })
        }
        const oldest = kept[0]
        if (oldest) {
          used = true
          next = Math.min(next ?? Infinity, oldest.at + DELTA_TTL_MS)
        } else if (!used) {
          // An empty log keeps its head only while the slot's snapshot is held; a slot with nothing left is freed.
          await this.storage.delete(logKey(s))
        }
      }
      if (used) live.push(s)
    }
    if (live.length !== slots.length) await this.storage.put(SLOTS_KEY, live)
    return next
  }

  private async arm(at: number) {
    const current = await this.storage.getAlarm()
    if (current === null || current > at) await this.storage.setAlarm(at)
  }
}

/** The length-prefixed body of a catch-up answer: each envelope behind its 4-byte big-endian length. */
export const frameEnvelopes = (envelopes: readonly Uint8Array[]): Uint8Array => {
  const total = envelopes.reduce((n, e) => n + 4 + e.length, 0)
  const out = new Uint8Array(total)
  const view = new DataView(out.buffer)
  let at = 0
  for (const e of envelopes) {
    view.setUint32(at, e.length)
    out.set(e, at + 4)
    at += 4 + e.length
  }
  return out
}

/** One cache room per source device, so the cache outlives link sessions (a cold open has no session yet). */
export const relayCacheRoomName = (ownerKey: string, space: string, sourceDevice: string) =>
  `${space ? `${space}|` : ""}relay-cache:${ownerKey}:${sourceDevice}`

/** The DO paths the Worker forwards a cache call to; nothing else reaches them. */
export const CACHE_PATH_PREFIX = "/cache/"
/** Set only by the Worker, after it checked the caller owns both devices. */
export const CACHE_VIEWER_HEADER = "x-cmux-cache-viewer"
export const CATCH_UP_BUDGET_DEFAULT = 64 * 1024
export const CATCH_UP_BUDGET_MAX = 256 * 1024
export const CATCH_UP_MAX_SURFACES = 64

const answer = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const refuse = (status: number, code: string) => answer({ error: { code } }, status)
const putStatus = (a: PutAnswer) => (a.ok ? 200 : a.code === "too_large" ? 413 : a.code === "full" ? 507 : a.code === "wrong_source" ? 409 : 400)

const readBody = async (req: Request): Promise<Uint8Array | null> => {
  const declared = Number(req.headers.get("content-length") ?? "0")
  if (declared > ENVELOPE_MAX) return null
  const body = new Uint8Array(await req.arrayBuffer())
  return body.length > ENVELOPE_MAX ? null : body
}

/**
 * The cache room's HTTP face (`LinkRelay.fetch` sends it every `/cache/` path). The viewer comes from the Worker's
 * header; the stream from `?stream=`. PUT/GET `snapshot`, POST `delta` (one envelope as the body), POST `catch-up`
 * (`{surfaces:[{surface, after}], budgetBytes}` -> `CatchUpReply`), POST `ack` (`{through}`).
 */
export const cacheFetch = async (cache: RelayCache, req: Request, path: string): Promise<Response> => {
  const url = new URL(req.url)
  const viewer = req.headers.get(CACHE_VIEWER_HEADER) ?? ""
  if (!viewer) return refuse(400, "no_viewer")
  const what = path.slice(CACHE_PATH_PREFIX.length)
  const now = Date.now()
  if (what === "catch-up" && req.method === "POST") {
    const b = (await req.json().catch(() => null)) as { surfaces?: unknown; budgetBytes?: unknown } | null
    if (!b || !Array.isArray(b.surfaces) || b.surfaces.length > CATCH_UP_MAX_SURFACES) return refuse(400, "bad_request")
    const asks: { surface: string; after: Position }[] = []
    for (const raw of b.surfaces as unknown[]) {
      const o = (raw ?? {}) as { surface?: unknown; after?: unknown }
      const after = parsePosition(o.after)
      if (typeof o.surface !== "string" || !validStream(o.surface) || !after) return refuse(400, "bad_request")
      asks.push({ surface: o.surface, after })
    }
    const budget = typeof b.budgetBytes === "number" && Number.isSafeInteger(b.budgetBytes) && b.budgetBytes > 0 ? Math.min(b.budgetBytes, CATCH_UP_BUDGET_MAX) : CATCH_UP_BUDGET_DEFAULT
    return answer(await cache.catchUpMany(viewer, asks, budget, now))
  }
  const stream = url.searchParams.get("stream") ?? ""
  if (!validStream(stream)) return refuse(400, "bad_stream")
  if (what === "snapshot" && req.method === "PUT") {
    const body = await readBody(req)
    if (!body) return refuse(413, "too_large")
    const a = await cache.putSnapshot(viewer, stream, body, now)
    return answer(a, putStatus(a))
  }
  if (what === "snapshot" && req.method === "GET") {
    const held = await cache.snapshot(viewer, stream, now)
    if (!held) return refuse(404, "no_snapshot")
    return new Response(held.env, { headers: { "content-type": "application/octet-stream", "x-cmux-cache-at": String(held.at) } })
  }
  if (what === "delta" && req.method === "POST") {
    const body = await readBody(req)
    if (!body) return refuse(413, "too_large")
    const a = await cache.appendDelta(viewer, stream, body, now)
    return answer(a, putStatus(a))
  }
  if (what === "ack" && req.method === "POST") {
    const b = (await req.json().catch(() => null)) as { through?: unknown } | null
    const through = parsePosition(b?.through)
    if (!through) return refuse(400, "bad_request")
    return answer({ drained: await cache.drainThrough(viewer, stream, through) })
  }
  return refuse(404, "not_found")
}
