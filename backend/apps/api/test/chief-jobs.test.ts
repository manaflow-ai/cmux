import { env, exports } from "cloudflare:workers"
import { introspectWorkflowInstance, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { storePlan } from "../src/inference/plan.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"

/**
 * A Chief's scheduled and triggered jobs, and the upsell (plans/cmux-next/chief-automations-DESIGN.md,
 * chief-brain-cc/jobs.ts, plan-checkout.ts): the person asks the Cloud Chief for a recurring job, the Chief
 * makes it with `chief-auto` from its turn machine, a run of it starts a new Chief turn with no message from
 * anyone (in the cloud, with every computer of the person off), and the Chief's reply lands in the chat. On
 * the free plan the second job answers automation.plan.required with a Stripe Checkout link (test mode).
 * Freestyle and Stripe are faked at their HTTP boundary.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace; SCHEDULER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; AUTOMATION_RUN: Workflow }
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

const SETTINGS = { CHIEF_CC_ENABLED: "1", CHIEF_CC_SNAPSHOT: "sh-test-chief-cc", CHIEF_CC_FREESTYLE_API_KEY: "test-freestyle-key-not-real", CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test", CHIEF_CC_TS_OAUTH: JSON.stringify({ client_id: "test-client", client_secret: "test-client-secret-not-real" }) }
const saved: Record<string, string | undefined> = {}
beforeAll(() => {
  for (const k of [...Object.keys(SETTINGS), "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_CC_OWNERS"]) saved[k] = testEnv[k]
  Object.assign(testEnv, SETTINGS)
})
afterAll(() => {
  for (const [k, v] of Object.entries(saved)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
})
afterEach(() => vi.restoreAllMocks())

/** A Cloud Chief whose owner's plan copy is `plan` (null = free). */
const enabledChief = async (sub: string, plan: string | null) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value as { id: string; personal_team: string }
  const user = ensured.id
  testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const ns = testEnv.TEAM_DO as unknown as { get(id: unknown): unknown; idFromName(n: string): unknown }
  await inDO(ns.get(ns.idFromName(ensured.personal_team)), async (i) => storePlan(i.ctx.storage.sql, plan, Date.now()))
  const chief = (await op(token, "chief.create", { display_name: "Jobs Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, model: "claude-opus-5-5" })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief, user, team: ensured.personal_team }
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
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<unknown>) => Promise<any>
const brainOf = (agent: string, conversation: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/${conversation}`))

/**
 * Waits until the brain has no turn running or queued, so the fake machine's last posts (its result note
 * goes out on a timer after the reply is visible) end inside the test, never at teardown (CI run 40273548162).
 */
const settled = async (agent: string, conversation: string) => {
  const brain = brainOf(agent, conversation)
  for (let i = 0; i < 200; i++) {
    const open = await inDO(brain, async (x) => x.ctx.storage.sql.exec(`SELECT COUNT(*) AS n FROM cb_inbox WHERE state = 'running' OR (state = 'queued' AND woke = 1)`).one().n as number)
    if (open === 0) return new Promise((r) => setTimeout(r, 100))
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error("the brain still has a turn open")
}

describe("Chief jobs and the upsell", { timeout: 90_000 }, () => {
  it("a job the Chief makes runs in the cloud: its run starts a Chief turn with the job's prompt and the reply lands in the chat", async () => {
    const seen: Record<string, any> = {}
    const cloud = fakeCloud(
      (prompt) => (prompt.includes("[job ") ? "Digest: 3 PRs merged overnight." : "Done: a daily digest at 9:00."),
      async (s, n) => {
        if (n !== 1) return
        seen.bad = await call(s, { action: "auto_create", name: "digest", when: "0 9 * * *" })
        seen.made = await call(s, { action: "auto_create", name: "Morning digest", when: "0 9 * * *", tz: "America/Los_Angeles", prompt: "Summarize last night's merged PRs on manaflow-ai/cmux." })
        seen.list = await call(s, { action: "auto_list" })
        seen.run = await call(s, { action: "auto_run", automation: seen.made.body?.job?.id })
        seen.other = await call(s, { action: "auto_rm", automation: "auto_00000000000000000000" })
      }
    )
    const a = await enabledChief("chief-jobs-run", "pro")
    expect((await send(a.token, a.chief.main_conversation, "j1", "every morning at 9 send me a digest of merged PRs")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    expect(seen.bad.status).toBe(400)
    expect(seen.made.status, JSON.stringify(seen.made.body)).toBe(200)
    const job = seen.made.body.job
    expect(job).toMatchObject({ name: "Morning digest", enabled: true, prompt: "Summarize last night's merged PRs on manaflow-ai/cmux." })
    expect(job.triggers).toContainEqual({ type: "cron", expr: "0 9 * * *", tz: "America/Los_Angeles" })
    expect(typeof job.next_run_at).toBe("number")
    expect(seen.list.body.jobs.map((j: any) => j.id)).toEqual([job.id])
    expect(seen.other.status).toBe(404)
    expect(seen.run.status, JSON.stringify(seen.run.body)).toBe(200)
    // The run (a Workflow) hands the prompt to the Chief: a second turn with no message from anyone.
    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(a.team))
    const instance = await introspectWorkflowInstance(testEnv.AUTOMATION_RUN, seen.run.body.run.id)
    try {
      await fireAlarm(scheduler)
      await instance.waitForStatus("complete")
    } finally {
      await instance[Symbol.asyncDispose]()
    }
    const brain = brainOf(a.chief.id, a.chief.main_conversation)
    for (let i = 0; i < 60 && cloud.started.length < 2; i++) {
      await fireAlarm(brain)
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(cloud.started.length).toBe(2)
    expect(cloud.started[1]!.input.prompt).toContain(`[job ${job.id}] Summarize last night's merged PRs on manaflow-ai/cmux.`)
    expect(cloud.started[1]!.input.prompt).toContain("it is not the person's word now")
    const mine = await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
    expect(JSON.stringify(mine.at(-1))).toContain("Digest: 3 PRs merged overnight.")
    // The job client ships to every turn machine, and a Chief tool cannot replace it.
    expect((cloud.started[1]!.input as any).files[".local/bin/chief-auto"]).toContain("auto_create")
    await settled(a.chief.id, a.chief.main_conversation)
  })

  it("on the free plan the second job answers automation.plan.required with a test-mode Stripe Checkout link", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      () => "ok",
      async (s, n) => {
        if (n !== 1) return
        seen.first = await call(s, { action: "auto_create", name: "Weekly report", when: "0 17 * * 5", prompt: "Write the weekly report." })
        seen.second = await call(s, { action: "auto_create", name: "Daily check", when: "0 8 * * *", prompt: "Check the deploys." })
      }
    )
    const a = await enabledChief("chief-jobs-free", null)
    expect((await send(a.token, a.chief.main_conversation, "f1", "every friday write the weekly report, and check deploys daily")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)
    expect(seen.first.status, JSON.stringify(seen.first.body)).toBe(200)
    expect(seen.second.status).toBe(402)
    expect(seen.second.body).toMatchObject({ code: "automation.plan.required", plan: "pro", test_mode: true })
    const link = String(seen.second.body.checkout)
    expect(link).toMatch(/^https:\/\/api\.test\/v1\/billing\/plan\/[A-Za-z0-9_-]+\.[0-9a-f]{64}$/)

    // Opening the link makes a Stripe Checkout page for Pro on this team, with the test key only.
    const inner = vi.mocked(globalThis.fetch).getMockImplementation()
    const stripe: Array<{ auth: string | null; form: Record<string, string> }> = []
    vi.mocked(globalThis.fetch).mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input))
      if (url.hostname === "api.stripe.com" && url.pathname === "/v1/checkout/sessions") {
        stripe.push({ auth: new Headers(init?.headers).get("authorization"), form: Object.fromEntries(new URLSearchParams(String(init?.body ?? ""))) })
        return Response.json({ id: "cs_test_jobs0001", url: "https://checkout.stripe.com/c/pay/cs_test_jobs0001" })
      }
      return inner!(input, init)
    })
    const res = await worker.fetch(link, { redirect: "manual" })
    expect(res.status).toBe(303)
    expect(res.headers.get("location")).toBe("https://checkout.stripe.com/c/pay/cs_test_jobs0001")
    expect(stripe).toHaveLength(1)
    expect(stripe[0]!.auth).toMatch(/^Bearer sk_test_/)
    expect(stripe[0]!.form).toMatchObject({
      mode: "subscription",
      "line_items[0][price_data][unit_amount]": "5000",
      "line_items[0][price_data][recurring][interval]": "month",
      "metadata[team]": a.team,
      "metadata[plan]": "pro",
      "metadata[kind]": "cmux_plan"
    })
    // A forged link is refused.
    expect((await worker.fetch(link.replace(/.$/, (c) => (c === "0" ? "1" : "0")), { redirect: "manual" })).status).toBe(404)
  })

  it("delivery refuses a job charged to a member who does not own the Chief, and a Chief that never answered there", async () => {
    fakeCloud(() => "ok")
    const a = await enabledChief("chief-jobs-owner", "pro")
    expect((await send(a.token, a.chief.main_conversation, "o1", "hi")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    const job = { run: "run_aaaaaaaaaaaaaaaaaaaa", automation: "auto_aaaaaaaaaaaaaaaaaaaa", chief: a.chief.id, conversation: a.chief.main_conversation, prompt: "x", trigger: "manual" }
    const brain = brainOf(a.chief.id, a.chief.main_conversation) as unknown as { chiefJob(j: unknown): Promise<any> }
    expect(await brain.chiefJob({ ...job, charged_user: "user_bbbbbbbbbbbbbbbbbbbb" })).toMatchObject({ ok: false, code: "chief.forbidden" })
    expect(await brain.chiefJob({ ...job, charged_user: null })).toMatchObject({ ok: false, code: "chief.forbidden" })
    expect(await brain.chiefJob({ ...job, chief: "agent_someone_else", charged_user: a.user })).toMatchObject({ ok: false, code: "chief.not_found" })
    // The owner's own job is taken, once per run.
    expect(await brain.chiefJob({ ...job, charged_user: a.user })).toEqual({ ok: true })
    expect(await brain.chiefJob({ ...job, charged_user: a.user })).toEqual({ ok: true })
    const rows = await inDO(brainOf(a.chief.id, a.chief.main_conversation), async (i) => i.ctx.storage.sql.exec(`SELECT text FROM cb_inbox WHERE message = ?`, `job:${job.run}`).toArray())
    expect(rows).toHaveLength(1)
    // The queued note starts a turn: let it post before the test ends (no turn left running at teardown).
    for (let i = 0; i < 60 && (await history(a.token, a.chief.main_conversation)).filter((m) => m.author === a.chief.id).length < 2; i++) {
      await fireAlarm(brainOf(a.chief.id, a.chief.main_conversation))
      await new Promise((r) => setTimeout(r, 50))
    }
    await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
    await settled(a.chief.id, a.chief.main_conversation)
  })
})
