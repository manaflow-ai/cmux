import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { base64url, importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { deliverUpstashJob, type UpstashJob } from "../src/chief-brain-cc/jobs-upstash.ts"
import type { Env } from "../src/env.ts"
import { storePlan } from "../src/inference/plan.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"

/**
 * Chief jobs on Upstash Workflow (chief-brain-cc/jobs-upstash.ts, issue 25573; CHIEF_JOBS_ENGINE=upstash):
 * `chief-auto add` makes a QStash schedule whose destination is the workflow endpoint, `ls`/`rm`/`run` reach
 * only this Chief's schedules in this chat, the endpoint takes only QStash-signed requests, and a fire's one
 * durable step hands the prompt to the Chief, once per workflow run. QStash is faked at its HTTP API (the
 * same calls the official SDK makes); the real QStash protocol is proven against Upstash's local server
 * separately (PR notes).
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace }
const testEnv = env as unknown as TestEnv
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, text: await res.clone().text(), json: (await res.json().catch(() => null)) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<unknown>) => Promise<any>
const brainOf = (agent: string, conversation: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/${conversation}`))

const WORKFLOW_URL = "https://api.test/v1/hooks/upstash/chief-job"
const SIGNING = { current: "sig-current-test-not-real", next: "sig-next-test-not-real" }
const SETTINGS = {
  CHIEF_CC_ENABLED: "1",
  CHIEF_CC_SNAPSHOT: "sh-test-chief-cc",
  CHIEF_CC_FREESTYLE_API_KEY: "test-freestyle-key-not-real",
  CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test",
  CHIEF_CC_TS_OAUTH: JSON.stringify({ client_id: "test-client", client_secret: "test-client-secret-not-real" }),
  CHIEF_JOBS_ENGINE: "upstash",
  CHIEF_JOBS_WORKFLOW_URL: WORKFLOW_URL,
  QSTASH_URL: "https://qstash.test",
  QSTASH_TOKEN: "qstash-test-token-not-real",
  QSTASH_CURRENT_SIGNING_KEY: SIGNING.current,
  QSTASH_NEXT_SIGNING_KEY: SIGNING.next
}
const saved: Record<string, string | undefined> = {}
beforeAll(() => {
  for (const k of [...Object.keys(SETTINGS), "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_CC_OWNERS"]) saved[k] = testEnv[k]
  Object.assign(testEnv, SETTINGS)
})
afterAll(() => {
  for (const [k, v] of Object.entries(saved)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
})
afterEach(() => vi.restoreAllMocks())

/** QStash's HTTP API as the SDK calls it: schedules (create, list, delete) and the workflow batch. */
type Schedule = { scheduleId: string; cron: string; destination: string; body: string; isPaused: boolean; retries: number; createdAt: number; method: string }
const fakeQStash = () => {
  const schedules = new Map<string, Schedule>()
  const created: Array<{ headers: Headers; destination: string }> = []
  const deleted: Array<string> = []
  const batches: Array<Array<{ destination: string; headers: Record<string, string>; body: string }>> = []
  const auth: Array<string | null> = []
  const inner = vi.mocked(globalThis.fetch).getMockImplementation()
  vi.mocked(globalThis.fetch).mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin !== "https://qstash.test") return inner!(input, init)
    auth.push(req.headers.get("authorization"))
    const create = url.pathname.match(/^\/v2\/schedules\/(https?:.+)$/)
    if (create && req.method === "POST") {
      const id = req.headers.get("upstash-schedule-id") ?? `scd_${crypto.randomUUID()}`
      created.push({ headers: req.headers, destination: decodeURIComponent(create[1]!) })
      schedules.set(id, { scheduleId: id, cron: req.headers.get("upstash-cron") ?? "", destination: decodeURIComponent(create[1]!), body: await req.text(), isPaused: false, retries: Number(req.headers.get("upstash-retries") ?? 3), createdAt: Date.now(), method: "POST" })
      return Response.json({ scheduleId: id })
    }
    if (url.pathname === "/v2/schedules" && req.method === "GET") return Response.json([...schedules.values()])
    const one = url.pathname.match(/^\/v2\/schedules\/([^/]+)$/)
    if (one && req.method === "DELETE") {
      deleted.push(one[1]!)
      schedules.delete(one[1]!)
      return new Response(null, { status: 200 })
    }
    if (url.pathname === "/v2/batch" && req.method === "POST") {
      const messages = (await req.json()) as Array<{ destination: string; headers: Record<string, string>; body: string }>
      batches.push(messages)
      return Response.json(messages.map((_, i) => ({ messageId: `msg_${batches.length}_${i}` })))
    }
    return Response.json({ error: `fake qstash: no ${req.method} ${url.pathname}` }, { status: 404 })
  })
  return { schedules, created, deleted, batches, auth }
}

/** A Cloud Chief on a paid plan, as chief-jobs.test.ts makes one. */
const enabledChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value as { id: string; personal_team: string }
  const user = ensured.id
  testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const ns = testEnv.TEAM_DO as unknown as { get(id: unknown): unknown; idFromName(n: string): unknown }
  await inDO(ns.get(ns.idFromName(ensured.personal_team)), async (i) => storePlan(i.ctx.storage.sql, "pro", Date.now()))
  const chief = (await op(token, "chief.create", { display_name: "Upstash Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, model: "claude-opus-5-5" })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief, user }
}
const replies = async (token: string, conversation: string, chief: string, n: number) => {
  for (let i = 0; i < 300; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no ${n} chief replies`)
}
const send = (token: string, conversation: string, key: string, text: string) => op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
const call = async (s: Started, vm: unknown) => {
  const r = await notes(s, { run: s.run, vm })
  return { status: r.status, body: (await r.json().catch(() => null)) as any }
}
const settled = async (agent: string, conversation: string) => {
  const brain = brainOf(agent, conversation)
  for (let i = 0; i < 200; i++) {
    const open = await inDO(brain, async (x) => x.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM cb_inbox WHERE state = 'running' OR (state = 'queued' AND woke = 1)`).one().n as number)
    if (open === 0) return new Promise((r) => setTimeout(r, 100))
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error("the brain still has a turn open")
}

/** A QStash request signature (HS256 JWT over the body's SHA-256), as QStash signs each delivery. */
const sign = async (body: string, key: string) => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)))
  const now = Math.floor(Date.now() / 1000)
  return new SignJWT({ body: base64url.encode(digest) })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer("Upstash")
    .setSubject(WORKFLOW_URL)
    .setIssuedAt(now)
    .setNotBefore(now)
    .setExpirationTime(now + 300)
    .setJti(crypto.randomUUID())
    .sign(new TextEncoder().encode(key))
}
const deliver = (body: string, signature?: string) =>
  worker.fetch(WORKFLOW_URL, { method: "POST", headers: { "content-type": "application/json", ...(signature ? { "upstash-signature": signature } : {}) }, body })

describe("Chief jobs on Upstash Workflow", { timeout: 90_000 }, () => {
  it("chief-auto makes, lists, runs and removes QStash schedules, only this Chief's in this chat", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      () => "Done: a summary every day at 7:15pm.",
      async (s, n) => {
        if (n !== 1) return
        seen.manual = await call(s, { action: "auto_create", name: "Ad hoc", when: "manual", prompt: "x" })
        seen.badCron = await call(s, { action: "auto_create", name: "Bad", when: "0 25 * * *", prompt: "x" })
        seen.made = await call(s, { action: "auto_create", name: "PR summary", when: "15 19 * * *", tz: "America/Los_Angeles", prompt: "Summarize today's cmux-next PRs." })
        // Someone else's schedules on the same QStash account: another Chief, and a body naming another owner.
        q.schedules.set("cj-agentsomeoneelse-00000000000000000000", { scheduleId: "cj-agentsomeoneelse-00000000000000000000", cron: "0 9 * * *", destination: WORKFLOW_URL, body: JSON.stringify({ v: 1, job: "cj-agentsomeoneelse-00000000000000000000", chief: "agent_someone_else", conversation: "conv_x", owner: "user_x", name: "theirs", prompt: "theirs", trigger: "cron" }), isPaused: false, retries: 5, createdAt: 1, method: "POST" })
        const forgedId = `${seen.made.body.job.id.slice(0, -4)}ffff`
        q.schedules.set(forgedId, { scheduleId: forgedId, cron: "0 9 * * *", destination: WORKFLOW_URL, body: JSON.stringify({ v: 1, job: forgedId, chief: a.chief.id, conversation: "conv_x", owner: "user_someone_else", name: "forged", prompt: "forged", trigger: "cron" }), isPaused: false, retries: 5, createdAt: 1, method: "POST" })
        seen.list = await call(s, { action: "auto_list" })
        seen.run = await call(s, { action: "auto_run", automation: seen.made.body.job.id })
        seen.rmOther = await call(s, { action: "auto_rm", automation: forgedId })
        seen.rm = await call(s, { action: "auto_rm", automation: seen.made.body.job.id })
      }
    )
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-ops")
    expect((await send(a.token, a.chief.main_conversation, "u1", "every day at 7:15pm summarize cmux-next PRs")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)

    expect(seen.manual.status).toBe(400)
    expect(seen.badCron.status).toBe(400)
    expect(seen.made.status, JSON.stringify(seen.made.body)).toBe(200)
    const job = seen.made.body.job
    expect(job).toMatchObject({ name: "PR summary", enabled: true, prompt: "Summarize today's cmux-next PRs." })
    expect(job.triggers).toEqual([{ type: "cron", expr: "15 19 * * *", tz: "America/Los_Angeles" }])
    // The schedule: QStash's clock, the workflow endpoint as destination, the Chief's id in the schedule id.
    expect(q.created).toHaveLength(1)
    expect(q.created[0]!.destination).toBe(WORKFLOW_URL)
    expect(q.created[0]!.headers.get("upstash-cron")).toBe("CRON_TZ=America/Los_Angeles 15 19 * * *")
    expect(q.created[0]!.headers.get("upstash-retries")).toBe("5")
    expect(job.id).toMatch(new RegExp(`^cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-[0-9a-f]{20}$`))
    const body = JSON.parse(q.schedules.get(job.id)?.body ?? "{}") as UpstashJob
    expect(body).toEqual({ v: 1, job: job.id, chief: a.chief.id, conversation: a.chief.main_conversation, owner: a.user, name: "PR summary", prompt: "Summarize today's cmux-next PRs.", trigger: "cron" })
    expect(q.auth.every((h) => h === "Bearer qstash-test-token-not-real")).toBe(true)
    // ls shows only its own; run triggers one workflow run of the same job; rm reaches only its own.
    expect(seen.list.body.jobs.map((j: any) => j.id)).toEqual([job.id])
    expect(seen.run.status, JSON.stringify(seen.run.body)).toBe(200)
    const triggered = q.batches.flat().find((m) => m.destination === WORKFLOW_URL)
    expect(triggered, JSON.stringify(q.batches)).toBeDefined()
    expect(JSON.parse(triggered!.body)).toMatchObject({ job: job.id, trigger: "manual", prompt: "Summarize today's cmux-next PRs." })
    expect(seen.rmOther.status).toBe(404)
    expect(seen.rm.status).toBe(200)
    expect(q.deleted).toEqual([job.id])
  })

  it("the workflow endpoint takes only QStash-signed jobs, and a fire hands the prompt to the Chief once per run", async () => {
    fakeCloud((prompt) => (prompt.includes("[job ") ? "PRs today: 4 merged, 2 open." : "hi"))
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-run")
    expect((await send(a.token, a.chief.main_conversation, "r1", "hi")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)

    const job: UpstashJob = { v: 1, job: `cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-0123456789abcdef0123`, chief: a.chief.id, conversation: a.chief.main_conversation, owner: a.user, name: "PR summary", prompt: "Summarize today's cmux-next PRs.", trigger: "cron" }
    const raw = JSON.stringify(job)
    // No signature, a wrong key, or a body changed after signing: refused before any step or brain call.
    expect((await deliver(raw)).ok).toBe(false)
    expect((await deliver(raw, await sign(raw, "not-the-signing-key"))).ok).toBe(false)
    expect((await deliver(JSON.stringify({ ...job, prompt: "something else" }), await sign(raw, SIGNING.current))).ok).toBe(false)
    expect(q.batches).toHaveLength(0)
    // A signed fire (as a schedule delivers it) starts the workflow run through QStash.
    const first = await deliver(raw, await sign(raw, SIGNING.next))
    expect(first.status, await first.clone().text()).toBe(200)
    const start = q.batches.flat().find((m) => m.destination === WORKFLOW_URL)
    expect(start, JSON.stringify(q.batches)).toBeDefined()
    expect(JSON.parse(start!.body)).toEqual(job)

    // The run's one step: the job's note in the Chief's conversation, once per run, and a turn that posts.
    const e = testEnv as unknown as Env
    expect(await deliverUpstashJob(e, job, "wfr_test_1")).toEqual({ ok: true })
    expect(await deliverUpstashJob(e, job, "wfr_test_1")).toEqual({ ok: true })
    const rows = await inDO(brainOf(a.chief.id, a.chief.main_conversation), async (i) => i.ctx.storage.sql.exec(`SELECT text FROM cb_inbox WHERE message = ?`, "job:upstash:wfr_test_1").toArray())
    expect(rows).toHaveLength(1)
    expect(rows[0].text).toContain(`[job ${job.job}] Summarize today's cmux-next PRs.`)
    for (let i = 0; i < 60 && (await history(a.token, a.chief.main_conversation)).filter((m) => m.author === a.chief.id).length < 2; i++) {
      await fireAlarm(brainOf(a.chief.id, a.chief.main_conversation))
      await new Promise((r) => setTimeout(r, 50))
    }
    const mine = await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
    expect(JSON.stringify(mine.at(-1))).toContain("PRs today: 4 merged, 2 open.")
    // A schedule body naming another owner never reaches the Chief (fails closed).
    expect(await deliverUpstashJob(e, { ...job, owner: "user_bbbbbbbbbbbbbbbbbbbb" }, "wfr_test_2")).toMatchObject({ ok: false, code: "chief.forbidden" })
    await settled(a.chief.id, a.chief.main_conversation)
  })

  it("without every Upstash setting, jobs stay on the SchedulerDO and the endpoint is off", async () => {
    const before = testEnv.QSTASH_NEXT_SIGNING_KEY
    delete testEnv.QSTASH_NEXT_SIGNING_KEY
    try {
      const raw = JSON.stringify({ v: 1 })
      expect((await deliver(raw, await sign(raw, SIGNING.current))).status).toBe(404)
    } finally {
      testEnv.QSTASH_NEXT_SIGNING_KEY = before
    }
  })
})
