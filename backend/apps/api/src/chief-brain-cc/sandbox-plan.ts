import { planRequiredDetails } from "@cmux/protocol"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { CloudEntitlementStore } from "../cloud-entitlements.ts"
import { parseAllowedTeams, teamPlan } from "../domains/cloud-plan.ts"
import { personalTeamIdFor } from "../domains/user.ts"

/**
 * A Chief's own computer is a cmux Cloud feature (DESIGN "Entitlement"): a new sandbox (create, fork) and a
 * `computer setup` need a Cloud plan on the owner's personal team, read exactly as Cloud machines read it
 * (cloud-plan.ts teamPlan: the paid plan with CLOUD_PLAN_ENTITLEMENTS on, a restriction blocks, else the stub rule
 * of CLOUD_ALLOWED_TEAMS in development, staging and test). One store per Chief's sandboxes object, so a profile
 * polling its status asks the plan service at most once per ENTITLEMENT_FRESH_MS.
 */
const stores = new WeakMap<object, CloudEntitlementStore>()

/** Whether owner `owner`'s personal team has a Cloud plan; a Chief with no known owner has none. Never throws. */
export const ownerEntitled = async (b: ChiefBrainDO, owner: string | null): Promise<boolean> => {
  if (!owner) return false
  const env = b.doEnv
  let store = stores.get(b.sql)
  if (!store) stores.set(b.sql, (store = new CloudEntitlementStore(b.sql, env, () => Date.now())))
  const team = personalTeamIdFor(owner)
  await store.refresh(team, { identity: `user:${owner}`, user: owner, kind: "system" })
  return teamPlan({ environment: env.ENVIRONMENT, allowedTeams: parseAllowedTeams(env.CLOUD_ALLOWED_TEAMS), prefix: null, image: null, entitlements: store }, team) !== null
}

/** The refusal of a sandbox or a computer without a Cloud plan (the Cloud machines' code and details). */
export const PLAN_REQUIRED = () => ({ status: 403, json: { code: "cloud.plan.required", error: "cloud.plan.required: your own computer and sandboxes need a cmux Cloud plan; ask the person to upgrade", details: planRequiredDetails() } })
