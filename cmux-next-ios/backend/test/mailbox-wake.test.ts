import { describe, expect, it } from "vitest"
import { call, connect, register, token } from "./helpers.ts"

// PROTOCOL.md "Store and forward": the "Mac sleeps" gap, hub side. A phone posts a chat send while its Mac is
// offline; the Mac's signaling socket comes back. Measured per run: hello to the item on the Mac's socket, and
// hello to the phone reading `applied` after the Mac's ack (the Mac's own apply time is measured in
// cmux-mobile-host). Prints p50/p95 over RUNS; asserts only a generous bound, so a loaded runner never fails it.

const RUNS = 40
const SIG = "ab".repeat(64)
const pct = (xs: number[], p: number) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))]!

describe("store and forward: the Mac sleeps", () => {
  it(`delivers a held send on the Mac's wake and the phone reads applied (p50/p95 over ${RUNS} runs)`, async () => {
    const t = await token("wake")
    const mac = await register(t, "mac", "personal-wake")
    const phone = await register(t, "phone", "personal-wake")
    const toItem: number[] = []
    const toApplied: number[] = []
    for (let run = 0; run < RUNS; run++) {
      const id = crypto.randomUUID()
      expect((await call("POST", `/v1/devices/${mac}/mailbox`, t, { id, from: phone, sealed: "x".repeat(800), hold: 3600 })).json).toMatchObject({ delivered: false })
      const s = await connect(t, "personal-wake", mac)
      await s.until((x) => x.frames.some((f) => f.type === "hello"))
      const hello = performance.now()
      await s.until((x) => x.frames.some((f) => f.type === "mailbox"))
      toItem.push(performance.now() - hello)
      s.send({ type: "mailbox_ack", results: [{ id, applied: true, sig: SIG }] })
      for (;;) {
        const state = (await call("GET", `/v1/devices/${mac}/mailbox/${id}`, t)).json
        if (state.state === "applied") break
        await new Promise((r) => setTimeout(r, 2))
      }
      toApplied.push(performance.now() - hello)
      s.ws.close()
    }
    const line = (name: string, xs: number[]) => `${name}: p50 ${pct(xs, 50).toFixed(1)} ms, p95 ${pct(xs, 95).toFixed(1)} ms`
    console.log(`mailbox-wake (${RUNS} runs) ${line("hello -> item on Mac socket", toItem)}; ${line("hello -> phone reads applied", toApplied)}`)
    expect(pct(toApplied, 95)).toBeLessThan(5_000)
  }, 120_000)
})
