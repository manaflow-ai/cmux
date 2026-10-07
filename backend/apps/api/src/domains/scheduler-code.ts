import { canonicalJson, type OutboxItem, type ReduceContext, type ReduceResult, type Reject } from "@cmux/ownership"
import { AutomationDeploy, cloudOpByName, type Automation, type Body } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { deniedPattern } from "../egress-hosts.ts"
import { decodeParams, reject } from "./common.ts"
import type { SchedulerState } from "./scheduler.ts"

/**
 * Code bodies in the SchedulerDO reducer (decisions A11, A12, C1): the daily
 * limit on code changes and `automation.deploy`. Pure like the rest of the
 * reducer. The Worker checks that a commit and its bundle exist before the op
 * reaches the owner; the loader reads only the owner team's repository, so a
 * ref that skipped that check can at worst fail its own runs.
 */

export const automationOutbox = (a: Automation): OutboxItem => ({ kind: "automation.upsert", entity: a.id, payload: a })

/** Code changes a team may make per UTC day (automations-billing.md 5.5). */
export const MAX_DEPLOYS_PER_DAY = 50

const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10)

/** The code ref a body pins, as a comparable key; undefined for other bodies. */
export const codeKey = (b: Body | undefined) => (b?.type === "code" ? canonicalJson(b.ref) : undefined)

/**
 * Counts one code change when `next` pins code that `prev` did not. Returns the
 * new counter, or a rejection at the daily limit. Pure: the day comes from ctx.now.
 */
export const countDeploy = (state: SchedulerState, prev: Body | undefined, next: Body, now: number): { ok: true; deploys: SchedulerState["deploys"] } | { ok: false; result: ReduceResult<SchedulerState> } => {
  const key = codeKey(next)
  if (key === undefined || key === codeKey(prev)) return { ok: true, deploys: state.deploys }
  const day = utcDay(now)
  const count = state.deploys?.day === day ? state.deploys.count : 0
  if (count >= MAX_DEPLOYS_PER_DAY) return { ok: false, result: reject("deploy.limit", `at most ${MAX_DEPLOYS_PER_DAY} code changes per team per UTC day`) }
  return { ok: true, deploys: { day, count: count + 1 } }
}

export const reduceDeploy = (state: SchedulerState, params: unknown, ctx: ReduceContext): ReduceResult<SchedulerState> => {
  const d = decodeParams<typeof AutomationDeploy.params.Type>(AutomationDeploy, params)
  if (!d.ok) return d
  const v = d.value
  const a = state.automations[v.automation]
  if (!a) return reject("selector.not_found", "automation not found")
  if (a.body.type !== "code") return reject("body.not_code", "only a code automation can be deployed")
  if (v.expected_version !== undefined && v.expected_version !== a.version) {
    return reject("version.conflict", "expected_version does not match", { expected: v.expected_version, actual: a.version })
  }
  if (a.body.ref.commit === v.commit) return { ok: true, state, value: a, changed: false }
  const body: Body = { type: "code", ref: { ...a.body.ref, commit: v.commit } }
  const counted = countDeploy(state, a.body, body, ctx.now)
  if (!counted.ok) return counted.result
  const next = { ...a, body, version: a.version + 1, updated_at: ctx.now }
  return {
    ok: true,
    state: { ...state, automations: { ...state.automations, [a.id]: next }, ...(counted.deploys ? { deploys: counted.deploys } : {}) },
    value: next,
    outbox: [automationOutbox(next)]
  }
}

/**
 * `op` steps (automations plan slice 4, P13): the params must decode with the op's own
 * schema at create and update, so a broken step fails then, not at run time.
 */
export const invalidBody = (body: Body): ({ ok: false } & Reject) | undefined => {
  if (body.type === "code") {
    const bad = (body.egress ?? []).find(deniedPattern)
    return bad ? reject("validation.invalid", `egress host ${bad} is not allowed (cmux's own domains)`) : undefined
  }
  if (body.type !== "steps") return undefined
  for (const [i, s] of body.steps.entries()) {
    if (s.type !== "op") continue
    const def = cloudOpByName.get(s.op)
    if (!def || Exit.isFailure(Schema.decodeUnknownExit(def.params as Schema.Codec<unknown>)(s.params ?? {}))) {
      return reject("validation.invalid", `step ${i}: invalid params for ${s.op}`)
    }
  }
  return undefined
}
