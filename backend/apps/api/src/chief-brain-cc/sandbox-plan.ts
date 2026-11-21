import { planRequiredDetails } from "@cmux/protocol"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { parseAllowedTeams, planFor } from "../domains/cloud-plan.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import { PRICING_URL } from "../plan-checkout.ts"
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
/** A platform that did not answer is asked again only after this long, so the profile's status polls do not hammer it. */
export const FAILED_FRESH_MS = 10_000
/** The platform's last word per object: the plan id from an answer, or null when it did not answer (unknown, never entitled). */
const answers = new WeakMap<object, { team: string; at: number; plan: string | null }>()

/**
 * The plans whose owners get a Chief's own Cloud computer (2026-11-20: only cmux NEXT Plus, Pro and Max): Plus (plan id `go`), Pro, Max, and Founders,
 * which is Pro sold early at the same limits (domains/cloud-plan.ts PAID_PLAN_LIMITS). `stub_default` is the stub
 * plan of development, staging and test only. Team and any other plan get no computer.
 */
export const COMPUTER_PLANS: ReadonlySet<string> = new Set(["go", "pro", "max", "founders", "stub_default"])

/** The stub plan id when the stub rule gives `team` one (development, staging and test only), else null. */
const stubPlan = (b: ChiefBrainDO, team: string): string | null =>
  planFor(b.doEnv.ENVIRONMENT, team, parseAllowedTeams(b.doEnv.CLOUD_ALLOWED_TEAMS))?.plan_id ?? null

/**
 * Owner `owner`'s personal team's Cloud plan id ("none" for no plan), or null when the platform did not answer and no
 * stub plan applies; a Chief with no known owner has none. Never throws.
 */
export const ownerPlan = async (b: ChiefBrainDO, owner: string | null): Promise<string | null> => {
  if (!owner) return "none"
  const env = b.doEnv
  const team = personalTeamIdFor(owner)
  const now = Date.now()
  // The stub rule (development, staging and test only) is read each time; a failure is cached as unknown, never as paid.
  const withStub = (plan: string | null): string | null => (plan !== null && plan !== "none" ? plan : (stubPlan(b, team) ?? plan))
  const cached = answers.get(b.sql)
  if (cached && cached.team === team && now - cached.at < (cached.plan === null ? FAILED_FRESH_MS : FRESH_MS)) return withStub(cached.plan)
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner }
  const reply = await platformCloud(env.CLOUD_DO, team).readOp(team, principal, "cloud.plan.get", {}).catch(() => null)
  const planId = reply?.ok ? (reply.value as { plan_id?: unknown } | null)?.plan_id : undefined
  const plan = reply?.ok ? (typeof planId === "string" && planId !== "" ? planId : "none") : null
  // An answer is kept FRESH_MS; an unreachable platform is kept as unknown for FAILED_FRESH_MS, then asked again.
  answers.set(b.sql, { team, at: now, plan })
  return withStub(plan)
}

/** Whether owner `owner`'s personal team has a Cloud plan (sandboxes); a Chief with no known owner has none. Never throws. */
export const ownerEntitled = async (b: ChiefBrainDO, owner: string | null): Promise<boolean> => {
  const plan = await ownerPlan(b, owner)
  return plan !== null && plan !== "none"
}

/** Whether owner `owner` may have and use a Chief's own Cloud computer: a plan in COMPUTER_PLANS. Never throws. */
export const ownerComputerEntitled = async (b: ChiefBrainDO, owner: string | null): Promise<boolean> =>
  computerPlanAllowed(await ownerPlan(b, owner))

/** Whether plan id `plan` (null: unknown) gives a Chief's own computer. */
export const computerPlanAllowed = (plan: string | null): boolean => plan !== null && COMPUTER_PLANS.has(plan)

/** A Chief's computer refused to an owner whose plan is not Plus, Pro or Max (the Cloud machines' code and details). */
export const COMPUTER_PLAN_REQUIRED = () => ({ status: 403 as const, code: "cloud.plan.required", error: `a Chief's computer needs cmux NEXT Plus, Pro or Max (${PRICING_URL}); go on without it, and only if the person's task cannot be done without a screen, tell them once in one line with that link`, details: planRequiredDetails() })

/** The refusal of a sandbox or a computer without a Cloud plan (the Cloud machines' code and details). */
export const PLAN_REQUIRED = () => ({ status: 403, json: { code: "cloud.plan.required", error: "cloud.plan.required: your own computer and sandboxes need a cmux Cloud plan; ask the person to upgrade", details: planRequiredDetails() } })
