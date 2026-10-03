import { exports, RpcTarget, type WorkflowStep, type WorkflowStepConfig } from "cloudflare:workers"
import { NonRetryableError } from "cloudflare:workflows"
import { codeBundlePath, type CodeRef, type UsageRecord } from "@cmux/protocol"
import { CodeStorage, teamRepoName } from "./code-storage.ts"
import type { Env } from "./env.ts"
import type { RecordResult } from "./usage-meter-do.ts"

/**
 * Tier 1 runs (decisions A11, A13, A20): chief-written Workflows code at a
 * pinned commit runs in a Dynamic Worker (Worker Loader) inside the one
 * AutomationRunWorkflow. The run's own Workflow instance is the durable engine:
 * the tenant's `run(event, step)` gets a wrapped step that forwards to the real
 * one, so step results are journaled by Cloudflare and a replay re-enters the
 * tenant code with cached results. The wrapped step meters every step into the
 * team's UsageMeterDO and stops at the hard cap (A18, A21).
 *
 * The tenant isolate has no network (`globalOutbound: null`) and no bindings
 * until the egress gateway and env.cmux land (slice 4). Limits per invocation:
 * 10 s CPU, 1,000 subrequests.
 */

/** Abuse limits for code runs (automations-billing.md 5.5). */
export const CODE_LIMITS = { cpuMs: 10_000, subRequests: 1_000 } as const
export const MAX_STEPS_PER_RUN = 2_000
export const MAX_STEP_RETRIES = 5
/** The compatibility date tenant code runs with; bumped deliberately, never per tenant. */
export const TENANT_COMPATIBILITY_DATE = "2026-08-20"

export interface CodeRunInput {
  readonly team: string
  readonly run: string
  readonly automation: string
  readonly ref: CodeRef
  readonly input: unknown
}

/** A refusal the run reports as its final error. */
export class CodeRunError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

/** Loader ids this isolate has loaded once (code never changes under an id). */
const loaded = new Set<string>()

/** Test seam (ENVIRONMENT=test only): bundles by `<commit>:<path>` instead of code.storage. */
export const testBundles = new Map<string, string>()

const meterOf = (env: Env, team: string) => env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team))

const record = async (env: Env, team: string, records: ReadonlyArray<UsageRecord>): Promise<RecordResult> =>
  (await meterOf(env, team).record(team, records)) as unknown as RecordResult

/** The loader id: one Dynamic Worker per (environment, team, commit, path). Code never changes under an id. */
export const loaderId = (env: Env, team: string, ref: CodeRef) => `${teamRepoName(env.ENVIRONMENT, team)}:${ref.commit}:${ref.path}`

const loadBundle = async (env: Env, team: string, ref: CodeRef): Promise<string> => {
  if (env.ENVIRONMENT === "test") {
    const text = testBundles.get(`${ref.commit}:${ref.path}`)
    if (text === undefined) throw new CodeRunError("code.not_found", `${codeBundlePath(ref)} not found at ${ref.commit}`)
    return text
  }
  const r = await new CodeStorage(env).file(teamRepoName(env.ENVIRONMENT, team), ref.commit, codeBundlePath(ref))
  if (!r.ok) {
    // A missing or oversize bundle never appears on retry; an unavailable store may.
    if (r.code === "code.unavailable" && r.retryable) throw new Error(r.message)
    throw new CodeRunError(r.code, r.message)
  }
  return r.value.text
}

/**
 * The step object tenant code receives. It is an RpcTarget, so the tenant
 * isolate calls it across the loader boundary; its callbacks come back as RPC
 * stubs that run in the tenant isolate.
 */
export class WrappedStep extends RpcTarget {
  private steps = 0

  constructor(
    private readonly step: WorkflowStep,
    private readonly env: Env,
    private readonly run: CodeRunInput
  ) {
    super()
  }

  /** Local checks only (name, reserved prefix, step count): no I/O, so a replay stays cheap. */
  private admit(name: unknown): string {
    if (typeof name !== "string" || name.length === 0 || name.length > 200) throw new NonRetryableError("a step name must be 1 to 200 characters", "step.invalid")
    // Harness steps use the cmux: prefix; tenant steps never collide with them.
    if (name.startsWith("cmux:")) throw new NonRetryableError(`step names starting "cmux:" are reserved (${name})`, "step.invalid")
    this.steps++
    if (this.steps > MAX_STEPS_PER_RUN) throw new NonRetryableError(`a run may take at most ${MAX_STEPS_PER_RUN} steps`, "limit.steps")
    return name
  }

  /**
   * Meters one step and enforces the cap. Called when the step really executes (inside the
   * step callback, or before a sleep or wait), never for journaled steps on replay. One key per
   * step name: a retried attempt or a repeated sleep call counts once.
   */
  private async meter(kind: string, name: string): Promise<void> {
    const r = await record(this.env, this.run.team, [
      { key: `step:${this.run.run}:${kind}:${name}`, meter: "automation.steps", quantity: 1, source: "step", observed_at: Date.now(), run: this.run.run, automation: this.run.automation, step: name, commit: this.run.ref.commit }
    ])
    if (!r.allowed) throw new NonRetryableError(`the team's automation spending cap is reached (${r.summary.stopped})`, "budget.cap_reached")
  }

  async do(name: string, a: unknown, b?: unknown): Promise<unknown> {
    const callback = (typeof a === "function" ? a : b) as (ctx: unknown) => Promise<unknown>
    const given = (typeof a === "function" ? undefined : a) as WorkflowStepConfig | undefined
    if (typeof callback !== "function") throw new NonRetryableError("step.do needs a callback", "step.invalid")
    this.admit(name)
    const limit = Math.min(given?.retries?.limit ?? 3, MAX_STEP_RETRIES)
    const config: WorkflowStepConfig = { ...given, retries: { delay: given?.retries?.delay ?? 1000, backoff: given?.retries?.backoff ?? "exponential", limit } }
    // The callback context is not forwarded: it holds harness objects; tenant code gets the attempt only.
    return this.step.do(name, config, async (ctx) => {
      await this.meter("do", name)
      return (await callback({ attempt: (ctx as { attempt?: number }).attempt ?? 1 })) as never
    })
  }

  async sleep(name: string, duration: Parameters<WorkflowStep["sleep"]>[1]): Promise<void> {
    this.admit(name)
    await this.meter("sleep", name)
    return this.step.sleep(name, duration)
  }

  async sleepUntil(name: string, timestamp: Date | number): Promise<void> {
    this.admit(name)
    await this.meter("sleepUntil", name)
    return this.step.sleepUntil(name, timestamp)
  }

  async waitForEvent(name: string, options: { type: string; timeout?: number | string }): Promise<unknown> {
    this.admit(name)
    if (typeof options?.type !== "string" || options.type.startsWith("cmux:")) throw new NonRetryableError("event types starting \"cmux:\" are reserved", "step.invalid")
    await this.meter("waitForEvent", name)
    return this.step.waitForEvent(name, options as { type: string; timeout?: number })
  }
}

interface TenantEntrypoint {
  run(event: { payload: unknown; timestamp: Date; instanceId: string }, step: WrappedStep): Promise<unknown>
}

/**
 * Runs one code automation inside the run's Workflow. Called on every replay;
 * the loader keeps a warm Dynamic Worker per id, and the step journal makes the
 * re-entry cheap. Throws CodeRunError for refusals the run reports as failed.
 */
export const runCode = async (env: Env, step: WorkflowStep, run: CodeRunInput, startedAt: Date): Promise<unknown> => {
  if (!env.LOADER) throw new CodeRunError("body.unsupported", "this deployment has no Worker Loader binding")
  const gate = await meterOf(env, run.team).check(run.team)
  if (!(gate as { allowed: boolean }).allowed) throw new CodeRunError("budget.cap_reached", "the team's automation spending cap is reached")
  const id = loaderId(env, run.team, run.ref)
  const props = { team: run.team, run: run.run, automation: run.automation, commit: run.ref.commit }
  // The first load in this isolate fetches the bundle before the loader, so a missing or oversize
  // bundle fails as itself (an error thrown inside the loader's callback loses its code).
  const fetched = loaded.has(id) ? undefined : await loadBundle(env, run.team, run.ref)
  loaded.add(id)
  const worker = env.LOADER.get(id, async () => ({
    compatibilityDate: TENANT_COMPATIBILITY_DATE,
    mainModule: "index.js",
    modules: { "index.js": fetched ?? (await loadBundle(env, run.team, run.ref)) },
    env: {},
    globalOutbound: null,
    limits: CODE_LIMITS,
    tails: [(exports as unknown as { AutomationTail: (o: { props: typeof props }) => Fetcher }).AutomationTail({ props })]
  }))
  const day = new Date().toISOString().slice(0, 10)
  const now = Date.now()
  await record(env, run.team, [
    { key: `inv:${run.run}`, meter: "automation.invocations", quantity: 1, source: "scheduler", observed_at: now, run: run.run, automation: run.automation },
    // Cloudflare bills a unique Dynamic Worker (id + code) per day; the ledger counts the same.
    { key: `dw:${id}:${day}`, meter: "automation.dynamic_workers", quantity: 1, source: "scheduler", observed_at: now, automation: run.automation, commit: run.ref.commit }
  ])
  const entry = worker.getEntrypoint(run.ref.export) as unknown as TenantEntrypoint
  return entry.run({ payload: run.input ?? null, timestamp: startedAt, instanceId: run.run }, new WrappedStep(step, env, run))
}
