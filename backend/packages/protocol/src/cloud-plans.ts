/**
 * The cmux plan catalog as the Cloud ops see it (CLOUD-PLAN-REQUIRED-DETAILS, 2026-10-04). Plan ids
 * here are the ones `cloud.billing.checkout` takes and the refusals name in `details.plan`; the
 * prices and Stripe lookup keys belong to billing, which is not built yet. One owner for the ids:
 * nothing else in the backend or the vectors writes a plan id literal.
 */
export interface CatalogPlan {
  readonly id: string
  /** The plan includes Cloud machines (it lifts cloud.plan.required). */
  readonly cloud: boolean
}

export const CLOUD_PLAN_CATALOG: ReadonlyArray<CatalogPlan> = [{ id: "pro", cloud: true }]

/** The first catalog plan with Cloud: what lifts cloud.plan.required ("See plans"). */
export const cloudEntryPlan = (): string => {
  const plan = CLOUD_PLAN_CATALOG.find((p) => p.cloud)
  if (!plan) throw new Error("the plan catalog has no plan with Cloud")
  return plan.id
}

/** `details` of a cloud.plan.required refusal. */
export const planRequiredDetails = (): { readonly plan: string } => ({ plan: cloudEntryPlan() })
