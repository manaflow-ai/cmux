import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers"
import { callCapability } from "./automation-caps.ts"
import { brainName } from "./chief-brain/brain-do.ts"
import type { JobDelivery } from "./chief-brain-cc/jobs.ts"
import {
  runMachineStep,
  type MachineExec,
  type StepOutcome,
  awaitMachine,
  stepFailureReport,
  type MachinePower,
} from "./automation-machine.ts";
import type { Principal } from "@cmux/ownership"
import { CodeRunError, runCode } from "./code-run.ts"
import type { Env, RawEnv } from "./env.ts"
import { parseBuildSpace, spacedEnv } from "./build-space.ts"
import { UNATTRIBUTED_USER } from "./usage-user.ts"
import type { AutomationRunParams, RunReport } from "./scheduler-do.ts"
import { platformCloud } from "./platform-cloud.ts"
import { declared } from "./do-stub.ts"

/**
 * One automation run (decision D13: the Workflow owns the run: steps, sleeps,
 * waits, retries). Progress goes back to the owner SchedulerDO as `run.report`
 * system ops inside durable steps, so a replayed step reports with the same key.
 */
export class AutomationRunWorkflow extends WorkflowEntrypoint<RawEnv, AutomationRunParams> {
  override async run(event: Readonly<WorkflowEvent<AutomationRunParams>>, step: WorkflowStep): Promise<void> {
    const p = event.payload
    // The run reaches its scheduler's build space (SchedulerDO puts a dev space in the params; build-space.ts).
    const space = parseBuildSpace(p.space)
    if (space === null) throw new Error("automation run: params name no build space")
    const env: Env = spacedEnv(this.env, space)
    const report = async (name: string, r: Omit<RunReport, "run">) => {
      const res = await step.do(name, async () => {
        const stub = env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(p.owner))
        const out = (await stub.reportRun(p.owner, { run: p.run, ...r })) as { ok: boolean; code?: string; stopped?: boolean }
        // A pruned or unknown run cannot take reports; retrying would not help.
        if (!out.ok && out.code !== "selector.not_found") throw new Error(`run.report refused: ${out.code}`)
        return { ok: out.ok, stopped: out.stopped === true }
      })
      // The owner ended this run (cancelled): stop here, with no further steps or reports.
      if (res.stopped) throw new RunStopped()
      return res.ok
    }

    await report("cmux:start-report", { state: "running", step: -1 })
    try {
      if (p.body.type === "agent_prompt") {
        await report("cmux:unsupported", {
          state: "failed",
          step: -1,
          error: { code: "body.unsupported", message: "agent_prompt runs need the mux (MuxDO) and machine placement, which this backend does not have yet" }
        })
        return
      }
      if (p.body.type === "chief") {
        // A Chief's job (chief-brain-cc/jobs.ts): hand the prompt to the Chief's conversation brain once
        // (journaled; the brain keys it by run). The Chief's own turn does the work and posts the result.
        const body = p.body
        const r: JobDelivery = await step.do("cmux:chief", { retries: { limit: 5, delay: 2000, backoff: "exponential" } }, async () => {
          const brain = declared(env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(body.chief, body.conversation))))
          const out = await brain.chiefJob({ run: p.run, automation: p.automation, chief: body.chief, conversation: body.conversation, prompt: body.prompt, ...(body.destination ? { destination: body.destination } : {}), trigger: p.trigger.type, ...(p.input === undefined ? {} : { input: p.input }), charged_user: p.charged_user ?? null })
          if (!out.ok && out.retry) throw new Error(`${out.code}: ${out.message}`)
          return out
        })
        if (!r.ok) {
          await report("cmux:chief-failed", { state: "failed", step: -1, error: { code: r.code, message: r.message.slice(0, 500) } })
          return
        }
        await report("cmux:finish", { state: "succeeded", step: 0, outcome: { goal_met: true, summary: "handed to the Chief; its reply is in the chat" } })
        return
      }
      if (p.body.type === "code") {
        // Tier 1: the tenant's Workflows code in a Dynamic Worker, metered and capped (code-run.ts).
        try {
          await runCode(env, step, { team: p.owner, run: p.run, automation: p.automation, ref: p.body.ref, egress: p.body.egress ?? [], input: p.input, user: p.charged_user ?? UNATTRIBUTED_USER }, event.timestamp)
        } catch (e) {
          // Only harness refusals carry a code; a tenant error name never chooses the run's error code.
          const code = e instanceof CodeRunError ? e.code : "run.failed"
          await report("cmux:fail", { state: "failed", step: -1, error: { code, message: String(e instanceof Error ? e.message : e).slice(0, 500) } })
          return
        }
        await report("cmux:finish", { state: "succeeded", step: -1 })
        return
      }
      const steps = p.body.steps
      // Journaled outputs of machine and agent steps (a replay refills this from the journal).
      const outputs = new Map<number, string>()
      // Machines this run already found running (each is woken before its first step).
      const awake = new Set<string>()
      const journal = { do: <T,>(name: string, fn: () => Promise<T>) => step.do(name, fn as () => Promise<any>) as Promise<T>, sleep: (name: string, ms: number) => step.sleep(name, ms) }
      for (let i = 0; i < steps.length; i++) {
        const s = steps[i]!
        switch (s.type) {
          case "sleep":
            await report(`cmux:sleeping-${i}`, { state: "sleeping", step: i - 1 })
            await step.sleep(`cmux:sleep-${i}`, s.seconds * 1000)
            break
          case "note":
            break
          case "op": {
            // One capability op as the automation; the key makes a replayed or retried step happen once.
            const r = await step.do(`cmux:op-${i}`, { retries: { limit: 3, delay: 1000, backoff: "exponential" } }, async () => {
              const out = await callCapability(env, { team: p.owner, run: p.run, automation: p.automation }, s.op, s.params, `step:${p.run}:${i}`)
              // A retryable refusal (owner unreachable, rate limit) throws so the engine retries; others end the run.
              if (!out.ok && (out.code === "owner.unreachable" || out.code === "rate.limited")) throw new Error(`${out.code}: ${out.message}`)
              return out.ok ? { ok: true as const } : { ok: false as const, code: out.code, message: out.message }
            })
            if (!r.ok) {
              await report(`cmux:op-failed-${i}`, { state: "failed", step: i - 1, error: { code: r.code, message: r.message.slice(0, 500) } })
              return
            }
            break
          }
          case "machine":
          case "agent": {
            // One command on one of the team's machines (org-workflows-DESIGN.md 4.2). The result is
            // journaled, so a replay never runs it again. No automatic retry: a lost answer does not
            // prove the command did not start (run.retry makes a new run).
            if (!awake.has(s.machine)) {
              // A stopped machine is started first (as the automation's creator); one that does not come up skips the run.
              if (!(await awaitMachine(journal, machinePowerFor(env, p.owner, p.charged_user ?? null), s.machine, p.run))) {
                await report(`cmux:${s.type}-not-running-${i}`, { state: "skipped", step: i - 1, error: { code: "machine_not_running", message: `step ${i}: ${s.machine} is not running and did not start` } })
                return
              }
              awake.add(s.machine)
            }
            const input = s.input_from === undefined ? null : (outputs.get(s.input_from) ?? null)
            const r: StepOutcome = await step.do(`cmux:${s.type}-${i}`, { retries: { limit: 0, delay: 1000, backoff: "constant" }, timeout: (s.timeout_seconds + 60) * 1000 }, async () =>
              // The automation's secrets are opened here, inside the step, and go on its stdin: never in the journal.
              // Both reach the run's build space through `env` (spacedEnv), not the raw `this.env`.
              runMachineStep(machineExecFor(env, p.owner, p.charged_user ?? null), s, { run: p.run, index: i }, input, await runSecretsFor(env, p.owner, p.run))
            )
            if (!r.ok) {
              const end = stepFailureReport(r)
              await report(`cmux:${s.type}-failed-${i}`, { state: end.state, step: i - 1, error: { code: end.error.code, message: end.error.message.slice(0, 500) } })
              return
            }
            outputs.set(i, r.output)
            break
          }
        }
        await report(`cmux:done-${i}`, { state: "running", step: i })
      }
      await report("cmux:finish", { state: "succeeded", step: steps.length - 1 })
    } catch (e) {
      if (e instanceof RunStopped) return
      await report("cmux:fail", { state: "failed", step: -1, error: { code: "run.failed", message: String(e).slice(0, 500) } }).catch((x) => {
        if (!(x instanceof RunStopped)) throw x
      })
    }
  }
}

/** The run team's CloudDO as the machine port (automationExec). */
const machineExecFor = (env: Env, team: string, user: string | null): MachineExec => {
  const stub = platformCloud(env.CLOUD_DO, team)
  return { exec: (machine, command, stdin, timeoutMs) => stub.automationExec(team, user, machine, command, stdin, timeoutMs) }
}

/** The opened secrets of the run's automation (SchedulerDO.runSecrets; empty when it has none or the run ended). */
const runSecretsFor = (env: Env, team: string, run: string): Promise<Record<string, string>> =>
  (env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(team)) as unknown as { runSecrets(entity: string, run: string): Promise<Record<string, string>> }).runSecrets(team, run)

/**
 * The team's CloudDO as the machine's power switch, as the automation's creator (a person: cloud.machine.start
 * is a person's op, as for the Chief's own wake). A run with no creator (an old row) cannot start a machine.
 */
const machinePowerFor = (env: Env, team: string, user: string | null): MachinePower | null => {
  if (!user || user === UNATTRIBUTED_USER) return null
  const cloud = platformCloud(env.CLOUD_DO, team)
  const principal: Principal = { identity: `session:${user}`, kind: "session", user, team }
  return {
    get: async (machine) => {
      const r = await cloud.readOp(team, principal, "cloud.machine.get", { machine })
      if (!r.ok) return { ok: false, code: r.code }
      return { ok: true, status: String((r.value as { status?: unknown } | null)?.status ?? ""), revision: r.revision }
    },
    start: async (machine, key) => {
      const reply = await cloud.submit(team, principal, { t: "op", op: "cloud.machine.start", params: { machine }, idempotency_key: key, origin: "script" })
      const f = reply.frames.find((x) => x.t === "result" || x.t === "reject")
      if (f && f.t === "result") return { ok: true }
      return { ok: false, code: f && f.t === "reject" ? f.code : "cloud.machine.start_unavailable" }
    }
  }
}

/** The owner already ended the run; the Workflow returns without reporting again. */
class RunStopped extends Error {}
