import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { storeVmPlan } from "../src/cloud-vm-plan.ts"
import { storePlan } from "../src/inference/plan.ts"
import { inDO, post, testEnv, token } from "./setup/inference-person.ts"
import { call, mirroredTeam, teamStub } from "./team-stack-support.ts"

/**
 * Cloud machines follow the team's paid plan (plans/cmux-next/paid-product-DESIGN.md): with
 * CLOUD_PLAN_ENTITLEMENTS on, CloudDO reads the plan the model router already gates on
 * (TeamDO.inferencePlan, the sign-in service's cmuxPlan) and applies that plan's limits. These
 * teams are not on CLOUD_ALLOWED_TEAMS, so without the flag they have no plan at all.
 */

const cloud = env as unknown as { CLOUD_DO: DurableObjectNamespace }
const cloudStub = (team: string) => cloud.CLOUD_DO.get(cloud.CLOUD_DO.idFromName(team)) as unknown as { fakeControl(cmd: Record<string, unknown>): Promise<unknown> }

/** A signed-in person whose personal team's plan copy (TeamDO) is `plan` (null = free); entitlements on unless `entitlements` is false. */
const person = async (subject: string, plan: string | null, entitlements = true) => {
  const t = await token(subject)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (i) => {
    storePlan(i.ctx.storage.sql, plan, Date.now())
    storeVmPlan(i.ctx.storage.sql, null, Date.now())
  })
  await cloudStub(team).fakeControl({ entitlements: entitlements ? "on" : "off" })
  return { t, team }
}
const create = (t: string, size: { cpu: number; memory_mb: number; disk_mb: number }) =>
  post("/v1/ops", t, { op: "cloud.machine.create", params: { name: "paid box", size }, idempotency_key: crypto.randomUUID(), origin: "user" })
const planGet = (t: string) => post("/v1/read", t, { op: "cloud.plan.get", params: {} })
const SMALL = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
/** TeamDO's plan copy changes (web billing rewrote cmuxPlan), and CloudDO's own copy (ENTITLEMENT_FRESH_MS) ages out. */
const planChanges = async (team: string, plan: string | null) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (i) => storePlan(i.ctx.storage.sql, plan, Date.now()))
  await cloudStub(team).fakeControl({ advance_ms: 61_000 })
}

describe("Cloud plan entitlements", { timeout: 60_000 }, () => {
  it("a Pro team creates a 4 vCPU / 8 GB machine and cloud.plan.get names pro and its limits", async () => {
    const x = await person("cloud-ent-pro", "pro")
    const plan = await planGet(x.t)
    expect(plan.value).toMatchObject({ plan_id: "pro", upgrade_plan: "max", limits: { max_active: 5, memory_options_mb: [4096, 8192, 16384] } })
    const r = await create(x.t, { cpu: 4, memory_mb: 8192, disk_mb: 32768 })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    expect(r.value.machine.size).toMatchObject({ cpu: 4, memory_mb: 8192 })
  })

  it("a free team gets cloud.plan.required", async () => {
    const x = await person("cloud-ent-free", null)
    const r = await create(x.t, { cpu: 2, memory_mb: 4096, disk_mb: 16384 })
    expect(r.ok).toBe(false)
    expect(r.error?.code ?? r.code).toBe("cloud.plan.required")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "none" })
  })

  it("Max allows 16 vCPU / 32 GB; Pro refuses the same size with cloud.size.locked naming max", async () => {
    const max = await person("cloud-ent-max", "max")
    const big = { cpu: 16, memory_mb: 32768, disk_mb: 65536 }
    const ok = await create(max.t, big)
    expect(ok.ok, JSON.stringify(ok)).toBe(true)
    expect((await planGet(max.t)).value).toMatchObject({ plan_id: "max", upgrade_plan: null, limits: { max_active: 5 } })
    const pro = await person("cloud-ent-pro-big", "pro")
    const refused = await create(pro.t, big)
    expect(refused.ok).toBe(false)
    expect(refused.error?.code ?? refused.code).toBe("cloud.size.locked")
  })

  it("Plus (go) allows one machine at Pro sizes with no hour cap, as classic sells it", async () => {
    const x = await person("cloud-ent-go", "go")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "go", upgrade_plan: "pro", limits: { max_active: 1, memory_options_mb: [4096, 8192, 16384], vm_hours_included: null } })
    expect((await create(x.t, { cpu: 8, memory_mb: 16384, disk_mb: 65536 })).ok).toBe(true)
    const second = await create(x.t, { cpu: 2, memory_mb: 4096, disk_mb: 16384 })
    expect(second.error?.code ?? second.code).toBe("cloud.quota.exceeded")
  })

  it("with the flag off a paid team keeps today's behavior (no plan off the allowlist)", async () => {
    const x = await person("cloud-ent-off", "pro", false)
    const r = await create(x.t, { cpu: 2, memory_mb: 4096, disk_mb: 16384 })
    expect(r.error?.code ?? r.code).toBe("cloud.plan.required")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "none" })
  })

  it("a plan-service outage keeps the last known plan", async () => {
    const x = await person("cloud-ent-outage", "pro")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "pro" })
    // The TeamDO copy goes stale and Stack fails: TeamDO answers unavailable.
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(x.team)), async (i) => {
      i.ctx.storage.sql.exec(`UPDATE inference_plan SET checked_at = 0, failed_at = NULL WHERE id = 1`)
      i.stack = { getUserPlan: async () => { throw new Error("stack down") }, getTeam: async () => { throw new Error("stack down") } }
    })
    await cloudStub(x.team).fakeControl({ advance_ms: 10 * 60_000 })
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "pro" })
    const r = await create(x.t, { cpu: 4, memory_mb: 8192, disk_mb: 32768 })
    expect(r.ok, JSON.stringify(r)).toBe(true)
  })

  it("Founders gets Pro's limits", async () => {
    const x = await person("cloud-ent-founders", "founders")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "founders", upgrade_plan: "max", limits: { max_active: 5, max_saved: 20, memory_options_mb: [4096, 8192, 16384] } })
    expect((await create(x.t, { cpu: 8, memory_mb: 16384, disk_mb: 65536 })).ok).toBe(true)
  })

  it("a lapsed plan is dropped at the next read, unlike an outage", async () => {
    const x = await person("cloud-ent-lapse", "pro")
    expect((await create(x.t, SMALL)).ok).toBe(true)
    await planChanges(x.team, null)
    const r = await create(x.t, SMALL)
    expect(r.error?.code ?? r.code).toBe("cloud.plan.required")
    expect(r.error?.details).toMatchObject({ plan: "pro" })
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "none", usage: { active: 1 } })
  })

  it("a downgrade below the machines a team runs keeps them and refuses one more, naming the plan that lifts it", async () => {
    const x = await person("cloud-ent-downgrade", "pro")
    for (let i = 0; i < 2; i++) expect((await create(x.t, SMALL)).ok).toBe(true)
    await planChanges(x.team, "go")
    expect((await planGet(x.t)).value).toMatchObject({ plan_id: "go", limits: { max_active: 1 }, usage: { active: 2 } })
    const r = await create(x.t, SMALL)
    expect(r.error?.code ?? r.code).toBe("cloud.quota.exceeded")
    expect(r.error?.details).toMatchObject({ plan: "pro", limit: 1, used: 2 })
    const list = await post("/v1/read", x.t, { op: "cloud.machine.list", params: {} })
    expect(list.value.machines).toHaveLength(2)
  })

  it("a shared team uses the team's Team plan, not a member's personal plan", async () => {
    const t = await mirroredTeam("Cloud Paid Co")
    await cloudStub(t.team).fakeControl({ entitlements: "on" })
    const teamPlanGet = async () => (await call(t.token, "/v1/read", { op: "cloud.plan.get", params: {} }, t.team)).body
    // The member's personal plan does not reach the shared team.
    const ensured = (await call(t.token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(ensured.value.personal_team)), async (i) => storePlan(i.ctx.storage.sql, "max", Date.now()))
    await inDO(teamStub(t.team), async (i) => storeVmPlan(i.ctx.storage.sql, null, Date.now()))
    expect((await teamPlanGet()).value).toMatchObject({ plan_id: "none" })
    await inDO(teamStub(t.team), async (i) => storePlan(i.ctx.storage.sql, "team", Date.now()))
    await cloudStub(t.team).fakeControl({ advance_ms: 61_000 })
    expect((await teamPlanGet()).value).toMatchObject({ plan_id: "team", upgrade_plan: null, limits: { max_active: 5 } })
  })
})
