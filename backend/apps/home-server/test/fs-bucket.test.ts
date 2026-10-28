import { describe, expect, it } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FsBucket } from "../src/fs-bucket.ts"

describe("self-hosted attachment bucket", () => {
  it("keeps an accepted part when a concurrent replacement fails", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-race-"))
    try {
      const bucket = new FsBucket(root)
      const upload = await bucket.createMultipartUpload("home/v1/race")
      const failing = new ReadableStream<Uint8Array>({
        async start(controller) {
          await new Promise((resolve) => setTimeout(resolve, 10))
          controller.error(new Error("failed attempt"))
        }
      })
      const [failed, accepted] = await Promise.allSettled([
        upload.uploadPart(1, failing),
        upload.uploadPart(1, new Uint8Array([7, 8, 9]))
      ])
      expect(failed.status).toBe("rejected")
      expect(accepted.status).toBe("fulfilled")
      await expect(upload.complete([accepted.status === "fulfilled" ? accepted.value : { partNumber: 1, etag: "" }])).resolves.toMatchObject({ size: 3 })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

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
})
