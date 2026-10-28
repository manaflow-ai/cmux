import { isMachineInstallKind } from "./machine-installs.ts"
import { createHmac, timingSafeEqual } from "node:crypto"
import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { authenticate } from "./auth.ts"
import { principalForOwner } from "./team-select.ts"
import type { AttachmentAccess, DownloadAccess } from "./conversation-do.ts"
import type { Env } from "./env.ts"
import { derivedReady, randomId, slotKeys, type UploadSlot } from "./home-attachment-store.ts"
import { completionFailure, ResumableSha256, streamInto, streamPartInto } from "./home-attachment-stream.ts"
import { ssoGate } from "./policy-gate.ts"
import { presignUrl, type Presigner } from "./r2-presign.ts"

/**
 * Home attachment routes (home-messaging.md section 10.1):
 *
 * - POST /v1/home/attachments/intent {conversation, sha256, byte_count, mime_type, name, width?, height?, duration_ms?, poster?, preview?}
 *   A current participant only; allow list, 100 MB cap, per-user quota. Answers
 *   {state: "exists"} for a hash this caller can already use here, otherwise a single-use slot:
 *   up to 32 MB {mode: "stream", upload_url} (PUT through the Worker, which hashes the bytes);
 *   larger files, when the intent says `multipart: true` (at every size), {mode: "multipart", upload_url,
 *   part_size, part_count, slot}: each part in order is one PUT through the Worker (header
 *   `x-cmux-part-number`) into one R2 part, its bytes hashed onto the SHA-256 the owner keeps;
 *   then POST /v1/home/attachments/multipart/complete {conversation, slot}. Every request does
 *   the same bounded work whatever the file's size (home-core `multipartPlan`). An intent without
 *   `multipart` (older clients) gets one request: {mode: "presigned"} with the S3 settings, else
 *   the Worker stream up to the zone's body limit (`uploadModeFor`).
 *   A video may declare `poster {sha256, byte_count, mime_type: image/jpeg|image/webp}` (2 MB):
 *   the answer adds `poster_upload` (PUT through the Worker, once, before the video commits);
 *   the poster is stored at `<object key>.poster` under the same slot and recorded on the video's record.
 *   An image may declare `preview` the same way (512 KB): `preview_upload`, `<object key>.preview`.
 * - POST /v1/home/attachments/url {conversation, hash, message_id?, part_index?, variant?}: a
 *   10-minute signed GET URL; the file name comes from that message part. `variant: "poster"|"preview"`
 *   signs the derived image recorded with a video or an image (`attachment.no_<variant>` when there is none).
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
  "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "application/json": "json", "application/zip": "zip", "application/octet-stream": "bin",
  "video/mp4": "mp4", "video/quicktime": "mov", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/aac": "aac", "audio/wav": "wav"
}

export type Fail = { readonly status: number; readonly code: string; readonly message: string; readonly extra?: Record<string, unknown> }
const failure = (f: Fail, headers: Record<string, string> = {}) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: { ...NO_STORE, ...headers } })
const success = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const isFail = (v: unknown): v is Fail => typeof v === "object" && v !== null && "status" in v && "code" in v

type Image = homeConversation.DerivedImage
type Variant = homeConversation.DerivedVariant
interface ConversationAttachments {
  attachmentAccess(entity: string, actor: string, hash: string): Promise<AttachmentAccess>
  createUploadSlot(entity: string, actor: string, quotaUser: string, meta: { hash: string; byte_count: number; mime_type: string; derived?: Image }, mode: UploadSlot["mode"], id: string): Promise<UploadSlot | null>
  uploadSlot(entity: string, id: string, mode: UploadSlot["mode"], consume: boolean, actor?: string): Promise<UploadSlot | null>
  derivedSlot(entity: string, id: string): Promise<UploadSlot | null>
  settleDerived(entity: string, id: string, etag: string | null): Promise<void>
  settleSlot(entity: string, id: string): Promise<void>
  setMultipartUpload(entity: string, id: string, uploadId: string): Promise<boolean>
  claimMultipartPart(entity: string, id: string, part: number, before: string | null): Promise<{ ok: true; claim: string } | { ok: false; busy: boolean }>
  releaseMultipartPart(entity: string, id: string, claim: string): Promise<void>
  recordMultipartPart(entity: string, id: string, part: number, etag: string, before: string | null, after: string, claim: string): Promise<boolean>
  multipartEtags(entity: string, id: string): Promise<Array<string>>
  reopenMultipart(entity: string, id: string): Promise<boolean>
  commitAttachment(entity: string, slotId: string, etag?: string): Promise<{ ok: true; state: "stored" | "exists"; object_key: string; derived?: Image } | { ok: false; code: "auth.forbidden" | "archived" | "slot_gone" }>
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
/** Each derived image is its own token purpose: an image token is never a poster or preview token, nor the other way. */
const derivedPurpose = (variant: Variant) => `home-attachment-${variant}-upload`
const DOWNLOAD = "home-attachment-download"
/** A part number names one of the slot's planned parts: an integer from 1 to its part count (R2: at most 10,000). */
const partNumberIn = (value: unknown, parts: number): value is number => Number.isInteger(value) && (value as number) >= 1 && (value as number) <= Math.min(parts, homeConversation.MULTIPART_PART_COUNT)
const partInvalid = (parts: number) => failure({ status: 400, code: "attachment.part_invalid", message: `part number must be an integer from 1 to ${parts}` })

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
  readonly variant?: Variant
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
export const callerOf = async (request: Request, env: Env, risk: "read" | "mutate-shared", admitted?: Principal): Promise<Caller | Fail> => {
  // A self-hosted server (backend/apps/home-server) passes the principal its Tailscale admission built; the Worker never does.
  if (admitted) {
    const actor = homeConversation.actorOf(admitted)
    return actor && admitted.user ? { principal: admitted, actor, user: admitted.user } : { status: 403, code: "auth.forbidden", message: "no user" }
  }
  const auth = request.headers.get("authorization") ?? ""
  const authenticated = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!authenticated?.user) return { status: 401, code: "auth.unauthenticated", message: "sign in first" }
  if (isMachineInstallKind(authenticated.install_kind)) return { status: 403, code: "auth.forbidden", message: "a VM install has no Home access" }
  const gate = await ssoGate(env, authenticated).catch((e: unknown) => (console.error(JSON.stringify({ msg: "sso gate unreachable", error: String(e) })), null))
  // A TeamDO or UserDO the gate asks was unreachable: retryable, never a 500 (cx-44j.51).
  if (!gate) return { status: 503, code: "owner.unreachable", message: "the sign-in policy could not be checked; retry", extra: { retryable: true } }
  if (gate.refusal) return { status: 403, code: "auth.forbidden", message: gate.refusal.message }
  const { stack_session: _s, email_domain: _d, ...stripped } = gate.principal
  // Review P2-2: in a shared team, guests and billing reach no Home owner (principalForOwner).
  const granted = await principalForOwner(env, "cloud:ConversationDO", stripped)
  const principal = granted && !("refused" in granted) ? granted : undefined
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

/** The zone's request body limit (HOME_ATTACHMENT_WORKER_BODY_BYTES; 100 MB on Free and Pro, the default). */
const workerBodyBytes = (env: Env): number => {
  const set = Number(env.HOME_ATTACHMENT_WORKER_BODY_BYTES)
  return Number.isSafeInteger(set) && set > 0 ? set : 100_000_000
}
/** What one presigned S3 PutObject may carry (R2: 5 GiB less 5 MiB; decimal 5 GB is under it). */
const SINGLE_PUT_BYTES = 5_000_000_000

/**
 * How an original of `byteCount` bytes is uploaded, or the refusal. Small files stream through the
 * Worker. A client that sends parts (`multipart: true`, CmuxHomeCore) gets multipart at every size.
 * An older client gets one request: a presigned PUT with the S3 settings, otherwise the Worker
 * stream up to the zone's body limit; past what one request can carry it is told to send parts.
 */
export const uploadModeFor = (byteCount: number, multipart: boolean, s3: boolean, workerBody: number): UploadSlot["mode"] | Fail => {
  if (byteCount <= L.streamMaxBytes) return "stream"
  if (multipart) return "multipart"
  if (s3 && byteCount <= SINGLE_PUT_BYTES) return "presigned"
  if (!s3 && byteCount <= workerBody) return "stream"
  return { status: 400, code: "attachment.multipart_required", message: "a file this large uploads in parts: send the intent with multipart: true" }
}

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
  } else await userOf(env, slot.quota_user).recordAttachmentStorage(slot.quota_user, slot.object_key, slot.byte_count + (committed.derived?.byte_count ?? 0))
  // The record's poster or preview (first upload wins): the one a message part may claim.
  return success({ state: committed.state, attachment: { hash: slot.hash, mime_type: slot.mime_type, byte_count: slot.byte_count, ...derivedField(slot.mime_type, committed.derived) } })
}

/** `{poster}` or `{preview}` (by the attachment's type) for an answer, or nothing. */
const derivedField = (mime: string, image: Image | undefined): Record<string, Image> => {
  const variant = homeConversation.derivedVariantOf(mime)
  return variant && image ? { [variant]: { hash: image.hash, mime_type: image.mime_type, byte_count: image.byte_count } } : {}
}

/** A slot whose declared poster or preview is not stored yet: 409, the slot stays usable. */
const derivedMissing = (slot: UploadSlot): Response | null => {
  const variant = homeConversation.derivedVariantOf(slot.mime_type)
  return derivedReady(slot) || !variant ? null : failure({ status: 409, code: `attachment.${variant}_missing`, message: `PUT the declared ${variant} to ${variant}_upload before the attachment` })
}

// --- Routes ---

/** POST /v1/home/attachments/intent */
export const handleAttachmentIntent = async (request: Request, env: Env, presign: Presigner = presignUrl, admitted?: Principal): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared", admitted)
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; multipart?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation)) return failure({ status: 400, code: "validation.invalid", message: "conversation id required" })
  const conversation = body.conversation
  const checked = homeConversation.validateAttachmentMeta(body)
  if (!checked.ok) return failure({ status: checked.code === "attachment.too_large" ? 413 : checked.code === "attachment.type_refused" ? 415 : 400, code: checked.code, message: checked.message })
  const meta = checked.meta
  const derivedCheck = homeConversation.validateDerivedImages(body as Record<string, unknown>, checked.class)
  if (!derivedCheck.ok) return failure({ status: derivedCheck.code === "attachment.too_large" ? 413 : derivedCheck.code === "attachment.type_refused" ? 415 : 400, code: derivedCheck.code, message: derivedCheck.message })
  const derived = derivedCheck.derived
  const s3 = s3Config(env)
  const mode = uploadModeFor(meta.byte_count, body.multipart === true, s3 !== null, workerBodyBytes(env))
  if (typeof mode !== "string") return failure(mode)
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  // Participant check before any quota, slot or storage.
  const seen = await conversationOf(env, conversation).attachmentAccess(conversation, caller.actor, meta.sha256)
  if (!seen.ok) return failure({ status: 403, code: "auth.forbidden", message: seen.message })
  if (!seen.open) return failure({ status: 409, code: "archived", message: "this conversation takes no new messages" })
  // Dedupe only for a hash this caller can already use here: never an answer about other conversations, members or hidden history.
  if (seen.record) {
    const r = seen.record
    return success({ state: "exists", attachment: { hash: r.hash, mime_type: r.mime_type, byte_count: r.byte_count, ...derivedField(r.mime_type, homeConversation.recordedImageOf(r)?.image) } })
  }
  // Every slot is charged its declared bytes, poster or preview included (refunded on an "exists" commit or an unused expiry).
  const slotId = randomId()
  const users = userOf(env, caller.user)
  const quota = await users.takeAttachmentQuota(caller.user, slotId, meta.byte_count + (derived?.image.byte_count ?? 0))
  if (!quota.ok) return failure({ status: 429, code: quota.code, message: `attachment quota reached (${quota.window})`, extra: { retry_after_ms: quota.retry_after_ms } })
  const slot = await conversationOf(env, conversation).createUploadSlot(conversation, caller.actor, caller.user, { hash: meta.sha256, byte_count: meta.byte_count, mime_type: meta.mime_type, ...(derived ? { derived: derived.image } : {}) }, mode, slotId)
  if (!slot) {
    await users.refundAttachmentQuota(caller.user, slotId)
    return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  }
  const origin = new URL(request.url).origin
  // Always through the Worker (small), whatever the attachment's mode.
  const derivedUpload = derived
    ? {
        [`${derived.variant}_upload`]: {
          method: "PUT",
          upload_url: `${origin}/v1/home/attachments/${derived.variant}/${conversation}/${uploadToken(env, conversation, slot.id, derivedPurpose(derived.variant))}`,
          headers: { "content-length": String(derived.image.byte_count) },
          expires_at: slot.expires_at
        }
      }
    : {}
  if (mode === "stream") {
    return success({
      state: "upload",
      mode,
      method: "PUT",
      upload_url: `${origin}/v1/home/attachments/upload/${conversation}/${uploadToken(env, conversation, slot.id)}`,
      headers: { "content-length": String(meta.byte_count) },
      expires_at: slot.expires_at,
      ...derivedUpload
    })
  }
  if (mode === "multipart") {
    // The R2 upload is made with the slot and kept on it, so expiry aborts it whatever the client does.
    // The object R2 completes carries the declared hash, so a completion whose answer was lost is recognised (completedObject).
    const upload = await env.HOME_ATTACHMENTS!.createMultipartUpload(slot.object_key, { httpMetadata: { contentType: slot.mime_type }, customMetadata: { sha256: slot.hash } })
    if (!(await conversationOf(env, conversation).setMultipartUpload(conversation, slot.id, upload.uploadId))) {
      await upload.abort()
      return failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
    }
    const plan = homeConversation.multipartPlan(meta.byte_count)
    return success({
      state: "upload",
      mode,
      method: "PUT",
      upload_url: `${origin}/v1/home/attachments/multipart/${conversation}/${uploadToken(env, conversation, slot.id)}`,
      headers: { "x-cmux-part-size": String(plan.partBytes) },
      part_size: plan.partBytes,
      part_count: plan.parts,
      slot: slot.id,
      expires_at: slot.expires_at,
      ...derivedUpload
    })
  }
  // An older client's single presigned PUT (uploadModeFor answers it only with the S3 settings).
  if (!s3) return failure({ status: 503, code: "attachment.large_unavailable", message: "large attachments are not enabled on this deployment" })
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
  return success({ state: "upload", mode, method: "PUT", upload_url: url, headers, slot: slot.id, expires_at: slot.expires_at, ...derivedUpload })
}

/** PUT /v1/home/attachments/upload/<conversation>/<slot>.<kid>.<mac>: single use; the bytes must hash to the slot's sha256. */
export const handleAttachmentUpload = async (request: Request, env: Env, conversation: string, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const [id, kid, sig, extra] = token.split(".")
  if (!id || !kid || !sig || extra !== undefined || !verify(env, kid, UPLOAD, [conversation, id], sig)) return invalid
  const conv = conversationOf(env, conversation)
  // A declared poster or preview not stored yet: refused before the slot is used, so the client PUTs it and retries.
  const peek = await conv.uploadSlot(conversation, id, "stream", false)
  if (!peek) return invalid
  const missing = derivedMissing(peek)
  if (missing) return missing
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

/**
 * PUT /v1/home/attachments/multipart/<conversation>/<slot token> with `x-cmux-part-number`: the next
 * part, in order, streamed into its R2 part while its bytes extend the slot's SHA-256. The last part
 * must complete the declared hash. A constant number of subrequests per part, whatever the file size.
 */
export const handleAttachmentMultipartPart = async (request: Request, env: Env, conversation: string, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const [id, kid, sig, extra] = token.split(".")
  if (!id || !kid || !sig || extra !== undefined || !verify(env, kid, UPLOAD, [conversation, id], sig)) return invalid
  const partText = request.headers.get("x-cmux-part-number") ?? ""
  if (!/^[1-9]\d{0,4}$/.test(partText)) return partInvalid(homeConversation.MULTIPART_PART_COUNT)
  const part = Number(partText)
  const conv = conversationOf(env, conversation)
  const slot = await conv.uploadSlot(conversation, id, "multipart", false)
  if (!slot?.multipart_upload_id) return invalid
  const missing = derivedMissing(slot)
  if (missing) return missing
  const plan = homeConversation.multipartPlan(slot.byte_count)
  if (!partNumberIn(part, plan.parts)) return partInvalid(plan.parts)
  const sha = new ResumableSha256(slot.multipart_hash)
  const next = sha.bytes / plan.partBytes + 1
  if (part !== next) return failure({ status: 409, code: "attachment.part_order", message: Number.isInteger(next) ? `send part ${next} next` : "every part is stored; complete the upload" })
  const length = Math.min(plan.partBytes, slot.byte_count - sha.bytes)
  // The part is this request's before any byte reaches R2: a concurrent PUT of it is refused here,
  // so it can never replace the R2 part after this one's etag is recorded.
  const claimed = await conv.claimMultipartPart(conversation, id, part, slot.multipart_hash ?? null)
  if (!claimed.ok) {
    return claimed.busy
      ? failure({ status: 409, code: "attachment.part_busy", message: `part ${part} is being uploaded by another request; send it again if that one fails`, extra: { retryable: true } })
      : failure({ status: 409, code: "attachment.part_order", message: "that part was already stored, or the slot ended" })
  }
  let recorded = false
  try {
    const upload = env.HOME_ATTACHMENTS!.resumeMultipartUpload(slot.object_key, slot.multipart_upload_id)
    const uploaded = await streamPartInto(upload, part, request, length, sha)
    if (!uploaded) return failure({ status: 400, code: "attachment.size_mismatch", message: `part ${part} must be exactly ${length} bytes` })
    const after = part < plan.parts ? sha.state() : `${sha.digest()}:${sha.bytes}`
    if (part === plan.parts && after !== `${slot.hash}:${slot.byte_count}`) {
      // The parts so far are hashed: no retry can fix the file, so the slot ends here.
      const used = await conv.uploadSlot(conversation, id, "multipart", true)
      await upload.abort().catch(() => undefined)
      if (used) await conv.settleSlot(conversation, id)
      return failure({ status: 400, code: "attachment.hash_mismatch", message: "the bytes do not match the declared sha256" })
    }
    // The claim ended (the slot expired or ended): nothing was recorded.
    recorded = await conv.recordMultipartPart(conversation, id, part, uploaded.etag, slot.multipart_hash ?? null, after, claimed.claim)
    if (!recorded) return failure({ status: 409, code: "attachment.part_order", message: "that part was already stored, or the slot ended" })
    return success({ part_number: part, byte_count: length, etag: uploaded.etag })
  } finally {
    // A part that was not recorded frees its claim at once, so the client sends it again.
    if (!recorded) await conv.releaseMultipartPart(conversation, id, claimed.claim).catch(() => undefined)
  }
}

/**
 * POST /v1/home/attachments/multipart/complete {conversation, slot, parts?}: once every part is
 * stored and the hash matched, R2 joins the recorded parts in one call and the owner commits the
 * object. `parts` (the client's own list, optional) must name the same parts and etags.
 */
export const handleAttachmentMultipartComplete = async (request: Request, env: Env, admitted?: Principal): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared", admitted)
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; slot?: unknown; parts?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || typeof body.slot !== "string" || !/^[0-9a-f]{32}$/.test(body.slot)) return failure({ status: 400, code: "validation.invalid", message: "conversation and slot required" })
  const conversation = body.conversation
  const conv = conversationOf(env, conversation)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const peek = await conv.uploadSlot(conversation, body.slot, "multipart", false, caller.actor)
  if (!peek?.multipart_upload_id) return invalid
  const missing = derivedMissing(peek)
  if (missing) return missing
  const { parts } = homeConversation.multipartPlan(peek.byte_count)
  const listed = body.parts
  if (listed !== undefined && (!Array.isArray(listed) || listed.length !== parts || listed.some((p, i) => !partNumberIn(p?.part_number, parts) || p.part_number !== i + 1 || typeof p.etag !== "string"))) return failure({ status: 400, code: "attachment.parts_invalid", message: `parts must be numbered 1 to ${parts}, in order, each with its etag` })
  const etags = await conv.multipartEtags(conversation, peek.id)
  if (etags.length !== parts || peek.multipart_hash !== `${peek.hash}:${peek.byte_count}`) return failure({ status: 409, code: "attachment.part_missing", message: "one or more upload parts are missing" })
  if (listed?.some((p: { etag: string }, i: number) => p.etag !== etags[i])) return failure({ status: 409, code: "attachment.part_missing", message: "the parts do not match the stored parts" })
  const slot = await conv.uploadSlot(conversation, peek.id, "multipart", true, caller.actor)
  if (!slot?.multipart_upload_id) return invalid
  const bucket = env.HOME_ATTACHMENTS!
  const upload = bucket.resumeMultipartUpload(slot.object_key, slot.multipart_upload_id)
  // Only bytes that cannot form the declared file end the slot; no retry can fix them.
  const refuse = async () => {
    await upload.abort().catch(() => undefined)
    await bucket.delete(slotKeys(slot))
    await conv.settleSlot(conversation, slot.id)
    return failure({ status: 400, code: "attachment.size_mismatch", message: "the stored parts do not form the declared file" })
  }
  let etag: string
  try {
    const object = await upload.complete(etags.map((tag, i) => ({ partNumber: i + 1, etag: tag })))
    if (object.size !== slot.byte_count) return refuse()
    etag = object.etag
  } catch (error) {
    const kind = completionFailure(error)
    if (kind === "integrity") return refuse()
    // A transient failure, or an upload already closed: R2 may have completed it before its answer was lost.
    const found = await completedObject(bucket, slot)
    if (found) etag = found.etag
    else if (kind === "closed" && found === null) return refuse()
    else {
      // Not known to have happened: the parts stay and the slot is open again, so the client completes again.
      await conv.reopenMultipart(conversation, slot.id)
      return failure({ status: 503, code: "attachment.complete_unavailable", message: "the upload could not be completed right now; complete it again", extra: { retryable: true } })
    }
  }
  return finish(env, conversation, slot, etag)
}

/**
 * The slot's object when an earlier completion already made it: the declared size and the
 * declared SHA-256 its upload was created with. Null when it is not there; undefined when R2
 * could not be asked (the caller keeps the slot for a retry).
 */
const completedObject = async (bucket: R2Bucket, slot: UploadSlot): Promise<R2Object | null | undefined> => {
  const head = await bucket.head(slot.object_key).catch(() => undefined)
  if (head === undefined) return undefined
  return head && head.size === slot.byte_count && head.customMetadata?.sha256 === slot.hash ? head : null
}

/**
 * PUT /v1/home/attachments/<poster|preview>/<conversation>/<slot>.<kid>.<mac>: the declared poster
 * (video) or preview (image) of an open slot, once; the bytes must hash to its sha256.
 */
export const handleAttachmentDerived = async (request: Request, env: Env, variant: Variant, conversation: string, token: string): Promise<Response> => {
  const off = configured(env)
  if (off) return failure(off)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: `the ${variant} slot is invalid, used or expired; ask for a new one` })
  const [id, kid, sig, extra] = token.split(".")
  if (!id || !kid || !sig || extra !== undefined || !verify(env, kid, derivedPurpose(variant), [conversation, id], sig)) return invalid
  const conv = conversationOf(env, conversation)
  const slot = await conv.derivedSlot(conversation, id)
  // The token's purpose names the variant; the slot's own type must name it too (a second check behind the token).
  if (!slot?.derived || homeConversation.derivedVariantOf(slot.mime_type) !== variant) return invalid
  const key = homeConversation.attachmentDerivedKey(slot.object_key, variant)
  const put = await streamInto(env.HOME_ATTACHMENTS!, key, request, slot.derived.byte_count, slot.derived.hash, slot.derived.mime_type)
  await conv.settleDerived(conversation, slot.id, put.ok ? (put.etag ?? "") : null)
  if (!put.ok) return failure({ status: 400, code: put.code, message: `the ${variant} bytes do not match the declared size and sha256` })
  return success({ state: `${variant}_stored` })
}

/** POST /v1/home/attachments/commit {conversation, slot}: after a presigned PUT; HEADs size and SHA-256 before the object is usable. */
export const handleAttachmentCommit = async (request: Request, env: Env, admitted?: Principal): Promise<Response> => {
  const caller = await callerOf(request, env, "mutate-shared", admitted)
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; slot?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || typeof body.slot !== "string" || !/^[0-9a-f]{32}$/.test(body.slot)) return failure({ status: 400, code: "validation.invalid", message: "conversation and slot required" })
  const conv = conversationOf(env, body.conversation)
  const invalid = failure({ status: 403, code: "attachment.slot_invalid", message: "the upload slot is invalid, used or expired; ask for a new one" })
  const peek = await conv.uploadSlot(body.conversation, body.slot, "presigned", false, caller.actor)
  if (!peek) return invalid
  const missing = derivedMissing(peek)
  if (missing) return missing
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
export const handleAttachmentUrl = async (request: Request, env: Env, admitted?: Principal): Promise<Response> => {
  const caller = await callerOf(request, env, "read", admitted)
  if (isFail(caller)) return failure(caller)
  const off = configured(env)
  if (off) return failure(off)
  const body = await readJson<{ conversation?: unknown; hash?: unknown; message_id?: unknown; part_index?: unknown; variant?: unknown }>(request)
  if (!body || typeof body.conversation !== "string" || !CONVERSATION_ID.test(body.conversation) || !homeConversation.isSha256(body.hash)) return failure({ status: 400, code: "validation.invalid", message: "conversation and hash required" })
  const at = body.message_id === undefined ? undefined : typeof body.message_id === "string" && MESSAGE_ID.test(body.message_id) && Number.isInteger(body.part_index) && (body.part_index as number) >= 0 && (body.part_index as number) < 16 ? { message_id: body.message_id, part_index: body.part_index as number } : null
  if (at === null) return failure({ status: 400, code: "validation.invalid", message: "message_id needs a part_index" })
  if (body.variant !== undefined && !homeConversation.isDerivedVariant(body.variant)) return failure({ status: 400, code: "validation.invalid", message: `variant must be "poster" or "preview"` })
  const variant = body.variant as Variant | undefined
  const slow = await limited(env, caller.user)
  if (slow) return failure(slow)
  const access = await conversationOf(env, body.conversation).downloadAccess(body.conversation, caller.actor, { hash: body.hash }, at)
  if (access === "forbidden") return failure({ status: 403, code: "auth.forbidden", message: "not a participant of this conversation" })
  if (!access) return failure({ status: 404, code: "attachment.not_found", message: "no such attachment in this conversation" })
  // Never a fallback to the original: a poster (preview) URL exists only for a video (image) part whose record holds one.
  if (variant && !derivedServed(access, variant)) return noDerived(variant)
  const expires = Date.now() + L.downloadTtlMs
  const path = downloadPath(env, { conversation: body.conversation, objectId: access.record.object_id, actor: caller.actor, expires, ...(at ? { message: at.message_id, part: at.part_index } : {}), ...(variant ? { variant } : {}) })
  return success({ url: `${new URL(request.url).origin}${path}`, expires_at: expires })
}

/** The derived image a download may serve: the record's (server-chosen key), for a record and, when asked by part, a part of the variant's class. */
const derivedServed = (access: NonNullable<DownloadAccess>, variant: Variant) =>
  homeConversation.derivedVariantOf(access.record.mime_type) === variant && (!access.part || homeConversation.derivedVariantOf(access.part.mime_type) === variant) ? access.record[variant] : undefined
const noDerived = (variant: Variant) => failure({ status: 404, code: `attachment.no_${variant}`, message: `this attachment has no ${variant}` })

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
  if (variant !== undefined && !homeConversation.isDerivedVariant(variant)) return failure({ status: 403, code: "auth.forbidden", message: "the link is invalid or expired" })
  const args: DownloadArgs = { conversation, objectId, actor: q.get("a") ?? "", expires: Number(q.get("e")), ...(message ? { message, part: part! } : {}), ...(variant ? { variant } : {}) }
  const kid = q.get("k") ?? ""
  const denied = failure({ status: 403, code: "auth.forbidden", message: "the link is invalid or expired" })
  // HEAD is a GET without a body: both verify against the GET signature.
  const signed = verify(env, kid, DOWNLOAD, downloadFields(args), q.get("s") ?? "")
  if (!signed || !args.actor || !Number.isSafeInteger(args.expires) || args.expires <= Date.now() || (message !== undefined && (!MESSAGE_ID.test(message) || !Number.isInteger(part)))) return denied
  const access = await conversationOf(env, conversation).downloadAccess(conversation, args.actor, { object_id: objectId }, message ? { message_id: message, part_index: part! } : undefined)
  if (!access || access === "forbidden") return denied
  const image = variant ? derivedServed(access, variant) : undefined
  if (variant && !image) return noDerived(variant)
  // What is served: the recorded object, or the poster or preview recorded with it (key, type, size and etag from the record, never from the request).
  const rec =
    variant && image ? { object_key: homeConversation.attachmentDerivedKey(access.record.object_key, variant), mime_type: image.mime_type, byte_count: image.byte_count, etag: image.etag } : access.record
  const name = variant && image ? `${variant}.${EXTENSIONS[image.mime_type] ?? "jpg"}` : (access.name ?? `attachment.${EXTENSIONS[rec.mime_type] ?? "bin"}`)
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
