import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * `spawn(tasks[])` of a Cloud Chief (chief-brain/brain-spawn.ts): subagents with no hand. A person
 * writes to the Chief over POST /v1/ops; the fake model calls `spawn` ("tool:spawn {...}"); each task
 * runs in its own child brain object; each report comes back as a `work` card in the conversation and
 * reaches the Chief's next (or running) turn. Fake model, real Worker boundary.
 */
const testEnv = env as unknown as Record<string, any>
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
  return { status: res.status, json: (await res.json()) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 100 } })).json.value.messages as Array<any>
const brain = (name: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(name))
const sql = <T,>(name: string, q: string, ...args: Array<unknown>) => runInDurableObject(brain(name), async (_i: unknown, s: DurableObjectState) => s.storage.sql.exec(q, ...args).toArray() as Array<T>)

const SAVED = ["CHIEF_SPAWN_MAX", "CHIEF_SPAWN_MODEL", "CHIEF_SPAWN_KEEP_DAYS"].map((k) => [k, testEnv[k]] as const)
afterEach(() => {
  for (const [k, v] of SAVED) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
  vi.restoreAllMocks()
})

const setup = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Spawn Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any }
  for (let i = 0; i < 20 && on.status !== 200; i++) [await fireAlarm(userDO), (on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true }))]
  expect(on.status).toBe(200)
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
  const mine = async () => (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
  const cards = async () => (await mine()).filter((m) => m.parts[0]?.type === "work" && String(m.parts[0].session).startsWith("sub_"))
  const say = async (key: string, text: string) => expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)).ok).toBe(true)
  /** Drives the wake path (conversation outbox, parent and child objects' jobs) until `done` holds. */
  const until = async (done: () => Promise<boolean>, what: string, tick?: () => Promise<unknown>) => {
    for (let i = 0; i < 600; i++) {
      if (await done()) return
      await fireAlarm(conv)
      if (tick) await tick()
      if (i % 10 === 9) await fireAlarm(brain(`${chief.id}/${chief.main_conversation}`)).catch(() => undefined)
      await new Promise((r) => setTimeout(r, 25))
    }
    throw new Error(`timed out waiting for ${what}`)
  }
  const child = (n: number) => `${chief.id}/${chief.main_conversation}:spawn:${n}`
  const run = async (id: string) => (await http("GET", `/v1/chiefs/${chief.id}/runs/${id}?conversation=${chief.main_conversation}`, token))
  return { token, chief, mine, cards, say, until, child, run }
}

/** The fake model's tool call; "SLOW" (a slow child stream) is JSON-escaped so the parent's own turn streams fast. */
const spawnText = (tasks: Array<string>) => `tool:spawn ${JSON.stringify({ tasks }).replaceAll("SLOW", "\\u0053LOW")}`

describe("a Cloud Chief spawns subagents with no hand", { timeout: 180_000 }, () => {
  it("returns three names at once, runs three child runs, and answers with their three work reports", async () => {
    const t = await setup("spawn-three")
    await t.say("k1", spawnText(["SLOW compute alpha " + "x ".repeat(40), "SLOW compute beta " + "x ".repeat(40), "SLOW compute gamma " + "x ".repeat(40)]))
    await t.until(async () => (await t.cards()).length === 3 && (await t.mine()).some((m) => m.parts[0]?.type === "text" && /\[(Ada|Bo|Cy)\]/.test(m.parts[0].text)), "three reports and an answer that uses them")
    const all = await t.mine()
    // The spawn answer names the three children and comes before any report (the tool never waits).
    const first = all.find((m) => m.parts[0]?.type === "text")!
    expect(first.parts[0].text).toContain("Ada, Bo, Cy")
    const cards = await t.cards()
    expect(cards.map((m) => m.parts[0].session).sort()).toEqual(["sub_1", "sub_2", "sub_3"])
    expect(Math.min(...cards.map((m) => m.seq))).toBeGreaterThan(first.seq)
    // The spawn tool step ended before any child did.
    const parentRun = (await t.run(first.parts[1].session)).json.value
    const tool = parentRun.steps.find((s: any) => s.kind === "tool" && s.tool?.name === "spawn")
    expect(tool.tool.output).toContain("Ada, Bo, Cy")
    for (const c of cards) expect(c.parts[0].preview).toMatch(/^(Ada|Bo|Cy): \[fake-echo\] reply to: Task:/)
    // Three child runs, each its own object, readable by a member through the runs route.
    for (const n of [1, 2, 3]) {
      const r = await t.run(`sub_${n}`)
      expect(r.status).toBe(200)
      expect(r.json.value.run.status).toBe("done")
      expect(r.json.value.run.parent_run).toBe(parentRun.run.id)
      expect(r.json.value.run.ended_at).toBeGreaterThan(tool.tool.ended_at)
      expect((await sql<{ n: number }>(t.child(n), `SELECT COUNT(*) AS n FROM cb_turn`))[0]!.n).toBe(1)
    }
  })

  it("never runs more children of one Chief than CHIEF_SPAWN_MAX at once, and all of them report", async () => {
    testEnv.CHIEF_SPAWN_MAX = "2"
    const t = await setup("spawn-cap")
    await t.say("k1", spawnText([1, 2, 3, 4, 5, 6].map((i) => `SLOW task ${i} ` + "y ".repeat(60))))
    let most = 0
    const running = async () => {
      const r = await sql<{ n: number }>(t.chief.id, `SELECT COUNT(*) AS n FROM cb_spawn_slot WHERE state = 'running'`)
      most = Math.max(most, Number(r[0]!.n))
    }
    await t.until(async () => (await t.cards()).length === 6, "six reports", running)
    expect(most).toBe(2)
    expect((await sql<{ n: number }>(t.chief.id, `SELECT COUNT(*) AS n FROM cb_spawn_slot`))[0]!.n).toBe(0)
  })

  it("still reports when a child object restarts in the middle of its run", async () => {
    const t = await setup("spawn-restart")
    await t.say("k1", spawnText(["SLOW a long task " + "z ".repeat(150)]))
    await t.until(async () => (await sql<{ n: number }>(t.child(1), `SELECT COUNT(*) AS n FROM cb_turn WHERE status = 'running' AND submitted = 1`).catch(() => [{ n: 0 }]))[0]!.n > 0, "the child's run to start")
    await runInDurableObject(brain(t.child(1)), async (_i: unknown, s: DurableObjectState) => {
      try {
        s.abort("test: restart the child mid-run")
      } catch {}
    }).catch(() => undefined)
    await t.until(async () => (await t.cards()).length === 1, "the restarted child's report", () => fireAlarm(brain(t.child(1))).catch(() => undefined))
    const card = (await t.cards())[0]!
    expect(card.parts[0].status).toBe("done")
    expect(card.parts[0].preview).toContain("a long task")
    expect((await t.run("sub_1")).json.value.run.status).toBe("done")
  })

  it("deletes a child's storage after its report, and members still read its run from the parent", async () => {
    testEnv.CHIEF_SPAWN_KEEP_DAYS = "0"
    const t = await setup("spawn-gc")
    await t.say("k1", spawnText(["compute delta"]))
    await t.until(async () => (await t.cards()).length === 1, "the report")
    // The cleanup job is due at once (0 days): the child's alarm runs it.
    await t.until(async () => (await sql<{ n: number }>(t.child(1), `SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'cb_turn'`).catch(() => [{ n: 1 }]))[0]!.n === 0, "the child's storage to go", () => fireAlarm(brain(t.child(1))).catch(() => undefined))
    const r = await t.run("sub_1")
    expect(r.status).toBe(200)
    expect(r.json.value.run).toMatchObject({ id: "sub_1", status: "done" })
    expect(r.json.value.steps.some((s: any) => s.kind === "talk")).toBe(true)
  })

  it("ends children with an out-of-credits report and no model call when the team has no credits", async () => {
    testEnv.CHIEF_SPAWN_MODEL = "claude-opus-5-5"
    const real = globalThis.fetch
    const upstream: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input instanceof Request ? input.url : String(input)
      if (url.startsWith("https://claude.test/")) upstream.push(url)
      return real(input, init)
    })
    const t = await setup("spawn-credits")
    await t.say("k1", spawnText(["compute one", "compute two"]))
    await t.until(async () => (await t.cards()).length === 2, "two reports")
    for (const c of await t.cards()) {
      expect(c.parts[0].status).toBe("failed")
      expect(c.parts[0].preview).toContain("out of Cloud credits")
    }
    for (const n of [1, 2]) expect((await t.run(`sub_${n}`)).json.value.run.status).toBe("failed")
    expect(upstream).toHaveLength(0)
    expect((await sql<{ n: number }>(t.child(1), `SELECT COUNT(*) AS n FROM cb_usage`))[0]!.n).toBe(0)
  })
})
