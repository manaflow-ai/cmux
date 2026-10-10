import { invites } from "@cmux/home-core"
import { CONTACT_PHOTO_JPEG_BASE64 } from "./contact-photo.ts"
import type { Env } from "./env.ts"

/**
 * Text (iMessage or SMS through SendBlue) for invites (stage C part 2, decision 2026-10-02):
 * the first contact with a number gets the cmux contact card first (.vcf as media), and the invite
 * text only after SendBlue reports the card SENT or DELIVERED; later invites get the text alone.
 * Status arrives on POST /v1/hooks/sendblue. The webhook secret is shared, not a signature, so the
 * route acts only on SendBlue's own record of the message (GET /api/v2/messages/<handle>).
 */

export const CARD_PATH = "/v1/home/cmux.vcf"

/** The hosted contact card: name cmux, the sending line, the photo. */
export const handleContactCard = (env: Env): Response => {
  if (!env.SENDBLUE_FROM_NUMBER || !env.HOME_INVITE_ORIGIN) return new Response("not configured", { status: 404 })
  const vcard = invites.renderVCard({ name: "cmux", phone: env.SENDBLUE_FROM_NUMBER, url: env.HOME_INVITE_ORIGIN, photoJpegBase64: CONTACT_PHOTO_JPEG_BASE64 })
  return new Response(vcard, { headers: { "content-type": "text/vcard; charset=utf-8", "content-disposition": 'attachment; filename="cmux.vcf"', "cache-control": "public, max-age=3600" } })
}

/** The public https base of this API Worker (status callbacks and the card URL). */
export const apiOrigin = (env: Env): string | null =>
  env.WORKER_NAME === "cmux-api" ? "https://cloud-api.cmux.dev" : env.WORKER_NAME === "cmux-api-staging" ? "https://cloud-api-staging.cmux.dev" : null

export const sendblueConfig = (env: Env): invites.SendblueConfig | null => {
  const origin = apiOrigin(env)
  if (!env.SENDBLUE_API_KEY || !env.SENDBLUE_API_SECRET || !env.SENDBLUE_FROM_NUMBER || !origin) return null
  return { apiKeyId: env.SENDBLUE_API_KEY, apiSecret: env.SENDBLUE_API_SECRET, fromNumber: env.SENDBLUE_FROM_NUMBER, statusCallback: `${origin}/v1/hooks/sendblue` }
}

export interface SendblueMessage {
  readonly message_handle: string
  readonly status: string
  readonly number: string
  readonly is_outbound: boolean
  readonly content: string
  readonly opted_out: boolean
}

/** SendBlue's own record of a message; null when it does not exist or the API refuses. */
export const fetchSendblueMessage = async (env: Env, handle: string, fetcher: typeof fetch = fetch): Promise<SendblueMessage | null> => {
  if (!env.SENDBLUE_API_KEY || !env.SENDBLUE_API_SECRET || !/^[A-Za-z0-9-]{8,80}$/.test(handle)) return null
  const res = await fetcher(`https://api.sendblue.com/api/v2/messages/${handle}`, { headers: { "sb-api-key-id": env.SENDBLUE_API_KEY, "sb-api-secret-key": env.SENDBLUE_API_SECRET } }).catch(() => null)
  if (!res || !res.ok) return null
  const body = (await res.json().catch(() => null)) as Record<string, unknown> | null
  const m = (body && typeof body.data === "object" && body.data ? body.data : body) as Record<string, unknown> | null
  if (!m || m.message_handle !== handle || typeof m.status !== "string" || typeof m.number !== "string") return null
  return { message_handle: handle, status: m.status, number: m.number, is_outbound: m.is_outbound !== false, content: typeof m.content === "string" ? m.content : "", opted_out: m.opted_out === true }
}

/**
 * POST /v1/hooks/sendblue: the shared secret header first, then SendBlue's record of the handle,
 * then the AddressDO of that number (HMAC id). Answers 200 for anything it ignores, so SendBlue
 * does not retry; 401 for a wrong secret; 503 when SendBlue's API cannot be read (retried).
 */
export const handleSendblueHook = async (request: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> => {
  if (request.method !== "POST") return new Response("method not allowed", { status: 405 })
  const headers = Object.fromEntries([...request.headers].map(([k, v]) => [k.toLowerCase(), v]))
  if (!env.SENDBLUE_WEBHOOK_SECRET || !invites.verifySendblueWebhook(env.SENDBLUE_WEBHOOK_SECRET, headers, env.SENDBLUE_WEBHOOK_HEADER ?? "sb-signing-secret")) {
    return new Response("unauthorized", { status: 401 })
  }
  const body = (await request.json().catch(() => null)) as { message_handle?: unknown } | null
  const handle = typeof body?.message_handle === "string" ? body.message_handle : ""
  if (!handle || !env.HOME_ADDRESS_KEY) return new Response(null, { status: 200 })
  const message = await fetchSendblueMessage(env, handle, fetcher)
  if (!message) return new Response("message not readable", { status: 503 })
  const phone = invites.normalizePhone(message.number)
  if (!invites.isAddress(phone)) return new Response(null, { status: 200 })
  const id = invites.addressId(env.HOME_ADDRESS_KEY, phone)
  const stub = env.ADDRESS_DO.get(env.ADDRESS_DO.idFromName(id)) as unknown as { textEvent(address: string, m: SendblueMessage): Promise<void> }
  await stub.textEvent(id, message)
  return new Response(null, { status: 200 })
}
