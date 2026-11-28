import { createHmac, timingSafeEqual } from "node:crypto"
import { keywordOf } from "../address/inbound.ts"

/**
 * Provider webhooks that feed AddressDO (`address.suppress`) and
 * `invite.delivery.report`. Pure: the Worker passes headers, the raw body and
 * the clock.
 */
export type WebhookEffect =
  | { readonly kind: "delivery"; readonly provider_id: string; readonly state: "delivered" | "bounced" | "complained" | "failed" | "sent" }
  | { readonly kind: "suppress"; readonly address: string; readonly reason: "opted_out" | "bounced" | "complained" }
  | { readonly kind: "ignore" }

const safeEqual = (a: string, b: string) => {
  const x = Buffer.from(a)
  const y = Buffer.from(b)
  return x.length === y.length && timingSafeEqual(x, y)
}

/**
 * Resend signs webhooks the Svix way: headers `svix-id`, `svix-timestamp`,
 * `svix-signature` (space-separated `v1,<base64>`), HMAC-SHA256 over
 * `<id>.<timestamp>.<body>` with the base64 part of the `whsec_` secret; the
 * timestamp must be within 5 minutes.
 */
export const verifyResendWebhook = (secret: string, headers: Readonly<Record<string, string | undefined>>, body: string, nowMs: number): boolean => {
  const id = headers["svix-id"]
  const ts = headers["svix-timestamp"]
  const sig = headers["svix-signature"]
  if (!id || !ts || !sig || !/^\d{1,12}$/.test(ts)) return false
  if (Math.abs(nowMs / 1000 - Number(ts)) > 300) return false
  const key = Buffer.from(secret.startsWith("whsec_") ? secret.slice(6) : secret, "base64")
  const expected = createHmac("sha256", key).update(`${id}.${ts}.${body}`).digest("base64")
  return sig.split(" ").some((part) => {
    const [version, value] = part.split(",")
    return version === "v1" && value !== undefined && safeEqual(value, expected)
  })
}

/** Resend event types to effects (https://resend.com/docs/dashboard/webhooks/event-types). */
export const resendWebhookEffects = (payload: unknown): ReadonlyArray<WebhookEffect> => {
  const p = payload as { type?: string; data?: { email_id?: string; to?: Array<string> } } | null
  const id = p?.data?.email_id
  const to = p?.data?.to?.[0]
  if (!p?.type || !id) return [{ kind: "ignore" }]
  switch (p.type) {
    case "email.delivered":
      return [{ kind: "delivery", provider_id: id, state: "delivered" }]
    case "email.bounced":
      return [{ kind: "delivery", provider_id: id, state: "bounced" }, ...(to ? [{ kind: "suppress" as const, address: to, reason: "bounced" as const }] : [])]
    case "email.complained":
      return [{ kind: "delivery", provider_id: id, state: "complained" }, ...(to ? [{ kind: "suppress" as const, address: to, reason: "complained" as const }] : [])]
    case "email.failed":
      return [{ kind: "delivery", provider_id: id, state: "failed" }]
    default:
      return [{ kind: "ignore" }]
  }
}

/**
 * SendBlue sends the configured webhook secret in a request header; its docs
 * do not name the header, so the name is configuration (default
 * `sb-signing-secret`, UNVERIFIED until the first staging webhook arrives).
 */
export const verifySendblueWebhook = (secret: string, headers: Readonly<Record<string, string | undefined>>, headerName = "sb-signing-secret"): boolean => {
  const presented = headers[headerName.toLowerCase()]
  return Boolean(secret) && typeof presented === "string" && safeEqual(presented, secret)
}

export const sendblueWebhookEffects = (payload: unknown): ReadonlyArray<WebhookEffect> => {
  const p = payload as { is_outbound?: boolean; content?: string; number?: string; message_handle?: string; status?: string; opted_out?: boolean } | null
  if (!p) return [{ kind: "ignore" }]
  if (p.is_outbound === false) {
    if (p.number && (keywordOf(p.content ?? "") === "stop" || p.opted_out === true)) return [{ kind: "suppress", address: p.number, reason: "opted_out" }]
    return [{ kind: "ignore" }]
  }
  if (!p.message_handle) return [{ kind: "ignore" }]
  const state = p.status === "DELIVERED" ? "delivered" : p.status === "ERROR" || p.status === "DECLINED" ? "failed" : p.status === "SENT" ? "sent" : null
  const effects: Array<WebhookEffect> = state ? [{ kind: "delivery", provider_id: p.message_handle, state }] : []
  if (p.opted_out === true && p.number) effects.push({ kind: "suppress", address: p.number, reason: "opted_out" })
  return effects.length ? effects : [{ kind: "ignore" }]
}
