import type { Step as StepSchema } from "@cmux/protocol"
import { asDaemonUser, layoutSelector, shellQuote } from "./cloud-acpmux-guest.ts"
import { SECRETS_READER, secretsLine } from "./automation-secrets-wire.ts"

/**
 * Machine and agent steps of an automation run (org workflows,
 * plans/cmux-next/org-workflows-DESIGN.md). A step runs one fixed command on one of the run's
 * team's own Cloud machines through CloudDO (`automationExec`); the Workflow journals the
 * result inside `step.do`, so a replay reads the journal and never runs the command again.
 *
 * Determinism: the command is a pure function of the step and (run, index). Free text (an agent
 * prompt, an earlier step's output) goes on stdin, never into the command string the provider
 * gets; on the guest the prompt becomes one argument after `--` (it is visible in the guest's own
 * process list, which only the team can read). An unattended agent turn fails on a permission
 * request instead of waiting, and acpmux cancels it 10 s before the step timeout.
 *
 * A step runs at most once: no automatic retry, because a lost answer does not prove the command
 * did not start. Guest scripts can dedupe their own effects with CMUX_STEP_KEY.
 */
type Step = typeof StepSchema.Type
export type MachineStep = Extract<Step, { readonly type: "machine" }>
export type AgentStep = Extract<Step, { readonly type: "agent" }>
export type MachineLikeStep = MachineStep | AgentStep

/** The journaled output of a step: the last 8 KiB of its stdout. */
export const STEP_OUTPUT_MAX = 8192

export type MachineExecRefusal = "not_found" | "not_running" | "forbidden" | "provider_failed" | "output_limit"
export type MachineExecReply =
  | { readonly ok: true; readonly exitCode: number; readonly stdout: string; readonly stderr: string }
  | { readonly ok: false; readonly refusal: MachineExecRefusal }

/** One guest exec on a machine of the run's team (CloudDO.automationExec in production). */
export interface MachineExec {
  exec(machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply>
}

export type StepOutcome =
  | { readonly ok: true; readonly output: string }
  | { readonly ok: false; readonly code: "machine.exit" | "machine.timeout" | "machine.not_found" | "machine.not_running" | "machine.forbidden" | "machine.unavailable" | "machine.output_limit"; readonly message: string }

export const isMachineLikeStep = (s: Step): s is MachineLikeStep => s.type === "machine" || s.type === "agent"

/** The guest command of step `index` of `run`: as the machine's work user, with the run, step and idempotency key. */
export const machineStepCommand = (step: MachineLikeStep, ctx: { readonly run: string; readonly index: number }, secrets = false): string => {
  const ids = `CMUX_RUN=${shellQuote(ctx.run)} CMUX_STEP=${ctx.index} CMUX_STEP_KEY=${shellQuote(`step:${ctx.run}:${ctx.index}`)}`
  // The harness is one of three literals, so it is safe in the command; the prompt never is.
  const own = step.type === "machine" ? step.command : `p="$(cat)"; PATH="$HOME/.local/bin:$PATH" exec acpmux run -m ${step.harness} --on-permission fail --timeout ${Math.max(1, step.timeout_seconds - 10)} -- "$p"`
  // With secrets, the first stdin line carries them (automation-secrets-wire.ts); the command line never does.
  const body = secrets ? `${SECRETS_READER}${own}` : own
  return `${layoutSelector()}; ${asDaemonUser(`${ids} bash -lc ${shellQuote(body)}`, { exec: true })}`
}

/** What the step reads on stdin: the agent prompt, then the input step's journaled output. */
export const machineStepStdin = (step: MachineLikeStep, input: string | null, secrets?: Readonly<Record<string, string>>): Uint8Array | null => {
  const text = step.type === "agent" ? (input === null ? step.prompt : `${step.prompt}\n\nInput:\n${input}`) : input
  if (secrets) return new TextEncoder().encode(`${secretsLine(secrets)}\n${text ?? ""}`)
  return text === null ? null : new TextEncoder().encode(text)
}

const lastLine = (s: string) => s.trimEnd().split("\n").pop()?.slice(0, 300) ?? ""

/** Runs one step through the port and maps the answer to a journaled outcome. */
export const runMachineStep = async (port: MachineExec, step: MachineLikeStep, ctx: { readonly run: string; readonly index: number }, input: string | null, secrets?: Readonly<Record<string, string>>): Promise<StepOutcome> => {
  const some = secrets && Object.keys(secrets).length > 0 ? secrets : undefined
  const r = await port.exec(step.machine, machineStepCommand(step, ctx, Boolean(some)), machineStepStdin(step, input, some), step.timeout_seconds * 1000)
  if (!r.ok) {
    if (r.refusal === "not_found") return { ok: false, code: "machine.not_found", message: `step ${ctx.index}: ${step.machine} is not a machine of this team` }
    if (r.refusal === "forbidden") return { ok: false, code: "machine.forbidden", message: `step ${ctx.index}: only automations of ${step.machine}'s creator may run commands on it` }
    if (r.refusal === "not_running") return { ok: false, code: "machine.not_running", message: `step ${ctx.index}: ${step.machine} is not running` }
    if (r.refusal === "output_limit") return { ok: false, code: "machine.output_limit", message: `step ${ctx.index}: the command's output exceeded the response limit` }
    return { ok: false, code: "machine.unavailable", message: `step ${ctx.index}: the machine did not answer` }
  }
  if (r.exitCode === 124) return { ok: false, code: "machine.timeout", message: `step ${ctx.index}: timed out after ${step.timeout_seconds} s` }
  if (r.exitCode !== 0) return { ok: false, code: "machine.exit", message: `step ${ctx.index}: exit ${r.exitCode}: ${lastLine(r.stderr) || lastLine(r.stdout)}` }
  return { ok: true, output: r.stdout.slice(-STEP_OUTPUT_MAX) }
}

/** Why step `i`'s `input_from` is invalid, or undefined: it must name an earlier machine or agent step. */
export const invalidStepRef = (steps: ReadonlyArray<Step>, i: number): string | undefined => {
  const s = steps[i]
  if (!s || !isMachineLikeStep(s) || s.input_from === undefined) return undefined
  if (s.input_from >= i) return `step ${i}: input_from must name an earlier step`
  const from = steps[s.input_from]
  if (!from || !isMachineLikeStep(from)) return `step ${i}: input_from must name a machine or agent step`
  return undefined
}

/**
 * Waking a stopped machine before a run (spec AUTOMATIONS-SPEC section 12). Freestyle machines stay
 * up unless a person pauses them (auto-pause.ts), so a run can find its machine paused. The run
 * starts it as the automation's creator (cloud.machine.start is a person's op, the same as the
 * Chief's own wake in chief-brain/brain-machine.ts) and waits, in journaled sleeps, until it runs.
 * A machine that does not come up is no failure of the automation: the run is skipped with reason
 * `machine_not_running`, so it sends no failure notice and does not count as a failed run.
 */
export interface MachinePower {
  get(machine: string): Promise<{ readonly ok: true; readonly status: string; readonly revision: string } | { readonly ok: false; readonly code: string }>
  start(machine: string, key: string): Promise<{ readonly ok: true } | { readonly ok: false; readonly code: string }>
}

/** The part of a Workflow step the wake uses (a journaled call and a journaled sleep). */
export interface StepLike {
  do<T>(name: string, fn: () => Promise<T>): Promise<T>
  sleep(name: string, ms: number): Promise<void>
}

export type WakeState = "running" | "starting" | "unavailable"

/** How often a starting machine is checked, and how many checks before the run gives up (about 5 min). */
export const WAKE_POLL_MS = 15_000
export const WAKE_POLLS = 20

const WAITING = new Set(["starting", "pausing", "provisioning"])

/** One check: running, starting (a start was asked for or is under way), or unavailable (cannot run). */
export const wakeOnce = async (power: MachinePower, machine: string, run: string): Promise<WakeState> => {
  const m = await power.get(machine)
  if (!m.ok) return "unavailable"
  if (m.status === "running") return "running"
  if (WAITING.has(m.status)) return "starting"
  if (m.status !== "paused") return "unavailable"
  // The key holds the revision: a machine paused again later in the run is started again, a replay is not.
  const s = await power.start(machine, `automation-wake:${run}:${machine}:${m.revision}`)
  return s.ok ? "starting" : "unavailable"
}

/** Wakes `machine` and waits for it; false when it will not run (no creator to start it as, refused, or not up in time). */
export const awaitMachine = async (step: StepLike, power: MachinePower | null, machine: string, run: string): Promise<boolean> => {
  if (!power) return false
  for (let i = 0; i < WAKE_POLLS; i++) {
    const s = await step.do(`cmux:wake-${machine}-${i}`, () => wakeOnce(power, machine, run))
    if (s === "running") return true
    if (s === "unavailable") return false
    await step.sleep(`cmux:wake-wait-${machine}-${i}`, WAKE_POLL_MS)
  }
  return false
}

/** How a failed machine or agent step ends its run: a stopped machine skips it, anything else fails it. */
export const stepFailureReport = (r: Extract<StepOutcome, { ok: false }>): { state: "skipped" | "failed"; error: { code: string; message: string } } =>
  r.code === "machine.not_running" ? { state: "skipped", error: { code: "machine_not_running", message: r.message } } : { state: "failed", error: { code: r.code, message: r.message } }
