import type { Automation } from "@cmux/protocol"
import type { Principal } from "@cmux/ownership"
import { FREE_CHIEF_JOBS, ownerPaid, UPSELL_PLAN } from "./chief-brain-cc/jobs.ts"
import type { Env } from "./env.ts"
import { planLink, PRICING_URL } from "./plan-checkout.ts"
import type { ReadResult } from "./owner-do.ts"

/**
 * The free-plan cap on Cloud Chief jobs made from the person's own clients
 * (docs/automations-platonic-ideal.md, Cloud slice): `cmux automation create --target cloud` and the Mac
 * app's Automations page send `automation.create` with a `chief` body over /v1/ops. `chief-auto` (a Chief
 * making a job from its turn) has the same cap in chief-brain-cc/jobs.ts; this gate counts the team's
 * `chief` automations of every Chief, so the two paths share one cap of FREE_CHIEF_JOBS.
 *
 * A plan read that fails lets the create through (an outage never blocks a paying person), as in jobs.ts.
 */
export interface PlanRefusal {
  readonly code: "automation.plan.required"
  readonly message: string
  readonly details: { readonly plan: string; readonly checkout: string; readonly test_mode: boolean }
}

/** Whether this op is a create of a Chief job by a person (session or install), the only case the gate looks at. */
export const isChiefJobCreate = (op: string, params: unknown, p: Principal): boolean =>
  op === "automation.create" && (p.kind === "session" || p.kind === "install") && typeof p.user === "string" && (params as { body?: { type?: unknown } } | null)?.body?.type === "chief"

/** Counts the team's `chief` automations through `list` (automation.list pages). */
export const chiefJobCount = async (list: (cursor?: string) => Promise<ReadResult>): Promise<number> => {
  let n = 0
  let cursor: string | undefined
  for (let i = 0; i < 20; i++) {
    const r = await list(cursor)
    if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
    const v = r.value as { automations: Array<Automation>; next_cursor?: string | null }
    n += v.automations.filter((a) => a.body.type === "chief").length
    if (!v.next_cursor) break
    cursor = v.next_cursor
  }
  return n
}

/** The refusal for a create over the free cap, or undefined when it may go on. */
export const chiefJobGate = async (env: Env, p: Principal, list: (cursor?: string) => Promise<ReadResult>): Promise<PlanRefusal | undefined> => {
  if (!p.user || !p.team) return undefined
  let count: number
  try {
    count = await chiefJobCount(list)
  } catch {
    return undefined
  }
  if (count < FREE_CHIEF_JOBS) return undefined
  if ((await ownerPaid(env, p.user)) !== "free") return undefined
  const link = env.CLOUD_API_ORIGIN ? await planLink(env, env.CLOUD_API_ORIGIN, p.team, UPSELL_PLAN) : null
  return {
    code: "automation.plan.required",
    message: `the free plan has ${FREE_CHIEF_JOBS} Cloud job; Pro ($50/month) has more. Nothing is charged until you pay on the checkout page.`,
    details: { plan: UPSELL_PLAN, checkout: link ?? PRICING_URL, test_mode: link !== null }
  }
}
