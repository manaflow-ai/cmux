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

/**
 * The wait is the answered item's own (review F1 on #40370): an answer that sends nothing to CloudDO (an agent's
 * approve, an integrations approval) returns at once, even while another Cloud answer's slow delivery is in flight.
 */
describe("only a Cloud answer waits, and only for its own delivery", { timeout: 60_000 }, () => {
  const agentPost = { type: "request", kind: "approve", title: "Claude Code needs permission", prompt: { action: { type: "command", summary: "Build", command: "npm run build" }, scopes: ["once", "session"] }, poster: { agent: "term_1", harness: "claude-code", label: "Claude Code · api" } }

  for (const other of ["agent", "connections"] as const)
    it(`${other === "agent" ? "an agent" : "an integrations"} answer during a slow Cloud delivery returns without the Cloud wait`, async () => {
      const u = user(`slowcloud${other}`)
      const deliveries: Array<Delivery> = []
      let release!: () => void
      const held = new Promise<void>((r) => (release = r))
      await inDO(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u)), async (instance) => {
        // Only the Cloud owner's delivery is held; any other target answers at once.
        const slow = fakeTargets(deliveries, () => held)
        const quick = fakeTargets(deliveries)
        instance.targetNamespace = (cls: string) => (cls === "CloudDO" ? slow(cls) : quick(cls))
        const answer = (item: string, key: string) => instance.submit(u, session(u), { t: "op", op: "feed.answer", params: { item, answer: { decision: "allow", scope: "once" } }, idempotency_key: key, origin: "user" })
        const approval = async (source: "cloud" | "connections", team: string) => {
          const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
          const prompt = { action: { type: "tool", tool: "cloud.machine.create", summary: "s", risk: "money", input: { approval: { team, request, digest: "sha256:abc" } } }, scopes: ["once"] }
          const posted = await instance.integrationApproval(u, team, prompt, 3_600_000, `approval:${request}`, source)
          expect(posted.ok, JSON.stringify(posted)).toBe(true)
          return posted.item as string
        }
        const cloudItem = await approval("cloud", `team_slowcloud${other}`)
        const otherItem =
          other === "connections"
            ? await approval("connections", `team_slowconn${other}`)
            : ((await instance.submit(u, { identity: "inst_dmn00000000000000000", kind: "install", user: u, install: "inst_dmn00000000000000000", install_kind: "daemon", agent: "agent_a", grant_classes: ["read", "mutate-own", "execute"] }, { t: "op", op: "feed.post", params: agentPost, idempotency_key: `post-${other}`, origin: "cli" })).frames.find((f: { t: string }) => f.t === "result").value.item.id as string)
        const cloudStarted = Date.now()
        const cloudAnswer = answer(cloudItem, "a-cloud").then(() => Date.now() - cloudStarted)
        await new Promise((r) => setTimeout(r, 50))
        const started = Date.now()
        const res = await answer(otherItem, `a-${other}`)
        const took = Date.now() - started
        expect(res.frames.some((f: { t: string }) => f.t === "result"), JSON.stringify(res.frames)).toBe(true)
        expect(took, `${other} answer waited on the Cloud delivery`).toBeLessThan(500)
        // The Cloud answer still waits for its own delivery, up to the bound.
        expect(await cloudAnswer).toBeGreaterThanOrEqual(1_500)
        release()
      })
    })

  it("a Cloud answer returns as soon as its own delivery ended", async () => {
    const deliveries: Array<Delivery> = []
    let release!: () => void
    const held = new Promise<void>((r) => (release = r))
    let releasedAt = Infinity
    setTimeout(() => ((releasedAt = Date.now()), release()), 300)
    const { started, returned } = await postAndAnswer(user("cloudown0001"), "team_cloudown0001", "cloud", deliveries, () => held)
    expect(answered(deliveries, "CloudDO").length).toBeGreaterThanOrEqual(1)
    // Not before its delivery ended (the release), and soon after it.
    expect(returned).toBeGreaterThanOrEqual(releasedAt)
    expect(returned - started).toBeLessThan(1_500)
  })
})

/**
 * Review F1 [P1] on #40370: the commit-time send and the alarm both sent the same answer. CloudDO (cmux-platform
 * approvals takeAnswer) acknowledged the alarm's duplicate while the first send's approved run was in flight ("request
 * is running"), the alarm deleted the row, and when that run then failed retryably (back to pending, throw) nothing was
 * left to redeliver: the create stayed pending forever. Sends of one channel are now serialized across both paths.
 */
describe("an overlapping alarm never drops an answer whose run then fails retryably", { timeout: 60_000 }, () => {
  it("redelivers the answer after the retryable failure and the create completes", async () => {
    const u = user("cloudoverlap1")
    const team = "team_cloudoverlap1"
    // The platform's request row and its run, as takeAnswer and execute treat them.
    const req = { state: "pending" as "pending" | "running" | "done", inFlight: 0, runs: 0 }
    let release!: () => void
    const firstRun = new Promise<void>((r) => (release = r))
    const cloud = {
      systemDeliver: async (_entity: string, _source: string, items: ReadonlyArray<{ id: number; op: string }>) => {
        const done: number[] = []
        for (const item of items) {
          if (req.state === "running" && req.inFlight === 0) req.state = "pending"
          if (req.state !== "pending") {
            done.push(item.id) // "request is running" or ended: acknowledged
            continue
          }
          req.state = "running"
          req.inFlight++
          const run = ++req.runs
          try {
            if (run === 1) {
              await firstRun
              req.state = "pending" // backToPending
              throw Object.assign(new Error("approved cloud.machine.create failed retryably"), { retryable: true })
            }
            req.state = "done"
          } finally {
            req.inFlight--
          }
          done.push(item.id)
        }
        return { done }
      },
    }
    await inDO(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u)), async (instance, state) => {
      instance.targetNamespace = (cls: string) => (cls === "CloudDO" ? { idFromName: (n: string) => n, get: () => cloud } : fakeTargets([])(cls))
      const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
      const prompt = { action: { type: "tool", tool: "cloud.machine.create", summary: "s", risk: "money", input: { approval: { team, request, digest: "sha256:abc" } } }, scopes: ["once"] }
      const posted = await instance.integrationApproval(u, team, prompt, 3_600_000, `approval:${request}`, "cloud")
      expect(posted.ok, JSON.stringify(posted)).toBe(true)
      const queued = () => (instance.boundEngine.outboxPending(1_000) as Array<{ entity: string }>).some((r) => r.entity === `approval:${request}`)
      // The answer's commit-time send starts its run and holds it (feed.answer returns at its 2 s bound).
      await instance.submit(u, session(u), { t: "op", op: "feed.answer", params: { item: posted.item, answer: { decision: "allow", scope: "once" } }, idempotency_key: `approve:${request}`, origin: "user" })
      expect(req).toMatchObject({ state: "running", runs: 1 })
      // The alarm afterCommit set fires while the run is in flight (the test fires it; the runtime's is cleared).
      await state.storage.deleteAlarm()
      const alarm = instance.alarm()
      await new Promise((r) => setTimeout(r, 200))
      // The run fails retryably: the answer must still be queued for redelivery.
      release()
      await alarm
      for (let i = 0; i < 50 && req.inFlight > 0; i++) await new Promise((r) => setTimeout(r, 20))
      expect(req.state).toBe("pending")
      expect(queued(), "the answer left the queue on the duplicate's 'already running' ack").toBe(true)
      // After the channel's backoff the alarm redelivers it and the create completes.
      for (let i = 0; i < 40 && req.state !== "done"; i++) {
        await new Promise((r) => setTimeout(r, 200))
        await state.storage.deleteAlarm()
        await instance.alarm()
      }
      expect(req).toMatchObject({ state: "done", runs: 2 })
      expect(queued()).toBe(false)
    })
  })
})

/**
 * Review F1 on #40370 (a0e8552d): the per-answer wait awaited the whole commit-time drain, so an answer whose own
 * delivery had ended stayed blocked behind a slower later channel in the same drain (up to the 2 s bound). It now wakes
 * on each delivery that ends.
 */
describe("an answer's wait ends with its own delivery, not with the drain", { timeout: 60_000 }, () => {
  it("two Cloud answers in one drain: the first returns when its own delivery ends, not when the slower second does", async () => {
    const u = user("cloudtwochan1")
    const ended: Record<string, number> = {}
    // team_x: the drain in flight when both answers commit (held 150 ms); team_a: quick; team_b: held 1.5 s.
    const holdMs: Record<string, number> = { team_twochanx: 150, team_twochana: 0, team_twochanb: 1_500 }
    await inDO(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u)), async (instance) => {
      instance.targetNamespace = (cls: string) => ({
        idFromName: (n: string) => n,
        get: (name: string) => ({
          systemDeliver: async (_e: string, _s: string, items: ReadonlyArray<{ id: number }>) => {
            if (cls === "CloudDO") await new Promise((r) => setTimeout(r, holdMs[name] ?? 0))
            if (cls === "CloudDO") ended[name] = Date.now()
            return { done: items.map((i) => i.id) }
          },
        }),
      })
      const item = async (team: string) => {
        const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
        const prompt = { action: { type: "tool", tool: "cloud.machine.create", summary: "s", risk: "money", input: { approval: { team, request, digest: "sha256:abc" } } }, scopes: ["once"] }
        const posted = await instance.integrationApproval(u, team, prompt, 3_600_000, `approval:${request}`, "cloud")
        expect(posted.ok, JSON.stringify(posted)).toBe(true)
        return posted.item as string
      }
      const [x, a, b] = [await item("team_twochanx"), await item("team_twochana"), await item("team_twochanb")]
      const answer = (it: string) => instance.submit(u, session(u), { t: "op", op: "feed.answer", params: { item: it, answer: { decision: "allow", scope: "once" } }, idempotency_key: `a-${it}`, origin: "user" })
      const xDone = answer(x)
      await new Promise((r) => setTimeout(r, 20))
      // Both commit while team_x's send is in flight, so the next drain sends team_a's answer, then team_b's.
      const aStarted = Date.now()
      const aDone = answer(a).then(() => Date.now())
      const bDone = answer(b)
      const aReturned = await aDone
      await Promise.all([xDone, bDone])
      expect(ended.team_twochana, "team_a's answer was delivered").toBeDefined()
      expect(ended.team_twochanb! - ended.team_twochana!, "team_b's delivery ended after team_a's").toBeGreaterThanOrEqual(1_000)
      expect(aReturned - ended.team_twochana!, "team_a's answer waited on team_b's slower delivery").toBeLessThan(300)
      expect(aReturned - aStarted).toBeLessThan(800)
    })
  })
})

/**
 * The delivered check reads the requested answer's own outbox row (review F2 of #40370 at 063e9942): it read only
 * the channel's first 100 pending rows, so with 101 queued the last answer read as delivered while it was still queued,
 * feed.answer returned at once, and the Mac retried before CloudDO had the answer.
 */
describe("the delivered check finds an answer behind 100 queued ones", { timeout: 120_000 }, () => {
  it("with 101 answers queued on one team's CloudDO channel, the last one still reads as queued", async () => {
    const u = user("cloudqueue101")
    const team = "team_cloudqueue101"
    await inDO(testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(u)), async (instance, state) => {
      // CloudDO is down: every answer stays queued (the channel backs off), and feed.answer returns at its first failure.
      instance.targetNamespace = (cls: string) => ({ idFromName: (n: string) => n, get: () => ({ systemDeliver: async () => { throw Object.assign(new Error(`${cls} down`), { retryable: true }) } }) })
      const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
      const prompt = { action: { type: "tool", tool: "cloud.machine.create", summary: "s", risk: "money", input: { approval: { team, request, digest: "sha256:abc" } } }, scopes: ["once"] }
      const posted = await instance.integrationApproval(u, team, prompt, 3_600_000, `approval:${request}`, "cloud")
      expect(posted.ok, JSON.stringify(posted)).toBe(true)
      // 100 earlier answers already queued ahead of it on the same channel (posted over more than a minute: the feed
      // takes at most 60 posts a minute per poster, so they are written straight into the outbox here).
      const sql = state.storage.sql
      const table = (sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%outbox'`).toArray()[0] as { name: string }).name
      const target = JSON.stringify({ class: "CloudDO", name: team })
      for (let i = 0; i < 100; i++)
        sql.exec(`INSERT INTO ${table} (seq, kind, entity, payload, created_at, target, channel) VALUES (?, ?, ?, ?, ?, ?, ?)`, 0, "integration.approval.answered", `approval:apr_earlier${i}`, JSON.stringify({ request: `apr_earlier${i}`, decision: "allow" }), Date.now(), target, `CloudDO:${team}`)
      await instance.submit(u, session(u), { t: "op", op: "feed.answer", params: { item: posted.item, answer: { decision: "allow", scope: "once" } }, idempotency_key: `approve:${request}`, origin: "user" })
      await state.storage.deleteAlarm()
      const queued = (instance.boundEngine.outboxPending(1_000) as Array<{ entity: string }>).filter((r) => r.entity.startsWith("approval:"))
      expect(queued).toHaveLength(101)
      expect(queued.at(-1)!.entity).toBe(`approval:${request}`)
      expect(instance.answerDelivered({ team, request }), "the 101st answer read as delivered while queued").toBe(false)
      expect(instance.answerDelivered({ team, request: "apr_earlier0" })).toBe(false)
      expect(instance.answerDelivered({ team, request: "apr_neverqueued" })).toBe(true)
    })
  })
})
