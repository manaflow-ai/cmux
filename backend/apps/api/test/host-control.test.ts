import { runInDurableObject as runIn } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { HostDO } from "../src/host-do.ts"
import { COMPACT_EVENTS } from "../src/host-mirror.ts"
import { call, hostUser, installToken, op, openHost, roundTrip, testEnv } from "./host-control-support.ts"

/** HostDO control plane (b1-control-do.md sections 2 to 4): auth, hello, presence, mirrors, forwarding, hibernation. */

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const ws = (host: string) => `workspace:${host}`
const workspaceState = (host: string, name: string) => ({ host, workspaces: [{ id: "ws_main01", name, order: 0, panes: [] }] })

describe("HostDO control sockets", { timeout: 60_000 }, () => {
  it("refuses a missing token, another account and a host this user never enrolled", async () => {
    const u = await hostUser("ctl-auth")
    expect((await openHost(u.host, "")).status).toBe(401)
    const other = await hostUser("ctl-auth-other")
    const stranger = await openHost(u.host, other.phone.token)
    expect(stranger.status).toBe(403)
    expect(stranger.body).toContain("auth.forbidden")
    // Another team's id in the query: the stranger is no member there either.
    expect((await openHost(u.host, other.phone.token, `?team=${(await op(u.session, "user.ensure", {})).json.value.personal_team}`)).status).toBe(403)
    expect((await openHost("host_doesnotexist01", u.phone.token)).status).toBe(403)
  })

  it("negotiates hello, refuses frames before it and closes 4002 on a version mismatch", async () => {
    const u = await hostUser("ctl-hello")
    const phone = await openHost(u.host, u.phone.token)
    expect(phone.status).toBe(101)
    expect(await phone.next((f) => f.t === "welcome")).toMatchObject({ role: "device", streams: [`host:${u.host}`, ws(u.host), `task:${u.host}`] })
    phone.send({ t: "subscribe" })
    expect(await phone.next((f) => f.t === "error")).toMatchObject({ code: "proto.hello_required", retryable: false })
    const ok = await phone.hello()
    expect(ok).toMatchObject({ t: "hello.ok", proto: "cmux.mobile/1", version: 1, caps: ["read", "signal", "presence", "resume"], max_frame: 131072 })

    const old = await openHost(u.host, u.phone.token)
    const at = old.frames.length
    old.send({ t: "hello", proto: "cmux.mobile/1", min: 2, max: 3, caps: [], client: { install: "in_x", platform: "ios", app_version: "9" } })
    expect(await old.next((f) => f.t === "error", at)).toMatchObject({ code: "proto.version_unsupported", details: { min: 1, max: 1 } })
    expect(await old.closed).toBe(4002)
  })

  it("lets the Mac in as host and the owner's Stack session in as a device", async () => {
    const u = await hostUser("ctl-roles")
    const mac = await openHost(u.host, u.mac.token)
    expect(await mac.next((f) => f.t === "welcome")).toMatchObject({ role: "host" })
    const web = await openHost(u.host, u.session)
    expect(await web.next((f) => f.t === "welcome")).toMatchObject({ role: "device" })
  })

  it("tracks host and device presence on host:<host>", async () => {
    const u = await hostUser("ctl-presence")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    phone.send({ t: "subscribe", stream: `host:${u.host}` })
    const first = await phone.next((f) => f.t === "snapshot")
    expect(first.state).toMatchObject({ host: u.host, presence: "offline", viewers: 1, devices: [{ install: u.phone.install, platform: "ios", active: true }] })

    const mac = await openHost(u.host, u.mac.token)
    expect(await phone.next((f) => f.t === "event" && f.op === "host.presence.set" && f.params.presence === "online")).toMatchObject({ params: { viewers: 1 } })
    await mac.hello("mac")
    mac.send({ t: "op", op: "host.presence.set", params: { host: u.host, presence: "sleeping", at: 1 }, idempotency_key: "presence-1" })
    expect(await mac.next((f) => f.t === "request-settled")).toMatchObject({ ok: true, stream: `host:${u.host}` })
    expect(await phone.next((f) => f.t === "event" && f.params?.presence === "sleeping")).toBeTruthy()
    mac.send({ t: "op", op: "host.caps.set", params: { host: u.host, proto: { min: 1, max: 1 }, caps: ["terminal", "rpc"], cmux_version: "0.70.0" }, idempotency_key: "caps-0001" })
    expect(await phone.next((f) => f.t === "event" && f.op === "host.caps.set")).toMatchObject({ params: { caps: ["terminal", "rpc"] } })
    mac.send({ t: "op", op: "host.presence.set", params: { presence: "offline" }, idempotency_key: "presence-2" })
    expect(await mac.next((f) => f.t === "reject")).toMatchObject({ code: "validation.invalid" })

    phone.send({ t: "presence.set", state: { active: false, client: "ios" } })
    expect(await phone.next((f) => f.t === "event" && f.op === "host.presence.set" && f.params.viewers === 0)).toBeTruthy()

    const watcher = await openHost(u.host, u.session)
    await watcher.hello("web")
    watcher.send({ t: "subscribe", stream: `host:${u.host}` })
    await watcher.next((f) => f.t === "snapshot")
    phone.ws.close(1000)
    expect(await watcher.next((f) => f.t === "event" && f.op === "host.device.remove")).toMatchObject({ params: { install: u.phone.install } })
    mac.ws.close(1000)
    expect(await watcher.next((f) => f.t === "event" && f.params?.presence === "offline")).toBeTruthy()
  })

  it("mirrors the Mac's workspace stream, repairs gaps from a snapshot and resumes subscribers", async () => {
    const u = await hostUser("ctl-mirror")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    expect(await mac.next((f) => f.t === "snapshot.request" && f.stream === ws(u.host))).toBeTruthy()
    mac.send({ t: "snapshot", stream: ws(u.host), seq: 5, state: workspaceState(u.host, "five"), decided: [] })
    await roundTrip(mac)

    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    phone.send({ t: "subscribe", stream: ws(u.host) })
    expect(await phone.next((f) => f.t === "snapshot" && f.stream === ws(u.host))).toMatchObject({ seq: 5, state: { workspaces: [{ name: "five" }] } })

    const event = (seq: number) => ({ t: "event", stream: ws(u.host), seq, tx: `tx_${seq}`, op: "workspace.upsert", params: { workspace: { id: "ws_main01", name: `n${seq}`, order: 0, panes: [] } }, actor: { identity: u.mac.install }, origin: "user", at: seq })
    mac.send(event(6))
    expect(await phone.next((f) => f.t === "event" && f.seq === 6)).toMatchObject({ op: "workspace.upsert" })
    // A gap is never forwarded: the Mac is asked for a snapshot, which subscribers then get.
    const before = mac.frames.length
    mac.send(event(8))
    expect(await mac.next((f) => f.t === "snapshot.request" && f.stream === ws(u.host), before)).toBeTruthy()
    mac.send({ t: "snapshot", stream: ws(u.host), seq: 8, state: workspaceState(u.host, "eight"), decided: [] })
    expect(await phone.next((f) => f.t === "snapshot" && f.seq === 8)).toMatchObject({ state: { workspaces: [{ name: "eight" }] } })
    expect(phone.frames.some((f) => f.t === "event" && f.seq === 8)).toBe(false)
    mac.send(event(9))
    mac.send(event(10))
    await phone.next((f) => f.t === "event" && f.seq === 10)

    // Resume: a gap inside the tail replays events; an older cursor gets snapshot + tail.
    const again = await openHost(u.host, u.session)
    await again.hello("web", { resume: [{ stream: ws(u.host), seq: 9 }] })
    expect(await again.next((f) => f.t === "event" && f.stream === ws(u.host))).toMatchObject({ seq: 10 })
    expect(again.frames.some((f) => f.t === "snapshot" && f.stream === ws(u.host))).toBe(false)
    const at = again.frames.length
    again.send({ t: "subscribe", stream: ws(u.host), after_seq: 3 })
    expect(await again.next((f) => f.t === "snapshot", at)).toMatchObject({ seq: 8 })
    expect((await again.next((f) => f.t === "event" && f.seq === 10, at)).seq).toBe(10)
    // Another host's stream is refused.
    again.send({ t: "subscribe", stream: "workspace:host_other01" })
    expect(await again.next((f) => f.t === "error" && f.code === "auth.forbidden")).toBeTruthy()
  })

  it("asks the Mac for a compacting snapshot once the tail passes its bound", async () => {
    const u = await hostUser("ctl-compact")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    mac.send({ t: "snapshot", stream: ws(u.host), seq: 0, state: workspaceState(u.host, "zero"), decided: [] })
    const at = mac.frames.length
    for (let seq = 1; seq <= COMPACT_EVENTS; seq++) mac.send({ t: "event", stream: ws(u.host), seq, tx: `tx_${seq}`, op: "workspace.status.set", params: { tab: "tab_t01", status: "idle", unread: seq }, actor: {}, origin: "user", at: seq })
    expect(await mac.next((f) => f.t === "snapshot.request" && f.stream === ws(u.host), at)).toBeTruthy()
    // An event of another family on this stream is refused.
    mac.send({ t: "event", stream: ws(u.host), seq: COMPACT_EVENTS + 1, tx: "tx_x", op: "task.state.set", params: {}, actor: {}, origin: "user", at: 1 })
    expect(await mac.next((f) => f.t === "error" && f.code === "validation.invalid", at)).toBeTruthy()
  })

  it("forwards device ops and reads to the Mac with idempotency keys, and refuses while it is offline", async () => {
    const u = await hostUser("ctl-forward")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    const rename = { t: "op", op: "workspace.rename", params: { workspace: "ws_main01", name: "renamed" }, idempotency_key: "01JB7Q2W8M0000WSREN001", origin: "user", from: "in_spoofed" }
    phone.send(rename)
    expect(await phone.next((f) => f.t === "reject")).toMatchObject({ code: "owner.unreachable", retryable: true })
    expect(await phone.next((f) => f.t === "request-settled")).toMatchObject({ ok: false })
    phone.send({ t: "op", op: "workspace.upsert", params: {}, idempotency_key: "upsert-0001" })
    expect(await phone.next((f) => f.t === "reject" && f.idempotency_key === "upsert-0001")).toMatchObject({ code: "auth.forbidden" })
    phone.send({ t: "op", op: "workspace.create", params: { host: "host_someoneelse" }, idempotency_key: "create-0001" })
    expect(await phone.next((f) => f.t === "reject" && f.idempotency_key === "create-0001")).toMatchObject({ code: "validation.invalid" })

    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    const at = phone.frames.length
    phone.send(rename)
    const forwarded = await mac.next((f) => f.t === "op" && f.op === "workspace.rename")
    expect(forwarded).toMatchObject({ idempotency_key: rename.idempotency_key, from: u.phone.install, stream: ws(u.host), actor: { identity: u.phone.install, install: u.phone.install, user: u.user, kind: "install" } })
    mac.send({ t: "result", to: u.phone.install, tx: "tx_9", idempotency_key: rename.idempotency_key, value: null, revision: "9", replayed: false })
    mac.send({ t: "request-settled", to: u.phone.install, tx: "tx_9", idempotency_key: rename.idempotency_key, stream: ws(u.host), sequence: 9, ok: true })
    const result = await phone.next((f) => f.t === "result", at)
    expect(result).toEqual({ t: "result", tx: "tx_9", idempotency_key: rename.idempotency_key, value: null, revision: "9", replayed: false })
    await phone.next((f) => f.t === "request-settled", at)
    // After settle, a stray answer for that key is not delivered.
    mac.send({ t: "result", to: u.phone.install, tx: "tx_9", idempotency_key: rename.idempotency_key, value: "late", revision: "9", replayed: true })
    await roundTrip(mac)
    await roundTrip(phone)
    expect(phone.frames.filter((f) => f.t === "result" && f.value === "late")).toHaveLength(0)

    phone.send({ t: "read", id: 7, op: "task.list", params: { host: u.host } })
    const read = await mac.next((f) => f.t === "read" && f.op === "task.list")
    expect(read.from).toBe(u.phone.install)
    mac.send({ t: "read.result", id: read.id, value: { tasks: [] }, revision: "3" })
    expect(await phone.next((f) => f.t === "read.result")).toEqual({ t: "read.result", id: 7, value: { tasks: [] }, revision: "3" })

    // An op in flight when the Mac goes away: outcome unknown, the device keeps the intent.
    phone.send({ t: "op", op: "workspace.tab.close", params: { tab: "tab_t01" }, idempotency_key: "close-0001" })
    await mac.next((f) => f.t === "op" && f.idempotency_key === "close-0001")
    mac.ws.close(1000)
    expect(await phone.next((f) => f.t === "error" && f.idempotency_key === "close-0001")).toMatchObject({ code: "owner.unreachable", retryable: true })
  })

  it("serves mirrors and routes Mac answers after the object restarts (hibernation)", async () => {
    const u = await hostUser("ctl-hibernate")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    mac.send({ t: "snapshot", stream: ws(u.host), seq: 2, state: workspaceState(u.host, "two"), decided: [] })
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    phone.send({ t: "op", op: "workspace.rename", params: { workspace: "ws_main01", name: "x" }, idempotency_key: "hib-rename-1" })
    await mac.next((f) => f.t === "op" && f.idempotency_key === "hib-rename-1")

    const stub = testEnv.HOST_DO.get(testEnv.HOST_DO.idFromName(u.host))
    await runInDurableObject(stub, async (_instance, state) => {
      // A fresh instance over the same storage and sockets: memory is empty, as after eviction.
      const fresh = new HostDO(state, testEnv as never)
      const [macWs] = state.getWebSockets("ctl:host")
      const [phoneWs] = state.getWebSockets(`ctl:dev:${u.phone.install}`)
      await fresh.webSocketMessage(macWs!, JSON.stringify({ t: "result", to: u.phone.install, tx: "tx_3", idempotency_key: "hib-rename-1", value: null, revision: "3", replayed: false }))
      await fresh.webSocketMessage(phoneWs!, JSON.stringify({ t: "subscribe", stream: ws(u.host) }))
    })
    expect(await phone.next((f) => f.t === "result" && f.idempotency_key === "hib-rename-1")).toMatchObject({ revision: "3" })
    expect(await phone.next((f) => f.t === "snapshot" && f.stream === ws(u.host))).toMatchObject({ seq: 2, state: { workspaces: [{ name: "two" }] } })
  })

  it("closes a revoked install's control socket at once", async () => {
    const u = await hostUser("ctl-revoke")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    const revoke = await op(u.session, "install.revoke", { install: u.phone.install })
    expect(revoke.json.ok).toBe(true)
    expect(await phone.closed).toBe(4401)
  })

  it("answers signal.turn_credentials with a typed error when TURN is not configured", async () => {
    const u = await hostUser("ctl-turn")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    phone.send({ t: "read", id: 1, op: "signal.turn_credentials", params: { host: u.host } })
    expect(await phone.next((f) => f.t === "error" && f.id === 1)).toMatchObject({ code: "signal.turn_unavailable", retryable: false })
    const r = await call("/v1/realtime/turn", u.phone.token, { host: u.host })
    expect(r.status).toBe(503)
    expect(r.json.error.code).toBe("signal.turn_unavailable")
    expect((await call("/v1/realtime/turn", undefined, {})).status).toBe(401)
  })

  it("admits a second install of the same user as a device, never as the host", async () => {
    const u = await hostUser("ctl-second")
    const laptop = await installToken(u.session, u.user, "cli", "macos")
    const s = await openHost(u.host, laptop.token)
    expect(await s.next((f) => f.t === "welcome")).toMatchObject({ role: "device" })
  })
})
