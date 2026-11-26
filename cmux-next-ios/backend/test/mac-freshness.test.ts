import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { FRESH_MS, userHubName, type TeamHub } from "../src/team-hub.ts"
import { call, connect, register, token } from "./helpers.ts"

// Mac freshness (PROTOCOL.md "Mac freshness"): every Mac listing says how long ago the hub last heard an online
// Mac, so a phone can tell an awake Mac from one whose socket is only half open (asleep), and from its own stale
// cache, on the first answer it gets.

const hubOf = (owner: string) => {
  const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
  return ns.get(ns.idFromName(userHubName(owner)))
}

/** Moves the Mac socket's connect `ms` into the past, as if the Mac connected then and never pinged since. */
const ageSocket = (owner: string, mac: string, ms: number) =>
  runInDurableObject(hubOf(owner), (hub, state) => {
    for (const ws of state.getWebSockets(mac)) {
      const h = hub as unknown as { attach(ws: WebSocket): Record<string, unknown>; setAttach(ws: WebSocket, a: Record<string, unknown>): void }
      h.setAttach(ws, { ...h.attach(ws), connectedAt: Date.now() - ms })
    }
  })

const quietOf = async (tok: string, team: string, mac: string) => {
  const inTeam = (await call("GET", `/v1/teams/${team}/macs`, tok)).json.macs.find((m: any) => m.deviceId === mac)
  const mine = (await call("GET", "/v1/me/macs", tok)).json.macs.find((m: any) => m.deviceId === mac)
  const boot = (await call("POST", "/v1/me/bootstrap", tok, { teamId: team, devices: [] })).json
  return { inTeam, mine, boot: boot.macs.macs.find((m: any) => m.deviceId === mac), bootMine: boot.myMacs.macs.find((m: any) => m.deviceId === mac) }
}

describe("Mac freshness", () => {
  it("lists quietMs only for an online Mac, in hello, presence and every Mac route", async () => {
    const owner = "fresh-ann"
    const team = `personal-${owner}`
    const t = await token(owner)
    const phone = await register(t, "phone", team)
    const mac = await register(t, "mac", team, "Fresh Mac")

    // Offline: no quietMs anywhere (an old phone sees the same shape as before).
    const off = await quietOf(t, team, mac)
    for (const m of [off.inTeam, off.mine, off.boot, off.bootMine]) {
      expect(m).toMatchObject({ online: false })
      expect(m).not.toHaveProperty("quietMs")
    }
    const p = await connect(t, team, phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p.frames[0].macs.find((m: any) => m.deviceId === mac)).not.toHaveProperty("quietMs")

    // The Mac connects: the presence frame says it was heard just now.
    const m = await connect(t, team, mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    const up = p.frames.find((f) => f.type === "presence" && f.mac.online)!.mac
    expect(up.quietMs).toBeGreaterThanOrEqual(0)
    expect(up.quietMs).toBeLessThan(FRESH_MS)
    const on = await quietOf(t, team, mac)
    for (const x of [on.inTeam, on.mine, on.boot, on.bootMine]) {
      expect(x).toMatchObject({ online: true })
      expect(x.quietMs).toBeGreaterThanOrEqual(0)
      expect(x.quietMs).toBeLessThan(FRESH_MS)
    }
    // A second phone socket's hello carries it too.
    const p2 = await connect(t, team, await register(t, "phone", team))
    await p2.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p2.frames[0].macs.find((x: any) => x.deviceId === mac).quietMs).toBeLessThan(FRESH_MS)

    // The Mac goes away: offline, no quietMs.
    m.ws.close(1000, "done")
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.online))
    expect(p.frames.filter((f) => f.type === "presence").at(-1)!.mac).not.toHaveProperty("quietMs")
    p.ws.close()
    p2.ws.close()
  })

  it("grows while a connected Mac is silent, and resets on its application ping", async () => {
    const owner = "fresh-bob"
    const team = `personal-${owner}`
    const t = await token(owner)
    const mac = await register(t, "mac", team, "Sleepy Mac")
    const m = await connect(t, team, mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))

    // Asleep: the socket is still open (online), but nothing was heard for a minute.
    await ageSocket(owner, mac, 60_000)
    const asleep = await quietOf(t, team, mac)
    for (const x of [asleep.inTeam, asleep.mine, asleep.boot, asleep.bootMine]) {
      expect(x).toMatchObject({ online: true })
      expect(x.quietMs).toBeGreaterThanOrEqual(60_000)
    }
    const phone = await register(t, "phone", team)
    const p = await connect(t, team, phone)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p.frames[0].macs.find((x: any) => x.deviceId === mac).quietMs).toBeGreaterThanOrEqual(60_000)

    // It wakes and pings (answered by the runtime, the hub keeps its time): fresh again.
    m.ws.send("ping")
    const deadline = Date.now() + 3000
    let quiet = Infinity
    while (Date.now() < deadline) {
      quiet = (await call("GET", `/v1/teams/${team}/macs`, t)).json.macs.find((x: any) => x.deviceId === mac).quietMs
      if (quiet < FRESH_MS) break
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(quiet).toBeLessThan(FRESH_MS)
    m.ws.close()
    p.ws.close()
  })
})
