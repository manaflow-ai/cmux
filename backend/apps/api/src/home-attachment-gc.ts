import type { SqlStore } from "@cmux/ownership"
import { conversation } from "@cmux/home-core"
import type { Env } from "./env.ts"
import * as store from "./home-attachment-store.ts"
import { completionFailure } from "./home-attachment-stream.ts"

/** The uploader's UserDO calls the attachment storage paths make. */
export type AttachmentUsers = { releaseAttachmentStorage(e: string, key: string): Promise<void>; refundAttachmentQuota(e: string, slot: string): Promise<void> }

/** What the attachment storage paths need from their ConversationDO (the only writer of the store). */
export interface AttachmentGcDeps {
  readonly sql: Pick<SqlStore, "exec">
  readonly env: Env
  readonly users: (user: string) => AttachmentUsers
  readonly scheduleAlarm: () => void
}

/** The earliest attachment work: the unreferenced sweep, an upload slot's expiry, or a prefix purge. */
export const attachmentWakeAt = (sql: Pick<SqlStore, "exec">): number | null => {
  // A queued drop is due at its own next attempt (a real time, so a commit never sets the alarm to 0).
  const times = [store.nextDropAt(sql), store.nextSweepAt(sql), store.nextSlotDue(sql), store.purgeAt(sql), store.nextAbortAt(sql)].filter((t): t is number => t !== null)
  return times.length ? Math.min(...times) : null
}

/** The attachment part of the ConversationDO wake: slot expiry, the due sweep, and a due prefix purge of `entity`. */
export const runAttachmentWake = async (deps: AttachmentGcDeps, entity: string | undefined, now: number): Promise<void> => {
  // Each step runs even when another throws (a failing drop never blocks the sweep or the purge); the first failure is rethrown.
  let failure: unknown
  const step = async (run: () => Promise<unknown>) => {
    try {
      await run()
    } catch (e) {
      failure ??= e
    }
  }
  await step(() => expireSlots(deps, now))
  await step(() => drainAborts(deps, now))
  await step(() => drainDrops(deps, now))
  // A reference released earlier in this wake marks the sweep dirty at Date.now(), which may be later than the wake's `now`.
  const at = Math.max(now, Date.now())
  const due = store.nextSweepAt(deps.sql)
  if (due !== null && due <= at) await step(() => sweepAttachments(deps, at))
  const purge = store.purgeAt(deps.sql)
  if (purge !== null && purge <= now && entity) {
    await step(async () => {
      await deletePrefix(deps.env, entity)
      store.clearPurge(deps.sql, purge)
    })
  }
  if (failure !== undefined) throw failure
}

/** Due slots one wake expires: its subrequests stay bounded; the alarm comes back at once while more are due. */
export const EXPIRE_PER_WAKE = 100

/**
 * Slots whose time is up, oldest first: their object keys are deleted (a PUT that never committed,
 * or a re-PUT to a presigned URL after the slot ended), a multipart slot's R2 upload is aborted, a
 * slot that never committed is refunded, then the row goes, so the next wake reads the next page.
 * An upload R2 already ended or no longer knows (NoSuchUpload) is done. Any other abort failure
 * queues the upload id (store.queueAbort) in the step that forgets the slot, so a later wake aborts
 * it (drainAborts) and one bad upload never holds back the slots after it. Each step is idempotent,
 * so a failed wake retries safely.
 */
const expireSlots = async (deps: AttachmentGcDeps, now: number): Promise<void> => {
  const due = store.dueSlots(deps.sql, now, EXPIRE_PER_WAKE)
  if (due.length === 0) return
  const bucket = deps.env.HOME_ATTACHMENTS
  const retry = new Set<string>()
  if (bucket) {
    await bucket.delete(due.flatMap(store.slotKeys))
    for (const slot of due) {
      // A multipart slot whose upload was never recorded (the owner was unreachable when the intent made it): the slot
      // is the record. A bucket that can list its open uploads (self-hosted) aborts every one under the slot's own key;
      // R2's binding cannot list them, and its lifecycle rule ends them.
      if (slot.mode === "multipart" && !slot.multipart_upload_id && abortsByPrefix(bucket)) {
        await bucket.abortMultipartUploads(slot.object_key).catch((e: unknown) => {
          console.error(JSON.stringify({ msg: "attachment multipart abort failed", object_key: slot.object_key, error: String(e).slice(0, 200) }))
          retry.add(slot.id)
        })
        continue
      }
      if (!slot.multipart_upload_id) continue
      try {
        await bucket.resumeMultipartUpload(slot.object_key, slot.multipart_upload_id).abort()
      } catch (e) {
        if (completionFailure(e) === "closed") continue
        console.error(JSON.stringify({ msg: "attachment multipart abort failed", object_key: slot.object_key, error: String(e).slice(0, 200) }))
        retry.add(slot.id)
      }
    }
  }
  for (const slot of due) {
    if (slot.state !== "tombstone") await deps.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
    // Queued in the same synchronous step that forgets the slot: the upload id (or, for an unrecorded one, its key prefix) is never lost.
    if (retry.has(slot.id)) store.queueAbort(deps.sql, { upload_id: slot.multipart_upload_id ?? `${PREFIX_ABORT}${slot.object_key}`, object_key: slot.object_key }, now)
    store.removeSlot(deps.sql, slot.id)
  }
}

/** A queued abort of every open upload under a slot's key (an upload the owner never recorded): no upload id is known. */
const PREFIX_ABORT = "prefix:"

/** Retries the queued aborts that are due; an upload R2 no longer knows is done, any other failure backs off. */
const drainAborts = async (deps: AttachmentGcDeps, now: number): Promise<void> => {
  const bucket = deps.env.HOME_ATTACHMENTS
  if (!bucket) return
  for (const upload of store.dueAborts(deps.sql, now)) {
    try {
      if (upload.upload_id.startsWith(PREFIX_ABORT)) {
        if (abortsByPrefix(bucket)) await bucket.abortMultipartUploads(upload.object_key)
      } else await bucket.resumeMultipartUpload(upload.object_key, upload.upload_id).abort()
    } catch (e) {
      if (completionFailure(e) !== "closed") {
        if (store.failAbort(deps.sql, upload.upload_id, now)) console.error(JSON.stringify({ event: "attachment.abort.dead_letter", object_key: upload.object_key }))
        else console.error(JSON.stringify({ msg: "attachment multipart abort failed", object_key: upload.object_key, error: String(e).slice(0, 200) }))
        continue
      }
    }
    store.clearAbort(deps.sql, upload.upload_id)
  }
}

/** Unreferenced uploads past the grace period: forget, delete their objects, release the uploaders' storage. */
export const sweepAttachments = async (deps: AttachmentGcDeps, now: number): Promise<number> => {
  const { records, done } = store.sweepBatch(deps.sql, now - conversation.ATTACHMENT_LIMITS.unreferencedGraceMs)
  await drainDrops(deps, Math.max(now, Date.now()))
  store.markSwept(deps.sql, now, done)
  return records.length
}

/**
 * Deletes the R2 objects of the due drops and releases their uploaders' stored bytes; a drop
 * leaves the queue only after both succeeded. A failed attempt moves that drop's next attempt
 * (store.failDrop backoff) instead of throwing, so the rest of the wake runs and the owner's alarm
 * follows the earliest next attempt. R2 deletes and releases are idempotent.
 */
const drainDrops = async (deps: AttachmentGcDeps, now: number): Promise<void> => {
  const fail = (r: conversation.AttachmentRecord, e: unknown) => {
    // A dead letter is an error-level event with ids only (a stable field for alerts); a retryable failure keeps its cause.
    if (store.failDrop(deps.sql, r.object_key, now)) console.error(JSON.stringify({ event: "attachment.drop.dead_letter", object_key: r.object_key, quota_user: r.quota_user }))
    else console.error(JSON.stringify({ msg: "attachment drop failed", object_key: r.object_key, quota_user: r.quota_user, error: String(e).slice(0, 200) }))
  }
  for (let drops = store.dueDrops(deps.sql, now); drops.length > 0; drops = store.dueDrops(deps.sql, now)) {
    try {
      if (deps.env.HOME_ATTACHMENTS) await deps.env.HOME_ATTACHMENTS.delete(drops.flatMap(store.recordKeys))
    } catch (e) {
      for (const r of drops) fail(r, e)
      continue
    }
    for (const r of drops) {
      try {
        await deps.users(r.quota_user).releaseAttachmentStorage(r.quota_user, r.object_key)
        store.clearDrop(deps.sql, r.object_key)
      } catch (e) {
        fail(r, e)
      }
    }
  }
}

/**
 * Conversation storage deletion: forgets every record and slot, deletes every object under
 * `home/v1/<conversation>/` (also orphans of failed uploads) and releases the uploaders' storage.
 * A dropped slot's URL may still finish a PUT after this (S3 checks expiry only at the start),
 * so the prefix is deleted again by the alarm once the latest dropped slot is past its expiry
 * plus the upload grace. The deletion path that calls it (no human for 30 days, section 10)
 * does not exist yet; the conversation takes no new uploads by then (archived).
 */
export const deleteAttachmentStorage = async (deps: AttachmentGcDeps, entity: string): Promise<number> => {
  const bucket = deps.env.HOME_ATTACHMENTS
  if (!bucket) return 0
  // Refunds and multipart aborts first (both idempotent): a failure throws before anything is forgotten, so a retry does them again.
  const before = store.allSlots(deps.sql)
  for (const slot of before) if (slot.state !== "tombstone") await deps.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
  await abortUploads(bucket, before)
  const { records, slots } = store.forgetAll(deps.sql)
  // Also the slots forgetAll returns: one opened during the awaits above is refunded too (refunds are idempotent).
  for (const slot of slots) if (slot.state !== "tombstone") await deps.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
  // And its upload aborted; it is forgotten now, so a failure is logged (R2's lifecycle rule, or the self-hosted prefix abort below, ends it).
  const aborted = new Set(before.map((s) => s.multipart_upload_id))
  await abortUploads(bucket, slots.filter((s) => !aborted.has(s.multipart_upload_id))).catch((e: unknown) => console.error(JSON.stringify({ msg: "attachment multipart abort failed", entity, error: String(e).slice(0, 200) })))
  if (slots.length) {
    store.schedulePurge(deps.sql, Math.max(...slots.map((s) => s.expires_at)) + store.UPLOADING_GRACE_MS)
    deps.scheduleAlarm()
  }
  await drainDrops(deps, Date.now())
  // A drop that failed keeps the alarm at its next attempt.
  deps.scheduleAlarm()
  const known = new Set(records.flatMap(store.recordKeys))
  return records.length + (await deletePrefix(deps.env, entity)).filter((k) => !known.has(k)).length
}

/**
 * Aborts the open R2 multipart upload of each multipart slot, so its stored parts go with the
 * conversation. An upload R2 already closed (completed or aborted: NoSuchUpload) is done; any
 * other failure throws, after every other abort was tried.
 */
const abortUploads = async (bucket: R2Bucket, slots: ReadonlyArray<store.UploadSlot>): Promise<void> => {
  let failure: unknown
  for (const slot of slots) {
    if (!slot.multipart_upload_id) continue
    try {
      await bucket.resumeMultipartUpload(slot.object_key, slot.multipart_upload_id).abort()
    } catch (e) {
      if (completionFailure(e) !== "closed") failure ??= e
    }
  }
  if (failure !== undefined) throw failure
}

/** A bucket that can enumerate its open uploads (the self-hosted FsBucket); R2's binding cannot, its lifecycle rule ends them. */
type PrefixAborting = { abortMultipartUploads(prefix: string): Promise<number> }
const abortsByPrefix = (bucket: R2Bucket): bucket is R2Bucket & PrefixAborting => typeof (bucket as Partial<PrefixAborting>).abortMultipartUploads === "function"

/**
 * Deletes every object under `home/v1/<conversation>/`, and, where the bucket can enumerate them,
 * every open multipart upload under it (also one no slot names any more); answers the keys it deleted.
 */
const deletePrefix = async (env: Env, entity: string): Promise<Array<string>> => {
  const bucket = env.HOME_ATTACHMENTS
  if (!bucket) return []
  if (abortsByPrefix(bucket)) await bucket.abortMultipartUploads(conversation.attachmentPrefix(entity))
  const deleted: Array<string> = []
  let cursor: string | undefined
  do {
    const page = await bucket.list({ prefix: conversation.attachmentPrefix(entity), ...(cursor ? { cursor } : {}) })
    if (page.objects.length) {
      await bucket.delete(page.objects.map((o) => o.key))
      deleted.push(...page.objects.map((o) => o.key))
    }
    cursor = page.truncated ? page.cursor : undefined
  } while (cursor)
  return deleted
}
