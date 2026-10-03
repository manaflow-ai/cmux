import type { Connection } from "@cmux/protocol"
import type { Env } from "../env.ts"
import { usableScopes } from "./google.ts"
import { FALLBACK_INTERVAL_MS, gmailAlias, gmailCurrentHistoryId, gmailHistorySince, MAX_RENEW_FAILURES, startGmailWatch, WATCH_RENEW_MS, watchOf, type NewMessage } from "./gmail-push.ts"
import { ProviderError, type Credential, type Http } from "./provider-core.ts"

/**
 * The ConnectionDO's Gmail watch lifecycle (integrations-plan.md G3, G4;
 * decision I2: the ConnectionDO alarm renews, because the token, the cursor
 * and the single-flight refresh live here). The host interface keeps this
 * module free of the Durable Object class.
 */

export interface WatchHost {
  readonly sql: SqlStorage
  readonly env: Env
  readonly http: Http
  /** A usable (refreshed if needed) credential for the connection. */
  credential(c: Connection): Promise<Credential>
  /** Adds or removes the push alias in AccountIndexDO. */
  alias(op: "add" | "remove", alias: string, owner: string, connection: string): Promise<void>
  /** One new message as an `event` trigger delivery (ids only). */
  deliver(c: Connection, m: NewMessage): Promise<void>
  /** Health change of the connection (connection.status). */
  status(c: Connection, status: "active" | "error", detail?: string): void
}

const READ = ["gmail.readonly", "gmail.modify"]
const token = (cred: Credential) => {
  if (cred.kind !== "oauth") throw new ProviderError("provider.error", "wrong credential kind")
  return cred.access_token
}

/** Whether this connection should have a Gmail watch on this deployment. */
export const wantsGmailWatch = (env: Env, c: Connection) =>
  c.provider === "gmail" && c.status === "active" && Boolean(env.GOOGLE_PUBSUB_TOPIC) && usableScopes(env, c.scopes_granted).some((s) => READ.includes(s))

/** Starts or renews the watch. A first watch sets the cursor; a renewal keeps it (no gap, no replay). */
export const ensureGmailWatch = async (h: WatchHost, c: Connection, now: number): Promise<void> => {
  if (!wantsGmailWatch(h.env, c)) return
  if (!c.account) {
    await dropGmailWatch(h, c.id)
    return
  }
  const alias = gmailAlias(c.account.name)
  const w = await startGmailWatch(h.http, token(await h.credential(c)), h.env.GOOGLE_PUBSUB_TOPIC!)
  const prior = watchOf(h.sql, c.id)
  h.sql.exec(
    `INSERT INTO google_watches (connection, kind, owner, alias, cursor, expires_at, renew_at, failures, fallback_at) VALUES (?, 'gmail', ?, ?, ?, ?, ?, 0, NULL)
     ON CONFLICT (connection) DO UPDATE SET alias = excluded.alias, cursor = COALESCE(google_watches.cursor, excluded.cursor), expires_at = excluded.expires_at, renew_at = excluded.renew_at, failures = 0, fallback_at = NULL`,
    c.id,
    c.owner,
    alias,
    prior?.cursor ?? w.historyId,
    w.expiration,
    Math.min(now + WATCH_RENEW_MS, w.expiration - 3600_000)
  )
  await h.alias("add", alias, c.owner, c.id)
  if (prior && prior.failures >= MAX_RENEW_FAILURES) h.status(c, "active")
}

/** One pull at a time per connection (a push, a redelivery and the fallback may overlap). */
const pulling = new Map<string, Promise<{ delivered: number }>>()
export const pullGmailHistory = (h: WatchHost, c: Connection): Promise<{ delivered: number }> => {
  const running = pulling.get(c.id)
  if (running) return running
  const work = pullOnce(h, c).finally(() => pulling.delete(c.id))
  pulling.set(c.id, work)
  return work
}

/** Moves the cursor only forward (history ids are decimal and grow). */
const advance = (h: WatchHost, connection: string, cursor: string) => {
  const cur = watchOf(h.sql, connection)?.cursor
  if (cur && BigInt(cur) >= BigInt(cursor)) return
  h.sql.exec(`UPDATE google_watches SET cursor = ? WHERE connection = ?`, cursor, connection)
}

/** Reads history from the cursor, delivers each new message, then moves the cursor (a crash in between replays; deliveries dedupe). */
const pullOnce = async (h: WatchHost, c: Connection): Promise<{ delivered: number }> => {
  const row = watchOf(h.sql, c.id)
  if (!row?.cursor) return { delivered: 0 }
  const t = token(await h.credential(c))
  const r = await gmailHistorySince(h.http, t, row.cursor)
  if ("reset" in r) {
    // Google dropped history that old: skip to now and say so (mail in the gap starts no runs).
    advance(h, c.id, await gmailCurrentHistoryId(h.http, t))
    console.error(JSON.stringify({ msg: "gmail history gap; cursor reset", connection: c.id }))
    return { delivered: 0 }
  }
  for (const m of r.messages) await h.deliver(c, m)
  advance(h, c.id, r.cursor)
  // More history than one pull reads: continue from the next alarm instead of waiting for new mail.
  if (r.more) h.sql.exec(`UPDATE google_watches SET fallback_at = ? WHERE connection = ?`, Date.now(), c.id)
  return { delivered: r.messages.length }
}

/** A verified Pub/Sub push for this connection. A connection without a watch row ignores it. */
export const onGmailPush = async (h: WatchHost, c: Connection | undefined, historyId: string): Promise<{ status: "ignored" | "pulled" | "failed"; delivered: number }> => {
  if (!c || !wantsGmailWatch(h.env, c) || !/^[0-9]{1,20}$/.test(historyId)) return { status: "ignored", delivered: 0 }
  const row = watchOf(h.sql, c.id)
  if (!row) return { status: "ignored", delivered: 0 }
  // An old notification (Pub/Sub redelivery) is still safe: history is read from our cursor, not from its id.
  try {
    const r = await pullGmailHistory(h, c)
    return { status: "pulled", delivered: r.delivered }
  } catch (e) {
    // The fallback read retries from the alarm; the push itself is acknowledged.
    h.sql.exec(`UPDATE google_watches SET fallback_at = COALESCE(fallback_at, ?) WHERE connection = ?`, Date.now() + 60_000, c.id)
    console.error(JSON.stringify({ msg: "gmail push pull failed", connection: c.id, error: e instanceof ProviderError ? e.code : "unknown" }))
    return { status: "failed", delivered: 0 }
  }
}

/** The alarm's watch work: renew due watches; run the fallback history read while push is unhealthy. */
export const runWatchWork = async (h: WatchHost, connections: Readonly<Record<string, Connection>>, now: number): Promise<void> => {
  const rows = h.sql.exec<{ connection: string; renew_at: number; fallback_at: number | null; failures: number; expires_at: number; alias: string }>(
    `SELECT connection, renew_at, fallback_at, failures, expires_at, alias FROM google_watches WHERE renew_at <= ? OR (fallback_at IS NOT NULL AND fallback_at <= ?)`,
    now,
    now
  ).toArray()
  for (const r of rows) {
    const c = connections[r.connection]
    if (!c || !wantsGmailWatch(h.env, c)) {
      await dropGmailWatch(h, r.connection)
      continue
    }
    if (r.renew_at <= now) {
      try {
        await ensureGmailWatch(h, c, now)
      } catch (e) {
        const failures = Number(r.failures) + 1
        const retry = now + Math.min(6 * 3600_000, 15 * 60_000 * 2 ** failures)
        h.sql.exec(`UPDATE google_watches SET failures = ?, renew_at = ?, fallback_at = COALESCE(fallback_at, ?) WHERE connection = ?`, failures, retry, now, c.id)
        console.error(JSON.stringify({ msg: "gmail watch renewal failed", connection: c.id, failures, error: e instanceof ProviderError ? e.code : "unknown" }))
        if (failures === MAX_RENEW_FAILURES) h.status(c, "error", "Gmail push could not be renewed; new-mail triggers use a slower fallback")
      }
    }
    const fresh = h.sql.exec<{ fallback_at: number | null; expires_at: number }>(`SELECT fallback_at, expires_at FROM google_watches WHERE connection = ?`, c.id).toArray()[0]
    // An expired watch sends nothing: fall back until a renewal succeeds.
    const due = fresh && ((fresh.fallback_at !== null && fresh.fallback_at <= now) || fresh.expires_at <= now)
    if (!due) continue
    try {
      await pullGmailHistory(h, c)
    } catch (e) {
      console.error(JSON.stringify({ msg: "gmail fallback read failed", connection: c.id, error: e instanceof ProviderError ? e.code : "unknown" }))
    }
    h.sql.exec(`UPDATE google_watches SET fallback_at = ? WHERE connection = ?`, now + FALLBACK_INTERVAL_MS, c.id)
  }
}

/**
 * Forgets the watch and its alias (disconnect, lost scope, closed gate). The
 * row is deleted synchronously; Google's watch then lapses within 7 days, and
 * its pushes reach nobody.
 */
export const dropGmailWatch = async (h: WatchHost, connection: string): Promise<void> => {
  const row = watchOf(h.sql, connection)
  h.sql.exec(`DELETE FROM google_watches WHERE connection = ?`, connection)
  if (row) await h.alias("remove", row.alias, row.owner, connection).catch(() => undefined)
}

/** A verified push from ingress/google-hooks.ts. */
export type GooglePush =
  | { readonly kind: "gmail"; readonly connection: string; readonly historyId: string; readonly messageId: string }
  | { readonly kind: "calendar"; readonly connection: string; readonly channel: string; readonly token: string; readonly state: string; readonly number: string }

/** Retry delay for a first watch that failed at link time. */
const FIRST_WATCH_RETRY_MS = 15 * 60_000

/**
 * The first watch right after a link. A failure leaves a row without a
 * cursor that the alarm renews later, so linking never fails because of push.
 */
export const startWatchSafely = async (h: WatchHost, c: Connection, now: number): Promise<void> => {
  if (!wantsGmailWatch(h.env, c) || !c.account) return
  try {
    await ensureGmailWatch(h, c, now)
  } catch (e) {
    h.sql.exec(
      `INSERT OR IGNORE INTO google_watches (connection, kind, owner, alias, cursor, expires_at, renew_at, failures, fallback_at) VALUES (?, 'gmail', ?, ?, NULL, 0, ?, 1, NULL)`,
      c.id,
      c.owner,
      gmailAlias(c.account.name),
      now + FIRST_WATCH_RETRY_MS
    )
    console.error(JSON.stringify({ msg: "gmail watch start failed", connection: c.id, error: e instanceof ProviderError ? e.code : "unknown" }))
  }
}
