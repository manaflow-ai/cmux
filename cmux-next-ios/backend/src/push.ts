import { importPKCS8, SignJWT } from "jose"
import type { Env } from "./env.ts"
import type { PushKind, PushRegistration } from "./store.ts"

/**
 * APNs for Feed-worthy agent events (PROTOCOL.md `POST /v1/devices/:deviceId/notify`). A deployed Worker's
 * fetch reaches APNs over HTTP/2 through Cloudflare's edge. Secrets: APNS_KEY_P8 (PKCS#8 PEM), APNS_KEY_ID,
 * APNS_TEAM_ID. Without them `notify` answers `configured:false` and sends nothing.
 */
export interface ApnsConfig {
  readonly keyP8: string
  readonly keyId: string
  readonly teamId: string
}

export const apnsConfig = (env: Env): ApnsConfig | null =>
  env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID ? { keyP8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID } : null

/** The bundle ids a phone may register a token for (APNS_TOPICS, comma separated). */
export const apnsTopics = (env: Env): ReadonlySet<string> =>
  new Set(
    (env.APNS_TOPICS ?? "")
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean)
  )

/** Apple wants one provider token reused for 20 to 60 minutes: one per isolate, renewed after 50 or when refused. */
let cached: { id: string; token: string; at: number } | undefined
const configId = (c: ApnsConfig) => `${c.teamId}:${c.keyId}:${c.keyP8.length}:${c.keyP8.slice(-16)}`

export const providerToken = async (config: ApnsConfig, now: number): Promise<string> => {
  if (cached && cached.id === configId(config) && now - cached.at < 50 * 60_000) return cached.token
  const key = await importPKCS8(config.keyP8.replace(/\\n/g, "\n"), "ES256")
  const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.keyId }).setIssuer(config.teamId).setIssuedAt(Math.floor(now / 1000)).sign(key)
  cached = { id: configId(config), token, at: now }
  return token
}

/** What the Mac reports. Only short labels: the Worker writes the notification text itself. */
export interface NotifyEvent {
  readonly eventId: string
  readonly kind: PushKind
  readonly agent: string
  readonly place: string
  readonly macId: string
  readonly macName: string
  readonly workspaceId?: string
  readonly tabId?: string
  readonly sessionId?: string
}

/** Printable text cut to `max` code points: control and format characters become spaces. */
export const clean = (text: unknown, max: number): string =>
  typeof text !== "string"
    ? ""
    : Array.from(text.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/gu, " ").replace(/\s+/g, " ").trim())
        .slice(0, max)
        .join("")

const TITLES: Record<PushKind, (agent: string) => string> = {
  question: (a) => `${a} has a question`,
  permission: (a) => `${a} needs permission`,
  completed: (a) => `${a} finished`,
  failed: (a) => `${a} stopped with an error`,
  chief: () => "Chief replied"
}

/** The APNs JSON body: fixed text per kind, the place as the body, ids for the tap. Never agent output. */
export const apnsPayload = (e: NotifyEvent) => {
  const agent = e.agent || "Your agent"
  const ask = e.kind === "question" || e.kind === "permission"
  return {
    aps: {
      alert: { title: TITLES[e.kind](agent), body: e.place ? `${e.place} · ${e.macName}` : e.macName },
      sound: "default",
      "thread-id": e.sessionId ?? e.macId,
      category: `CMUX_MOBILE_${e.kind.toUpperCase()}`,
      ...(ask ? { "interruption-level": "time-sensitive" } : {})
    },
    mobile: {
      mac: e.macId,
      kind: e.kind,
      eventId: e.eventId,
      ...(e.workspaceId ? { workspaceId: e.workspaceId } : {}),
      ...(e.tabId ? { tabId: e.tabId } : {}),
      ...(e.sessionId ? { sessionId: e.sessionId } : {})
    }
  }
}

export const apnsRequest = (target: PushRegistration, e: NotifyEvent, token: string, now: number): Request => {
  const host = target.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
  const ask = e.kind === "question" || e.kind === "permission"
  return new Request(`https://${host}/3/device/${target.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": target.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // An ask matters for a day; a finished turn for an hour.
      "apns-expiration": String(Math.floor((now + (ask ? 24 * 3600_000 : 3600_000)) / 1000)),
      "apns-collapse-id": e.eventId.slice(0, 64),
      "content-type": "application/json"
    },
    body: JSON.stringify(apnsPayload(e))
  })
}

export type ApnsOutcome = "sent" | "drop_target" | "failed"

export const classifyApns = (status: number, reason: string | undefined): ApnsOutcome => {
  if (status === 200) return "sent"
  if (status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") return "drop_target"
  return "failed"
}

/** Sends one event to every target; never throws. */
export const sendApns = async (
  config: ApnsConfig,
  targets: ReadonlyArray<PushRegistration>,
  e: NotifyEvent,
  now: number,
  fetcher: typeof fetch = fetch
): Promise<Array<{ token: string; outcome: ApnsOutcome; status: number; reason?: string }>> => {
  if (targets.length === 0) return []
  const token = await providerToken(config, now)
  return Promise.all(
    targets.map(async (t) => {
      try {
        const res = await fetcher(apnsRequest(t, e, token, now))
        const reason = res.status === 200 ? undefined : ((await res.json().catch(() => ({}))) as { reason?: string }).reason
        if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) cached = undefined
        return { token: t.token, outcome: classifyApns(res.status, reason), status: res.status, ...(reason ? { reason } : {}) }
      } catch (err) {
        return { token: t.token, outcome: "failed" as const, status: 0, reason: String(err).slice(0, 120) }
      }
    })
  )
}
