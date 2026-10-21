import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { retireAllTeamHubs } from "../src/index.ts"
import { memoryStore } from "../src/store.ts"
import { userHubName, uuidToBytes, type TeamHub } from "../src/team-hub.ts"
import { call, connect, DEV_PROJECT, PROD_PROJECT, register, token, worker, type Sock } from "./helpers.ts"

/**
 * The hub is per user (PROTOCOL.md "Signaling WebSocket"): uma and vic are both members of team-u, and
 * neither may learn of, list, signal or reach the other's devices through any endpoint or hub message.
 */
const HEX = "cd".repeat(32)
const TEAM = "team-u"
const offer = (from: string, to: string, sessionId = crypto.randomUUID(), kind = "webrtc-offer") => ({ type: "signal", to, from, sessionId, payload: { kind, sdp: "v=0" } })
const hello = (s: Sock) => s.until((x) => x.frames.some((f) => f.type === "hello"))
const errors = (s: Sock) => s.frames.filter((f) => f.type === "error")
/** Every id and name a socket has heard, as one string to search. */
const heard = (s: Sock) => JSON.stringify(s.frames)
const hubOf = (owner: string) => (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB.get((env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB.idFromName(userHubName(owner)))

const setup = async () => {
  const uma = await token("uma")
  const vic = await token("vic")
  const umaPhone = await register(uma, "phone", TEAM, "Uma iPhone")
  const umaMac = await register(uma, "mac", TEAM, "Uma Studio")
  const vicPhone = await register(vic, "phone", TEAM, "Vic iPhone")
  const vicMac = await register(vic, "mac", TEAM, "Vic Studio")
  return { uma, vic, umaPhone, umaMac, vicPhone, vicMac }
}

describe("per-user hub isolation (two users on one team)", () => {
  it("REST: lists, bootstrap and device views show only the caller's own devices", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const ids = (r: { json: any }, key = "macs") => (r.json[key] as Array<{ deviceId: string }>).map((d) => d.deviceId)
    for (const [tok, own, other] of [
      [uma, [umaMac], [vicMac, vicPhone]],
      [vic, [vicMac], [umaMac, umaPhone]]
    ] as const) {
      const team = await call("GET", `/v1/teams/${TEAM}/macs`, tok)
      expect(team.status).toBe(200)
      expect(ids(team)).toEqual(expect.arrayContaining([...own]))
      for (const id of other) expect(ids(team)).not.toContain(id)
      const mine = await call("GET", "/v1/me/macs", tok)
      for (const id of other) expect(ids(mine)).not.toContain(id)
      const devices = await call("GET", "/v1/me/devices", tok)
      for (const id of other) expect(ids(devices, "devices")).not.toContain(id)
      const boot = await call("POST", "/v1/me/bootstrap", tok, { teamId: TEAM, devices: [] })
      for (const id of other) {
        expect(ids({ json: boot.json.macs })).not.toContain(id)
        expect(ids({ json: boot.json.myMacs })).not.toContain(id)
      }
    }
    // Nothing of uma's appears anywhere in vic's answers, not even her user id.
    const sub = "uma"
    for (const path of [`/v1/teams/${TEAM}/macs`, "/v1/me/macs", "/v1/me/devices"])
      expect(JSON.stringify((await call("GET", path, vic)).json)).not.toMatch(new RegExp(`${umaMac}|${umaPhone}|"${sub}"|Uma`))
  })

  it("REST: another user cannot take over, delete, push to or notify from a teammate's devices", async () => {
    const { uma, vic, umaPhone, umaMac } = await setup()
    expect(await call("POST", "/v1/devices", vic, { deviceId: umaMac, kind: "mac", name: "Mine now", teamId: TEAM })).toMatchObject({ status: 403, json: { error: { code: "not_owner" } } })
    expect(await call("DELETE", `/v1/devices/${umaMac}`, vic)).toMatchObject({ status: 403 })
    expect((await call("PUT", `/v1/devices/${umaPhone}/push`, vic, { token: HEX, environment: "sandbox", topic: "dev.cmux.mobile" })).status).toBe(403)
    expect((await call("DELETE", `/v1/devices/${umaPhone}/push`, vic)).status).toBe(403)
    expect((await call("POST", `/v1/devices/${umaMac}/notify`, vic, { eventId: "e1", kind: "question" })).status).toBe(403)
    // Uma's devices are untouched.
    const mine = (await call("GET", "/v1/me/devices", uma)).json.devices
    expect(mine.find((d: any) => d.deviceId === umaMac)).toMatchObject({ name: "Uma Studio", teamId: TEAM })
  })

  it("hub: hello and presence carry only the socket owner's Macs", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const vp = await connect(vic, TEAM, vicPhone)
    const vm = await connect(vic, TEAM, vicMac)
    const up = await connect(uma, TEAM, umaPhone)
    for (const s of [vp, vm, up]) await hello(s)
    expect(vp.frames[0].macs.map((m: any) => m.deviceId)).toContain(vicMac)
    expect(vp.frames[0].macs.every((m: any) => m.ownerUserId === "vic")).toBe(true)
    expect(up.frames[0].macs.map((m: any) => m.deviceId)).toContain(umaMac)
    expect(up.frames[0].macs.every((m: any) => m.ownerUserId === "uma")).toBe(true)
    expect(up.frames[0].macs[0]).not.toHaveProperty("teamId")
    // Uma's Mac comes online, is renamed, goes offline and is deleted: vic's sockets hear none of it.
    const um = await connect(uma, TEAM, umaMac)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && f.mac.online))
    expect((await call("POST", "/v1/devices", uma, { deviceId: umaMac, kind: "mac", name: "Uma Renamed", teamId: TEAM })).status).toBe(200)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.name === "Uma Renamed"))
    um.ws.close(1000, "done")
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && !f.mac.online))
    expect((await call("DELETE", `/v1/devices/${umaMac}`, uma)).status).toBe(200)
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.removed))
    // Vic's own Mac still announces itself to vic: the hub is alive, it just never mixes users.
    vm.ws.close(1000, "done")
    await vp.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === vicMac && !f.mac.online))
    for (const s of [vp, vm]) expect(heard(s)).not.toMatch(new RegExp(`${umaMac}|${umaPhone}|Uma`))
    expect(heard(up)).not.toMatch(new RegExp(`${vicMac}|${vicPhone}|Vic`))
    for (const s of [vp, up]) s.ws.close()
  })

  it("hub: no signal, wg-endpoints or session reuse reaches another user's device, online or not", async () => {
    const { uma, vic, umaPhone, umaMac, vicPhone, vicMac } = await setup()
    const up = await connect(uma, TEAM, umaPhone)
    const um = await connect(uma, TEAM, umaMac)
    const vp = await connect(vic, TEAM, vicPhone)
    const vm = await connect(vic, TEAM, vicMac)
    for (const s of [up, um, vp, vm]) await hello(s)

    // Uma's own session works.
    const sessionId = crypto.randomUUID()
    up.send(offer(umaPhone, umaMac, sessionId, "wg-init"))
    await um.until((s) => s.frames.some((f) => f.type === "signal"))

    // Vic's phone to uma's online Mac: refused as not_owner (never "offline", which would tell it exists).
    for (const kind of ["webrtc-offer", "wg-init", "wg-endpoints", "webrtc-ice", "bye"]) vp.send(offer(vicPhone, umaMac, crypto.randomUUID(), kind))
    // Riding uma's session, in either direction, from vic's phone and vic's Mac.
    vp.send(offer(vicPhone, umaMac, sessionId, "wg-endpoints"))
    vm.send(offer(vicMac, umaPhone, sessionId, "wg-resp"))
    // Vic's Mac starting a session to uma's phone.
    vm.send(offer(vicMac, umaPhone))
    // A spoofed from.
    vp.send(offer(umaPhone, umaMac))
    await vp.until((s) => errors(s).length === 7)
    await vm.until((s) => errors(s).length === 2)
    expect(errors(vp).slice(0, 6).every((e) => e.code === "not_owner")).toBe(true)
    expect(errors(vp)[6]).toMatchObject({ code: "bad_request" })
    expect(errors(vm).every((e) => e.code === "not_owner")).toBe(true)
    // Uma's own Mac (also offline) is equally unknown to vic: same refusal.
    um.ws.close(1000, "done")
    await up.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === umaMac && !f.mac.online))
    vp.send(offer(vicPhone, umaMac))
    await vp.until((s) => errors(s).length === 8)
    expect(errors(vp)[7]).toMatchObject({ code: "not_owner" })

    // Retired relay frames addressed to uma's devices are never forwarded either.
    const frame = new Uint8Array(36)
    frame.set(uuidToBytes(sessionId), 0)
    frame.set(uuidToBytes(umaPhone), 16)
    vm.ws.send(frame)
    await vm.until((s) => errors(s).some((e) => e.code === "relay_retired"))

    // Uma's sockets got only uma's own frames.
    expect(up.frames.filter((f) => f.type === "signal")).toHaveLength(0)
    expect(um.frames.filter((f) => f.type === "signal")).toHaveLength(1)
    expect(up.binary.length + um.binary.length).toBe(0)
    for (const s of [up, um]) expect(heard(s)).not.toMatch(new RegExp(`${vicMac}|${vicPhone}|"vic"`))
    for (const s of [up, vp, vm]) s.ws.close()
  })

  it("hub: a user cannot open a socket as a teammate's device", async () => {
    const { vic, umaPhone, umaMac } = await setup()
    for (const id of [umaPhone, umaMac]) {
      const res = await worker.fetch(`https://api.test/v1/teams/${TEAM}/signal?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${vic}` } })
      expect(res.status).toBe(403)
    }
  })

  it("a hub refuses a socket that names another owner", async () => {
    const vic = await token("vic")
    await register(vic, "phone", TEAM)
    const umaPhone = await register(await token("uma"), "phone", TEAM)
    // vic's hub, asked (as a routing bug would) to admit uma's device under uma's owner key.
    const claim = { userId: "uma", projectId: "p", deviceId: umaPhone, ownerKey: "uma", teamId: TEAM }
    const res = await hubOf("vic").fetch("https://team-hub/signal", { headers: { upgrade: "websocket", "x-cmux-mobile-claim": JSON.stringify(claim) } })
    expect(res.status).toBe(500)
    expect((await hubOf("vic").macs("vic")).every((m) => m.ownerUserId === "vic")).toBe(true)
  })
})

describe("per-user hub: one user's own devices", () => {
  it("a phone dials the user's own Mac in another team; presence still lists one team's Macs", async () => {
    const uma = await token("uma")
    const phone = await register(uma, "phone", TEAM)
    const mac = await register(uma, "mac", "personal-uma", "Uma Air")
    const p = await connect(uma, TEAM, phone)
    const m = await connect(uma, "personal-uma", mac)
    await hello(p)
    await hello(m)
    expect(p.frames[0].macs.map((x: any) => x.deviceId)).not.toContain(mac)
    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "webrtc-answer", sdp: "a" } })
    await p.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac)).toBe(false)
    for (const s of [p, m]) s.ws.close()
  })

  it("a Mac that moves team is closed with 4001 and drops out of its old team's presence", async () => {
    const uma = await token("uma")
    const phone = await register(uma, "phone", TEAM)
    const other = await register(uma, "phone", "team-u2")
    const mac = await register(uma, "mac", TEAM, "Mover")
    const p = await connect(uma, TEAM, phone)
    const p2 = await connect(uma, "team-u2", other)
    const m = await connect(uma, TEAM, mac)
    let code = 0
    m.ws.addEventListener("close", (e) => {
      code = (e as CloseEvent).code
    })
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    expect((await call("POST", "/v1/devices", uma, { deviceId: mac, kind: "mac", name: "Mover", teamId: "team-u2" })).status).toBe(200)
    await m.until((s) => s.closed)
    expect(code).toBe(4001)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.removed))
    await p2.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.removed))
    // Its old team no longer admits it; its new team does.
    expect((await worker.fetch(`https://api.test/v1/teams/${TEAM}/signal?deviceId=${mac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${uma}` } })).status).toBe(403)
    const again = await connect(uma, "team-u2", mac)
    await p2.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    for (const s of [p, p2, again]) s.ws.close()
  })

  it("a phone that moves team keeps its open socket and its link keeps signaling", async () => {
    const uma = await token("uma")
    const phone = await register(uma, "phone", TEAM)
    const mac = await register(uma, "mac", TEAM)
    const p = await connect(uma, TEAM, phone)
    const m = await connect(uma, TEAM, mac)
    for (const s of [p, m]) await hello(s)
    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId, "wg-init"))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    // The app switched team view: the phone re-registers elsewhere while its link is up.
    expect((await call("POST", "/v1/devices", uma, { deviceId: phone, kind: "phone", name: "Uma iPhone", teamId: "team-u2" })).status).toBe(200)
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-endpoints", generation: 2, endpoints: ["198.51.100.9:5000"] } })
    await m.until((s) => s.frames.filter((f) => f.type === "signal").length === 2)
    expect(p.closed).toBe(false)
    for (const s of [p, m]) s.ws.close()
  })

  it("a new hub lists the user's offline Macs from the database (old registrations)", async () => {
    const owner = "wes"
    const mac = crypto.randomUUID()
    // A Mac registered before per-user hubs: in the database only, never announced to this hub.
    const r = await memoryStore().upsertDevice({ deviceId: mac, ownerUserId: owner, teamId: `personal-${owner}`, kind: "mac", name: "Old Mac", wgPublicKey: null })
    expect(r).not.toBe("not_owner")
    const wes = await token(owner)
    const phone = await register(wes, "phone", `personal-${owner}`)
    const p = await connect(wes, `personal-${owner}`, phone)
    await hello(p)
    expect(p.frames[0].macs).toEqual([{ deviceId: mac, name: "Old Mac", online: false, lastSeenAt: null, ownerUserId: owner }])
    // And the phone can dial it once it connects.
    const m = await connect(wes, `personal-${owner}`, mac)
    p.send(offer(phone, mac))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    for (const s of [p, m]) s.ws.close()
  })

  it("account deletion closes every socket with 4002 and empties the hub", async () => {
    const xia = await token("xia")
    const phone = await register(xia, "phone", "personal-xia")
    const mac = await register(xia, "mac", "personal-xia")
    const p = await connect(xia, "personal-xia", phone)
    const codes: Array<number> = []
    p.ws.addEventListener("close", (e) => codes.push((e as CloseEvent).code))
    await hello(p)
    expect((await call("DELETE", "/v1/me", xia)).status).toBe(200)
    await p.until((s) => s.closed)
    expect(codes).toEqual([4002])
    expect(await hubOf("xia").macs("xia")).toEqual([])
    const res = await worker.fetch(`https://api.test/v1/teams/personal-xia/signal?deviceId=${mac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${xia}` } })
    expect(res.status).toBe(403)
  })
})

describe("migration from team hubs", () => {
  it("serving a team retires its old team hub: parked sockets are closed and its mixed rows deleted", async () => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const legacy = ns.get(ns.idFromName("team-legacy"))
    // A team hub as the old code left it: a teammate's Mac socket parked across the deploy, and its row.
    await runInDurableObject(legacy, (_hub, state) => {
      const pair = new WebSocketPair()
      state.acceptWebSocket(pair[1], ["11111111-1111-4111-8111-111111111111"])
      pair[1].serializeAttachment({ userId: "vic", projectId: DEV_PROJECT, deviceId: "11111111-1111-4111-8111-111111111111", kind: "mac", name: "Vic parked" })
      state.storage.sql.exec(`INSERT INTO macs (device_id, name, owner_user_id) VALUES ('11111111-1111-4111-8111-111111111111', 'Vic parked', 'vic')`)
    })
    const uma = await token("uma")
    expect((await call("GET", "/v1/teams/team-legacy/macs", uma)).json).toEqual({ macs: [] })
    const tables = async () =>
      runInDurableObject(legacy, (_hub, state) => ({
        macs: state.storage.sql.exec(`SELECT count(*) AS n FROM macs`).one().n as number,
        open: state.getWebSockets().filter((w) => !(w.deserializeAttachment() as { replaced?: boolean }).replaced).length
      }))
    const deadline = Date.now() + 3000
    let t = await tables()
    while ((t.macs || t.open) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50))
      t = await tables()
    }
    expect(t).toEqual({ macs: 0, open: 0 })
  })

  it("retiring twice on one live object works, and a team hub an older Worker bound to an owner is still retired", async () => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const legacy = ns.get(ns.idFromName("team-legacy-2"))
    const park = () =>
      runInDurableObject(legacy, (_hub, state) => {
        const pair = new WebSocketPair()
        state.acceptWebSocket(pair[1], ["22222222-2222-4222-8222-222222222222"])
        pair[1].serializeAttachment({ userId: "vic", projectId: DEV_PROJECT, deviceId: "22222222-2222-4222-8222-222222222222", kind: "mac", name: "Vic parked" })
        // What the previous Worker's slow path could leave during the deploy overlap: an owner in a team hub.
        state.storage.sql.exec(`INSERT INTO meta (key, value) VALUES ('owner', 'vic') ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        state.storage.sql.exec(`INSERT INTO macs (device_id, name, owner_user_id) VALUES ('22222222-2222-4222-8222-222222222222', 'Vic parked', 'vic') ON CONFLICT(device_id) DO NOTHING`)
      })
    await park()
    expect(await legacy.retireTeamHub()).toEqual({ closed: 1 })
    // Same live object again: the tables were recreated, so this neither throws nor skips a newly parked socket.
    await park()
    expect(await legacy.retireTeamHub()).toEqual({ closed: 1 })
    expect(await legacy.retireTeamHub()).toEqual({ closed: 0 })
  })

  it("a stale database read cannot seed back a Mac deleted from the hub", async () => {
    const yan = await token("yan")
    const mac = await register(yan, "mac", "personal-yan", "Gone")
    expect((await call("DELETE", `/v1/devices/${mac}`, yan)).status).toBe(200)
    // The slow path read the database before the deletion and seeds afterwards.
    await hubOf("yan").seed("yan", { userId: "yan", projectId: DEV_PROJECT }, [{ deviceId: mac, name: "Gone", teamId: "personal-yan", lastSeenAt: null }])
    expect((await hubOf("yan").macs("yan")).map((m) => m.deviceId)).not.toContain(mac)
    // Registering it again is a new registration: it is listed.
    expect((await call("POST", "/v1/devices", yan, { deviceId: mac, kind: "mac", name: "Back", teamId: "personal-yan" })).status).toBe(200)
    expect((await hubOf("yan").macs("yan")).map((m) => m.deviceId)).toContain(mac)
  })

  it("a device id deleted by one user and registered by another is admitted only for the new owner", async () => {
    const uma = await token("uma")
    const vic = await token("vic")
    const id = await register(uma, "phone", TEAM, "Uma old phone")
    const first = await connect(uma, TEAM, id)
    await hello(first)
    expect((await call("DELETE", `/v1/devices/${id}`, uma)).status).toBe(200)
    await first.until((s) => s.closed)
    expect((await call("POST", "/v1/devices", vic, { deviceId: id, kind: "phone", name: "Vic phone", teamId: TEAM })).status).toBe(200)
    const asUma = await worker.fetch(`https://api.test/v1/teams/${TEAM}/signal?deviceId=${id}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${uma}` } })
    expect(asUma.status).toBe(403)
    const v = await connect(vic, TEAM, id)
    await hello(v)
    expect(v.frames[0].macs.every((m: any) => m.ownerUserId === "vic")).toBe(true)
    v.ws.close()
  })

  it("a retire that failed (the hub was mid-deploy) is retried by a later request in the same isolate", async () => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const legacy = ns.get(ns.idFromName("team-legacy-3"))
    const parked = "33333333-3333-4333-8333-333333333333"
    await runInDurableObject(legacy, (hub, state) => {
      const pair = new WebSocketPair()
      state.acceptWebSocket(pair[1], [parked])
      pair[1].serializeAttachment({ userId: "vic", projectId: DEV_PROJECT, deviceId: parked, kind: "mac", name: "Vic parked" })
      // Shadowing the method makes the RPC fail with "The RPC receiver does not implement the method", what a
      // hub still running the previous deploy's class answers (seen on dev after the 0.10.0 deploy).
      ;(hub as unknown as { retireTeamHub: unknown }).retireTeamHub = undefined
    })
    const uma = await token("uma")
    const open = () => runInDurableObject(legacy, (_hub, state) => state.getWebSockets().filter((w) => !(w.deserializeAttachment() as { replaced?: boolean }).replaced).length)
    expect((await call("GET", "/v1/teams/team-legacy-3/macs", uma)).status).toBe(200)
    // Let that retire fail, then the hub "finishes restarting" onto the new class.
    await new Promise((r) => setTimeout(r, 200))
    await runInDurableObject(legacy, (hub) => {
      delete (hub as unknown as { retireTeamHub?: unknown }).retireTeamHub
    })
    const deadline = Date.now() + 3000
    while ((await open()) > 0 && Date.now() < deadline) {
      // The phone keeps polling, as the app does every 4 s while its Mac looks offline.
      await call("GET", "/v1/teams/team-legacy-3/macs", uma)
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(await open()).toBe(0)
  })

  it("a team hub still on the previous class (kept warm by traffic) has its parked sockets moved anyway", async () => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const legacy = ns.get(ns.idFromName("team-legacy-4"))
    const uma = await token("uma")
    const mac = await register(uma, "mac", "team-legacy-4", "Uma parked")
    const codes: Array<number> = []
    await runInDurableObject(legacy, (hub, state) => {
      const pair = new WebSocketPair()
      state.acceptWebSocket(pair[1], [mac])
      pair[1].serializeAttachment({ userId: "uma", projectId: DEV_PROJECT, deviceId: mac, kind: "mac", name: "Uma parked" })
      pair[0].accept()
      pair[0].addEventListener("close", (e) => codes.push((e as CloseEvent).code))
      // The previous class, as live after a deploy: no retireTeamHub, but its forgetMac (closes 4001 "moved").
      // RPC only reaches prototype methods, so forgetMac goes on the prototype (as the previous class has it).
      ;(hub as unknown as Record<string, unknown>).retireTeamHub = undefined
      ;(Object.getPrototypeOf(hub) as Record<string, unknown>).forgetMac = async function (this: { ctx: DurableObjectState }, deviceId: string) {
        for (const ws of this.ctx.getWebSockets(deviceId)) ws.close(4001, "moved")
      }
    })
    const open = () => runInDurableObject(legacy, (_hub, state) => state.getWebSockets().filter((w) => w.readyState === WebSocket.OPEN).length)
    const deadline = Date.now() + 3000
    do {
      expect((await call("GET", "/v1/me/macs", uma)).status).toBe(200)
      await new Promise((r) => setTimeout(r, 50))
    } while ((await open()) > 0 && Date.now() < deadline)
    await runInDurableObject(legacy, (hub) => {
      delete (Object.getPrototypeOf(hub) as Record<string, unknown>).forgetMac
      delete (hub as unknown as Record<string, unknown>).retireTeamHub
    })
    expect(await open()).toBe(0)
    expect(codes).toEqual([4001])
  })

  it("the cron sweep retires every team's old hub without any request, in both projects' naming", async () => {
    const ns = (env as unknown as { TEAM_HUB: DurableObjectNamespace<TeamHub> }).TEAM_HUB
    const parkIn = async (name: string, device: string) => {
      const stub = ns.get(ns.idFromName(name))
      await runInDurableObject(stub, (_hub, state) => {
        const pair = new WebSocketPair()
        state.acceptWebSocket(pair[1], [device])
        pair[1].serializeAttachment({ userId: "zed", projectId: DEV_PROJECT, deviceId: device, kind: "mac", name: "parked" })
      })
      return () => runInDurableObject(stub, (_hub, state) => state.getWebSockets().filter((w) => !(w.deserializeAttachment() as { replaced?: boolean }).replaced).length)
    }
    // A primary-project Mac in a Stack team and a non-primary one in a personal space, as the database has them.
    const dev = crypto.randomUUID()
    const prod = crypto.randomUUID()
    await memoryStore().upsertDevice({ deviceId: dev, ownerUserId: "zed", teamId: "team-sweep", kind: "mac", name: "Zed", wgPublicKey: null })
    await memoryStore().upsertDevice({ deviceId: prod, ownerUserId: `${PROD_PROJECT}:zed`, teamId: "personal-zed", kind: "mac", name: "Zed prod", wgPublicKey: null })
    const openDev = await parkIn("team-sweep", dev)
    const openProd = await parkIn(`${PROD_PROJECT}:personal-zed`, prod)
    const r = await retireAllTeamHubs(env as never)
    expect(r.failed).toBe(0)
    expect(r.closed).toBeGreaterThanOrEqual(2)
    expect([await openDev(), await openProd()]).toEqual([0, 0])
    // A second sweep finds nothing to do.
    expect((await retireAllTeamHubs(env as never)).closed).toBe(0)
  })

  it("never retires a user hub", async () => {
    const uma = await token("uma")
    const mac = await register(uma, "mac", "personal-uma", "Kept")
    expect(await hubOf("uma").retireTeamHub()).toEqual({ closed: 0 })
    expect((await hubOf("uma").macs("uma")).map((m) => m.deviceId)).toContain(mac)
  })
})
