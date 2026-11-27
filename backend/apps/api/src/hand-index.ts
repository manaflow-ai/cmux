import type { HandSummary } from "./hand-wire.ts"

/**
 * The owner's hand index: the HandDO named `owner:<user>` (one object per person, the unit that
 * serializes "which hands and which Chief grants does this person have"). It lists the person's
 * hands and holds the `hands` grant per Chief: a granted Chief may mint pairing codes and call the
 * person's hands. Each hand object keeps its own copy of the grant list (pushed on change), so a
 * call costs no hop to the index.
 */
export const indexName = (user: string) => `owner:${user}`
export const handName = (hand: string) => `h:${hand}`

export const createIndexTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_index (hand TEXT PRIMARY KEY, body TEXT NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_grant_index (agent TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_default_level (profile TEXT PRIMARY KEY, level TEXT NOT NULL)`)
}

/** The owner's default level for new hands of `profile`, if set. */
export const indexDefaultLevel = (sql: SqlStorage, profile: string): string | undefined =>
  sql.exec<{ level: string }>(`SELECT level FROM hand_default_level WHERE profile = ?`, profile).toArray()[0]?.level

export const indexSetDefaultLevel = (sql: SqlStorage, profile: string, level: string) =>
  sql.exec(`INSERT INTO hand_default_level (profile, level) VALUES (?, ?) ON CONFLICT(profile) DO UPDATE SET level = excluded.level`, profile, level)

export const indexPut = (sql: SqlStorage, summary: HandSummary | { hand: string; removed: true }) => {
  if ("removed" in summary) {
    sql.exec(`DELETE FROM hand_index WHERE hand = ?`, summary.hand)
    return
  }
  sql.exec(`INSERT INTO hand_index (hand, body) VALUES (?, ?) ON CONFLICT(hand) DO UPDATE SET body = excluded.body`, summary.hand, JSON.stringify(summary))
}

export const indexList = (sql: SqlStorage): Array<HandSummary> =>
  sql
    .exec<{ body: string }>(`SELECT body FROM hand_index ORDER BY hand`)
    .toArray()
    .map((r) => JSON.parse(r.body) as HandSummary)

export const indexGrants = (sql: SqlStorage): Array<string> => sql.exec<{ agent: string }>(`SELECT agent FROM hand_grant_index ORDER BY agent`).toArray().map((r) => r.agent)

export const indexSetGrant = (sql: SqlStorage, agent: string, on: boolean, now: number) => {
  if (on) sql.exec(`INSERT INTO hand_grant_index (agent, at) VALUES (?, ?) ON CONFLICT(agent) DO NOTHING`, agent, now)
  else sql.exec(`DELETE FROM hand_grant_index WHERE agent = ?`, agent)
}
