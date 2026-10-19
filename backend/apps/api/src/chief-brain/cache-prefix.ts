/**
 * Where a request puts its cache marks, so it reads what an earlier request wrote (the reference
 * client's AskAI.keys / wait / lead, adapted to Bedrock).
 *
 * Bedrock reads a cache entry only at a mark of the request (no look-back; measured on staging
 * 2026-10-16). A request is a list of text pieces; it marks two of them:
 * - `write`: the end of the part the next request repeats (the view's last whole 4-line block), so
 *   that request can read it;
 * - `read`: the longest piece prefix an earlier request wrote and that is still live, so this
 *   request reads it instead of writing it again.
 * A prefix is named by a hash chain over its pieces. A request whose read point another call is
 * still writing waits for that call's first event (its entry exists from then on), as the
 * reference client's `AskAI.wait` does, instead of paying the same write in parallel.
 */

/** FNV-1a (32 bit) over `s`, from `h`. */
const fnv = (h: number, s: string): number => {
  let x = h >>> 0
  for (let k = 0; k < s.length; k++) {
    x ^= s.charCodeAt(k)
    x = Math.imul(x, 16777619) >>> 0
  }
  return x
}

/** The name of each piece prefix: element j names pieces 0..j (after `seed`: the model and anything before the pieces). */
export const prefixNames = (seed: string, pieces: ReadonlyArray<string>): string[] => {
  let a = fnv(2166136261, seed)
  let b = fnv(0x811c9dc5 ^ 0x5bd1e995, `${seed.length}:${seed}`)
  return pieces.map((p) => ((a = fnv(a, p)), (b = fnv(b ^ p.length, p)), `${a.toString(36)}.${b.toString(36)}`))
}

/** The index of the piece that ends the view's last whole block: the one before the piece ending in `</chat>` (-1: none). */
export const viewWrite = (pieces: ReadonlyArray<string>): number => {
  const end = pieces.findIndex((p) => p.endsWith("</chat>"))
  return end - 1
}

/** A rendered `<chat>` context cut as the turn view is (optchat-core block_pieces): the header, every 4 lines, then the rest with `</chat>`. */
export const blockPieces = (text: string): string[] => {
  const pieces: string[] = []
  let start = 0
  let lines = 0
  for (let k = text.indexOf("\n"); k >= 0 && k + 1 < text.length; k = text.indexOf("\n", k + 1)) {
    if (lines % 4 === 0) {
      pieces.push(text.slice(start, k + 1))
      start = k + 1
    }
    lines++
  }
  pieces.push(text.slice(start))
  // pi-ai drops a whitespace-only text block, which would shift every later mark index.
  return pieces.filter((p) => p.trim().length > 0)
}

export const ttlMs = (ttl: string | undefined): number => (ttl === "5m" ? 5 * 60_000 : 60 * 60_000)

/** The header that carries a request's mark indices (the first user message's blocks) to the Claude route's body conversion. */
export const CACHE_BLOCKS_HEADER = "x-cmux-cache-blocks"

export interface Entry {
  readonly h: string
  readonly at: number
}

/** Marks for one request: `read` (or none), `write`, and the names to record once it is sent. */
export interface Plan {
  readonly read: number | undefined
  readonly write: number
  readonly names: ReadonlyArray<string>
}

/** The read and write marks of `pieces` against `live` entry names: read is the longest live prefix. */
export const plan = (names: ReadonlyArray<string>, live: (h: string) => boolean, write: number): Plan => {
  let read: number | undefined
  for (let j = names.length - 1; j >= 0; j--) {
    if (live(names[j]!)) {
      read = j
      break
    }
  }
  return { read: read === write ? undefined : read, write, names }
}

/** The mark indices as the header value: the write mark first, then the read mark (none without a write point: the request has no view). */
export const marksHeader = (p: Plan): string => (p.write < 0 ? "" : [p.write, ...(p.read !== undefined && p.read >= 0 && p.read !== p.write ? [p.read] : [])].join(","))

/**
 * The turn side: entries kept in the brain object's storage (cb_config `cache.prefix`), so a turn after
 * an eviction (a gap) still marks where the last turn wrote. Records the request's write point and its
 * end (the next turn of an unchanged view and delta reads all of it), refreshes the entry it reads.
 */
export const turnPlan = (sql: SqlStorage, seed: string, pieces: ReadonlyArray<string>, ttl: number, now = Date.now()): Plan => {
  const raw = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'cache.prefix'`).toArray()[0]?.value
  let entries: Entry[] = []
  try {
    entries = raw ? (JSON.parse(raw) as Entry[]).filter((e) => typeof e?.h === "string" && typeof e?.at === "number") : []
  } catch {
    entries = []
  }
  entries = entries.filter((e) => now - e.at < ttl)
  const live = new Set(entries.map((e) => e.h))
  const names = prefixNames(seed, pieces)
  const p = plan(names, (h) => live.has(h), viewWrite(pieces))
  const touched = new Set([p.read, p.write, names.length - 1].filter((x): x is number => typeof x === "number" && x >= 0).map((j) => names[j]!))
  const next = [...[...touched].map((h) => ({ h, at: now })), ...entries.filter((e) => !touched.has(e.h))].slice(0, 16)
  sql.exec(`INSERT INTO cb_config (name, value) VALUES ('cache.prefix', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, JSON.stringify(next))
  return p
}

/**
 * The compactor side (in memory: compactions run inside one object): `AskAI.wait` + `lead`. `acquire`
 * waits while the request's longest known prefix is still being written by another call, then returns
 * the plan and a lead for its write point, which the call ends with `begun` (first stream event: the
 * entry exists) or `end` (failed: forget it).
 */
export class PrefixCache {
  private readonly entries = new Map<string, { at: number; ready: Promise<void> | null }>()

  constructor(private readonly ttl: number) {}

  /** At most this long for another call's first event; then this call goes without reading that prefix. */
  static readonly WAIT_MS = 20_000

  async acquire(names: ReadonlyArray<string>, write: number): Promise<{ plan: Plan; begun: () => void; end: () => void }> {
    const waited = new Set<string>()
    // One deadline for all waits of this call, however many writers it waits behind.
    const deadline = Date.now() + PrefixCache.WAIT_MS
    for (;;) {
      const now = Date.now()
      for (const [h, e] of this.entries) if (e.ready === null && now - e.at >= this.ttl) this.entries.delete(h)
      const known = [...names].reverse().find((h) => this.entries.has(h) && !waited.has(h))
      const got = known === undefined ? undefined : this.entries.get(known)
      // Another call is writing this prefix: wait for its first event (or its failure), then look again.
      if (known !== undefined && got?.ready && now < deadline) {
        waited.add(known)
        let timer: ReturnType<typeof setTimeout> | undefined
        await Promise.race([got.ready, new Promise<void>((r) => (timer = setTimeout(r, deadline - now)))]).finally(() => clearTimeout(timer))
        continue
      }
      const p = plan(names, (h) => this.entries.get(h)?.ready === null, write)
      // A read refreshes its entry (Bedrock restarts the entry's TTL on a hit).
      const read = p.read === undefined ? undefined : this.entries.get(names[p.read]!)
      if (read) read.at = now
      const h = write >= 0 ? names[write] : undefined
      if (!h || this.entries.has(h)) {
        if (h) this.entries.get(h)!.at = now
        return { plan: p, begun: () => undefined, end: () => undefined }
      }
      let free = () => undefined as void
      const own = { at: 0, ready: new Promise<void>((ok) => (free = ok)) as Promise<void> | null }
      this.entries.set(h, own)
      const begun = () => {
        if (own.ready === null) return
        own.ready = null
        own.at = Date.now()
        free()
      }
      const end = () => {
        if (own.ready === null) return
        this.entries.delete(h)
        own.ready = null
        free()
      }
      return { plan: p, begun, end }
    }
  }
}
