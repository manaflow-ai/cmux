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
 * 10 s CPU, 1,000 subrequests. The tenant module is wrapped by a harness module
 * whose first log line names the run, so the tail attributes CPU and logs to the
 * right run although one warm Dynamic Worker serves every run of the same code.
 */

/** Abuse limits for code runs (automations-billing.md 5.5). */
export const CODE_LIMITS = { cpuMs: 10_000, subRequests: 1_000 } as const
export const MAX_STEPS_PER_RUN = 2_000
export const MAX_STEP_RETRIES = 5
/** Longest single sleep or event wait (each holds a concurrency slot; ledger keys live 35 days). */
export const MAX_WAIT_MS = 30 * 24 * 3600_000
const MAX_RETRY_DELAY_MS = 3600_000
/** The compatibility date tenant code runs with; bumped deliberately, never per tenant. */
export const TENANT_COMPATIBILITY_DATE = "2026-08-20"
/** First log line of every harness invocation; AutomationTail reads it (automation-tail.ts). */
export const RUN_MARKER = "cmux.run"

export interface CodeRunInput {
  readonly team: string
  readonly run: string
  readonly automation: string
  readonly ref: CodeRef
  readonly input: unknown
}

/** A refusal the run reports as its final error (only the harness sets these codes, never tenant code). */
export class CodeRunError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

/** Loader ids this isolate has loaded once (code never changes under an id); bounded. */
const loaded = new Set<string>()
const MAX_LOADED_IDS = 1_000

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
  if (!r.ok) throw new CodeRunError(r.code, r.message)
  return r.value.text
}

/**
 * The marker module: the harness imports it before the tenant bundle, so it holds the
 * runtime's own console.log before any tenant module code runs. Tenant code can still
 * log lines that look like a marker, but not before the harness's first line of an
 * invocation, and the tail reads only that first line (automation-tail.ts).
 */
const MARKER_MODULE = `const log = console.log.bind(console);
export const mark = (...a) => log(...a);
`

/**
 * The harness module: it imports the marker and then the tenant bundle, logs the run
 * marker first, then runs the tenant's WorkflowEntrypoint class with the wrapped step.
 */
const harnessModule = (exportName: string) => `
import { WorkerEntrypoint } from "cloudflare:workers";
import { mark } from "./cmux-marker.js";
import * as tenant from "./tenant.js";
const Tenant = tenant[${JSON.stringify(exportName)}];
export class CmuxHarness extends WorkerEntrypoint {
  async run(meta, event, step) {
    mark(${JSON.stringify(RUN_MARKER)}, meta.run, meta.automation, meta.invocation);
    if (typeof Tenant !== "function") throw new Error("the export is not a WorkflowEntrypoint class");
    return new Tenant(this.ctx, this.env).run(event, step);
  }
}
`

/**
 * The identity of one tenant invocation, chosen by the API Worker when it calls the harness
 * (one call is one invocation, so one id). The tail keys usage on it, so a redelivered tail
 * carries the same marker and counts once. Runtime ids are not used for billing until a
 * staging redelivery proves them stable (automations-plan.md 2a).
 */
export const newInvocationId = (): string => {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  return `inv_${Array.from(crypto.getRandomValues(new Uint8Array(20)), (b) => alphabet[b % 36]).join("")}`
}

/** Validates tenant step config: plain object, bounded retries, delay and timeout. */
const stepConfig = (given: unknown): WorkflowStepConfig => {
  const c = given !== null && typeof given === "object" && !Array.isArray(given) ? (given as { retries?: { limit?: unknown; delay?: unknown; backoff?: unknown }; timeout?: unknown }) : {}
  const r = c.retries ?? {}
  const limit = typeof r.limit === "number" && Number.isFinite(r.limit) ? Math.max(0, Math.min(MAX_STEP_RETRIES, Math.floor(r.limit))) : 3
  const delay = typeof r.delay === "number" && Number.isFinite(r.delay) ? Math.max(0, Math.min(MAX_RETRY_DELAY_MS, r.delay)) : 1000
  const backoff = r.backoff === "constant" || r.backoff === "linear" ? r.backoff : "exponential"
  const timeout = typeof c.timeout === "number" && Number.isFinite(c.timeout) ? Math.max(1000, Math.min(15 * 60_000, c.timeout)) : 10 * 60_000
  return { retries: { limit, delay, backoff }, timeout }
}

const durationMs = (d: unknown): number | undefined => (typeof d === "number" && Number.isFinite(d) && d >= 0 ? d : undefined)

/**
 * The step object tenant code receives. It is an RpcTarget, so the tenant
 * isolate calls it across the loader boundary; its callbacks come back as RPC
 * stubs that run in the tenant isolate. State and helpers are `#` private:
 * TypeScript `private` methods would still be callable over RPC.
 */
export class WrappedStep extends RpcTarget {
  #steps = 0
  #occurrences = new Map<string, number>()
  /** Why the harness stopped the run; it wins over whatever the tenant returns or throws. */
  #stopped: CodeRunError | undefined
  readonly #step: WorkflowStep
  readonly #env: Env
  readonly #run: CodeRunInput

  constructor(step: WorkflowStep, env: Env, run: CodeRunInput) {
    super()
    this.#step = step
    this.#env = env
    this.#run = run
  }

  /** Harness view of the stop reason (no secret: the same code and message the tenant saw). */
  stopReason(): CodeRunError | undefined {
    return this.#stopped
  }

  #stop(code: string, message: string): never {
    this.#stopped ??= new CodeRunError(code, message)
    throw new NonRetryableError(message, code)
  }

  /** Local checks only (name, reserved prefix, step count): no I/O, so a replay stays cheap. Returns the occurrence key. */
  #admit(kind: string, name: unknown): string {
    if (this.#stopped) throw new NonRetryableError(this.#stopped.message, this.#stopped.code)
    if (typeof name !== "string" || name.length === 0 || name.length > 200) this.#stop("step.invalid", "a step name must be 1 to 200 characters")
    // Harness steps use the cmux: prefix; tenant steps never collide with them.
    if (name.startsWith("cmux:")) this.#stop("step.invalid", `step names starting "cmux:" are reserved (${name})`)
    this.#steps++
    if (this.#steps > MAX_STEPS_PER_RUN) this.#stop("limit.steps", `a run may take at most ${MAX_STEPS_PER_RUN} steps`)
    // The engine numbers repeated names; so do we, in call order, which a replay repeats exactly.
    const n = (this.#occurrences.get(`${kind}:${name}`) ?? 0) + 1
    this.#occurrences.set(`${kind}:${name}`, n)
    return `${kind}:${name}#${n}`
  }

  /**
   * Meters one step and enforces the cap. Called when the step really executes (inside the
   * step callback, or before a sleep or wait). One key per step occurrence: a retried attempt
   * or a replayed sleep counts once. The key holds a hash of the tenant's step name, so its
   * length never depends on tenant input; a record the ledger refuses stops the run (a step
   * must never run unmetered). `inStep`: a meter outage inside step.do is a plain error the
   * engine retries; outside (sleeps, waits) it stops the run.
   */
  async #meter(occurrence: string, name: string, inStep: boolean): Promise<void> {
    const [kind, , n] = [occurrence.slice(0, occurrence.indexOf(":")), "", occurrence.slice(occurrence.lastIndexOf("#") + 1)]
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(name)))
    const hash = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("")
    let r: RecordResult
    try {
      r = await record(this.#env, this.#run.team, [
        { key: `step:${this.#run.run}:${kind}:${hash}#${n}`, meter: "automation.steps", quantity: 1, source: "step", observed_at: Date.now(), run: this.#run.run, automation: this.#run.automation, step: name, commit: this.#run.ref.commit }
      ])
    } catch (e) {
      const message = `usage meter unavailable: ${e instanceof Error ? e.message : String(e)}`
      if (inStep) throw new Error(message)
      this.#stop("meter.unavailable", message)
    }
    if (r!.invalid > 0 || r!.too_large) this.#stop("meter.invalid", "the usage ledger refused this step's record")
    if (!r!.allowed) this.#stop("budget.cap_reached", `the team's automation spending cap is reached (${r!.summary.stopped})`)
  }

  async do(name: string, a: unknown, b?: unknown): Promise<unknown> {
    const callback = (typeof a === "function" ? a : b) as (ctx: unknown) => Promise<unknown>
    if (typeof callback !== "function") this.#stop("step.invalid", "step.do needs a callback")
    const occurrence = this.#admit("do", name)
    // The callback context is not forwarded: it holds harness objects; tenant code gets the attempt only.
    return this.#step.do(name, stepConfig(typeof a === "function" ? undefined : a), async (ctx) => {
      await this.#meter(occurrence, name, true)
      return (await callback({ attempt: (ctx as { attempt?: number }).attempt ?? 1 })) as never
    })
  }

  async sleep(name: string, duration: unknown): Promise<void> {
    const occurrence = this.#admit("sleep", name)
    const ms = durationMs(duration)
    if (ms === undefined || ms > MAX_WAIT_MS) this.#stop("step.invalid", `sleep takes a number of milliseconds up to ${MAX_WAIT_MS}`)
    await this.#meter(occurrence, name, false)
    return this.#step.sleep(name, ms)
  }

  async sleepUntil(name: string, timestamp: unknown): Promise<void> {
    const occurrence = this.#admit("sleepUntil", name)
    const at = timestamp instanceof Date ? timestamp.getTime() : durationMs(timestamp)
    if (at === undefined || at - Date.now() > MAX_WAIT_MS) this.#stop("step.invalid", `sleepUntil takes an instant at most ${MAX_WAIT_MS} ms ahead`)
    await this.#meter(occurrence, name, false)
    return this.#step.sleepUntil(name, at)
  }

  async waitForEvent(name: string, options: unknown): Promise<unknown> {
    const occurrence = this.#admit("waitForEvent", name)
    const o = (options ?? {}) as { type?: unknown; timeout?: unknown }
    if (typeof o.type !== "string" || o.type.length === 0 || o.type.length > 100 || o.type.startsWith("cmux:")) this.#stop("step.invalid", "an event type is 1 to 100 characters and never starts with \"cmux:\"")
    const timeout = o.timeout === undefined ? 24 * 3600_000 : durationMs(o.timeout)
    if (timeout === undefined || timeout > MAX_WAIT_MS) this.#stop("step.invalid", `waitForEvent timeout is a number of milliseconds up to ${MAX_WAIT_MS}`)
    await this.#meter(occurrence, name, false)
    return this.#step.waitForEvent(name, { type: o.type as string, timeout })
  }
}

interface HarnessEntrypoint {
  run(meta: { run: string; automation: string; invocation: string }, event: { payload: unknown; timestamp: Date; instanceId: string }, step: WrappedStep): Promise<unknown>
}

/**
 * Runs one code automation inside the run's Workflow. Called on every replay;
 * the loader keeps a warm Dynamic Worker per id, and the step journal makes the
 * re-entry cheap. Throws CodeRunError for refusals the run reports as failed;
 * the harness's own stop reason wins over anything tenant code throws or returns.
 */
export const runCode = async (env: Env, step: WorkflowStep, run: CodeRunInput, startedAt: Date): Promise<unknown> => {
  if (!env.LOADER) throw new CodeRunError("body.unsupported", "this deployment has no Worker Loader binding")
  const id = loaderId(env, run.team, run.ref)
  // Gate and start record in one harness step: the engine retries a short meter outage.
  const allowed = await step.do("cmux:start", { retries: { limit: 5, delay: 1000, backoff: "exponential" } }, async () => {
    const day = new Date().toISOString().slice(0, 10)
    const r = await record(env, run.team, [
      // Cloudflare bills a unique Dynamic Worker (id + code) per day; the ledger counts the same.
      { key: `dw:${id}:${day}`, meter: "automation.dynamic_workers", quantity: 1, source: "scheduler", observed_at: Date.now(), automation: run.automation, commit: run.ref.commit }
    ])
    return r.allowed
  })
  if (!allowed) throw new CodeRunError("budget.cap_reached", "the team's automation spending cap is reached")
  // The first load in this isolate fetches the bundle before the loader, so a missing or oversize
  // bundle fails as itself (an error thrown inside the loader's callback loses its code).
  const fetched = loaded.has(id) ? undefined : await loadBundle(env, run.team, run.ref)
  if (loaded.size >= MAX_LOADED_IDS) loaded.clear()
  loaded.add(id)
  const props = { team: run.team, commit: run.ref.commit }
  const worker = env.LOADER.get(id, async () => ({
    compatibilityDate: TENANT_COMPATIBILITY_DATE,
    mainModule: "harness.js",
    modules: { "harness.js": harnessModule(run.ref.export ?? "default"), "cmux-marker.js": MARKER_MODULE, "tenant.js": fetched ?? (await loadBundle(env, run.team, run.ref)) },
    env: {},
    globalOutbound: null,
    limits: CODE_LIMITS,
    tails: [(exports as unknown as { AutomationTail: (o: { props: typeof props }) => Fetcher }).AutomationTail({ props })]
  }))
  const wrapped = new WrappedStep(step, env, run)
  const entry = worker.getEntrypoint("CmuxHarness") as unknown as HarnessEntrypoint
  let result: unknown
  try {
    result = await entry.run({ run: run.run, automation: run.automation, invocation: newInvocationId() }, { payload: run.input ?? null, timestamp: startedAt, instanceId: run.run }, wrapped)
  } catch (e) {
    throw wrapped.stopReason() ?? e
  }
  // Tenant code may catch the harness's stop and return normally; the stop still ends the run.
  const stopped = wrapped.stopReason()
  if (stopped) throw stopped
  return result
}
