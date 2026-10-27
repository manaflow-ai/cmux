import { describe, expect, it } from "vitest"
import { attachmentQuota, cleanAttachmentPart, validateAttachmentMeta } from "../src/conversation/index.ts"

/**
 * Any file attaches (Lawrence 2026-10-20, "“index.html” can't be attached ... need to fix this"):
 * clients send UTF-8 text as text/plain whatever its name, and other bytes as
 * application/octet-stream; the owner takes both under any valid name. Downloads stay inert
 * (attachment disposition, nosniff, a sandbox CSP), so a name no longer decides.
 */
const meta = (name: string, mime_type: string) => ({ sha256: "a".repeat(64), byte_count: 1_234, mime_type, name })

describe("attachments: any file", () => {
  it.each(["index.html", "run.sh", "app.js", "logo.svg", "setup.exe", "Makefile", ".zshrc"])("takes %s as text", (name) => {
    const result = validateAttachmentMeta(meta(name, "text/plain"))
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.class).toBe("file")
  })

  it.each(["state.sqlite", "blob", "firmware.bin", "Setup.dmg"])("takes %s as a generic file", (name) => {
    const result = validateAttachmentMeta(meta(name, "application/octet-stream"))
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.class).toBe("file")
  })

  it("keeps a message part of either kind", () => {
    const part = { type: "attachment", hash: "b".repeat(64), name: "index.html", mime_type: "text/plain", byte_count: 10 }
    expect(cleanAttachmentPart(part)).not.toBeNull()
    expect(cleanAttachmentPart({ ...part, name: "a.out", mime_type: "application/octet-stream" })).not.toBeNull()
  })

  it("still refuses an SVG or HTML type, which a client never sends", () => {
    expect(validateAttachmentMeta(meta("x.svg", "image/svg+xml")).ok).toBe(false)
    expect(validateAttachmentMeta(meta("index.html", "text/html")).ok).toBe(false)
  })

  it("admits large originals while preserving the intent rate limit", () => {
    const now = 100_000_000
    const usage = { intents: [], bytes: [{ at: now, bytes: 20_000_000_000 }], stored: 20_000_000_000 }
    expect(attachmentQuota(usage, 20_000_000_000, now)).toEqual({ ok: true })
    expect(validateAttachmentMeta({ ...meta("large.bin", "application/octet-stream"), byte_count: 20_000_000_000 }).ok).toBe(true)
    expect(attachmentQuota({ ...usage, intents: Array(300).fill(now) }, 1, now)).toMatchObject({ ok: false, window: "day_intents" })
  })

})
