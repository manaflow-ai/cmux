import { planRequiredDetails } from "@cmux/protocol"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { parseAllowedTeams, planFor } from "../domains/cloud-plan.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import { platformCloud } from "../platform-cloud.ts"
import type { Principal } from "@cmux/ownership"

/**
 * A Chief's own computer is a cmux Cloud feature (DESIGN "Entitlement"): a new sandbox (create, fork) and a
 * `computer setup` need a Cloud plan on the owner's personal team. The plan comes from where Cloud machines read
 * it: cmux-platform's `cloud.plan.get`, asked as the owner (`plan_id` "none" = no plan). When the platform is not
 * bound or does not answer, only the stub rule of CLOUD_ALLOWED_TEAMS applies, which holds only in development,
 * staging and test (domains/cloud-plan.ts planFor), so production without an answer refuses.
 */
const FRESH_MS = 60_000
const answers = new WeakMap<object, { team: string; at: number; paid: boolean }>()

/** Whether owner `owner`'s personal team has a Cloud plan; a Chief with no known owner has none. Never throws. */
export const ownerEntitled = async (b: ChiefBrainDO, owner: string | null): Promise<boolean> => {
  if (!owner) return false
  const env = b.doEnv
  const team = personalTeamIdFor(owner)
  const now = Date.now()
  const cached = answers.get(b.sql)
  if (cached && cached.team === team && now - cached.at < FRESH_MS) return cached.paid
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner }
  const reply = await platformCloud(env.CLOUD_DO, team).readOp(team, principal, "cloud.plan.get", {}).catch(() => null)
  const planId = reply?.ok ? (reply.value as { plan_id?: unknown } | null)?.plan_id : undefined
  const paid = (typeof planId === "string" && planId !== "none") || planFor(env.ENVIRONMENT, team, parseAllowedTeams(env.CLOUD_ALLOWED_TEAMS)) !== null
  // Only an answer is kept: an unreachable platform is asked again next time.
  if (reply?.ok) answers.set(b.sql, { team, at: now, paid })
  return paid
}

/** The refusal of a sandbox or a computer without a Cloud plan (the Cloud machines' code and details). */
export const PLAN_REQUIRED = () => ({ status: 403, json: { code: "cloud.plan.required", error: "cloud.plan.required: your own computer and sandboxes need a cmux Cloud plan; ask the person to upgrade", details: planRequiredDetails() } })
