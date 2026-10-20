import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * The Claude Code route of a Cloud Chief (chief-brain-cc/): for an owner on the paid-model list, each turn
 * runs as Claude Code in its own Freestyle VM (joined to the tailnet with a one-use key from the Tailscale
 * API) and streams back to POST /v1/chief-cc/<agent>/<conversation>/notes with a per-turn token; the reply
 * is posted as the Chief, the VM is deleted by its exact id, the team needs no Cloud credits, and the next
 * turn's input carries the earlier reply (the Chief's memory). Freestyle and the Tailscale API are faked at
 * their HTTP boundary; the fake VM plays the turn machine (backend/chief-cc/image/run.mjs) by posting notes
 * to the Worker. One file on purpose: it replaces globalThis.fetch and the route's settings.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace }
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

interface Started { readonly vm: string; readonly run: string; readonly input: { notes_url: string; token: string; prompt: string; system: string; model: string } }
/** Freestyle, the Tailscale API and the turn machine at their HTTP boundary; the Worker's own calls go to the real fetch. */
const fakeCloud = (answer: (prompt: string, n: number) => string) => {
  const real = globalThis.fetch
  const made: Array<{ id: string; body: any }> = []
  const deleted: Array<string> = []
  const boots: Array<{ vm: string; stdin: string }> = []
  const started: Array<Started> = []
  const keys: Array<string> = []
  const other: Array<string> = []
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin === "https://api.tailscale.com") {
      if (url.pathname === "/api/v2/oauth/token") return Response.json({ access_token: "test-ts-access", expires_in: 3600 })
      const key = `tskey-auth-test-${keys.length + 1}`
      keys.push(key)
      expect(req.headers.get("authorization")).toBe("Bearer test-ts-access")
      expect((await req.json()) as any).toMatchObject({ capabilities: { devices: { create: { reusable: false, ephemeral: true, preauthorized: true, tags: ["tag:agent-cloud"] } } } })
      return Response.json({ id: `k${keys.length}`, key })
    }
    if (url.origin !== "https://freestyle.test") {
      if (!url.hostname.endsWith(".test")) return real(input, init)
      other.push(req.url)
      return new Response("not this route", { status: 500 })
    }
    expect(req.headers.get("authorization")).toBe("Bearer test-freestyle-key-not-real")
    if (req.method === "POST" && url.pathname === "/v5/vms") {
      const id = `vm-test${made.length + 1}`
      made.push({ id, body: await req.json() })
      return Response.json({ id })
    }
    const del = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname)
    if (req.method === "DELETE" && del) return deleted.push(del[1]!), Response.json({})
    const ex = /^\/v5\/vms\/([^/]+)\/exec-await$/.exec(url.pathname)
    if (req.method === "POST" && ex) {
      const vm = ex[1]!
      const body = (await req.json()) as { command: string; stdin?: string }
      const stdin = body.stdin ? atob(body.stdin) : ""
      if (body.command.startsWith("/opt/chief-cc/boot.sh ")) return boots.push({ vm, stdin }), Response.json({ statusCode: 0, stdout: "ready\n" })
      const start = /^\/opt\/chief-cc\/start\.sh (run_[0-9]+)$/.exec(body.command)
      if (start) {
        const s: Started = { vm, run: start[1]!, input: JSON.parse(stdin) }
        started.push(s)
        // The turn machine: the stream, then the result, posted to the Worker as run.mjs does.
        setTimeout(() => void machine(s, answer(s.input.prompt, started.length)), 20)
        return Response.json({ statusCode: 0, stdout: "started\n" })
      }
      return Response.json({ statusCode: 0, stdout: "" })
    }
    return new Response("unexpected", { status: 500 })
  })
  return { made, deleted, boots, started, keys, other }
}
const notes = (s: Started, body: unknown, token = s.input.token) => worker.fetch(s.input.notes_url, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
const machine = async (s: Started, reply: string) => {
  const half = Math.floor(reply.length / 2)
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_start" }, { gen: 0, type: "text_delta", delta: reply.slice(0, half) }] })
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_delta", delta: reply.slice(half) }, { gen: 0, type: "text_done", text: reply }, { gen: 0, type: "done" }] })
  await notes(s, { run: s.run, result: { status: "done", reply, model: s.input.model, usage: { input: 3, output: 7, cache_read: 0, cache_write: 0 }, first_token_ms: 900, total_ms: 1500, last_gen: 0 } })
}

/** `cc`: on the Claude Code route's owner list (and the paid-model list); `paid`: on the paid-model list only. */
const enabledChief = async (sub: string, lists: "cc" | "paid" | false) => {
  const listed = lists !== false
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  if (listed) testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  if (lists === "cc") testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const chief = (await op(token, "chief.create", { display_name: "Route Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, listed ? { enabled: true, model: "claude-opus-5-5" } : { enabled: true })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief }
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

describe("Cloud Chief on the Claude Code route", { timeout: 120_000 }, () => {
  it("runs each turn in its own VM on the tailnet, posts the streamed reply with no Cloud credits, deletes the VM, and gives the next turn the earlier reply", async () => {
    const cloud = fakeCloud((prompt, n) => (n === 1 ? "The launch code word is TANGERINE." : prompt.includes("TANGERINE") ? "You told me before: TANGERINE." : "I do not remember."))
    // No credits granted: this route is not charged to them.
    const { token, chief } = await enabledChief("chief-cc-owner", "cc")
    expect((await send(token, chief.main_conversation, "c1", "pick a code word for the launch")).ok).toBe(true)
    const [first] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(first.parts[0].text).toBe("The launch code word is TANGERINE.")
    expect((await send(token, chief.main_conversation, "c2", "what was the code word?")).ok).toBe(true)
    const [, second] = await replies(token, chief.main_conversation, chief.id, 2)
    expect(second.parts[0].text).toBe("You told me before: TANGERINE.")

    // One VM per turn, from the snapshot, with Freestyle's own timers as the backstop; each deleted by its exact id.
    expect(cloud.made).toHaveLength(2)
    for (const m of cloud.made) expect(m.body).toMatchObject({ snapshotId: "sh-test-chief-cc", idleTimeoutSeconds: 300, automaticRestart: false, firewall: { rules: [{ action: "allow", destination: { public: true } }] } })
    for (const m of cloud.made) expect(m.body.slug).toMatch(/^cmuxnp-test-ccb-[0-9a-f]{12}$/)
    expect(cloud.deleted.sort()).toEqual(["vm-test1", "vm-test2"])
    // Each VM joins with its own one-use key, given on stdin only (never in the command line).
    expect(cloud.boots.map((x) => x.stdin)).toEqual(cloud.keys)
    // The turn input: the person's message, the Chief's system prompt and model; the Worker's own notes URL.
    expect(cloud.started[0]!.input.prompt).toContain("pick a code word for the launch")
    expect(cloud.started[0]!.input.system).toContain("Name: Route Chief")
    expect(cloud.started[0]!.input.model).toBe("claude-opus-5-5")
    expect(cloud.started[0]!.input.notes_url).toBe(`https://api.test/v1/chief-cc/${chief.id}/${chief.main_conversation}/notes`)
    // No call to the Cloud model route.
    expect(cloud.other).toEqual([])

    // The run: done, its reply step, usage and the first-token mark.
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    expect(runs.map((r) => r.status)).toEqual(["done", "done"])
    const run = (await http("GET", `/v1/chiefs/${chief.id}/runs/${runs[1].id}?conversation=${chief.main_conversation}`, token)).json.value
    expect(run.steps.filter((s: any) => s.kind === "talk").map((s: any) => s.text)).toEqual(["The launch code word is TANGERINE."])
    // Neither the tailnet key nor the turn token reaches a reply or a run.
    const all = JSON.stringify([await history(token, chief.main_conversation), runs, run])
    for (const secret of [...cloud.keys, ...cloud.started.map((s) => s.input.token)]) expect(all).not.toContain(secret)
  })

  it("refuses notes without the running turn's token, and after the turn ended", async () => {
    const cloud = fakeCloud(() => "noted")
    const { token, chief } = await enabledChief("chief-cc-notes", "cc")
    expect((await send(token, chief.main_conversation, "n1", "hello")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect((await notes(s, { run: s.run, events: [] }, "not-the-token")).status).toBe(401)
    expect((await notes(s, { run: s.run, events: [] })).status).toBe(401)
    expect((await worker.fetch(s.input.notes_url, { method: "POST", body: "{}" })).status).toBe(401)
  })

  it.each([
    ["off the paid-model list", "chief-cc-other", false],
    ["on the paid-model list but not on the Claude Code route's list", "chief-cc-paid", "paid"]
  ] as const)("leaves an owner %s on the brain they had: no VM", async (_, sub, on) => {
    const cloud = fakeCloud(() => "never")
    const { token, chief } = await enabledChief(sub, on)
    expect((await send(token, chief.main_conversation, "o1", "hi there")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).not.toBe("never")
    expect(cloud.made).toHaveLength(0)
  })
})
