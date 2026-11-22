import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { quiesce } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/**
 * Coordinator decision: connect_info and link_token audit rows are kept 400 days (above the
 * 365-day policy floor), then pruned by the existing alarm pass in bounded batches.
 */
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const DAY = 86_400_000

describe("Cloud access audit retention (400 days)", () => {
  it("the alarm prunes rows older than 400 days in bounded batches, keeps newer ones, and schedules itself while old rows exist", async () => {
    const user = cloudTestUser(3)
    const team = personalTeamIdFor(user)
    const p: Principal = { identity: `user:${user}`, user, team, kind: "session" }
    const stub = namespace.get(namespace.idFromName(team)) as any
    // A machine row makes the object exist (bound) like a real team.
    await stub.submit(team, p, { t: "op", op: "cloud.machine.create", params: { name: "box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const result = await runIn(stub, async (i, state) => {
      await quiesce(i, state)
      const now = Date.now()
      for (let n = 0; n < 1200; n++) i.audit.record({ op: "connect_info", machine: "vm_x", at: now - 401 * DAY - n })
      i.audit.record({ op: "connect_info", machine: "vm_recent", at: now - 399 * DAY })
      const count = () => (state.storage.sql.exec("SELECT count(*) AS n FROM cloud_access_audit").toArray()[0] as { n: number }).n
      const wake = i.nextWakeAt(i.boundEngine.currentState, now) as number | null
      await i.alarm()
      const afterOne = count()
      await quiesce(i, state)
      for (let k = 0; k < 5; k++) await i.alarm()
      return { wake, now, afterOne, final: count(), recent: state.storage.sql.exec("SELECT count(*) AS n FROM cloud_access_audit WHERE entry LIKE '%vm_recent%'").toArray()[0] }
    })
    expect(result.wake).not.toBeNull()
    expect(result.wake!).toBeLessThanOrEqual(result.now + 1000)
    // Bounded: one pass does not delete all 1200 old rows.
    expect(result.afterOne).toBeGreaterThan(1)
    expect(result.afterOne).toBeLessThan(1201)
    expect(result.final).toBe(1)
    expect(result.recent).toEqual({ n: 1 })
  })
})
