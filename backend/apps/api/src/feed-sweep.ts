import type { Env } from "./env.ts"

/**
 * Feed text sweep (feed.md 4, privacy, coordinator option A 2026-10-03). A FeedDO scrubs its
 * stored text (event params, ledger replies) on bind, so an object that gets no request keeps
 * text a stale build wrote. This cron pass pages user ids from the Postgres projection and asks
 * each user's FeedDO to scrub if it holds a feed. It is idempotent (the scrub marks are
 * high-water marks) and resumable: the cursor lives in one reserved FeedDO object, and a full
 * pass repeats at most once a day.
 */
export const SWEEP_OBJECT = "sweep:feed-text"
export const SWEEP_PAGE = 200
const SWEEP_CONCURRENCY = 8
const SWEEP_BUDGET_MS = 10 * 60_000
const SWEEP_INTERVAL_MS = 24 * 3600_000

export interface SweepState {
  readonly after: string | null
  readonly completed_at: number | null
}

export interface SweepFeed {
  scrubIfBound(): Promise<boolean>
  sweepState(): Promise<SweepState>
  setSweepState(s: SweepState): Promise<void>
}

export interface SweepDeps {
  /** User ids greater than `after`, ascending, at most `limit`. */
  readonly listUsers: (after: string | null, limit: number) => Promise<ReadonlyArray<string>>
  readonly feed: (name: string) => SweepFeed
  readonly now: () => number
}

export interface SweepReport {
  readonly skipped: boolean
  readonly users: number
  readonly bound: number
  /** Feeds whose scrub threw; the pass moves on (one bad object never stops it). */
  readonly failed: number
  readonly done: boolean
}

export const sweepFeedText = async (deps: SweepDeps): Promise<SweepReport> => {
  const cursor = deps.feed(SWEEP_OBJECT)
  const start = deps.now()
  let state = await cursor.sweepState()
  if (state.after === null && state.completed_at !== null && start - state.completed_at < SWEEP_INTERVAL_MS) return { skipped: true, users: 0, bound: 0, failed: 0, done: false }
  let users = 0
  let bound = 0
  let failed = 0
  while (deps.now() - start < SWEEP_BUDGET_MS) {
    const page = await deps.listUsers(state.after, SWEEP_PAGE)
    if (page.length === 0) {
      state = { after: null, completed_at: deps.now() }
      await cursor.setSweepState(state)
      return { skipped: false, users, bound, failed, done: true }
    }
    for (let i = 0; i < page.length; i += SWEEP_CONCURRENCY) {
      const results = await Promise.allSettled(page.slice(i, i + SWEEP_CONCURRENCY).map((id) => deps.feed(id).scrubIfBound()))
      bound += results.filter((r) => r.status === "fulfilled" && r.value).length
      failed += results.filter((r) => r.status === "rejected").length
    }
    users += page.length
    state = { after: page[page.length - 1]!, completed_at: state.completed_at }
    await cursor.setSweepState(state)
  }
  return { skipped: false, users, bound, failed, done: false }
}

/** Production wiring: user ids from the projection, FeedDO stubs by user id. */
export const sweepDeps = (env: Env): SweepDeps => ({
  listUsers: async (after, limit) => {
    if (env.PROJECTION_READS === "mysql") return listUsersMysql(env, after, limit)
    // The writer role: the read-only role may not read users (staging, 2026-10-03: "permission denied for table users").
    const hyperdrive = env.HYPERDRIVE ?? env.HYPERDRIVE_RO
    if (!hyperdrive) throw new Error("HYPERDRIVE binding missing")
    const { default: pg } = await import("pg")
    const client = new pg.Client({ connectionString: hyperdrive.connectionString, statement_timeout: 10_000, query_timeout: 15_000, connectionTimeoutMillis: 10_000 })
    await client.connect()
    try {
      const r = await client.query<{ id: string }>("SELECT id FROM users WHERE ($1::text IS NULL OR id > $1) ORDER BY id LIMIT $2", [after, limit])
      return r.rows.map((row) => row.id)
    } finally {
      await client.end()
    }
  },
  feed: (name) => env.FEED_DO.get(env.FEED_DO.idFromName(name)) as unknown as SweepFeed,
  now: () => Date.now()
})

/** The same page from the PlanetScale MySQL projection (after the verified cutover). */
export const listUsersMysql = async (env: Env, after: string | null, limit: number): Promise<Array<string>> => {
  const target = env.PS_MYSQL_RO ?? env.PS_MYSQL
  if (!target) throw new Error("PS_MYSQL binding missing")
  const { connectMysql } = await import("./mysql-connect.ts")
  const client = await connectMysql(target)
  try {
    const [rows] = (await client.query("SELECT /*+ MAX_EXECUTION_TIME(10000) */ id FROM users WHERE (? IS NULL OR id > ?) ORDER BY id LIMIT ?", [after, after, limit])) as [Array<{ id: string }>]
    return rows.map((r) => r.id)
  } finally {
    await client.end().catch(() => undefined)
  }
}
