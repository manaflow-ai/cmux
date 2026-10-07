import { describe, expect, it } from "vitest"
import vectors from "../../../../cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json"
import { decodeFrame, encodeFrame, splitBatch, type FrameKind } from "../src/host-relay/frame.ts"
import { hexId, peerIdOf, route, type RelayView } from "../src/host-relay/route.ts"

const hex = (text: string): Uint8Array => Uint8Array.from(text.match(/../g) ?? [], (h) => Number.parseInt(h, 16))

interface Case {
  readonly name: string
  readonly valid: "yes" | "no"
  readonly hex: string
  readonly kind?: FrameKind
  readonly peer?: string
  readonly payload?: string
  readonly records?: string
  readonly error?: string
}
const cases = (vectors as { cases: ReadonlyArray<Case> }).cases

describe("relay frame (shared golden vectors with cmux-transport)", () => {
  it("decodes and re-encodes every valid vector byte for byte", () => {
    const valid = cases.filter((c) => c.valid === "yes")
    expect(valid.length).toBeGreaterThanOrEqual(3)
    for (const c of valid) {
      const decoded = decodeFrame(hex(c.hex))
      expect(decoded.ok, c.name).toBe(true)
      if (!decoded.ok) continue
      expect(decoded.frame.kind).toBe(c.kind)
      expect(hexId(decoded.frame.peer)).toBe(c.peer)
      expect(hexId(decoded.frame.payload)).toBe(c.payload)
      if (c.records !== undefined) {
        const records = splitBatch(decoded.frame.payload)
        expect(records).not.toBe("bad_batch")
        if (records !== "bad_batch") expect(records.map(hexId)).toEqual(c.records.split(","))
      }
      expect(hexId(encodeFrame(decoded.frame) as Uint8Array)).toBe(c.hex)
    }
  })

  it("refuses every invalid vector with the expected error, in the shared order", () => {
    const invalid = cases.filter((c) => c.valid === "no")
    expect(invalid.length).toBeGreaterThanOrEqual(3)
    for (const c of invalid) {
      const decoded = decodeFrame(hex(c.hex))
      expect(decoded.ok, c.name).toBe(false)
      if (!decoded.ok) expect(decoded.error, c.name).toBe(c.error)
    }
  })
})

describe("relay routing (transport.md 6 and 9.1)", () => {
  const host = hex("f0e1d2c3b4a5968778695a4b3c2d1e0f")
  const alice = "00112233445566778899aabbccddeeff"
  const mallory = "ffeeddccbbaa99887766554433221100"
  const frameFrom = (peer: string) => hex(`0101${peer}0020${"04000000" + "00".repeat(28)}`)
  const view = (over: Partial<RelayView> = {}): RelayView => ({
    hostPeer: host,
    hostConnected: true,
    connectedClients: new Set([alice, mallory]),
    reachable: new Set([alice]),
    ...over
  })

  it("forwards a client frame to the host with peer rewritten to the client's own id", () => {
    // Alice claims to be someone else; the relay overwrites the claim.
    const r = route(view(), { role: "client", peer: alice }, frameFrom(mallory))
    expect(r.forward).toBe(true)
    if (r.forward) {
      expect(r.to).toEqual({ role: "host" })
      expect(hexId(r.bytes.subarray(2, 18))).toBe(alice)
    }
  })

  it("refuses clients outside the host's reachability and while the host is offline", () => {
    expect(route(view(), { role: "client", peer: mallory }, frameFrom(mallory))).toEqual({ forward: false, reason: "not_reachable" })
    expect(route(view({ hostConnected: false }), { role: "client", peer: alice }, frameFrom(alice))).toEqual({ forward: false, reason: "host_offline" })
  })

  it("sends a host frame only to the named reachable, connected client, with peer set to the host", () => {
    const r = route(view(), { role: "host" }, frameFrom(alice))
    expect(r.forward).toBe(true)
    if (r.forward) {
      expect(r.to).toEqual({ role: "client", peer: alice })
      expect(hexId(r.bytes.subarray(2, 18))).toBe(hexId(host))
    }
    expect(route(view(), { role: "host" }, frameFrom(mallory))).toEqual({ forward: false, reason: "not_reachable" })
    expect(route(view({ connectedClients: new Set() }), { role: "host" }, frameFrom(alice))).toEqual({ forward: false, reason: "client_offline" })
  })

  it("drops malformed frames before any routing decision", () => {
    expect(route(view(), { role: "client", peer: alice }, hex("0101"))).toEqual({ forward: false, reason: "short" })
    expect(route(view(), { role: "client", peer: alice }, hex(`0101${alice}0010`))).toEqual({ forward: false, reason: "bad_batch" })
  })

  it("derives peer ids from public ids", async () => {
    const id = await peerIdOf("inst_00000000000000000009")
    expect(id).toMatch(/^[0-9a-f]{32}$/)
    expect(await peerIdOf("inst_00000000000000000009")).toBe(id)
  })
})
