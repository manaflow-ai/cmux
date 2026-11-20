import { env, runInDurableObject } from "cloudflare:test"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { ConnectivityAlertDesk, emptyDesk, LIMITS, tellHeld, type MacCheck, type SlackCall } from "../src/connectivity-alerts.ts"
import {
  applyCanary,
  applyHeartbeat,
  CANARY_SILENT_MS,
  checkSilence,
  classify,
  emptyWatch,
  isCanaryEmail,
  isWorkTime,
  nextWatchDue,
  parseCanary,
  STRIKES,
  workDeadline,
  type CanaryResult,
  type WatchIncident
} from "../src/connectivity-canary.ts"
import { phoneCloseRecord } from "../src/team-hub.ts"
import { call, connect, register, token } from "./helpers.ts"

// Thursday 2026-11-12 10:00 Pacific (18:00 UTC): working time.
const T0 = Date.parse("2026-11-12T18:00:00.000Z")
const MAC = { id: "0f3c2a9e-1111-2222-3333-444455556666", name: "Canary Mac" }
const AWAKE = (at: number): MacCheck => ({ liveness: { connected: true, lastPingAt: at - 1000, pings: true } })
const ASLEEP: MacCheck = { liveness: { connected: true, lastPingAt: T0 - 3_600_000, pings: true } }
const GONE: MacCheck = { liveness: { connected: false, lastPingAt: null, pings: false } }

const result = (at: number, over: Partial<CanaryResult> = {}): CanaryResult => ({
  probe: "wireguard",
  at: new Date(at).toISOString(),
  outcome: "fail",
  step: "dial",
  error: "dial timed out after 25 s",
  transport: "wireguard",
  durationMs: 25_000,
  mac: MAC,
  ...over
})
const pass = (at: number, over: Partial<CanaryResult> = {}) => result(at, { outcome: "pass", step: undefined, error: undefined, path: "direct", ...over })

/** One fresh desk, watch and incident set, and a helper that feeds it a result a minute apart. */
const rig = () => {
  const desk = emptyDesk()
  const watch = emptyWatch()
  const incidents: Record<string, WatchIncident> = {}
  let minute = 0
  const feed = (r: (at: number) => CanaryResult, check: (at: number) => MacCheck = AWAKE) => {
    const at = T0 + minute++ * 60_000
    return applyCanary(desk, watch, incidents, r(at), check(at), at)
  }
  return { desk, watch, incidents, feed }
}

describe("the canary's report", () => {
  it("parses a round and refuses what it cannot judge", () => {
    const [r] = parseCanary({ results: [{ ...result(T0), mac: { id: MAC.id.toUpperCase(), name: " Canary Mac " }, error: "x".repeat(900) }] })
    expect(r).toMatchObject({ probe: "wireguard", outcome: "fail", step: "dial", mac: { id: MAC.id, name: "Canary Mac" } })
    expect(r!.error).toHaveLength(300)
    expect(parseCanary({ results: [pass(T0)] })[0]!.step).toBeUndefined()
    for (const bad of [{}, { results: [] }, { results: Array(9).fill(pass(T0)) }, { results: [{ ...result(T0), step: "warp" }] }, { results: [{ ...result(T0), probe: "Bad Probe" }] }, { results: [{ ...result(T0), mac: {} }] }, { results: [{ ...result(T0), at: "soon" }] }])
      expect(() => parseCanary(bad as Record<string, unknown>), JSON.stringify(bad).slice(0, 60)).toThrow()
  })

  it("hears only the canary's own account", () => {
    expect(isCanaryEmail("cmux-agent-development@manaflow.ai")).toBe(true)
    expect(isCanaryEmail(" CMUX-agent-development@manaflow.ai ")).toBe(true)
    expect(isCanaryEmail("tina@manaflow.ai")).toBe(false)
    expect(isCanaryEmail(null)).toBe(false)
    expect(isCanaryEmail("probe@cmux.com", "probe@cmux.com")).toBe(true)
    expect(isCanaryEmail("cmux-agent-development@manaflow.ai", "probe@cmux.com")).toBe(false)
  })

  it("blames the service before the Mac is needed, and the canary's Mac only when it is not pinging", () => {
    for (const step of ["auth", "ice", "register", "signaling"] as const) expect(classify(result(T0, { step }), GONE, T0), step).toBe("service")
    for (const step of ["presence", "dial", "ping"] as const) {
      expect(classify(result(T0, { step }), AWAKE(T0), T0), step).toBe("service")
      expect(classify(result(T0, { step }), ASLEEP, T0), step).toBe("host_down")
      expect(classify(result(T0, { step }), GONE, T0), step).toBe("host_down")
      // The hub could not answer: a service problem, never "the canary's Mac is down".
      expect(classify(result(T0, { step }), { liveness: null }, T0), step).toBe("service")
    }
  })

  it("judges the Mac's ping inside the run's own window, at now when the canary's clock runs fast", () => {
    const run = result(T0, { durationMs: 25_000 })
    const pingAt = (t: number): MacCheck => ({ liveness: { connected: true, lastPingAt: t, pings: true } })
    expect(classify(run, pingAt(T0 - 45_000), T0 + 30_000)).toBe("service")
    expect(classify(run, pingAt(T0 - 46_000), T0 + 30_000)).toBe("host_down") // slept before the run
    expect(classify(run, pingAt(T0 + 25_000 + 30_000), T0 + 60_000)).toBe("service")
    expect(classify(run, pingAt(T0 + 25_000 + 31_000), T0 + 60_000)).toBe("host_down") // woke only after the run
    // A canary clock 2 minutes fast: its run is judged at the service's now, where the Mac's last ping is.
    expect(classify(result(T0 + 120_000), AWAKE(T0), T0)).toBe("service")
  })
})

describe("the canary on the desk", () => {
  it("posts only on the third failure in a row at the same step, then resolves on the first pass", () => {
    const { feed, incidents } = rig()
    expect(feed((at) => result(at)).actions).toEqual([])
    expect(feed((at) => result(at)).actions).toEqual([])
    const third = feed((at) => result(at))
    expect(third.actions).toHaveLength(1)
    expect(third.actions[0]).toMatchObject({ kind: "post", route: "team" })
    const text = (third.actions[0] as { text: string }).text
    expect(text).toContain(":red_circle: *The connectivity canary can't connect (WireGuard)*")
    expect(text).toContain("failing at connecting to its Mac for 2m, 3 runs in a row")
    expect(text).toContain("Its Mac “Canary Mac” is awake")
    // Still failing: nothing new.
    expect(feed((at) => result(at)).actions).toEqual([])
    const back = feed((at) => pass(at))
    expect(back.actions.map((a) => a.kind)).toEqual(["update", "reply"])
    expect((back.actions[0] as { text: string }).text).toContain(":large_green_circle: *The connectivity canary couldn't connect (WireGuard)* — passing again after 4m")
    expect((back.actions[1] as { text: string }).text).toBe("Resolved: the canary passed again after 4m.")
    expect(Object.values(incidents)).toHaveLength(1)
  })

  it("never posts failures that change step, or a pass between them", () => {
    const { feed } = rig()
    for (const step of ["dial", "ping", "dial", "signaling", "dial"] as const) expect(feed((at) => result(at, { step })).actions, step).toEqual([])
    expect(feed((at) => result(at)).actions).toEqual([])
    expect(feed((at) => pass(at)).actions).toEqual([])
    expect(feed((at) => result(at)).actions).toEqual([])
    expect(feed((at) => result(at)).actions).toEqual([])
  })

  it("says the canary's own Mac is down, never a service outage, when that Mac is not pinging", () => {
    const { feed } = rig()
    feed((at) => result(at), () => ASLEEP)
    feed((at) => result(at), () => ASLEEP)
    const third = feed((at) => result(at), () => ASLEEP)
    const text = (third.actions[0] as { text: string }).text
    expect(text).toContain(":large_yellow_circle: *The canary's own Mac “Canary Mac” is down*")
    expect(text).toContain("Not a service outage")
    expect(text).not.toContain("can't connect")
    const back = feed((at) => pass(at))
    expect((back.actions[1] as { text: string }).text).toBe("Resolved: the canary's Mac is back after 3m.")
  })

  it("closes a host-down incident and opens a service one when the Mac is awake but still unreachable", () => {
    const { feed } = rig()
    for (let i = 0; i < STRIKES; i++) feed((at) => result(at), () => ASLEEP)
    expect(feed((at) => result(at)).actions).toEqual([])
    expect(feed((at) => result(at)).actions).toEqual([])
    const switched = feed((at) => result(at))
    expect(switched.actions.map((a) => a.kind)).toEqual(["update", "reply", "post"])
    expect((switched.actions[2] as { text: string }).text).toContain(":red_circle: *The connectivity canary can't connect")
  })

  it("threads every other probe's incident of the same outage under the first", () => {
    const { desk, watch, incidents } = rig()
    const probes = ["wireguard", "wireguard-turn-tls", "webrtc", "webrtc-relay"]
    const posts: Array<{ kind: string; thread?: string }> = []
    for (let round = 0; round < STRIKES; round++) {
      const at = T0 + round * 60_000
      for (const probe of probes) posts.push(...(applyCanary(desk, watch, incidents, result(at, { probe, step: "signaling" }), GONE, at).actions as Array<{ kind: string; thread?: string }>))
    }
    expect(posts).toHaveLength(4)
    expect(posts[0]!.thread).toBeUndefined()
    for (const p of posts.slice(1)) expect(p.thread).toBe(Object.values(incidents).find((i) => !i.parent)!.id)
    // A service outage never counts against (or waits for) the hourly limits.
    expect(desk.meta.posted.filter((p) => p.reporter === "canary")).toHaveLength(0)
  })

  it("never holds a service outage, even with the hour's limit used up", () => {
    const { desk, watch, incidents } = rig()
    desk.meta.posted = Array.from({ length: LIMITS.overallPerHour }, (_, i) => ({ at: T0 - 1000 - i, reporter: `r${i}`, route: "team" as const }))
    let actions: Array<unknown> = []
    for (let i = 0; i < STRIKES; i++) actions = applyCanary(desk, watch, incidents, result(T0 + i * 60_000), AWAKE(T0 + i * 60_000), T0 + i * 60_000).actions
    expect(actions).toHaveLength(1)
    expect(desk.meta.held.team).toEqual([])
  })

  it("counts one slot per canary-Mac outage, holds the rest over the limit, keeps their ends quiet, and tells the count", () => {
    const { desk, watch, incidents } = rig()
    const probes = ["wireguard", "webrtc"]
    const down = (minute: number) => {
      const out: Array<unknown> = []
      for (let r = 0; r < STRIKES; r++) {
        const at = T0 + (minute + r) * 60_000
        for (const probe of probes) out.push(...applyCanary(desk, watch, incidents, result(at, { probe }), ASLEEP, at).actions)
      }
      return out
    }
    const back = (minute: number) => {
      const at = T0 + minute * 60_000
      return probes.flatMap((probe) => applyCanary(desk, watch, incidents, pass(at, { probe }), AWAKE(at), at).actions)
    }
    // Five outages of the canary's Mac in an hour, each on two probes: one slot each (later ones are "Again:" replies).
    for (let k = 0; k < LIMITS.perReporterPerHour; k++) {
      expect(down(k * 10).length, `outage ${k}`).toBe(probes.length)
      back(k * 10 + 4)
    }
    expect(desk.meta.posted.filter((p) => p.reporter === "canary")).toHaveLength(LIMITS.perReporterPerHour)
    // The sixth is held: nothing posted, its end quiet, the count told later.
    expect(down(55)).toEqual([])
    expect(desk.meta.held.team).toHaveLength(1)
    expect(back(59)).toEqual([])
    const told = tellHeld(desk, T0 + 2 * 3_600_000)
    expect((told[0] as { text: string }).text).toContain("1 more connectivity incident was held back by the hourly limit and not posted (the connectivity canary)")
  })

  it("keeps a second canary's streaks apart (another Mac), and counts a resend from a fast clock once", () => {
    const { desk, watch, incidents } = rig()
    const other = { id: "aaaaaaaa-1111-2222-3333-444455556666", name: "Laptop" }
    for (let i = 0; i < STRIKES; i++) {
      const at = T0 + i * 60_000
      applyCanary(desk, watch, incidents, result(at), AWAKE(at), at)
      // The other canary passes in between: it must not reset this one.
      expect(applyCanary(desk, watch, incidents, pass(at + 1, { mac: other }), AWAKE(at), at + 1).actions).toEqual([])
    }
    expect(Object.values(incidents).filter((i) => i.kind === "service")).toHaveLength(1)
    // A canary clock 5 minutes fast resends one result: one strike, not two.
    const fast = rig()
    const ahead = T0 + 5 * 60_000
    fast.watch.probes = {}
    applyCanary(fast.desk, fast.watch, fast.incidents, result(ahead), AWAKE(T0), T0)
    applyCanary(fast.desk, fast.watch, fast.incidents, result(ahead), AWAKE(T0), T0 + 20_000)
    expect(fast.watch.probes[`${MAC.id}/wireguard`]!.streak).toBe(1)
  })

  it("ignores a result older than the probe's last (a resend)", () => {
    const { desk, watch, incidents } = rig()
    for (let i = 0; i < 2; i++) applyCanary(desk, watch, incidents, result(T0 + i * 60_000), AWAKE(T0 + i * 60_000), T0 + i * 60_000)
    expect(applyCanary(desk, watch, incidents, result(T0 + 60_000), AWAKE(T0), T0 + 3 * 60_000).actions).toEqual([])
    expect(watch.probes[`${MAC.id}/wireguard`]!.streak).toBe(2)
  })
})

describe("alerting watches itself", () => {
  it("knows working time: weekdays 9:00-19:00 Pacific", () => {
    expect(isWorkTime(T0)).toBe(true) // Thu 10:00
    expect(isWorkTime(Date.parse("2026-11-12T16:59:00Z"))).toBe(false) // Thu 8:59
    expect(isWorkTime(Date.parse("2026-11-13T02:59:00Z"))).toBe(true) // Thu 18:59
    expect(isWorkTime(Date.parse("2026-11-13T03:00:00Z"))).toBe(false) // Thu 19:00
    expect(isWorkTime(Date.parse("2026-11-14T18:00:00Z"))).toBe(false) // Sat 10:00
    // Summer time: 9:00 PDT is 16:00 UTC.
    expect(isWorkTime(Date.parse("2026-07-14T16:00:00Z"))).toBe(true)
  })

  it("counts only working time toward the 4 hours, so a weekend or a night is not silence", () => {
    // Thursday 10:00 + 4 h of work = 14:00.
    expect(workDeadline(T0, 4 * 3_600_000)).toBe(Date.parse("2026-11-12T22:00:00Z"))
    // Thursday 17:00: 2 h on Thursday, 2 h on Friday from 9:00 = Friday 11:00.
    expect(workDeadline(Date.parse("2026-11-13T01:00:00Z"), 4 * 3_600_000)).toBe(Date.parse("2026-11-13T19:00:00Z"))
    // Friday 18:00: 1 h Friday, then Monday 9:00 + 3 h = Monday 12:00.
    expect(workDeadline(Date.parse("2026-11-14T02:00:00Z"), 4 * 3_600_000)).toBe(Date.parse("2026-11-16T20:00:00Z"))
  })

  it("posts 'blind' once when the canary goes silent for 10 minutes, and resolves on its next report", () => {
    const { desk, watch, incidents } = rig()
    applyCanary(desk, watch, incidents, pass(T0), AWAKE(T0), T0)
    expect(nextWatchDue(watch)).toBe(T0 + CANARY_SILENT_MS)
    expect(checkSilence(desk, watch, incidents, T0 + CANARY_SILENT_MS - 1).actions).toEqual([])
    const blind = checkSilence(desk, watch, incidents, T0 + CANARY_SILENT_MS)
    expect((blind.actions[0] as { text: string }).text).toContain(":black_circle: *Connectivity alerting is blind: the canary hasn't reported for 10m*")
    expect(checkSilence(desk, watch, incidents, T0 + 3 * CANARY_SILENT_MS).actions).toEqual([])
    expect(nextWatchDue(watch)).toBeUndefined()
    const back = applyCanary(desk, watch, incidents, pass(T0 + 25 * 60_000), AWAKE(T0 + 25 * 60_000), T0 + 25 * 60_000)
    expect(back.actions.map((a) => a.kind)).toEqual(["update", "reply"])
    expect((back.actions[0] as { text: string }).text).toContain("reporting again after 25m")
  })

  it("posts 'may be blind' after 4 working hours without a team heartbeat; test-route heartbeats don't count", () => {
    const { desk, watch, incidents } = rig()
    applyHeartbeat(watch, incidents, "team", T0)
    expect(checkSilence(desk, watch, incidents, T0 + 3 * 3_600_000).actions).toEqual([])
    applyHeartbeat(watch, incidents, "test", T0 + 3 * 3_600_000)
    const blind = checkSilence(desk, watch, incidents, Date.parse("2026-11-12T22:00:00Z"))
    expect((blind.actions[0] as { text: string }).text).toContain("no team phone has checked in for 4h of working time")
    const back = applyHeartbeat(watch, incidents, "team", Date.parse("2026-11-12T23:00:00Z"))
    expect(back.actions.map((a) => a.kind)).toEqual(["update", "reply"])
  })

  it("stays quiet over a weekend and before anything ever reported", () => {
    const { desk, watch, incidents } = rig()
    expect(checkSilence(desk, watch, incidents, T0 + 30 * 86_400_000).actions).toEqual([])
    expect(nextWatchDue(watch)).toBeUndefined()
    // A heartbeat Friday 17:00; Monday 8:00 is only 2 working hours later.
    applyHeartbeat(watch, incidents, "team", Date.parse("2026-11-14T01:00:00Z"))
    expect(checkSilence(desk, watch, incidents, Date.parse("2026-11-16T16:00:00Z")).actions).toEqual([])
  })
})

describe("phone disconnect record", () => {
  it("logs a short device id, the close and how long it was open, no user", () => {
    const att = { userId: "tina", projectId: "p", deviceId: "abcdef12-3456-7890-abcd-ef1234567890", kind: "phone" as const, name: "Tina's iPhone", teamId: "t", connectedAt: T0 }
    const rec = phoneCloseRecord(att, { code: 1006, reason: "", wasClean: false }, T0 + 65_000)
    expect(rec).toEqual({ msg: "phone signaling closed", device: "abcdef12", code: 1006, reason: null, clean: false, replaced: false, durationMs: 65_000 })
    expect(JSON.stringify(rec)).not.toContain("tina")
    expect(JSON.stringify(rec)).not.toContain("iPhone")
  })
})

describe("POST /v1/diagnostics/connectivity-canary and -heartbeat", () => {
  let calls: Array<{ method: string; body: Record<string, unknown> }>
  beforeEach(() => {
    calls = []
    let ts = 5000
    ConnectivityAlertDesk.testSlack = (async (method, b) => {
      calls.push({ method, body: b })
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
  const settled = () => runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.settled())
  const round = (mac: string, over: Partial<CanaryResult> = {}) => ({ results: [{ ...result(Date.now()), mac: { id: mac, name: "Canary Mac" }, ...over }] })

  it("refuses every account but the canary's", async () => {
    expect(await call("POST", "/v1/diagnostics/connectivity-canary", await token("tina"), round(MAC.id))).toMatchObject({ status: 403, json: { error: { code: "not_canary" } } })
    expect(await call("POST", "/v1/diagnostics/connectivity-canary", undefined, round(MAC.id))).toMatchObject({ status: 401 })
    expect(await call("POST", "/v1/diagnostics/connectivity-canary", await token("agent"), { results: [] })).toMatchObject({ status: 400 })
  })

  it("posts a service incident after three failures while the canary's Mac pings, and resolves on a pass", async () => {
    const tok = await token("agent")
    const space = "personal-agent"
    const mac = await register(tok, "mac", space, "Canary Mac")
    const sock = await connect(tok, space, mac)
    await sock.until((s) => s.frames.some((f) => f.type === "hello"))
    const ping = async () => {
      const pong = new Promise<void>((resolve) => sock.ws.addEventListener("message", (e) => e.data === "pong" && resolve()))
      sock.ws.send("ping")
      await pong
    }
    for (let i = 0; i < STRIKES; i++) {
      await ping()
      expect(await call("POST", "/v1/diagnostics/connectivity-canary", tok, round(mac, { at: new Date(Date.now() + i).toISOString(), durationMs: 0 }))).toMatchObject({ status: 202, json: { accepted: 1 } })
    }
    await settled()
    expect(calls).toHaveLength(1)
    expect(calls[0]).toMatchObject({ method: "chat.postMessage", body: { channel: "CTEAM" } })
    expect(String(calls[0]!.body.text)).toContain("The connectivity canary can't connect (WireGuard)")
    expect(await call("POST", "/v1/diagnostics/connectivity-canary", tok, round(mac, { outcome: "pass", step: undefined, at: new Date(Date.now() + 10).toISOString() }))).toMatchObject({ status: 202 })
    await settled()
    expect(calls.map((c) => c.method)).toEqual(["chat.postMessage", "chat.update", "chat.postMessage"])
    expect(calls[2]!.body).toMatchObject({ thread_ts: calls[1]!.body.ts, text: expect.stringContaining("Resolved: the canary passed again") })
    sock.ws.close()
  })

  it("says the canary's Mac is down when that Mac is not connected", async () => {
    const tok = await token("agent")
    const gone = crypto.randomUUID()
    for (let i = 0; i < STRIKES; i++) await call("POST", "/v1/diagnostics/connectivity-canary", tok, round(gone, { probe: "webrtc", step: "presence", at: new Date(Date.now() + i).toISOString() }))
    await settled()
    expect(calls.some((c) => String(c.body.text).includes("The canary's own Mac “Canary Mac” is down"))).toBe(true)
    expect(calls.some((c) => String(c.body.text).includes("can't connect (WebRTC)"))).toBe(false)
  })

  it("takes a team phone's heartbeat, sends agents and simulators to the test route, and refuses outsiders", async () => {
    const app = { version: "1.2.0", build: "450", config: "TestFlight", simulator: false }
    expect(await call("POST", "/v1/diagnostics/connectivity-heartbeat", await token("tina"), { app })).toMatchObject({ status: 202, json: { route: "team" } })
    expect(await call("POST", "/v1/diagnostics/connectivity-heartbeat", await token("tina"), { app: { ...app, simulator: true } })).toMatchObject({ status: 202, json: { route: "test" } })
    expect(await call("POST", "/v1/diagnostics/connectivity-heartbeat", await token("agent"), { app })).toMatchObject({ status: 202, json: { route: "test" } })
    expect(await call("POST", "/v1/diagnostics/connectivity-heartbeat", await token("out"), { app })).toMatchObject({ status: 403 })
    expect(await call("POST", "/v1/diagnostics/connectivity-heartbeat", await token("tina"), {})).toMatchObject({ status: 400 })
    const { watch } = await runInDurableObject(desk(), (d: ConnectivityAlertDesk) => d.watchSnapshot())
    expect(watch.lastTeamHeartbeatAt).toBeTypeOf("number")
  })
})
