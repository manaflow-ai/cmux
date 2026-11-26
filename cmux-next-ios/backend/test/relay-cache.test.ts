import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import type { LinkRelay } from "../src/link-relay.ts"
import { DELTA_TTL_MS, HEADER_LEN, peek, RelayCache, SNAPSHOT_TTL_MS } from "../src/relay-cache.ts"
import { register, token, worker } from "./helpers.ts"

// RFD 0142 R2 and R9, PROTOCOL.md "Relay snapshot seal" and "Relay delta catch-up": a source Mac puts sealed
// snapshots and deltas for one of the owner's viewers; the viewer reads its snapshot and catches up after the
// position it holds, with the Mac away. Off unless LINK_RELAY_CACHE=on.

/** A `cmux-relay-snapshot-v1` envelope that passes `peek` (the relay never opens one, so the bytes are filler). */
const envelope = (epoch: number, seq: number, key = 7, ct = 32): Uint8Array => {
  const out = new Uint8Array(HEADER_LEN + 4 + ct + 64)
  const v = new DataView(out.buffer)
  out[0] = 1
  v.setBigUint64(1, BigInt(epoch))
  v.setBigUint64(9, BigInt(seq))
  out.fill(key, 17, 49)
  out[49] = 4
  v.setUint32(HEADER_LEN, ct)
  out.fill(0xab, HEADER_LEN + 4, HEADER_LEN + 4 + ct)
  return out
}

const vars = env as unknown as { LINK_RELAY_CACHE?: string }
const withCache = async (fn: () => Promise<void>) => {
  vars.LINK_RELAY_CACHE = "on"
  try {
    await fn()
  } finally {
    delete vars.LINK_RELAY_CACHE
  }
}

const devices = async (user = "alice") => {
  const tok = await token(user)
  const phone = await register(tok, "phone", "team-a")
  const mac = await register(tok, "mac", "team-a")
  return { tok, phone, mac }
}
const at = (tok: string, method: string, path: string, body?: BodyInit, type?: string) =>
  worker.fetch(`https://api.test${path}`, { method, body, headers: { authorization: `Bearer ${tok}`, ...(type ? { "content-type": type } : {}) } })
const put = (tok: string, mac: string, phone: string, what: "snapshot" | "delta", stream: string, env: Uint8Array) =>
  at(tok, what === "snapshot" ? "PUT" : "POST", `/v1/relay-cache/${mac}/${what}?deviceId=${mac}&viewer=${phone}&stream=${stream}`, env, "application/octet-stream")
const catchUp = (tok: string, mac: string, phone: string, surfaces: { surface: string; after: { epoch: number; seq: number } }[], budgetBytes?: number) =>
  at(tok, "POST", `/v1/relay-cache/${mac}/catch-up?deviceId=${phone}`, JSON.stringify({ surfaces, budgetBytes }), "application/json")

describe("relay cache (R2, R9)", () => {
  it("is off by default", async () => {
    const { tok, phone, mac } = await devices()
    const res = await put(tok, mac, phone, "snapshot", "s1", envelope(1, 1))
    expect(res.status).toBe(503)
    expect(((await res.json()) as any).error.code).toBe("relay_cache_off")
  })

  it("serves the newest sealed snapshot to its viewer only, written only by the source", async () =>
    withCache(async () => {
      const { tok, phone, mac } = await devices()
      expect((await put(tok, mac, phone, "snapshot", "s1", envelope(1, 5))).status).toBe(200)
      expect(((await (await put(tok, mac, phone, "snapshot", "s1", envelope(1, 4))).json()) as any).outcome).toBe("stale")
      expect(((await (await put(tok, mac, phone, "snapshot", "s1", envelope(1, 6))).json()) as any).outcome).toBe("stored")
      const t0 = Date.now()
      const got = await at(tok, "GET", `/v1/relay-cache/${mac}/snapshot?deviceId=${phone}&stream=s1`)
      const ms = Date.now() - t0
      expect(got.status).toBe(200)
      expect(peek(new Uint8Array(await got.arrayBuffer()))?.position).toEqual({ epoch: 1n, seq: 6n })
      // Another of the owner's phones holds nothing (each snapshot is sealed to one viewer).
      const other = await register(tok, "phone", "team-a")
      expect((await at(tok, "GET", `/v1/relay-cache/${mac}/snapshot?deviceId=${other}&stream=s1`)).status).toBe(404)
      // Only the source writes; another user cannot read; malformed bytes are refused.
      expect((await at(tok, "PUT", `/v1/relay-cache/${mac}/snapshot?deviceId=${phone}&viewer=${phone}&stream=s1`, envelope(1, 9))).status).toBe(403)
      const bob = await token("bob")
      expect((await at(bob, "GET", `/v1/relay-cache/${mac}/snapshot?deviceId=${phone}&stream=s1`)).status).toBe(403)
      expect((await put(tok, mac, phone, "snapshot", "s1", new Uint8Array(40))).status).toBe(400)
      console.log(JSON.stringify({ row: "relay-cache snapshot read (miniflare, idle)", ms }))
    }))

  it("catches up contiguously, reports a gap or a restart as cut, and cuts whole surfaces past the budget", async () =>
    withCache(async () => {
      const { tok, phone, mac } = await devices()
      for (let seq = 1; seq <= 4; seq++) expect((await put(tok, mac, phone, "delta", "a", envelope(1, seq))).status).toBe(200)
      expect((await put(tok, mac, phone, "delta", encodeURIComponent("t1/delta"), envelope(1, 1))).status).toBe(200)
      // A retry is a duplicate; a hole restarts the log at the new delta.
      expect(((await (await put(tok, mac, phone, "delta", "a", envelope(1, 3))).json()) as any).outcome).toBe("duplicate")
      for (let seq = 1; seq <= 2; seq++) await put(tok, mac, phone, "delta", "b", envelope(1, seq))
      expect(((await (await put(tok, mac, phone, "delta", "b", envelope(1, 9))).json()) as any).outcome).toBe("restarted")
      const reply = (await (await catchUp(tok, mac, phone, [
        { surface: "a", after: { epoch: 1, seq: 1 } },
        { surface: "b", after: { epoch: 1, seq: 1 } },
        { surface: "none", after: { epoch: 1, seq: 0 } },
      ])).json()) as any
      expect(reply.fromRelay).toBe(true)
      expect(reply.surfaces).toHaveLength(1)
      expect(reply.surfaces[0]).toMatchObject({ surface: "a", head: { epoch: 1, seq: 4 } })
      expect(reply.surfaces[0].sealed).toHaveLength(3)
      expect(reply.cut).toEqual(["b", "none"])
      // At the head: nothing to send, not a gap. Another epoch: a gap.
      const same = (await (await catchUp(tok, mac, phone, [{ surface: "a", after: { epoch: 1, seq: 4 } }, { surface: "b", after: { epoch: 2, seq: 1 } }])).json()) as any
      expect(same.surfaces).toEqual([{ surface: "a", sealed: [], head: { epoch: 1, seq: 4 } }])
      expect(same.cut).toEqual(["b"])
      // A budget smaller than surface a's three deltas cuts a whole, never part of it.
      const small = (await (await catchUp(tok, mac, phone, [{ surface: "a", after: { epoch: 1, seq: 1 } }], 300)).json()) as any
      expect(small).toEqual({ fromRelay: true, surfaces: [], cut: ["a"] })
      // The viewer's ack drains what it applied; a later catch-up from there still works.
      const ack = await at(tok, "POST", `/v1/relay-cache/${mac}/ack?deviceId=${phone}&stream=a`, JSON.stringify({ through: { epoch: 1, seq: 3 } }), "application/json")
      expect(((await ack.json()) as any).drained).toBe(3)
      const tail = (await (await catchUp(tok, mac, phone, [{ surface: "a", after: { epoch: 1, seq: 3 } }])).json()) as any
      expect(tail.surfaces[0].sealed).toHaveLength(1)
    }))

  it("expires deltas after 10 minutes and snapshots after a day, and frees the slot", async () => {
    const stub = (env as unknown as Env).LINK_RELAY.get((env as unknown as Env).LINK_RELAY.idFromName(`relay-cache-test-${crypto.randomUUID()}`))
    await runInDurableObject(stub as unknown as DurableObjectStub<LinkRelay>, async (_o, state) => {
      const cache = new RelayCache(state.storage)
      const t = 1_000_000
      await cache.putSnapshot("v", "s", envelope(1, 1), t)
      await cache.appendDelta("v", "s", envelope(1, 1), t)
      await cache.appendDelta("v", "s", envelope(1, 2), t + DELTA_TTL_MS / 2)
      expect(await cache.catchUp("v", "s", { epoch: 1n, seq: 0n }, t + DELTA_TTL_MS - 1)).toMatchObject({ type: "deltas" })
      // The first delta expired: a catch-up from before it is a gap, from after it still works.
      expect(await cache.catchUp("v", "s", { epoch: 1n, seq: 0n }, t + DELTA_TTL_MS)).toEqual({ type: "gap" })
      expect(await cache.purge(t + DELTA_TTL_MS)).toBe(t + DELTA_TTL_MS / 2 + DELTA_TTL_MS)
      expect(await cache.snapshot("v", "s", t + SNAPSHOT_TTL_MS - 1)).not.toBeNull()
      expect(await cache.purge(t + SNAPSHOT_TTL_MS)).toBeUndefined()
      expect(await cache.snapshot("v", "s", t + SNAPSHOT_TTL_MS)).toBeNull()
      expect(await state.storage.get("cacheslots")).toEqual([])
    })
  })
})
