import { env } from "cloudflare:workers"
import type { Principal } from "@cmux/ownership"
import { CloudPlan, cloudEntryPlan } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import { planView, STUB_PLAN } from "../src/domains/cloud-plan.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/**
 * The Cloud page shows "See plans" for every limit: CloudPlan names the plan to upgrade to
 * (upgrade_plan), and cloud.quota.exceeded / cloud.size.locked carry `plan`, the plan that would
 * lift the limit. CLOUD-LINK-FOLLOWUPS (3): the stub plan and no plan both name the catalog entry plan.
 */
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }

describe("Cloud upgrade plan (See plans)", () => {
  it("planView carries upgrade_plan, and the CloudPlan schema requires it", () => {
    const stub = planView(STUB_PLAN, { active: 0, saved: 0 }, Date.now())
    expect(stub).toMatchObject({ plan_id: "stub_default", upgrade_plan: cloudEntryPlan() })
    expect(planView({ ...STUB_PLAN, upgrade_plan: "pro" }, { active: 0, saved: 0 }, Date.now())).toMatchObject({ upgrade_plan: "pro" })
    expect(planView(null, { active: 0, saved: 0 }, Date.now())).toMatchObject({ plan_id: "none", upgrade_plan: cloudEntryPlan() })
    expect(Exit.isSuccess(Schema.decodeUnknownExit(CloudPlan)(stub))).toBe(true)
    const { upgrade_plan: _drop, ...without } = stub as Record<string, unknown>
    expect(Exit.isSuccess(Schema.decodeUnknownExit(CloudPlan)(without))).toBe(false)
  })

  it("quota and size refusals name the plan that would lift the limit (the entry plan on the stub plan)", async () => {
    const user = cloudTestUser(2)
    const team = personalTeamIdFor(user)
    const p: Principal = { identity: `user:${user}`, user, team, kind: "session" }
    const stub = namespace.get(namespace.idFromName(team)) as any
    const send = async (params: unknown) => {
      const r = await stub.submit(team, p, { t: "op", op: "cloud.machine.create", params, idempotency_key: crypto.randomUUID(), origin: "user" })
      return r.frames.find((f: { t: string }) => f.t === "result" || f.t === "reject")
    }
    const locked = await send({ name: "big", size: { ...SIZE, cpu: 64 } })
    expect(locked).toMatchObject({ t: "reject", code: "cloud.size.locked" })
    expect(locked.details).toHaveProperty("plan", cloudEntryPlan())
    for (let i = 0; i < STUB_PLAN.max_active; i++) expect(await send({ name: `b${i}`, size: SIZE })).toMatchObject({ t: "result" })
    const quota = await send({ name: "one more", size: SIZE })
    expect(quota).toMatchObject({ t: "reject", code: "cloud.quota.exceeded", details: { limit: STUB_PLAN.max_active, resource: "active" } })
    expect(quota.details).toHaveProperty("plan", cloudEntryPlan())
  })
})
