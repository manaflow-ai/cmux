import { cloudEntryPlan, type CloudMachine, type CloudPlan } from "@cmux/protocol"
import type { CloudTransport } from "../cloud-vm-api-config.ts"

/**
 * Plan limits for CloudDO (state-placement.md 5.7, contract 1.5).
 *
 * Two sources, the paid one first:
 * - Paid entitlements (CLOUD_PLAN_ENTITLEMENTS=on, plans/cmux-next/paid-product-DESIGN.md): the
 *   team's paid plan, the same one the model router gates on (TeamDO.inferencePlan, the sign-in
 *   service's cmuxPlan that web billing writes from Stripe), mapped to PAID_PLAN_LIMITS. CloudDO
 *   keeps the last known plan (cloud-entitlements.ts) and hands it to the pure reducers through
 *   CloudConfig.entitlements.
 * - Operator and company grants, as classic Cloud honours them (cloudPlanId, companyPlanKey): a
 *   `cmuxVmPlan` on the sign-in record, and verified company-domain accounts. Machine limits only.
 * - STUB_PLAN: only in the stub environments (development, staging, test) and only for teams on
 *   CLOUD_ALLOWED_TEAMS ("*" = every team: NEXT's own users while NEXT Cloud is in dogfood).
 * Every other team gets no plan, so create answers cloud.plan.required and no provider VM is made
 * for free. With the flag off (production until go-live) only the stub applies, as before.
 */
export interface PlanLimits {
  readonly plan_id: string
  readonly max_active: number
  readonly max_saved: number
  readonly memory_options_mb: ReadonlyArray<number>
  readonly locked_memory_options_mb: ReadonlyArray<number>
  readonly vm_hours_included: number | null
  readonly max_cpu: number
  readonly max_disk_mb: number
  /** The plan that lifts these limits ("See plans"); null only for a plan nothing lifts. */
  readonly upgrade_plan: string | null
}

/** Only in STUB_PLAN_ENVIRONMENTS (development, staging, test): Max's machine sizes, so dogfood is not capped below what people pay for. */
export const STUB_PLAN: PlanLimits = {
  plan_id: "stub_default",
  max_active: 5,
  max_saved: 10,
  memory_options_mb: [4096, 8192, 16384, 32768, 65536],
  locked_memory_options_mb: [],
  vm_hours_included: null,
  max_cpu: 32,
  max_disk_mb: 262144,
  // CLOUD-LINK-FOLLOWUPS (3): the catalog entry plan, so "See plans" shows on the stub plan too.
  upgrade_plan: cloudEntryPlan()
}

const GiB = 1024
/** Pro, Team and Founders: 5 machines at once, up to 8 vCPU / 16 GB, disk 128 GB (classic entitlements.ts). */
const PRO_LIMITS: Omit<PlanLimits, "plan_id" | "upgrade_plan"> = {
  max_active: 5,
  max_saved: 20,
  memory_options_mb: [4 * GiB, 8 * GiB, 16 * GiB],
  locked_memory_options_mb: [],
  vm_hours_included: null,
  max_cpu: 8,
  max_disk_mb: 128 * GiB
}

/**
 * The Cloud limits of each paid plan id (the ids web billing writes as cmuxPlan). They are classic's
 * live allowance (web/services/vms/entitlements.ts on main), because both apps sell the same Stripe
 * products: Plus ($15, id `go`, #26732) is one machine at Pro sizes with no hour cap; Pro, Founders
 * and Team five up to 8 vCPU / 16 GB; Max five up to 32 vCPU / 64 GB with 256 GB disk.
 * `upgrade_plan` is the plan that lifts them: Plus -> Pro, Pro and Founders -> Max; Max and Team
 * have no self-serve plan above them (null).
 */
export const PAID_PLAN_LIMITS: Readonly<Record<string, PlanLimits>> = {
  go: { plan_id: "go", ...PRO_LIMITS, max_active: 1, upgrade_plan: "pro" },
  pro: { plan_id: "pro", ...PRO_LIMITS, upgrade_plan: "max" },
  founders: { plan_id: "founders", ...PRO_LIMITS, upgrade_plan: "max" },
  team: { plan_id: "team", ...PRO_LIMITS, upgrade_plan: null },
  max: { plan_id: "max", max_active: 5, max_saved: 50, memory_options_mb: [4 * GiB, 8 * GiB, 16 * GiB, 32 * GiB, 64 * GiB], locked_memory_options_mb: [], vm_hours_included: null, max_cpu: 32, max_disk_mb: 256 * GiB, upgrade_plan: null }
}

/**
 * Company accounts (classic web services/billing/companyPlan.ts hasCompanyPlanGrant): a verified email on
 * one of these domains is Team by default, Max when the person's own plan is Max, with no machine cap.
 * The same list as web services/admin/access.ts ADMIN_EMAIL_DOMAINS (test/cloud-plan-overrides.test.ts).
 */
export const COMPANY_EMAIL_DOMAINS: ReadonlySet<string> = new Set(["cmux.com", "manaflow.ai", "manaflow.com"])
/** Classic gives company accounts no active-machine cap (maxActiveVms null); the reducers compare numbers, so the cap is out of reach. */
export const COMPANY_MAX_ACTIVE = Number.MAX_SAFE_INTEGER
/** Entitlement keys of the company grant (never a web plan id); their limits name the plan they are (team or max). */
export const COMPANY_PLAN_LIMITS: Readonly<Record<string, PlanLimits>> = {
  company: { ...PAID_PLAN_LIMITS.team!, max_active: COMPANY_MAX_ACTIVE },
  company_max: { ...PAID_PLAN_LIMITS.max!, max_active: COMPANY_MAX_ACTIVE }
}

/** The limits of an entitlement key (a paid plan id or a company key), or null (free, unknown, or no plan). */
export const paidPlanLimits = (plan: string | null | undefined): PlanLimits | null =>
  plan && Object.hasOwn(PAID_PLAN_LIMITS, plan) ? PAID_PLAN_LIMITS[plan]! : plan && Object.hasOwn(COMPANY_PLAN_LIMITS, plan) ? COMPANY_PLAN_LIMITS[plan]! : null

/** Plans a `cmuxVmPlan` grant does not lower below a paid Max (classic billingPlanIdFromMetadata). */
const KEEPS_MAX: ReadonlySet<string | null> = new Set([null, "pro", "team", "founders", "max"])

/**
 * The Cloud plan id of one sign-in service record, exactly as classic Cloud reads it (web
 * services/billing/teamResolution.ts billingPlanIdFromMetadata, then entitlements.ts
 * normalizedPlanId): the operator's `cmuxVmPlan` wins over the billing `cmuxPlan`, except that a
 * lower paid grant never hides a paid Max (exact values, as classic compares them). An explicit
 * `cmuxVmPlan` such as "free", or a blank one, is an operator restriction and stands ("free").
 * Machine limits only: the model router and billing keep reading `cmuxPlan` alone.
 */
export const cloudPlanId = (plan: string | null, vmPlan: string | null): string | null => {
  if (plan === "max" && KEEPS_MAX.has(vmPlan)) return "max"
  const value = vmPlan ?? plan
  if (value === null) return null
  const id = value.trim().toLowerCase()
  return id || "free"
}

/**
 * A company account's email (classic web services/admin/access.ts isAdminEmail): printable ASCII,
 * a plain local part, and exactly one of COMPANY_EMAIL_DOMAINS after the last "@" (no subdomain,
 * lookalike or trailing dot). The caller also requires the address to be verified.
 */
export const isCompanyEmail = (email: string | null | undefined): boolean => {
  if (typeof email !== "string") return false
  const normalized = email.trim()
  if (normalized.length === 0 || normalized.length > 254 || !/^[\x21-\x7e]+$/.test(normalized)) return false
  const at = normalized.lastIndexOf("@")
  if (at <= 0 || at === normalized.length - 1) return false
  const local = normalized.slice(0, at)
  const domain = normalized.slice(at + 1).toLowerCase()
  if (local.length > 64 || !/^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$/.test(local)) return false
  return /^[a-z0-9.-]+$/.test(domain) && COMPANY_EMAIL_DOMAINS.has(domain)
}

/** The company grant's entitlement key, or null; Max stays Max (classic resolveVmEntitlements). */
export const companyPlanKey = (company: boolean, ownPlan: string | null): string | null => (company ? (ownPlan === "max" ? "company_max" : "company") : null)

/** The team's paid plan as CloudDO last knew it (cloud-entitlements.ts), read synchronously by the reducers. */
export interface CloudEntitlements {
  /** CLOUD_PLAN_ENTITLEMENTS is on for this object. */
  readonly enabled: boolean
  /** The team's last known paid plan id, or null when it has none (or it was never read). */
  plan(team: string): string | null
}

/** What CloudDO's reducer needs from the deployment. Fixed per object instance, so the reducer stays pure. */
export interface CloudConfig {
  readonly transport?: CloudTransport
  readonly environment: string
  /** CLOUD_ALLOWED_TEAMS: the only teams with the stub plan and provider calls; empty = nobody, ALL_TEAMS = everyone. */
  readonly allowedTeams: ReadonlySet<string>
  /** This environment's provider name prefix (cmuxnp-dev-cld-, cmuxnp-stg-cld-, cmuxnp-prod-cld-); null = no provider. */
  readonly prefix: string | null
  /** The image every machine boots from; null = no provider, or no usable snapshot (see imageProblem). */
  readonly image: string | null
  /** Why there is no image: no snapshot configured, or one without this environment's prefix (CLOUD-DEV-SNAPSHOT). */
  readonly imageProblem?: "missing" | "foreign"
  /** Paid plan entitlements; absent = the stub rule only. */
  readonly entitlements?: CloudEntitlements
}

/** Environments where the stub plan may apply, as an explicit list (never "not production"). */
export const STUB_PLAN_ENVIRONMENTS: ReadonlySet<string> = new Set(["development", "staging", "test"])

/** The CLOUD_ALLOWED_TEAMS entry that puts every team on the stub plan (still only in STUB_PLAN_ENVIRONMENTS). */
export const ALL_TEAMS = "*"

export const planFor = (environment: string, team: string | null | undefined, allowed: ReadonlySet<string>): PlanLimits | null =>
  STUB_PLAN_ENVIRONMENTS.has(environment) && team !== null && team !== undefined && team !== "" && (allowed.has(team) || allowed.has(ALL_TEAMS)) ? STUB_PLAN : null

/**
 * The entitlement key of a record whose plan is set but grants no machines: an operator restriction
 * (`cmuxVmPlan` "free", blank or malformed) or an unknown plan id. Classic gives it zero machines,
 * so it also wins over the stub plan.
 */
export const CLOUD_RESTRICTED = "restricted"

/** The team's limits: its paid plan when entitlements are on and it has one, none when it is restricted, else the stub rule. */
export const teamPlan = (config: CloudConfig, team: string | null | undefined): PlanLimits | null => {
  const key = config.entitlements?.enabled && team ? config.entitlements.plan(team) : null
  if (key === CLOUD_RESTRICTED) return null
  return paidPlanLimits(key) ?? planFor(config.environment, team, config.allowedTeams)
}

/** CLOUD_ALLOWED_TEAMS: comma-separated team ids, or "*" for every team; blanks dropped; unset or empty = nobody. */
export const parseAllowedTeams = (raw: string | undefined): ReadonlySet<string> => new Set((raw ?? "").split(",").map((t) => t.trim()).filter((t) => t.length > 0))

export const DEFAULT_SIZE = { cpu: 2, disk_mb: 16384 } as const
/** The memory a record assumes when it names none (the stub plan's smallest option). */
export const DEFAULT_MEMORY_MB = 4096
export const DEFAULT_IDLE_SECONDS = 1800

/** Whether a memory size needs another plan: not offered, or offered but locked. */
export const sizeLocked = (plan: PlanLimits, memoryMb: number) => !plan.memory_options_mb.includes(memoryMb) || plan.locked_memory_options_mb.includes(memoryMb)

/** The provider name of a machine: `<prefix><machine id>` with `_` as `-` (provider names are DNS labels). */
export const providerName = (prefix: string, machine: string) => `${prefix}${machine.replace(/_/g, "-")}`

/** End of the current UTC month (the usage period). */
export const periodEnd = (now: number) => {
  const d = new Date(now)
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
}

export const planView = (plan: PlanLimits | null, usage: { active: number; saved: number }, now: number): typeof CloudPlan.Type => ({
  plan_id: plan?.plan_id ?? "none",
  // No plan: the entry plan lifts cloud.plan.required (the same plan its details name).
  upgrade_plan: plan ? plan.upgrade_plan : cloudEntryPlan(),
  limits: {
    max_active: plan?.max_active ?? 0,
    max_saved: plan?.max_saved ?? 0,
    memory_options_mb: [...(plan?.memory_options_mb ?? [])],
    locked_memory_options_mb: [...(plan?.locked_memory_options_mb ?? [])],
    vm_hours_included: plan?.vm_hours_included ?? null
  },
  // VM-hours metering (UsageMeterDO) is not wired yet: null (unknown) until it is, so no page shows "0 of 40 h".
  usage: { active: usage.active, saved: usage.saved, vm_hours_used: null, period_end: periodEnd(now) }
})

export type CloudMachineView = typeof CloudMachine.Type

/**
 * Why this deployment cannot create a machine, or undefined. No provider (key or prefix) is a retryable
 * cloud.provider.unavailable; no usable snapshot is cloud.no_snapshot_configured, not retryable and with
 * no fallback image (CLOUD-DEV-SNAPSHOT: only the image lane's snapshot for this environment).
 */
export const createConfigProblem = (config: CloudConfig): { code: string; message: string; retryable: boolean } | undefined => {
  if (!config.prefix) return { code: "cloud.provider.unavailable", message: "Cloud machines are not configured on this deployment", retryable: true }
  if (!config.image) {
    const why = config.imageProblem === "foreign" ? "the configured snapshot is not this environment's image" : "no image snapshot is configured for this environment yet"
    return { code: "cloud.no_snapshot_configured", message: why, retryable: false }
  }
  return undefined
}

/** Refusal details for a plan limit: what was asked or used, plus the plan that would lift it (null when none). */
export const limitDetails = (plan: PlanLimits, details: Record<string, unknown>): Record<string, unknown> => ({ ...details, plan: plan.upgrade_plan })
