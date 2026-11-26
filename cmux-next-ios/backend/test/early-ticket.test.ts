import { describe, expect, it } from "vitest"
import { connect, register, token, worker, type Sock } from "./helpers.ts"

// PROTOCOL.md "Early relay ticket": a dialer with no path but the relay asks for its own ticket in its wg-init, so
// its relay join runs while the Mac gathers and answers. Old and new, both ways.

const pair = async () => {
  const tok = await token("alice")
  const phone = await register(tok, "phone", "team-a")
  const mac = await register(tok, "mac", "team-a")
  const p = await connect(tok, "team-a", phone)
  const m = await connect(tok, "team-a", mac)
  for (const s of [p, m]) await s.until((x) => x.frames.some((f) => f.type === "hello"))
  return { tok, phone, mac, p, m, sessionId: crypto.randomUUID() }
}

const init = (extra: Record<string, unknown> = {}) => ({ kind: "wg-init", publicKey: "k", endpoints: [], overlayIP: "10.77.0.2", relay: "now", ...extra })
const ofKind = (s: Sock, sessionId: string, kind: string) => s.frames.filter((f) => f.type === "signal" && f.sessionId === sessionId && f.payload?.kind === kind)

describe("early relay ticket", () => {
  it("new dialer, new hub: wg-ticket comes back at once with the dialer's own ticket, which joins before the Mac answers", async () => {
    const { tok, phone, mac, p, m, sessionId } = await pair()
    p.send({ type: "signal", to: mac, from: phone, sessionId, payload: init({ ticketEarly: true }) })
    await p.until((x) => ofKind(x, sessionId, "wg-ticket").length === 1)
    const [ticket] = ofKind(p, sessionId, "wg-ticket")
    expect(ticket.to).toBe(phone)
    expect(ticket.from).toBe(mac)
    expect(typeof ticket.relayTicket).toBe("string")
    // The Mac never sees it, and its own wg-init carries the Mac's ticket, not the phone's.
    await m.until((x) => ofKind(x, sessionId, "wg-init").length === 1)
    expect(ofKind(m, sessionId, "wg-ticket")).toEqual([])
    expect(ofKind(m, sessionId, "wg-init")[0].relayTicket).not.toBe(ticket.relayTicket)
    // The join needs nothing from the Mac.
    const res = await worker.fetch(`https://api.test/v1/relay/${sessionId}?deviceId=${phone}`, {
      headers: { Upgrade: "websocket", authorization: `Bearer ${tok}`, "x-cmux-relay-ticket": ticket.relayTicket },
    })
    expect(res.status).toBe(101)
    res.webSocket!.accept()
    res.webSocket!.close()
    // wg-resp later stamps the same ticket.
    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-resp", publicKey: "k", endpoints: [], overlayIP: "10.77.0.1" } })
    await p.until((x) => ofKind(x, sessionId, "wg-resp").length === 1)
    expect(ofKind(p, sessionId, "wg-resp")[0].relayTicket).toBe(ticket.relayTicket)
  })

  it("old dialer, new hub: a wg-init without ticketEarly (or with it false) gets no wg-ticket", async () => {
    for (const extra of [{}, { ticketEarly: false }, { ticketEarly: "yes" }]) {
      const { phone, mac, p, m, sessionId } = await pair()
      p.send({ type: "signal", to: mac, from: phone, sessionId, payload: init(extra) })
      await m.until((x) => ofKind(x, sessionId, "wg-init").length === 1)
      m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-resp", publicKey: "k", endpoints: [], overlayIP: "10.77.0.1" } })
      await p.until((x) => ofKind(x, sessionId, "wg-resp").length === 1)
      expect(ofKind(p, sessionId, "wg-ticket")).toEqual([])
    }
  })

  it("only the service sends wg-ticket: a client's is refused and never forwarded", async () => {
    const { phone, mac, p, m, sessionId } = await pair()
    m.send({ type: "signal", to: phone, from: mac, sessionId, payload: { kind: "wg-ticket" }, relayTicket: "forged" })
    await m.until((x) => x.frames.some((f) => f.type === "error" && f.code === "bad_request" && f.sessionId === sessionId))
    expect(ofKind(p, sessionId, "wg-ticket")).toEqual([])
  })
})
