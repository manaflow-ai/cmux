import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/**
 * Third review P2-1: with rows but no usable provider (an operator removed the key, prefix or image),
 * the alarm must not fire again at once forever. The sweep and the cancelled-create lookups need the
 * provider, so their past due times may not drive the wake while it is missing.
 */
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>

describe("CloudDO wake without a provider (P2-1)", () => {
  it("a team with rows and no provider schedules no immediate wake", async () => {
    const user = cloudTestUser(1)
    const team = personalTeamIdFor(user)
    const alice: Principal = { identity: `user:${user}`, user, team, kind: "session" }
    const stub = namespace.get(namespace.idFromName(team)) as any
    const r = await stub.submit(team, alice, { t: "op", op: "cloud.machine.create", params: { name: "box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(r.frames.some((f: { t: string }) => f.t === "result" || f.t === "reject")).toBe(true)
    await fireAlarm(stub)
    const { wake, now } = await runIn(stub, async (i) => {
      i.env = { ...i.env, CLOUD_DRIVER: undefined, CLOUD_NAME_PREFIX: undefined }
      // The last sweep was more than an hour ago: its next run is overdue.
      i.ctx.storage.sql.exec("UPDATE cloud_sweep SET at = ? WHERE id = 1", Date.now() - 3 * 3_600_000)
      const now = Date.now()
      return { wake: i.nextWakeAt(i.boundEngine.currentState, now) as number | null, now }
    })
    expect(wake === null || wake > now + 60_000).toBe(true)
  })
})
