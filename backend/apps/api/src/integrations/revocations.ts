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

type Row = { connection: string; owner: string; provider: string; account: string | null; generation: number; sealed: string; attempts: number; first_at: number; next_at: number }

export const createRevocationTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS pending_revocations (
    connection TEXT PRIMARY KEY, owner TEXT NOT NULL, provider TEXT NOT NULL, account TEXT, generation INTEGER NOT NULL,
    sealed TEXT NOT NULL, attempts INTEGER NOT NULL, first_at INTEGER NOT NULL, next_at INTEGER NOT NULL)`)

/**
 * Removes the connection's credential; when the provider can revoke, keeps
 * the sealed copy for revocation only. Synchronous, so it runs in the same
 * turn as the disconnect commit. Returns whether a revocation is pending.
 */
export const takeCredentialForRevocation = (
  sql: SqlStorage,
  c: { id: string; owner: string; provider: IntegrationProvider; account: { key: string } | null },
  impl: ProviderImpl | undefined,
  now: number
): boolean => {
  const row = sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM credentials WHERE connection = ?`, c.id).toArray()[0]
  sql.exec(`DELETE FROM credentials WHERE connection = ?`, c.id)
  if (!row || !impl?.revoke) return false
  sql.exec(
    `INSERT OR REPLACE INTO pending_revocations (connection, owner, provider, account, generation, sealed, attempts, first_at, next_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
    c.id,
    c.owner,
    c.provider,
    c.account?.key ?? null,
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

/** Runs every due revocation once. Never throws; never logs a token. */
export const drainRevocations = async (sql: SqlStorage, env: Env, http: Http, providers: Readonly<Record<string, ProviderImpl>>, linked: Linked, now: number): Promise<void> => {
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
        outcome = "done"
      } else if (r.account && (await sharedGrantInUse(impl, linked, r.account, r.connection))) {
        console.log(JSON.stringify({ msg: "provider revocation skipped: the grant is still used by another connection", connection: r.connection, provider: r.provider }))
        outcome = "done"
      } else {
        const credential = JSON.parse(await open(env.INTEGRATIONS_KEK, JSON.parse(r.sealed) as SealedSecret, aadFor(r.connection, r.owner, r.provider, Number(r.generation)))) as Credential
        outcome = await impl.revoke(env, http, credential)
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
