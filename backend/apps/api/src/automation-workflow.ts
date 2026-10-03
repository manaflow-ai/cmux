import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers"
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

    await report("start", { state: "running", step: -1 })
    try {
      if (p.body.type === "agent_prompt") {
        await report("unsupported", {
          state: "failed",
          step: -1,
          error: { code: "body.unsupported", message: "agent_prompt runs need the mux (MuxDO) and machine placement, which this backend does not have yet" }
        })
        return
      }
      if (p.body.type === "code") {
        // Tier 1 loader (Dynamic Workers) lands after the usage ledger and the hard cap (automations-plan.md slices 2-3):
        // no tenant code runs before its usage is metered and capped.
        await report("unsupported", {
          state: "failed",
          step: -1,
          error: { code: "body.unsupported", message: "code runs need the Tier 1 loader, which this backend does not have yet" }
        })
        return
      }
      const steps = p.body.steps
      for (let i = 0; i < steps.length; i++) {
        const s = steps[i]!
        switch (s.type) {
          case "sleep":
            await report(`sleeping-${i}`, { state: "sleeping", step: i - 1 })
            await step.sleep(`sleep-${i}`, s.seconds * 1000)
            break
          case "note":
            break
        }
        await report(`done-${i}`, { state: "running", step: i })
      }
      await report("finish", { state: "succeeded", step: steps.length - 1 })
    } catch (e) {
      await report("fail", { state: "failed", step: -1, error: { code: "run.failed", message: String(e).slice(0, 500) } })
    }
  }
}
