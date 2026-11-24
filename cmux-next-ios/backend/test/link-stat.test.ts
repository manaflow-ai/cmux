import { afterEach, describe, expect, it, vi } from "vitest"
import { linkStatLine, MAX_LINK_STAT_FRAME } from "../src/team-hub.ts"
import { connect, register, token } from "./helpers.ts"

// A phone's link_stat as cmux-mobile-link sends it (link_stat.rs, PROTOCOL.md "Link stats").
const stat = (over: Record<string, unknown> = {}) => ({
  type: "link_stat",
  v: 1,
  transport: "wireguard",
  path: "turn-tls",
  reason: "first",
  setupMs: 812,
  marks: { signaling_open: 120, dial_start: 130, link_ready: 700, first_pong: 812 },
  rtt: { n: 3, p50: 41, p95: 77, max: 80 },
  pings: 3,
  lost: 0,
  switches: 1,
  net: "cellular",
  upS: 2,
  lib: "0.1.0",
  ...over
})

const ingress = { colo: "SJC", country: "US", continent: "NA" }

describe("link_stat log line", () => {
  it("keeps fixed words and clamped numbers, and adds where the phone entered and where its hub runs", () => {
    expect(linkStatLine(stat(), "phone", ingress, "LAX")).toEqual({
      event: "link_stat",
      v: 1,
      kind: "phone",
      transport: "wireguard",
      path: "turn-tls",
      reason: "first",
      pings: 3,
      lost: 0,
      setupMs: 812,
      marks: { signaling_open: 120, dial_start: 130, link_ready: 700, first_pong: 812 },
      rttN: 3,
      rttP50: 41,
      rttP95: 77,
      rttMax: 80,
      switches: 1,
      net: "cellular",
      upS: 2,
      lib: "0.1.0",
      ingressColo: "SJC",
      country: "US",
      continent: "NA",
      hubColo: "LAX"
    })
  })

  it("clamps numbers, drops unknown marks, words and free text, and never copies an id", () => {
    const line = linkStatLine(
      stat({
        setupMs: 1e12,
        marks: { first_pong: 5, "x 10.0.0.1": 3, link_ready: "soon" },
        rtt: { n: 2, p50: 1e9, p95: 1e9, max: 1e9 },
        pings: 1e9,
        net: "wifi 192.168.1.1",
        end: "app",
        lib: "a version with spaces",
        deviceId: "6f1c7a6e-0000-4000-8000-000000000000",
        userId: "alice"
      }),
      "phone",
      undefined,
      null
    )!
    expect(line.setupMs).toBe(600_000)
    expect(line.marks).toEqual({ first_pong: 5 })
    expect(line.rttP95).toBe(600_000)
    expect(line.pings).toBe(100_000)
    expect(line.net).toBeUndefined()
    // `end` only on an end stat.
    expect(line.end).toBeUndefined()
    expect(line.lib).toBeUndefined()
    expect(JSON.stringify(line)).not.toMatch(/alice|6f1c7a6e|10\.0\.0\.1|192\.168/)
    expect(line).toMatchObject({ ingressColo: null, country: null, continent: null, hubColo: null })
    expect(linkStatLine(stat({ reason: "end", end: "keepalive" }), "phone", ingress, null)!.end).toBe("keepalive")
  })

  it("logs which protocol mapped the Mac's endpoint and whether the route uses it, fixed words only", () => {
    expect(linkStatLine(stat({ path: "direct", portmap: { by: "pcp", used: true } }), "phone", ingress, null)).toMatchObject({ path: "direct", portmapBy: "pcp", portmapUsed: true })
    expect(linkStatLine(stat({ portmap: { by: "upnp", used: false } }), "phone", ingress, null)).toMatchObject({ portmapBy: "upnp", portmapUsed: false })
    for (const bad of [{ by: "203.0.113.7", used: true }, { by: "pcp", used: "yes" }, "pcp", null]) {
      const line = linkStatLine(stat({ portmap: bad }), "phone", ingress, null)!
      expect(line.portmapBy).toBeUndefined()
      expect(line.portmapUsed).toBeUndefined()
    }
  })

  it("flattens keystroke round trips and keeps at most six clamped spikes", () => {
    const line = linkStatLine(
      stat({
        echo: { n: 40, p50: 45, p95: 140, p99: 1900, max: 1900 },
        ack: { n: 40, p50: 38, p95: 120, p99: 1e9, max: 1e9 },
        spikeCount: 9,
        spikes: [[1940, 1880, 1900], [62, -1, 400], [5, 30, "slow"], [1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11], [12, 13, 14], [15, 16, 17]]
      }),
      "phone",
      ingress,
      null
    )!
    expect(line).toMatchObject({ echoN: 40, echoP50: 45, echoP95: 140, echoP99: 1900, echoMax: 1900, ackP99: 600_000, spikeCount: 9 })
    // The first six entries are read, malformed ones dropped; -1 is "no answer yet".
    expect(line.spikes).toEqual([[1940, 1880, 1900], [62, -1, 400], [3, 4, 5], [6, 7, 8]])
    expect(linkStatLine(stat({ echo: "fast", spikes: "none" }), "phone", ingress, null)).not.toHaveProperty("echoN")
  })

  it("rejects a malformed stat", () => {
    for (const bad of [{ v: 2 }, { transport: "carrier-pigeon" }, { path: "10.0.0.1:443" }, { reason: "because" }, { pings: -1 }, { lost: "none" }, { pings: Number.NaN }]) {
      expect(linkStatLine(stat(bad), "phone", ingress, null)).toBeNull()
    }
  })
})

describe("link_stat on the signaling socket", () => {
  afterEach(() => vi.restoreAllMocks())

  it("logs one line per accepted stat and never answers, malformed or not", async () => {
    const logged: Array<Record<string, unknown>> = []
    vi.spyOn(console, "log").mockImplementation((...args: Array<unknown>) => {
      try {
        const j = JSON.parse(String(args[0]))
        if (j?.event === "link_stat") logged.push(j)
      } catch {}
    })
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const p = await connect(alice, "team-a", phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    p.send(stat())
    // Malformed and too-soon stats are dropped silently: a session-less error would fail the phone's dials.
    p.send(stat({ transport: "nope" }))
    p.send(stat({ reason: "periodic" }))
    p.ws.send(JSON.stringify(stat({ marks: { first_pong: 1, pad: "x".repeat(MAX_LINK_STAT_FRAME) } })))
    // A frame the hub does answer, so the stats before it were all handled when its answer comes.
    p.send({ type: "nonsense" })
    await p.until((s) => s.frames.some((f) => f.type === "error"))
    expect(p.frames.filter((f) => f.type === "error")).toEqual([{ type: "error", code: "bad_request", message: "unknown frame type" }])
    expect(logged).toHaveLength(1)
    expect(logged[0]).toMatchObject({ event: "link_stat", kind: "phone", transport: "wireguard", path: "turn-tls", reason: "first", rttP50: 41 })
    expect(JSON.stringify(logged[0])).not.toContain(phone)
    // The end stat is logged even right after another.
    p.send(stat({ reason: "end", end: "app" }))
    p.send({ type: "nonsense" })
    await p.until((s) => s.frames.filter((f) => f.type === "error").length === 2)
    expect(logged.map((l) => l.reason)).toEqual(["first", "end"])
    p.ws.close()
  })

  it("ignores a Mac's stat", async () => {
    const logged: Array<unknown> = []
    vi.spyOn(console, "log").mockImplementation((...args: Array<unknown>) => {
      if (String(args[0]).includes('"link_stat"')) logged.push(args[0])
    })
    const alice = await token("alice")
    const mac = await register(alice, "mac", "team-a")
    const m = await connect(alice, "team-a", mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))
    m.send(stat())
    m.send({ type: "nonsense" })
    await m.until((s) => s.frames.some((f) => f.type === "error"))
    expect(logged).toHaveLength(0)
    m.ws.close()
  })
})
