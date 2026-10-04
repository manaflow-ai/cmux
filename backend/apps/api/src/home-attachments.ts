import { createHash, createHmac, timingSafeEqual } from "node:crypto"
import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { authenticate, withGrantClasses } from "./auth.ts"
import type { AttachmentAccess } from "./conversation-do.ts"
import type { Env } from "./env.ts"
import { ssoGate } from "./policy-gate.ts"

/**
 * Home attachment routes (home-messaging.md section 2: "upload intent, then bytes to R2 by
 * content hash, then the message references the hash"):
 *
 * - POST /v1/home/attachments/intent {conversation, sha256, byte_count, mime_type, name, width?, height?, duration_ms?}
 *   A current participant only; type allow list, size cap, per-user byte quota. Answers
 *   {state: "exists"} for a hash this caller can already see in this conversation, otherwise
 *   {state: "upload", upload_url, method: "PUT", headers, expires_at}.
 * - PUT /v1/home/attachments/upload/<slot>: the bytes. The Worker hashes them while they stream
 *   to R2 and records the object in the ConversationDO only when SHA-256 and length match.
 * - POST /v1/home/attachments/url {conversation, hash}: a short-lived signed GET URL.
 * - GET|HEAD /v1/home/attachments/<conversation>/<sha256>?a&e&s: streams from R2 after the
 *   ConversationDO re-checks that the signed actor is still a participant who may see the hash.
 *
 * The bucket is private; nothing reaches R2 except through these routes.
 */
const CONVERSATION_ID = /^conv_(dm_)?[0-9A-HJKMNP-TV-Z]{26}$/
const L = homeConversation.ATTACHMENT_LIMITS
const NO_STORE = { "cache-control": "private, no-store" }

type Fail = { readonly status: number; readonly code: string; readonly message: string; readonly extra?: Record<string, unknown> }
const failure = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const success = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })

interface ConversationAttachments {
  attachmentAccess(entity: string, actor: string, hash: string): Promise<AttachmentAccess>
  commitAttachment(entity: string, actor: string, rec: { hash: string; object_key: string; mime_type: string; byte_count: number; name: string }): Promise<{ ok: true; state: "stored" | "exists"; object_key: string } | { ok: false; code: "auth.forbidden" }>
}
const conversationOf = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationAttachments
const quotaOf = (env: Env, user: string) =>
  env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as { takeAttachmentQuota(e: string, key: string, bytes: number): Promise<{ ok: true } | { ok: false; window: string; retry_after_ms: number }> }

const configured = (env: Env): Fail | null =>
  env.HOME_ATTACHMENTS && env.HOME_ATTACHMENT_KEY && env.HOME_ATTACHMENT_KEY.length >= 32 ? null : { status: 503, code: "home.not_configured", message: "attachments are not configured on this deployment" }

// --- Signing (HMAC-SHA256 with HOME_ATTACHMENT_KEY, domain-separated per purpose) ---

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url")
const mac = (env: Env, purpose: string, payload: string) => createHmac("sha256", env.HOME_ATTACHMENT_KEY!).update(`${purpose}\u0000${payload}`).digest()
const sameMac = (a: Buffer, b: string) => {
  const given = Buffer.from(b, "base64url")
  return given.length === a.length && timingSafeEqual(given, a)
}

interface UploadSlot {
  readonly c: string
  readonly h: string
  readonly n: number
  readonly m: string
  readonly f: string
  readonly a: string
  /** Slot nonce (log correlation; each PUT attempt still gets its own object key). */
  readonly i: string
  readonly e: number
}

const signSlot = (env: Env, slot: UploadSlot) => {
  const body = b64url(JSON.stringify(slot))
  return `${body}.${b64url(mac(env, "home-attachment-upload", body))}`
}
const openSlot = (env: Env, token: string): UploadSlot | null => {
  const [body, sig, extra] = token.split(".")
  if (!body || !sig || extra !== undefined || !sameMac(mac(env, "home-attachment-upload", body), sig)) return null
  try {
    const slot = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as UploadSlot
    return slot.e > Date.now() && CONVERSATION_ID.test(slot.c) && homeConversation.isSha256(slot.h) ? slot : null
  } catch {
    return null
  }
}

const downloadMac = (env: Env, conversation: string, hash: string, actor: string, expires: number) => mac(env, "home-attachment-download", `${conversation}\u0000${hash}\u0000${actor}\u0000${expires}`)

/** Path and query of a signed download for `actor`, valid until `expires` (ms). */
export const downloadPath = (env: Env, conversation: string, hash: string, actor: string, expires: number): string =>
  `/v1/home/attachments/${conversation}/${hash}?${new URLSearchParams({ a: actor, e: String(expires), s: b64url(downloadMac(env, conversation, hash, actor, expires)) })}`

// --- Callers ---

type Caller = { readonly principal: Principal; readonly actor: string; readonly user: string }

/** Bearer -> principal with SSO policy and the install's grant; installs need `risk` in their grant. */
const callerOf = async (request: Request, env: Env, risk: "read" | "mutate-shared"): Promise<Caller | Fail> => {
  const auth = request.headers.get("authorization") ?? ""
  const authenticated = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!authenticated?.user) return { status: 401, code: "auth.unauthenticated", message: "sign in first" }
  const gate = await ssoGate(env, authenticated)
  if (gate.refusal) return { status: 403, code: "auth.forbidden", message: gate.refusal.message }
  const { stack_session: _s, email_domain: _d, ...stripped } = gate.principal
  const principal = await withGrantClasses(env, stripped)
  if (!principal || (principal.kind !== "session" && !(principal.grant_classes ?? []).includes(risk))) return { status: 403, code: "auth.forbidden", message: `grant does not cover ${risk}` }
  const actor = homeConversation.actorOf(principal)
  if (!actor || !principal.user) return { status: 403, code: "auth.forbidden", message: "no user" }
  return { principal, actor, user: principal.user }
}

const limited = async (env: Env, user: string): Promise<Fail | null> => {
  if (!env.HOME_ATTACHMENT_LIMIT) return null
  const { success: ok } = await env.HOME_ATTACHMENT_LIMIT.limit({ key: `attachment:${user}` })
  return ok ? null : { status: 429, code: "rate_limited", message: "too many attachment requests", extra: { retry_after_ms: 60_000 } }
}

const isFail = (v: unknown): v is Fail => typeof v === "object" && v !== null && "status" in v && "code" in v

const access = async (env: Env, conversation: string, actor: string, hash: string): Promise<AttachmentAccess> => conversationOf(env, conversation).attachmentAccess(conversation, actor, hash)

// --- Routes ---

/** POST /v1/home/attachments/intent */
export const handleAttachmentIntent = async (request: Request, env: Env): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared")
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = (await request.json().catch(() => null)) as { conversation?: unknown } | null
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation)) return failure({ status: 400, code: "validation.invalid", message: "conversation id required" })
  const conversation = body.conversation
  const checked = homeConversation.validateAttachmentMeta(body)
  if (!checked.ok) return failure({ status: checked.code === "attachment.too_large" ? 413 : checked.code === "attachment.type_refused" ? 415 : 400, code: checked.code, message: checked.message })
  const meta = checked.meta
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  // Participant check before any quota, token or storage.
  const seen = await access(env, conversation, caller.actor, meta.sha256)
  if (!seen.ok) return failure({ status: 403, code: "auth.forbidden", message: seen.message })
  if (!seen.open) return failure({ status: 409, code: "archived", message: "this conversation takes no new messages" })
  // Dedupe only for a hash this caller can already see here: never an answer about other conversations or hidden history.
  if (seen.record) return success({ state: "exists", attachment: { hash: seen.record.hash, mime_type: seen.record.mime_type, byte_count: seen.record.byte_count } })
  const quota = await quotaOf(env, caller.user).takeAttachmentQuota(caller.user, `${conversation}:${meta.sha256}`, meta.byte_count)
  if (!quota.ok) return failure({ status: 429, code: "attachment.quota", message: `attachment ${quota.window} quota reached`, extra: { retry_after_ms: quota.retry_after_ms } })
  const expires = Date.now() + L.uploadTtlMs
  const slot: UploadSlot = { c: conversation, h: meta.sha256, n: meta.byte_count, m: meta.mime_type, f: meta.name, a: caller.actor, i: crypto.randomUUID().replace(/-/g, ""), e: expires }
  return success({
    state: "upload",
    upload_url: `${new URL(request.url).origin}/v1/home/attachments/upload/${signSlot(env, slot)}`,
    method: "PUT",
    headers: { "content-type": meta.mime_type, "content-length": String(meta.byte_count) },
    expires_at: expires
  })
}

/** PUT /v1/home/attachments/upload/<slot>: the slot is the credential; the bytes must hash to its sha256. */
export const handleAttachmentUpload = async (request: Request, env: Env, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const slot = openSlot(env, token)
  if (!slot) return failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid or expired; ask for a new one" })
  const declared = request.headers.get("content-length")
  if (!request.body || (declared !== null && Number(declared) !== slot.n)) return failure({ status: 400, code: "attachment.size_mismatch", message: `expected exactly ${slot.n} bytes` })
  const bucket = env.HOME_ATTACHMENTS!
  // A fresh key per attempt: a replayed slot with other bytes can never overwrite (then delete) a recorded object.
  const key = homeConversation.attachmentObjectKey(slot.c, slot.h, crypto.randomUUID().replace(/-/g, ""))
  const hasher = createHash("sha256")
  let count = 0
  const meter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, ctl) {
      count += chunk.byteLength
      if (count > slot.n) return ctl.error(new Error("body longer than declared"))
      hasher.update(chunk)
      ctl.enqueue(chunk)
    }
  })
  // FixedLengthStream gives R2 the length up front and fails a body of any other length.
  const fixed = new FixedLengthStream(slot.n)
  const piped = request.body.pipeThrough(meter).pipeTo(fixed.writable).catch(() => undefined)
  try {
    await bucket.put(key, fixed.readable, { httpMetadata: { contentType: slot.m }, customMetadata: { conversation: slot.c, sha256: slot.h, uploader: slot.a } })
    await piped
  } catch {
    await bucket.delete(key)
    return failure({ status: 400, code: "attachment.size_mismatch", message: `expected exactly ${slot.n} bytes` })
  }
  if (count !== slot.n || hasher.digest("hex") !== slot.h) {
    await bucket.delete(key)
    return failure({ status: 400, code: "attachment.hash_mismatch", message: "the bytes do not match the declared sha256" })
  }
  const committed = await conversationOf(env, slot.c).commitAttachment(slot.c, slot.a, { hash: slot.h, object_key: key, mime_type: slot.m, byte_count: slot.n, name: slot.f })
  if (!committed.ok) {
    await bucket.delete(key)
    return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  }
  // Same bytes uploaded earlier here: keep the first object.
  if (committed.object_key !== key) await bucket.delete(key)
  return success({ state: committed.state, attachment: { hash: slot.h, mime_type: slot.m, byte_count: slot.n } })
}

/** POST /v1/home/attachments/url {conversation, hash}: a signed GET URL for a participant who may see the hash. */
export const handleAttachmentUrl = async (request: Request, env: Env): Promise<Response> => {
  const caller = await callerOf(request, env, "read")
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = (await request.json().catch(() => null)) as { conversation?: unknown; hash?: unknown } | null
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || !homeConversation.isSha256(body.hash)) return failure({ status: 400, code: "validation.invalid", message: "conversation and hash required" })
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  const seen = await access(env, body.conversation, caller.actor, body.hash)
  if (!seen.ok) return failure({ status: 403, code: "auth.forbidden", message: seen.message })
  if (!seen.record) return failure({ status: 404, code: "attachment.not_found", message: "no such attachment in this conversation" })
  const expires = Date.now() + L.downloadTtlMs
  return success({ url: `${new URL(request.url).origin}${downloadPath(env, body.conversation, body.hash, caller.actor, expires)}`, expires_at: expires })
}

/** GET|HEAD /v1/home/attachments/<conversation>/<sha256>: signature, expiry, then the owner's live participant check. */
export const handleAttachmentDownload = async (request: Request, env: Env, conversation: string, hash: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const q = new URL(request.url).searchParams
  const actor = q.get("a") ?? ""
  const expires = Number(q.get("e"))
  const sig = q.get("s") ?? ""
  const denied = failure({ status: 403, code: "auth.forbidden", message: "the link is invalid or expired" })
  if (!actor || !Number.isSafeInteger(expires) || expires <= Date.now() || !sameMac(downloadMac(env, conversation, hash, actor, expires), sig)) return denied
  const seen = await access(env, conversation, actor, hash)
  if (!seen.ok || !seen.record) return denied
  const rec = seen.record
  const headers = new Headers({
    "content-type": rec.mime_type,
    "content-disposition": homeConversation.contentDisposition(rec.mime_type, rec.name),
    "x-content-type-options": "nosniff",
    "content-security-policy": "default-src 'none'; sandbox",
    "referrer-policy": "no-referrer",
    "accept-ranges": "bytes",
    "cache-control": `private, max-age=${Math.max(0, Math.floor((expires - Date.now()) / 1000))}`
  })
  if (request.method === "HEAD") {
    headers.set("content-length", String(rec.byte_count))
    return new Response(null, { headers })
  }
  const wantsRange = request.headers.has("range")
  const obj = await env.HOME_ATTACHMENTS!.get(rec.object_key, wantsRange ? { range: request.headers } : {})
  if (!obj) return failure({ status: 404, code: "attachment.not_found", message: "the object is gone" })
  const r = obj.range as { offset?: number; length?: number; suffix?: number } | undefined
  if (wantsRange && r) {
    const offset = r.suffix !== undefined ? obj.size - r.suffix : (r.offset ?? 0)
    const length = r.suffix !== undefined ? r.suffix : (r.length ?? obj.size - offset)
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`)
    headers.set("content-length", String(length))
    return new Response(obj.body, { status: 206, headers })
  }
  headers.set("content-length", String(obj.size))
  return new Response(obj.body, { headers })
}
