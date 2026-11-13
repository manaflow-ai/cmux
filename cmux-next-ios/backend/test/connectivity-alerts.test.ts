import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import {
  applyReport,
  audienceOf,
  ConnectivityAlertDesk,
  duration,
  emptyDesk,
  isTeamEmail,
  LIMITS,
  parseReport,
  type IncidentReport,
  type SlackCall
} from "../src/connectivity-alerts.ts"
import { call, PROD_PROJECT, token } from "./helpers.ts"

const PATH = "/v1/diagnostics/connectivity-incidents"
const T0 = Date.parse("2026-11-12T16:00:00.000Z")

/** A valid report body; `over` replaces fields. */
const body = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  id: crypto.randomUUID(),
  kind: "mac_unreachable",
  state: "open",
  startedAt: new Date(Date.now() - 31_000).toISOString(),
  observedAt: new Date().toISOString(),
  durationMs: 31_000,
  mac: { id: "0f3c2a9e-1111-2222-3333-444455556666", name: "Studio" },
  attempts: 6,
  lastError: "dial timed out after 25 s",
  transport: "wireguard",
  serviceReachable: true,
  network: "wifi",
  app: { version: "1.2.0", build: "450", config: "TestFlight", simulator: false },
  device: { model: "iPhone17,4", os: "27.2" },
  ...over
})
const report = (over: Record<string, unknown> = {}, at = T0): IncidentReport =>
  parseReport(body({ startedAt: new Date(at - 31_000).toISOString(), observedAt: new Date(at).toISOString(), ...over }))

describe("who is heard", () => {
  it("takes the team domains exactly or as a subdomain, never a look-alike", () => {
    for (const ok of ["a@manaflow.ai", "a@cmux.com", "a@manaflow.com", "a@eng.manaflow.ai", "A@MANAFLOW.AI", " a@cmux.com "]) expect(isTeamEmail(ok), ok).toBe(true)
    for (const no of ["a@notmanaflow.ai", "a@manaflow.ai.example.com", "a@cmux.co", "a@manaflow.io", "manaflow.ai", "@manaflow.ai", "a@example.com"]) expect(isTeamEmail(no), no).toBe(false)
  })

  it("routes agents, service accounts and simulators to the test channel, and refuses the rest", () => {
    expect(audienceOf("tina@manaflow.ai", true, false)).toEqual({ route: "team" })
    expect(audienceOf("tina@manaflow.ai", true, true)).toEqual({ route: "test", why: "simulator" })
    expect(audienceOf("cmux-agent-development@manaflow.ai", true, false)).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("cmux-agent-anything@cmux.com", true, false)).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("ops-bot@cmux.com", true, false, "ops-bot@cmux.com, other@cmux.com")).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("tina@manaflow.ai", false, false)).toEqual({ route: "refuse", why: "unverified" })
    expect(audienceOf("olive@example.com", true, false)).toEqual({ route: "refuse", why: "not_team" })
    expect(audienceOf(null, true, false)).toEqual({ route: "refuse", why: "not_team" })
  })
})

describe("the report", () => {
  it("accepts a full report and bounds its free text", () => {
    const r = parseReport(body({ lastError: "x".repeat(1000) }))
    expect(r.lastError).toHaveLength(300)
    expect(r.app.simulator).toBe(false)
  })

  it.each([
    [{ id: "short" }, "id"],
    [{ kind: "mac_slow" }, "kind"],
    [{ state: "closed" }, "state"],
    [{ state: "ended" }, "endReason"],
    [{ state: "ended", endReason: "bored" }, "endReason"],
    [{ startedAt: "yesterday" }, "startedAt"],
    [{ durationMs: -1 }, "durationMs"],
    [{ durationMs: undefined }, "durationMs"],
    [{ mac: { id: "m" } }, "mac.name"],
    [{ app: { version: "1", build: "1", config: "Debug" } }, "app.simulator"],
    [{ transport: "Wire Guard!" }, "transport"],
    [{ simulations: ["drop_everything"] }, "simulations"]
  ])("refuses %j", (over, field) => {
    expect(() => parseReport(body(over))).toThrow(field)
  })

  it("formats durations", () => {
    expect([duration(31_000), duration(130_000), duration(120_000), duration(3_780_000), duration(7_200_000)]).toEqual(["31s", "2m 10s", "2m", "1h 3m", "2h"])
  })
})

describe("the desk", () => {
  const tina = { key: "tina", email: "tina@manaflow.ai" }
  const ted = { key: "ted", email: "ted@cmux.com" }

  it("posts a start once, then edits it and replies in its thread at the end", () => {
    const desk = emptyDesk()
    const open = report()
    const first = applyReport(desk, open, tina, "team", T0)
    expect(first.actions.map((a) => a.kind)).toEqual(["post"])
    expect(first.actions[0]!).toMatchObject({ route: "team" })
    const text = (first.actions[0] as { text: string }).text
    expect(text).toContain("tina@manaflow.ai can't reach Mac “Studio”")
    expect(text).toContain("6 dials")
    expect(text).toContain("dial timed out after 25 s")
    expect(text).toContain("WireGuard · wifi · iPhone17,4 · iOS 27.2 · cmux 1.2.0 (450) TestFlight")
    // A resend of the same start (the phone retried after a lost answer) posts nothing.
    expect(applyReport(desk, open, tina, "team", T0 + 1000)).toEqual({ accepted: true, note: "duplicate", actions: [] })
    const resolved = report({ id: open.id, state: "resolved", durationMs: 130_000 }, T0 + 100_000)
    const end = applyReport(desk, resolved, tina, "team", T0 + 100_000)
    expect(end.actions.map((a) => a.kind)).toEqual(["update", "reply"])
    expect((end.actions[0] as { text: string }).text).toContain("reconnected after 2m 10s")
    expect((end.actions[1] as { text: string }).text).toBe("Resolved: reconnected after 2m 10s.")
    // An incident ends once.
    expect(applyReport(desk, report({ id: open.id, state: "ended", endReason: "app_backgrounded" }), tina, "team", T0 + 200_000).actions).toEqual([])
  })

  it("posts an end whose start never came (a relaunch lost it) as one message", () => {
    const desk = emptyDesk()
    const ended = report({ state: "ended", endReason: "app_relaunched", durationMs: 95_000 })
    const out = applyReport(desk, ended, tina, "team", T0)
    expect(out.actions.map((a) => a.kind)).toEqual(["post"])
    expect((out.actions[0] as { text: string }).text).toContain("couldn't reach Mac “Studio”* for 1m 35s — never reconnected (the app was closed before it reconnected)")
  })

  it("refuses an incident id another account already used", () => {
    const desk = emptyDesk()
    const open = report()
    applyReport(desk, open, tina, "team", T0)
    expect(applyReport(desk, { ...open, state: "resolved" }, ted, "team", T0)).toMatchObject({ accepted: false, actions: [] })
  })

  it("limits new threads per reporter and overall per hour, and says what it held back", () => {
    const desk = emptyDesk()
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) expect(applyReport(desk, report(), tina, "team", T0 + i).actions).toHaveLength(1)
    const held = applyReport(desk, report(), tina, "team", T0 + 10)
    expect(held).toMatchObject({ accepted: true, note: "rate_limited", actions: [] })
    // Another teammate still gets through, and the post says one incident was held back.
    const next = applyReport(desk, report(), ted, "team", T0 + 20)
    expect((next.actions[0] as { text: string }).text).toContain("1 more incident in the last hour were not posted (rate limit)")
    // The held incident's end is posted as a whole once the hour has passed.
    const heldId = Object.values(desk.incidents).find((i) => i.suppressed)!.id
    const late = applyReport(desk, report({ id: heldId, state: "resolved", durationMs: 50_000 }), tina, "team", T0 + 3_600_001)
    expect(late.actions.map((a) => a.kind)).toEqual(["post"])
    // Overall limit: 20 a route.
    const busy = emptyDesk()
    for (let i = 0; i < LIMITS.overallPerHour; i++) applyReport(busy, report(), { key: `u${i}`, email: `u${i}@cmux.com` }, "team", T0)
    expect(applyReport(busy, report(), { key: "u99", email: "u99@cmux.com" }, "team", T0).note).toBe("rate_limited")
    // The test route has its own budget.
    expect(applyReport(busy, report(), { key: "u99", email: "u99@cmux.com" }, "test", T0).actions).toHaveLength(1)
  })

  it("flags a likely service outage when teammates lose Macs together, and a service the phone could not reach", () => {
    const desk = emptyDesk()
    applyReport(desk, report(), tina, "team", T0)
    const second = applyReport(desk, report({ serviceReachable: false }), ted, "team", T0 + 60_000)
    const text = (second.actions[0] as { text: string }).text
    expect(text).toContain("1 other teammate lost a Mac within 10 minutes of this: likely service-side")
    expect(text).toContain("could not reach the cmux service either")
    // Far apart in time: no correlation.
    const apart = applyReport(desk, report({}, T0 + 3_000_000), { key: "tom", email: "tom@manaflow.com" }, "team", T0 + 3_000_000)
    expect((apart.actions[0] as { text: string }).text).not.toContain("other teammate")
  })

  it("says when the phone delivered a report late, and when a developer simulation was on", () => {
    const desk = emptyDesk()
    const out = applyReport(desk, report({ simulations: ["block_udp"] }, T0), tina, "team", T0 + 600_000)
    const text = (out.actions[0] as { text: string }).text
    expect(text).toContain("Delivered 10m late")
    expect(text).toContain("Developer network simulation on: block_udp")
  })

  it("escapes Slack markup from the phone", () => {
    const out = applyReport(emptyDesk(), report({ mac: { id: "m-1234567", name: "<!channel> & co" }, lastError: "`<@U1>`" }), tina, "team", T0)
    const text = (out.actions[0] as { text: string }).text
    expect(text).toContain("“&lt;!channel&gt; &amp; co”")
    expect(text).not.toContain("<!channel>")
    expect(text).not.toContain("<@U1>")
  })
})

describe("POST /v1/diagnostics/connectivity-incidents", () => {
  let calls: Array<{ method: string; body: Record<string, unknown> }>
  let fail: Array<string>
  beforeEach(() => {
    calls = []
    fail = []
    let ts = 1000
    ConnectivityAlertDesk.testSlack = (async (method, b) => {
      calls.push({ method, body: b })
      const error = fail.shift()
      if (error) return { ok: false, error }
      return { ok: true, ts: `${++ts}.0001`, channel: String(b.channel) }
    }) satisfies SlackCall
  })
  afterEach(() => {
    ConnectivityAlertDesk.testSlack = undefined
  })

  const desk = () => (env as unknown as { CONNECTIVITY_ALERT_DESK: DurableObjectNamespace<ConnectivityAlertDesk> }).CONNECTIVITY_ALERT_DESK.get(
    (env as unknown as { CONNECTIVITY_ALERT_DESK: DurableObjectNamespace<ConnectivityAlertDesk> }).CONNECTIVITY_ALERT_DESK.idFromName("desk")
  )

  it("posts a team member's incident to the team channel, then edits it when it resolves", async () => {
    const tok = await token("tina")
    const open = body()
    expect(await call("POST", PATH, tok, open)).toMatchObject({ status: 202, json: { accepted: true, route: "team" } })
    expect(calls).toHaveLength(1)
    expect(calls[0]).toMatchObject({ method: "chat.postMessage", body: { channel: "CTEAM" } })
    expect(String(calls[0]!.body.text)).toContain("tina@manaflow.ai can't reach Mac “Studio”")
    // A resend (the answer was lost) posts nothing more.
    expect(await call("POST", PATH, tok, open)).toMatchObject({ status: 202, json: { note: "duplicate" } })
    expect(calls).toHaveLength(1)
    expect(await call("POST", PATH, tok, { ...open, state: "resolved", durationMs: 75_000, observedAt: new Date().toISOString() })).toMatchObject({ status: 202 })
    expect(calls.map((c) => c.method)).toEqual(["chat.postMessage", "chat.update", "chat.postMessage"])
    expect(calls[1]!.body).toMatchObject({ channel: "CTEAM", ts: calls.length && "1001.0001" })
    expect(calls[2]!.body).toMatchObject({ channel: "CTEAM", thread_ts: "1001.0001", text: "Resolved: reconnected after 1m 15s." })
  })

  it("hears every team domain, a subdomain, and the production project's users", async () => {
    for (const who of ["ted", "tom", "sub"]) expect((await call("POST", PATH, await token(who), body())).json.route, who).toBe("team")
    expect((await call("POST", PATH, await token("tina", { project: PROD_PROJECT }), body())).json.route).toBe("team")
    expect(calls.map((c) => c.body.channel)).toEqual(["CTEAM", "CTEAM", "CTEAM", "CTEAM"])
  })

  it("refuses everyone else, a look-alike domain and an unverified email, and posts nothing", async () => {
    for (const [who, code] of [
      ["out", "not_team"],
      ["look", "not_team"],
      ["pre", "not_team"],
      ["una", "email_unverified"],
      ["nobody", "not_team"]
    ] as const)
      expect(await call("POST", PATH, await token(who), body()), who).toMatchObject({ status: 403, json: { error: { code } } })
    expect(await call("POST", PATH, undefined, body())).toMatchObject({ status: 401 })
    expect(calls).toEqual([])
  })

  it("sends simulators and agent or service accounts to the test channel only", async () => {
    expect((await call("POST", PATH, await token("tina"), body({ app: { version: "1.2.0", build: "1", config: "Debug", simulator: true } }))).json.route).toBe("test")
    for (const who of ["agent", "agent2", "ops"]) expect((await call("POST", PATH, await token(who), body())).json.route, who).toBe("test")
    expect(calls.map((c) => c.body.channel)).toEqual(["CTEST", "CTEST", "CTEST", "CTEST"])
    expect(String(calls[0]!.body.text)).toContain("Test route: simulator build")
  })

  it("refuses a malformed report", async () => {
    expect(await call("POST", PATH, await token("tina"), body({ kind: "nope" }))).toMatchObject({ status: 400, json: { error: { code: "bad_request" } } })
    expect(calls).toEqual([])
  })

  it("keeps an accepted report when Slack fails, and delivers it in order on the retry", async () => {
    const tok = await token("ted")
    fail.push("ratelimited")
    const open = body()
    expect((await call("POST", PATH, tok, open)).status).toBe(202)
    // The end arrives while the start still waits for Slack: both stay queued, in order.
    expect((await call("POST", PATH, tok, { ...open, state: "ended", endReason: "network_lost", durationMs: 40_000 })).status).toBe(202)
    expect(calls).toHaveLength(1)
    const queued = await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())
    expect(queued.outbox.map((o) => o.action.kind)).toEqual(["post", "update", "reply"])
    expect(await runDurableObjectAlarm(desk())).toBe(true)
    expect(calls.map((c) => c.method)).toEqual(["chat.postMessage", "chat.postMessage", "chat.update", "chat.postMessage"])
    expect(String(calls[2]!.body.text)).toContain("never reconnected (the phone lost its network)")
    expect((await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())).outbox).toEqual([])
  })

  it("drops a call Slack can never accept instead of retrying it forever", async () => {
    fail.push("channel_not_found")
    expect((await call("POST", PATH, await token("tom"), body())).status).toBe(202)
    expect((await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())).outbox).toEqual([])
  })
})
