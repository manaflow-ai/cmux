import { createHash } from "node:crypto"
import { describe, expect, it } from "vitest"
import { ResumableSha256 } from "../src/home-attachment-stream.ts"

const PIECE = 4096
const bytes = new Uint8Array(3 * PIECE + 77).map((_, i) => (i * 31 + 7) % 256)
const expected = (b: Uint8Array) => createHash("sha256").update(b).digest("hex")

describe("Home attachments: SHA-256 carried between multipart pieces", () => {
  it("matches node:crypto at every padding boundary", () => {
    for (const size of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000]) {
      const sha = new ResumableSha256(null)
      sha.update(bytes.subarray(0, size))
      expect(sha.digest()).toBe(expected(bytes.subarray(0, size)))
    }
  })

  it("resumes from the state stored after each whole piece, whatever the chunk sizes", () => {
    let state: string | null = null
    for (let start = 0; start < bytes.length; start += PIECE) {
      const sha = new ResumableSha256(state)
      const piece = bytes.subarray(start, Math.min(bytes.length, start + PIECE))
      for (let i = 0; i < piece.length; i += 100) sha.update(piece.subarray(i, i + 100))
      if (start + PIECE < bytes.length) state = sha.state()
      else expect(sha.digest()).toBe(expected(bytes))
    }
    const partial = new ResumableSha256(null)
    partial.update(bytes.subarray(0, 10))
    // Only whole 64-byte blocks carry over: a piece boundary inside a block is refused.
    expect(() => partial.state()).toThrow()
  })
})
