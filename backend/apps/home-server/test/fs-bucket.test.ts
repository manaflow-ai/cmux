import { describe, expect, it } from "bun:test"
import { existsSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FsBucket, FsBucketError } from "../src/fs-bucket.ts"

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

  it("completes only from a parts list in ascending order, without duplicates, of parts it stored with their etags", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const upload = await bucket.createMultipartUpload("home/v1/ordered")
      const one = await upload.uploadPart(1, "one,")
      const two = await upload.uploadPart(2, "two,")
      const three = await upload.uploadPart(3, "three")
      const wrongEtag = "0".repeat(32)
      const refused: Array<[Array<{ partNumber: number; etag: string }>, RegExp]> = [
        [[], /InvalidPart/],
        [[two, one, three], /InvalidPartOrder/],
        [[one, one, two, three], /InvalidPartOrder/],
        [[one, three, two], /InvalidPartOrder/],
        [[one, two, three, { partNumber: 4, etag: three.etag }], /InvalidPart/],
        [[one, { partNumber: 2, etag: wrongEtag }, three], /InvalidPart/],
        [[one, { partNumber: 2, etag: three.etag }, three], /InvalidPart/],
        [[{ partNumber: 0, etag: one.etag }, two, three], /InvalidPart/],
        [[{ partNumber: 1.5, etag: one.etag }, two, three], /InvalidPart/],
        [[one, two, { partNumber: "3/../../escape" as unknown as number, etag: three.etag }], /InvalidPart/]
      ]
      for (const [parts, error] of refused) {
        await expect(upload.complete(parts)).rejects.toThrow(error)
        // A refused completion writes no object and leaves the upload open.
        expect(await bucket.head("home/v1/ordered")).toBeNull()
      }
      // Nor any half-assembled file beside where the object would go.
      const outputDir = join(root, "home", "v1")
      expect(readdirSync(root).filter((name) => name !== ".multipart" && name !== "home")).toEqual([])
      expect(existsSync(outputDir) ? readdirSync(outputDir) : []).toEqual([])

      // Quoted etags, as an HTTP client echoes them, match the stored part.
      const done = await upload.complete([one, { partNumber: 2, etag: `"${two.etag}"` }, three])
      expect(done.size).toBe("one,two,three".length)
      expect(await new Response((await bucket.get("home/v1/ordered"))!.body!).text()).toBe("one,two,three")
      expect(readdirSync(join(root, ".multipart"))).toEqual([])

      // A completion may leave out parts that were stored, as R2 allows; the rest are discarded.
      const gaps = await bucket.createMultipartUpload("home/v1/gaps")
      const a = await gaps.uploadPart(1, "a")
      await gaps.uploadPart(2, "dropped")
      const c = await gaps.uploadPart(5, "c")
      await gaps.complete([a, c])
      expect(await new Response((await bucket.get("home/v1/gaps"))!.body!).text()).toBe("ac")
      expect(readdirSync(join(root, ".multipart"))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("answers NoSuchUpload for an unknown upload before it checks the part number, and InvalidPart for a real upload", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const mine = await bucket.createMultipartUpload("home/v1/mine")
      const theirs = await bucket.createMultipartUpload("home/v1/theirs")
      const closed = await bucket.createMultipartUpload("home/v1/closed")
      await closed.abort()
      const unknown = [
        bucket.resumeMultipartUpload("home/v1/mine", "0".repeat(32)),
        bucket.resumeMultipartUpload("home/v1/mine", theirs.uploadId),
        bucket.resumeMultipartUpload("home/v1/closed", closed.uploadId)
      ]
      const badNumbers = [0, 10_001, 1.5, -1, Number.NaN, "1" as unknown as number]
      // The upload id and key are checked first: an upload that does not exist for this key is
      // NoSuchUpload whatever part number it names, so a caller can't tell a bad number from a bad id.
      for (const upload of unknown) {
        for (const number of [...badNumbers, 1]) {
          const error = await upload.uploadPart(number, "x").catch((e: unknown) => e)
          expect(error).toBeInstanceOf(FsBucketError)
          expect((error as FsBucketError).code).toBe("NoSuchUpload")
        }
      }
      // A real upload names a bad part number as InvalidPart, and writes nothing for it.
      for (const number of badNumbers) {
        const error = await mine.uploadPart(number, "x").catch((e: unknown) => e)
        expect(error).toBeInstanceOf(FsBucketError)
        expect((error as FsBucketError).code).toBe("InvalidPart")
      }
      const part = await mine.uploadPart(1, "kept")
      await mine.complete([part])
      expect(await new Response((await bucket.get("home/v1/mine"))!.body!).text()).toBe("kept")
      await theirs.abort()
      expect(readdirSync(join(root, ".multipart"))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("lists only stored objects and never walks the internal .multipart directory", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      await bucket.put("home/v1/a", "a")
      // A key may still use .multipart as an inner path segment; only the bucket's own top-level directory is internal.
      await bucket.put("home/v1/.multipart/b", "b")
      const open = await bucket.createMultipartUpload("home/v1/big")
      for (let n = 1; n <= 300; n++) await open.uploadPart(n, "x")
      // Entries under .multipart that list would trip over if it walked in: one that looks like
      // a stored object, and a dangling link that stat refuses. Skipping the directory sees neither.
      writeFileSync(join(root, ".multipart", "stray"), "s")
      writeFileSync(join(root, ".multipart", "stray.meta.json"), JSON.stringify({ etag: "e", size: 1, uploaded: 0 }))
      symlinkSync(join(root, "missing"), join(root, ".multipart", "dangling"))

      expect((await bucket.list()).objects.map((o) => o.key)).toEqual(["home/v1/.multipart/b", "home/v1/a"])
      expect((await bucket.list({ prefix: "home/" })).objects.map((o) => o.key)).toEqual(["home/v1/.multipart/b", "home/v1/a"])
      expect((await bucket.list({ prefix: ".multipart/" })).objects).toEqual([])

      // The internal directory is not addressable as a key, so no caller can read, write or forge an upload record there.
      for (const key of [".multipart", ".multipart/stray", `.multipart/${open.uploadId}.json`]) {
        await expect(bucket.put(key, "{}")).rejects.toThrow(/invalid object key/)
        await expect(bucket.get(key)).rejects.toThrow(/invalid object key/)
        await expect(bucket.createMultipartUpload(key)).rejects.toThrow(/invalid object key/)
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("keeps each open upload's parts in its own directory, so closing one never scans another's parts", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const first = await bucket.createMultipartUpload("home/v1/first")
      const second = await bucket.createMultipartUpload("home/v1/second")
      const parts = []
      for (let n = 1; n <= 50; n++) {
        parts.push(await first.uploadPart(n, "f"))
        await second.uploadPart(n, "s")
      }
      // The shared directory grows with open uploads (a record and a parts directory each), not with their parts.
      expect(readdirSync(join(root, ".multipart")).sort()).toEqual([first.uploadId, `${first.uploadId}.json`, second.uploadId, `${second.uploadId}.json`].sort())
      await first.complete(parts)
      expect(await new Response((await bucket.get("home/v1/first"))!.body!).text()).toBe("f".repeat(50))
      expect(readdirSync(join(root, ".multipart")).sort()).toEqual([second.uploadId, `${second.uploadId}.json`].sort())
      expect(readdirSync(join(root, ".multipart", second.uploadId))).toHaveLength(100)
      await second.abort()
      expect(readdirSync(join(root, ".multipart"))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("keeps an upload's custom metadata on the object it completes, as R2 does, so a caller can recognise its own completed upload", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const upload = await bucket.createMultipartUpload("home/v1/tagged", { httpMetadata: { contentType: "video/mp4" }, customMetadata: { sha256: "ab".repeat(32) } })
      await upload.complete([await upload.uploadPart(1, "tagged bytes")])
      const head = await bucket.head("home/v1/tagged")
      expect([head?.size, head?.httpMetadata.contentType, head?.customMetadata]).toEqual([12, "video/mp4", { sha256: "ab".repeat(32) }])
      expect((await bucket.list({ prefix: "home/v1/" })).objects[0]?.customMetadata).toEqual({ sha256: "ab".repeat(32) })
      // A put keeps its own custom metadata too; an object stored without any answers an empty map.
      await bucket.put("home/v1/plain", "x", { customMetadata: { from: "put" } })
      await bucket.put("home/v1/bare", "y")
      expect([(await bucket.head("home/v1/plain"))?.customMetadata, (await bucket.head("home/v1/bare"))?.customMetadata]).toEqual([{ from: "put" }, {}])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
