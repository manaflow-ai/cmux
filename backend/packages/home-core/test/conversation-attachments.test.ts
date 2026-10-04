import { describe, expect, it } from "vitest"
import {
  ATTACHMENT_LIMITS,
  attachmentQuota,
  makeConversationDomain,
  messageDeleteWrites,
  previewAttachmentsOf,
  TABLE_ATTREF,
  validateAttachmentMeta,
  type AttachmentRecord,
  type ConversationParams,
  type ConversationState,
  type Principal
} from "../src/conversation/index.ts"
import { CoreHost, DomainHost, human, text } from "./support/harness.ts"
import { ALICE, BOB, CAROL } from "./support/cloud.ts"
import { bumpEntry, validBump } from "../src/inbox/reducer.ts"

/** Home attachments (home-messaging.md section 2, attachment part): metadata rules, quota and the owner's hash check. */
const session = (user: string, name: string): Principal => ({ identity: `${user}:s`, user, kind: "session", display_name: name })
const HASH = "a".repeat(64)
const POSTER = "b".repeat(64)
const meta = (over: Record<string, unknown> = {}) => ({ sha256: HASH, byte_count: 1000, mime_type: "image/png", name: "photo.png", ...over })

describe("attachment metadata (upload intent)", () => {
  it("admits allow-listed types up to 100 MB per file", () => {
    expect(validateAttachmentMeta(meta({ byte_count: ATTACHMENT_LIMITS.maxBytes }))).toMatchObject({ ok: true, class: "image" })
    expect(validateAttachmentMeta(meta({ mime_type: "video/mp4", name: "clip.mp4", byte_count: ATTACHMENT_LIMITS.maxBytes, duration_ms: 5000 }))).toMatchObject({ ok: true, class: "video" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/pdf", name: "doc.pdf" }))).toMatchObject({ ok: true, class: "file" })
    for (const [mime, name] of [["image/heic", "a.heic"], ["video/quicktime", "a.mov"], ["audio/mp4", "a.m4a"], ["audio/mpeg", "a.mp3"], ["audio/aac", "a.aac"], ["audio/wav", "a.wav"], ["text/markdown", "a.md"], ["text/csv", "a.csv"], ["application/json", "a.json"], ["application/zip", "a.zip"]]) {
      expect(validateAttachmentMeta(meta({ mime_type: mime, name }))).toMatchObject({ ok: true })
    }
  })

  it("the allow list is the agreed one: no avif, webm, office documents, svg, html or xml", () => {
    for (const [mime, name] of [["image/avif", "a.avif"], ["video/webm", "a.webm"], ["application/msword", "a.doc"], ["image/svg+xml", "a.svg"], ["application/xml", "a.xml"], ["text/xml", "a.txt"], ["image/heif", "a.heif"]]) {
      expect(validateAttachmentMeta(meta({ mime_type: mime, name }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    }
  })

  it("refuses types off the allow list and executable extensions whatever the type", () => {
    expect(validateAttachmentMeta(meta({ mime_type: "image/svg+xml", name: "x.svg" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "text/html", name: "x.html" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/x-msdownload", name: "setup.exe" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "application/zip", name: "Setup.EXE" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
    expect(validateAttachmentMeta(meta({ mime_type: "text/plain", name: "run.sh" }))).toMatchObject({ ok: false, code: "attachment.type_refused" })
  })

  it("refuses sizes over the class cap, bad hashes and bad names", () => {
    expect(validateAttachmentMeta(meta({ byte_count: ATTACHMENT_LIMITS.maxBytes + 1 }))).toMatchObject({ ok: false, code: "attachment.too_large" })
    expect(validateAttachmentMeta(meta({ mime_type: "video/mp4", name: "v.mp4", byte_count: ATTACHMENT_LIMITS.maxBytes + 1 }))).toMatchObject({ ok: false, code: "attachment.too_large" })
    expect(validateAttachmentMeta(meta({ byte_count: 0 }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ sha256: "A".repeat(64) }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ name: "../etc/passwd" }))).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(validateAttachmentMeta(meta({ name: "a\u0000.png" }))).toMatchObject({ ok: false, code: "validation.invalid" })
  })
})

describe("attachment quota (per user: 2 GB and 300 intents per day, 10 GB stored)", () => {
  const now = Date.UTC(2026, 9, 3)
  const empty = { bytes: [], intents: [], stored: 0 }
  it("admits until the daily byte cap, then answers when to retry", () => {
    const day = ATTACHMENT_LIMITS.quota.dayBytes
    expect(day).toBe(2_000_000_000)
    expect(attachmentQuota(empty, day, now)).toEqual({ ok: true })
    const used = { ...empty, bytes: [{ bytes: day - 10, at: now - 3_600_000 }] }
    expect(attachmentQuota(used, 10, now)).toEqual({ ok: true })
    const refused = attachmentQuota(used, 11, now)
    expect(refused).toMatchObject({ ok: false, code: "attachment.quota", window: "day_bytes" })
    expect(refused.ok === false && refused.retry_after_ms).toBe(23 * 3_600_000)
    // Every slot is charged, also a repeated intent for the same hash (refunds happen on "exists" or expiry).
  })
  it("caps intents per day at 300", () => {
    const intents = Array.from({ length: 300 }, (_, i) => now - i * 1000)
    expect(ATTACHMENT_LIMITS.quota.dayIntents).toBe(300)
    expect(attachmentQuota({ ...empty, intents: intents.slice(1) }, 1, now)).toEqual({ ok: true })
    expect(attachmentQuota({ ...empty, intents }, 1, now)).toMatchObject({ ok: false, code: "attachment.quota", window: "day_intents" })
  })
  it("caps stored bytes per uploader at 10 GB", () => {
    expect(ATTACHMENT_LIMITS.quota.storedBytes).toBe(10_000_000_000)
    expect(attachmentQuota({ ...empty, stored: 10_000_000_000 - 5 }, 5, now)).toEqual({ ok: true })
    expect(attachmentQuota({ ...empty, stored: 10_000_000_000 - 5 }, 6, now)).toMatchObject({ ok: false, code: "attachment.storage_quota", window: "stored" })
  })
})

describe("message.send with attachment parts (the owner checks the hash)", () => {
  const records = new Map<string, AttachmentRecord>()
  const record = (hash: string, mime_type = "image/png", byte_count = 1000): AttachmentRecord => ({ hash, object_id: hash.slice(0, 32), object_key: `home/v1/conv_GROUP/${hash.slice(0, 32)}`, mime_type, byte_count, uploaders: [ALICE], quota_user: ALICE, created_at: 0 })
  records.set(HASH, record(HASH))
  records.set(POSTER, record(POSTER, "image/jpeg", 50))
  const asked: Array<[string, string, number]> = []
  // As the DO answers: only for an uploader (here Alice) or a hash referenced above the actor's floor.
  const domain = makeConversationDomain({
    participantPolicy: (_p, participant) => ({ ok: true, display_name: participant.display_name }),
    attachmentFor: (hash, actor, floor) => {
      asked.push([hash, actor, floor])
      const rec = records.get(hash)
      return rec && rec.uploaders.includes(actor) ? rec : undefined
    }
  })
  const part = (over: Record<string, unknown> = {}) => ({ type: "attachment", hash: HASH, name: "photo.png", mime_type: "image/png", byte_count: 1000, width: 10, height: 20, ...over })
  const group = () => {
    const host = new DomainHost<ConversationState, ConversationParams>(domain)
    expect(host.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_GROUP", kind: "group", title: "T", participants: [human(ALICE, "Alice"), human(BOB, "Bob")] }, "c").ok).toBe(true)
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

  it("the owner's lookup is bound to the author: another member's unsent upload is unknown to Bob, with the same code", () => {
    const host = group()
    asked.length = 0
    const bob = host.run(session(BOB, "Bob"), "message.send", { client_msg_id: "b1", parts: [part()] }, "b1")
    expect(bob).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(asked[0]).toEqual([HASH, BOB, 0])
    expect(send(host, [part()], "a1").ok).toBe(true)
  })

  it("the lookup gets the author's since_join floor", () => {
    const host = group()
    expect(host.run(session(ALICE, "Alice"), "conversation.settings.set", { history_visible: "since_join" }, "s").ok).toBe(true)
    expect(send(host, [text("one")], "t1").ok).toBe(true)
    expect(host.run(session(ALICE, "Alice"), "participants.add", { participant: human(CAROL, "Carol") }, "add").ok).toBe(true)
    asked.length = 0
    host.run(session(CAROL, "Carol"), "message.send", { client_msg_id: "c1", parts: [part()] }, "c1")
    expect(asked[0]).toEqual([HASH, CAROL, 1])
  })

  it("retention deletes of a message also delete its reference rows", () => {
    const host = group()
    const sent = send(host, [part(), part({ hash: POSTER, mime_type: "image/jpeg", byte_count: 50 })], "m1")
    const id = (sent.ok && (sent.value as { message_id: string }).message_id) as string
    const message = host.rows.get<{ id: string; author: string; client_msg_id: string; parts: Array<unknown> }>("msg", id)!.row
    const writes = messageDeleteWrites(message as never)
    expect(writes).toEqual(
      expect.arrayContaining([
        { table: "msg", op: "delete", key: id },
        { table: "msgkey", op: "delete", key: `${ALICE}:m1` },
        { table: TABLE_ATTREF, op: "delete", key: `${HASH}:${id}` },
        { table: TABLE_ATTREF, op: "delete", key: `${POSTER}:${id}` }
      ])
    )
  })

  it("the inbox preview of an attachment message is empty text plus {kind, count}", () => {
    const host = group()
    host.outbox.length = 0
    expect(send(host, [part(), part({ hash: POSTER, mime_type: "image/jpeg", byte_count: 50 })], "m1").ok).toBe(true)
    const bump = host.outbox.find((o) => o.kind === "inbox.bump")!.payload as { preview: string; preview_attachments?: unknown }
    expect(bump.preview).toBe("")
    expect(bump.preview_attachments).toEqual({ kind: "photo", count: 2 })
    expect(previewAttachmentsOf({ parts: [text("hi")] } as never)).toBeUndefined()
    expect(previewAttachmentsOf({ parts: [part({ mime_type: "video/mp4" }), part({ mime_type: "application/pdf" })] } as never)).toEqual({ kind: "file", count: 2 })
    expect(previewAttachmentsOf({ parts: [part({ mime_type: "audio/mpeg" })] } as never)).toEqual({ kind: "audio", count: 1 })
  })

  it("the inbox keeps preview_attachments from the newest bump and drops it when a newer bump has none", () => {
    const base = { conversation: "conv_X", kind: "group" as const, title: "T", last_seq: 1, last_at: "2026-10-03T00:00:00.000Z", preview: "" }
    const withFiles = { ...base, rev: 2, preview_attachments: { kind: "video", count: 1 } }
    expect(validBump(withFiles)).toBe(true)
    expect(validBump({ ...withFiles, preview_attachments: { kind: "exe", count: 1 } })).toBe(false)
    const entry = bumpEntry(undefined, withFiles as never)
    expect(entry.preview_attachments).toEqual({ kind: "video", count: 1 })
    const later = bumpEntry(entry, { ...base, rev: 3, last_seq: 2, preview: "Bob: hi" } as never)
    expect(later.preview_attachments).toBeUndefined()
  })

  it("a local head (Rust parity) has no attachment parts", () => {
    const core = new CoreHost()
    const r = core.run("user_local", "k1", { kind: "message.send", client_msg_id: "k1", parts: [part()] as never })
    expect(r).toMatchObject({ ok: false, code: "invalid_parts" })
  })
})
