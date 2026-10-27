import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { base64url, importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { type FireBody, jobsStoreName, type StoreOp } from "../src/chief-brain-cc/jobs-store.ts"
import { storePlan } from "../src/inference/plan.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"

/**
 * Chief jobs on Upstash Workflow (chief-brain-cc/jobs-upstash.ts and jobs-store.ts, issue 25573;
 * CHIEF_JOBS_ENGINE=upstash). The records live in the team's `<team>/chief-jobs` brain object; QStash keeps
 * cron schedules and runs each fire as a workflow run. Covered: every `chief-auto` action and its ownership,
 * webhook jobs (signed, once per delivery), provider-event jobs (GitHub CI failed, pushed by GitHub's webhook,
 * once per delivery), the signed workflow endpoint, the step (once per run, removed or paused jobs do
 * nothing), retry exhaustion on the record, the outbox when Upstash is down, and the engine being off.
 * QStash is faked at its HTTP API, the calls the official SDK makes.
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

/** QStash's HTTP API as the SDK calls it: schedules (create, list, pause, resume, delete) and the workflow batch. */
type Schedule = { scheduleId: string; cron: string; destination: string; body: string; isPaused: boolean; retries: number; createdAt: number; method: string }
type Batch = { destination: string; headers: Record<string, string>; body: string }
const fakeQStash = () => {
  const schedules = new Map<string, Schedule>()
  const created: Array<{ headers: Headers; destination: string; body: string }> = []
  const deleted: Array<string> = []
  const batches: Array<Array<Batch>> = []
  const auth: Array<string | null> = []
  const down = { batch: false, schedules: false }
  const inner = vi.mocked(globalThis.fetch).getMockImplementation()
  vi.mocked(globalThis.fetch).mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin !== "https://qstash.test") return inner!(input, init)
    auth.push(req.headers.get("authorization"))
    if (down.schedules && url.pathname.startsWith("/v2/schedules")) return Response.json({ error: "fake qstash: down" }, { status: 503 })
    const create = url.pathname.match(/^\/v2\/schedules\/(https?:.+)$/)
    if (create && req.method === "POST") {
      const id = req.headers.get("upstash-schedule-id") ?? `scd_${crypto.randomUUID()}`
      const body = await req.text()
      created.push({ headers: req.headers, destination: decodeURIComponent(create[1]!), body })
      schedules.set(id, { scheduleId: id, cron: req.headers.get("upstash-cron") ?? "", destination: decodeURIComponent(create[1]!), body, isPaused: false, retries: Number(req.headers.get("upstash-retries") ?? 3), createdAt: Date.now(), method: "POST" })
      return Response.json({ scheduleId: id })
    }
    if (url.pathname === "/v2/schedules" && req.method === "GET") return Response.json([...schedules.values()])
    const flip = url.pathname.match(/^\/v2\/schedules\/([^/]+)\/(pause|resume)$/)
    if (flip && req.method === "PATCH") {
      const sc = schedules.get(flip[1]!)
      if (!sc) return Response.json({ error: "schedule not found" }, { status: 404 })
      sc.isPaused = flip[2] === "pause"
      return new Response(null, { status: 200 })
    }
    const one = url.pathname.match(/^\/v2\/schedules\/([^/]+)$/)
    if (one && req.method === "DELETE") {
      if (!schedules.has(one[1]!)) return Response.json({ error: "schedule not found" }, { status: 404 })
      deleted.push(one[1]!)
      schedules.delete(one[1]!)
      return new Response(null, { status: 200 })
    }
    if (url.pathname === "/v2/batch" && req.method === "POST") {
      if (down.batch) return Response.json({ error: "fake qstash: down" }, { status: 503 })
      const messages = (await req.json()) as Array<Batch>
      batches.push(messages)
      return Response.json(messages.map((_, i) => ({ messageId: `msg_${batches.length}_${i}` })))
    }
    return Response.json({ error: `fake qstash: no ${req.method} ${url.pathname}` }, { status: 404 })
  })
  /** Workflow runs started (the first invocation of each, as `client.trigger` and `serve` send it). */
  const runs = () => batches.flat().filter((m) => m.destination === WORKFLOW_URL).map((m) => ({ id: m.headers["upstash-workflow-runid"], body: JSON.parse(m.body) as FireBody }))
  return { schedules, created, deleted, batches, auth, down, runs }
}
const storeOf = (team: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(jobsStoreName(team))) as unknown as { cjStore(team: string, o: StoreOp): Promise<any> }

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

/** Signs a webhook job delivery the way its sender must (automation-hook.ts scheme). */
const hookSign = async (secret: string, ts: string, body: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${body}`)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
const hookPost = async (url: string, secret: string, body: string, ts = String(Math.floor(Date.now() / 1000))) =>
  worker.fetch(url, { method: "POST", headers: { "content-type": "application/json", "x-cmux-timestamp": ts, "x-cmux-signature": `v1=${await hookSign(secret, ts, body)}` }, body })
const ghHmac = async (body: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(testEnv.GITHUB_WEBHOOK_SECRET!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
/** A GitHub App webhook delivery, as GitHub sends it to /v1/hooks/github. */
const ghHook = async (event: string, payload: unknown) => {
  const body = JSON.stringify(payload)
  const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await ghHmac(body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": event }, body })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
/** Links a private GitHub App connection (installation 99, repos acme/web and acme/api) on the team, as integrations.test.ts does. */
const linkGitHub = async (token: string, team: string) => {
  const connect = await op(token, "integration.connect", { provider: "github", sharing: "private" })
  const state = new URL(connect.value.authorize_url).searchParams.get("state")!
  const routes: Record<string, () => Response> = {
    "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
    "https://api.github.com/user/installations/99/repositories": () => ok({ repositories: [{ full_name: "acme/web" }, { full_name: "acme/api" }] }),
    "https://api.github.com/user/installations": () => ok({ installations: [{ id: 99, account: { login: "acme", type: "Organization" }, permissions: { issues: "write", actions: "read" } }] }),
    "https://api.github.com/app/installations/99/access_tokens": () => ok({ token: "ghs_x", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201)
  }
  const ns = testEnv.CONNECTION_DO as unknown as { get(id: unknown): unknown; idFromName(n: string): unknown }
  await inDO(ns.get(ns.idFromName(team)), async (i) => {
    i.http = async (req: Request) => {
      const key = Object.keys(routes).find((k) => req.url.startsWith(k))
      return key ? routes[key]!() : new Response("not found", { status: 404 })
    }
  })
  const done = await op(token, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })
  expect(done.value?.status, JSON.stringify(done)).toBe("active")
  return connect.value.connection.id as string
}
/** The Chief's chat after a run: wait for its n-th reply, firing the brain's alarm meanwhile. */
const replyAfterRun = async (a: { token: string; chief: { id: string; main_conversation: string } }, n: number) => {
  for (let i = 0; i < 60 && (await history(a.token, a.chief.main_conversation)).filter((m) => m.author === a.chief.id).length < n; i++) {
    await fireAlarm(brainOf(a.chief.id, a.chief.main_conversation))
    await new Promise((r) => setTimeout(r, 50))
  }
  return (await replies(a.token, a.chief.main_conversation, a.chief.id, n)).at(-1)
}
const noteOf = async (a: { chief: { id: string; main_conversation: string } }, run: string) =>
  (await inDO(brainOf(a.chief.id, a.chief.main_conversation), async (i) => i.ctx.storage.sql.exec(`SELECT text, effect_authorized FROM cb_inbox WHERE message = ?`, `job:upstash:${run}`).toArray())) as Array<{ text: string; effect_authorized: number }>

describe("Chief jobs on Upstash Workflow", { timeout: 120_000 }, () => {
  it("chief-auto makes, lists, pauses, runs and removes jobs; the records are the team's, only this Chief's in this chat", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      () => "Done: a summary every day at 7:15pm.",
      async (s, n) => {
        if (n !== 1) return
        seen.badCron = await call(s, { action: "auto_create", name: "Bad", when: "0 25 * * *", prompt: "x" })
        seen.badEvent = await call(s, { action: "auto_create", name: "Bad", when: "github workflow_run.completed conclusion", prompt: "x" })
        // QStash refusing the schedule: the Chief hears it and no record is left behind.
        q.down.schedules = true
        seen.down = await call(s, { action: "auto_create", name: "Down", when: "0 9 * * *", prompt: "x" })
        seen.downList = await call(s, { action: "auto_list" })
        q.down.schedules = false
        seen.made = await call(s, { action: "auto_create", name: "PR summary", when: "15 19 * * *", tz: "America/Los_Angeles", prompt: "Summarize today's cmux-next PRs." })
        seen.manual = await call(s, { action: "auto_create", name: "Ad hoc", when: "manual", prompt: "Say hi." })
        // Another Chief's record in the same team's store, and a schedule on the account that no record names.
        await storeOf(a.team).cjStore(a.team, { op: "insert", job: { id: "cj-agentsomeoneelse-00000000000000000000", agent: "agent_someone_else", owner: a.user, conversation: a.chief.main_conversation, name: "theirs", prompt: "theirs", trigger: { type: "manual" } } })
        q.schedules.set("cj-agentstray-00000000000000000000", { scheduleId: "cj-agentstray-00000000000000000000", cron: "0 9 * * *", destination: WORKFLOW_URL, body: "{}", isPaused: false, retries: 5, createdAt: 1, method: "POST" })
        seen.list = await call(s, { action: "auto_list" })
        seen.pause = await call(s, { action: "auto_pause", automation: seen.made.body.job.id })
        seen.paused = q.schedules.get(seen.made.body.job.id)?.isPaused
        seen.resume = await call(s, { action: "auto_resume", automation: seen.made.body.job.id })
        seen.resumed = q.schedules.get(seen.made.body.job.id)?.isPaused
        seen.run = await call(s, { action: "auto_run", automation: seen.manual.body.job.id })
        seen.runOther = await call(s, { action: "auto_run", automation: "cj-agentsomeoneelse-00000000000000000000" })
        seen.hookNotWebhook = await call(s, { action: "auto_hook", automation: seen.made.body.job.id })
        seen.rmOther = await call(s, { action: "auto_rm", automation: "cj-agentsomeoneelse-00000000000000000000" })
        seen.rm = await call(s, { action: "auto_rm", automation: seen.made.body.job.id })
        seen.after = await call(s, { action: "auto_list" })
      }
    )
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-ops")
    expect((await send(a.token, a.chief.main_conversation, "u1", "every day at 7:15pm summarize cmux-next PRs")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)

    expect(seen.badCron.status).toBe(400)
    expect(seen.badEvent.status).toBe(400)
    expect(seen.down.status).toBe(502)
    expect(seen.down.body.code).toBe("jobs.unavailable")
    expect(seen.downList.body.jobs).toEqual([])
    expect(seen.made.status, JSON.stringify(seen.made.body)).toBe(200)
    const job = seen.made.body.job
    expect(job).toMatchObject({ name: "PR summary", enabled: true, prompt: "Summarize today's cmux-next PRs.", triggers: [{ type: "cron", expr: "15 19 * * *", tz: "America/Los_Angeles" }] })
    expect(job.next_run_at).toBeGreaterThan(Date.now())
    // The schedule: QStash's clock, the workflow endpoint as destination, the job id as schedule id, a body
    // that names only the team and the job (the record has the rest).
    const made = q.created.find((x) => x.headers.get("upstash-schedule-id") === job.id)!
    expect(made.destination).toBe(WORKFLOW_URL)
    expect(made.headers.get("upstash-cron")).toBe("CRON_TZ=America/Los_Angeles 15 19 * * *")
    expect(made.headers.get("upstash-retries")).toBe("5")
    expect(JSON.parse(made.body)).toEqual({ v: 2, team: a.team, job: job.id, trigger: "cron" })
    expect(job.id).toMatch(new RegExp(`^cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-[0-9a-f]{20}$`))
    expect(q.auth.every((h) => h === "Bearer qstash-test-token-not-real")).toBe(true)
    // A manual job has no schedule.
    expect(seen.manual.status).toBe(200)
    expect(q.created.some((x) => x.headers.get("upstash-schedule-id") === seen.manual.body.job.id)).toBe(false)
    // ls reads the records: this Chief's two jobs, not another Chief's record nor a stray schedule.
    expect(seen.list.body.jobs.map((j: any) => j.id)).toEqual([job.id, seen.manual.body.job.id])
    expect(seen.pause.body.job.enabled).toBe(false)
    expect(seen.paused).toBe(true)
    expect(seen.resume.body.job.enabled).toBe(true)
    expect(seen.resumed).toBe(false)
    // run starts one workflow run of that job with our run id.
    expect(seen.run.status, JSON.stringify(seen.run.body)).toBe(200)
    expect(q.runs()).toEqual([{ id: seen.run.body.run.id, body: { v: 2, team: a.team, job: seen.manual.body.job.id, trigger: "manual" } }])
    expect(seen.runOther.status).toBe(404)
    expect(seen.hookNotWebhook.status).toBe(400)
    expect(seen.rmOther.status).toBe(404)
    expect(seen.rm.status).toBe(200)
    expect(q.deleted).toEqual([job.id])
    expect(seen.after.body.jobs.map((j: any) => j.id)).toEqual([seen.manual.body.job.id])
  })

  it("the workflow endpoint takes only QStash-signed fires; the step reads the record and hands the prompt to the Chief once per run", async () => {
    fakeCloud((prompt) => (prompt.includes("[job ") ? "PRs today: 4 merged, 2 open." : "hi"))
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-run")
    expect((await send(a.token, a.chief.main_conversation, "r1", "hi")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)

    const id = `cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-0123456789abcdef0123`
    const st = storeOf(a.team)
    await st.cjStore(a.team, { op: "insert", job: { id, agent: a.chief.id, owner: a.user, conversation: a.chief.main_conversation, name: "PR summary", prompt: "Summarize today's cmux-next PRs.", trigger: { type: "cron", expr: "15 19 * * *", tz: "UTC" } } })
    const fire: FireBody = { v: 2, team: a.team, job: id, trigger: "cron" }
    const raw = JSON.stringify(fire)
    // No signature, a wrong key, a body changed after signing, or a body that is not a fire: refused.
    expect((await deliver(raw)).ok).toBe(false)
    expect((await deliver(raw, await sign(raw, "not-the-signing-key"))).ok).toBe(false)
    expect((await deliver(JSON.stringify({ ...fire, job: `${id.slice(0, -4)}ffff` }), await sign(raw, SIGNING.current))).ok).toBe(false)
    const junk = JSON.stringify({ v: 1, job: id })
    expect((await deliver(junk, await sign(junk, SIGNING.current))).ok).toBe(false)
    expect(q.runs()).toHaveLength(0)
    // A signed fire (as the schedule delivers it) starts the workflow run through QStash.
    const first = await deliver(raw, await sign(raw, SIGNING.next))
    expect(first.status, await first.clone().text()).toBe(200)
    expect(q.runs().map((r) => r.body)).toEqual([fire])

    // The step: the job's note in the Chief's conversation, once per run, and a turn that posts.
    expect(await st.cjStore(a.team, { op: "fire", body: fire, run: "wfr_test_1" })).toEqual({ ok: true })
    expect(await st.cjStore(a.team, { op: "fire", body: fire, run: "wfr_test_1" })).toEqual({ ok: true })
    const rows = await noteOf(a, "wfr_test_1")
    expect(rows).toHaveLength(1)
    expect(rows[0]!.effect_authorized).toBe(1)
    expect(rows[0]!.text).toContain(`[job ${id}] Summarize today's cmux-next PRs.`)
    expect(JSON.stringify(await replyAfterRun(a, 2))).toContain("PRs today: 4 merged, 2 open.")
    expect((await st.cjStore(a.team, { op: "get", id })).last_run).toMatchObject({ run: "wfr_test_1", state: "delivered", trigger: "cron" })
    // Retries ran out: the record shows the failure.
    await st.cjStore(a.team, { op: "failed", id, run: "wfr_test_9", trigger: "cron", message: "owner.unreachable: the Chief's record could not be read" })
    expect((await st.cjStore(a.team, { op: "get", id })).last_run).toMatchObject({ run: "wfr_test_9", state: "failed" })
    // Paused: a scheduled fire does nothing (a manual run still goes).
    await st.cjStore(a.team, { op: "pause", id, paused: true })
    expect(await st.cjStore(a.team, { op: "fire", body: fire, run: "wfr_test_2" })).toMatchObject({ ok: false, code: "job.paused" })
    expect(await noteOf(a, "wfr_test_2")).toHaveLength(0)
    await st.cjStore(a.team, { op: "pause", id, paused: false })
    // A record naming another owner never reaches the Chief (fails closed).
    const forged = `cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-ffffffffffffffffffff`
    await st.cjStore(a.team, { op: "insert", job: { id: forged, agent: a.chief.id, owner: "user_bbbbbbbbbbbbbbbbbbbb", conversation: a.chief.main_conversation, name: "x", prompt: "x", trigger: { type: "manual" } } })
    expect(await st.cjStore(a.team, { op: "fire", body: { ...fire, job: forged, trigger: "manual" }, run: "wfr_test_3" })).toMatchObject({ ok: false, code: "chief.forbidden" })
    // Removed: a fire that still comes does nothing.
    await st.cjStore(a.team, { op: "remove", id })
    expect(await st.cjStore(a.team, { op: "fire", body: fire, run: "wfr_test_4" })).toMatchObject({ ok: false, code: "job.gone" })
    expect(await noteOf(a, "wfr_test_4")).toHaveLength(0)
    await settled(a.chief.id, a.chief.main_conversation)
  })

  it("a webhook job runs once per signed delivery, with the body as its input; a paused one refuses", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      () => "ok",
      async (s, n) => {
        if (n !== 1) return
        seen.made = await call(s, { action: "auto_create", name: "Deploys", when: "webhook", prompt: "Tell me what deployed." })
        seen.hook = await call(s, { action: "auto_hook", automation: seen.made.body.job.id })
      }
    )
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-hook")
    expect((await send(a.token, a.chief.main_conversation, "h1", "tell me when something deploys")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)

    expect(seen.made.status, JSON.stringify(seen.made.body)).toBe(200)
    const id = seen.made.body.job.id as string
    const { url, secret } = seen.made.body.webhook as { url: string; secret: string }
    expect(url).toBe(`https://api.test/v1/hooks/chief-job/${a.team}/${id}`)
    expect(secret).toMatch(/^whsec_[0-9a-f]{64}$/)
    expect(seen.hook.body.webhook).toMatchObject({ url, secret })
    expect(q.created).toHaveLength(0)

    const body = JSON.stringify({ service: "web", version: "1.2.3" })
    expect((await hookPost(url, "whsec_wrong", body)).status).toBe(401)
    expect((await hookPost(url, secret, body, String(Math.floor(Date.now() / 1000) - 3600))).status).toBe(401)
    const ts = String(Math.floor(Date.now() / 1000))
    const first = await hookPost(url, secret, body, ts)
    expect(first.status, await first.clone().text()).toBe(202)
    const accepted = (await first.json()) as any
    expect(accepted).toMatchObject({ ok: true, status: "accepted" })
    // The same signed delivery again: one run.
    expect(((await (await hookPost(url, secret, body, ts)).json()) as any).status).toBe("duplicate")
    expect(q.runs()).toEqual([{ id: accepted.run, body: { v: 2, team: a.team, job: id, trigger: "webhook", input: expect.objectContaining({ body: { service: "web", version: "1.2.3" } }) } }])
    // The run's note carries the delivery as its input.
    expect(await storeOf(a.team).cjStore(a.team, { op: "fire", body: q.runs()[0]!.body, run: accepted.run })).toEqual({ ok: true })
    const note = (await noteOf(a, accepted.run))[0]!.text
    expect(note).toContain("Tell me what deployed.")
    expect(note).toContain('"version":"1.2.3"')
    // Paused: refused, nothing starts. Another job's id with this secret: not found.
    await storeOf(a.team).cjStore(a.team, { op: "pause", id, paused: true })
    expect((await hookPost(url, secret, JSON.stringify({ n: 2 }))).status).toBe(409)
    expect((await hookPost(`https://api.test/v1/hooks/chief-job/${a.team}/${id.slice(0, -4)}ffff`, secret, body)).status).toBe(401)
    expect(q.runs()).toHaveLength(1)
    await replyAfterRun(a, 2)
    await settled(a.chief.id, a.chief.main_conversation)
  })

  it("CI failed: GitHub's workflow_run webhook starts the Chief's event job once, with the run's details; nothing polls", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      (prompt) => (prompt.includes("[job ") ? "CI failed on main: CI. Looking." : "ok"),
      async (s, n) => {
        if (n !== 1) return
        seen.made = await call(s, { action: "auto_create", name: "CI red", when: "github workflow_run.completed workflow_run.conclusion=failure repository.full_name=acme/web", prompt: "CI failed: find why and tell me." })
      }
    )
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-ci")
    await linkGitHub(a.token, a.team)
    expect((await send(a.token, a.chief.main_conversation, "c1", "tell me when CI fails on acme/web")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    await settled(a.chief.id, a.chief.main_conversation)
    expect(seen.made.status, JSON.stringify(seen.made.body)).toBe(200)
    const id = seen.made.body.job.id as string
    expect(seen.made.body.job.triggers).toEqual([{ type: "event", provider: "github", event: "workflow_run.completed", filter: { "workflow_run.conclusion": "failure", "repository.full_name": "acme/web" } }])
    expect(seen.made.body.job.next_run_at).toBeNull()

    const run = (conclusion: string, repo = "acme/web") => ({
      action: "completed",
      installation: { id: 99 },
      repository: { full_name: repo },
      workflow_run: { id: 777, name: "CI", conclusion, status: "completed", head_branch: "main", head_sha: "a".repeat(40), html_url: "https://github.com/acme/web/actions/runs/777", run_attempt: 1 }
    })
    const red = run("failure")
    // Green, another repository, another event: nothing.
    expect((await ghHook("workflow_run", run("success"))).json.runs).toBe(0)
    expect((await ghHook("workflow_run", run("failure", "acme/api"))).json.runs).toBe(0)
    expect((await ghHook("workflow_run", { ...red, action: "requested" })).json.runs).toBe(0)
    expect(q.runs()).toHaveLength(0)
    // Red: one run. GitHub's redelivery of the same delivery (same signed body): no second run.
    expect((await ghHook("workflow_run", red)).json.runs).toBe(1)
    expect((await ghHook("workflow_run", red)).json.runs).toBe(0)
    const started = q.runs()
    expect(started).toHaveLength(1)
    expect(started[0]!.body).toMatchObject({ v: 2, team: a.team, job: id, trigger: "event", input: { provider: "github", event: "workflow_run.completed" } })
    // Its step: the note carries the failed run, the Chief answers in the chat.
    expect(await storeOf(a.team).cjStore(a.team, { op: "fire", body: started[0]!.body, run: started[0]!.id! })).toEqual({ ok: true })
    const [row] = await noteOf(a, started[0]!.id!)
    const note = row!.text
    // The payload is written by whoever pushed or opened the PR: that turn gets no hands or chiefs.
    expect(row!.effect_authorized).toBe(0)
    expect(note).toContain("CI failed: find why and tell me.")
    expect(note).toContain("https://github.com/acme/web/actions/runs/777")
    expect(JSON.stringify(await replyAfterRun(a, 2))).toContain("CI failed on main")
    // Paused: the next red starts nothing.
    await storeOf(a.team).cjStore(a.team, { op: "pause", id, paused: true })
    expect((await ghHook("workflow_run", { ...red, workflow_run: { ...red.workflow_run, id: 778 } })).json.runs).toBe(0)
    await settled(a.chief.id, a.chief.main_conversation)
  })

  it("a run that cannot reach Upstash waits in the outbox and starts when it is back", async () => {
    fakeCloud(() => "ok")
    const q = fakeQStash()
    const a = await enabledChief("chief-upstash-outbox")
    const id = `cj-${a.chief.id.replace(/[^A-Za-z0-9]/g, "")}-00000000000000000001`
    const st = storeOf(a.team)
    await st.cjStore(a.team, { op: "insert", job: { id, agent: a.chief.id, owner: a.user, conversation: a.chief.main_conversation, name: "x", prompt: "x", trigger: { type: "manual" } } })
    q.down.batch = true
    expect(await st.cjStore(a.team, { op: "enqueue", id, run: "cj_run_outbox", trigger: "manual" })).toMatchObject({ status: "accepted" })
    expect(q.runs()).toHaveLength(0)
    const pending = await inDO(st, async (i) => i.ctx.storage.sql.exec(`SELECT state, attempts, next_at FROM cc_job_runs WHERE run = 'cj_run_outbox'`).one())
    expect(pending).toMatchObject({ state: "pending", attempts: 1 })
    expect(pending.next_at).toBeGreaterThan(Date.now())
    // The same run again is not a second run.
    expect(await st.cjStore(a.team, { op: "enqueue", id, run: "cj_run_outbox", trigger: "manual" })).toMatchObject({ status: "duplicate" })
    q.down.batch = false
    await inDO(st, async (i) => {
      i.ctx.storage.sql.exec(`UPDATE cc_job_runs SET next_at = 0 WHERE run = 'cj_run_outbox'`)
      await i.onJob({ job: { id: "cj-send:cj_run_outbox", fn: "cj-send" } })
    })
    expect(q.runs()).toEqual([{ id: "wfr_cj_run_outbox", body: { v: 2, team: a.team, job: id, trigger: "manual" } }])
    expect(await inDO(st, async (i) => i.ctx.storage.sql.exec(`SELECT state FROM cc_job_runs WHERE run = 'cj_run_outbox'`).one().state)).toBe("sent")
  })

  it("without every Upstash setting, jobs stay on the SchedulerDO and both endpoints are off", async () => {
    const before = testEnv.QSTASH_NEXT_SIGNING_KEY
    delete testEnv.QSTASH_NEXT_SIGNING_KEY
    try {
      const raw = JSON.stringify({ v: 2 })
      expect((await deliver(raw, await sign(raw, SIGNING.current))).status).toBe(404)
      expect((await worker.fetch("https://api.test/v1/hooks/chief-job/team_aaaaaaaaaaaaaaaaaaaa/cj-agentx-00000000000000000000", { method: "POST", body: "{}" })).status).toBe(404)
    } finally {
      testEnv.QSTASH_NEXT_SIGNING_KEY = before
    }
  })
})
