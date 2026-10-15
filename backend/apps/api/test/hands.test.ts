import { env, exports } from "cloudflare:workers"
import { Effect } from "effect"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { agentProgram, handsLayer, type HandsReport } from "../src/chief-brain/brain-hands.ts"
import type { Env } from "../src/env.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Chief hands at the Worker boundary (hand-routes.ts, HandDO, chief-brain/brain-hands.ts). The test
 * plays the hand's end of the wire (cmux-tui/crates/acpmux/src/hand/link.rs speaks the same
 * frames): it pairs with a single-use code, dials the socket with its own key, and answers
 * requests. The person drives the HTTP routes; a Chief drives the brain's `agent` tool program.
 */
const testEnv = env as unknown as Env & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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
const http = async (method: string, path: string, token: string | undefined, body?: unknown) => {
  const headers: Record<string, string> = { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }
  const res = await worker.fetch(`https://api.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))), (b) => b.toString(16).padStart(2, "0")).join("")
const newKey = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** The hand's end: dial, say hello, answer requests with `answer`. */
const dial = async (hand: string, key: string, profile: "sandbox" | "mac", answer: (f: any, send: (x: unknown) => void) => void) => {
  const res = await worker.fetch(`https://api.test/v1/hands/${hand}/socket`, { headers: { Upgrade: "websocket", authorization: `Bearer ${key}` } })
  const ws = res.webSocket
  const frames: Array<any> = []
  const closes: Array<number> = []
  if (!ws) return { status: res.status, frames, closes, ws: null }
  const send = (x: unknown) => ws.send(JSON.stringify(x))
  ws.addEventListener("message", (e) => {
    const f = JSON.parse(e.data as string)
    frames.push(f)
    answer(f, send)
  })
  ws.addEventListener("close", (e) => {
    closes.push(e.code)
  })
  ws.accept()
  send({ t: "hello", version: "test", profile, roots: ["/work"], agent_policy: "approve-edits", harnesses: ["claude", "codex", "opencode"], os: "linux", arch: "x86_64", hostname: "sb-3" })
  return { status: res.status, frames, closes, ws }
}

const owner = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  await op(token, "chief.create", { display_name: "Chief" }, `default-${sub}`)
  const lead = (await op(token, "chief.create", { display_name: "Lead" }, `lead-${sub}`)).value as { id: string }
  for (let i = 0; i < 5; i++) await fireAlarm(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)))
  return { token, user, lead: lead.id }
}

const pairHand = async (token: string, profile: "sandbox" | "mac" = "sandbox") => {
  const minted = await http("POST", "/v1/hands/pair-codes", token, { name: "sb-3", profile })
  expect(minted.status, JSON.stringify(minted.json)).toBe(200)
  const { hand, code, install } = minted.json.value as { hand: string; code: string; install: string }
  expect(install).toContain(`/hand/install.sh | sh -s -- --pair ${code}`)
  const key = newKey()
  const paired = await http("POST", "/v1/hands/pair", undefined, { code, key_sha256: await sha(key), name: "sb-3", profile })
  expect(paired.json).toMatchObject({ ok: true, value: { hand } })
  return { hand, code, key }
}

describe("Chief hands", { timeout: 60_000 }, () => {
  it("pairs once, authenticates the hand by its key, and answers the person's calls with an audit row", async () => {
    const { token } = await owner("hands-pair")
    const { hand, code, key } = await pairHand(token)
    // Single use: the same code again is refused.
    expect((await http("POST", "/v1/hands/pair", undefined, { code, key_sha256: await sha(newKey()), name: "x", profile: "sandbox" })).json.error.code).toBe("hand.pair_invalid")
    // A wrong key gets no socket.
    expect((await dial(hand, newKey(), "sandbox", () => undefined)).status).toBe(403)
    const h = await dial(hand, key, "sandbox", (f, send) => {
      if (f.t === "req" && f.action === "fs.read") send({ t: "res", id: f.id, ok: true, value: { text: "hello\n", sha256: "abc", path: f.params.path } })
      if (f.t === "req" && f.action === "fs.edit") send({ t: "res", id: f.id, ok: false, error: { code: "fs.edit.ambiguous", message: "found 2 times" } })
    })
    expect(h.status).toBe(101)
    const read = await http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.read", params: { path: "/work/a.txt" } })
    expect(read.json).toMatchObject({ ok: true, value: { text: "hello\n", sha256: "abc" } })
    const edit = await http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.edit", params: { path: "/work/a.txt", edits: [{ old: "l", new: "L" }], expect_sha256: "abc" } })
    expect(edit.json.error.code).toBe("fs.edit.ambiguous")
    expect((await http("POST", `/v1/hands/${hand}/call`, token, { action: "rm -rf", params: {} })).json.error.code).toBe("hand.bad_action")
    const listed = (await http("GET", "/v1/hands", token)).json.value as Array<{ hand: string; online: boolean; profile: string }>
    expect(listed.find((x) => x.hand === hand)).toMatchObject({ profile: "sandbox" })
    const audit = (await http("GET", `/v1/hands/${hand}/audit`, token)).json.value as Array<{ action: string; outcome: string; who: string }>
    expect(audit.map((a) => [a.action, a.outcome])).toEqual([["rm -rf", "hand.bad_action"], ["fs.edit", "fs.edit.ambiguous"], ["fs.read", "ok"]])
    // Another person sees no such hand.
    const other = await sessionToken("hands-pair-other")
    await op(other, "user.ensure", {})
    expect((await http("POST", `/v1/hands/${hand}/call`, other, { action: "fs.read", params: { path: "/" } })).status).toBe(404)
    // Removal closes the socket and the key stops working.
    expect((await http("DELETE", `/v1/hands/${hand}`, token)).status).toBe(200)
    expect(h.closes).toContain(4403)
    expect((await dial(hand, key, "sandbox", () => undefined)).status).toBe(403)
  })

  it("lets a granted Chief run an agent on a hand and streams its events back as activity", async () => {
    const { token, user, lead } = await owner("hands-agent")
    const { hand, key } = await pairHand(token)
    const caller = { kind: "chief" as const, user, agent: lead }
    const reports: Array<HandsReport> = []
    const program = agentProgram({ action: "start", hand: "sb-3", harness: "codex", cwd: "/work/app", prompt: "fix the typo", wait_seconds: 30 }, (r) => reports.push(r), "call-1")
    const run = () => Effect.runPromise(Effect.provide(Effect.catch(program, (e) => Effect.succeed({ error: e.code })), handsLayer(testEnv, caller))) as Promise<any>
    // No grant yet: refused before anything reaches the hand.
    expect(await run()).toEqual({ error: "hand.no_grant" })
    expect((await http("PUT", `/v1/hands/grants/${lead}`, token, { on: true })).json.value.grants).toEqual([lead])
    await dial(hand, key, "sandbox", (f, send) => {
      if (f.t !== "req" || f.action !== "agent.start") return
      send({ t: "res", id: f.id, ok: true, value: { session: "sess-1", harness: "codex", cwd: f.params.cwd } })
      send({ t: "event", session: "sess-1", seq: 1, event: { kind: "turn_start" } })
      send({ t: "event", session: "sess-1", seq: 2, event: { kind: "tool", update: false, id: "t1", title: "Edit src/app.ts", status: "pending" } })
      send({ t: "event", session: "sess-1", seq: 3, event: { kind: "text", text: "Fixed the typo in src/app.ts." } })
      send({ t: "event", session: "sess-1", seq: 4, event: { kind: "turn_end", stop_reason: "end_turn" } })
    })
    const done = await run()
    expect(done).toMatchObject({ session: "sess-1", done: true, stop_reason: "end_turn", text: "Fixed the typo in src/app.ts.", tools: ["Edit src/app.ts"] })
    const lines = reports.filter((r) => r.type === "run.activity").map((r) => (r as { line: string }).line)
    expect(lines[0]).toBe("Running codex in sb-3 · 0s")
    expect(reports.some((r) => r.type === "step.upsert" && r.step.id === "tool:call-1")).toBe(true)
    const audit = (await http("GET", `/v1/hands/${hand}/audit`, token)).json.value as Array<{ action: string; who: string; outcome: string }>
    expect(audit[0]).toMatchObject({ action: "agent.start", who: `agent:${lead}`, outcome: "ok" })
  })

  it("refuses Cloud requests to a mac hand until the trust review turns them on", async () => {
    const { token } = await owner("hands-mac")
    const { hand, key } = await pairHand(token, "mac")
    const h = await dial(hand, key, "mac", (f, send) => f.t === "req" && send({ t: "res", id: f.id, ok: true, value: {} }))
    expect(h.status).toBe(101)
    const r = await http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.list", params: { path: "/Users" } })
    expect(r.json.error.code).toBe("hand.mac_disabled")
    expect(h.frames.filter((f) => f.t === "req")).toHaveLength(0)
  })
})
