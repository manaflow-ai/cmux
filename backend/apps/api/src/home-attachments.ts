import { createHmac, timingSafeEqual } from "node:crypto"
import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { authenticate, withGrantClasses } from "./auth.ts"
import type { AttachmentAccess, DownloadAccess } from "./conversation-do.ts"
import type { Env } from "./env.ts"
import { posterReady, randomId, slotKeys, type UploadSlot } from "./home-attachment-store.ts"
import { streamInto } from "./home-attachment-stream.ts"
import { ssoGate } from "./policy-gate.ts"
import { presignUrl, type Presigner } from "./r2-presign.ts"

/**
 * Home attachment routes (home-messaging.md section 10.1):
 *
 * - POST /v1/home/attachments/intent {conversation, sha256, byte_count, mime_type, name, width?, height?, duration_ms?, poster?}
 *   A current participant only; allow list, 100 MB cap, per-user quota. Answers
 *   {state: "exists"} for a hash this caller can already use here, otherwise a single-use slot:
 *   up to 32 MB {mode: "stream", upload_url} (PUT through the Worker, which hashes the bytes);
 *   above {mode: "presigned", upload_url, headers, slot} (PUT straight to the private bucket,
 *   then POST /v1/home/attachments/commit {conversation, slot}). The presigned PUT signs
 *   `if-none-match: *`, so the URL cannot overwrite an object that is already there.
 *   A video may declare `poster {sha256, byte_count, mime_type: image/jpeg|image/webp}` (2 MB):
 *   the answer adds `poster_upload` (PUT through the Worker, once, before the video commits);
 *   the poster is stored at `<object key>.poster` under the same slot and recorded on the video's record.
 * - POST /v1/home/attachments/url {conversation, hash, message_id?, part_index?, variant?}: a
 *   10-minute signed GET URL; the file name comes from that message part. `variant: "poster"`
 *   signs the poster recorded with a video (`attachment.no_poster` when there is none).
 * - GET|HEAD /v1/home/attachments/<conversation>/<object id>?m&p&variant&a&e&k&s: signature (key
 *   id, method, conversation, object, part, variant, actor, expiry), then the owner's live
 *   participant and history-floor check on every request.
 *
 * No URL carries user content: slot and object ids are random, names and hashes stay server-side.
 */
const CONVERSATION_ID = /^conv_(dm_)?[0-9A-HJKMNP-TV-Z]{26}$/
const KEY_ID = /^[A-Za-z0-9_-]{1,16}$/
const MESSAGE_ID = /^msg_[A-Za-z0-9]{1,40}$/
const L = homeConversation.ATTACHMENT_LIMITS
const NO_STORE = { "cache-control": "private, no-store" }
const EXTENSIONS: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf",
  "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "application/json": "json", "application/zip": "zip",
  "video/mp4": "mp4", "video/quicktime": "mov", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/aac": "aac", "audio/wav": "wav"
}

type Fail = { readonly status: number; readonly code: string; readonly message: string; readonly extra?: Record<string, unknown> }
const failure = (f: Fail, headers: Record<string, string> = {}) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: { ...NO_STORE, ...headers } })
const success = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const isFail = (v: unknown): v is Fail => typeof v === "object" && v !== null && "status" in v && "code" in v

type Poster = homeConversation.AttachmentPoster
interface ConversationAttachments {
  attachmentAccess(entity: string, actor: string, hash: string): Promise<AttachmentAccess>
  createUploadSlot(entity: string, actor: string, quotaUser: string, meta: { hash: string; byte_count: number; mime_type: string; poster?: Poster }, mode: UploadSlot["mode"], id: string): Promise<UploadSlot | null>
  uploadSlot(entity: string, id: string, mode: UploadSlot["mode"], consume: boolean, actor?: string): Promise<UploadSlot | null>
  posterSlot(entity: string, id: string): Promise<UploadSlot | null>
  settlePoster(entity: string, id: string, etag: string | null): Promise<void>
  settleSlot(entity: string, id: string): Promise<void>
  commitAttachment(entity: string, slotId: string, etag?: string): Promise<{ ok: true; state: "stored" | "exists"; object_key: string; poster?: Poster } | { ok: false; code: "auth.forbidden" | "archived" | "slot_gone" }>
  downloadAccess(entity: string, actor: string, by: { hash: string } | { object_id: string }, at?: { message_id: string; part_index: number }): Promise<DownloadAccess | "forbidden">
}
interface UserAttachments {
  takeAttachmentQuota(e: string, key: string, bytes: number): Promise<{ ok: true } | { ok: false; code: string; window: string; retry_after_ms: number }>
  recordAttachmentStorage(e: string, key: string, bytes: number): Promise<void>
  refundAttachmentQuota(e: string, key: string): Promise<void>
}
const conversationOf = (env: Env, id: string) => env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)) as unknown as ConversationAttachments
const userOf = (env: Env, user: string) => env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as UserAttachments

const configured = (env: Env): Fail | null =>
  env.HOME_ATTACHMENTS && env.HOME_ATTACHMENT_KEY && env.HOME_ATTACHMENT_KEY.length >= 32 ? null : { status: 503, code: "home.not_configured", message: "attachments are not configured on this deployment" }

// --- Signing: HMAC-SHA256 over (purpose, key id, fields); current key signs, current or previous verifies ---

const currentKid = (env: Env) => env.HOME_ATTACHMENT_KEY_ID ?? "1"
const keyFor = (env: Env, kid: string): string | null => {
  if (!KEY_ID.test(kid)) return null
  if (kid === currentKid(env)) return env.HOME_ATTACHMENT_KEY ?? null
  if (env.HOME_ATTACHMENT_KEY_PREVIOUS && env.HOME_ATTACHMENT_KEY_PREVIOUS_ID === kid && env.HOME_ATTACHMENT_KEY_PREVIOUS.length >= 32) return env.HOME_ATTACHMENT_KEY_PREVIOUS
  return null
}
const mac = (key: string, purpose: string, kid: string, fields: ReadonlyArray<string>) => createHmac("sha256", key).update([purpose, kid, ...fields].join("\u0000")).digest()
/** Constant-time: a wrong length compares against the expected MAC too, then fails. */
const verify = (env: Env, kid: string, purpose: string, fields: ReadonlyArray<string>, given: string): boolean => {
  const key = keyFor(env, kid) ?? env.HOME_ATTACHMENT_KEY ?? ""
  const expected = mac(key, purpose, kid, fields)
  let sig = Buffer.from(given, "base64url")
  const sameLength = sig.length === expected.length
  if (!sameLength) sig = Buffer.alloc(expected.length)
  return timingSafeEqual(sig, expected) && sameLength && keyFor(env, kid) !== null
}

const UPLOAD = "home-attachment-upload"
const POSTER_UPLOAD = "home-attachment-poster-upload"
const DOWNLOAD = "home-attachment-download"
/** The only `variant` of a download: a video's poster image. */
export const POSTER = "poster"

const uploadToken = (env: Env, conversation: string, slot: string, purpose = UPLOAD) => {
  const kid = currentKid(env)
  return `${slot}.${kid}.${Buffer.from(mac(env.HOME_ATTACHMENT_KEY!, purpose, kid, [conversation, slot])).toString("base64url")}`
}

export interface DownloadArgs {
  readonly conversation: string
  readonly objectId: string
  readonly actor: string
  readonly expires: number
  readonly message?: string
  readonly part?: number
  readonly variant?: typeof POSTER
  /** Tests and rotation drills only; the Worker always signs with the current key and GET. */
  readonly kid?: string
  readonly method?: string
}
const downloadFields = (a: DownloadArgs) => [a.method ?? "GET", a.conversation, a.objectId, a.message ?? "", a.part === undefined ? "" : String(a.part), a.variant ?? "", a.actor, String(a.expires)]

/** Path and query of a signed download. */
export const downloadPath = (env: Env, a: DownloadArgs): string => {
  const kid = a.kid ?? currentKid(env)
  const key = keyFor(env, kid) ?? env.HOME_ATTACHMENT_KEY!
  const q = new URLSearchParams({ ...(a.message ? { m: a.message, p: String(a.part ?? 0) } : {}), ...(a.variant ? { variant: a.variant } : {}), a: a.actor, e: String(a.expires), k: kid, s: Buffer.from(mac(key, DOWNLOAD, kid, downloadFields(a))).toString("base64url") })
  return `/v1/home/attachments/${a.conversation}/${a.objectId}?${q}`
}

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

const s3Config = (env: Env) =>
  env.HOME_ATTACHMENTS_S3_ENDPOINT && env.HOME_ATTACHMENTS_S3_BUCKET && env.HOME_ATTACHMENTS_S3_ACCESS_KEY_ID && env.HOME_ATTACHMENTS_S3_SECRET_ACCESS_KEY
    ? { endpoint: env.HOME_ATTACHMENTS_S3_ENDPOINT.replace(/\/$/, ""), bucket: env.HOME_ATTACHMENTS_S3_BUCKET, accessKeyId: env.HOME_ATTACHMENTS_S3_ACCESS_KEY_ID, secretAccessKey: env.HOME_ATTACHMENTS_S3_SECRET_ACCESS_KEY }
    : null

const readJson = async <T>(request: Request): Promise<T | null> => (await request.json().catch(() => null)) as T | null

/**
 * After a verified upload: the owner records the object (first upload wins) and settles the slot.
 * `stored` counts toward the uploader's stored bytes; `exists` deletes this slot's object now and
 * refunds its bytes; a refusal deletes the object too.
 */
const finish = async (env: Env, conversation: string, slot: UploadSlot, etag: string | undefined): Promise<Response> => {
  const bucket = env.HOME_ATTACHMENTS!
  const committed = await conversationOf(env, conversation).commitAttachment(conversation, slot.id, etag)
  if (!committed.ok) {
    await bucket.delete(slotKeys(slot))
    if (committed.code === "archived") return failure({ status: 409, code: "archived", message: "this conversation takes no new messages" })
    if (committed.code === "slot_gone") return failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
    return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  }
  if (committed.object_key !== slot.object_key) {
    await bucket.delete(slotKeys(slot))
    await userOf(env, slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
  } else await userOf(env, slot.quota_user).recordAttachmentStorage(slot.quota_user, slot.object_key, slot.byte_count + (committed.poster?.byte_count ?? 0))
  // The record's poster (first upload wins): the one a message part may claim.
  return success({ state: committed.state, attachment: { hash: slot.hash, mime_type: slot.mime_type, byte_count: slot.byte_count, ...(committed.poster ? { poster: committed.poster } : {}) } })
}

const posterMissing = () => failure({ status: 409, code: "attachment.poster_missing", message: "PUT the declared poster to poster_upload before the video" })

// --- Routes ---

/** POST /v1/home/attachments/intent */
export const handleAttachmentIntent = async (request: Request, env: Env, presign: Presigner = presignUrl): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared")
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation)) return failure({ status: 400, code: "validation.invalid", message: "conversation id required" })
  const conversation = body.conversation
  const checked = homeConversation.validateAttachmentMeta(body)
  if (!checked.ok) return failure({ status: checked.code === "attachment.too_large" ? 413 : checked.code === "attachment.type_refused" ? 415 : 400, code: checked.code, message: checked.message })
  const meta = checked.meta
  const posterCheck = homeConversation.validatePosterMeta((body as { poster?: unknown }).poster, checked.class)
  if (!posterCheck.ok) return failure({ status: posterCheck.code === "attachment.too_large" ? 413 : posterCheck.code === "attachment.type_refused" ? 415 : 400, code: posterCheck.code, message: posterCheck.message })
  const poster = posterCheck.poster
  const mode: UploadSlot["mode"] = meta.byte_count > L.streamMaxBytes ? "presigned" : "stream"
  const s3 = s3Config(env)
  if (mode === "presigned" && !s3) return failure({ status: 503, code: "attachment.large_unavailable", message: `files over ${L.streamMaxBytes} bytes are not enabled on this deployment` })
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  // Participant check before any quota, slot or storage.
  const seen = await conversationOf(env, conversation).attachmentAccess(conversation, caller.actor, meta.sha256)
  if (!seen.ok) return failure({ status: 403, code: "auth.forbidden", message: seen.message })
  if (!seen.open) return failure({ status: 409, code: "archived", message: "this conversation takes no new messages" })
  // Dedupe only for a hash this caller can already use here: never an answer about other conversations, members or hidden history.
  if (seen.record) {
    const p = seen.record.poster
    return success({ state: "exists", attachment: { hash: seen.record.hash, mime_type: seen.record.mime_type, byte_count: seen.record.byte_count, ...(p ? { poster: { hash: p.hash, mime_type: p.mime_type, byte_count: p.byte_count } } : {}) } })
  }
  // Every slot is charged its declared bytes, poster included (refunded on an "exists" commit or an unused expiry).
  const slotId = randomId()
  const users = userOf(env, caller.user)
  const quota = await users.takeAttachmentQuota(caller.user, slotId, meta.byte_count + (poster?.byte_count ?? 0))
  if (!quota.ok) return failure({ status: 429, code: quota.code, message: `attachment quota reached (${quota.window})`, extra: { retry_after_ms: quota.retry_after_ms } })
  const slot = await conversationOf(env, conversation).createUploadSlot(conversation, caller.actor, caller.user, { hash: meta.sha256, byte_count: meta.byte_count, mime_type: meta.mime_type, ...(poster ? { poster } : {}) }, mode, slotId)
  if (!slot) {
    await users.refundAttachmentQuota(caller.user, slotId)
    return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  }
  const origin = new URL(request.url).origin
  // Always through the Worker (small), whatever the video's mode.
  const posterUpload = poster
    ? { poster_upload: { method: "PUT", upload_url: `${origin}/v1/home/attachments/poster/${conversation}/${uploadToken(env, conversation, slot.id, POSTER_UPLOAD)}`, headers: { "content-length": String(poster.byte_count) }, expires_at: slot.expires_at } }
    : {}
  if (mode === "stream") {
    return success({
      state: "upload",
      mode,
      method: "PUT",
      upload_url: `${origin}/v1/home/attachments/upload/${conversation}/${uploadToken(env, conversation, slot.id)}`,
      headers: { "content-length": String(meta.byte_count) },
      expires_at: slot.expires_at,
      ...posterUpload
    })
  }
  // Signed headers the client must send as given: the length, the checksum (R2 rejects other bytes) and
  // `if-none-match: *` (R2 rejects a PUT to a key that already holds an object, so the URL cannot overwrite after commit).
  const headers = { "content-length": String(meta.byte_count), "if-none-match": "*", "x-amz-checksum-sha256": Buffer.from(meta.sha256, "hex").toString("base64") }
  const url = presign({
    method: "PUT",
    url: `${s3!.endpoint}/${s3!.bucket}/${slot.object_key.split("/").map(encodeURIComponent).join("/")}`,
    region: "auto",
    accessKeyId: s3!.accessKeyId,
    secretAccessKey: s3!.secretAccessKey,
    headers,
    expiresSec: L.uploadTtlMs / 1000,
    // The URL ends exactly at the slot's stored expiry (the grace is counted from it).
    now: slot.expires_at - L.uploadTtlMs
  })
  return success({ state: "upload", mode, method: "PUT", upload_url: url, headers, slot: slot.id, expires_at: slot.expires_at, ...posterUpload })
}

/** PUT /v1/home/attachments/upload/<conversation>/<slot>.<kid>.<mac>: single use; the bytes must hash to the slot's sha256. */
export const handleAttachmentUpload = async (request: Request, env: Env, conversation: string, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const [id, kid, sig, extra] = token.split(".")
  if (!id || !kid || !sig || extra !== undefined || !verify(env, kid, UPLOAD, [conversation, id], sig)) return invalid
  const conv = conversationOf(env, conversation)
  // A video whose declared poster is not stored yet: refused before the slot is used, so the client PUTs the poster and retries.
  const peek = await conv.uploadSlot(conversation, id, "stream", false)
  if (!peek) return invalid
  if (!posterReady(peek)) return posterMissing()
  // Consumed before any byte is read: a second PUT with this slot is refused whatever happens next.
  const slot = await conv.uploadSlot(conversation, id, "stream", true)
  if (!slot) return invalid
  const bucket = env.HOME_ATTACHMENTS!
  const put = await streamInto(bucket, slot.object_key, request, slot.byte_count, slot.hash, slot.mime_type)
  if (!put.ok) {
    await bucket.delete(slotKeys(slot))
    await conv.settleSlot(conversation, slot.id)
    return failure({ status: 400, code: put.code, message: put.code === "attachment.hash_mismatch" ? "the bytes do not match the declared sha256" : `expected exactly ${slot.byte_count} bytes` })
  }
  return finish(env, conversation, slot, put.etag)
}

/** PUT /v1/home/attachments/poster/<conversation>/<slot>.<kid>.<mac>: the declared poster of an open video slot, once; the bytes must hash to its sha256. */
export const handleAttachmentPoster = async (request: Request, env: Env, conversation: string, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the poster slot is invalid, used or expired; ask for a new one" })
  const [id, kid, sig, extra] = token.split(".")
  if (!id || !kid || !sig || extra !== undefined || !verify(env, kid, POSTER_UPLOAD, [conversation, id], sig)) return invalid
  const conv = conversationOf(env, conversation)
  const slot = await conv.posterSlot(conversation, id)
  if (!slot?.poster) return invalid
  const key = homeConversation.attachmentPosterKey(slot.object_key)
  const put = await streamInto(env.HOME_ATTACHMENTS!, key, request, slot.poster.byte_count, slot.poster.hash, slot.poster.mime_type)
  await conv.settlePoster(conversation, slot.id, put.ok ? (put.etag ?? "") : null)
  if (!put.ok) return failure({ status: 400, code: put.code, message: "the poster bytes do not match the declared size and sha256" })
  return success({ state: "poster_stored" })
}

/** POST /v1/home/attachments/commit {conversation, slot}: after a presigned PUT; HEADs size and SHA-256 before the object is usable. */
export const handleAttachmentCommit = async (request: Request, env: Env): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared")
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; slot?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || typeof body.slot !== "string" || !/^[0-9a-f]{32}$/.test(body.slot)) return failure({ status: 400, code: "validation.invalid", message: "conversation and slot required" })
  const conv = conversationOf(env, body.conversation)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const peek = await conv.uploadSlot(body.conversation, body.slot, "presigned", false, caller.actor)
  if (!peek) return invalid
  if (!posterReady(peek)) return posterMissing()
  const bucket = env.HOME_ATTACHMENTS!
  const head = await bucket.head(peek.object_key)
  // Not there yet: the slot stays, so the client may commit again after its PUT finishes.
  if (!head) return failure({ status: 409, code: "attachment.not_uploaded", message: "no bytes were uploaded for this slot yet" })
  const slot = await conv.uploadSlot(body.conversation, body.slot, "presigned", true, caller.actor)
  if (!slot) return invalid
  const sum = head.checksums.sha256
  if (head.size !== slot.byte_count || !sum || Buffer.from(sum).toString("hex") !== slot.hash) {
    await bucket.delete(slotKeys(slot))
    // A tombstone until the URL expires: a later PUT to this key is deleted by the alarm.
    await conv.settleSlot(body.conversation, slot.id)
    return failure({ status: 400, code: head.size !== slot.byte_count ? "attachment.size_mismatch" : "attachment.hash_mismatch", message: "the uploaded object does not match the declared size and sha256" })
  }
  return finish(env, body.conversation, slot, head.etag)
}

/** POST /v1/home/attachments/url {conversation, hash, message_id?, part_index?, variant?} */
export const handleAttachmentUrl = async (request: Request, env: Env): Promise<Response> => {
  const caller = await callerOf(request, env, "read")
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; hash?: unknown; message_id?: unknown; part_index?: unknown; variant?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || !homeConversation.isSha256(body.hash)) return failure({ status: 400, code: "validation.invalid", message: "conversation and hash required" })
  const at = body.message_id === undefined ? undefined : typeof body.message_id === "string" && MESSAGE_ID.test(body.message_id) && Number.isInteger(body.part_index) && (body.part_index as number) >= 0 && (body.part_index as number) < 16 ? { message_id: body.message_id, part_index: body.part_index as number } : null
  if (at === null) return failure({ status: 400, code: "validation.invalid", message: "message_id needs a part_index" })
  if (body.variant !== undefined && body.variant !== POSTER) return failure({ status: 400, code: "validation.invalid", message: `variant must be "${POSTER}"` })
  const variant = body.variant === POSTER ? POSTER : undefined
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  const access = await conversationOf(env, body.conversation).downloadAccess(body.conversation, caller.actor, { hash: body.hash }, at)
  if (access === "forbidden") return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  if (!access) return failure({ status: 404, code: "attachment.not_found", message: "no such attachment in this conversation" })
  // Never a fallback to the video: a poster URL exists only for a video (part) whose record holds a poster.
  if (variant && !posterServed(access)) return failure({ status: 404, code: "attachment.no_poster", message: "this attachment has no poster" })
  const expires = Date.now() + L.downloadTtlMs
  const path = downloadPath(env, { conversation: body.conversation, objectId: access.record.object_id, actor: caller.actor, expires, ...(at ? { message: at.message_id, part: at.part_index } : {}), ...(variant ? { variant } : {}) })
  return success({ url: `${new URL(request.url).origin}${path}`, expires_at: expires })
}

/** The poster a download may serve: the record's (server-chosen key), for a video record and, when asked by part, a video part. */
const posterServed = (access: NonNullable<DownloadAccess>) =>
  homeConversation.ATTACHMENT_TYPES[access.record.mime_type] === "video" && (!access.part || homeConversation.ATTACHMENT_TYPES[access.part.mime_type] === "video") ? access.record.poster : undefined

/** `bytes=a-b`, `bytes=a-`, `bytes=-n` against `size`: the clamped range, "unsatisfiable", or null to serve everything. */
export const parseRange = (header: string | null, size: number): { offset: number; length: number } | "unsatisfiable" | null => {
  const m = header ? /^bytes=(\d*)-(\d*)$/.exec(header.trim()) : null
  if (!m || (m[1] === "" && m[2] === "")) return null
  if (m[1] === "") {
    const suffix = Number(m[2])
    if (suffix === 0) return "unsatisfiable"
    const length = Math.min(suffix, size)
    return { offset: size - length, length }
  }
  const start = Number(m[1])
  const end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1)
  if (start >= size || end < start) return "unsatisfiable"
  return { offset: start, length: end - start + 1 }
}

/** GET|HEAD /v1/home/attachments/<conversation>/<object id>: signature, expiry, then the owner's live check. */
export const handleAttachmentDownload = async (request: Request, env: Env, conversation: string, objectId: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const q = new URL(request.url).searchParams
  const message = q.get("m") ?? undefined
  const part = message === undefined ? undefined : Number(q.get("p"))
  const variant = q.get("variant") ?? undefined
  if (variant !== undefined && variant !== POSTER) return failure({ status: 403, code: "auth.forbidden", message: "the link is invalid or expired" })
  const args: DownloadArgs = { conversation, objectId, actor: q.get("a") ?? "", expires: Number(q.get("e")), ...(message ? { message, part: part! } : {}), ...(variant ? { variant } : {}) }
  const kid = q.get("k") ?? ""
  const denied = failure({ status: 403, code: "auth.forbidden", message: "the link is invalid or expired" })
  // HEAD is a GET without a body: both verify against the GET signature.
  const signed = verify(env, kid, DOWNLOAD, downloadFields(args), q.get("s") ?? "")
  if (!signed || !args.actor || !Number.isSafeInteger(args.expires) || args.expires <= Date.now() || (message !== undefined && (!MESSAGE_ID.test(message) || !Number.isInteger(part)))) return denied
  const access = await conversationOf(env, conversation).downloadAccess(conversation, args.actor, { object_id: objectId }, message ? { message_id: message, part_index: part! } : undefined)
  if (!access || access === "forbidden") return denied
  const poster = variant ? posterServed(access) : undefined
  if (variant && !poster) return failure({ status: 404, code: "attachment.no_poster", message: "this attachment has no poster" })
  // What is served: the recorded object, or the poster recorded with it (key, type, size and etag from the record, never from the request).
  const rec = poster
    ? { object_key: homeConversation.attachmentPosterKey(access.record.object_key), mime_type: poster.mime_type, byte_count: poster.byte_count, etag: poster.etag }
    : access.record
  const name = poster ? `poster.${EXTENSIONS[poster.mime_type] ?? "jpg"}` : (access.name ?? `attachment.${EXTENSIONS[rec.mime_type] ?? "bin"}`)
  const headers = new Headers({
    "content-type": homeConversation.servedContentType(rec.mime_type),
    "content-disposition": homeConversation.contentDisposition(rec.mime_type, name),
    "x-content-type-options": "nosniff",
    "content-security-policy": "default-src 'none'; sandbox",
    "referrer-policy": "no-referrer",
    "accept-ranges": "bytes",
    "cache-control": `private, max-age=${Math.max(0, Math.floor((args.expires - Date.now()) / 1000))}`
  })
  const range = parseRange(request.headers.get("range"), rec.byte_count)
  if (range === "unsatisfiable") return failure({ status: 416, code: "attachment.range", message: "range not satisfiable" }, { "content-range": `bytes */${rec.byte_count}` })
  if (request.method === "HEAD") {
    headers.set("content-length", String(rec.byte_count))
    return new Response(null, { headers })
  }
  // Only the version recorded at commit is served (a later overwrite of the key is never read).
  const obj = await env.HOME_ATTACHMENTS!.get(rec.object_key, { ...(range ? { range } : {}), ...(rec.etag ? { onlyIf: { etagMatches: rec.etag } } : {}) })
  if (!obj || !("body" in obj)) return failure({ status: 404, code: "attachment.not_found", message: "the object is gone" })
  if (range) {
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${rec.byte_count}`)
    headers.set("content-length", String(range.length))
    return new Response(obj.body, { status: 206, headers })
  }
  headers.set("content-length", String(obj.size))
  return new Response(obj.body, { headers })
}
