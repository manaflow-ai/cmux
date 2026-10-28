import { env } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
// @ts-expect-error a Vite raw import of web's company domain list (the test runner bundles it; the Worker build never sees it)
import webAccessText from "../../../../web/services/admin/access.ts?raw"
import { cloudVmPlanOf, storeVmPlan } from "../src/cloud-vm-plan.ts"
import { readVmPlanOverride } from "../src/stack-server.ts"
import { CLOUD_RESTRICTED, cloudPlanId, COMPANY_EMAIL_DOMAINS, COMPANY_MAX_ACTIVE, companyPlanKey, isCompanyEmail, PAID_PLAN_LIMITS, paidPlanLimits, STUB_PLAN, teamPlan, type CloudConfig } from "../src/domains/cloud-plan.ts"
import { CloudEntitlementStore } from "../src/cloud-entitlements.ts"
import { userIdFor } from "../src/domains/user.ts"
import { storePlan } from "../src/inference/plan.ts"
import { inDO, post, testEnv } from "./setup/inference-person.ts"
import { call, mirroredTeam, teamStub } from "./team-stack-support.ts"

/**
 * Cloud machine limits honour the operator and company grants classic Cloud honours (web
 * services/billing/teamResolution.ts billingPlanIdFromMetadata, services/vms/entitlements.ts
 * resolveVmEntitlements with services/billing/companyPlan.ts hasCompanyPlanGrant). Machine limits
 * only: the model router's paid gate (TeamDO.inferencePlan) and billing keep reading cmuxPlan.
 */

const cloud = env as unknown as { CLOUD_DO: DurableObjectNamespace }
const cloudStub = (team: string) => cloud.CLOUD_DO.get(cloud.CLOUD_DO.idFromName(team)) as unknown as { fakeControl(cmd: Record<string, unknown>): Promise<unknown> }
const teamDO = (team: string) => testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))

/** A Stack session token with this email; `verified` sets the email_verified claim. */
const tokenWith = async (subject: string, email: string, verified: boolean) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email, name: subject, ...(verified ? { email_verified: true } : {}) })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(subject)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

/** A signed-in person whose personal team has paid plan `plan` and operator grant `vmPlan` (TeamDO's copies); entitlements on. */
const person = async (subject: string, plan: string | null, vmPlan: string | null, email = `${subject}@example.com`, verified = false) => {
  const t = await tokenWith(subject, email, verified)
  const ensured = await post("/v1/ops", t, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
  const team = ensured.value.personal_team as string
  await inDO(teamDO(team), async (i) => {
    storePlan(i.ctx.storage.sql, plan, Date.now())
    storeVmPlan(i.ctx.storage.sql, vmPlan, Date.now())
  })
  await cloudStub(team).fakeControl({ entitlements: "on" })
  return { t, team }
}
const SMALL = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const create = (t: string, size = SMALL) => post("/v1/ops", t, { op: "cloud.machine.create", params: { name: "grant box", size }, idempotency_key: crypto.randomUUID(), origin: "user" })
const planGet = async (t: string) => (await post("/v1/read", t, { op: "cloud.plan.get", params: {} })).value
const code = (r: any) => r.error?.code ?? r.code

describe("cloudPlanId: classic's billingPlanIdFromMetadata", () => {
  it.each([
    [null, null, null],
    ["pro", null, "pro"],
    [null, "pro", "pro"],
    ["pro", "founders", "founders"],
    // An explicit override is an operator restriction, also over a paid plan.
    ["pro", "free", "free"],
    // A lower paid grant never hides a paid Max; a restriction still does.
    ["max", "pro", "max"],
    ["max", "team", "max"],
    ["max", "founders", "max"],
    ["max", null, "max"],
    ["max", "free", "free"],
    ["go", "max", "max"],
    [" Pro ", null, "pro"],
    // Classic compares the Max exception exactly, then trims and lowercases the winner; a blank override restricts.
    ["max", " pro ", "pro"],
    ["pro", "   ", "free"]
  ] as const)("cmuxPlan %s with cmuxVmPlan %s is %s", (plan, vm, want) => {
    expect(cloudPlanId(plan, vm)).toBe(want)
  })

  it.each([
    [{}, null],
    [{ cmuxVmPlan: null }, null],
    [{ cmuxVmPlan: "pro" }, "pro"],
    [{ cmuxVmPlan: "" }, ""],
    [{ cmuxVmPlan: "  " }, "  "],
    [{ cmuxVmPlan: 3 }, ""],
    [{ cmuxVmPlan: "x".repeat(65) }, ""],
    [null, null],
    [[], null]
  ] as const)("the sign-in record %j reads as cmuxVmPlan %j", (metadata, want) => {
    expect(readVmPlanOverride(metadata)).toBe(want)
  })

  it("a blank or malformed cmuxVmPlan read from the record restricts a paid plan, as in classic", () => {
    expect(cloudPlanId("pro", readVmPlanOverride({ cmuxVmPlan: "" }))).toBe("free")
    expect(cloudPlanId("max", readVmPlanOverride({ cmuxVmPlan: 7 }))).toBe("free")
    expect(cloudPlanId("pro", readVmPlanOverride({}))).toBe("pro")
  })

  it("a restriction wins over the stub plan on an allowlisted team; no plan keeps the stub", () => {
    const config = (plan: string | null): CloudConfig => ({ environment: "staging", allowedTeams: new Set(["team_a"]), prefix: null, image: null, entitlements: { enabled: true, plan: () => plan } })
    expect(teamPlan(config(CLOUD_RESTRICTED), "team_a")).toBeNull()
    expect(teamPlan(config(null), "team_a")).toEqual(STUB_PLAN)
    expect(teamPlan(config("pro"), "team_a")).toEqual(PAID_PLAN_LIMITS.pro)
  })

  it("the company domains are web's admin domains", () => {
    const list = /export const ADMIN_EMAIL_DOMAINS = \[([^\]]+)\]/.exec(webAccessText as string)?.[1]
    expect(list, "web ADMIN_EMAIL_DOMAINS not found").toBeDefined()
    expect(new Set(list!.split(",").map((d) => d.trim().replace(/^"|"$/g, "")).filter(Boolean))).toEqual(COMPANY_EMAIL_DOMAINS)
  })

  it("the company grant is Team (Max for a Max owner) with no machine cap", () => {
    expect(companyPlanKey(false, "pro")).toBeNull()
    expect(paidPlanLimits(companyPlanKey(true, null))).toEqual({ ...PAID_PLAN_LIMITS.team, max_active: COMPANY_MAX_ACTIVE })
    expect(paidPlanLimits(companyPlanKey(true, "pro"))).toEqual({ ...PAID_PLAN_LIMITS.team, max_active: COMPANY_MAX_ACTIVE })
    expect(paidPlanLimits(companyPlanKey(true, "max"))).toEqual({ ...PAID_PLAN_LIMITS.max, max_active: COMPANY_MAX_ACTIVE })
  })

  it.each([
    ["a@manaflow.ai", true],
    ["a.b+c@CMUX.com", true],
    [" a@manaflow.com ", true],
    ["a@example.com", false],
    ['"x"@cmux.com', false],
    ["a b@cmux.com", false],
    ["a@b@cmux.com", false],
    ["a@sub.manaflow.ai", false],
    ["a@manaflow.ai.", false],
    ["a@manaflow.ai.evil.com", false],
    ["@cmux.com", false],
    [null, false]
  ] as const)("isCompanyEmail(%s) is %s (classic isAdminEmail)", (email, want) => {
    expect(isCompanyEmail(email)).toBe(want)
  })
})

describe("Cloud machine grants", { timeout: 60_000 }, () => {
  it("a cmuxVmPlan grant read from the sign-in service gives its limits; the model router still sees no paid plan", async () => {
    const x = await person("grant-vm-pro", null, null)
    // The grant copy goes stale; TeamDO reads it from the sign-in service (the owner's user record).
    await inDO(teamDO(x.team), async (i) => {
      i.ctx.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0 WHERE id = 1`)
      i.stack = { getUserPlan: async () => null, getUserVmPlan: async () => ({ vm_plan: "pro" }), getTeam: async () => null }
    })
    expect(await planGet(x.t)).toMatchObject({ plan_id: "pro", limits: { max_active: 5 } })
    const r = await create(x.t)
    expect(r.ok, JSON.stringify(r)).toBe(true)
    // Billing is untouched: the paid gate the model router and credits read stays unpaid.
    const answer = await (teamDO(x.team) as unknown as { inferencePlan(team: string, user: string, stackUser?: string): Promise<unknown> }).inferencePlan(x.team, userIdFor(testEnv.STACK_PROJECT_ID, "grant-vm-pro"), "grant-vm-pro")
    expect(answer).toMatchObject({ ok: true, paid: false })
  })

  it("cmuxVmPlan free is an operator restriction over a paid plan", async () => {
    const x = await person("grant-vm-free", "pro", "free")
    expect(code(await create(x.t))).toBe("cloud.plan.required")
    expect(await planGet(x.t)).toMatchObject({ plan_id: "none" })
  })

  it("a paid Max keeps Max over a lower grant", async () => {
    const x = await person("grant-vm-max", "max", "pro")
    expect(await planGet(x.t)).toMatchObject({ plan_id: "max", limits: { max_active: 20 } })
  })

  it("a stale grant copy answers while the sign-in service is down", async () => {
    const x = await person("grant-vm-outage", null, "pro")
    await inDO(teamDO(x.team), async (i) => {
      i.ctx.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0 WHERE id = 1`)
      i.stack = { getUserPlan: async () => { throw new Error("stack down") }, getUserVmPlan: async () => { throw new Error("stack down") }, getTeam: async () => { throw new Error("stack down") } }
    })
    expect(await planGet(x.t)).toMatchObject({ plan_id: "pro" })
  })

  it("a shared team's cmuxVmPlan applies to the team", async () => {
    const t = await mirroredTeam("Grant Co")
    await cloudStub(t.team).fakeControl({ entitlements: "on" })
    await inDO(teamStub(t.team), async (i) => {
      storePlan(i.ctx.storage.sql, null, Date.now())
      storeVmPlan(i.ctx.storage.sql, "team", Date.now())
    })
    const got = (await call(t.token, "/v1/read", { op: "cloud.plan.get", params: {} }, t.team)).body
    expect(got.value).toMatchObject({ plan_id: "team", limits: { max_active: 5 } })
  })

  it("a verified company account's personal team is Team with no machine cap", async () => {
    const x = await person("grant-company", null, null, "grant-company@manaflow.ai", true)
    expect(await planGet(x.t)).toMatchObject({ plan_id: "team", upgrade_plan: null, limits: { max_active: COMPANY_MAX_ACTIVE, memory_options_mb: [4096, 8192, 16384] } })
    for (let i = 0; i < 6; i++) expect((await create(x.t)).ok).toBe(true)
  })

  it("a verified company account that pays for Max gets Max sizes, uncapped", async () => {
    const x = await person("grant-company-max", "max", null, "grant-company-max@cmux.com", true)
    expect(await planGet(x.t)).toMatchObject({ plan_id: "max", limits: { max_active: COMPANY_MAX_ACTIVE } })
    expect((await create(x.t, { cpu: 16, memory_mb: 32768, disk_mb: 65536 })).ok).toBe(true)
  })

  it("an empty cmuxVmPlan read from the sign-in service restricts a paid Pro", async () => {
    const x = await person("grant-vm-empty", "pro", null)
    await inDO(teamDO(x.team), async (i) => {
      i.ctx.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0 WHERE id = 1`)
      i.stack = { getUserPlan: async () => "pro", getUserVmPlan: async () => ({ vm_plan: readVmPlanOverride({ cmuxVmPlan: "" }) }), getTeam: async () => null }
    })
    expect(await planGet(x.t)).toMatchObject({ plan_id: "none" })
    expect(code(await create(x.t))).toBe("cloud.plan.required")
  })

  it("a padded cmuxPlan counts for machines as in classic, while the router's exact paid gate is unchanged", async () => {
    const x = await person("grant-padded-max", " Max ", null, "grant-padded-max@manaflow.ai", true)
    expect(await planGet(x.t)).toMatchObject({ plan_id: "max", limits: { max_active: COMPANY_MAX_ACTIVE } })
    const y = await person("grant-padded-pro", " Pro ", null)
    expect(await planGet(y.t)).toMatchObject({ plan_id: "pro" })
    const answer = await (teamDO(y.team) as unknown as { inferencePlan(team: string, user: string, stackUser?: string): Promise<unknown> }).inferencePlan(y.team, userIdFor(testEnv.STACK_PROJECT_ID, "grant-padded-pro"), "grant-padded-pro")
    expect(answer).toMatchObject({ ok: true, paid: false })
  })

  it("an older grant answer never overwrites a newer one", async () => {
    const x = await person("grant-vm-order", null, null)
    await inDO(teamDO(x.team), async (i) => {
      const sql = i.ctx.storage.sql as SqlStorage
      sql.exec(`DELETE FROM cloud_vm_plan`)
      storeVmPlan(sql, "pro", 2_000)
      storeVmPlan(sql, "free", 1_000)
      expect(sql.exec<{ vm_plan: string; checked_at: number }>(`SELECT vm_plan, checked_at FROM cloud_vm_plan WHERE id = 1`).one()).toEqual({ vm_plan: "pro", checked_at: 2_000 })
      expect(await cloudVmPlanOf(sql, null, x.team, undefined, "grant-vm-order", 2_000 + 1)).toEqual({ ok: true, vm_plan: "pro" })
    })
  })

  it.each(["company", "company_max", "user_gone", "enterprise"])("a cmuxVmPlan of %s on the record is an unknown plan: it restricts and grants nothing", async (value) => {
    const x = await person(`grant-vm-unknown-${value}`, "pro", null)
    await inDO(teamDO(x.team), async (i) => {
      i.ctx.storage.sql.exec(`UPDATE cloud_vm_plan SET checked_at = 0 WHERE id = 1`)
      i.stack = { getUserPlan: async () => "pro", getUserVmPlan: async () => ({ vm_plan: value }), getTeam: async () => null }
    })
    expect(await planGet(x.t)).toMatchObject({ plan_id: "none" })
    expect(code(await create(x.t))).toBe("cloud.plan.required")
  })

  it("a company account's tier follows its plan after cmuxVmPlan, as classic's userBillingPlanId does (web services/vms/auth.ts)", async () => {
    const x = await person("grant-company-vm-max", "pro", "max", "grant-company-vm-max@manaflow.ai", true)
    expect(await planGet(x.t)).toMatchObject({ plan_id: "max", limits: { max_active: COMPANY_MAX_ACTIVE } })
    const y = await person("grant-company-vm-free", "max", "free", "grant-company-vm-free@manaflow.ai", true)
    expect(await planGet(y.t)).toMatchObject({ plan_id: "team", limits: { max_active: COMPANY_MAX_ACTIVE } })
  })

  it("an older entitlement read never overwrites a newer one (concurrent refreshes)", async () => {
    const x = await person("grant-ent-order", null, null)
    await inDO(cloud.CLOUD_DO.get(cloud.CLOUD_DO.idFromName(x.team)), async (i) => {
      const store = new CloudEntitlementStore(i.ctx.storage.sql, env as never, () => 0)
      store.record("team_order", "pro", 2_000)
      store.record("team_order", "max", 1_000)
      expect(store.plan("team_order")).toBe("pro")
      store.record("team_order", null, 1_500)
      expect(store.plan("team_order")).toBe("pro")
      expect(new CloudEntitlementStore(i.ctx.storage.sql, env as never, () => 0).plan("team_order")).toBe("pro")
      store.record("team_order", null, 3_000)
      expect(new CloudEntitlementStore(i.ctx.storage.sql, env as never, () => 0).plan("team_order")).toBeNull()
    })
  })

  it("an unverified company address gets no grant", async () => {
    const x = await person("grant-company-unverified", null, null, "grant-company-unverified@manaflow.ai", false)
    expect(code(await create(x.t))).toBe("cloud.plan.required")
  })
})
