import type { NotifyTargets } from "./domains/user-notify.ts"
import { activityRequests, activitySignature, dismissDue, feedBadge } from "./domains/feed-notify.ts"
import type { FeedState } from "./domains/feed.ts"
import { dismissMessage, providerToken, sendApnsMessage, type ApnsConfig } from "./push/apns.ts"
import { activityState, liveActivityRequest, stateKey } from "./push/live-activity.ts"

/**
 * FeedDO's effects after a commit (plans/cmux-next/ios-next/c7-notify.md sections
 * 3 and 6): a background dismiss push for pushed items that stopped needing the
 * user, and Live Activity updates when the open requests an activity follows
 * change. What was sent is kept in side tables, so a hibernated object never
 * sends twice and the shared reducer stays unchanged. Delivery is at most once:
 * rows are written before the send (feed.md 7.3).
 */
export interface FeedPushEffectsDeps {
  readonly sql: SqlStorage
  readonly state: FeedState
  readonly config: ApnsConfig | null
  readonly targets: () => Promise<NotifyTargets>
  readonly dropTarget: (token: string, reason: string) => Promise<void>
  readonly now: number
  readonly fetcher?: typeof fetch
}

const ensureTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS feed_dismissed (item TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS feed_activity_sent (activity TEXT PRIMARY KEY, state TEXT NOT NULL, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS feed_notify_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`)
}

export const runFeedPushEffects = async (deps: FeedPushEffectsDeps): Promise<void> => {
  const { sql, state, now } = deps
  ensureTables(sql)
  const dismissed = new Set(sql.exec<{ item: string }>(`SELECT item FROM feed_dismissed`).toArray().map((r) => r.item))
  const due = dismissDue(state, dismissed)
  const signature = activitySignature(state)
  const lastSignature = sql.exec<{ value: string }>(`SELECT value FROM feed_notify_meta WHERE key = 'activity_signature'`).toArray()[0]?.value ?? ""
  // Forget rows of items the owner pruned.
  for (const item of dismissed) if (!state.items[item]) sql.exec(`DELETE FROM feed_dismissed WHERE item = ?`, item)
  if (due.length === 0 && signature === lastSignature) return
  for (const item of due) sql.exec(`INSERT OR IGNORE INTO feed_dismissed (item, at) VALUES (?, ?)`, item, now)
  sql.exec(`INSERT INTO feed_notify_meta (key, value) VALUES ('activity_signature', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, signature)
  if (!deps.config) {
    console.log(JSON.stringify({ msg: "feed.notify.skipped", reason: "apns not configured", dismiss: due.length }))
    return
  }
  const targets = await deps.targets()
  if (due.length > 0 && targets.push.length > 0) {
    const results = await sendApnsMessage(deps.config, targets.push, dismissMessage(due, feedBadge(state, now), now), now, deps.fetcher)
    for (const r of results) if (r.outcome === "drop_target") await deps.dropTarget(r.token, r.reason ?? "rejected")
    console.log(JSON.stringify({ msg: "feed.dismiss.sent", items: due.length, results: results.map((r) => ({ outcome: r.outcome, status: r.status })) }))
  }
  if (signature === lastSignature || targets.activities.length === 0) return
  const open = activityRequests(state)
  const token = await providerToken(deps.config, now)
  const fetcher = deps.fetcher ?? fetch
  for (const a of targets.activities) {
    const next = activityState(a, open)
    const key = stateKey(next)
    const prior = sql.exec<{ state: string }>(`SELECT state FROM feed_activity_sent WHERE activity = ?`, a.activity).toArray()[0]?.state
    // A new registration starts as running on the phone: send only a change from that.
    if ((prior ?? "running|") === key) continue
    sql.exec(`INSERT INTO feed_activity_sent (activity, state, at) VALUES (?, ?, ?) ON CONFLICT (activity) DO UPDATE SET state = excluded.state, at = excluded.at`, a.activity, key, now)
    try {
      const res = await fetcher(liveActivityRequest(a, next, token, now))
      console.log(JSON.stringify({ msg: "feed.activity.sent", activity: a.activity, phase: next.phase, status: res.status }))
    } catch (e) {
      console.error(JSON.stringify({ msg: "feed.activity.failed", activity: a.activity, error: String(e).slice(0, 120) }))
    }
  }
}
