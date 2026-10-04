import { describe, expect, it } from "vitest"
import {
  ATTACHMENT_LIMITS,
  attachmentQuota,
  makeConversationDomain,
  TABLE_ATTREF,
  validateAttachmentMeta,
  type AttachmentRecord,
  type ConversationParams,
  type ConversationState,
  type Principal
} from "../src/conversation/index.ts"
import { CoreHost, DomainHost, human, text } from "./support/harness.ts"
import { ALICE } from "./support/cloud.ts"

/** Home attachments (home-messaging.md section 2, attachment part): metadata rules, quota and the owner's hash check. */
const session = (user: string, name: string): Principal => ({ identity: `${user}:s`, user, kind: "session", display_name: name })
const HASH = "a".repeat(64)
const POSTER = "b".repeat(64)
const meta = (over: Record<string, unknown> = {}) => ({ sha256: HASH, byte_count: 1000, mime_type: "image/png", name: "photo.png", ...over })

describe("attachment metadata (upload intent)", () => {
  it("admits allow-listed types under their class cap", () => {
    expect(validateAttachmentMeta(meta())).toMatchObject({ ok: true, class: "image" })
    expect(validateAttachmentMeta(meta({ mime_type: "video/mp4", name: "clip.mp4", byte_count: ATTACHMENT_LIMITS.maxBytes.video, duration_ms: 5000 }))).toMatchObject({ ok: true, class: "video" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/pdf", name: "doc.pdf" }))).toMatchObject({ ok: true, class: "file" })
  })

  it("refuses types off the allow list and executable extensions whatever the type", () => {
    expect(validateAttachmentMeta(meta({ mime_type: "image/svg+xml", name: "x.svg" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "text/html", name: "x.html" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/x-msdownload", name: "setup.exe" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/zip", name: "Setup.EXE" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "text/plain", name: "run.sh" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
  })

  it("refuses sizes over the class cap, bad hashes and bad names", () => {
    expect(validateAttachmentMeta(meta({ byte_count: ATTACHMENT_LIMITS.maxBytes.image + 1 }))).toMatchObject({ ok: false, code: "attachment.too_large" })
    expect(validateAttachmentMeta(meta({ mime_type: "video/mp4", name: "v.mp4", byte_count: ATTACHMENT_LIMITS.maxBytes.video + 1 }))).toMatchObject({ ok: false, code: "attachment.too_large" })
    expect(validateAttachmentMeta(meta({ byte_count: 0 }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ sha256: "A".repeat(64) }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ name: "../etc/passwd" }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ name: "a\u0000.png" }))).toMatchObject({ ok: false, code: "validation.invalid" })
  })
})

describe("attachment quota (per user, rolling day and month)", () => {
  const now = Date.UTC(2026, 9, 3)
  it("admits until the daily cap, then answers when to retry", () => {
    const day = ATTACHMENT_LIMITS.quota.dayBytes
    expect(attachmentQuota([], day, now)).toEqual({ ok: true })
    const used = [{ bytes: day - 10, at: now - 3_600_000 }]
    expect(attachmentQuota(used, 10, now)).toEqual({ ok: true })
    const refused = attachmentQuota(used, 11, now)
    expect(refused).toMatchObject({ ok: false, window: "day" })
    expect(refused.ok === false && refused.retry_after_ms).toBe(23 * 3_600_000)
  })
  it("counts the month window too", () => {
    const month = ATTACHMENT_LIMITS.quota.monthBytes
    const used = Array.from({ length: 10 }, (_, i) => ({ bytes: month / 10, at: now - (i + 2) * 86_400_000 }))
    expect(attachmentQuota(used, 1, now)).toMatchObject({ ok: false, window: "month" })
  })
})

describe("message.send with attachment parts (the owner checks the hash)", () => {
  const records = new Map<string, AttachmentRecord>()
  const record = (hash: string, mime_type = "image/png", byte_count = 1000): AttachmentRecord => ({ hash, object_key: `home/v1/conv_GROUP/${hash}/u1`, mime_type, byte_count, name: "photo.png", uploaders: [ALICE], created_at: 0 })
  records.set(HASH, record(HASH))
  records.set(POSTER, record(POSTER, "image/jpeg", 50))
  const domain = makeConversationDomain({ attachmentFor: (hash) => records.get(hash) })
  const part = (over: Record<string, unknown> = {}) => ({ type: "attachment", hash: HASH, name: "photo.png", mime_type: "image/png", byte_count: 1000, width: 10, height: 20, ...over })
  const group = () => {
    const host = new DomainHost<ConversationState, ConversationParams>(domain)
    expect(host.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_GROUP", kind: "group", title: "T", participants: [human(ALICE, "Alice")] }, "c").ok).toBe(true)
    return host
  }
  const send = (host: DomainHost<ConversationState, ConversationParams>, parts: unknown, key: string) => host.run(session(ALICE, "Alice"), "message.send", { client_msg_id: key, parts }, key)

  it("accepts a part whose hash was uploaded for this conversation and records the reference", () => {
    const host = group()
    const sent = send(host, [part(), text("look")], "m1")
    expect(sent.ok).toBe(true)
    const id = (sent.ok && (sent.value as { message_id: string }).message_id) as string
    expect(host.rows.get(TABLE_ATTREF, `${HASH}:${id}`)?.row).toMatchObject({ hash: HASH, message_id: id, seq: 1 })
    // Retraction removes the reference, so the object becomes collectable.
    expect(host.run(session(ALICE, "Alice"), "message.retract", { message_id: id }, "r1").ok).toBe(true)
    expect(host.rows.get(TABLE_ATTREF, `${HASH}:${id}`)).toBeUndefined()
  })

  it("refuses an unknown or foreign hash, a mismatched size or type, and an unknown poster", () => {
    const host = group()
    expect(send(host, [part({ hash: "c".repeat(64) })], "m1")).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(send(host, [part({ byte_count: 999 })], "m2")).toMatchObject({ ok: false, code: "attachment_mismatch" })
    expect(send(host, [part({ mime_type: "image/jpeg" })], "m3")).toMatchObject({ ok: false, code: "attachment_mismatch" })
    expect(send(host, [part({ poster_hash: "d".repeat(64) })], "m4")).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(send(host, [part({ name: "photo.exe" })], "m5")).toMatchObject({ ok: false, code: "invalid_parts" })
  })

  it("an edit moves references: new hashes are checked, dropped ones are released", () => {
    const host = group()
    const sent = send(host, [part()], "m1")
    const id = (sent.ok && (sent.value as { message_id: string }).message_id) as string
    expect(host.run(session(ALICE, "Alice"), "message.edit", { message_id: id, parts: [part({ hash: "e".repeat(64) })] }, "e0")).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(host.run(session(ALICE, "Alice"), "message.edit", { message_id: id, parts: [part({ hash: POSTER, mime_type: "image/jpeg", byte_count: 50 })] }, "e1").ok).toBe(true)
    expect(host.rows.get(TABLE_ATTREF, `${HASH}:${id}`)).toBeUndefined()
    expect(host.rows.get(TABLE_ATTREF, `${POSTER}:${id}`)).toBeDefined()
  })

  it("a local head (Rust parity) has no attachment parts", () => {
    const core = new CoreHost()
    const r = core.run("user_local", "k1", { kind: "message.send", client_msg_id: "k1", parts: [part()] as never })
    expect(r).toMatchObject({ ok: false, code: "invalid_parts" })
  })
})
