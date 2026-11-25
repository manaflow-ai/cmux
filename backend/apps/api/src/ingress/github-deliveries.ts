/**
 * One GitHub delivery is processed once per team connection (ConnectionDO.ingest, one DO per team),
 * keyed by GitHub's own `X-GitHub-Delivery` GUID, which GitHub keeps across its redeliveries.
 *
 * The GUID header is not covered by `X-Hub-Signature-256`, so a captured signed body re-sent under a
 * new GUID is refused too: a body digest already recorded under another GUID is a replay. A delivery
 * whose processing failed part way (the hook answered 502) stays claimed but not done, so GitHub's
 * redelivery of the same GUID runs again; the scheduler and Chief jobs dedupe what already ran by
 * the same delivery id.
 *
 * Rows live four days: GitHub redelivers for three (the platform feed's DELIVERY_TTL_MS keeps the same).
 * Each claim deletes the expired rows through the `at` index, so the table stays bounded by four days
 * of one team's deliveries.
 */

/** GitHub permits redelivery for three days; delivery GUIDs are kept a day longer. */
export const GITHUB_DELIVERY_TTL_MS = 4 * 24 * 60 * 60 * 1000

export type DeliveryClaim =
  /** First sight of this GUID and body: process it. */
  | "new"
  /** Same GUID claimed before but not finished (a failed attempt): process it again. */
  | "retry"
  /** Same GUID already processed: answer success, do nothing. */
  | "duplicate"
  /** Same signed body under a different GUID: a replay with a forged header; do nothing. */
  | "replayed"

export const createGitHubDeliveryTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS github_deliveries (
    connection TEXT NOT NULL, guid TEXT NOT NULL, digest TEXT NOT NULL, at INTEGER NOT NULL, done INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (connection, guid))`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_deliveries_digest ON github_deliveries (connection, digest)`)
  sql.exec(`CREATE INDEX IF NOT EXISTS github_deliveries_at ON github_deliveries (at)`)
}

export const claimGitHubDelivery = (sql: SqlStorage, connection: string, guid: string, digest: string, now: number): DeliveryClaim => {
  sql.exec(`DELETE FROM github_deliveries WHERE at < ?`, now - GITHUB_DELIVERY_TTL_MS)
  const same = sql
    .exec<{ done: number; digest: string }>(`SELECT done, digest FROM github_deliveries WHERE connection = ? AND guid = ?`, connection, guid)
    .toArray()[0]
  // A known GUID with another body is a forged header too: the GUID names one delivery.
  if (same) return same.digest !== digest ? "replayed" : same.done ? "duplicate" : "retry"
  const other = sql.exec<{ guid: string }>(`SELECT guid FROM github_deliveries WHERE connection = ? AND digest = ? LIMIT 1`, connection, digest).toArray()[0]
  if (other) return "replayed"
  sql.exec(`INSERT INTO github_deliveries (connection, guid, digest, at, done) VALUES (?, ?, ?, ?, 0)`, connection, guid, digest, now)
  return "new"
}

export const finishGitHubDelivery = (sql: SqlStorage, connection: string, guid: string) => {
  sql.exec(`UPDATE github_deliveries SET done = 1 WHERE connection = ? AND guid = ?`, connection, guid)
}
