import { describe, expect, it } from "vitest"
import { attachmentHashes, checkAttachments, type AttachmentRecord } from "../src/conversation/attachments.ts"
import { cardText, cleanCardPart } from "../src/conversation/card.ts"
import { attachmentHeldBy } from "../src/conversation/link-preview.ts"
import { messageText } from "../src/conversation/search.ts"
import type { Message, Part } from "../src/conversation/types.ts"
import { validateParts } from "../src/conversation/validate.ts"

/** card parts (https://github.com/manaflow-ai/cmux/issues/25830); the shape cases live in the conformance corpus. */
const shot = { hash: "e".repeat(64), mime_type: "image/png", byte_count: 123_456, width: 1280, height: 800 }
const browser = { type: "card", kind: "browser", surface: "browser", step: "Returning to LinkedIn Messaging", live: true, image: shot } as const

describe("card parts", () => {
  it("keeps only known fields and fills live", () => {
    const [part] = validateParts([{ ...browser, live: undefined, extra: 1, image: { ...shot, extra: 2 } }], true)
    expect(part).toEqual({ type: "card", kind: "browser", surface: "browser", step: browser.step, live: false, image: shot })
  })

  it("refuses an unknown kind and a bad shape", () => {
    expect(() => validateParts([{ type: "card", kind: "map" }], true)).toThrow()
    expect(cleanCardPart({ type: "card", kind: "next_steps", choices: ["a", "b", "c", "d"] })).toBeNull()
    expect(cleanCardPart({ type: "card", kind: "sign_in", site: "localhost" })).toBeNull()
    expect(cleanCardPart({ type: "card", kind: "browser", surface: "browser", step: "x", target: "machine:" })).toBeNull()
  })

  it("checks a browser card's screenshot against the conversation's attachment record", () => {
    const parts = validateParts([browser], true)
    expect([...attachmentHashes(parts)]).toEqual([shot.hash])
    const record = { hash: shot.hash, object_id: "o", object_key: "k", mime_type: "image/png", byte_count: shot.byte_count, uploaders: ["agent_mux"] } as unknown as AttachmentRecord
    expect(checkAttachments(parts, () => undefined, "agent_mux", 0)).toBe("unknown_attachment")
    expect(checkAttachments(parts, () => ({ ...record, byte_count: 1 }), "agent_mux", 0)).toBe("attachment_mismatch")
    expect(checkAttachments(parts, () => ({ ...record, mime_type: "image/jpeg" }), "agent_mux", 0)).toBe("attachment_mismatch")
    expect(checkAttachments(parts, () => record, "agent_mux", 0)).toBeNull()
  })

  it("serves the screenshot as an attachment of its part", () => {
    const [part] = validateParts([browser], true)
    expect(attachmentHeldBy(part, shot.hash)).toEqual({ type: "attachment", hash: shot.hash, name: "browser-card.png", mime_type: "image/png", byte_count: shot.byte_count, width: 1280, height: 800 })
    expect(attachmentHeldBy(part, "f".repeat(64))).toBeUndefined()
  })

  it("has a text fallback and searchable text", () => {
    const parts = validateParts(
      [
        { ...browser, surface: "computer" },
        { type: "card", kind: "sign_in", site: "linkedin.com" },
        { type: "card", kind: "next_steps", choices: ["Retry", "Stop"] }
      ],
      true
    ) as ReadonlyArray<Extract<Part, { type: "card" }>>
    expect(parts.map(cardText)).toEqual(["Computer: Returning to LinkedIn Messaging", "Secure Store: sign in to linkedin.com", "→ Retry\n→ Stop"])
    expect(messageText({ parts } as unknown as Message)).toBe("Returning to LinkedIn Messaging linkedin.com Retry Stop")
  })
})
