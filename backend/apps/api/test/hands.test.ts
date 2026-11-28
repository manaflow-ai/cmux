import { env, exports } from "cloudflare:workers"
import { Effect } from "effect"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { agentProgram, handsLayer, handsProgram, type HandsReport } from "../src/chief-brain/brain-hands.ts"
import { presenceRegistration, proofMessage } from "../src/hand-levels.ts"
import { presenceReplacement } from "../src/hand-presence.ts"
import { jwkThumbprint } from "../src/domains/user.ts"
const jwkThumb = async (k: { kty: string; crv: string; x: string; y: string }) => jwkThumbprint(k)
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
  send({ t: "hello", version: "test", profile, roots: ["/work"], agent_policy: "approve-edits", harnesses: ["claude", "codex", "opencode"], caps: ["levels"], os: "linux", arch: "x86_64", hostname: "sb-3" })
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
  it("runs a sandbox hand at full with no verdict, lets a Chief only lower the level, and raises it only with the owner's app proof", async () => {
    const { token, user, lead } = await owner("hands-levels")
    const { hand, key } = await pairHand(token)
    const seen: Array<any> = []
    await dial(hand, key, "sandbox", (f, send) => {
      if (f.t !== "req") return
      seen.push(f)
      send({ t: "res", id: f.id, ok: true, value: { ran: f.action } })
    })
    // A sandbox starts at full: forwarded with no classifier verdict and no approval; a caller's own _verdict is dropped.
    expect((await http("GET", "/v1/hands", token)).json.value.find((h: any) => h.hand === hand)).toMatchObject({ level: "full" })
    expect((await http("POST", `/v1/hands/${hand}/call`, token, { action: "exec", params: { argv: ["rm", "-rf", "build"], cwd: "/work/p", _verdict: "deny" } })).json).toMatchObject({ ok: true })
    expect(seen.at(-1).params).toMatchObject({ _level: "full", argv: ["rm", "-rf", "build"] })
    expect(seen.at(-1).params._verdict).toBeUndefined()
    expect((await http("GET", `/v1/hands/${hand}/approvals`, token)).json.value).toEqual([])
    // A granted Chief lowers it to read-only: a write is refused before it reaches the hand.
    await http("PUT", `/v1/hands/grants/${lead}`, token, { on: true })
    const chief = (args: any) => Effect.runPromise(Effect.provide(Effect.catch(handsProgram(args), (e) => Effect.succeed({ error: e.code })), handsLayer(testEnv, { kind: "chief", user, agent: lead }))) as Promise<any>
    expect(await chief({ action: "set_level", hand, level: "read-only" })).toMatchObject({ level: "read-only", from: "full" })
    const before = seen.length
    expect((await http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.write", params: { path: "/work/p/a", text: "x" } })).json.error.code).toBe("hand.read_only")
    // A caller's own _level never counts: the Cloud writes the hand's level.
    expect((await http("POST", `/v1/hands/${hand}/call`, token, { action: "exec", params: { argv: ["true"], cwd: "/work/p", _level: "full" } })).json.error.code).toBe("hand.read_only")
    expect(seen.length).toBe(before)
    expect((await http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.read", params: { path: "/work/p/a" } })).json.ok).toBe(true)
    // The Chief cannot raise it back; the person's session alone cannot either.
    expect(await chief({ action: "set_level", hand, level: "full" })).toEqual({ error: "hand.level_refused" })
    expect((await http("PUT", `/v1/hands/${hand}/level`, token, { level: "full" })).json.error.code).toBe("hand.level_refused")
    // With the proof of one of the owner's app installs (an ECDSA P-256 signature over a single-use challenge) it rises.
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).value.id as string
    const sign = async (message: string) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    // The raise is signed by the install's presence key (Secure Enclave, user presence), registered with its install key.
    const presence = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const pj = (await crypto.subtle.exportKey("jwk", presence.publicKey)) as JsonWebKey
    const signWith = async (k: CryptoKey, message: string) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, new TextEncoder().encode(message))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const pub = { kty: "EC", crv: "P-256", x: pj.x!, y: pj.y! }
    expect((await http("PUT", "/v1/hands/presence-key", token, { install, public_jwk: pub, signature: await signWith(presence.privateKey, presenceRegistration(testEnv, install, pub)) })).json.error.code).toBe("hand.presence_refused")
    expect((await http("PUT", "/v1/hands/presence-key", token, { install, public_jwk: pub, signature: await sign(presenceRegistration(testEnv, install, pub)) })).json.ok).toBe(true)
    const { nonce } = (await http("POST", `/v1/hands/${hand}/level-challenge`, token)).json.value
    const bad = await http("PUT", `/v1/hands/${hand}/level`, token, { level: "full", install, nonce, signature: await sign(proofMessage(testEnv, hand, "auto", nonce)) })
    expect(bad.json.error.code).toBe("hand.level_refused")
    // The nonce was spent by the failed try: a new one, signed for the exact target and level.
    const second = (await http("POST", `/v1/hands/${hand}/level-challenge`, token)).json.value.nonce
    // Signed by the install key (no presence): refused. By the presence key: the level rises.
    expect((await http("PUT", `/v1/hands/${hand}/level`, token, { level: "full", install, nonce: second, signature: await sign(proofMessage(testEnv, hand, "full", second)) })).json.error.code).toBe("hand.level_refused")
    const third = (await http("POST", `/v1/hands/${hand}/level-challenge`, token)).json.value.nonce
    const raised = await http("PUT", `/v1/hands/${hand}/level`, token, { level: "full", install, nonce: third, signature: await signWith(presence.privateKey, proofMessage(testEnv, hand, "full", third)) })
    expect(raised.json, JSON.stringify(raised.json)).toMatchObject({ ok: true, value: { level: "full", from: "read-only" } })
    const audit = (await http("GET", `/v1/hands/${hand}/audit`, token)).json.value.filter((a: any) => a.action === "level").map((a: any) => [a.who, a.outcome])
    expect(audit).toEqual([[`session:${user}`, "read-only->full"], [`session:${user}`, "refused:read-only->full"], [`session:${user}`, "refused:read-only->full"], [`session:${user}`, "refused:read-only->full"], [`agent:${lead}`, "refused:read-only->full"], [`agent:${lead}`, "full->read-only"]])
  })

  it("at level ask, holds a write for the owner: a deny needs only the session, an allow needs the app proof", async () => {
    const { token } = await owner("hands-approve")
    const { hand, key } = await pairHand(token)
    let approvalId = ""
    let reqId = ""
    const answers: Array<any> = []
    await dial(hand, key, "sandbox", (f, send) => {
      if (f.t === "req") {
        expect(f.params).toMatchObject({ _level: "ask", _verdict: "ask" })
        approvalId = crypto.randomUUID()
        reqId = f.id
        send({ t: "approve", id: approvalId, req: f.id, summary: { action: f.action } })
        return
      }
      if (f.t === "approval") {
        answers.push(f)
        send({ t: "res", id: reqId, ok: false, error: { code: "policy.owner_denied", message: "the owner did not approve this request" } })
      }
    })
    expect((await http("PUT", `/v1/hands/${hand}/level`, token, { level: "ask" })).json.value).toMatchObject({ level: "ask" })
    // The owner's app socket (the user wire) gets the approval as it happens: no polling.
    const wire = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const appFrames: Array<any> = []
    wire.webSocket!.addEventListener("message", (e) => {
      const f = JSON.parse(e.data as string)
      if (String(f.t).startsWith("hand-approval")) appFrames.push(f)
    })
    wire.webSocket!.accept()
    wire.webSocket!.send(JSON.stringify({ t: "subscribe" }))
    await new Promise((r) => setTimeout(r, 100))
    const pending = http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.write", params: { path: "/work/p/a", text: "x" }, timeout_ms: 5_000 })
    for (let i = 0; i < 50 && !approvalId; i++) await new Promise((r) => setTimeout(r, 20))
    const listed = (await http("GET", `/v1/hands/${hand}/approvals`, token)).json.value
    expect(listed[0]).toMatchObject({ id: approvalId, sign: expect.stringContaining(`:${hand}:${approvalId}:allow`) })
    // An allow without the owner's app proof is refused and changes nothing; a deny goes to the hand.
    expect((await http("POST", `/v1/hands/${hand}/approvals/${approvalId}`, token, { allow: true })).json.error.code).toBe("hand.approval_proof")
    expect((await http("POST", `/v1/hands/${hand}/approvals/${approvalId}`, token, { allow: false })).json).toMatchObject({ ok: true, value: { allow: false } })
    for (let i = 0; i < 50 && answers.length === 0; i++) await new Promise((r) => setTimeout(r, 20))
    expect(answers).toEqual([{ t: "approval", id: approvalId, allow: false }])
    for (let i = 0; i < 50 && appFrames.length < 2; i++) await new Promise((r) => setTimeout(r, 20))
    expect(appFrames).toEqual([
      { t: "hand-approval-pending", hand, id: approvalId, summary: { action: "fs.write" }, at: expect.any(Number), sign: expect.stringContaining(`:${hand}:${approvalId}:allow`) },
      { t: "hand-approval-settled", hand, id: approvalId, outcome: "denied" }
    ])
    expect((await http("POST", `/v1/hands/${hand}/approvals/${approvalId}`, token, { allow: false })).json.error.code).toBe("hand.approval_answered")
    expect((await pending).json.error.code).toBe("policy.owner_denied")
  })

  it("at level auto, reads the classifier's verdict from Haiku and Opus reply shapes and names the reason when it cannot", async () => {
    const { token } = await owner("hands-auto")
    const { hand, key } = await pairHand(token)
    const seen: Array<any> = []
    await dial(hand, key, "sandbox", (f, send) => {
      if (f.t !== "req") return
      seen.push(f)
      send({ t: "res", id: f.id, ok: true, value: { ran: f.action } })
    })
    expect((await http("PUT", `/v1/hands/${hand}/level`, token, { level: "auto" })).json.value).toMatchObject({ level: "auto" })
    const read = (name: string) => http("POST", `/v1/hands/${hand}/call`, token, { action: "fs.read", params: { path: `/work/p/${name}.txt` } })
    for (const shape of ["shape-haiku", "shape-opus", "shape-braces"]) {
      expect((await read(shape)).json, shape).toMatchObject({ ok: true })
      expect(seen.at(-1).params, shape).toMatchObject({ _level: "auto", _verdict: "allow" })
    }
    // A deny after a thought is refused in the Cloud: the hand never sees it.
    const before = seen.length
    expect((await read("shape-thinking")).json.error.code).toBe("hand.classifier_denied")
    expect(seen.length).toBe(before)
    // Prose with no verdict fails closed to ask, and the log says why (size and shape, never the text).
    expect((await read("shape-prose")).json).toMatchObject({ ok: true })
    expect(seen.at(-1).params).toMatchObject({ _verdict: "ask" })
    // A nested (quoted) allow never counts and the reply's own deny wins; two verdicts, or an allow with a non-number confidence, ask.
    expect((await read("shape-injected")).json.error.code).toBe("hand.classifier_denied")
    for (const shape of ["shape-two", "shape-boolconf"]) {
      expect((await read(shape)).json, shape).toMatchObject({ ok: true })
      expect(seen.at(-1).params, shape).toMatchObject({ _verdict: "ask" })
    }
    // A credential path asks by rule, before any model call (a model may refuse to judge it).
    expect((await read(".ssh/config")).json).toMatchObject({ ok: true })
    expect(seen.at(-1).params).toMatchObject({ _verdict: "ask" })
    const log = (await http("GET", `/v1/hands/${hand}/verdicts`, token)).json.value as Array<any>
    expect(log.map((v) => v.verdict).sort()).toEqual(["allow", "allow", "allow", "ask", "ask", "ask", "ask", "deny", "deny"])
    expect(log.find((v) => v.model === "rule")).toMatchObject({ action: "fs.read", verdict: "ask", reason: "it names a credential or key location: the person decides" })
    expect(log.find((v) => v.reason === "the classifier gave more than one verdict")).toBeTruthy()
    expect(log.find((v) => v.reason === "injection")).toMatchObject({ verdict: "deny" })
    expect(log.find((v) => String(v.reason).startsWith("the classifier reply had no readable")).reason).toBe("the classifier reply had no readable verdict (22 chars, stop stop, text)")
    expect(log.find((v) => v.reason === "removes the home folder")).toMatchObject({ verdict: "deny" })
  })

  it("closes an agent prompt's approval when the hand stops waiting for it", async () => {
    const { token } = await owner("hands-expire")
    const { hand, key } = await pairHand(token)
    const sock = await dial(hand, key, "sandbox", () => {})
    const send = (x: unknown) => sock.ws!.send(JSON.stringify(x))
    const wire = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const appFrames: Array<any> = []
    wire.webSocket!.addEventListener("message", (e) => {
      const f = JSON.parse(e.data as string)
      if (String(f.t).startsWith("hand-approval")) appFrames.push(f)
    })
    wire.webSocket!.accept()
    wire.webSocket!.send(JSON.stringify({ t: "subscribe" }))
    await new Promise((r) => setTimeout(r, 100))
    // An agent's permission prompt: its approval names the session, not a Cloud request.
    const id = crypto.randomUUID()
    send({ t: "approve", id, req: "01a1-session", summary: { action: "agent.permission", session: "01a1-session", title: "Bash date" } })
    let listed: Array<any> = []
    for (let i = 0; i < 50 && listed.length === 0; i++) {
      await new Promise((r) => setTimeout(r, 20))
      listed = (await http("GET", `/v1/hands/${hand}/approvals`, token)).json.value
    }
    expect(listed[0]).toMatchObject({ id, summary: { action: "agent.permission" } })
    send({ t: "approval-expired", id })
    for (let i = 0; i < 50 && listed.length > 0; i++) {
      await new Promise((r) => setTimeout(r, 20))
      listed = (await http("GET", `/v1/hands/${hand}/approvals`, token)).json.value
    }
    expect(listed).toEqual([])
    // A late answer is refused: the row is closed, and the app saw it settle as expired.
    expect((await http("POST", `/v1/hands/${hand}/approvals/${id}`, token, { allow: false })).json.error.code).toBe("hand.approval_answered")
    for (let i = 0; i < 50 && appFrames.length < 2; i++) await new Promise((r) => setTimeout(r, 20))
    expect(appFrames.map((f) => [f.t, f.outcome ?? null])).toEqual([["hand-approval-pending", null], ["hand-approval-settled", "expired"]])
  })

  it("replaces an install's presence key only with the current key's signature (or a fresh sign-in) and tells the owner's devices", async () => {
    const { token } = await owner("hands-presence")
    const ec = async () => (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const pubOf = async (k: CryptoKeyPair) => { const j = (await crypto.subtle.exportKey("jwk", k.publicKey)) as JsonWebKey; return { kty: "EC", crv: "P-256", x: j.x!, y: j.y! } }
    const signWith = async (k: CryptoKey, m: string) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, new TextEncoder().encode(m))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const installKey = await ec()
    const install = (await op(token, "install.register", { public_jwk: await pubOf(installKey), kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).value.id as string
    const wire = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const frames: Array<any> = []
    wire.webSocket!.addEventListener("message", (e) => {
      const f = JSON.parse(e.data as string)
      if (f.t === "hand-presence-key") frames.push(f)
    })
    wire.webSocket!.accept()
    wire.webSocket!.send(JSON.stringify({ t: "subscribe" }))
    await new Promise((r) => setTimeout(r, 100))
    const bodyFor = async (k: CryptoKeyPair, extra: Record<string, unknown> = {}) => {
      const pub = await pubOf(k)
      return { install, public_jwk: pub, signature: await signWith(installKey.privateKey, presenceRegistration(testEnv, install, pub)), ...extra }
    }
    const put = async (b: Record<string, unknown>) => (await http("PUT", "/v1/hands/presence-key", token, b)).json
    const state = async () => (await http("GET", `/v1/hands/presence-key?install=${install}`, token)).json.value as { gen: number; thumbprint: string | null }
    // The current key signs the count and both thumbprints (as the client builds it from GET).
    const replaceBy = async (current: CryptoKeyPair, next: CryptoKeyPair) => {
      const s = await state()
      const nextThumb = await jwkThumb(await pubOf(next))
      return bodyFor(next, { current_signature: await signWith(current.privateKey, presenceReplacement(testEnv, install, s.gen, s.thumbprint!, nextThumb)) })
    }
    // The install key itself is never a presence key.
    expect((await put(await bodyFor(installKey))).error.message).toContain("not the install key")
    // The first key needs only the install key's signature.
    const first = await ec()
    expect(await put(await bodyFor(first))).toMatchObject({ ok: true, value: { by: "first", attested: false } })
    expect(await state()).toMatchObject({ gen: 1, thumbprint: await jwkThumb(await pubOf(first)) })
    // A new key signed only by the install key (no fresh sign-in in this test deployment): refused.
    const second = await ec()
    const refused = await put(await bodyFor(second))
    expect(refused.error.code).toBe("hand.presence_refused")
    expect(refused.error.message).toContain("replacing it needs a signature by the current key")
    // Signed by a key that is not the current one: refused.
    expect((await put(await replaceBy(await ec(), second))).error.code).toBe("hand.presence_refused")
    // Signed by the current presence key: replaced. Then back to a third key, then the first one's old body is replayed: refused.
    const toSecond = await replaceBy(first, second)
    expect(await put(toSecond)).toMatchObject({ ok: true, value: { by: "current_key" } })
    const third = await ec()
    expect(await put(await replaceBy(second, third))).toMatchObject({ ok: true, value: { by: "current_key" } })
    expect(await put(await replaceBy(third, first))).toMatchObject({ ok: true, value: { by: "current_key" } })
    expect((await put(toSecond)).error.code).toBe("hand.presence_refused")
    // An attestation the server cannot verify is refused, never ignored.
    const fourth = await ec()
    expect((await put({ ...(await replaceBy(first, fourth)), attestation: "bm90LWFuLWF0dGVzdGF0aW9u", key_id: "a2V5" })).error.code).toBe("hand.presence_refused")
    for (let i = 0; i < 50 && frames.length < 4; i++) await new Promise((r) => setTimeout(r, 20))
    expect(frames.map((f) => [f.install, f.by, f.replaced])).toEqual([[install, "first", false], [install, "current_key", true], [install, "current_key", true], [install, "current_key", true]])
  })

})
