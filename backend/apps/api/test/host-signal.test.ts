import { describe, expect, it } from "vitest"
import { SIGNAL_BURST, SIGNAL_WINDOW_MS, SignalBudget, signalBodyError } from "../src/host-signal.ts"
import { hostUser, installToken, openHost } from "./host-control-support.ts"

/** WebRTC signaling relay on HostDO (b1-control-do.md section 5): ephemeral, `from` rewritten, host <-> device only. */

const offer = (to: string, extra: Record<string, unknown> = {}) => ({ t: "signal", kind: "offer", session: "sess_abc123", to, body: { sdp: "v=0\r\n", carrier: "webrtc" }, ...extra })

describe("HostDO signal relay", { timeout: 60_000 }, () => {
  it("relays offer and answer between a device and its host and overwrites from", async () => {
    const u = await hostUser("sig-relay")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()

    phone.send(offer(u.host, { from: "in_spoofed" }))
    const got = await mac.next((f) => f.t === "signal" && f.kind === "offer")
    expect(got).toEqual({ t: "signal", kind: "offer", session: "sess_abc123", to: u.host, from: u.phone.install, body: { sdp: "v=0\r\n", carrier: "webrtc" } })
    // `to` may also name the host's install.
    phone.send({ t: "signal", kind: "ice", session: "sess_abc123", to: u.mac.install, body: { candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdp_mid: "0", sdp_mline_index: 0 } })
    expect(await mac.next((f) => f.t === "signal" && f.kind === "ice")).toMatchObject({ from: u.phone.install })

    mac.send({ t: "signal", kind: "answer", session: "sess_abc123", to: u.phone.install, from: "in_other", body: { sdp: "v=0\r\n" } })
    expect(await phone.next((f) => f.t === "signal" && f.kind === "answer")).toMatchObject({ from: u.mac.install, to: u.phone.install })
    mac.send({ t: "signal", kind: "bye", session: "sess_abc123", to: u.phone.install, body: { reason: "closed" } })
    expect(await phone.next((f) => f.t === "signal" && f.kind === "bye")).toMatchObject({ body: { reason: "closed" } })
  })

  it("refuses device-to-device signals, unknown peers and malformed bodies", async () => {
    const u = await hostUser("sig-scope")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    const ipad = await installToken(u.session, u.user, "ios", "ios")
    const tablet = await openHost(u.host, ipad.token)
    await tablet.hello("ipados")

    phone.send(offer(ipad.install))
    expect(await phone.next((f) => f.t === "error" && f.code === "auth.forbidden")).toBeTruthy()
    mac.send(offer("in_notattached01"))
    expect(await mac.next((f) => f.t === "error" && f.code === "signal.peer_offline")).toMatchObject({ retryable: true })
    phone.send({ t: "signal", kind: "offer", session: "sess_abc123", to: u.host, body: { sdp: "", private: 1 } })
    expect(await phone.next((f) => f.t === "error" && f.code === "validation.invalid")).toBeTruthy()
    phone.send({ t: "signal", kind: "offer", session: "not-a-session", to: u.host, body: { sdp: "x" } })
    expect(await phone.next((f) => f.t === "error" && f.message.includes("sess_"))).toBeTruthy()
    expect(tablet.frames.some((f) => f.t === "signal")).toBe(false)

    phone.send({ t: "subscribe", stream: `host:${u.host}` })
    await phone.next((f) => f.t === "snapshot")
    mac.ws.close(1000)
    await phone.next((f) => f.t === "event" && f.params?.presence === "offline")
    const at = phone.frames.length
    phone.send(offer(u.host))
    expect(await phone.next((f) => f.t === "error" && f.code === "signal.peer_offline", at)).toBeTruthy()
  })

  it("limits signals per socket", async () => {
    const u = await hostUser("sig-rate")
    const mac = await openHost(u.host, u.mac.token)
    await mac.hello("mac")
    const phone = await openHost(u.host, u.phone.token)
    await phone.hello()
    // Two bursts at once (under the gate's 256 queued frames): the refill cannot keep up even on a slow runner.
    for (let i = 0; i < SIGNAL_BURST * 2; i++) phone.send({ t: "signal", kind: "ice.end", session: "sess_abc123", to: u.host, body: {} })
    expect(await phone.next((f) => f.t === "error" && f.code === "signal.rate_limited")).toMatchObject({ retryable: true })
  })

  it("refills the per-socket budget over the window", () => {
    const budget = new SignalBudget()
    const sock = {} as WebSocket
    for (let i = 0; i < SIGNAL_BURST; i++) expect(budget.take(sock, 0)).toBe(true)
    expect(budget.take(sock, 0)).toBe(false)
    expect(budget.take(sock, SIGNAL_WINDOW_MS / SIGNAL_BURST)).toBe(true)
    expect(budget.take(sock, SIGNAL_WINDOW_MS / SIGNAL_BURST)).toBe(false)
  })

  it("checks bodies against the signal schema", () => {
    expect(signalBodyError("offer", { sdp: "x".repeat(65537) })?.code).toBe("validation.invalid")
    expect(signalBodyError("ice", { candidate: "c", sdp_mid: null, sdp_mline_index: null })).toBeUndefined()
    expect(signalBodyError("ice.end", { extra: true })?.code).toBe("validation.invalid")
    expect(signalBodyError("bye", { reason: "superseded" })).toBeUndefined()
    expect(signalBodyError("bye", { reason: "whatever" })?.code).toBe("validation.invalid")
  })
})
