import { describe, expect, it } from "vitest"
import { MAX_BATCH, MAX_BATCHED_PHONES, notifyLimitKey, notifyTargets, parseNotify } from "../src/push.ts"
import type { PushRegistration } from "../src/store.ts"

// The lead and batch fields of a notify (PROTOCOL.md "More than 20 phones: a lead and batches").

const SIG = "ab".repeat(64)
const box = (i: number) => `B${i}`.padEnd(400, "A")

describe("notify batch fields", () => {
  const PHONE = "33333333-3333-4333-8333-333333333333"
  const sealed = { [PHONE]: { box: box(0), sig: SIG } }
  const base = { eventId: "e-1", kind: "question" }

  it("parses a lead's batchedPhones and a batch's number", () => {
    expect(parseNotify({ ...base, sealed, batchedPhones: [PHONE.toUpperCase()] })).toMatchObject({ batchedPhones: [PHONE] })
    expect(parseNotify({ ...base, sealed, batch: 2 })).toMatchObject({ batch: 2 })
    expect(parseNotify({ ...base, sealed, batch: MAX_BATCH })).toMatchObject({ batch: MAX_BATCH })
    expect(parseNotify({ ...base, batchedPhones: Array.from({ length: MAX_BATCHED_PHONES }, () => PHONE) })).not.toBeTypeOf("string")
  })

  it("refuses a malformed batch field instead of dropping it (a dropped one would push twice)", () => {
    for (const bad of [
      { batch: 1 },
      { sealed, batch: 0 },
      { sealed, batch: 1.5 },
      { sealed, batch: "1" },
      { sealed, batch: MAX_BATCH + 1 },
      { sealed, batch: 1, batchedPhones: [PHONE] },
      { batchedPhones: ["not-a-phone"] },
      { batchedPhones: PHONE },
      { batchedPhones: Array.from({ length: MAX_BATCHED_PHONES + 1 }, () => PHONE) }
    ])
      expect(parseNotify({ ...base, ...bad })).toBeTypeOf("string")
  })

  it("splits targets so each phone is in exactly one request", () => {
    const reg = (deviceId: string) => ({ deviceId }) as PushRegistration
    const targets = ["a", "b", "c"].map((c) => reg(`${c.repeat(8)}-0000-4000-8000-000000000000`))
    const [a, b, c] = targets.map((r) => r.deviceId)
    const s = (ids: Array<string>) => Object.fromEntries(ids.map((id) => [id, { box: "x", sig: SIG }]))
    expect(notifyTargets(targets, {}).length).toBe(3)
    expect(notifyTargets(targets, { sealed: s([a!]), batchedPhones: [b!] }).map((r) => r.deviceId)).toEqual([a, c])
    expect(notifyTargets(targets, { sealed: s([b!]), batch: 1 }).map((r) => r.deviceId)).toEqual([b])
  })

  it("gives each batch its own rate bucket", () => {
    expect(notifyLimitKey("m", "question")).toBe("m")
    expect(notifyLimitKey("m", "question", 2)).toBe("m:batch:2")
    expect(notifyLimitKey("m", "terminal", 1)).toBe("m:terminal:batch:1")
  })
})
