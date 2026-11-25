import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  AGENT_CALL_DEBOUNCE_MS,
  audioText,
  audioToken,
  callKey,
  callScript,
  callTrigger,
  decideCall,
  maskNumber,
  normalizeNumber,
  twiml,
  verifyScript,
  type AgentCallSettings
} from "../src/agent-call.ts"
import worker from "../src/index.ts"
import { register, token } from "./helpers.ts"

// Agent Calls (PROTOCOL.md "Agent calls"): the same triggers and the same 30 second rule as the iPhone's Agent
// Alarms, a number verified by a call that reads a code, and nothing said but the kind and the names.

afterEach(() => vi.restoreAllMocks())

const on: AgentCallSettings = { enabled: true, triggers: ["permission", "question", "needsInput", "agentFailed"], number: "+14155550100", pendingNumber: null }

describe("the rule", () => {
  it("rings for the iPhone's triggers and nothing else", () => {
    expect(callTrigger({ kind: "permission" })).toBe("permission")
    expect(callTrigger({ kind: "question" })).toBe("question")
    expect(callTrigger({ kind: "failed" })).toBe("agentFailed")
    expect(callTrigger({ kind: "terminal", state: "waiting" })).toBe("needsInput")
    expect(callTrigger({ kind: "terminal", state: "failed" })).toBe("agentFailed")
    for (const e of [{ kind: "completed" }, { kind: "chief" }, { kind: "terminal" }, { kind: "terminal", state: "finished" }, { kind: "terminal", state: "notified" }] as const)
      expect(callTrigger(e)).toBeNull()
  })

  it("keys an ask by its permission id, like the iPhone", () => {
    expect(callKey("mac", { eventId: "e", permissionId: "p1" })).toBe("ask:p1")
    expect(callKey("mac", { eventId: "e2" })).toBe("event:mac:e2")
  })

  it("calls at most once in 30 seconds and once per event", () => {
    const t0 = 1_800_000_000_000
    expect(decideCall(on, "permission", false, null, t0)).toEqual({ decision: "call", number: on.number })
    expect(decideCall(on, "question", false, t0, t0 + 1_000)).toEqual({ decision: "debounced", waitMs: 29_000 })
    expect(decideCall(on, "question", false, t0, t0 + 29_999).decision).toBe("debounced")
    expect(decideCall(on, "question", false, t0, t0 + AGENT_CALL_DEBOUNCE_MS).decision).toBe("call")
    expect(decideCall(on, "permission", true, null, t0).decision).toBe("duplicate")
    // A clock moved back holds.
    expect(decideCall(on, "permission", false, t0, t0 - 60_000)).toEqual({ decision: "debounced", waitMs: 30_000 })
  })

  it("never calls when off, without a number, or with the trigger off", () => {
    expect(decideCall({ ...on, enabled: false }, "permission", false, null, 0).decision).toBe("off")
    expect(decideCall({ ...on, number: null }, "permission", false, null, 0).decision).toBe("no_number")
    expect(decideCall({ ...on, triggers: ["question"] }, "permission", false, null, 0).decision).toBe("trigger_off")
  })
})

describe("what the call says", () => {
  it("names the agent and the Mac and nothing else", () => {
    expect(callScript("permission", "Mac mini", "Claude Code")).toBe("Hi, this is cmux. Claude Code on Mac mini needs your permission. Open cmux to answer.")
    expect(callScript("question", "Studio", undefined)).toBe("Hi, this is cmux. An agent on Studio has a question for you. Open cmux to answer.")
    expect(callScript("needsInput", "MacBook Pro", "Codex")).toContain("is waiting for you in its terminal")
    expect(callScript("agentFailed", "MacBook Pro", "Codex")).toContain("stopped and needs you")
    // Markup or a command in a name is not read out.
    expect(callScript("permission", "<Mac>", "rm -rf /; echo")).not.toMatch(/[<>;/]/)
  })

  it("reads a code digit by digit, twice", () => {
    expect(verifyScript("042917")).toBe("Hi, this is cmux. Your verification code is 0, 4, 2, 9, 1, 7. Again, 0, 4, 2, 9, 1, 7.")
  })

  it("plays the voice twice, or says it with Twilio's voice, escaped", () => {
    expect(twiml("a & b", "https://x/v1/agent-call/audio/t")).toBe(
      '<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/><Play>https://x/v1/agent-call/audio/t</Play><Pause length="1"/><Play>https://x/v1/agent-call/audio/t</Play></Response>'
    )
    expect(twiml("a & <b>")).toContain("<Say>a &amp; &lt;b&gt;</Say>")
  })

  it("takes numbers with their country code only", () => {
    expect(normalizeNumber("+1 (415) 555-0100")).toBe("+14155550100")
    expect(normalizeNumber("+44 20 7946 0958")).toBe("+442079460958")
    for (const bad of ["4155550100", "+0123456789", "+1 415", "call me", 14155550100]) expect(normalizeNumber(bad)).toBeNull()
    expect(maskNumber("+14155550100")).toBe("+14••• ••0100")
  })
})

describe("signed audio links", () => {
  it("carry the text, expire, and refuse a forged or altered link", async () => {
    const now = 1_800_000_000_000
    const tok = await audioToken("k", "Hi, this is cmux.", now)
    expect(await audioText("k", tok, now + 1_000)).toBe("Hi, this is cmux.")
    expect(await audioText("k", tok, now + 11 * 60_000)).toBeNull()
    expect(await audioText("other", tok, now)).toBeNull()
    const [body, sig] = tok.split(".")
    expect(await audioText("k", `${body}x.${sig}`, now)).toBeNull()
    expect(await audioText("k", "garbage", now)).toBeNull()
  })

  it("is the one route reachable with no bearer, and only with a valid link", async () => {
    const bad = await worker.fetch(new Request("https://api.test/v1/agent-call/audio/nope.nope"), env as never, createExecutionContext())
    expect(bad.status).toBe(404)
  })
})

/** What a placed call says: through its signed MeloTTS link, or its `<Say>` (the tests have no AI binding). */
const spoken = async (body: string): Promise<string> => {
  const link = body.match(/\/audio\/([^<]+)</)?.[1]
  if (link) return (await audioText("agent-call-test-key", link, Date.now())) ?? ""
  return body.match(/<Say>([^<]*)<\/Say>/)?.[1] ?? ""
}
const codeOf = async (body: string) => (await spoken(body)).match(/code is ([\d, ]+)\./)![1]!.replace(/[, ]/g, "")

/** Twilio answering 201, with every call it was asked to place. */
const twilio = () => {
  const calls: Array<{ to: string; twiml: string }> = []
  const realFetch = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const req = input instanceof Request ? input : new Request(String(input), init)
    if (req.url.startsWith("https://api.twilio.com/2010-04-01/Accounts/ACtest/Calls.json")) {
      expect(req.headers.get("authorization")).toBe(`Basic ${btoa("ACtest:twilio-test-token")}`)
      const form = new URLSearchParams(await req.text())
      expect(form.get("From")).toBe("+14155550199")
      calls.push({ to: form.get("To")!, twiml: form.get("Twiml")! })
      return Response.json({ sid: `CA${calls.length}` }, { status: 201 })
    }
    return realFetch(input, init)
  })
  return calls
}

const send = async (t: string, method: string, path: string, body?: unknown) => {
  const ctx = createExecutionContext()
  const res = await worker.fetch(
    new Request(`https://api.test${path}`, {
      method,
      headers: { "content-type": "application/json", authorization: `Bearer ${t}` },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    }),
    env as never,
    ctx
  )
  await waitOnExecutionContext(ctx)
  return { status: res.status, json: (await res.json()) as any }
}

/** A person with a Mac and a verified number (the code read out of the faked call). */
const verified = async (name: string, calls: Array<{ to: string; twiml: string }>) => {
  const t = await token(name)
  const mac = await register(t, "mac", `personal-${name}`)
  const started = await send(t, "POST", "/v1/me/agent-call/verify", { number: "+1 415 555 0100" })
  expect(started.status).toBe(200)
  expect(started.json.calling).toBe("+14••• ••0100")
  const code = await codeOf(calls.at(-1)!.twiml)
  expect(code).toMatch(/^\d{6}$/)
  return { t, mac, code }
}

describe("routes", () => {
  it("verifies a number by a call that reads the code, then turns calls on", async () => {
    const calls = twilio()
    const { t, code } = await verified("callie", calls)
    const before = await send(t, "GET", "/v1/me/agent-call")
    expect(before.json).toMatchObject({ configured: true, enabled: false, number: null, pendingNumber: "+14••• ••0100" })
    expect((await send(t, "POST", "/v1/me/agent-call/confirm", { code: code === "000000" ? "111111" : "000000" })).status).toBe(400)
    const ok = await send(t, "POST", "/v1/me/agent-call/confirm", { code })
    expect(ok.status).toBe(200)
    expect(ok.json).toMatchObject({ enabled: true, number: "+14••• ••0100", pendingNumber: null })
    expect(calls[0]!.to).toBe("+14155550100")
  })

  it("refuses a number with no country code", async () => {
    twilio()
    const t = await token("nocc")
    const r = await send(t, "POST", "/v1/me/agent-call/verify", { number: "415 555 0100" })
    expect(r.status).toBe(400)
  })

  it("gives up a code after five wrong tries", async () => {
    const calls = twilio()
    const { t, code } = await verified("tries", calls)
    const wrong = code === "123456" ? "654321" : "123456"
    const statuses = []
    for (let i = 0; i < 5; i++) statuses.push((await send(t, "POST", "/v1/me/agent-call/confirm", { code: wrong })).status)
    expect(statuses).toEqual([400, 400, 400, 400, 410])
    expect((await send(t, "POST", "/v1/me/agent-call/confirm", { code })).status).toBe(410)
  })

  it("places at most three code calls an hour", async () => {
    twilio()
    const t = await token("spammer")
    const statuses = []
    for (let i = 0; i < 4; i++) statuses.push((await send(t, "POST", "/v1/me/agent-call/verify", { number: "+14155550100" })).status)
    expect(statuses).toEqual([200, 200, 200, 429])
  })

  it("calls for a Mac's ask, holds a second within 30 s, and never calls twice for one ask", async () => {
    const calls = twilio()
    const { t, mac, code } = await verified("asker", calls)
    await send(t, "POST", "/v1/me/agent-call/confirm", { code })
    const n0 = calls.length
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e1", kind: "permission", permissionId: "p1", agent: "Claude Code" })
    expect(calls.length).toBe(n0 + 1)
    expect(await spoken(calls.at(-1)!.twiml)).toMatch(/^Hi, this is cmux\. Claude Code on mac-\w+ needs your permission\. Open cmux to answer\.$/)
    // A second event 0 s later: held.
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e2", kind: "question", permissionId: "q1", agent: "Codex" })
    // The same ask again: never.
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e1", kind: "permission", permissionId: "p1", agent: "Claude Code" })
    // A finished turn: never.
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e3", kind: "completed", sessionId: "s1" })
    expect(calls.length).toBe(n0 + 1)
    const view = await send(t, "GET", "/v1/me/agent-call")
    expect(view.json.log.map((l: { decision: string }) => l.decision)).toEqual(["debounced", "call"])
  })

  it("calls nobody when off or for a trigger turned off", async () => {
    const calls = twilio()
    const { t, mac, code } = await verified("quiet", calls)
    await send(t, "POST", "/v1/me/agent-call/confirm", { code })
    await send(t, "PUT", "/v1/me/agent-call", { triggers: ["question"] })
    const n0 = calls.length
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e1", kind: "permission", permissionId: "p9" })
    await send(t, "PUT", "/v1/me/agent-call", { enabled: false })
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e2", kind: "question", permissionId: "q9" })
    expect(calls.length).toBe(n0)
  })

  it("test call: held by the same 30 s window; removing the number turns calls off", async () => {
    const calls = twilio()
    const { t, code } = await verified("tester", calls)
    await send(t, "POST", "/v1/me/agent-call/confirm", { code })
    // The code call itself was 0 s ago, but only agent and test calls count for the window.
    const first = await send(t, "POST", "/v1/me/agent-call/test")
    expect(first.status).toBe(200)
    expect((await send(t, "POST", "/v1/me/agent-call/test")).status).toBe(429)
    const removed = await send(t, "PUT", "/v1/me/agent-call", { number: null })
    expect(removed.json).toMatchObject({ enabled: false, number: null })
    expect((await send(t, "POST", "/v1/me/agent-call/test")).status).toBe(409)
  })

  it("a Twilio refusal is in Recent, and the ask is not retried", async () => {
    const t = await token("refused")
    const mac = await register(t, "mac", "personal-refused")
    let fail = false
    const realFetch = globalThis.fetch
    const placed: Array<string> = []
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const req = input instanceof Request ? input : new Request(String(input), init)
      if (req.url.includes("api.twilio.com")) {
        const form = new URLSearchParams(await req.text())
        placed.push(form.get("Twiml")!)
        return fail ? Response.json({ code: 21215, message: "geo" }, { status: 400 }) : Response.json({ sid: "CA" }, { status: 201 })
      }
      return realFetch(input, init)
    })
    await send(t, "POST", "/v1/me/agent-call/verify", { number: "+14155550100" })
    const code = await codeOf(placed[0]!)
    await send(t, "POST", "/v1/me/agent-call/confirm", { code })
    fail = true
    await send(t, "POST", `/v1/devices/${mac}/notify`, { eventId: "e1", kind: "failed", agent: "Codex" })
    const view = await send(t, "GET", "/v1/me/agent-call")
    expect(view.json.log[0]).toMatchObject({ trigger: "agentFailed", decision: "failed", reason: "twilio 400 21215" })
  })

  it("says it is not set up on a server without Twilio", async () => {
    const t = await token("unset")
    const bare = { ...env, TWILIO_ACCOUNT_SID: undefined } as never
    const ctx = createExecutionContext()
    const res = await worker.fetch(new Request("https://api.test/v1/me/agent-call", { headers: { authorization: `Bearer ${t}` } }), bare, ctx)
    expect(((await res.json()) as any).configured).toBe(false)
    const v = await worker.fetch(
      new Request("https://api.test/v1/me/agent-call/verify", { method: "POST", headers: { authorization: `Bearer ${t}`, "content-type": "application/json" }, body: '{"number":"+14155550100"}' }),
      bare,
      createExecutionContext()
    )
    expect(v.status).toBe(503)
  })
})
