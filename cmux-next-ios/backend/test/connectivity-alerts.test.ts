import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import {
  ALIVE_WITHIN_MS,
  applyReport,
  audienceOf,
  ConnectivityAlertDesk,
  duration,
  emptyDesk,
  expireStale,
  isTeamEmail,
  judgedAt,
  LIMITS,
  nextExpiry,
  OPEN_EXPIRY_MS,
  parseReport,
  PER_REPORTER_STORED,
  retryable,
  startVerdict,
  type IncidentReport,
  type MacCheck,
  type SlackCall
} from "../src/connectivity-alerts.ts"
import { call, connect, PROD_PROJECT, register, token } from "./helpers.ts"

const PATH = "/v1/diagnostics/connectivity-incidents"
const T0 = Date.parse("2026-11-12T16:00:00.000Z")
const TEAM = { route: "team" as const }
/** A Mac that pinged a second before the report. */
const AWAKE = (now: number): MacCheck => ({ liveness: { connected: true, lastPingAt: now - 1000, pings: true } })

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
const text = (o: { actions: ReadonlyArray<unknown> }, i = 0) => (o.actions[i] as { text: string }).text

describe("who is heard", () => {
  it("takes the team domains exactly or as a subdomain, never a look-alike", () => {
    for (const ok of ["a@manaflow.ai", "a@cmux.com", "a@manaflow.com", "a@eng.manaflow.ai", "A@MANAFLOW.AI", " a@cmux.com "]) expect(isTeamEmail(ok), ok).toBe(true)
    for (const no of ["a@notmanaflow.ai", "a@manaflow.ai.example.com", "a@cmux.co", "a@manaflow.io", "manaflow.ai", "@manaflow.ai", "a@example.com"]) expect(isTeamEmail(no), no).toBe(false)
  })

  it("routes agents, simulators, Debug builds and network simulations to the test channel, and refuses the rest", () => {
    const shipping = { simulator: false, config: "TestFlight" }
    expect(audienceOf("tina@manaflow.ai", true, shipping)).toEqual({ route: "team" })
    expect(audienceOf("tina@manaflow.ai", true, { ...shipping, config: "AppStore" })).toEqual({ route: "team" })
    expect(audienceOf("tina@manaflow.ai", true, { ...shipping, simulator: true })).toEqual({ route: "test", why: "simulator" })
    expect(audienceOf("tina@manaflow.ai", true, { ...shipping, config: "Debug" })).toEqual({ route: "test", why: "debug_build" })
    expect(audienceOf("tina@manaflow.ai", true, { ...shipping, simulations: ["block_udp"] })).toEqual({ route: "test", why: "network_simulation" })
    expect(audienceOf("cmux-agent-development@manaflow.ai", true, shipping)).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("cmux-agent-anything@cmux.com", true, shipping)).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("ops-bot@cmux.com", true, shipping, "ops-bot@cmux.com, other@cmux.com")).toEqual({ route: "test", why: "agent_account" })
    expect(audienceOf("tina@manaflow.ai", false, shipping)).toEqual({ route: "refuse", why: "unverified" })
    expect(audienceOf("olive@example.com", true, shipping)).toEqual({ route: "refuse", why: "not_team" })
    expect(audienceOf(null, true, shipping)).toEqual({ route: "refuse", why: "not_team" })
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
    [{ mac: { name: "Studio" } }, "mac.id"],
    [{ app: { version: "1", build: "1", config: "Debug" } }, "app.simulator"]
  ])("refuses %j", (over, field) => {
    expect(() => parseReport(body(over))).toThrow(field)
  })

  it("keeps a report whose descriptive fields are odd, leaving them out", () => {
    const r = parseReport(body({ mac: { id: "m-12345678", name: "   " }, lastError: "", transport: "Wire Guard!", network: 7, simulations: ["drop_everything", "block_udp"], device: null }))
    expect(r.mac.name).toBe("Unnamed Mac")
    expect(r.lastError).toBeUndefined()
    expect(r.transport).toBeUndefined()
    expect(r.network).toBeUndefined()
    expect(r.simulations).toEqual(["block_udp"])
    expect(r.device).toEqual({ model: "unknown", os: "?" })
  })

  it("formats durations", () => {
    expect([duration(31_000), duration(130_000), duration(120_000), duration(3_780_000), duration(7_200_000)]).toEqual(["31s", "2m 10s", "2m", "1h 3m", "2h"])
  })
})

describe("whether the Mac was awake", () => {
  const open = report({}, T0)
  it("posts only for a Mac that sent an application ping within 45 s", () => {
    expect(startVerdict(open, AWAKE(T0), T0)).toBeUndefined()
    expect(startVerdict(open, { liveness: { connected: true, lastPingAt: T0 - ALIVE_WITHIN_MS, pings: true } }, T0)).toBeUndefined()
    // Asleep: the socket is still open (half open) but the pings stopped.
    expect(startVerdict(open, { liveness: { connected: true, lastPingAt: T0 - ALIVE_WITHIN_MS - 1, pings: true } }, T0)).toBe("mac_asleep")
    // A connect alone proves nothing (a dark wake connects and sleeps again).
    expect(startVerdict(open, { liveness: { connected: true, lastPingAt: null, pings: false } }, T0)).toBe("mac_liveness_unknown")
    expect(startVerdict(open, { liveness: { connected: false, lastPingAt: null, pings: false } }, T0)).toBe("mac_offline")
    // Gone now, but it pinged right before the phone saw the incident: it was awake.
    expect(startVerdict(open, { liveness: { connected: false, lastPingAt: T0 - 10_000, pings: true } }, T0)).toBeUndefined()
    expect(startVerdict(open, { liveness: null }, T0)).toBe("mac_offline")
  })

  it("always posts when the phone could not reach the cmux service, and judges a late report at the time the phone saw it", () => {
    const outage = report({ serviceReachable: false }, T0)
    expect(startVerdict(outage, { liveness: null }, T0)).toBeUndefined()
    // Delivered 10 min late: the Mac pinged just before the phone saw it (asleep since): posted.
    expect(startVerdict(open, { liveness: { connected: true, lastPingAt: T0 - 5000, pings: true } }, T0 + 600_000)).toBeUndefined()
    // Delivered late, the Mac's last ping was long before the phone saw it: it was asleep then.
    expect(startVerdict(open, { liveness: { connected: true, lastPingAt: T0 - 120_000, pings: true } }, T0 + 600_000)).toBe("mac_asleep")
    expect(judgedAt(open, T0 + 600_000)).toBe(T0)
  })
})

describe("the desk", () => {
  const tina = { key: "tina", email: "tina@manaflow.ai" }
  const ted = { key: "ted", email: "ted@cmux.com" }

  it("posts a start once, then edits it and replies in its thread at the end", () => {
    const desk = emptyDesk()
    const open = report()
    const first = applyReport(desk, open, tina, TEAM, AWAKE(T0), T0)
    expect(first.actions.map((a) => a.kind)).toEqual(["post"])
    expect(first.actions[0]!).toMatchObject({ route: "team" })
    expect(text(first)).toContain("tina@manaflow.ai can't reach Mac “Studio”")
    expect(text(first)).toContain("6 dials")
    expect(text(first)).toContain("dial timed out after 25 s")
    expect(text(first)).toContain("WireGuard · wifi · iPhone17,4 · iOS 27.2 · cmux 1.2.0 (450) TestFlight")
    // A resend of the same start (the phone retried after a lost answer) posts nothing.
    expect(applyReport(desk, open, tina, TEAM, AWAKE(T0), T0 + 1000)).toMatchObject({ accepted: true, note: "duplicate", actions: [] })
    const resolved = report({ id: open.id, state: "resolved", durationMs: 130_000 }, T0 + 100_000)
    const end = applyReport(desk, resolved, tina, TEAM, { liveness: null }, T0 + 100_000)
    expect(end.actions.map((a) => a.kind)).toEqual(["update", "reply"])
    expect(text(end)).toContain("reconnected after 2m 10s")
    expect(text(end, 1)).toBe("Resolved: reconnected after 2m 10s.")
    // An incident ends once.
    expect(applyReport(desk, report({ id: open.id, state: "ended", endReason: "app_backgrounded" }), tina, TEAM, AWAKE(T0), T0 + 200_000).actions).toEqual([])
  })

  it("stays quiet about a Mac that was asleep, start and end", () => {
    const desk = emptyDesk()
    const open = report()
    const asleep: MacCheck = { liveness: { connected: true, lastPingAt: T0 - 600_000, pings: true } }
    expect(applyReport(desk, open, tina, TEAM, asleep, T0)).toMatchObject({ note: "mac_asleep", actions: [] })
    expect(applyReport(desk, report({ id: open.id, state: "ended", endReason: "mac_offline", durationMs: 400_000 }), tina, TEAM, { liveness: null }, T0 + 400_000)).toMatchObject({
      note: "mac_asleep",
      actions: []
    })
  })

  it("posts an end whose start never came (a relaunch lost it) as one message", () => {
    const desk = emptyDesk()
    const ended = report({ state: "ended", endReason: "app_relaunched", durationMs: 95_000 })
    const out = applyReport(desk, ended, tina, TEAM, AWAKE(T0), T0)
    expect(out.actions.map((a) => a.kind)).toEqual(["post"])
    expect(text(out)).toContain("couldn't reach Mac “Studio”* for 1m 35s — never reconnected (the app was closed before it reconnected)")
  })

  it("puts the same person's next outage of the same Mac in the first one's thread", () => {
    const desk = emptyDesk()
    const first = report({}, T0)
    applyReport(desk, first, tina, TEAM, AWAKE(T0), T0)
    applyReport(desk, report({ id: first.id, state: "ended", endReason: "app_backgrounded", durationMs: 50_000 }, T0 + 20_000), tina, TEAM, AWAKE(T0), T0 + 20_000)
    // Back in the app a minute later, still unreachable: a reply, not a new message (it counts against the hour).
    const again = report({}, T0 + 90_000)
    const out = applyReport(desk, again, tina, TEAM, AWAKE(T0 + 90_000), T0 + 90_000)
    expect(out.actions).toEqual([{ kind: "reply", incident: first.id, text: expect.stringContaining("Again: :red_circle:") }])
    const end = applyReport(desk, report({ id: again.id, state: "resolved", durationMs: 70_000 }, T0 + 130_000), tina, TEAM, { liveness: null }, T0 + 130_000)
    expect(end.actions).toEqual([{ kind: "reply", incident: first.id, text: expect.stringContaining("Resolved: reconnected after 1m 10s.") }])
    expect(desk.meta.posted).toHaveLength(2)
    // The same Mac's link then keeps dropping (the other kind): still its thread, never a second message.
    const unstable = applyReport(desk, report({ kind: "link_unstable", drops: 3 }, T0 + 135_000), tina, TEAM, AWAKE(T0 + 135_000), T0 + 135_000)
    expect(unstable.actions).toEqual([{ kind: "reply", incident: first.id, text: expect.stringContaining("keeps dropping") }])
    // Another Mac, or 30 minutes later: a message of its own.
    expect(applyReport(desk, report({ mac: { id: "m-other-1", name: "Air" } }, T0 + 140_000), tina, TEAM, AWAKE(T0 + 140_000), T0 + 140_000).actions[0]).toMatchObject({ kind: "post" })
    expect(applyReport(desk, report({}, T0 + 2_000_000), tina, TEAM, AWAKE(T0 + 2_000_000), T0 + 2_000_000).actions[0]).toMatchObject({ kind: "post" })
  })

  it("counts thread replies against the hour's limit, so going back and forth never floods a thread", () => {
    const desk = emptyDesk()
    let at = T0
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) {
      const open = report({}, at)
      expect(applyReport(desk, open, tina, TEAM, AWAKE(at), at).actions).toHaveLength(1)
      applyReport(desk, report({ id: open.id, state: "ended", endReason: "app_backgrounded" }, at + 5000), tina, TEAM, AWAKE(at), at + 5000)
      at += 60_000
    }
    expect(applyReport(desk, report({}, at), tina, TEAM, AWAKE(at), at)).toMatchObject({ note: "rate_limited", actions: [] })
  })

  it("says how many were held back only for the last hour, in the right number", () => {
    const desk = emptyDesk()
    const onMac = (i: number, at = T0) => report({ mac: { id: `mac-${i}-0000`, name: `Mac ${i}` } }, at)
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) applyReport(desk, onMac(i), tina, TEAM, AWAKE(T0), T0)
    applyReport(desk, onMac(80), tina, TEAM, AWAKE(T0), T0 + 1)
    applyReport(desk, onMac(81), tina, TEAM, AWAKE(T0), T0 + 2)
    expect(text(applyReport(desk, onMac(82), ted, TEAM, AWAKE(T0), T0 + 3))).toContain("• 2 more incidents were held back in the last hour (rate limit)")
    // Held long ago and never told: not "in the last hour" any more, so not said.
    const old = emptyDesk()
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) applyReport(old, onMac(i), tina, TEAM, AWAKE(T0), T0)
    applyReport(old, onMac(90), tina, TEAM, AWAKE(T0), T0 + 1)
    const later = applyReport(old, onMac(91, T0 + 2 * 3_600_000), ted, TEAM, AWAKE(T0 + 2 * 3_600_000), T0 + 2 * 3_600_000)
    expect(text(later)).not.toContain("held back")
  })

  it("closes a message whose end never came, and still takes a late end", () => {
    const desk = emptyDesk()
    const open = report({}, T0)
    applyReport(desk, open, tina, TEAM, AWAKE(T0), T0)
    expect(nextExpiry(desk)).toBe(T0 + OPEN_EXPIRY_MS)
    expect(expireStale(desk, T0 + OPEN_EXPIRY_MS - 1).actions).toEqual([])
    const closed = expireStale(desk, T0 + OPEN_EXPIRY_MS)
    expect(closed.actions.map((a) => a.kind)).toEqual(["update", "reply"])
    expect((closed.actions[0] as { text: string }).text).toContain("never reconnected (no end arrived from the phone)")
    expect((closed.actions[1] as { text: string }).text).toBe("No end arrived from the phone within 3h (the app was closed or removed); this incident is closed.")
    expect(expireStale(desk, T0 + OPEN_EXPIRY_MS + 60_000).actions).toEqual([])
    expect(nextExpiry(desk)).toBeUndefined()
    // The phone comes back and sends the real end: the message is edited again.
    const late = applyReport(desk, report({ id: open.id, state: "ended", endReason: "app_relaunched", durationMs: 9_000_000 }, T0 + OPEN_EXPIRY_MS + 120_000), tina, TEAM, { liveness: null }, T0 + OPEN_EXPIRY_MS + 120_000)
    expect(late.actions.map((a) => a.kind)).toEqual(["update", "reply"])
  })

  it("refuses an incident id another account already used", () => {
    const desk = emptyDesk()
    const open = report()
    applyReport(desk, open, tina, TEAM, AWAKE(T0), T0)
    expect(applyReport(desk, { ...open, state: "resolved" }, ted, TEAM, AWAKE(T0), T0)).toMatchObject({ accepted: false, actions: [] })
  })

  it("limits new threads per reporter and overall per hour, and says what it held back", () => {
    const desk = emptyDesk()
    // Different Macs, so none of them threads under another.
    const onMac = (i: number, at = T0) => report({ mac: { id: `mac-${i}-0000`, name: `Mac ${i}` } }, at)
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) expect(applyReport(desk, onMac(i), tina, TEAM, AWAKE(T0), T0 + i).actions).toHaveLength(1)
    const held = onMac(99)
    expect(applyReport(desk, held, tina, TEAM, AWAKE(T0), T0 + 10)).toMatchObject({ accepted: true, note: "rate_limited", actions: [] })
    // Another teammate still gets through, and the post says one incident was held back.
    const next = applyReport(desk, onMac(50), ted, TEAM, AWAKE(T0), T0 + 20)
    expect(text(next)).toContain("• 1 more incident was held back in the last hour (rate limit)")
    // The held incident's end is posted as a whole once the hour has passed.
    const late = applyReport(desk, { ...held, state: "resolved", durationMs: 50_000 }, tina, TEAM, AWAKE(T0), T0 + 3_600_001)
    expect(late.actions.map((a) => a.kind)).toEqual(["post"])
    expect(desk.meta.held.team).toEqual([])
    // Overall limit: 20 a route.
    const busy = emptyDesk()
    for (let i = 0; i < LIMITS.overallPerHour; i++) applyReport(busy, onMac(i), { key: `u${i}`, email: `u${i}@cmux.com` }, TEAM, AWAKE(T0), T0)
    expect(applyReport(busy, onMac(1), { key: "u99", email: "u99@cmux.com" }, TEAM, AWAKE(T0), T0).note).toBe("rate_limited")
    // The test route has its own budget.
    expect(applyReport(busy, onMac(1), { key: "u99", email: "u99@cmux.com" }, { route: "test", why: "simulator" }, AWAKE(T0), T0).actions).toHaveLength(1)
  })

  it("counts a held incident once and says so in the next post, even when that post is an end", () => {
    const desk = emptyDesk()
    const onMac = (i: number) => report({ mac: { id: `mac-${i}-0000`, name: `Mac ${i}` } }, T0)
    for (let i = 0; i < LIMITS.perReporterPerHour; i++) applyReport(desk, onMac(i), tina, TEAM, AWAKE(T0), T0)
    // Held: its start and then its end arrive while the limit holds; it counts once.
    const held = onMac(90)
    applyReport(desk, held, tina, TEAM, AWAKE(T0), T0 + 1)
    applyReport(desk, { ...held, state: "ended", endReason: "mac_offline", durationMs: 60_000 }, tina, TEAM, AWAKE(T0), T0 + 2)
    expect(desk.meta.held.team).toHaveLength(1)
    // The next post is an end (its start was lost to a relaunch): it still carries the count.
    const endOnly = applyReport(desk, report({ mac: { id: "mac-77-0000", name: "M" }, state: "ended", endReason: "app_relaunched" }, T0 + 3), ted, TEAM, AWAKE(T0), T0 + 3)
    expect(text(endOnly)).toContain("• 1 more incident was held back in the last hour (rate limit)")
    expect(desk.meta.held.team).toEqual([])
  })

  it("keeps at most 100 incidents per reporter", () => {
    const desk = emptyDesk()
    for (let i = 0; i < PER_REPORTER_STORED; i++) applyReport(desk, report({ mac: { id: `mac-${i}-0000`, name: "M" } }), tina, TEAM, { liveness: null }, T0)
    expect(applyReport(desk, report(), tina, TEAM, AWAKE(T0), T0)).toMatchObject({ note: "reporter_cap", actions: [], changed: [] })
    expect(applyReport(desk, report(), ted, TEAM, AWAKE(T0), T0).actions).toHaveLength(1)
  })

  it("flags a likely service outage when teammates lose Macs together, and a service the phone could not reach", () => {
    const desk = emptyDesk()
    applyReport(desk, report(), tina, TEAM, AWAKE(T0), T0)
    const second = applyReport(desk, report({ serviceReachable: false }), ted, TEAM, AWAKE(T0), T0 + 60_000)
    expect(text(second)).toContain("1 other teammate lost a Mac within 10 minutes of this: likely service-side")
    expect(text(second)).toContain("could not reach the cmux service either")
    // Far apart in time: no correlation.
    const apart = applyReport(desk, report({}, T0 + 3_000_000), { key: "tom", email: "tom@manaflow.com" }, TEAM, AWAKE(T0 + 3_000_000), T0 + 3_000_000)
    expect(text(apart)).not.toContain("other teammate")
  })

  it("says when the phone delivered a report late", () => {
    const desk = emptyDesk()
    const out = applyReport(desk, report({}, T0), tina, TEAM, AWAKE(T0 + 600_000), T0 + 600_000)
    expect(text(out)).toContain("Delivered 10m late")
  })

  it("escapes Slack markup from the phone", () => {
    const out = applyReport(emptyDesk(), report({ mac: { id: "m-1234567", name: "<!channel> & co" }, lastError: "`<@U1>`" }), tina, TEAM, AWAKE(T0), T0)
    expect(text(out)).toContain("“&lt;!channel&gt; &amp; co”")
    expect(text(out)).not.toContain("<!channel>")
    expect(text(out)).not.toContain("<@U1>")
  })

  it("retries only Slack failures that can pass", () => {
    for (const e of ["ratelimited", "network: TypeError", "http_502", "internal_error", "service_unavailable"]) expect(retryable(e), e).toBe(true)
    for (const e of ["channel_not_found", "invalid_auth", "not_authed", "invalid_arguments", "restricted_action", "http_400", "brand_new_error", undefined]) expect(retryable(e), String(e)).toBe(false)
  })
})

describe("the hub's application ping", () => {
  it("answers ping with pong and says when the Mac last proved it was awake", async () => {
    const tok = await token("tina")
    const macId = await register(tok, "mac", "personal-tina", "Studio")
    const mac = await connect(tok, "personal-tina", macId)
    await mac.until((s) => s.frames.some((f) => f.type === "hello"))
    const before = Date.now()
    mac.ws.send("ping")
    const pong = new Promise<string>((resolve) => mac.ws.addEventListener("message", (e) => typeof e.data === "string" && e.data === "pong" && resolve(e.data)))
    expect(await pong).toBe("pong")
    const hubs = (env as unknown as { TEAM_HUB: DurableObjectNamespace }).TEAM_HUB
    type Live = { connected: boolean; lastPingAt: number | null; pings: boolean }
    const hub = hubs.get(hubs.idFromName("user:tina")) as unknown as { macLiveness(owner: string, id: string, at?: number): Promise<Live> }
    const live = await hub.macLiveness("tina", macId)
    expect(live.connected).toBe(true)
    expect(live.pings).toBe(true)
    expect(live.lastPingAt).toBeGreaterThanOrEqual(before - 1000)
    expect(await hub.macLiveness("tina", crypto.randomUUID())).toEqual({ connected: false, lastPingAt: null, pings: false })
    // The Mac reconnects (it woke): its new socket has not pinged. For a moment before the reconnect, the
    // old socket's recorded ping speaks; for now, the new socket (no ping yet) does.
    const firstPing = live.lastPingAt!
    const again = await connect(tok, "personal-tina", macId)
    await again.until((s) => s.frames.some((f) => f.type === "hello"))
    const beforeReconnect = await hub.macLiveness("tina", macId, firstPing + 1)
    expect(beforeReconnect).toEqual({ connected: true, lastPingAt: firstPing, pings: true })
    expect((await hub.macLiveness("tina", macId, Date.now() + 1000)).lastPingAt).toBeNull()
    again.ws.close()
    mac.ws.close()
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

  const desk = () => {
    const ns = (env as unknown as { CONNECTIVITY_ALERT_DESK: DurableObjectNamespace<ConnectivityAlertDesk> }).CONNECTIVITY_ALERT_DESK
    return ns.get(ns.idFromName("desk"))
  }
  /** Waits for the desk's Slack calls made after its answer. */
  const settled = () => runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.settled())

  /** A user's awake Mac: registered, its socket open, and it sent the application ping (answered "pong"). */
  const awakeMac = async (user: string, tok: string) => {
    const space = `personal-${user}`
    const id = await register(tok, "mac", space, "Studio")
    const sock = await connect(tok, space, id)
    await sock.until((s) => s.frames.some((f) => f.type === "hello"))
    const pong = new Promise<void>((resolve) => sock.ws.addEventListener("message", (e) => e.data === "pong" && resolve()))
    sock.ws.send("ping")
    await pong
    return { id, sock }
  }

  it("posts a team member's incident to the team channel, then edits it when it resolves", async () => {
    const tok = await token("tina")
    const mac = await awakeMac("tina", tok)
    const open = body({ mac: { id: mac.id, name: "Studio" } })
    expect(await call("POST", PATH, tok, open)).toMatchObject({ status: 202, json: { accepted: true, route: "team" } })
    await settled()
    expect(calls).toHaveLength(1)
    expect(calls[0]).toMatchObject({ method: "chat.postMessage", body: { channel: "CTEAM" } })
    expect(String(calls[0]!.body.text)).toContain("tina@manaflow.ai can't reach Mac “Studio”")
    // A resend (the answer was lost) posts nothing more.
    expect(await call("POST", PATH, tok, open)).toMatchObject({ status: 202, json: { note: "duplicate" } })
    expect(await call("POST", PATH, tok, { ...open, state: "resolved", durationMs: 75_000, observedAt: new Date().toISOString() })).toMatchObject({ status: 202 })
    await settled()
    expect(calls.map((c) => c.method)).toEqual(["chat.postMessage", "chat.update", "chat.postMessage"])
    expect(calls[1]!.body).toMatchObject({ channel: "CTEAM", ts: "1001.0001" })
    expect(calls[2]!.body).toMatchObject({ channel: "CTEAM", thread_ts: "1001.0001", text: "Resolved: reconnected after 1m 15s." })
    mac.sock.ws.close()
  })

  it("posts nothing for a Mac that connected but never pinged (a dark wake)", async () => {
    const tok = await token("ted")
    const id = await register(tok, "mac", "personal-ted", "Napping")
    const sock = await connect(tok, "personal-ted", id)
    await sock.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(await call("POST", PATH, tok, body({ mac: { id, name: "Napping" } }))).toMatchObject({ status: 202, json: { note: "mac_liveness_unknown" } })
    await settled()
    expect(calls).toEqual([])
    sock.ws.close()
  })

  it("posts nothing for a Mac that is not connected (asleep, quit or someone else's)", async () => {
    const tok = await token("ted")
    expect(await call("POST", PATH, tok, body({ mac: { id: crypto.randomUUID(), name: "Gone" } }))).toMatchObject({ status: 202, json: { note: "mac_offline" } })
    await settled()
    expect(calls).toEqual([])
  })

  it("hears every team domain, a subdomain, and the production project's users", async () => {
    for (const who of ["ted", "tom", "sub"]) {
      const tok = await token(who)
      const mac = await awakeMac(who, tok)
      expect((await call("POST", PATH, tok, body({ mac: { id: mac.id, name: "Studio" } }))).json.route, who).toBe("team")
      mac.sock.ws.close()
    }
    // The production project's tina: her hub is scoped by project; her report is still heard (here, as an
    // offline Mac: the test hub for that project has no socket).
    expect((await call("POST", PATH, await token("tina", { project: PROD_PROJECT }), body())).json.route).toBe("team")
    await settled()
    expect(calls.map((c) => c.body.channel)).toEqual(["CTEAM", "CTEAM", "CTEAM"])
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

  it("sends simulators, Debug builds and agent or service accounts to the test channel only", async () => {
    const tok = await token("tina")
    const mac = await awakeMac("tina", tok)
    const at = (over: Record<string, unknown>) => body({ mac: { id: mac.id, name: "Studio" }, ...over })
    expect((await call("POST", PATH, tok, at({ app: { version: "1.2.0", build: "1", config: "Debug", simulator: true } }))).json.route).toBe("test")
    mac.sock.ws.close()
    for (const who of ["agent", "agent2", "ops"]) {
      const t = await token(who)
      const m = await awakeMac(who, t)
      expect((await call("POST", PATH, t, body({ mac: { id: m.id, name: "Studio" } }))).json.route, who).toBe("test")
      m.sock.ws.close()
    }
    await settled()
    expect(calls.map((c) => c.body.channel)).toEqual(["CTEST", "CTEST", "CTEST", "CTEST"])
    expect(String(calls[0]!.body.text)).toContain("Test route: simulator build")
  })

  it("refuses a malformed report", async () => {
    expect(await call("POST", PATH, await token("tina"), body({ kind: "nope" }))).toMatchObject({ status: 400, json: { error: { code: "bad_request" } } })
    expect(calls).toEqual([])
  })

  it("keeps an accepted report when Slack fails, and delivers it in order on the retry", async () => {
    const tok = await token("ted")
    const mac = await awakeMac("ted", tok)
    fail.push("ratelimited")
    const open = body({ mac: { id: mac.id, name: "Studio" } })
    expect((await call("POST", PATH, tok, open)).status).toBe(202)
    await settled()
    // The end arrives while the start still waits for Slack: both stay queued, in order.
    expect((await call("POST", PATH, tok, { ...open, state: "ended", endReason: "network_lost", durationMs: 40_000 })).status).toBe(202)
    await settled()
    expect(calls).toHaveLength(1)
    const queued = await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())
    expect(queued.outbox.map((o) => o.action.kind)).toEqual(["post", "update", "reply"])
    // The retry's wait is over (5 s): its alarm runs.
    await runInDurableObject(desk(), (_d: ConnectivityAlertDesk, state: DurableObjectState) => state.storage.put("retryAt", Date.now() - 1))
    expect(await runDurableObjectAlarm(desk())).toBe(true)
    expect(calls.map((c) => c.method)).toEqual(["chat.postMessage", "chat.postMessage", "chat.update", "chat.postMessage"])
    expect(String(calls[2]!.body.text)).toContain("never reconnected (the phone lost its network)")
    expect((await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())).outbox).toEqual([])
    mac.sock.ws.close()
  })

  it("drops a call Slack can never accept instead of holding up the alerts behind it", async () => {
    const tok = await token("tom")
    const mac = await awakeMac("tom", tok)
    fail.push("not_authed")
    expect((await call("POST", PATH, tok, body({ mac: { id: mac.id, name: "Studio" } }))).status).toBe(202)
    await settled()
    expect((await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.snapshot())).outbox).toEqual([])
    mac.sock.ws.close()
  })
})
