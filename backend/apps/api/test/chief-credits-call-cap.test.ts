import { env } from "cloudflare:workers"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import worker from "../src/index.ts"
import { CreditsGate } from "../src/chief-brain/credits-gate.ts"
import { userIdFor } from "../src/domains/user.ts"
import { post, testEnv, token } from "./setup/inference-person.ts"

/**
 * The per-chief call cap at the team meter (the guard after the staging credit drain of 2026-10-28,
 * where looping compactors made up to 365 paid calls a minute per chief). A chief over the cap gets
 * no hold, so no model call goes out, and the refusal says why and when to try again. It fails
 * closed: the cap is counted in the meter's own ledger, so a restarted brain cannot reset it.
 */
const KEY = "test-billing-levels-key-0123456789abcdef"
const runEnv = (extra: Record<string, string> = {}) => ({ ...env, CLOUD_API_ORIGIN: "https://api.test", ...extra }) as any
const MODEL = { id: "priced", name: "priced", api: "anthropic-messages", provider: "test", baseUrl: "https://x.test", reasoning: false, input: ["text"], cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 }, contextWindow: 200_000, maxTokens: 1000 } as any
const answered = (usd: number) => ({ role: "assistant", content: [{ type: "text", text: "ok" }], api: "anthropic-messages", provider: "test", model: "priced", stopReason: "stop", timestamp: Date.now(), usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: usd } } }) as any
const MESSAGES = [{ role: "user", content: [{ type: "text", text: "summarize" }] }]

const fundedTeam = async (stackUser: string) => {
  const t = await token(stackUser)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  const ctx = createExecutionContext()
  const res = await worker.fetch!(
    new Request("https://api.test/v1/internal/credits", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${KEY}` }, body: JSON.stringify({ action: "grant", stack_user: stackUser, usd: 5, actor: "test", reason: "call cap", key: `g-${stackUser}` }) }) as any,
    runEnv() as any,
    ctx
  )
  await waitOnExecutionContext(ctx)
  expect(res.status).toBe(200)
  return { team, user: userIdFor(testEnv.STACK_PROJECT_ID, stackUser) }
}

describe("per-chief model call cap", { timeout: 60_000 }, () => {
  it("refuses a chief's call over its per-minute cap with a clear error, and leaves other chiefs alone", async () => {
    const { team } = await fundedTeam("call-cap")
    const e = runEnv({ CHIEF_MODEL_CALLS_PER_MINUTE: "3", CHIEF_MODEL_CALLS_PER_HOUR: "100" })
    const loop = new CreditsGate(e, "brain-loop", () => ({ team, chief: "agent_loop", conversation: "conv_loop" }))
    // Three failing compactor calls ($0 each, as on staging) use up the minute.
    for (let k = 0; k < 3; k++) {
      expect(await loop.before(`compact:${k}`, MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
      await loop.after(`compact:${k}`, answered(0))
    }
    const refused = await loop.before("compact:3", MODEL, "claude-opus-5-5", MESSAGES)
    expect(refused).toMatchObject({ ok: false })
    const text = (refused as { refused?: string }).refused ?? ""
    expect(text).toMatch(/^rate_limited: chief agent_loop made 3 paid model calls in the last 60 s \(cap 3\); retry after \d+ s$/)

    // A restarted brain (a new gate, a new scope) is still over the cap: the count is the meter's.
    const restarted = new CreditsGate(e, "brain-loop-2", () => ({ team, chief: "agent_loop", conversation: "conv_loop" }))
    expect(await restarted.before("compact:4", MODEL, "claude-opus-5-5", MESSAGES)).toMatchObject({ ok: false })

    // Another chief of the same team still gets its calls.
    const other = new CreditsGate(e, "brain-other", () => ({ team, chief: "agent_other", conversation: "conv_other" }))
    expect(await other.before("turn:1", MODEL, "claude-opus-5-5", MESSAGES)).toEqual({ ok: true })
  })
})
