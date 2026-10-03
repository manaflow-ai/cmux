import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { SWEEP_OBJECT, sweepFeedText, type SweepDeps, type SweepFeed } from "../src/feed-sweep.ts"

/**
 * The feed text sweep (feed-sweep.ts): a FeedDO that gets no request still loses text a stale
 * build wrote, an object without a feed stays unbound, and the pass resumes from its cursor.
 */
const testEnv = env as unknown as { FEED_DO: DurableObjectNamespace }
const stub = (name: string) => testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(name))
const STALE = "Deploy secret-project-zeta to prod"

/** A bound feed whose stored event and ledger reply still hold text (as a stale build wrote them). */
const staleFeed = async (user: string) => {
  // Bind the user's feed (creates its tables), as any request would.
  await (stub(user) as unknown as { debug(entity: string): Promise<unknown> }).debug(user)
  await runInDurableObject(stub(user), async (_instance: unknown, state) => {
    const seq = Number(state.storage.sql.exec("SELECT COALESCE(MAX(seq), 0) AS s FROM own_events").one().s) + 1
    state.storage.sql.exec(
      "INSERT INTO own_events (seq, tx, op, params, actor, origin, at, effects) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
      seq, `tx-${seq}`, "feed.post", JSON.stringify({ type: "notice", kind: "notice", title: STALE }), JSON.stringify({ identity: "x" }), "cli", 1
    )
    state.storage.sql.exec(
      "INSERT INTO own_ledger (identity, idempotency_key, tx, op, params_hash, ok, reply, sequence, revision, actor, origin, created_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)",
      "x", `k-${seq}`, `tx-${seq}`, "feed.post", "h", JSON.stringify({ t: "result", tx: `tx-${seq}`, idempotency_key: `k-${seq}`, value: { item: { id: "fi_1", title: STALE }, deduped: false }, revision: String(seq), replayed: false }), seq, String(seq), "{}", "cli", Date.now()
    )
  })
}

const stored = async (user: string) =>
  runInDurableObject(stub(user), async (_i: unknown, state) =>
    [...state.storage.sql.exec("SELECT params AS t FROM own_events").toArray(), ...state.storage.sql.exec("SELECT reply AS t FROM own_ledger").toArray()].map((r: any) => String(r.t)).join("\n")
  )

describe("feed text sweep", { timeout: 60_000 }, () => {
  it("scrubs feeds that get no request, leaves objects without a feed unbound, and resumes", async () => {
    const users = ["user_sweep_a", "user_sweep_b", "user_sweep_none"]
    await staleFeed("user_sweep_a")
    await staleFeed("user_sweep_b")
    expect(await stored("user_sweep_a")).toContain(STALE)
    let now = 1_000_000
    const listed: Array<string | null> = []
    const deps: SweepDeps = {
      listUsers: async (after, limit) => {
        listed.push(after)
        return users.filter((u) => after === null || u > after).sort().slice(0, Math.min(limit, 2))
      },
      feed: (name) => stub(name) as unknown as SweepFeed,
      now: () => now
    }
    const first = await sweepFeedText(deps)
    expect(first).toMatchObject({ skipped: false, users: 3, bound: 2, done: true })
    for (const u of ["user_sweep_a", "user_sweep_b"]) expect(await stored(u)).not.toContain(STALE)
    const unbound = await runInDurableObject(stub("user_sweep_none"), async (_i: unknown, state) => state.storage.sql.exec("SELECT COUNT(*) AS n FROM do_entity").one().n)
    expect(Number(unbound)).toBe(0)
    // Paged with a cursor: the second page starts after the last id of the first.
    expect(listed).toEqual([null, "user_sweep_b", "user_sweep_none"])
    // A finished pass waits a day; then it runs again from the start.
    expect(await sweepFeedText(deps)).toMatchObject({ skipped: true })
    now += 24 * 3600_000 + 1
    expect(await sweepFeedText(deps)).toMatchObject({ skipped: false, done: true })
    expect(await (stub(SWEEP_OBJECT) as unknown as SweepFeed).sweepState()).toMatchObject({ after: null })

  })

  it("moves past a feed whose scrub throws", async () => {
    let calls = 0
    const deps: SweepDeps = {
      listUsers: async (after) => (after === null ? ["user_bad", "user_ok"] : []),
      feed: (name) =>
        name === "user_bad"
          ? ({ scrubIfBound: async () => { calls += 1; throw new Error("broken object") } } as unknown as SweepFeed)
          : name === "user_ok"
            ? ({ scrubIfBound: async () => { calls += 1; return true } } as unknown as SweepFeed)
            : (stub("sweep:feed-text-throw-test") as unknown as SweepFeed),
      now: () => 5
    }
    expect(await sweepFeedText(deps)).toMatchObject({ users: 2, bound: 1, failed: 1, done: true })
    expect(calls).toBe(2)
  })
})
