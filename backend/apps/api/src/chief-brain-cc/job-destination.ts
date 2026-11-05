import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { postSlackMessage, slackEnabled, type SlackDestination } from "../chief-slack.ts"
import type { Env } from "../env.ts"

export const validSlackDestination = (value: unknown): value is SlackDestination => {
  if (!value || typeof value !== "object") return false
  const d = value as Record<string, unknown>
  return d.type === "slack" && typeof d.slackTeamId === "string" && /^T[A-Z0-9]+$/.test(d.slackTeamId) && typeof d.channelId === "string" && /^[CDG][A-Z0-9]+$/.test(d.channelId)
}

/** Resolve a channel only from the owner's install: a model cannot select somebody else's workspace. */
export const resolveJobDestination = async (env: Env, owner: string, request: Record<string, unknown>): Promise<SlackDestination | undefined> => {
  if (request.destination === undefined && request.slack_channel === undefined) return undefined
  if (!slackEnabled(env)) throw new Error("Slack destinations are only available in development")
  if (request.destination !== undefined && !validSlackDestination(request.destination)) throw new Error("invalid Slack destination")
  if (request.slack_channel !== undefined && (typeof request.slack_channel !== "string" || !/^(?:[CDG][A-Z0-9]+|#[a-z0-9_-]+)$/.test(request.slack_channel))) throw new Error("Slack channel must be an id or #name")
  if (!env.PLATFORM || !env.INTERNAL_TOKEN) throw new Error("Slack is not connected in this deployment")
  let body: { channels?: Array<{ slackTeamId?: string; channelId?: string; id?: string; name?: string }> }
  try {
    const response = await env.PLATFORM.fetch(`https://platform/internal/v1/slack/channels?ownerUserId=${encodeURIComponent(owner)}`, {
      headers: { Authorization: `Bearer ${env.INTERNAL_TOKEN}` }, signal: AbortSignal.timeout(10_000)
    })
    if (!response.ok) { await response.body?.cancel(); throw new Error() }
    body = await response.json() as typeof body
  } catch {
    throw new Error("could not read your Slack channels")
  }
  const explicit = request.destination as SlackDestination | undefined
  const channels = (Array.isArray(body.channels) ? body.channels : []).map((c) => ({ ...c, channelId: c.channelId ?? c.id }))
  const matches = channels.filter((c) => explicit
    ? c.slackTeamId === explicit.slackTeamId && c.channelId === explicit.channelId
    : c.channelId === request.slack_channel || `#${c.name}` === request.slack_channel)
  if (matches.length !== 1) throw new Error(matches.length > 1 ? "Slack channel name is ambiguous; use its channel id" : "Slack channel is not available on your install")
  const destination = { type: "slack", slackTeamId: matches[0]!.slackTeamId, channelId: matches[0]!.channelId }
  if (!validSlackDestination(destination)) throw new Error("invalid Slack channel response")
  return destination
}

export const JOB_DESTINATION_SCHEMA = `CREATE TABLE IF NOT EXISTS cb_job_destinations (message TEXT PRIMARY KEY, destination TEXT NOT NULL, attempted INTEGER NOT NULL DEFAULT 0)`
const ready = (b: ChiefBrainDO) => b.sql.exec(JOB_DESTINATION_SCHEMA)

/** Stored before kick, beside the deduplicated inbox row; workflow redelivery never changes a destination. */
export const rememberJobDestination = (b: ChiefBrainDO, message: string, destination: SlackDestination): void => {
  ready(b)
  b.sql.exec(`INSERT INTO cb_job_destinations (message, destination) VALUES (?, ?) ON CONFLICT (message) DO NOTHING`, message, JSON.stringify(destination))
}

/** The final turn reply, once per destination. At-most-once: Slack failure never repeats an effect or delays a turn. */
export const finishJobDestinations = (b: ChiefBrainDO, turn: string): void => {
  ready(b)
  const final = b.sql.exec<{ reply: string | null; status: string; post: string }>(`SELECT reply, status, post FROM cb_turn WHERE id = ?`, turn).toArray()[0]
  if (!final || final.status !== "done" || final.post !== "posted" || !final.reply) return
  const rows = b.sql.exec<{ message: string; destination: string }>(`SELECT d.message, d.destination FROM cb_job_destinations d JOIN cb_inbox i ON i.message = d.message WHERE i.turn = ? AND d.attempted = 0`, turn).toArray()
  const destinations = new Map<string, SlackDestination>()
  for (const row of rows) {
    b.sql.exec(`UPDATE cb_job_destinations SET attempted = 1 WHERE message = ?`, row.message)
    const destination: unknown = JSON.parse(row.destination)
    if (validSlackDestination(destination)) destinations.set(`${destination.slackTeamId}:${destination.channelId}`, destination)
  }
  const owner = b.config().owner
  for (const destination of destinations.values()) b.doCtx.waitUntil((async () => {
    try {
      // The ordinary automation API also accepts destinations. Recheck at delivery so an
      // arbitrary team id (or an uninstalled workspace) never receives this owner's answer.
      if (!owner) return
      const allowed = await resolveJobDestination(b.doEnv, owner, { destination })
      if (allowed) await postSlackMessage(b.doEnv, { ...allowed, text: final.reply! })
    } catch {
      console.warn(JSON.stringify({ msg: "chief.slack.automation_delivery_failed" }))
    }
  })())
}
