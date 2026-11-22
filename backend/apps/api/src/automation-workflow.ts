import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers"
import { callCapability } from "./automation-caps.ts"
import { CodeRunError, runCode } from "./code-run.ts"
import type { Env } from "./env.ts"
import type { AutomationRunParams, RunReport } from "./scheduler-do.ts"

/**
 * One automation run (decision D13: the Workflow owns the run: steps, sleeps,
 * waits, retries). Progress goes back to the owner SchedulerDO as `run.report`
 * system ops inside durable steps, so a replayed step reports with the same key.
 */
export class AutomationRunWorkflow extends WorkflowEntrypoint<Env, AutomationRunParams> {
  override async run(event: Readonly<WorkflowEvent<AutomationRunParams>>, step: WorkflowStep): Promise<void> {
    const p = event.payload
    const report = async (name: string, r: Omit<RunReport, "run">) => {
      const res = await step.do(name, async () => {
        const stub = this.env.SCHEDULER_DO.get(this.env.SCHEDULER_DO.idFromName(p.owner))
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
      if (p.body.type === "code") {
        // Tier 1: the tenant's Workflows code in a Dynamic Worker, metered and capped (code-run.ts).
        try {
          await runCode(this.env, step, { team: p.owner, run: p.run, automation: p.automation, ref: p.body.ref, egress: p.body.egress ?? [], input: p.input }, event.timestamp)
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
              const out = await callCapability(this.env, { team: p.owner, run: p.run, automation: p.automation }, s.op, s.params, `step:${p.run}:${i}`)
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

/** The owner already ended the run; the Workflow returns without reporting again. */
class RunStopped extends Error {}
