import { describe, expect, it } from "vitest"
import { mux } from "../src/index.ts"

/** A channel Chief's wake queue takes wakes only from its channel (plans/cmux-next/chief-channels-DESIGN.md 1). */
const system = { identity: "system:test", kind: "system" } as const
const ctx = (n: number) => ({ now: 1_000 + n, tx: `tx${n}`, principal: system, idempotencyKey: `k${n}` }) as any
const run = (head: mux.MuxHead, op: string, params: Record<string, unknown>, n: number) => {
  const r = mux.muxDomain.reduce(head, op, params, ctx(n))
  if (!r.ok) throw new Error(`${op}: ${r.code}`)
  return r
}

describe("mux channel scope", () => {
  it("a channel-bound chief drops wakes from any other conversation", () => {
    const bound = run(mux.INITIAL_MUX_HEAD, "mux.bind", { agent: "agent_A", owner_user: "user_O", brain: "cloud", channel: "conv_CHAN" }, 1)
    expect(bound.state).toMatchObject({ agent: "agent_A", channel: "conv_CHAN" })
    const elsewhere = run(bound.state, "mux.wake", { conversation: "conv_OTHER", seq: 1, reason: "mention" }, 2)
    expect(elsewhere.value).toBeNull()
    expect((elsewhere as { changed?: boolean }).changed).toBe(false)
    expect(elsewhere.state.pending).toBe(0)
    const inside = run(bound.state, "mux.wake", { conversation: "conv_CHAN", seq: 1, reason: "mention" }, 3)
    expect(inside.value).toMatchObject({ conversation: "conv_CHAN", seq: 1 })
    expect(inside.state.pending).toBe(1)
  })

  it("an unscoped chief takes wakes from every conversation, and a bad scope is refused", () => {
    const bound = run(mux.INITIAL_MUX_HEAD, "mux.bind", { agent: "agent_B", owner_user: "user_O", brain: "cloud" }, 1)
    expect(bound.state.channel).toBeUndefined()
    expect(run(bound.state, "mux.wake", { conversation: "conv_ANY", seq: 1, reason: "dm" }, 2).value).not.toBeNull()
    const r = mux.muxDomain.reduce(mux.INITIAL_MUX_HEAD, "mux.bind", { agent: "agent_C", owner_user: "user_O", brain: "cloud", channel: 7 }, ctx(3))
    expect(r.ok).toBe(false)
  })
})
