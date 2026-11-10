import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import type { Principal } from "@cmux/ownership"

/**
 * A person's answer to a Cloud approval (G8) reaches the team's CloudDO while the answer is committed, not at FeedDO's
 * next alarm. The Mac retries its create with the same key right after feed.answer returns; an answer still waiting
 * for the alarm made that retry read approval.pending, and the Mac then slept its backoff (1, 2, 4, 8 s) before it saw
 * the machine (cmux-platform#875: "turned a few hundred ms into whole steps"). feed.answer now returns once the
 * CloudDO delivery ended or after a bounded wait, so the retry finds the approved run in flight or done.
 *
 * The integrations ConnectionDO keeps the alarm path: its targets read the PlanetScale projection, which the alarm
 * drains first (owner-outbox.ts).
 */
const testEnv = env as unknown as { FEED_DO: DurableObjectNamespace }
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

type Delivery = { readonly cls: string; readonly name: string; readonly source: string; readonly ops: ReadonlyArray<string>; readonly at: number }

/** A fake target namespace for `cls`: records every systemDeliver, answers after `hold` (when given). */
const fakeTargets = (deliveries: Array<Delivery>, hold?: () => Promise<void>) => (cls: string) => ({
  idFromName: (name: string) => name,
  get: (name: string) => ({
    systemDeliver: async (_entity: string, source: string, items: ReadonlyArray<{ id: number; op: string }>) => {
      if (hold) await hold()
      deliveries.push({ cls, name, source, ops: items.map((i) => i.op), at: Date.now() })
      return { done: items.map((i) => i.id) }
    },
  }),
})

const user = (n: string) => `user_${n.padEnd(20, "0").slice(0, 20)}`
const session = (u: string): Principal => ({ identity: `session:${u}`, kind: "session", user: u })

/** Posts one `source` approval for `team` into `u`'s feed and answers it allow as the person's session; returns the time the answer returned. */
const postAndAnswer = (u: string, team: string, source: "cloud" | "connections", deliveries: Array<Delivery>, hold?: () => Promise<void>) =>
  inDO(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u)), async (instance) => {
    instance.targetNamespace = fakeTargets(deliveries, hold)
    const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
    const prompt = { action: { type: "tool", tool: "cloud.machine.create", summary: "cloud.machine.create for new machine", risk: "money", input: { approval: { team, request, digest: "sha256:abc" } } }, scopes: ["once"] }
    const posted = await instance.integrationApproval(u, team, prompt, 3_600_000, `approval:${request}`, source)
    expect(posted.ok, JSON.stringify(posted)).toBe(true)
    const started = Date.now()
    const res = await instance.submit(u, session(u), { t: "op", op: "feed.answer", params: { item: posted.item, answer: { decision: "allow", scope: "once" } }, idempotency_key: `approve:${request}`, origin: "user" })
    expect(res.frames.some((f: { t: string }) => f.t === "result"), JSON.stringify(res.frames)).toBe(true)
    const returned = Date.now()
    // The answers still queued in this feed's outbox for an owner object (the alarm's work).
    const queued = (instance.boundEngine.outboxPending(1_000) as Array<{ kind: string; target?: { class: string } | null }>)
      .filter((r) => r.kind === "integration.approval.answered")
      .map((r) => r.target?.class ?? "")
    return { started, returned, queued }
  })

const answered = (d: ReadonlyArray<Delivery>, cls: string) => d.filter((x) => x.cls === cls && x.ops.includes("integration.approval.answered"))

describe("a Cloud approval answer reaches CloudDO at commit", { timeout: 60_000 }, () => {
  it("is delivered to the team's CloudDO before feed.answer returns, with no alarm, and once", async () => {
    const deliveries: Array<Delivery> = []
    const u = user("cloudanswer1")
    const { queued } = await postAndAnswer(u, "team_cloudanswer1", "cloud", deliveries)
    // No alarm fired yet: the delivery is the commit's own.
    expect(answered(deliveries, "CloudDO")).toEqual([{ cls: "CloudDO", name: "team_cloudanswer1", source: `feed:${u}`, ops: ["integration.approval.answered"], at: expect.any(Number) }])
    // Marked sent: the alarm finds nothing left to send again.
    expect(queued).toEqual([])
  })

  it("does not hold feed.answer past its bound when CloudDO is slow; the run's delivery still lands", async () => {
    const deliveries: Array<Delivery> = []
    let release!: () => void
    const held = new Promise<void>((r) => (release = r))
    const { started, returned } = await postAndAnswer(user("cloudanswer2"), "team_cloudanswer2", "cloud", deliveries, () => held)
    // Bounded (OwnerDO PROMPT_DRAIN_WAIT_MS, 2 s): an approved run that takes longer goes on after the answer returned.
    expect(returned - started).toBeGreaterThanOrEqual(1_500)
    expect(returned - started).toBeLessThan(5_000)
    expect(answered(deliveries, "CloudDO")).toHaveLength(0)
    release()
    for (let i = 0; i < 50 && answered(deliveries, "CloudDO").length === 0; i++) await new Promise((r) => setTimeout(r, 20))
    // At least once: the runtime's own alarm may send the still-queued row as well; CloudDO takes a repeated answer
    // once (cmux-platform approvals takeAnswer: a running or ended request ignores it).
    expect(answered(deliveries, "CloudDO").length).toBeGreaterThanOrEqual(1)
  })

  it("leaves an integrations answer queued for the alarm, behind the projection its ConnectionDO reads", async () => {
    const deliveries: Array<Delivery> = []
    const { queued } = await postAndAnswer(user("connanswer01"), "team_connanswer01", "connections", deliveries)
    expect(answered(deliveries, "ConnectionDO")).toHaveLength(0)
    expect(queued).toEqual(["ConnectionDO"])
  })
})
