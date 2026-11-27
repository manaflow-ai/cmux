/**
 * The hub's central relay region pick (RFD 0142 O2, after Google Espresso): glue to the Rust crate
 * `cmux-region-pick` (`rust/crates/cmux-region-pick`), built to `region-pick-wasm/region_pick.wasm`.
 *
 * `relayPlacement` (placement.ts) estimates a relay's round trip through each region from the two ends'
 * locations. It cannot see a carrier that backhauls far away or a bad peering path. The user's TeamHub knows
 * what each relayed link actually did (the phone's `link_stat`), so with `LINK_RELAY_CENTRAL_PICK=on` it keeps a
 * learned round trip per network pair (`pairKey`: both ends' AS number and ingress colo) and region, and asks the
 * Rust pick where the pair's next relay goes. All of the logic is in Rust; this file only moves numbers.
 */
import wasmModule from "./region-pick-wasm/region_pick.wasm"
import { REGIONS, type Region, costTo } from "./placement.ts"
import type { Ingress } from "./team-hub.ts"

/** The buffer layout version the glue speaks (`rust/crates/cmux-region-pick/src/wasm.rs` `ABI`). */
export const REGION_PICK_ABI = 1
const N = REGIONS.length
const IO_LEN = 32

interface Exports {
  memory: WebAssembly.Memory
  rp_abi(): number
  rp_io(): number
  rp_pick(): void
  rp_observe_ms(prevMs: number, prevN: number, sample: number): number
}

let instance: Exports | null | undefined
/** The wasm, instantiated once per isolate; null when it is missing or speaks another layout (then: no pick). */
const wasm = (): Exports | null => {
  if (instance !== undefined) return instance
  try {
    const e = new WebAssembly.Instance(wasmModule, {}).exports as unknown as Exports
    instance = e.rp_abi() === REGION_PICK_ABI ? e : null
  } catch {
    instance = null
  }
  return instance
}

/** What the hub learned for one region of one pair. */
export interface Learned {
  readonly ms: number
  readonly n: number
}

export type PickBy = "measured" | "calibrated" | "fallback"

export interface CentralPick {
  readonly region: Region | undefined
  readonly by: PickBy
  /** The pick's score (ms), learned or estimated; absent for a fallback. */
  readonly ms?: number
}

/**
 * A user network pair's key: the phone's and the Mac's `asn@colo`, the phone first. Undefined when either end
 * lacks an AS number or colo (no key: the pick is not used). Names no user or device, and the hub keeps it per
 * user only.
 */
export const pairKey = (phone: Ingress | null | undefined, mac: Ingress | null | undefined): string | undefined => {
  const end = (i: Ingress | null | undefined) => (i && typeof i.asn === "number" && i.asn > 0 && i.colo ? `${i.asn}@${i.colo}` : undefined)
  const a = end(phone)
  const b = end(mac)
  return a && b ? `${a}>${b}` : undefined
}

/** `relayPlacement`'s per-region estimate, joiner leg plus peer leg (undefined where an end is unknown). */
export const estimates = (joiner: Ingress | null | undefined, peer: Ingress | null | undefined): (number | undefined)[] =>
  REGIONS.map((r) => {
    const a = costTo(joiner, r)
    const b = costTo(peer, r)
    return a === undefined || b === undefined ? undefined : a + b
  })

const indexOf = (r: string | undefined): number => (r === undefined ? -1 : (REGIONS as readonly string[]).indexOf(r))

/**
 * Where the pair's next relay goes: `fallback` (the placement's own pick) when nothing is learned or the wasm is
 * unavailable, else the Rust pick over `estimate` and `learned` with hysteresis around `current`.
 */
export const centralPick = (
  estimate: readonly (number | undefined)[],
  learned: Readonly<Partial<Record<Region, Learned>>>,
  current: Region | undefined,
  fallback: Region | undefined
): CentralPick => {
  const e = wasm()
  if (!e) return { region: fallback, by: "fallback" }
  const io = new Float64Array(e.memory.buffer, e.rp_io(), IO_LEN)
  for (let r = 0; r < N; r++) {
    const est = estimate[r]
    io[r] = est === undefined ? Number.NaN : est
    const l = learned[REGIONS[r]!]
    io[N + r] = l ? l.ms : Number.NaN
    io[2 * N + r] = l ? l.n : 0
  }
  io[3 * N] = indexOf(current)
  io[3 * N + 1] = indexOf(fallback)
  e.rp_pick()
  const at = io[3 * N + 2]!
  const by = io[3 * N + 3]!
  const ms = io[3 * N + 4]!
  const region = at >= 0 ? REGIONS[at] : undefined
  if (by === 2) return { region, by: "fallback" }
  return { region, by: by === 0 ? "measured" : "calibrated", ms: Number.isFinite(ms) ? Math.round(ms) : undefined }
}

/** `prev` with one more relay round-trip sample (ms); `prev` itself when the sample is refused or the wasm is unavailable. */
export const observe = (prev: Learned | undefined, sample: number): Learned | undefined => {
  const e = wasm()
  if (!e) return prev
  const ms = e.rp_observe_ms(prev ? prev.ms : Number.NaN, prev ? prev.n : 0, sample)
  return Number.isFinite(ms) ? { ms, n: (prev ? prev.n : 0) + 1 } : prev
}

/** At most this many network pairs are kept per user; past it the least recently seen go. */
export const REGION_PAIRS_MAX = 64
/** A learned round trip older than this is forgotten (networks and peering change). */
export const REGION_RTT_TTL_MS = 7 * 86_400_000
/** A phone's `link_stat` is credited to its relay's region only within this long of the placement. */
export const PLACEMENT_CREDIT_MS = 30 * 60_000
/** A `link_stat` window credits a region only with at least this many round trip samples. */
export const MIN_RTT_SAMPLES = 3
const PLACED_DEVICES_MAX = 1024

interface Placed {
  readonly pair: string
  readonly region: Region
  readonly at: number
}

/**
 * One user's learned relay round trips (in the TeamHub's SQLite, created only once the switch is on) and the
 * placements its phones' `link_stat`s are credited to (memory only: a wake forgets, which costs a few samples).
 */
export class RegionLearner {
  private ready = false
  private readonly placed = new Map<string, Placed[]>()

  constructor(private readonly sql: SqlStorage) {}

  /** After the hub's storage was deleted (`retireTeamHub`): the tables are made again on next use. */
  reset() {
    this.ready = false
    this.placed.clear()
  }

  private tables() {
    if (this.ready) return
    this.sql.exec(`CREATE TABLE IF NOT EXISTS region_rtt (pair TEXT NOT NULL, region TEXT NOT NULL, ms REAL NOT NULL, n INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (pair, region))`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS region_pick (pair TEXT PRIMARY KEY, region TEXT NOT NULL, at INTEGER NOT NULL)`)
    this.ready = true
  }

  /** What was learned for `pair`, fresher than `REGION_RTT_TTL_MS`. */
  learned(pair: string, now = Date.now()): Partial<Record<Region, Learned>> {
    this.tables()
    const out: Partial<Record<Region, Learned>> = {}
    for (const r of this.sql.exec<{ region: string; ms: number; n: number }>(`SELECT region, ms, n FROM region_rtt WHERE pair = ? AND at >= ?`, pair, now - REGION_RTT_TTL_MS)) {
      if ((REGIONS as readonly string[]).includes(r.region)) out[r.region as Region] = { ms: r.ms, n: r.n }
    }
    return out
  }

  /**
   * The region for a new relay between `phone` and `mac`: the central pick when the pair has a key, else
   * `fallback`. Remembers the placement for the phone's `link_stat`s and the pick for the pair's next session.
   */
  place(phoneId: string, phone: Ingress | null | undefined, mac: Ingress | null | undefined, joiner: Ingress | null | undefined, peer: Ingress | null | undefined, fallback: Region | undefined, now = Date.now()): CentralPick & { readonly pair?: string } {
    const pair = pairKey(phone, mac)
    if (!pair) return { region: fallback, by: "fallback" }
    this.tables()
    const current = this.sql.exec<{ region: string }>(`SELECT region FROM region_pick WHERE pair = ? AND at >= ?`, pair, now - REGION_RTT_TTL_MS).toArray()[0]?.region
    const picked = centralPick(estimates(joiner, peer), this.learned(pair, now), current && (REGIONS as readonly string[]).includes(current) ? (current as Region) : undefined, fallback)
    if (picked.region) {
      if (picked.by !== "fallback") this.sql.exec(`INSERT OR REPLACE INTO region_pick (pair, region, at) VALUES (?, ?, ?)`, pair, picked.region, now)
      if (this.placed.size >= PLACED_DEVICES_MAX && !this.placed.has(phoneId)) this.placed.clear()
      const kept = (this.placed.get(phoneId) ?? []).filter((p) => now - p.at <= PLACEMENT_CREDIT_MS).slice(-7)
      kept.push({ pair, region: picked.region, at: now })
      this.placed.set(phoneId, kept)
    }
    return { ...picked, pair }
  }

  /**
   * A phone's relayed round trip (`link_stat` p50 over `n` samples): credited to its relay's region when every
   * placement of that phone in the last `PLACEMENT_CREDIT_MS` was the same pair and region (otherwise which relay
   * the stat measured is unknown, and it is not used). Returns the region credited.
   */
  credit(phoneId: string, p50: number, n: number, now = Date.now()): Region | undefined {
    if (n < MIN_RTT_SAMPLES || !Number.isFinite(p50)) return undefined
    const recent = (this.placed.get(phoneId) ?? []).filter((p) => now - p.at <= PLACEMENT_CREDIT_MS)
    const first = recent[0]
    if (!first || recent.some((p) => p.pair !== first.pair || p.region !== first.region)) return undefined
    this.tables()
    const prev = this.sql.exec<{ ms: number; n: number; at: number }>(`SELECT ms, n, at FROM region_rtt WHERE pair = ? AND region = ?`, first.pair, first.region).toArray()[0]
    const was = prev && now - prev.at <= REGION_RTT_TTL_MS ? { ms: prev.ms, n: prev.n } : undefined
    const next = observe(was, p50)
    if (!next || next === was) return undefined
    this.sql.exec(`INSERT OR REPLACE INTO region_rtt (pair, region, ms, n, at) VALUES (?, ?, ?, ?, ?)`, first.pair, first.region, next.ms, Math.min(next.n, 1_000_000), now)
    this.prune(now)
    return first.region
  }

  private prune(now: number) {
    this.sql.exec(`DELETE FROM region_rtt WHERE at < ?`, now - REGION_RTT_TTL_MS)
    this.sql.exec(`DELETE FROM region_pick WHERE at < ?`, now - REGION_RTT_TTL_MS)
    const pairs = this.sql.exec<{ c: number }>(`SELECT COUNT(DISTINCT pair) AS c FROM region_rtt`).one().c
    if (pairs <= REGION_PAIRS_MAX) return
    this.sql.exec(
      `DELETE FROM region_rtt WHERE pair IN (SELECT pair FROM region_rtt GROUP BY pair ORDER BY MAX(at) ASC LIMIT ?)`,
      pairs - REGION_PAIRS_MAX
    )
    this.sql.exec(`DELETE FROM region_pick WHERE pair NOT IN (SELECT DISTINCT pair FROM region_rtt)`)
  }

  /** Learned rows and picks (tests and diagnostics). */
  rows(): { rtt: { pair: string; region: string; ms: number; n: number }[]; picks: { pair: string; region: string }[] } {
    this.tables()
    return {
      rtt: this.sql.exec<{ pair: string; region: string; ms: number; n: number }>(`SELECT pair, region, ms, n FROM region_rtt ORDER BY pair, region`).toArray(),
      picks: this.sql.exec<{ pair: string; region: string }>(`SELECT pair, region FROM region_pick ORDER BY pair`).toArray()
    }
  }
}
