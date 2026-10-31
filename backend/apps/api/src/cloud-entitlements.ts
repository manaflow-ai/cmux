import type { Principal } from "@cmux/ownership"
import { CLOUD_RESTRICTED, cloudPlanId, companyPlanKey, PAID_PLAN_LIMITS, type CloudEntitlements } from "./domains/cloud-plan.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"

/** CloudDO asks TeamDO again after this long; TeamDO keeps its own copy fresh (inference/plan.ts PLAN_FRESH_MS). */
export const ENTITLEMENT_FRESH_MS = 60_000

/** CLOUD_PLAN_ENTITLEMENTS: "on" turns paid plan entitlements on; anything else (or unset) is off. */
export const entitlementsOn = (env: Pick<Env, "CLOUD_PLAN_ENTITLEMENTS">) => env.CLOUD_PLAN_ENTITLEMENTS === "on"

/**
 * The team's paid plan as CloudDO last knew it (paid-product-DESIGN.md). The read is the one the
 * model router uses (TeamDO.inferencePlan: the sign-in service's cmuxPlan, cached by TeamDO), so
 * Cloud machines and model usage follow one plan.
 *
 * The last known paid plan is kept in this object's storage (`cloud_entitlement`), so an alarm
 * pass after an eviction still sees it, and a plan-service outage (TeamDO answers unavailable)
 * never locks out a team that had a plan. Only an answer from the plan service changes it. The
 * table is created on the first paid answer: a team that never had a plan writes nothing.
 */
export class CloudEntitlementStore implements CloudEntitlements {
  enabled: boolean
  private readonly memo = new Map<string, { plan: string | null; at: number }>()

  constructor(
    private readonly sql: SqlStorage,
    private readonly env: Env,
    private readonly now: () => number
  ) {
    this.enabled = entitlementsOn(env)
  }

  plan(team: string): string | null {
    const hit = this.memo.get(team)
    if (hit) return hit.plan
    const plan = this.stored(team)
    this.memo.set(team, { plan, at: 0 })
    return plan
  }

  /** Asks TeamDO for the team's plan when the copy is older than ENTITLEMENT_FRESH_MS; never throws. */
  async refresh(team: string, principal: Principal): Promise<void> {
    if (!this.enabled || !principal.user) return
    const now = this.now()
    const hit = this.memo.get(team)
    if (hit && hit.at > 0 && now - hit.at < ENTITLEMENT_FRESH_MS) return
    const plan = await this.read(team, principal).catch((e: unknown) => {
      console.warn(JSON.stringify({ msg: "cloud.entitlement.read_failed", team, error: String(e).slice(0, 160) }))
      return undefined
    })
    // undefined: unavailable; keep the last known plan.
    if (plan === undefined) return
    this.record(team, plan, now)
  }

  /**
   * The team's entitlement key (cloud-plan.ts paidPlanLimits), null for none, undefined when the
   * plan service is unavailable. As classic Cloud reads it: the paid plan, then the operator's
   * `cmuxVmPlan` over it (cloudPlanId), and on a personal team of a verified company account the
   * company grant (companyPlanKey). Billing and the model router keep reading the paid plan alone.
   */
  private async read(team: string, principal: Principal): Promise<string | null | undefined> {
    const user = principal.user!
    // A personal team pays through its owner's personal plan (inference/route.ts does the same).
    const personal = team === personalTeamIdFor(user)
    const users = this.env.USER_DO.get(this.env.USER_DO.idFromName(user))
    const stackUser = personal ? (principal.stack_user_id ?? (await users.stackUserOf(user)) ?? undefined) : undefined
    // The company grant follows the owner's verified email (UserDO's record), never a client claim.
    const company = personal && (await users.cloudCompanyAccount(user))
    if (personal && !stackUser) return companyPlanKey(company, null)
    const teams = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team))
    const [answer, grant] = await Promise.all([teams.inferencePlan(team, user, stackUser), teams.cloudVmPlan(team, stackUser)])
    if (!answer.ok || !grant.ok) return undefined
    // The raw cmuxPlan, not the router's exact-match paid flag: classic normalizes it (" Max " is max) for machines.
    const own = cloudPlanId(answer.plan ?? null, grant.vm_plan)
    // A set plan that grants nothing (a restriction, an unknown id) is kept as such: it also blocks the stub plan.
    // Only a web plan id counts from the record: the company keys are granted here alone, never read from metadata.
    return companyPlanKey(company, own) ?? (own === null ? null : Object.hasOwn(PAID_PLAN_LIMITS, own) ? own : CLOUD_RESTRICTED)
  }

  /** Records a read that started at `at`; a read that started before a newer recorded one changes nothing (concurrent refreshes). */
  record(team: string, plan: string | null, at: number) {
    const hit = this.memo.get(team)
    if (hit && hit.at > at) return
    this.memo.set(team, { plan, at })
    if (plan !== null) {
      this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_entitlement (team TEXT PRIMARY KEY, plan TEXT NOT NULL, checked_at INTEGER NOT NULL)`)
      this.sql.exec(`INSERT INTO cloud_entitlement (team, plan, checked_at) VALUES (?, ?, ?) ON CONFLICT (team) DO UPDATE SET plan = excluded.plan, checked_at = excluded.checked_at WHERE excluded.checked_at >= cloud_entitlement.checked_at`, team, plan, at)
    } else if (this.hasTable()) {
      this.sql.exec(`DELETE FROM cloud_entitlement WHERE team = ? AND checked_at <= ?`, team, at)
    }
  }

  private stored(team: string): string | null {
    if (!this.hasTable()) return null
    return this.sql.exec<{ plan: string }>(`SELECT plan FROM cloud_entitlement WHERE team = ?`, team).toArray()[0]?.plan ?? null
  }

  private hasTable() {
    return this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'cloud_entitlement'`).one().n > 0
  }
}
