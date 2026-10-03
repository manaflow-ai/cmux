import type { IntegrationProvider } from "@cmux/protocol"
import type { Env } from "../env.ts"
import { aadFor, open, type SealedSecret } from "./crypto.ts"
import type { Credential, Http, ProviderImpl } from "./provider-core.ts"

/**
 * Provider-side revocation after a disconnect (integrations-plan.md G5, CASA
 * control C7). The disconnect commits and the credential leaves the
 * `credentials` table at once; for providers that can revoke a grant, the
 * sealed credential moves to `pending_revocations` until the provider
 * confirms. Attempts back off and give up after REVOCATION_GIVE_UP_MS, so a
 * provider outage never keeps a token longer than that.
 *
 * A grant can be shared: Google revokes the whole grant of a user to our
 * OAuth client, so a revoke is skipped while another connection of the same
 * grant (`ProviderImpl.grantKeys`) is still linked. The local token is gone
 * either way; the grant goes when its last connection does.
 */

export const REVOCATION_GIVE_UP_MS = 24 * 3600_000
const MAX_BACKOFF_MS = 30 * 60_000
/** A drain claims a row for this long before its provider call, so two drains never revoke one row twice. */
const CLAIM_MS = 60_000

type Row = { connection: string; owner: string; provider: string; account: string | null; stop_alias: string | null; stop_done: number; generation: number; sealed: string; attempts: number; first_at: number; next_at: number }

export const createRevocationTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS pending_revocations (
    connection TEXT PRIMARY KEY, owner TEXT NOT NULL, provider TEXT NOT NULL, account TEXT, stop_alias TEXT, stop_done INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL,
    sealed TEXT NOT NULL, attempts INTEGER NOT NULL, first_at INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
  // Objects created by 1722e8ddd9c have the table without stop_alias.
  const columns = sql.exec<{ name: string }>(`PRAGMA table_info(pending_revocations)`).toArray().map((c) => c.name)
  if (!columns.includes("stop_alias")) sql.exec(`ALTER TABLE pending_revocations ADD COLUMN stop_alias TEXT`)
  if (!columns.includes("stop_done")) sql.exec(`ALTER TABLE pending_revocations ADD COLUMN stop_done INTEGER NOT NULL DEFAULT 0`)
}

/**
 * Removes the connection's credential; when the provider can revoke, keeps
 * the sealed copy for revocation only. Synchronous, so it runs in the same
 * turn as the disconnect commit. Returns whether a revocation is pending.
 */
export const takeCredentialForRevocation = (
  sql: SqlStorage,
  c: { id: string; owner: string; provider: IntegrationProvider; account: { key: string } | null },
  impl: ProviderImpl | undefined,
  now: number,
  /** A push watch to stop before the revoke (Gmail users.stop), named by its alias. */
  stopAlias: string | null = null
): boolean => {
  const row = sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM credentials WHERE connection = ?`, c.id).toArray()[0]
  sql.exec(`DELETE FROM credentials WHERE connection = ?`, c.id)
  if (!row || !impl?.revoke) return false
  sql.exec(
    `INSERT OR REPLACE INTO pending_revocations (connection, owner, provider, account, stop_alias, generation, sealed, attempts, first_at, next_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
    c.id,
    c.owner,
    c.provider,
    c.account?.key ?? null,
    stopAlias,
    Number(row.generation),
    row.sealed,
    now,
    now
  )
  return true
}

export const nextRevocationAt = (sql: SqlStorage): number | null => {
  const at = sql.exec<{ at: number | null }>(`SELECT MIN(next_at) AS at FROM pending_revocations`).toArray()[0]?.at
  return at === null || at === undefined ? null : Number(at)
}

/** Linked connections of an account key (AccountIndexDO.list). */
export type Linked = (accountKey: string) => Promise<ReadonlyArray<{ team: string; connection: string }>>

/** Stops a provider push watch with the credential; throws on failure. */
export type StopWatch = (provider: string, credential: Credential, alias: string, connection: string) => Promise<void>

/** users.stop is retried this long before the revoke goes ahead without it (the failure is recorded). */
export const STOP_BEFORE_REVOKE_MS = 6 * 3600_000

/** Records a watch whose stop failed for good (the caller's table; see gmail-push.ts). */
export type StopFailed = (connection: string, alias: string, reason: string) => void

/** Runs every due revocation once. Never throws; never logs a token. */
export const drainRevocations = async (
  sql: SqlStorage,
  env: Env,
  http: Http,
  providers: Readonly<Record<string, ProviderImpl>>,
  linked: Linked,
  now: number,
  stopWatch?: StopWatch,
  stopFailed?: StopFailed
): Promise<void> => {
  const due = sql.exec<Row>(`SELECT * FROM pending_revocations WHERE next_at <= ?`, now).toArray()
  for (const r of due) {
    // Claim before any await: a concurrent drain no longer sees this row as due.
    sql.exec(`UPDATE pending_revocations SET next_at = ? WHERE connection = ? AND first_at = ?`, now + CLAIM_MS, r.connection, r.first_at)
    const impl = providers[r.provider]
    let outcome: "done" | "retry" = "retry"
    try {
      if (!impl?.revoke) outcome = "done"
      else if (!env.INTEGRATIONS_KEK) {
        console.error(JSON.stringify({ msg: "provider revocation skipped: no INTEGRATIONS_KEK", connection: r.connection, provider: r.provider }))
        if (r.stop_alias && !r.stop_done) stopFailed?.(r.connection, r.stop_alias, "no INTEGRATIONS_KEK to open the credential")
        outcome = "done"
      } else {
        const credential = JSON.parse(await open(env.INTEGRATIONS_KEK, JSON.parse(r.sealed) as SealedSecret, aadFor(r.connection, r.owner, r.provider, Number(r.generation)))) as Credential
        // The watch is per mailbox, not per connection: stop it only when no other connection uses that mailbox.
        // The stop runs before the revoke (the token dies with the grant) and is retried until it succeeds or
        // STOP_BEFORE_REVOKE_MS passes; then the failure is recorded and the revoke goes ahead.
        if (r.stop_alias && !r.stop_done && stopWatch) {
          let stopped = (await linked(r.stop_alias)).some((l) => l.connection !== r.connection)
          if (!stopped) {
            try {
              await stopWatch(r.provider, credential, r.stop_alias, r.connection)
              stopped = true
            } catch (e) {
              const reason = e instanceof Error ? `${e.name}: ${e.message}`.slice(0, 200) : "users.stop failed"
              if (now - Number(r.first_at) < STOP_BEFORE_REVOKE_MS) throw new Error(`watch stop pending: ${reason}`)
              stopFailed?.(r.connection, r.stop_alias, reason)
              stopped = true
            }
          }
          if (stopped) sql.exec(`UPDATE pending_revocations SET stop_done = 1 WHERE connection = ? AND first_at = ?`, r.connection, r.first_at)
        }
        if (r.account && (await sharedGrantInUse(impl, linked, r.account, r.connection))) {
          console.log(JSON.stringify({ msg: "provider revocation skipped: the grant is still used by another connection", connection: r.connection, provider: r.provider }))
          outcome = "done"
        } else outcome = await impl.revoke(env, http, credential)
      }
    } catch (e) {
      console.error(JSON.stringify({ msg: "provider revocation failed", connection: r.connection, provider: r.provider, error: e instanceof Error ? e.name : "unknown" }))
    }
    const attempts = Number(r.attempts) + 1
    if (outcome === "done" || now - Number(r.first_at) >= REVOCATION_GIVE_UP_MS) {
      if (outcome !== "done") console.error(JSON.stringify({ msg: "provider revocation gave up", connection: r.connection, provider: r.provider, attempts }))
      sql.exec(`DELETE FROM pending_revocations WHERE connection = ? AND first_at = ?`, r.connection, r.first_at)
    } else {
      sql.exec(`UPDATE pending_revocations SET attempts = ?, next_at = ? WHERE connection = ? AND first_at = ?`, attempts, now + Math.min(MAX_BACKOFF_MS, 30_000 * 2 ** attempts), r.connection, r.first_at)
    }
  }
}

const sharedGrantInUse = async (impl: ProviderImpl, linked: Linked, account: string, connection: string): Promise<boolean> => {
  for (const key of impl.grantKeys?.(account) ?? [account]) {
    if ((await linked(key)).some((l) => l.connection !== connection)) return true
  }
  return false
}
