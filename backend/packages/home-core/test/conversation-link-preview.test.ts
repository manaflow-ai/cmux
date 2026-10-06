import { describe, expect, it } from "vitest"
import {
  attachmentHashes,
  makeConversationDomain,
  messageText,
  TABLE_ATTREF,
  validLinkUrl,
  type AttachmentRecord,
  type ConversationParams,
  type ConversationState,
  type Principal
} from "../src/conversation/index.ts"
import { CoreHost, DomainHost, human, text } from "./support/harness.ts"
import { ALICE, BOB } from "./support/cloud.ts"

/**
 * `link_preview` parts (iMessage-style sender-side previews): the same shape rules as the Rust
 * crate (cmux-conversation link_preview.rs); on a cloud head the image is checked against the
 * conversation's attachment records like an attachment part's hash.
 */
const session = (user: string, name: string): Principal => ({ identity: `${user}:s`, user, kind: "session", display_name: name })
const IMAGE = "f".repeat(64)
const preview = (over: Record<string, unknown> = {}) => {
  const part: Record<string, unknown> = { type: "link_preview", url: "https://example.com/a?b=c#d", title: "Example", site: "example.com", image: { hash: IMAGE, mime_type: "image/jpeg", byte_count: 512_000 }, ...over }
  for (const key of Object.keys(part)) if (part[key] === undefined) delete part[key]
  return part
}

const BAD: ReadonlyArray<Record<string, unknown>> = [
  { url: "" },
  { url: `https://example.com/${"a".repeat(2048 - 19)}` },
  { url: "ftp://example.com" },
  { url: "javascript:alert(1)" },
  { url: "file:///etc/passwd" },
  { url: "example.com" },
  { url: "https://" },
  { url: "https:///path" },
  { url: "https://exa mple.com" },
  { url: "https://example.com/\n" },
  { url: "https://user@example.com" },
  { url: "https:\\\\example.com" },
  { url: 42 },
  { title: "" },
  { title: "x".repeat(301) },
  { title: "a\u0007b" },
  { site: "" },
  { site: "s".repeat(254) },
  { site: "a\nb" },
  { image: { hash: "ABC", mime_type: "image/jpeg", byte_count: 10 } },
  { image: { hash: IMAGE, mime_type: "image/png", byte_count: 10 } },
  { image: { hash: IMAGE, mime_type: "image/jpeg", byte_count: 0 } },
  { image: { hash: IMAGE, mime_type: "image/jpeg", byte_count: 512_001 } }
]

describe("link_preview parts on a local head (the Rust crate's rules)", () => {
  const send = (part: unknown) => new CoreHost().run("user_local", "k", { kind: "message.send", client_msg_id: "k", parts: [part] as never })

  it("accepts a well-formed preview and returns only its known fields", () => {
    const part = preview({ extra: true })
    const sent = send(part)
    expect(sent.ok).toBe(true)
    const { extra: _extra, ...known } = part
    expect(sent.ok && sent.commit.message?.parts[0]).toEqual(known)
    const bare = { type: "link_preview", url: "http://example.com" }
    const bareSent = send(bare)
    expect(bareSent.ok && bareSent.commit.message?.parts[0]).toEqual(bare)
    expect(send(preview({ image: { hash: IMAGE, mime_type: "image/webp", byte_count: 1 } })).ok).toBe(true)
    expect(send(preview({ title: "é".repeat(300), site: "s".repeat(253) })).ok).toBe(true)
    const longest = `https://example.com/${"a".repeat(2048 - 20)}`
    expect(longest.length).toBe(2048)
    expect(send(preview({ url: longest })).ok).toBe(true)
    expect(send(preview({ url: "HTTPS://Example.com" })).ok).toBe(true)
  })

  it("refuses bad URLs, text and images with invalid_parts", () => {
    for (const over of BAD) expect(send(preview(over)), JSON.stringify(over)).toMatchObject({ ok: false, code: "invalid_parts" })
  })

  it("validLinkUrl counts UTF-8 bytes, as the Rust rule does", () => {
    expect(validLinkUrl(`https://example.com/${"é".repeat(1014)}`)).toBe(true)
    expect(validLinkUrl(`https://example.com/${"é".repeat(1015)}`)).toBe(false)
  })

  it("search text includes the title", () => {
    const sent = send(preview())
    expect(sent.ok && messageText(sent.commit.message!)).toBe("Example")
  })
})

describe("link_preview parts on a cloud head (the image is an attachment record)", () => {
  const record = (hash: string, mime_type: string, byte_count: number): AttachmentRecord => ({ hash, object_id: hash.slice(0, 32), object_key: `home/v1/conv_GROUP/${hash.slice(0, 32)}`, mime_type, byte_count, uploaders: [ALICE], quota_user: ALICE, created_at: 0 })
  const records = new Map<string, AttachmentRecord>([[IMAGE, record(IMAGE, "image/jpeg", 2000)]])
  const domain = makeConversationDomain({
    participantPolicy: (_p, participant) => ({ ok: true, display_name: participant.display_name }),
    attachmentFor: (hash, actor) => {
      const rec = records.get(hash)
      return rec && rec.uploaders.includes(actor) ? rec : undefined
    }
  })
  const group = () => {
    const host = new DomainHost<ConversationState, ConversationParams>(domain)
    expect(host.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_GROUP", kind: "group", title: "T", participants: [human(ALICE, "Alice"), human(BOB, "Bob")] }, "c").ok).toBe(true)
    return host
  }
  const send = (host: DomainHost<ConversationState, ConversationParams>, user: string, parts: unknown, key: string) => host.run(session(user, user), "message.send", { client_msg_id: key, parts }, key)
  const image = (mime_type: string, byte_count: number) => ({ hash: IMAGE, mime_type, byte_count })

  it("commits a preview whose image matches a record the author may use, and records the reference", () => {
    const host = group()
    expect(send(host, BOB, [preview({ image: image("image/jpeg", 2000) })], "b1")).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(send(host, ALICE, [preview({ image: { ...image("image/jpeg", 2000), hash: "e".repeat(64) } })], "a0")).toMatchObject({ ok: false, code: "unknown_attachment" })
    expect(send(host, ALICE, [preview({ image: image("image/webp", 2000) })], "a1")).toMatchObject({ ok: false, code: "attachment_mismatch" })
    expect(send(host, ALICE, [preview({ image: image("image/jpeg", 2001) })], "a2")).toMatchObject({ ok: false, code: "attachment_mismatch" })
    const sent = send(host, ALICE, [text("look"), preview({ image: image("image/jpeg", 2000) })], "a3")
    expect(sent.ok).toBe(true)
    const id = (sent.ok && (sent.value as { message_id: string }).message_id) as string
    expect(host.rows.get(TABLE_ATTREF, `${IMAGE}:${id}`)?.row).toMatchObject({ hash: IMAGE, message_id: id })
    expect(send(host, ALICE, [preview({ image: undefined })], "a4").ok).toBe(true)
    BAD.forEach((over, index) => expect(send(host, ALICE, [preview(over)], `bad-${index}`), JSON.stringify(over)).toMatchObject({ ok: false, code: "invalid_parts" }))
  })

  it("attachmentHashes counts a preview image as referenced", () => {
    expect([...attachmentHashes([preview() as never, { type: "text", text: "x" }])]).toEqual([IMAGE])
  })
})
