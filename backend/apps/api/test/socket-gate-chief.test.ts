import { describe, expect, it } from "vitest"
import { SocketGate } from "../src/socket-gate.ts"

/**
 * The per-frame chief check never depends on install_kind (fail closed): a socket principal that
 * holds a chief token with mutate-shared is checked on every mutating frame even when a future path
 * leaves install_kind out. Review P3, backend lead.
 */
describe("SocketGate placed-chief check", () => {
  const principal = { identity: "install:inst_x", kind: "install" as const, user: "user_1", install: "inst_abcdefghij0123456789", grant: "grant_1", agent: "agent_0123456789ABCDEFGHJKMNPQRS", grant_classes: ["read", "mutate-own", "mutate-shared"] }
  const frame = JSON.stringify({ t: "op", op: "message.send", params: {}, idempotency_key: "k1" })

  const gate = (answer: { ok: boolean; op_classes?: Array<string> }) => {
    let asked = 0
    const env = { USER_DO: { idFromName: (n: string) => n, get: () => ({ installGrant: async () => (asked++, answer) }) } }
    const ctx = { waitUntil: () => {}, getWebSockets: () => [] }
    return { gate: new SocketGate(ctx as never, env as never, () => true, () => {}), asked: () => asked }
  }
  const socket = () => {
    const sent: Array<string> = []
    let closed: number | undefined
    return { ws: { send: (s: string) => sent.push(s), close: (code: number) => (closed = code) } as unknown as WebSocket, sent, closed: () => closed }
  }

  it("checks a chief token without install_kind and refuses when the chief rights are gone", async () => {
    const g = gate({ ok: true, op_classes: ["read", "mutate-own"] })
    const s = socket()
    expect(await g.gate.chiefFrameAllowed(s.ws, { principal, subscribed: false } as never, frame)).toBe(false)
    expect(g.asked()).toBe(1)
    expect(s.closed()).toBe(4401)
    expect(s.sent.some((m) => JSON.parse(m).code === "auth.forbidden")).toBe(true)
  })

  it("lets a confirmed chief frame through and never asks for a read frame", async () => {
    const g = gate({ ok: true, op_classes: ["read", "mutate-own", "mutate-shared"] })
    const s = socket()
    expect(await g.gate.chiefFrameAllowed(s.ws, { principal, subscribed: false } as never, frame)).toBe(true)
    expect(await g.gate.chiefFrameAllowed(s.ws, { principal, subscribed: false } as never, JSON.stringify({ t: "op", op: "conversation.snapshot", params: {} }))).toBe(true)
    expect(g.asked()).toBe(1)
  })
})
