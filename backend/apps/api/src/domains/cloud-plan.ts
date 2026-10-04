import type { CloudMachine, CloudPlan } from "@cmux/protocol"

/**
 * Plan limits for CloudDO (state-placement.md 5.7, contract 1.5).
 *
 * STUB: the backend has no Cloud entitlement yet (the billing webhook path, Stripe -> MySQL billing
 * tables -> op to the owner, is not built). Until it lands, every team outside production gets
 * STUB_PLAN, and production gets no plan, so production answers cloud.plan.required and never
 * calls the provider for free. Replace `planFor` with the entitlement read when billing lands.
 */
export interface PlanLimits {
  readonly plan_id: string
  readonly max_active: number
  readonly max_saved: number
  readonly memory_options_mb: ReadonlyArray<number>
  readonly locked_memory_options_mb: ReadonlyArray<number>
  readonly vm_hours_included: number | null
}

export const STUB_PLAN: PlanLimits = {
  plan_id: "stub_default",
  max_active: 5,
  max_saved: 10,
  memory_options_mb: [4096, 8192],
  locked_memory_options_mb: [],
  vm_hours_included: null
}

/** What CloudDO's reducer needs from the deployment. Fixed per object instance, so the reducer stays pure. */
export interface CloudConfig {
  /** null: no plan (production until billing lands). */
  readonly plan: PlanLimits | null
  /** This environment's provider name prefix (cmuxnp-dev-, cmuxnp-stg-, cmuxnp-prod-); null = no provider. */
  readonly prefix: string | null
  /** The image every machine boots from; null = no provider. */
  readonly image: string | null
}

export const planFor = (environment: string): PlanLimits | null => (environment === "production" ? null : STUB_PLAN)

export const DEFAULT_SIZE = { cpu: 2, disk_mb: 16384 } as const
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
  limits: {
    max_active: plan?.max_active ?? 0,
    max_saved: plan?.max_saved ?? 0,
    memory_options_mb: [...(plan?.memory_options_mb ?? [])],
    locked_memory_options_mb: [...(plan?.locked_memory_options_mb ?? [])],
    vm_hours_included: plan?.vm_hours_included ?? null
  },
  // VM-hours metering (UsageMeterDO) is not wired yet: 0 until it is.
  usage: { active: usage.active, saved: usage.saved, vm_hours_used: 0, period_end: periodEnd(now) }
})

export type CloudMachineView = typeof CloudMachine.Type
