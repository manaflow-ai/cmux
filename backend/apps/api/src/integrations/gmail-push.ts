import type { Http } from "./provider-core.ts"
import { googleApi } from "./google.ts"
import { ProviderError } from "./provider-core.ts"

/**
 * Gmail push (spec integrations.md "New-email triggers", S2;
 * integrations-plan.md G3 and G4). Gmail `users.watch` publishes
 * `{emailAddress, historyId}` to our Pub/Sub topic; the Worker routes it by
 * the alias `gmail:email:<address>` to the ConnectionDO, which reads
 * `history.list` from its stored cursor and emits one
 * `mail.message.received {connection, message_id, thread_id, labels}` per
 * new INBOX message. Stored per connection: the cursor (a history id), the
 * watch expiry and renewal state. Never a subject, sender, snippet or body.
 */

const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"

/** Google advises a daily watch renewal; a watch lives at most 7 days. */
export const WATCH_RENEW_MS = 24 * 3600_000
/** While push is unhealthy, the server-side fallback reads history this often (S2 allows it only as a fallback). */
export const FALLBACK_INTERVAL_MS = 15 * 60_000
/** Consecutive failed renewals before the connection is marked `error`. */
export const MAX_RENEW_FAILURES = 3
/** Pages of history read per push; more waits for the next push or fallback. */
const MAX_HISTORY_PAGES = 10

export const gmailAlias = (address: string) => `gmail:email:${address.trim().toLowerCase()}`

export interface NewMessage {
  readonly message_id: string
  readonly thread_id: string
  readonly labels: ReadonlyArray<string>
}

export const createWatchTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS google_watches (
    connection TEXT PRIMARY KEY, kind TEXT NOT NULL, owner TEXT NOT NULL, alias TEXT NOT NULL, cursor TEXT,
    expires_at INTEGER NOT NULL, renew_at INTEGER NOT NULL, failures INTEGER NOT NULL DEFAULT 0,
    fallback_at INTEGER, stop_since INTEGER, stop_failures INTEGER NOT NULL DEFAULT 0)`)
  // Objects created by 1990f1df4d9 have the table without the stop columns.
  const columns = sql.exec<{ name: string }>(`PRAGMA table_info(google_watches)`).toArray().map((c) => c.name)
  if (!columns.includes("stop_since")) sql.exec(`ALTER TABLE google_watches ADD COLUMN stop_since INTEGER`)
  if (!columns.includes("stop_failures")) sql.exec(`ALTER TABLE google_watches ADD COLUMN stop_failures INTEGER NOT NULL DEFAULT 0`)
  // Watches whose users.stop never succeeded (CASA evidence: Google may still send this mailbox's ids).
  sql.exec(`CREATE TABLE IF NOT EXISTS watch_stop_failures (connection TEXT PRIMARY KEY, alias TEXT NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL)`)
}

/** How long users.stop is retried before the failure is recorded and the watch forgotten. */
export const STOP_GIVE_UP_MS = 24 * 3600_000
/** Recorded stop failures are kept this long. */
export const STOP_FAILURE_RETENTION_MS = 30 * 24 * 3600_000

export const recordStopFailure = (sql: SqlStorage, connection: string, alias: string, reason: string, now: number) => {
  sql.exec(`INSERT OR REPLACE INTO watch_stop_failures (connection, alias, reason, at) VALUES (?, ?, ?, ?)`, connection, alias, reason.slice(0, 200), now)
  console.error(JSON.stringify({ msg: "gmail watch stop failed for good", connection, reason: reason.slice(0, 200) }))
}

export interface WatchRow {
  readonly connection: string
  readonly kind: "gmail"
  readonly owner: string
  readonly alias: string
  readonly cursor: string | null
  readonly expires_at: number
  readonly renew_at: number
  readonly failures: number
  readonly fallback_at: number | null
  /** Set while the watch is being stopped (users.stop pending); such a row never routes pushes. */
  readonly stop_since: number | null
  readonly stop_failures: number
}

export const watchOf = (sql: SqlStorage, connection: string): WatchRow | undefined =>
  sql.exec<WatchRow & Record<string, SqlStorageValue>>(`SELECT * FROM google_watches WHERE connection = ?`, connection).toArray()[0]

/** The earliest renewal or fallback time across watches, for the owner's alarm. */
export const nextWatchAt = (sql: SqlStorage): number | null => {
  const r = sql.exec<{ at: number | null }>(`SELECT MIN(MIN(renew_at, COALESCE(fallback_at, renew_at))) AS at FROM google_watches`).toArray()[0]?.at
  return r === null || r === undefined ? null : Number(r)
}

/** Starts or renews the watch on INBOX. Returns Google's history id and expiry. */
export const startGmailWatch = async (http: Http, token: string, topic: string): Promise<{ historyId: string; expiration: number }> => {
  const b = await googleApi(http, token, "POST", `${GMAIL}/watch`, { body: { topicName: topic, labelIds: ["INBOX"], labelFilterBehavior: "include" }, what: "users.watch" })
  const historyId = String(b.historyId ?? "")
  const expiration = Number(b.expiration ?? 0)
  if (!/^[0-9]{1,20}$/.test(historyId) || !Number.isFinite(expiration) || expiration <= 0) throw new ProviderError("provider.error", "users.watch returned no history id or expiration")
  return { historyId, expiration }
}

export const stopGmailWatch = (http: Http, token: string) => googleApi(http, token, "POST", `${GMAIL}/stop`, { what: "users.stop" })

/**
 * New INBOX messages after `cursor`, oldest first, and the cursor to store.
 * `reset` when Google no longer has history that old (404): the caller moves
 * the cursor to the newest history id and records the gap.
 */
export const gmailHistorySince = async (http: Http, token: string, cursor: string): Promise<{ messages: Array<NewMessage>; cursor: string; more: boolean } | { reset: true }> => {
  const messages: Array<NewMessage> = []
  const seen = new Set<string>()
  let pageToken: string | undefined
  let latest = cursor
  let lastRecord = cursor
  for (let page = 0; page < MAX_HISTORY_PAGES; page++) {
    const q = new URLSearchParams({ startHistoryId: cursor, historyTypes: "messageAdded", labelId: "INBOX", maxResults: "500" })
    if (pageToken) q.set("pageToken", pageToken)
    let b: Record<string, unknown>
    try {
      b = await googleApi(http, token, "GET", `${GMAIL}/history?${q}`, { what: "history.list" })
    } catch (e) {
      if (e instanceof ProviderError && e.status === 404) return { reset: true }
      throw e
    }
    for (const h of (b.history ?? []) as Array<{ id?: string; messagesAdded?: Array<{ message?: { id?: string; threadId?: string; labelIds?: Array<string> } }> }>) {
      if (typeof h.id === "string" && /^[0-9]{1,20}$/.test(h.id)) lastRecord = h.id
      for (const a of h.messagesAdded ?? []) {
        const m = a.message
        if (!m?.id || !m.threadId || seen.has(m.id)) continue
        seen.add(m.id)
        messages.push({ message_id: m.id, thread_id: m.threadId, labels: [...(m.labelIds ?? [])].sort() })
      }
    }
    if (typeof b.historyId === "string" && /^[0-9]{1,20}$/.test(b.historyId)) latest = b.historyId
    pageToken = typeof b.nextPageToken === "string" ? b.nextPageToken : undefined
    if (!pageToken) return { messages, cursor: latest, more: false }
  }
  // Stopped early: continue after the last record read (history lists records after startHistoryId).
  return { messages, cursor: lastRecord, more: true }
}

/** Gmail profile's current history id (used to reset a cursor after a gap). */
export const gmailCurrentHistoryId = async (http: Http, token: string): Promise<string> => {
  const b = await googleApi(http, token, "GET", `${GMAIL}/profile`, { what: "users.getProfile" })
  const id = String(b.historyId ?? "")
  if (!/^[0-9]{1,20}$/.test(id)) throw new ProviderError("provider.error", "users.getProfile returned no history id")
  return id
}
