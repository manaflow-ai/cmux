import type { Reject } from "@cmux/ownership"

/**
 * Per-team abuse limits of the SchedulerDO (automations-billing.md 5.5,
 * decision A18). Pure: time comes from the reducer's `ctx.now`.
 */

/** Runs that hold a slot (started, or queued with a Workflow) across the whole team. */
export const MAX_ACTIVE_RUNS_PER_TEAM = 50
/** Run creations per team: a token bucket of RUN_BURST tokens refilled at RUN_RATE_PER_SEC. */
export const RUN_RATE_PER_SEC = 5
export const RUN_BURST = 20

/** Open (not terminal) runs per team; past it new runs are refused, so owner state stays bounded. */
export const MAX_OPEN_RUNS_PER_TEAM = 250

export interface RunBucket {
  readonly tokens: number
  readonly at: number
}

/** Takes one creation token; undefined when the bucket is empty. */
export const takeRunToken = (bucket: RunBucket | undefined, now: number): RunBucket | undefined => {
  const elapsed = bucket ? Math.max(0, now - bucket.at) / 1000 : 0
  const tokens = bucket ? Math.min(RUN_BURST, bucket.tokens + elapsed * RUN_RATE_PER_SEC) : RUN_BURST
  if (tokens < 1) return undefined
  return { tokens: tokens - 1, at: now }
}

/** Retryable, so the engine does not record it: the same key may start the run after the bucket refills. */
export const rateLimited = (): { ok: false } & Reject => ({
  ok: false,
  code: "rate.limited",
  message: `at most ${RUN_RATE_PER_SEC} runs per second per team (burst ${RUN_BURST}); retry shortly`,
  retryable: true
})

/** Retryable like the bucket: a deferred delivery or a retried fire starts once runs finish. */
export const queueFull = (): { ok: false } & Reject => ({
  ok: false,
  code: "rate.limited",
  message: `at most ${MAX_OPEN_RUNS_PER_TEAM} open runs per team; retry when runs finish`,
  retryable: true
})
