import type { Env } from "../env.ts"

// RFD 0123 (Chief in Slack), Plan and billing: a Slack message costs only the awake time it causes. The brain times
// each turn a Slack message started, keeps it per Slack sender and UTC day, and reports it to cmux-platform's usage
// store as `chief.slack_awake_seconds` (cmux-platform#1884: user = the paying owner, label = the Slack sender).
// A non-owner's messages stop waking the Chief once that sender's day reaches the allowance; they still reach the
// conversation, so the owner sees them, and ride along as context with the next turn.

/** cmux-platform Units.ts SLACK_NON_OWNER_DAILY_AWAKE_SECONDS: the RFD's default 2 awake hours a day. */
export const SLACK_NON_OWNER_DAILY_AWAKE_SECONDS = 2 * 3600

export const SLACK_METER_SCHEMA = [
  // Who sent each Slack message that reached this brain (the turn's trigger is looked up here at its end).
  `CREATE TABLE IF NOT EXISTS cb_slack_senders (message TEXT PRIMARY KEY, slack_team TEXT NOT NULL, slack_user TEXT NOT NULL, sender_is_owner INTEGER NOT NULL, cmux_team TEXT NOT NULL, owner TEXT NOT NULL)`,
  // One row per Slack-caused turn: its awake seconds, and whether cmux-platform has the fact yet.
  `CREATE TABLE IF NOT EXISTS cb_slack_awake (turn TEXT PRIMARY KEY, slack_team TEXT NOT NULL, slack_user TEXT NOT NULL, sender_is_owner INTEGER NOT NULL, cmux_team TEXT NOT NULL, owner TEXT NOT NULL, day TEXT NOT NULL, at INTEGER NOT NULL, seconds INTEGER NOT NULL, reported INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS cb_slack_awake_day ON cb_slack_awake (slack_team, slack_user, day)`
]

export interface SlackSender {
  readonly slackTeamId: string
  readonly slackUserId: string
  readonly senderIsOwner: boolean
  readonly cmuxTeamId: string
  readonly ownerUserId: string
}

interface Sql { exec<T extends Record<string, SqlStorageValue>>(query: string, ...bindings: unknown[]): { toArray(): T[] } }

export const utcDay = (ms: number): string => new Date(ms).toISOString().slice(0, 10)

/** Whole awake seconds of a turn, at least 1 for any turn that ran (a turn that never started costs nothing). */
export const awakeSeconds = (started: number, ended: number): number => ended > started ? Math.max(1, Math.ceil((ended - started) / 1000)) : 0

/** Units.ts slackAwakeLabel: `slack:<team>/<user>` under the store's label rules, or "" when the ids do not fit. */
export const slackAwakeLabel = (slackTeam: string, slackUser: string): string =>
  /^[A-Z0-9]{1,24}$/.test(slackTeam) && /^[A-Z0-9]{1,24}$/.test(slackUser) ? `slack:${slackTeam}/${slackUser}` : ""

export const recordSlackSender = (sql: Sql, message: string, s: SlackSender): void => {
  sql.exec(`INSERT INTO cb_slack_senders (message, slack_team, slack_user, sender_is_owner, cmux_team, owner) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`, message, s.slackTeamId, s.slackUserId, s.senderIsOwner ? 1 : 0, s.cmuxTeamId, s.ownerUserId)
}

/** Awake seconds this sender's messages caused on `day`. */
export const senderAwakeSeconds = (sql: Sql, slackTeam: string, slackUser: string, day: string): number =>
  Number(sql.exec<{ s: number | null }>(`SELECT SUM(seconds) AS s FROM cb_slack_awake WHERE slack_team = ? AND slack_user = ? AND day = ?`, slackTeam, slackUser, day).toArray()[0]?.s ?? 0)

/** Whether this message may wake the Chief: the owner always may; a non-owner until their day's allowance is spent. */
export const slackMayWake = (sql: Sql, s: SlackSender, now: number, allowance = SLACK_NON_OWNER_DAILY_AWAKE_SECONDS): boolean =>
  s.senderIsOwner || senderAwakeSeconds(sql, s.slackTeamId, s.slackUserId, utcDay(now)) < allowance

/** At a turn's end: a turn a Slack message started is metered against its sender. Returns whether a row was added. */
export const meterSlackTurn = (sql: Sql, turn: string, triggerMessage: string, started: number, ended: number): boolean => {
  const s = sql.exec<{ slack_team: string; slack_user: string; sender_is_owner: number; cmux_team: string; owner: string }>(`SELECT slack_team, slack_user, sender_is_owner, cmux_team, owner FROM cb_slack_senders WHERE message = ?`, triggerMessage).toArray()[0]
  const seconds = awakeSeconds(started, ended)
  if (!s || seconds === 0) return false
  return sql.exec(`INSERT INTO cb_slack_awake (turn, slack_team, slack_user, sender_is_owner, cmux_team, owner, day, at, seconds) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING RETURNING turn`, turn, s.slack_team, s.slack_user, s.sender_is_owner, s.cmux_team, s.owner, utcDay(started), started, seconds).toArray().length > 0
}

export interface AwakeFact {
  readonly key: string
  readonly unit: "chief.slack_awake_seconds"
  readonly quantity: number
  readonly at: number
  readonly user: string
  readonly source: "chief_brain"
  readonly payer: "team"
  readonly label: string
}

/** The usage fact of one metered turn; its key is the turn's, so a resend is a duplicate, never a second charge. */
export const awakeFact = (agent: string, r: { turn: string; owner: string; slack_team: string; slack_user: string; at: number; seconds: number }): AwakeFact => ({
  key: `chief-slack:${agent}:${r.turn}`,
  unit: "chief.slack_awake_seconds",
  quantity: r.seconds,
  at: r.at,
  user: r.owner,
  source: "chief_brain",
  payer: "team",
  label: slackAwakeLabel(r.slack_team, r.slack_user)
})

/**
 * Sends the facts cmux-platform does not have yet, per cmux team, at most `limit` rows per call; a failed send keeps
 * the rows for the next turn's end. One bounded attempt: callers run it under waitUntil, never on a turn's path.
 */
export async function reportSlackAwake(env: Pick<Env, "PLATFORM" | "INTERNAL_TOKEN">, sql: Sql, agent: string, limit = 100): Promise<number> {
  if (!env.PLATFORM || !env.INTERNAL_TOKEN) return 0
  const rows = sql.exec<{ turn: string; owner: string; cmux_team: string; slack_team: string; slack_user: string; at: number; seconds: number }>(`SELECT turn, owner, cmux_team, slack_team, slack_user, at, seconds FROM cb_slack_awake WHERE reported = 0 ORDER BY at LIMIT ?`, limit).toArray()
  const byTeam = new Map<string, typeof rows>()
  for (const r of rows) byTeam.set(r.cmux_team, [...(byTeam.get(r.cmux_team) ?? []), r])
  let sent = 0
  for (const [team, teamRows] of byTeam) {
    try {
      const res = await env.PLATFORM.fetch(`https://platform/internal/v1/usage/${encodeURIComponent(team)}/facts`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${env.INTERNAL_TOKEN}` },
        body: JSON.stringify({ facts: teamRows.map((r) => awakeFact(agent, r)) }),
        signal: AbortSignal.timeout(10_000)
      })
      if (!res.ok) {
        console.warn(JSON.stringify({ msg: "chief_slack.awake_report_failed", status: res.status }))
        await res.body?.cancel()
        continue
      }
      const body = await res.json() as { refused?: Array<{ index?: unknown; error?: unknown }> }
      const refused = new Set((body.refused ?? []).map((r) => r.index))
      // A refused fact will be refused again: mark it reported (2) so it stops resending, and log it.
      teamRows.forEach((r, i) => sql.exec(`UPDATE cb_slack_awake SET reported = ? WHERE turn = ?`, refused.has(i) ? 2 : 1, r.turn))
      if (refused.size) console.warn(JSON.stringify({ msg: "chief_slack.awake_fact_refused", count: refused.size, error: String(body.refused?.[0]?.error ?? "").slice(0, 200) }))
      sent += teamRows.length - refused.size
    } catch {
      console.warn(JSON.stringify({ msg: "chief_slack.awake_report_failed" }))
    }
  }
  return sent
}
