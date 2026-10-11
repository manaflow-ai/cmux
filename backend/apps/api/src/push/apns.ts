import type { FeedItem, PushTarget } from "@cmux/protocol"
import { importPKCS8, SignJWT } from "jose"

/**
 * APNs sender for owner-decided pushes (plans/cmux-next/feed.md 7.3). A
 * deployed Worker's fetch reaches APNs over HTTP/2 through Cloudflare's edge;
 * `wrangler dev` does not (HTTP/1.1), so local runs only build requests.
 * Secrets: APNS_KEY_P8 (PKCS#8 PEM), APNS_KEY_ID, APNS_TEAM_ID.
 */

export interface ApnsConfig {
  readonly keyP8: string
  readonly keyId: string
  readonly teamId: string
}

export const apnsConfig = (env: { APNS_KEY_P8?: string; APNS_KEY_ID?: string; APNS_TEAM_ID?: string }): ApnsConfig | null =>
  env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID ? { keyP8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID } : null

/** Apple wants one token reused for 20 to 60 minutes; one per isolate, renewed after 50 or when Apple refuses it. */
let cached: { id: string; token: string; at: number } | undefined

const configId = (c: ApnsConfig) => `${c.teamId}:${c.keyId}:${c.keyP8.length}:${c.keyP8.slice(-16)}`

export const forgetProviderToken = () => {
  cached = undefined
}

export const providerToken = async (config: ApnsConfig, now: number): Promise<string> => {
  if (cached && cached.id === configId(config) && now - cached.at < 50 * 60_000) return cached.token
  const key = await importPKCS8(config.keyP8.replace(/\\n/g, "\n"), "ES256")
  const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.keyId }).setIssuer(config.teamId).setIssuedAt(Math.floor(now / 1000)).sign(key)
  cached = { id: configId(config), token, at: now }
  return token
}

/**
 * The notification for one feed item. Text is the item's title and its poster;
 * mail items (FD1) carry no content, only ids, so the app fetches what to show.
 * `category` lets the iPhone offer answer actions for the kind.
 */
/** Cuts text to at most `max` code points (never inside a surrogate pair). */
export const cut = (text: string, max: number) => Array.from(text).slice(0, max).join("")

/** APNs refuses payloads over 4 KB; text is cut well below it. */
export const APNS_MAX_PAYLOAD_BYTES = 4096

export const apnsPayload = (item: FeedItem) => {
  const mail = item.kind === "mail"
  const poster = cut([item.poster.harness, item.poster.label].filter(Boolean).join(" · "), 120)
  return {
    aps: {
      alert: mail ? { title: "New mail" } : { title: cut(item.title, 200), ...(poster ? { subtitle: poster } : {}), ...(item.body && item.type === "notice" ? { body: cut(item.body, 240) } : {}) },
      sound: "default",
      "thread-id": item.thread ?? item.id,
      category: `FEED_${item.type === "request" ? item.kind.toUpperCase().replace(/[^A-Z0-9]/g, "_") : "NOTICE"}`,
      ...(item.priority === "urgent" ? { "interruption-level": "time-sensitive" } : {})
    },
    cmux: { feed_item: item.id, kind: item.kind, type: item.type }
  }
}

/** The JSON body, guaranteed under the APNs limit (falls back to the title alone). */
export const payloadText = (item: FeedItem): string => {
  const full = JSON.stringify(apnsPayload(item))
  if (new TextEncoder().encode(full).length <= APNS_MAX_PAYLOAD_BYTES) return full
  return JSON.stringify({ aps: { alert: { title: cut(item.title, 100) }, sound: "default" }, cmux: { feed_item: item.id } })
}

/**
 * One alert for APNs, independent of who decided it (FeedDO for feed items, UserDO for Home
 * messages): the JSON body (under APNS_MAX_PAYLOAD_BYTES), the collapse id, the priority and
 * when APNs may drop it.
 */
export interface ApnsMessage {
  readonly body: string
  readonly collapseId: string
  readonly priority: "5" | "10"
  /** Unix ms. */
  readonly expiresAt: number
}

/** The message for one feed item. */
export const feedMessage = (item: FeedItem, now: number): ApnsMessage => ({
  body: payloadText(item),
  collapseId: item.id.slice(0, 64),
  priority: item.priority === "low" ? "5" : "10",
  // An item stops mattering when it closes or expires; APNs drops it after that.
  expiresAt: Math.min(item.expires_at, now + 24 * 3600_000)
})

export const apnsMessageRequest = (target: PushTarget, message: ApnsMessage, token: string): Request => {
  const host = target.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
  return new Request(`https://${host}/3/device/${target.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": target.topic,
      "apns-push-type": "alert",
      "apns-priority": message.priority,
      "apns-expiration": String(Math.floor(message.expiresAt / 1000)),
      "apns-collapse-id": message.collapseId.slice(0, 64),
      "content-type": "application/json"
    },
    body: message.body
  })
}

export const apnsRequest = (target: PushTarget, item: FeedItem, token: string, now: number): Request => apnsMessageRequest(target, feedMessage(item, now), token)

/** What to do with a target after one APNs answer. */
export type ApnsOutcome = "sent" | "drop_target" | "retry_later" | "failed"

export const classifyApns = (status: number, reason: string | undefined): ApnsOutcome => {
  if (status === 200) return "sent"
  if (status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") return "drop_target"
  if (status === 429 || status >= 500) return "retry_later"
  return "failed"
}

export interface SendResult {
  readonly token: string
  readonly outcome: ApnsOutcome
  readonly status: number
  readonly reason?: string
}

/** Sends one message to every target; never throws (each answer is classified). */
export const sendApnsMessage = async (config: ApnsConfig, targets: ReadonlyArray<PushTarget>, message: ApnsMessage, now: number, fetcher: typeof fetch = fetch): Promise<ReadonlyArray<SendResult>> => {
  if (targets.length === 0) return []
  const token = await providerToken(config, now)
  return Promise.all(
    targets.map(async (t) => {
      try {
        const res = await fetcher(apnsMessageRequest(t, message, token))
        const reason = res.status === 200 ? undefined : ((await res.json().catch(() => ({}))) as { reason?: string }).reason
        // A refused provider token is minted again on the next send.
        if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) forgetProviderToken()
        return { token: t.token, outcome: classifyApns(res.status, reason), status: res.status, ...(reason ? { reason } : {}) }
      } catch (e) {
        return { token: t.token, outcome: "retry_later" as const, status: 0, reason: String(e).slice(0, 120) }
      }
    })
  )
}

/** Sends one feed item to every target; never throws. */
export const sendApns = (config: ApnsConfig, targets: ReadonlyArray<PushTarget>, item: FeedItem, now: number, fetcher: typeof fetch = fetch): Promise<ReadonlyArray<SendResult>> =>
  sendApnsMessage(config, targets, feedMessage(item, now), now, fetcher)
