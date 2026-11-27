import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { REGIONS } from "../src/placement.ts"
import { centralPick, observe, pairKey, REGION_PICK_ABI, RegionLearner } from "../src/region-pick.ts"
import { userHubName, type Ingress, type TeamHub } from "../src/team-hub.ts"
import { register, sockOf, token, worker, type Sock } from "./helpers.ts"

/** An ingress with only what the pick reads. */
const at = (i: Partial<Ingress>): Ingress => ({ country: null, continent: null, colo: null, ...i })
/** An estimate array in REGIONS order from a few named regions. */
const est = (named: Partial<Record<(typeof REGIONS)[number], number>>) => REGIONS.map((r) => named[r])

// The same cases as rust/crates/cmux-region-pick/src/tests.rs, through the built wasm: the glue and the crate agree.
describe("central region pick: the wasm matches the Rust crate", () => {
  it("speaks layout version 1", () => expect(REGION_PICK_ABI).toBe(1))

  it("nothing learned keeps the placement's pick", () => {
    expect(centralPick(est({ wnam: 40, enam: 70 }), {}, undefined, "enam")).toEqual({ region: "enam", by: "fallback" })
    expect(centralPick(est({ wnam: 40 }), {}, undefined, undefined)).toEqual({ region: undefined, by: "fallback" })
  })

  it("a measured detour moves the pair, and a measured better region keeps it", () => {
    const e = est({ wnam: 40, enam: 70, weur: 150 })
    expect(centralPick(e, { wnam: { ms: 200, n: 3 } }, undefined, "wnam")).toEqual({ region: "enam", by: "calibrated", ms: 130 })
    expect(centralPick(e, { wnam: { ms: 200, n: 3 }, enam: { ms: 85, n: 1 } }, "enam", "wnam")).toEqual({ region: "enam", by: "measured", ms: 85 })
  })

  it("a calibrated region can win, and a slow last mile alone does not wander", () => {
    expect(centralPick(est({ wnam: 30, apac: 5 }), { wnam: { ms: 120, n: 1 } }, "wnam", "wnam")).toEqual({ region: "apac", by: "calibrated", ms: 65 })
    expect(centralPick(est({ wnam: 40, enam: 70 }), { wnam: { ms: 160, n: 1 } }, undefined, "wnam").region).toBe("wnam")
  })

  it("hysteresis: 20 % or 10 ms, as relay_rank.rs", () => {
    const e = est({ wnam: 50, enam: 50 })
    const l = (w: number, n: number) => ({ wnam: { ms: w, n: 1 }, enam: { ms: n, n: 1 } })
    expect(centralPick(e, l(100, 85), "wnam", undefined).region).toBe("wnam")
    expect(centralPick(e, l(100, 79), "wnam", undefined).region).toBe("enam")
    expect(centralPick(e, l(30, 21), "wnam", undefined).region).toBe("wnam")
    expect(centralPick(e, l(30, 19), "wnam", undefined).region).toBe("enam")
  })

  it("observe seeds then averages (alpha 0.25) and refuses junk", () => {
    const a = observe(undefined, 100)
    expect(a).toEqual({ ms: 100, n: 1 })
    expect(observe(a, 200)).toEqual({ ms: 125, n: 2 })
    for (const bad of [-1, Number.NaN, Number.POSITIVE_INFINITY, 5001]) expect(observe(a, bad)).toBe(a)
  })
})

describe("pairKey", () => {
  it("keys on both ends' AS number and colo, the phone first, and needs both", () => {
    expect(pairKey(at({ colo: "SJC", asn: 7922 }), at({ colo: "LAX", asn: 701 }))).toBe("7922@SJC>701@LAX")
    expect(pairKey(at({ colo: "SJC" }), at({ colo: "LAX", asn: 701 }))).toBeUndefined()
    expect(pairKey(at({ colo: null, asn: 7922 }), at({ colo: "LAX", asn: 701 }))).toBeUndefined()
    expect(pairKey(at({ colo: "SJC", asn: 7922 }), undefined)).toBeUndefined()
  })
})

const hubs = (env as unknown as Env).TEAM_HUB as unknown as DurableObjectNamespace<TeamHub>
const hubOf = (user: string) => hubs.get(hubs.idFromName(userHubName(user)))
const tables = (user: string) =>
  runInDurableObject(hubOf(user), (_h: TeamHub, state) =>
    state.storage.sql.exec<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'region_%' ORDER BY name`).toArray().map((r) => r.name)
  )
const rows = (user: string) => runInDurableObject(hubOf(user), (_h: TeamHub, state) => new RegionLearner(state.storage.sql).rows())

describe("RegionLearner (the hub's tables)", () => {
  it("credits a relayed link_stat to the phone's placement, then moves the pair off a measured detour", async () => {
    await runInDurableObject(hubOf(`learner-${crypto.randomUUID()}`), (_h: TeamHub, state) => {
      const l = new RegionLearner(state.storage.sql)
      const phone = at({ colo: "SJC", asn: 7922, lat: 37.3, lon: -121.9 })
      const mac = at({ colo: "SJC", asn: 7922, lat: 37.4, lon: -122 })
      const first = l.place("p1", phone, mac, phone, mac, "wnam", 1_000)
      expect(first).toMatchObject({ region: "wnam", by: "fallback", pair: "7922@SJC>7922@SJC" })
      // Too few samples, then a window that counts.
      expect(l.credit("p1", 400, 2, 2_000)).toBeUndefined()
      expect(l.credit("p1", 400, 5, 2_000)).toBe("wnam")
      expect(l.rows().rtt).toEqual([{ pair: "7922@SJC>7922@SJC", region: "wnam", ms: 400, n: 1 }])
      // 400 ms where the estimate said a few: the next session tries another region.
      const second = l.place("p1", phone, mac, phone, mac, "wnam", 3_000)
      expect(second.by).toBe("calibrated")
      expect(second.region).not.toBe("wnam")
      // Two different placements in the window: a stat can't tell which relay it measured, so it is not used.
      expect(l.credit("p1", 50, 5, 4_000)).toBeUndefined()
      // Past the window only the newest placement is recent again.
      expect(l.credit("p1", 50, 5, 3_000 + 31 * 60_000)).toBeUndefined()
      l.place("p1", phone, mac, phone, mac, "wnam", 3_000 + 40 * 60_000)
      // A pair with no AS number has no key: the placement is unchanged and nothing is stored.
      expect(l.place("p2", at({ colo: "SJC" }), mac, phone, mac, "wnam", 5_000)).toEqual({ region: "wnam", by: "fallback" })
    })
  })

  it("keeps at most 64 pairs, dropping the least recently seen", async () => {
    await runInDurableObject(hubOf(`learner-${crypto.randomUUID()}`), (_h: TeamHub, state) => {
      const l = new RegionLearner(state.storage.sql)
      for (let i = 0; i < 70; i++) {
        const a = at({ colo: "SJC", asn: 1000 + i })
        l.place(`p${i}`, a, a, a, a, "wnam", i * 10)
        expect(l.credit(`p${i}`, 80, 5, i * 10 + 1)).toBe("wnam")
      }
      const pairs = new Set(l.rows().rtt.map((r) => r.pair))
      expect(pairs.size).toBe(64)
      expect(pairs.has("1000@SJC>1000@SJC")).toBe(false)
      expect(pairs.has("1069@SJC>1069@SJC")).toBe(true)
    })
  })
})

describe("TeamHub with the central pick (LINK_RELAY_CENTRAL_PICK)", () => {
  const vars = env as unknown as { LINK_RELAY_CENTRAL_PICK?: string }
  afterEach(() => {
    delete vars.LINK_RELAY_CENTRAL_PICK
  })

  /** A signal socket entering Cloudflare at `colo` from AS `asn` (the Worker reads `req.cf`). */
  const open = async (tok: string, deviceId: string, asn: number): Promise<Sock> => {
    const req = new Request(`https://api.test/v1/teams/team-a/signal?deviceId=${deviceId}`, {
      headers: { Upgrade: "websocket", authorization: `Bearer ${tok}` },
      cf: { colo: "SJC", country: "US", continent: "NA", latitude: "37.3", longitude: "-121.9", asn }
    } as RequestInit)
    const res = await worker.fetch(req)
    expect(res.status).toBe(101)
    const s = sockOf(res.webSocket!)
    await s.until((x) => x.frames.some((f) => f.type === "hello"))
    return s
  }
  const until = async (f: () => Promise<boolean>) => {
    for (let i = 0; i < 100; i++) {
      if (await f()) return true
      await new Promise((r) => setTimeout(r, 10))
    }
    return false
  }
  // A v1 link_stat exactly as today's phones send it (no field was added for the pick).
  const relayed = (extra: Record<string, unknown> = {}) => ({ type: "link_stat", v: 1, transport: "wireguard", path: "https-relay", reason: "first", rtt: { n: 5, p50: 180, p95: 220, max: 240 }, pings: 5, lost: 0, ...extra })
  const run = async (user: string) => {
    const tok = await token(user)
    const phone = await register(tok, "phone", "team-a")
    const mac = await register(tok, "mac", "team-a")
    const p = await open(tok, phone, 7922)
    const m = await open(tok, mac, 701)
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((x) => x.frames.some((f) => f.type === "signal" && f.sessionId === sessionId))
    return { p, m }
  }

  it("off (the default): no table is made and relayed stats are only logged, as before", async () => {
    const { p, m } = await run("alice")
    p.send(relayed())
    await new Promise((r) => setTimeout(r, 100))
    expect(await tables("alice")).toEqual([])
    p.ws.close()
    m.ws.close()
  })

  it("on: today's v1 link_stat over the relay feeds the pair's region, and an unknown extra field is still accepted", async () => {
    vars.LINK_RELAY_CENTRAL_PICK = "on"
    const { p, m } = await run("bob")
    p.send(relayed({ futureField: { anything: 1 } }))
    expect(await until(async () => (await rows("bob")).rtt.length === 1)).toBe(true)
    expect((await rows("bob")).rtt[0]).toMatchObject({ pair: "7922@SJC>701@SJC", ms: 180, n: 1 })
    // A stat that did not ride the relay is not credited (an end stat skips the rate limit).
    p.send(relayed({ path: "direct", reason: "end", end: "app", rtt: { n: 5, p50: 9, p95: 9, max: 9 } }))
    await new Promise((r) => setTimeout(r, 100))
    expect((await rows("bob")).rtt[0]).toMatchObject({ ms: 180, n: 1 })
    p.ws.close()
    m.ws.close()
  })
})
