import type { Connection } from "@cmux/protocol"
import type { Env } from "../env.ts"
import { usableScopes } from "./google.ts"
import {
  FALLBACK_INTERVAL_MS,
  gmailAlias,
  gmailCurrentHistoryId,
  gmailHistorySince,
  MAX_RENEW_FAILURES,
  recordStopFailure,
  startGmailWatch,
  STOP_FAILURE_RETENTION_MS,
  STOP_GIVE_UP_MS,
  stopGmailWatch,
  WATCH_RENEW_MS,
  watchOf,
  type NewMessage
} from "./gmail-push.ts"
import { googleRefresh } from "./google.ts"
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
  /** Keeps work running after the RPC answered (the object stays alive; the alarm is the safety net). */
  background(work: Promise<unknown>): void
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
    await stopAndDropWatch(h, c.id, now)
    return
  }
  const alias = gmailAlias(c.account.name)
  const w = await startGmailWatch(h.http, token(await h.credential(c)), h.env.GOOGLE_PUBSUB_TOPIC!)
  const prior = watchOf(h.sql, c.id)
  h.sql.exec(
    `INSERT INTO google_watches (connection, kind, owner, alias, cursor, expires_at, renew_at, failures, fallback_at) VALUES (?, 'gmail', ?, ?, ?, ?, ?, 0, NULL)
     ON CONFLICT (connection) DO UPDATE SET alias = excluded.alias, cursor = COALESCE(google_watches.cursor, excluded.cursor), expires_at = excluded.expires_at, renew_at = excluded.renew_at, failures = 0, stop_since = NULL, stop_failures = 0, fallback_at = CASE WHEN ? THEN google_watches.fallback_at ELSE NULL END`,
    c.id,
    c.owner,
    alias,
    prior?.cursor ?? w.historyId,
    w.expiration,
    Math.min(now + WATCH_RENEW_MS, w.expiration - 3600_000),
    // A pull in flight keeps its safety fallback until it finishes.
    pulling.has(c.id) ? 1 : 0
  )
  await h.alias("add", alias, c.owner, c.id)
  if (prior && prior.failures >= MAX_RENEW_FAILURES) h.status(c, "active")
}

/**
 * One pull at a time per connection (a push, a redelivery and the fallback
 * may overlap). A request that arrives during a pull marks a rerun: the
 * running pull may have read history before that request's mail existed.
 */
const pulling = new Map<string, { work: Promise<{ delivered: number }>; rerun: boolean }>()
export const pullGmailHistory = (h: WatchHost, c: Connection): Promise<{ delivered: number }> => {
  const running = pulling.get(c.id)
  if (running) {
    running.rerun = true
    return running.work
  }
  const entry = { work: Promise.resolve({ delivered: 0 }), rerun: false }
  entry.work = (async () => {
    let delivered = 0
    try {
      do {
        entry.rerun = false
        delivered += (await pullOnce(h, c, () => entry.rerun)).delivered
      } while (entry.rerun)
    } finally {
      pulling.delete(c.id)
    }
    return { delivered }
  })()
  pulling.set(c.id, entry)
  return entry.work
}
export const pullRunning = (connection: string) => pulling.has(connection)

/** Moves the cursor only forward (history ids are decimal and grow). */
const advance = (h: WatchHost, connection: string, cursor: string) => {
  const cur = watchOf(h.sql, connection)?.cursor
  if (cur && BigInt(cur) >= BigInt(cursor)) return
  h.sql.exec(`UPDATE google_watches SET cursor = ? WHERE connection = ?`, cursor, connection)
}

/** Reads history from the cursor, delivers each new message, then moves the cursor (a crash in between replays; deliveries dedupe). */
const pullOnce = async (h: WatchHost, c: Connection, rerunPending: () => boolean): Promise<{ delivered: number }> => {
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
  // A healthy watch needs no fallback once a pull succeeded and no newer request waits for a rerun.
  if (!rerunPending()) h.sql.exec(`UPDATE google_watches SET fallback_at = NULL WHERE connection = ? AND failures = 0 AND expires_at > ?`, c.id, Date.now())
  // More history than one pull reads: continue from the next alarm instead of waiting for new mail.
  if (r.more) h.sql.exec(`UPDATE google_watches SET fallback_at = ? WHERE connection = ?`, Date.now(), c.id)
  return { delivered: r.messages.length }
}

/** A verified Pub/Sub push for this connection. A connection without a watch row ignores it. */
export const onGmailPush = async (h: WatchHost, c: Connection | undefined, historyId: string): Promise<{ status: "ignored" | "queued"; delivered: number }> => {
  if (!c || !wantsGmailWatch(h.env, c) || !/^[0-9]{1,20}$/.test(historyId)) return { status: "ignored", delivered: 0 }
  const row = watchOf(h.sql, c.id)
  if (!row || row.stop_since !== null) return { status: "ignored", delivered: 0 }
  // An old notification (Pub/Sub redelivery) is still safe: history is read from our cursor, not from its id.
  // Answer at once and pull in the background: a slow history call never delays the push's ack. The
  // fallback time set first is the safety net: if this pull is cut off, the alarm reads again.
  h.sql.exec(`UPDATE google_watches SET fallback_at = COALESCE(fallback_at, ?) WHERE connection = ?`, Date.now() + 60_000, c.id)
  h.background(
    pullGmailHistory(h, c).catch((e) => console.error(JSON.stringify({ msg: "gmail push pull failed", connection: c.id, error: e instanceof ProviderError ? e.code : "unknown" })))
  )
  return { status: "queued", delivered: 0 }
}

/**
 * Gmail users.stop with a disconnected connection's credential (refreshed
 * first when expired). A connection that linked the same mailbox meanwhile
 * renews its watch at once, so the stop never leaves it without push.
 */
export const stopWatchWith = async (env: Env, http: Http, provider: string, credential: Credential, alias: string, connection: string): Promise<void> => {
  if (provider !== "gmail") return
  const fresh = (await googleRefresh(env, http, credential)) ?? credential
  await stopGmailWatch(http, token(fresh))
  const others = (await env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(alias)).list()).filter((l) => l.connection !== connection)
  await Promise.allSettled(others.map((l) => env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(l.team)).renewWatchSoon(l.team, l.connection)))
}

/** The alarm's watch work: renew due watches; run the fallback history read while push is unhealthy. */
export const runWatchWork = async (h: WatchHost, connections: Readonly<Record<string, Connection>>, now: number): Promise<void> => {
  const rows = h.sql.exec<{ connection: string; renew_at: number; fallback_at: number | null; failures: number; expires_at: number; alias: string }>(
    `SELECT connection, renew_at, fallback_at, failures, expires_at, alias FROM google_watches WHERE renew_at <= ? OR (fallback_at IS NOT NULL AND fallback_at <= ?)`,
    now,
    now
  ).toArray()
  h.sql.exec(`DELETE FROM watch_stop_failures WHERE at < ?`, now - STOP_FAILURE_RETENTION_MS)
  for (const r of rows) {
    const c = connections[r.connection]
    if (!c || !wantsGmailWatch(h.env, c)) {
      // Scope lost, gate closed, connection gone or unhealthy: stop the watch at Gmail, then forget it.
      await stopAndDropWatch(h, r.connection, now, c)
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
    // Only an unhealthy watch keeps polling; a healthy one waits for pushes.
    h.sql.exec(`UPDATE google_watches SET fallback_at = ? WHERE connection = ? AND (failures > 0 OR expires_at <= ?)`, now + FALLBACK_INTERVAL_MS, c.id, now)
  }
}

/**
 * Forgets the watch row and its alias at once. Only for a disconnect: the
 * revocation drain then runs users.stop with the sealed credential, retried
 * before the token is destroyed (revocations.ts). Every other drop goes
 * through stopAndDropWatch.
 */
export const dropGmailWatch = async (h: WatchHost, connection: string): Promise<void> => {
  const row = watchOf(h.sql, connection)
  h.sql.exec(`DELETE FROM google_watches WHERE connection = ?`, connection)
  if (row) await h.alias("remove", row.alias, row.owner, connection).catch(() => undefined)
}

/**
 * Stops the watch at Gmail with the connection's own credential, then forgets
 * it. The alias goes first, so no push routes here meanwhile. A failed
 * users.stop keeps the row in the stopping state and the alarm retries with
 * backoff; after STOP_GIVE_UP_MS the failure is recorded and the row goes.
 * The watch is per mailbox: when another connection still links the mailbox,
 * no stop is sent.
 */
export const stopAndDropWatch = async (h: WatchHost, connection: string, now: number, c?: Connection): Promise<void> => {
  const row = watchOf(h.sql, connection)
  if (!row) return
  if (row.stop_since === null) h.sql.exec(`UPDATE google_watches SET stop_since = ?, fallback_at = NULL WHERE connection = ?`, now, connection)
  const since = row.stop_since ?? now
  await h.alias("remove", row.alias, row.owner, connection).catch(() => undefined)
  const done = (reason?: string) => {
    if (reason) recordStopFailure(h.sql, connection, row.alias, reason, now)
    h.sql.exec(`DELETE FROM google_watches WHERE connection = ?`, connection)
  }
  try {
    const others = (await h.env.ACCOUNT_INDEX_DO.get(h.env.ACCOUNT_INDEX_DO.idFromName(row.alias)).list()).filter((l) => l.connection !== connection)
    if (others.length > 0) return done()
    if (!c) return done("the connection is gone; no credential to stop the watch")
    await stopGmailWatch(h.http, token(await h.credential(c)))
    done()
  } catch (e) {
    const reason = e instanceof ProviderError ? `${e.code}: ${e.message}` : "users.stop failed"
    if (now - since >= STOP_GIVE_UP_MS) return done(reason)
    const failures = Number(row.stop_failures) + 1
    h.sql.exec(`UPDATE google_watches SET stop_failures = ?, renew_at = ? WHERE connection = ?`, failures, now + Math.min(3600_000, 60_000 * 2 ** failures), connection)
  }
}

/** Renews a watch at the next alarm, armed now (never moving an earlier alarm later). */
export const renewSoon = async (storage: DurableObjectStorage, connection: string, now: number): Promise<void> => {
  storage.sql.exec(`UPDATE google_watches SET renew_at = ? WHERE connection = ? AND stop_since IS NULL`, now, connection)
  const current = await storage.getAlarm()
  if (current === null || current > now) await storage.setAlarm(now)
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
