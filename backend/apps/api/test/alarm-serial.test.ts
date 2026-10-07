import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as Record<string, any>

// Miniflare fires real alarms while tests also call alarm() directly (fireAlarm in test/setup/alarm.ts).
// The runtime and a direct call enter through the same alarm(), so runs must queue, never overlap.
describe("OwnerDO alarm runs", () => {
  it("never overlap: a direct alarm() waits for the run in flight", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "alarm-serial-probe")
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    const peak = await runInDurableObject(stub, async (i) => {
      i.bind(user)
      let active = 0
      let max = 0
      i.onWake = async () => {
        active += 1
        max = Math.max(max, active)
        await new Promise((r) => setTimeout(r, 20))
        active -= 1
      }
      await Promise.all([i.alarm(), i.alarm(), i.alarm()])
      return max
    })
    expect(peak).toBe(1)
  })

  it("a failed run does not block the next one", async () => {
    const user = userIdFor(testEnv.STACK_PROJECT_ID, "alarm-serial-probe-2")
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    const runs = await runInDurableObject(stub, async (i) => {
      i.bind(user)
      let count = 0
      i.onWake = async () => {
        count += 1
        if (count === 1) throw new Error("first wake fails")
      }
      await Promise.all([i.alarm(), i.alarm()])
      await i.alarmIdle
      return count
    })
    expect(runs).toBe(2)
  })
})
