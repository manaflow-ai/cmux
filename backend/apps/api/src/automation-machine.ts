import type { Step as StepSchema } from "@cmux/protocol"
import { asDaemonUser, layoutSelector, shellQuote } from "./cloud-acpmux-guest.ts"

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
export const machineStepCommand = (step: MachineLikeStep, ctx: { readonly run: string; readonly index: number }): string => {
  const ids = `CMUX_RUN=${shellQuote(ctx.run)} CMUX_STEP=${ctx.index} CMUX_STEP_KEY=${shellQuote(`step:${ctx.run}:${ctx.index}`)}`
  // The harness is one of three literals, so it is safe in the command; the prompt never is.
  const body = step.type === "machine" ? step.command : `p="$(cat)"; PATH="$HOME/.local/bin:$PATH" exec acpmux run -m ${step.harness} --on-permission fail --timeout ${Math.max(1, step.timeout_seconds - 10)} -- "$p"`
  return `${layoutSelector()}; ${asDaemonUser(`${ids} bash -lc ${shellQuote(body)}`, { exec: true })}`
}

/** What the step reads on stdin: the agent prompt, then the input step's journaled output. */
export const machineStepStdin = (step: MachineLikeStep, input: string | null): Uint8Array | null => {
  const text = step.type === "agent" ? (input === null ? step.prompt : `${step.prompt}\n\nInput:\n${input}`) : input
  return text === null ? null : new TextEncoder().encode(text)
}

const lastLine = (s: string) => s.trimEnd().split("\n").pop()?.slice(0, 300) ?? ""

/** Runs one step through the port and maps the answer to a journaled outcome. */
export const runMachineStep = async (port: MachineExec, step: MachineLikeStep, ctx: { readonly run: string; readonly index: number }, input: string | null): Promise<StepOutcome> => {
  const r = await port.exec(step.machine, machineStepCommand(step, ctx), machineStepStdin(step, input), step.timeout_seconds * 1000)
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
