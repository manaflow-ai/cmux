import { inbox as homeInbox } from "@cmux/home-core"
import type { PushTarget } from "@cmux/protocol"
import { FOREGROUND_MAX_WAIT_MS, FOREGROUND_RECHECK_MS, HOURLY_PUSH_CAP, homeApnsMessage, RETRY_LIMIT, retryBackoffMs, stillPushable, type HomePushQueue } from "./home-push.ts"
import type { ApnsMessage, SendResult } from "./push/apns.ts"

/** What one drain needs from its UserDO (the only writer of the queue and of the push targets). */
export interface HomePushDrainDeps {
  readonly queue: HomePushQueue
  readonly entity: string
  readonly entry: (conversation: string) => homeInbox.InboxEntry | undefined
  readonly pushTargets: (entity: string) => Promise<ReadonlyArray<PushTarget>>
  /** Whether the user's Mac is active (FeedDO presence and `feed.prefs.push_skip_when_mac_active`). */
  readonly quiet: (entity: string) => Promise<boolean>
  readonly send: (targets: ReadonlyArray<PushTarget>, message: ApnsMessage, now: number) => Promise<ReadonlyArray<SendResult> | null>
  readonly dropPushTarget: (entity: string, token: string, reason: string) => Promise<void>
}

/**
 * Sends due Home pushes. Device facts are checked here: no push target settles the row; an
 * active Mac holds a plain row back (a read meanwhile clears it) and drops it after
 * FOREGROUND_MAX_WAIT_MS, and the hourly cap defers it to when the window frees (approvals
 * pass both). A row is settled before its send (at most once), so a retried alarm never sends
 * it again; APNs retry_later puts it back with a backoff, and tokens APNs refuses are dropped.
 * Known gap (home-messaging.md section 9): the cap counts before the send, so a retried row
 * counts twice.
 */
export const drainHomePush = async (deps: HomePushDrainDeps, now: number): Promise<void> => {
  const { queue, entity } = deps
  const due = queue.due(now)
  if (due.length === 0) return
  // Device facts once per drain, before any row is read: the per-row step below never awaits before its settle.
  let targets = await deps.pushTargets(entity)
  const quiet = due.some((r) => !r.approval) ? await deps.quiet(entity) : false
  const log = (msg: string, row: { conversation: string; seq: number }, extra: Record<string, unknown> = {}) =>
    console.log(JSON.stringify({ msg, conversation: row.conversation, seq: row.seq, ...extra }))
  for (const listed of due) {
    // Re-read after the previous send's await: an overlapping drain may have settled it.
    const row = queue.dueRow(listed.conversation, now)
    if (!row) continue
    const message = homeApnsMessage(row.conversation, row, row.seq, row.approval, now)
    const skip = stillPushable(deps.entry(row.conversation), row.approval, now) ?? (targets.length === 0 ? "no_target" : message === null ? "empty" : null)
    if (skip !== null || !message) {
      queue.settle(row.conversation, row.seq, now, false)
      log("home.push.skipped", row, { reason: skip })
      continue
    }
    if (!row.approval) {
      if (quiet) {
        if (now - row.queued_at >= FOREGROUND_MAX_WAIT_MS) {
          queue.settle(row.conversation, row.seq, now, false)
          log("home.push.skipped", row, { reason: "mac_active" })
        } else {
          queue.defer(row.conversation, now + FOREGROUND_RECHECK_MS)
          log("home.push.deferred", row, { reason: "mac_active" })
        }
        continue
      }
      const budget = queue.budget(now)
      if (budget.sent >= HOURLY_PUSH_CAP) {
        queue.defer(row.conversation, budget.freeAt ?? now + 60_000)
        log("home.push.deferred", row, { reason: "hourly_cap", until: budget.freeAt })
        continue
      }
      queue.recordSend(now)
    }
    queue.settle(row.conversation, row.seq, now, true)
    try {
      const results = await deps.send(targets, message, now)
      if (results === null) {
        log("home.push.skipped", row, { reason: "apns not configured" })
        continue
      }
      const dropped = new Set(results.filter((r) => r.outcome === "drop_target").map((r) => r.token))
      for (const token of dropped) await deps.dropPushTarget(entity, token, results.find((r) => r.token === token)?.reason ?? "rejected")
      targets = targets.filter((t) => !dropped.has(t.token))
      log("home.push.sent", row, { results: results.map((r) => ({ outcome: r.outcome, status: r.status, reason: r.reason })) })
      // No device took it and APNs asked to retry: the row comes back with a backoff (bounded), else the loss is logged.
      const retry = results.some((r) => r.outcome === "retry_later") && !results.some((r) => r.outcome === "sent")
      if (retry && row.attempts >= RETRY_LIMIT) log("home.push.lost", row, { attempts: row.attempts })
      else if (retry) log("home.push.retry", row, { attempts: row.attempts + 1, reopened: queue.reopen(row, now + retryBackoffMs(row.attempts)) })
    } catch (e) {
      // An effect after the settle never throws out of the wake: the decision stands (at most once).
      console.error(JSON.stringify({ msg: "home.push.failed", conversation: row.conversation, error: String(e).slice(0, 200) }))
    }
  }
}
