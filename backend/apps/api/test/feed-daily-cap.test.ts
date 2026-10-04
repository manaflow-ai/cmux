import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { describe, expect, it } from "vitest"

/**
 * DO audit 5.6: one install posts at most MAX_POSTS_PER_DAY feed items per day, so a runaway agent
 * cannot churn the event window. Enforced by FeedDO (the shared reducer and its vectors stay as they are).
 */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { FEED_DO: DurableObjectNamespace }
const U = "user_dailycap000000000000"
const agent = { identity: "inst_dmn00000000000000099", kind: "install", user: U, install: "inst_dmn00000000000000099", install_kind: "daemon", agent: "agent_a", grant_classes: ["read", "mutate-own", "execute"] }

describe("feed daily post cap", { timeout: 60_000 }, () => {
  it("refuses an install's post past the daily cap, retryable, and counts per install", async () => {
    const stub = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(U)) as any
    const post = (who: Record<string, unknown>, i: number) =>
      stub.submit(U, who, { t: "op", op: "feed.post", params: { type: "notice", kind: "notice", title: `n${i}` }, idempotency_key: `p${i}`, origin: "cli" })
    const first = await post(agent, 0)
    expect(first.frames.some((f: { t: string }) => f.t === "result")).toBe(true)
    await runInDurableObject(stub, async (i) => {
      i.maxPostsPerDay = 3
    })
    await post(agent, 1)
    await post(agent, 2)
    const over = await post(agent, 3)
    expect(over.frames.find((f: { t: string }) => f.t === "reject")).toMatchObject({ code: "feed.rate_limited", retryable: true })
    // A retry of an accepted key still answers from the ledger.
    expect((await post(agent, 1)).frames.find((f: { t: string }) => f.t === "result")).toMatchObject({ replayed: true })
    // Another install has its own count.
    const other = { ...agent, identity: "inst_dmn00000000000000098", install: "inst_dmn00000000000000098" }
    expect((await post(other, 10)).frames.some((f: { t: string }) => f.t === "result")).toBe(true)
  })
})
