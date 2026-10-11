import { freshTimestamp, hmacHex, sha256Hex, timingSafeEqual } from "./verify.ts"

/**
 * Per-provider webhook verifiers (spec integrations.md). Each takes the raw
 * body and headers, checks the signature with a constant-time compare and the
 * provider's replay rule, and returns a normalized delivery with ids only:
 * the provider account (to find the connection), a delivery id (dedupe), the
 * event type and, where the provider requires it, an immediate reply.
 */

export type Provider = "github" | "slack" | "linear"

export interface Delivery {
  readonly provider: Provider
  /** Stable provider account key, for example `github:installation:42`, `slack:team:T1`, `linear:org:<uuid>`. */
  readonly account: string
  /**
   * Dedupe id from signed content only: Slack's event_id is in the signed body;
   * GitHub and Linear send their delivery ids in unsigned headers, so the id is
   * the body hash (their bodies carry unique ids and times).
   */
  readonly delivery_id: string
  /** Provider event type, for example `pull_request.opened`, `message`, `Issue.create`. */
  readonly event: string
  readonly payload: unknown
}

export type Verified =
  | { ok: true; delivery: Delivery }
  /** Verified, but answered at once (Slack URL verification); nothing to deliver. */
  | { ok: true; reply: { status: number; body: unknown } }
  | { ok: false; status: 400 | 401; message: string }

const bad = (status: 400 | 401, message: string): Verified => ({ ok: false, status, message })

const parse = (text: string): Record<string, unknown> | undefined => {
  try {
    const v = JSON.parse(text) as unknown
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/** GitHub App webhooks: `X-Hub-Signature-256: sha256=<hex HMAC(secret, body)>`; dedupe by `X-GitHub-Delivery` (GitHub has no signed timestamp). */
export const verifyGitHub = async (secret: string, headers: Headers, body: string): Promise<Verified> => {
  const sig = headers.get("x-hub-signature-256") ?? ""
  if (!sig.startsWith("sha256=") || !timingSafeEqual(sig.slice(7), await hmacHex(secret, body))) return bad(401, "bad signature")
  const delivery = headers.get("x-github-delivery")
  const event = headers.get("x-github-event")
  if (!delivery || !event) return bad(400, "missing X-GitHub-Delivery or X-GitHub-Event")
  const p = parse(body)
  if (!p) return bad(400, "body is not a JSON object")
  const installation = (p.installation as { id?: unknown } | undefined)?.id
  if (typeof installation !== "number") return bad(400, "no installation id (only GitHub App webhooks are accepted)")
  const action = typeof p.action === "string" ? `.${p.action}` : ""
  const signed = (await sha256Hex(body)).slice(0, 40)
  return { ok: true, delivery: { provider: "github", account: `github:installation:${installation}`, delivery_id: `sha256:${signed}`, event: `${event}${action}`, payload: p } }
}

/**
 * Slack Events API: `X-Slack-Signature: v0=<hex HMAC(secret, "v0:<ts>:<body>")>`
 * with `X-Slack-Request-Timestamp` within five minutes; dedupe by `event_id`;
 * `url_verification` answers the challenge.
 */
export const verifySlack = async (secret: string, headers: Headers, body: string, now: number): Promise<Verified> => {
  const ts = headers.get("x-slack-request-timestamp")
  if (!freshTimestamp(ts, now)) return bad(401, "missing or stale X-Slack-Request-Timestamp")
  const sig = headers.get("x-slack-signature") ?? ""
  if (!sig.startsWith("v0=") || !timingSafeEqual(sig.slice(3), await hmacHex(secret, `v0:${ts}:${body}`))) return bad(401, "bad signature")
  const p = parse(body)
  if (!p) return bad(400, "body is not a JSON object")
  if (p.type === "url_verification" && typeof p.challenge === "string") return { ok: true, reply: { status: 200, body: { challenge: p.challenge } } }
  if (p.type !== "event_callback") return { ok: true, reply: { status: 200, body: { ok: true } } }
  const team = p.team_id
  const eventId = p.event_id
  const type = (p.event as { type?: unknown } | undefined)?.type
  if (typeof team !== "string" || typeof eventId !== "string" || typeof type !== "string") return bad(400, "event_callback without team_id, event_id or event.type")
  return { ok: true, delivery: { provider: "slack", account: `slack:team:${team}`, delivery_id: eventId, event: type, payload: p } }
}

/**
 * Linear: `Linear-Signature: <hex HMAC(secret, body)>`; `webhookTimestamp`
 * (ms) in the body within one minute (Linear's recommendation); dedupe by
 * `Linear-Delivery`.
 */
export const verifyLinear = async (secret: string, headers: Headers, body: string, now: number): Promise<Verified> => {
  const sig = headers.get("linear-signature") ?? ""
  if (!sig || !timingSafeEqual(sig, await hmacHex(secret, body))) return bad(401, "bad signature")
  const p = parse(body)
  if (!p) return bad(400, "body is not a JSON object")
  const ts = p.webhookTimestamp
  if (typeof ts !== "number" || Math.abs(now - ts) > 60_000) return bad(401, "stale webhookTimestamp")
  const delivery = headers.get("linear-delivery")
  const org = p.organizationId
  if (!delivery || typeof org !== "string") return bad(400, "missing Linear-Delivery or organizationId")
  const type = typeof p.type === "string" ? p.type : (headers.get("linear-event") ?? "unknown")
  const action = typeof p.action === "string" ? `.${p.action}` : ""
  const signed = (await sha256Hex(body)).slice(0, 40)
  return { ok: true, delivery: { provider: "linear", account: `linear:org:${org}`, delivery_id: `sha256:${signed}`, event: `${type}${action}`, payload: p } }
}
