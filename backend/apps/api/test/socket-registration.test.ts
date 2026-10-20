import { describe, expect, it } from "vitest"
import { SocketGate } from "../src/socket-gate.ts"

const A = "a".repeat(64), B = "b".repeat(64)
const principal = (install_authority: string) => ({ identity: "install", kind: "install" as const, user: "user", install: "install", grant: "grant", install_authority })
const socket = () => {
  let state = WebSocket.READY_STATE_OPEN
  const closes: number[] = []
  return { closes, ws: { get readyState() { return state }, close: (code: number) => { state = WebSocket.READY_STATE_CLOSED; closes.push(code) } } as unknown as WebSocket }
}
const deferred = () => {
  let resolve!: (ok: boolean) => void
  const promise = new Promise<boolean>((yes) => { resolve = yes })
  return { promise, resolve }
}
const gate = (register: () => Promise<boolean>) => new SocketGate({ waitUntil: () => {}, getWebSockets: () => [] } as never,
  { USER_DO: { idFromName: (user: string) => user, get: () => ({ registerSocket: register }) } } as never, () => true, () => {})

describe("owner registration fences frame admission", () => {
  it("a frame waits for the registration that refuses its stale incarnation", async () => {
    const held = deferred(), owner = gate(() => held.promise), p = principal(A), peer = socket()
    owner.seed(peer.ws, p, { cls: "CloudDO", name: "team" })
    const admitted = owner.frameAllowed(peer.ws, { principal: p, subscribed: false })
    expect(owner.live(peer.ws, { principal: p, subscribed: false })).toBe(false)
    held.resolve(false)
    expect(await admitted).toBe(false); expect(peer.closes).toEqual([4401])
  })

  it("unreachable registration cannot leave the connection authorized", async () => {
    const owner = gate(async () => { throw new Error("unavailable") }), p = principal(A), peer = socket()
    owner.seed(peer.ws, p, { cls: "CloudDO", name: "team" })
    expect(await owner.frameAllowed(peer.ws, { principal: p, subscribed: false })).toBe(false)
    expect(peer.closes).toEqual([4401])
  })

  it("refusing an older registration does not poison a fresh incarnation of the same install", async () => {
    const held = deferred(); let calls = 0
    const owner = gate(() => ++calls === 1 ? held.promise : Promise.resolve(true)), old = socket(), fresh = socket()
    owner.seed(old.ws, principal(A), { cls: "CloudDO", name: "team" })
    owner.seed(fresh.ws, principal(B), { cls: "CloudDO", name: "team" })
    expect(await owner.frameAllowed(fresh.ws, { principal: principal(B), subscribed: false })).toBe(true)
    held.resolve(false)
    expect(await owner.frameAllowed(old.ws, { principal: principal(A), subscribed: false })).toBe(false)
    expect(await owner.frameAllowed(fresh.ws, { principal: principal(B), subscribed: false })).toBe(true)
    expect(fresh.closes).toEqual([])
  })
})
