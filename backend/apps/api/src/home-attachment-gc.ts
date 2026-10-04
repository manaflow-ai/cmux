import type { SqlStore } from "@cmux/ownership"
import { conversation } from "@cmux/home-core"
import type { Env } from "./env.ts"
import * as store from "./home-attachment-store.ts"

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
  const times = [store.nextDropAt(sql), store.nextSweepAt(sql), store.nextSlotDue(sql), store.purgeAt(sql)].filter((t): t is number => t !== null)
  return times.length ? Math.min(...times) : null
}

/** The attachment part of the ConversationDO wake: slot expiry, the due sweep, and a due prefix purge of `entity`. */
export const runAttachmentWake = async (deps: AttachmentGcDeps, entity: string | undefined, now: number): Promise<void> => {
  await expireSlots(deps, now)
  await drainDrops(deps, now)
  // A reference released earlier in this wake marks the sweep dirty at Date.now(), which may be later than the wake's `now`.
  const at = Math.max(now, Date.now())
  const due = store.nextSweepAt(deps.sql)
  if (due !== null && due <= at) await sweepAttachments(deps, at)
  const purge = store.purgeAt(deps.sql)
  if (purge !== null && purge <= now && entity) {
    await deletePrefix(deps.env, entity)
    store.clearPurge(deps.sql, purge)
  }
}

/**
 * Slots whose time is up: their object key is deleted (a PUT that never committed, or a re-PUT
 * to a presigned URL after the slot ended), a slot that never committed is refunded, then the
 * row goes. Each step is idempotent, so a failed wake retries safely.
 */
const expireSlots = async (deps: AttachmentGcDeps, now: number): Promise<void> => {
  for (;;) {
    const due = store.dueSlots(deps.sql, now, 100)
    if (due.length === 0) return
    if (deps.env.HOME_ATTACHMENTS) await deps.env.HOME_ATTACHMENTS.delete(due.flatMap(store.slotKeys))
    for (const slot of due) {
      if (slot.state !== "tombstone") await deps.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
      store.removeSlot(deps.sql, slot.id)
    }
    if (due.length < 100) return
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
    console.error(JSON.stringify({ msg: "attachment drop failed", object_key: r.object_key, error: String(e).slice(0, 200) }))
    store.failDrop(deps.sql, r.object_key, now)
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
  if (!deps.env.HOME_ATTACHMENTS) return 0
  // Refunds first (idempotent by slot id): a failure throws before anything is forgotten, so a retry refunds again.
  for (const slot of store.allSlots(deps.sql)) if (slot.state !== "tombstone") await deps.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
  const { records, slots } = store.forgetAll(deps.sql)
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

/** Deletes every object under `home/v1/<conversation>/`; answers the keys it deleted. */
const deletePrefix = async (env: Env, entity: string): Promise<Array<string>> => {
  const bucket = env.HOME_ATTACHMENTS
  if (!bucket) return []
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
