import type { OutboxItem } from "@cmux/ownership"
import type { RunRow } from "./scheduler-rows.ts"

/**
 * A notice to the creator's Feed when a run fails (spec AUTOMATIONS-SPEC section 12, models-scout):
 * the Feed already pushes to the person's devices. One item per run (the outbox key), and one Feed
 * thread per automation (dedupe_key), so a failing schedule updates one item instead of piling up.
 * A run skipped because its machine was not running (machine_not_running) is no failure: no notice.
 * Exit codes of a command: 3 = a check failed, 1 = a crash.
 */
export const failureNotice = (run: Pick<RunRow, "id" | "automation" | "state" | "error">, a: { readonly name: string; readonly created_by: string | undefined }): OutboxItem | null => {
  if ((run.state !== "failed" && run.state !== "dead") || !a.created_by) return null
  const error = run.error ?? { code: "run.failed", message: "" }
  return {
    kind: "feed.post",
    entity: `automation-failed:${run.id}`,
    target: { class: "FeedDO", name: a.created_by },
    payload: {
      type: "notice",
      kind: "notice",
      title: `${a.name}: ${what(run.state, error)}`.slice(0, 200),
      body: `${error.message || error.code}\n\nRun ${run.id}. See it with: cmux automation history ${a.name} --target cloud; its log: cmux automation logs ${run.id} --target cloud`.slice(0, 4096),
      priority: "high",
      dedupe_key: `automation-failed:${run.automation}`,
      thread: `automation:${run.automation}`,
      poster: { label: "Automations" }
    }
  }
}

const what = (state: string, e: { readonly code: string; readonly message: string }): string => {
  if (state === "dead") return "stopped without a result"
  if (e.code === "machine.timeout" || e.code === "budget.wall_clock" || e.code === "run.deadline") return "timed out"
  if (e.code === "machine.exit") {
    const exit = /\bexit (\d+)/.exec(e.message)?.[1]
    if (exit === "3") return "a check failed"
    if (exit === "1") return "crashed"
  }
  return "failed"
}
