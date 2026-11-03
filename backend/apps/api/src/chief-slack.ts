import type { conversation } from "@cmux/home-core"
import type { Env } from "./env.ts"

/** Authenticated by the platform's Slack signature/install lookup, never a public API body. */
export interface SlackInbound {
  readonly slackTeamId: string
  readonly channelId: string
  readonly threadTs: string
  readonly ts: string
  readonly slackUserId: string
  /** Trusted install identity supplied by the platform, never a Slack display name. */
  readonly botUserId?: string
  readonly slackUserName: string
  readonly isOwner: boolean
  readonly text: string
  readonly permalink: string
  readonly ownerUserId: string
  readonly cmuxTeamId: string
  readonly channelName?: string
}

export interface SlackDestination {
  readonly type: "slack"
  readonly slackTeamId: string
  readonly channelId: string
}

export interface SlackMessage {
  readonly slackTeamId: string
  readonly channelId: string
  readonly threadTs?: string
  readonly text: string
}

export const slackEnabled = (env: Pick<Env, "ENVIRONMENT">): boolean => env.ENVIRONMENT === "development" || env.ENVIRONMENT === "test"

export const validSlackInbound = (v: SlackInbound): boolean => {
  if (!v || typeof v !== "object") return false
  const id = (s: unknown) => typeof s === "string" && /^[A-Z][A-Z0-9]{1,80}$/.test(s)
  const ts = (s: unknown) => typeof s === "string" && /^\d{1,20}\.\d{1,10}$/.test(s)
  return id(v.slackTeamId) && id(v.channelId) && id(v.slackUserId) && ts(v.threadTs) && ts(v.ts)
    && (v.botUserId === undefined || id(v.botUserId))
    && typeof v.isOwner === "boolean" && typeof v.text === "string" && v.text.trim().length > 0 && new TextEncoder().encode(v.text).length <= 64_000
    && typeof v.slackUserName === "string" && v.slackUserName.length > 0 && v.slackUserName.length <= 200 && !/\p{Cc}/u.test(v.slackUserName)
    && typeof v.ownerUserId === "string" && /^user_[A-Za-z0-9_-]{1,128}$/.test(v.ownerUserId)
    && typeof v.cmuxTeamId === "string" && /^team_[A-Za-z0-9_-]{1,128}$/.test(v.cmuxTeamId)
    && typeof v.permalink === "string" && /^https:\/\//.test(v.permalink) && v.permalink.length <= 4096
    && (v.channelName === undefined || (typeof v.channelName === "string" && v.channelName.length <= 100 && !/\p{Cc}/u.test(v.channelName)))
}

export const isOwnSlackMessage = (v: SlackInbound): boolean => v.botUserId !== undefined && v.slackUserId === v.botUserId

/** One bounded binding-internal attempt. The caller schedules this with waitUntil, never awaits a turn on Slack. */
export async function postSlackMessage(env: Pick<Env, "ENVIRONMENT" | "PLATFORM" | "INTERNAL_TOKEN">, message: SlackMessage): Promise<string | undefined> {
  if (!slackEnabled(env)) return
  if (!env.PLATFORM || !env.INTERNAL_TOKEN) {
    console.warn(JSON.stringify({ msg: "chief_slack.delivery_unconfigured" }))
    return
  }
  try {
    const res = await env.PLATFORM.fetch("https://platform/internal/v1/slack/messages", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${env.INTERNAL_TOKEN}` },
      body: JSON.stringify(message),
      signal: AbortSignal.timeout(10_000)
    })
    if (!res.ok) {
      console.warn(JSON.stringify({ msg: "chief_slack.delivery_failed", status: res.status }))
      await res.body?.cancel()
      return
    }
    const body = await res.json() as { ts?: unknown }
    return typeof body.ts === "string" ? body.ts : undefined
  } catch {
    // Do not log request/error bodies: a transport exception can contain credentials or message text.
    console.warn(JSON.stringify({ msg: "chief_slack.delivery_failed" }))
  }
}

/** Authority comes only from persisted metadata; display names remain quoted untrusted text. */
export const formatSlackMessage = (message: conversation.Message & { slack: { isOwner: boolean; displayName: string } }): string =>
  `[Slack participant ${message.author}; isOwner=${message.slack.isOwner === true}] displayName=${JSON.stringify(message.slack.displayName)}\n${message.parts.filter((p) => p.type === "text").map((p) => p.text).join("\n")}`
