import { describe, expect, it } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FsBucket } from "../src/fs-bucket.ts"

describe("self-hosted attachment bucket", () => {
  it("supports an atomic conditional write and resumable multipart objects", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const writes = await Promise.all([
        bucket.put("home/v1/race.part", new Uint8Array([1]), { onlyIf: { etagDoesNotMatch: "*" } }),
        bucket.put("home/v1/race.part", new Uint8Array([2]), { onlyIf: { etagDoesNotMatch: "*" } })
      ])
      expect(writes.filter(Boolean)).toHaveLength(1)
      expect(writes.filter((write) => write === null)).toHaveLength(1)

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
