import { describe, expect, it } from "vitest"
import { post, sessionToken } from "./cloud-bind-support.ts"

// Cron triggers and op access through the API Worker (the SchedulerDO's input boundary).
const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const codeOf = (r: { body: any }) => r.body?.error?.code ?? r.body?.code
const steps = { type: "steps", steps: [{ type: "note", text: "hi" }] }
const signedIn = async (sub: string) => {
  const token = await sessionToken(sub)
  expect((await op(token, "user.ensure", {})).body.ok).toBe(true)
  return token
}

describe("automation triggers over the API (workerd)", () => {
  it("refuses a cron with a seconds field, an unknown zone, an expression that never fires and bad syntax", async () => {
    const token = await signedIn("sched-cron-refusals")
    for (const [expr, tz] of [["* * * * * *", "UTC"], ["* * * * *", "Mars/Olympus"], ["0 0 30 2 *", "UTC"], ["nope", "UTC"]] as const) {
      const r = await op(token, "automation.create", { name: "x", triggers: [{ type: "cron", expr, tz }], body: steps })
      expect([expr, tz, r.body.ok ?? false]).toEqual([expr, tz, false])
    }
    expect((await op(token, "automation.create", { name: "daily", triggers: [{ type: "cron", expr: "0 9 * * *", tz: "UTC" }], body: steps })).body.ok).toBe(true)
  })

  it("refuses a public call to an internal op", async () => {
    const token = await signedIn("sched-internal-op")
    const r = await op(token, "automation.fire", {})
    expect(r.status).toBe(400)
    expect(codeOf(r)).toBe("validation.invalid")
  })
})
