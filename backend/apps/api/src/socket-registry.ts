import type { Env } from "./env.ts"

/**
 * Instant revocation for sockets (coordinator (e), Lawrence Q2): every owner that accepts a socket
 * of an install registers it in the user's UserDO; `install.revoke` then closes those sockets on
 * every owner at once (closeInstall RPC). A row lives until the socket's token expires (a socket
 * never outlives its token). A failed close stays `closing` and the UserDO alarm retries it.
 * Tables live in UserDO storage; nothing here is user content.
 */
const TABLE = `CREATE TABLE IF NOT EXISTS socket_owners (install TEXT NOT NULL, cls TEXT NOT NULL, name TEXT NOT NULL, expires_at INTEGER NOT NULL, closing INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (install, cls, name))`
/** Retry delay for a close that failed (an unreachable owner). */
const CLOSE_RETRY_MS = 5_000
const OWNER_CLASS = /^[A-Z][A-Za-z]{1,40}DO$/

const bindingOf = (cls: string) => cls.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toUpperCase()

export const registerSocketOwner = (sql: SqlStorage, install: string, cls: string, name: string, expiresAt: number, now: number): void => {
  if (!OWNER_CLASS.test(cls) || name.length === 0 || name.length > 200) return
  sql.exec(TABLE)
  sql.exec(`DELETE FROM socket_owners WHERE expires_at <= ? AND closing = 0`, now)
  sql.exec(
    `INSERT INTO socket_owners (install, cls, name, expires_at) VALUES (?, ?, ?, ?) ON CONFLICT (install, cls, name) DO UPDATE SET expires_at = MAX(expires_at, excluded.expires_at)`,
    install,
    cls,
    name,
    expiresAt
  )
}

/** Marks every live owner of `install` for closing (in the revoke's turn). */
export const markInstallClosing = (sql: SqlStorage, install: string, now: number): number => {
  sql.exec(TABLE)
  sql.exec(`DELETE FROM socket_owners WHERE install = ? AND expires_at <= ?`, install, now)
  return sql.exec(`UPDATE socket_owners SET closing = 1 WHERE install = ?`, install).rowsWritten
}

/** When a pending close is due again, or null. */
export const nextCloseAt = (sql: SqlStorage, retryAt: number | null): number | null => {
  if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'socket_owners'`).toArray().length === 0) return null
  const n = Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM socket_owners WHERE closing = 1`).toArray()[0]?.n ?? 0)
  return n === 0 ? null : (retryAt ?? Date.now())
}

/**
 * Sends closeInstall to every owner marked closing; a delivered (or expired) row goes, a failed one
 * stays for the next try. Returns whether any close failed.
 */
export const flushInstallCloses = async (sql: SqlStorage, env: Env, now: number): Promise<boolean> => {
  if (sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'socket_owners'`).toArray().length === 0) return false
  sql.exec(`DELETE FROM socket_owners WHERE closing = 1 AND expires_at <= ?`, now)
  const rows = sql.exec<{ install: string; cls: string; name: string }>(`SELECT install, cls, name FROM socket_owners WHERE closing = 1 LIMIT 200`).toArray()
  let failed = false
  await Promise.all(
    rows.map(async (r) => {
      const ns = (env as unknown as Record<string, DurableObjectNamespace | undefined>)[bindingOf(r.cls)]
      const ok = ns
        ? await (ns.get(ns.idFromName(r.name)) as unknown as { closeInstall(entity: string, install: string): Promise<boolean> }).closeInstall(r.name, r.install).then(() => true, () => false)
        : true
      if (ok) sql.exec(`DELETE FROM socket_owners WHERE install = ? AND cls = ? AND name = ?`, r.install, r.cls, r.name)
      else failed = true
    })
  )
  return failed
}

export { CLOSE_RETRY_MS }
