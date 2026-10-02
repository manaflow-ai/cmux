import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain, EventFrame, OwnerFrame, Principal, ResultFrame } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** Records the price it was told: the owner looks the price up, the client never sends it. */
const shop: Domain<{ bought: Array<{ item: string; price: number; origin: string }> }> = {
  initial: () => ({ bought: [] }),
  reduce: (s, op, params, ctx) => {
    const p = params as { item?: string; resolved?: { price: number } | null }
    if (op !== "buy" || !p.item) return { ok: false, code: "validation.invalid", message: op }
    if (!p.resolved) return { ok: false, code: "selector.not_found", message: "no price" }
    const row = { item: p.item, price: p.resolved.price, origin: ctx.origin }
    return { ok: true, state: { bought: [...s.bought, row] }, value: row }
  }
}
const alice: Principal = { identity: "alice" }

describe("owner-resolved inputs (SubmitOptions.resolved)", () => {
  const setup = () => {
    const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), shop, { stream: "s" })
    const frames: Array<OwnerFrame> = []
    const buy = (key: string, params: Record<string, unknown>, resolved: unknown, origin: "cli" | "mcp" = "cli") => {
      frames.length = 0
      engine.submit(alice, { t: "op", op: "buy", params, idempotency_key: key, origin }, (_t, f) => frames.push(f), { resolved })
      return { result: frames.find((f) => f.t === "result" || f.t === "reject") as ResultFrame, event: frames.find((f): f is EventFrame => f.t === "event") }
    }
    return { engine, buy }
  }

  it("reaches the reducer and the event, and replaces a client-sent `resolved`", () => {
    const { buy } = setup()
    const r = buy("k1", { item: "pen", resolved: { price: 0 } }, { price: 3 }, "mcp")
    expect(r.result.value).toEqual({ item: "pen", price: 3, origin: "mcp" })
    // The event carries the input, so mirrors replay the same decision.
    expect(r.event?.params).toEqual({ item: "pen", resolved: { price: 3 } })
  })

  it("is not part of the idempotency hash: a retry whose lookup changed replays the first decision", () => {
    const { engine, buy } = setup()
    buy("k1", { item: "pen" }, { price: 3 })
    const retry = buy("k1", { item: "pen" }, { price: 5 })
    expect(retry.result.replayed).toBe(true)
    expect(retry.result.value).toEqual({ item: "pen", price: 3, origin: "cli" })
    expect(engine.currentState.bought).toHaveLength(1)
    // Different client params with the same key are still a conflict.
    expect((buy("k1", { item: "ink" }, { price: 3 }).result as unknown as { code: string }).code).toBe("idempotency.conflict")
  })

  it("null tells the reducer the lookup found nothing", () => {
    const { buy } = setup()
    expect((buy("k1", { item: "pen" }, null).result as unknown as { code: string }).code).toBe("selector.not_found")
  })
})
