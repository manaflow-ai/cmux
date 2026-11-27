import { describe, expect, it } from "vitest"
import { uuidToBytes } from "../src/team-hub.ts"
import { call, connect, PROD_PROJECT, register, token, worker } from "./helpers.ts"

const offer = (from: string, to: string, sessionId = crypto.randomUUID()) => ({ type: "signal", to, from, sessionId, payload: { kind: "webrtc-offer", sdp: "v=0" } })

describe("TeamHub signaling", () => {
  it("refuses sockets without auth, membership or a registered own device", async () => {
    const alice = await token("alice")
    const mac = await register(alice, "mac", "team-a")
    const up = { Upgrade: "websocket" }
    expect((await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: up })).status).toBe(401)
    const asBob = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: { ...up, authorization: `Bearer ${await token("bob")}` } })
    expect(asBob.status).toBe(403)
    const asMallory = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${mac}`, { headers: { ...up, authorization: `Bearer ${await token("mallory")}` } })
    expect(asMallory.status).toBe(403)
    const unknown = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${crypto.randomUUID()}`, { headers: { ...up, authorization: `Bearer ${alice}` } })
    expect(unknown.status).toBe(403)
  })

  it("admits a device only in the team it is registered in, also after it moved", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a", "Alice iPhone")
    const up = { Upgrade: "websocket", authorization: `Bearer ${alice}` }
    const first = await connect(alice, "team-a", phone)
    first.ws.close()
    expect((await call("POST", "/v1/devices", alice, { deviceId: phone, kind: "phone", name: "Alice iPhone", teamId: "personal-alice" })).status).toBe(200)
    // The old team's hub forgot it; the database says it lives elsewhere now.
    const stale = await worker.fetch(`https://api.test/v1/teams/team-a/signal?deviceId=${phone}`, { headers: up })
    expect(stale.status).toBe(403)
    const moved = await connect(alice, "personal-alice", phone)
    moved.ws.close()
  })

  it("sends hello and broadcasts Mac presence on connect and disconnect", async () => {
    const team = "team-a"
    const alice = await token("alice")
    const phone = await register(alice, "phone", team)
    const mac = await register(alice, "mac", team, "Presence Mac")
    const p = await connect(alice, team, phone, true)
    await p.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(p.frames[0]).toMatchObject({ type: "hello", you: phone })
    expect(p.frames[0].macs.find((m: any) => m.deviceId === mac)).toMatchObject({ online: false })
    const m = await connect(alice, team, mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    expect(p.frames.find((f) => f.type === "presence")!.mac).toMatchObject({ deviceId: mac, name: "Presence Mac", online: true })
    const listed = await call("GET", `/v1/teams/${team}/macs`, alice)
    expect(listed.json.macs.find((x: any) => x.deviceId === mac)).toMatchObject({ online: true })
    m.ws.close(1000, "done")
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.online))
    expect(p.frames.filter((f) => f.type === "presence").at(-1)!.mac.lastSeenAt).toEqual(expect.any(String))
    p.ws.close()
  })

  it("forwards signals to an owned Mac, the reply direction, and refuses other owners", async () => {
    const team = "team-a"
    const alice = await token("alice")
    const bob = await token("bob")
    const phone = await register(alice, "phone", team)
    const mac = await register(alice, "mac", team)
    const bobPhone = await register(bob, "phone", team)
    const p = await connect(alice, team, phone)
    const m = await connect(alice, team, mac)
    const bp = await connect(bob, team, bobPhone)
    for (const s of [p, m, bp]) await s.until((x) => x.frames.some((f) => f.type === "hello"))

    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toEqual({ type: "signal", to: mac, from: phone, fromUserId: "alice", sessionId, payload: { kind: "webrtc-offer", sdp: "v=0" } })

    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "webrtc-answer", sdp: "v=0 answer" } })
    await p.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.find((f) => f.type === "signal")).toMatchObject({ from: mac, fromUserId: "alice", payload: { kind: "webrtc-answer" } })

    // Bob is in the team but does not own the Mac.
    bp.send(offer(bobPhone, mac))
    await bp.until((s) => s.frames.some((f) => f.type === "error"))
    expect(bp.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    // Bob cannot ride Alice's session either.
    bp.send({ ...offer(bobPhone, mac, sessionId) })
    await bp.until((s) => s.frames.filter((f) => f.type === "error").length >= 2)
    // The Mac cannot start a session to a phone.
    m.send(offer(mac, bobPhone))
    await m.until((s) => s.frames.some((f) => f.type === "error"))
    expect(m.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    // Spoofed `from` is refused.
    p.send(offer(bobPhone, mac))
    await p.until((s) => s.frames.some((f) => f.type === "error"))
    expect(p.frames.find((f) => f.type === "error")).toMatchObject({ code: "bad_request" })
    expect(m.frames.filter((f) => f.type === "signal")).toHaveLength(1)
    for (const s of [p, m, bp]) s.ws.close()
  })

  it("overwrites a client-supplied fromUserId with the verified sender", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m = await connect(alice, "team-a", mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))
    p.send({ ...offer(phone, mac), fromUserId: "mallory" })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal").fromUserId).toBe("alice")
    for (const s of [p, m]) s.ws.close()
  })

  it("personal space signals for its owner only", async () => {
    const solo = await token("solo")
    const team = "personal-solo"
    const phone = await register(solo, "phone", team)
    const mac = await register(solo, "mac", team)
    const p = await connect(solo, team, phone)
    const m = await connect(solo, team, mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    const sessionId = crypto.randomUUID()
    p.send(offer(phone, mac, sessionId))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toMatchObject({ from: phone, fromUserId: "solo" })
    const alicePhone = await register(await token("alice"), "phone", "team-a")
    const other = await worker.fetch(`https://api.test/v1/teams/${team}/signal?deviceId=${alicePhone}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${await token("alice")}` } })
    expect(other.status).toBe(403)
    for (const s of [p, m]) s.ws.close()
  })

  it("reports an offline Mac", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    p.send(offer(phone, mac))
    await p.until((s) => s.frames.some((f) => f.type === "error"))
    expect(p.frames.find((f) => f.type === "error")).toMatchObject({ code: "offline" })
    p.ws.close()
  })

  it("drops retired WireGuard relay frames with one relay_retired error per session, and keeps the socket", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m = await connect(alice, "team-a", mac)
    for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2" } })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))

    // An older phone's relay frames for an admitted session: none is forwarded.
    const frame = (to: string, sid = sessionId) => {
      const b = new Uint8Array(32 + 4)
      b.set(uuidToBytes(sid), 0)
      b.set(uuidToBytes(to), 16)
      b.set([1, 2, 3, 4], 32)
      return b
    }
    for (let i = 0; i < 10; i++) p.ws.send(frame(mac))
    const other = crypto.randomUUID()
    p.ws.send(frame(mac, other))
    await p.until((s) => s.frames.filter((f) => f.type === "error" && f.code === "relay_retired").length === 2)
    // Each error names its session (a sessionless error would fail the client's other dials).
    const errors = p.frames.filter((f) => f.type === "error" && f.code === "relay_retired")
    expect(errors.map((e) => e.sessionId).sort()).toEqual([sessionId, other].sort())
    // The socket still signals: a bad frame is answered, and the session's next signal reaches the Mac.
    p.send({ type: "nope" })
    await p.until((s) => s.frames.some((f) => f.type === "error" && f.code === "bad_request"))
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "bye", reason: "done" } })
    await m.until((s) => s.frames.filter((f) => f.type === "signal").length === 2)
    expect(m.binary).toHaveLength(0)
    expect(p.frames.filter((f) => f.type === "error" && f.code === "relay_retired")).toHaveLength(2)
    for (const s of [p, m]) s.ws.close()
  })

  it("forwards wg-endpoints, and names the session when it refuses an unknown kind", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m = await connect(alice, "team-a", mac)
    for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
    const sessionId = crypto.randomUUID()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2", version: 2 } })
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    const announcement = { kind: "wg-endpoints", generation: 1, endpoints: ["203.0.113.7:4000"], relayed: ["203.0.113.7:4000"], relayedTls: ["203.0.113.7:4000"] }
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: announcement })
    await m.until((s) => s.frames.filter((f) => f.type === "signal").length === 2)
    expect(m.frames.filter((f) => f.type === "signal")[1]).toMatchObject({ from: phone, sessionId, payload: announcement })
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: { kind: "wg-relay" } })
    await p.until((s) => s.frames.some((f) => f.type === "error" && f.code === "bad_request"))
    expect(p.frames.find((f) => f.type === "error" && f.code === "bad_request")).toMatchObject({ sessionId })
    for (const s of [p, m]) s.ws.close()
  })

  it("reports where a team's hub runs", async () => {
    const alice = await token("alice")
    const r = await call("GET", "/v1/teams/team-a/hub", alice)
    expect(r.status).toBe(200)
    expect(r.json).toHaveProperty("hubColo")
    expect(r.json).toHaveProperty("ingressColo")
    expect((await call("GET", "/v1/teams/team-a/hub", await token("mallory"))).status).toBe(403)
  })

  it("a reconnect replaces the old socket without an offline blip", async () => {
    const alice = await token("alice")
    const phone = await register(alice, "phone", "team-a")
    const mac = await register(alice, "mac", "team-a")
    const p = await connect(alice, "team-a", phone)
    const m1 = await connect(alice, "team-a", mac)
    await p.until((s) => s.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && f.mac.online))
    const m2 = await connect(alice, "team-a", mac)
    await m1.until((s) => s.closed)
    p.send(offer(phone, mac))
    await m2.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(p.frames.some((f) => f.type === "presence" && f.mac.deviceId === mac && !f.mac.online)).toBe(false)
    for (const s of [p, m2]) s.ws.close()
  })

  it("production users signal their own Macs; the same sub in dev cannot", async () => {
    const pat = await token("pat", { project: PROD_PROJECT })
    const phone = await register(pat, "phone", "team-p")
    const mac = await register(pat, "mac", "team-p")
    const p = await connect(pat, "team-p", phone, true)
    const m = await connect(pat, "team-p", mac)
    await m.until((s) => s.frames.some((f) => f.type === "hello"))
    p.send(offer(phone, mac))
    await m.until((s) => s.frames.some((f) => f.type === "signal"))
    expect(m.frames.find((f) => f.type === "signal")).toMatchObject({ from: phone, fromUserId: "pat" })

    // Dev alice and prod alice share a sub and the id personal-alice, not a space.
    const prodAlice = await token("alice", { project: PROD_PROJECT })
    const devAlice = await token("alice")
    const prodMac = await register(prodAlice, "mac", "personal-alice")
    const devPhone = await register(devAlice, "phone", "personal-alice")
    const pm = await connect(prodAlice, "personal-alice", prodMac)
    const dp = await connect(devAlice, "personal-alice", devPhone)
    await dp.until((s) => s.frames.some((f) => f.type === "hello"))
    expect(dp.frames[0].macs.map((x: any) => x.deviceId)).not.toContain(prodMac)
    dp.send(offer(devPhone, prodMac))
    await dp.until((s) => s.frames.some((f) => f.type === "error"))
    expect(dp.frames.find((f) => f.type === "error")).toMatchObject({ code: "not_owner" })
    expect(pm.frames.some((f) => f.type === "signal")).toBe(false)
    // Nor can the dev user open a socket as the prod device.
    const asDev = await worker.fetch(`https://api.test/v1/teams/personal-alice/signal?deviceId=${prodMac}`, { headers: { Upgrade: "websocket", authorization: `Bearer ${devAlice}` } })
    expect(asDev.status).toBe(403)
    for (const s of [p, m, pm, dp]) s.ws.close()
  })
})
