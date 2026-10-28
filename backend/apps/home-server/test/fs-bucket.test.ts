import { describe, expect, it } from "bun:test"
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FsBucket } from "../src/fs-bucket.ts"

describe("self-hosted attachment bucket", () => {
  it("streams resumable multipart objects and keeps listing cursors valid across deletes", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const upload = await bucket.createMultipartUpload("home/v1/original", { httpMetadata: { contentType: "application/octet-stream" } })
      const first = await upload.uploadPart(1, new Blob([new Uint8Array([1, 2, 3])]).stream())
      const second = await upload.uploadPart(2, new Blob([new Uint8Array([4, 5])]).stream())
      const complete = await upload.complete([first, second])
      expect(complete.size).toBe(5)
      expect(complete.httpMetadata.contentType).toBe("application/octet-stream")
      const stored = await bucket.get("home/v1/original")
      expect(stored?.body).toBeDefined()
      expect(new Uint8Array(await new Response(stored!.body!).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4, 5]))
      await expect(bucket.resumeMultipartUpload(upload.key, upload.uploadId).abort()).resolves.toBeUndefined()
      // R2 numbers parts 1 to 10,000.
      const more = await bucket.createMultipartUpload("home/v1/numbers")
      for (const number of [0, 10_001, 1.5, -1]) await expect(more.uploadPart(number, "x")).rejects.toThrow()
      await expect(more.uploadPart(10_000, "x")).resolves.toMatchObject({ partNumber: 10_000 })

      await bucket.put("pieces/a", "a")
      await bucket.put("pieces/b", "b")
      await bucket.put("pieces/c", "c")
      const page = await bucket.list({ prefix: "pieces/", limit: 2 })
      expect(page.truncated).toBe(true)
      await bucket.delete(page.objects.map((object) => object.key))
      expect((await bucket.list({ prefix: "pieces/", cursor: page.cursor })).objects.map((object) => object.key)).toEqual(["pieces/c"])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it("refuses a resumed upload whose id is forged, path-like or minted for another object", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const mine = await bucket.createMultipartUpload("home/v1/mine")
      const theirs = await bucket.createMultipartUpload("home/v1/theirs")
      const kept = await theirs.uploadPart(1, "theirs")
      expect(mine.uploadId).toMatch(/^[0-9a-f]{32}$/)

      // An id the bucket never minted, or one shaped like a path, is refused before any file is touched.
      for (const forged of ["", "../escape", "a/b", `${mine.uploadId}/x`, `${mine.uploadId}.part.1`, mine.uploadId.toUpperCase(), "0".repeat(31)]) {
        expect(() => bucket.resumeMultipartUpload("home/v1/mine", forged)).toThrow(/NoSuchUpload/)
      }
      const unminted = bucket.resumeMultipartUpload("home/v1/mine", "0".repeat(32))
      await expect(unminted.uploadPart(1, "x")).rejects.toThrow(/NoSuchUpload/)
      await expect(unminted.complete([{ partNumber: 1, etag: kept.etag }])).rejects.toThrow(/NoSuchUpload/)

      // Another object's upload id, resumed under this key, can't write, assemble or abort it.
      const crossed = bucket.resumeMultipartUpload("home/v1/mine", theirs.uploadId)
      await expect(crossed.uploadPart(1, "overwritten")).rejects.toThrow(/NoSuchUpload/)
      await expect(crossed.complete([kept])).rejects.toThrow(/NoSuchUpload/)
      await expect(crossed.abort()).rejects.toThrow(/NoSuchUpload/)
      expect(await bucket.head("home/v1/mine")).toBeNull()
      expect(await bucket.head("home/v1/theirs")).toBeNull()

      // The real owner still finishes its upload with its own bytes.
      const done = await bucket.resumeMultipartUpload("home/v1/theirs", theirs.uploadId).complete([kept])
      expect(done.key).toBe("home/v1/theirs")
      expect(await new Response((await bucket.get("home/v1/theirs"))!.body!).text()).toBe("theirs")
      await mine.abort()
      expect(readdirSync(join(root, ".multipart"))).toEqual([])
      expect(existsSync(join(root, "escape"))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
