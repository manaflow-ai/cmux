import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers"
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
    const report = (name: string, r: Omit<RunReport, "run">) =>
      step.do(name, async () => {
        const stub = this.env.SCHEDULER_DO.get(this.env.SCHEDULER_DO.idFromName(p.owner))
        const res = (await stub.reportRun(p.owner, { run: p.run, ...r })) as { ok: boolean; code?: string }
        // A pruned or unknown run cannot take reports; retrying would not help.
        if (!res.ok && res.code !== "selector.not_found") throw new Error(`run.report refused: ${res.code}`)
        return res.ok
      })

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
          await runCode(this.env, step, { team: p.owner, run: p.run, automation: p.automation, ref: p.body.ref, input: p.input }, event.timestamp)
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
        }
        await report(`cmux:done-${i}`, { state: "running", step: i })
      }
      await report("cmux:finish", { state: "succeeded", step: steps.length - 1 })
    } catch (e) {
      await report("cmux:fail", { state: "failed", step: -1, error: { code: "run.failed", message: String(e).slice(0, 500) } })
    }
  }
}
