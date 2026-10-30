import { describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FsBucket, FsBucketError } from "../src/fs-bucket.ts"

/** Every file under `dir` with its contents, to show an operation left a directory exactly as it was. */
const snapshot = (dir: string): Record<string, string> =>
  Object.fromEntries(
    readdirSync(dir, { recursive: true, withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => [join(entry.parentPath, entry.name), readFileSync(join(entry.parentPath, entry.name), "utf8")])
  )

/** `dir` becomes a link to `target`; `restore` puts the real directory back. */
const swapForLink = (dir: string, target: string) => {
  renameSync(dir, `${dir}.real`)
  symlinkSync(target, dir)
}
const restore = (dir: string) => {
  rmSync(dir)
  renameSync(`${dir}.real`, dir)
}

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
      expect(() => bucket.resumeMultipartUpload(upload.key, upload.uploadId)).toThrow(/NoSuchUpload/)
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

  it("rejects equal-sized bytes whose content hash does not match the metadata", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      await bucket.put("home/v1/hash", "old bytes")
      // Simulate a crash/torn replacement after data was published but before metadata changed.
      writeFileSync(join(root, "home", "v1", "hash"), "new bytes")
      expect(await bucket.head("home/v1/hash")).toBeNull()
      expect(await bucket.get("home/v1/hash")).toBeNull()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it("reads objects with the pre-contentHash metadata format and cleans orphaned data files", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const data = "legacy bytes"
      const etag = createHash("md5").update(data).digest("hex")
      mkdirSync(join(root, "home", "v1"), { recursive: true })
      writeFileSync(join(root, "home", "v1", "legacy"), data)
      writeFileSync(join(root, "home", "v1", "legacy.meta.json"), JSON.stringify({ etag, size: data.length, uploaded: 0 }))
      expect(await bucket.head("home/v1/legacy")).toMatchObject({ etag, size: data.length })

      // Simulate a crash after the data rename but before metadata publication.
      writeFileSync(join(root, "home", "v1", "orphan"), "orphaned bytes")
      expect((await bucket.list({ prefix: "home/v1/" })).objects.map((object) => object.key)).toContain("home/v1/legacy")
      expect(existsSync(join(root, "home", "v1", "orphan"))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it("refuses a parent-directory symlink swapped after the final directory check", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const root = join(parent, "bucket")
      const outside = join(parent, "outside")
      mkdirSync(outside)
      const keyDir = join(root, "a")
      let checks = 0
      const bucket = new FsBucket(root, {
        afterPathCheck: () => {
          checks += 1
          if (checks === 2) swapForLink(keyDir, outside)
        }
      })
      await expect(bucket.put("a/secret", "inside")).rejects.toThrow(/symbolic link/)
      expect(existsSync(join(outside, "secret"))).toBe(false)
      restore(keyDir)
    } finally {
      rmSync(parent, { recursive: true, force: true })
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
      expect(() => bucket.resumeMultipartUpload("home/v1/mine", "0".repeat(32))).toThrow(/NoSuchUpload/)

      // Another object's upload id, resumed under this key, can't write, assemble or abort it.
      expect(() => bucket.resumeMultipartUpload("home/v1/mine", theirs.uploadId)).toThrow(/NoSuchUpload/)
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

  it("serializes concurrent part replacement and completion with abort", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const upload = await bucket.createMultipartUpload("home/v1/serialized")
      const parts = await Promise.all([upload.uploadPart(1, "first"), upload.uploadPart(1, "second")])
      const winner = parts.at(-1)!
      const [completed, aborted] = await Promise.allSettled([upload.complete([winner]), upload.abort()])
      expect(aborted.status).toBe("fulfilled")
      if (completed.status === "fulfilled") {
        expect(await new Response((await bucket.get("home/v1/serialized"))!.body!).text()).toBe("second")
      } else {
        expect(await bucket.head("home/v1/serialized")).toBeNull()
      }
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
        () => bucket.resumeMultipartUpload("home/v1/mine", "0".repeat(32)),
        () => bucket.resumeMultipartUpload("home/v1/mine", theirs.uploadId),
        () => bucket.resumeMultipartUpload("home/v1/closed", closed.uploadId)
      ]
      const badNumbers = [0, 10_001, 1.5, -1, Number.NaN, "1" as unknown as number]
      // The upload id and key are checked first: an upload that does not exist for this key is
      // NoSuchUpload whatever part number it names, so a caller can't tell a bad number from a bad id.
      for (const resume of unknown) expect(resume).toThrow(/NoSuchUpload/)
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
      // A file no key could have written (a backslash in its name) is skipped, not listed under a key get would refuse.
      writeFileSync(join(root, "home", "v1", "odd\\name"), "o")
      writeFileSync(join(root, "home", "v1", "odd\\name.meta.json"), JSON.stringify({ etag: "e", size: 1, uploaded: 0 }))

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
  it("refuses keys with '.', '..' or empty segments, backslashes or absolute paths, so no key reaches outside the root or into .multipart", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const root = join(parent, "bucket")
      const bucket = new FsBucket(root)
      const open = await bucket.createMultipartUpload("home/v1/open")
      const record = `.multipart/${open.uploadId}.json`
      const refused = [
        `./${record}`,
        "./.multipart/x",
        "a/../.multipart/x",
        "./a",
        "a/./b",
        "a/.",
        "a/..",
        "..",
        ".",
        "",
        "a//b",
        "a/",
        "/a",
        "../outside",
        "a/../../outside",
        `../${"bucket"}/a`,
        join(parent, "outside"),
        "a\\b",
        "..\\outside",
        ".multipart\\x",
        "a\u0000b"
      ]
      for (const key of refused) {
        await expect(bucket.put(key, "{}"), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.get(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.head(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.delete(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.delete(["fine", key]), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.createMultipartUpload(key), key).rejects.toThrow(/invalid object key/)
        expect(() => bucket.resumeMultipartUpload(key, open.uploadId), key).toThrow(/invalid object key/)
      }
      // Nothing landed beside the root, and inside it only the open upload exists.
      expect(readdirSync(parent)).toEqual(["bucket"])
      expect(readdirSync(root)).toEqual([".multipart"])
      expect(readFileSync(join(root, record), "utf8")).toBe(JSON.stringify({ key: "home/v1/open" }))

      // Dots inside a segment, dotfiles and an inner .multipart segment are ordinary keys.
      for (const key of ["home/v1/.multipart/b", ".hidden", "a/.b", "a..b", "...", "a/b..", "v1.2/file.txt"]) {
        await bucket.put(key, key)
        expect(await new Response((await bucket.get(key))!.body!).text()).toBe(key)
        expect((await bucket.head(key))?.key).toBe(key)
        await bucket.delete(key)
        expect(await bucket.head(key)).toBeNull()
      }
      await open.abort()
    } finally {
      rmSync(parent, { recursive: true, force: true })
    }
  })
  it("refuses to overwrite an open upload's record through a key that normalizes into .multipart, so the upload can't be redirected", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const victim = await bucket.createMultipartUpload("home/v1/victim", { httpMetadata: { contentType: "image/png" } })
      const part = await victim.uploadPart(1, "victim bytes")
      const recordPath = join(root, ".multipart", `${victim.uploadId}.json`)
      const original = readFileSync(recordPath, "utf8")

      // The attack: rewrite the record so the upload names another object, then finish it as that object.
      const forged = JSON.stringify({ key: "home/v1/target", contentType: "text/html" })
      for (const key of [`./.multipart/${victim.uploadId}.json`, `a/../.multipart/${victim.uploadId}.json`, `./.multipart/./${victim.uploadId}.json`]) {
        await expect(bucket.put(key, forged), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.delete(key), key).rejects.toThrow(/invalid object key/)
      }
      expect(readFileSync(recordPath, "utf8")).toBe(original)

      expect(() => bucket.resumeMultipartUpload("home/v1/target", victim.uploadId)).toThrow(/NoSuchUpload/)
      expect(await bucket.head("home/v1/target")).toBeNull()
      expect(readFileSync(recordPath, "utf8")).toBe(original)

      // The real upload is untouched and still completes as its own object.
      const done = await bucket.resumeMultipartUpload("home/v1/victim", victim.uploadId).complete([part])
      expect(done.key).toBe("home/v1/victim")
      expect(done.httpMetadata.contentType).toBe("image/png")
      expect(await new Response((await bucket.get("home/v1/victim"))!.body!).text()).toBe("victim bytes")
      expect(await bucket.head("home/v1/target")).toBeNull()
      expect(readdirSync(join(root, ".multipart"))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("never follows a symbolic link out of the bucket: a linked directory, a linked file or a dangling link", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const outside = join(parent, "outside")
      mkdirSync(outside)
      const meta = JSON.stringify({ etag: "e", size: 6, uploaded: 0 })
      writeFileSync(join(outside, "secret"), "secret")
      writeFileSync(join(outside, "secret.meta.json"), meta)
      const before = () => readdirSync(outside).sort()
      const kept = before()
      const root = join(parent, "bucket")
      const bucket = new FsBucket(root)

      // A directory under the root that links outside it: no route reads, writes, creates or deletes through it.
      symlinkSync(outside, join(root, "linked"))
      await expect(bucket.put("linked/new", "x")).rejects.toThrow(/symbolic link/)
      await expect(bucket.put("linked/deep/new", "x")).rejects.toThrow(/symbolic link/)
      await expect(bucket.get("linked/secret")).rejects.toThrow(/symbolic link/)
      await expect(bucket.head("linked/secret")).rejects.toThrow(/symbolic link/)
      await expect(bucket.delete("linked/secret")).rejects.toThrow(/symbolic link/)
      await expect(bucket.createMultipartUpload("linked/up")).rejects.toThrow(/symbolic link/)
      // A link that appears after the upload opened is caught when the upload completes.
      const late = await bucket.createMultipartUpload("later/up")
      const latePart = await late.uploadPart(1, "late")
      symlinkSync(outside, join(root, "later"))
      await expect(late.complete([latePart])).rejects.toThrow(/symbolic link/)
      expect(before()).toEqual(kept)

      // A linked object file or metadata file is not read through.
      symlinkSync(join(outside, "secret"), join(root, "file"))
      writeFileSync(join(root, "file.meta.json"), meta)
      await expect(bucket.get("file")).rejects.toThrow(/symbolic link/)
      await expect(bucket.head("file")).rejects.toThrow(/symbolic link/)
      writeFileSync(join(root, "metalink"), "secret")
      symlinkSync(join(outside, "secret.meta.json"), join(root, "metalink.meta.json"))
      await expect(bucket.head("metalink")).rejects.toThrow(/symbolic link/)
      await expect(bucket.get("metalink")).rejects.toThrow(/symbolic link/)
      // A put over a linked file replaces the link and leaves its target alone.
      await bucket.put("file", "mine")
      expect(lstatSync(join(root, "file")).isSymbolicLink()).toBe(false)
      expect(await new Response((await bucket.get("file"))!.body!).text()).toBe("mine")
      await bucket.put("metalink", "mine too")
      expect(readFileSync(join(outside, "secret"), "utf8")).toBe("secret")
      expect(readFileSync(join(outside, "secret.meta.json"), "utf8")).toBe(meta)

      // An open upload's parts directory, or the .multipart directory itself, linked outside.
      const planted = await bucket.createMultipartUpload("home/v1/planted")
      symlinkSync(outside, join(root, ".multipart", planted.uploadId))
      await expect(planted.uploadPart(1, "x")).rejects.toThrow(/symbolic link/)
      const linkedRoot = join(parent, "linked-multipart")
      mkdirSync(linkedRoot)
      symlinkSync(outside, join(linkedRoot, ".multipart"))
      await expect(new FsBucket(linkedRoot).createMultipartUpload("home/v1/x")).rejects.toThrow(/symbolic link/)
      expect(before()).toEqual(kept)

      // list skips links, dangling or not, and never walks out of the root.
      await bucket.put("home/v1/real", "real")
      symlinkSync(join(parent, "missing"), join(root, "dangling"))
      symlinkSync(join(parent, "missing"), join(root, "home", "v1", "dangling"))
      writeFileSync(join(root, "home", "v1", "dangling.meta.json"), meta)
      symlinkSync(outside, join(root, "home", "v1", "away"))
      expect((await bucket.list()).objects.map((o) => o.key)).toEqual(["file", "home/v1/real", "metalink"])
      await expect(bucket.get("home/v1/dangling")).rejects.toThrow(/symbolic link/)
      expect(before()).toEqual(kept)
    } finally {
      rmSync(parent, { recursive: true, force: true })
    }
  })
  it("accepts a root that is itself a symbolic link, and stores in the directory it names", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const real = join(parent, "real")
      mkdirSync(real)
      symlinkSync(real, join(parent, "root"))
      const bucket = new FsBucket(join(parent, "root"))
      await bucket.put("home/v1/a", "a")
      const upload = await bucket.createMultipartUpload("home/v1/b")
      await upload.complete([await upload.uploadPart(1, "b")])
      expect(await new Response((await bucket.get("home/v1/a"))!.body!).text()).toBe("a")
      expect((await bucket.head("home/v1/b"))?.size).toBe(1)
      expect((await bucket.list()).objects.map((o) => o.key)).toEqual(["home/v1/a", "home/v1/b"])
      expect(readFileSync(join(real, "home", "v1", "b"), "utf8")).toBe("b")
      await bucket.delete(["home/v1/a", "home/v1/b"])
      expect((await bucket.list()).objects).toEqual([])
    } finally {
      rmSync(parent, { recursive: true, force: true })
    }
  })
  it("refuses a list limit outside 1 to 1,000 as R2 does (InvalidMaxKeys), and pages with any limit inside it", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      for (const limit of [0, -1, 1001, 1.5, Number.NaN, "2" as unknown as number]) {
        const error = await bucket.list({ limit }).catch((e: unknown) => e)
        expect(error, String(limit)).toBeInstanceOf(FsBucketError)
        expect((error as FsBucketError).code).toBe("InvalidMaxKeys")
      }
      await bucket.put("a", "a")
      await bucket.put("b", "b")
      for (const limit of [0, -1, 1001]) await expect(bucket.list({ limit })).rejects.toThrow(/InvalidMaxKeys/)
      const first = await bucket.list({ limit: 1 })
      expect(first.objects.map((o) => o.key)).toEqual(["a"])
      expect(first.truncated).toBe(true)
      const second = await bucket.list({ limit: 1, cursor: first.cursor })
      expect(second.objects.map((o) => o.key)).toEqual(["b"])
      expect(second.truncated).toBe(false)
      expect((await bucket.list({ limit: 1000 })).objects).toHaveLength(2)
      expect((await bucket.list()).objects).toHaveLength(2)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("refuses any key whose first segment folds to .multipart, so a case-insensitive disk can't reach an upload record", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const victim = await bucket.createMultipartUpload("home/v1/victim")
      const part = await victim.uploadPart(1, "victim bytes")
      const recordPath = join(root, ".multipart", `${victim.uploadId}.json`)
      const original = readFileSync(recordPath, "utf8")
      const id = victim.uploadId
      // Case (APFS, HFS+ and NTFS ignore it), compatibility forms (fullwidth), ignorable code points
      // (HFS+ drops some) and the trailing dots and spaces Windows strips all name the same directory.
      const folded = [
        `.MULTIPART/${id}.json`,
        `.Multipart/${id}.json`,
        ".Multipart/x",
        ".MULTIPART",
        `\uFF0E\uFF4D\uFF55\uFF4C\uFF54\uFF49\uFF50\uFF41\uFF52\uFF54/${id}.json`,
        `.multi\u200Dpart/${id}.json`,
        `.MULTI\u00ADPART/${id}.json`,
        `.multipart./${id}.json`,
        `.multipart /${id}.json`
      ]
      for (const key of folded) {
        await expect(bucket.put(key, "{}"), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.get(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.head(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.delete(key), key).rejects.toThrow(/invalid object key/)
        await expect(bucket.createMultipartUpload(key), key).rejects.toThrow(/invalid object key/)
        expect(() => bucket.resumeMultipartUpload(key, id), key).toThrow(/invalid object key/)
      }
      expect(readFileSync(recordPath, "utf8")).toBe(original)

      // The attack through an upper-case key: rewrite the record to name another object, then finish it as that object.
      await expect(bucket.put(`.MULTIPART/${id}.json`, JSON.stringify({ key: "home/v1/target" }))).rejects.toThrow(/invalid object key/)
      expect(() => bucket.resumeMultipartUpload("home/v1/target", id)).toThrow(/NoSuchUpload/)
      expect(await bucket.head("home/v1/target")).toBeNull()
      expect(readFileSync(recordPath, "utf8")).toBe(original)
      await bucket.resumeMultipartUpload("home/v1/victim", id).complete([part])
      expect(await new Response((await bucket.get("home/v1/victim"))!.body!).text()).toBe("victim bytes")

      // Only the first segment is reserved, and only when it folds to exactly .multipart.
      for (const key of ["home/v1/.MULTIPART/b", "home/.Multipart", ".multipart-notes/x", "multipart/x", ".multiparts/x"]) {
        await bucket.put(key, key)
        expect(await new Response((await bucket.get(key))!.body!).text()).toBe(key)
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("refuses an operation when a checked directory is swapped for a link before it is used, at every point between check and use", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const outside = join(parent, "outside")
      mkdirSync(outside)
      writeFileSync(join(outside, "secret"), "secret")
      writeFileSync(join(outside, "secret.meta.json"), JSON.stringify({ etag: "e", size: 6, uploaded: 0 }))
      const root = join(parent, "bucket")
      // The test seam runs after the bucket has checked a path's directories and before it uses them.
      let calls = 0
      let swapAt = 0
      let swap: () => void = () => undefined
      const bucket = new FsBucket(root, {
        afterPathCheck: () => {
          calls += 1
          if (calls === swapAt) swap()
        }
      })
      /**
       * Runs `op` once to count its checkpoints, then once per checkpoint with the swap there. The op
       * is refused at every checkpoint, except that one which finished its last use of the swapped
       * directory before the swap (completion, which closes the upload afterwards) may succeed and pass `finished`.
       */
      const atEveryCheckpoint = async (name: string, setup: () => Promise<() => Promise<unknown>>, swapNow: () => void, undo: () => void, finished?: () => Promise<void>) => {
        const dry = await setup()
        calls = 0
        swapAt = 0
        await dry()
        const checkpoints = calls
        expect(checkpoints, `${name}: the check seam ran`).toBeGreaterThan(0)
        for (let at = 1; at <= checkpoints; at++) {
          const op = await setup()
          const before = snapshot(parent)
          let swapped = false
          swap = () => {
            swapped = true
            swapNow()
          }
          calls = 0
          swapAt = at
          const outcome = await op().then(() => null, (error: unknown) => error)
          expect(swapped, `${name} @${at}`).toBe(true)
          swapAt = 0
          undo()
          if (outcome === null && finished) await finished()
          else expect(String(outcome), `${name} @${at}`).toMatch(/symbolic link/)
          // Nothing outside the bucket was read into it, written, created or removed.
          expect(Object.fromEntries(Object.entries(snapshot(parent)).filter(([path]) => !path.startsWith(`${root}/`))), `${name} @${at}`).toEqual(
            Object.fromEntries(Object.entries(before).filter(([path]) => !path.startsWith(`${root}/`)))
          )
        }
      }
      const a = join(root, "a")
      const linkA = () => swapForLink(a, outside)
      const unlinkA = () => restore(a)
      await atEveryCheckpoint("get", async () => {
        await bucket.put("a/secret", "inside")
        return () => bucket.get("a/secret")
      }, linkA, unlinkA)
      await atEveryCheckpoint("head", async () => {
        await bucket.put("a/secret", "inside")
        return () => bucket.head("a/secret")
      }, linkA, unlinkA)
      await atEveryCheckpoint("delete", async () => {
        await bucket.put("a/secret", "inside")
        return () => bucket.delete("a/secret")
      }, linkA, unlinkA)
      await atEveryCheckpoint("put", async () => () => bucket.put("a/secret", "overwrite"), linkA, unlinkA)
      await atEveryCheckpoint("put creating directories", async () => {
        await bucket.put("a/secret", "inside")
        rmSync(join(a, "b"), { recursive: true, force: true })
        return () => bucket.put("a/b/c/new", "new")
      }, linkA, unlinkA)
      await atEveryCheckpoint("complete", async () => {
        await bucket.put("a/secret", "inside")
        const upload = await bucket.createMultipartUpload("a/up")
        const part = await upload.uploadPart(1, "up")
        return () => upload.complete([part])
      }, linkA, unlinkA, async () => {
        expect(await new Response((await bucket.get("a/up"))!.body!).text()).toBe("up")
      })

      // The upload directory itself, swapped for a link to a copy outside the root: its record and parts are not trusted.
      const multipart = join(root, ".multipart")
      const copy = join(parent, "multipart-copy")
      // The copy holds other bytes under the same part etags, so reading anything through it shows.
      const linkMultipart = () => {
        rmSync(copy, { recursive: true, force: true })
        cpSync(multipart, copy, { recursive: true })
        for (const entry of readdirSync(copy, { recursive: true, withFileTypes: true })) {
          if (entry.isFile() && /^part\.\d+$/.test(entry.name)) writeFileSync(join(entry.parentPath, entry.name), "FORGED")
        }
        swapForLink(multipart, copy)
      }
      const unlinkMultipart = () => {
        restore(multipart)
        rmSync(copy, { recursive: true, force: true })
      }
      await atEveryCheckpoint("upload part", async () => {
        const upload = await bucket.createMultipartUpload("home/v1/parts")
        await upload.uploadPart(1, "one")
        return () => upload.uploadPart(2, "two")
      }, linkMultipart, unlinkMultipart)
      await atEveryCheckpoint("complete from .multipart", async () => {
        await bucket.delete("home/v1/assembled")
        const upload = await bucket.createMultipartUpload("home/v1/assembled")
        const part = await upload.uploadPart(1, "one")
        return async () => {
          try {
            return await upload.complete([part])
          } finally {
            // Refused or not, no object was assembled from bytes read through the link: a swap
            // before the parts are read refuses the completion, one after it leaves the real bytes.
            // (Read through a bucket without the seam, so the check itself adds no checkpoint.)
            const stored = await new FsBucket(root).get("home/v1/assembled")
            if (stored) expect(await new Response(stored.body!).text()).toBe("one")
          }
        }
      }, linkMultipart, unlinkMultipart)

      expect(await new Response((await bucket.get("a/secret"))!.body!).text()).toBe("inside")
      expect(readFileSync(join(outside, "secret"), "utf8")).toBe("secret")
    } finally {
      rmSync(parent, { recursive: true, force: true })
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
  it("aborts every open upload under a key prefix, parts and record, and leaves other prefixes' uploads and stored objects alone", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const gone = [await bucket.createMultipartUpload("home/v1/conv_a/one"), await bucket.createMultipartUpload("home/v1/conv_a/two")]
      for (const upload of gone) await upload.uploadPart(1, "a part")
      const kept = await bucket.createMultipartUpload("home/v1/conv_b/one")
      const keptPart = await kept.uploadPart(1, "b part")
      // A prefix match is by key, not by path segment: conv_ab is not under conv_a/.
      const sibling = await bucket.createMultipartUpload("home/v1/conv_ab/one")
      await sibling.uploadPart(1, "ab part")
      await bucket.put("home/v1/conv_a/stored", "stored")
      expect(await bucket.abortMultipartUploads("home/v1/conv_a/")).toBe(2)
      expect(readdirSync(join(root, ".multipart")).sort()).toEqual([kept.uploadId, `${kept.uploadId}.json`, sibling.uploadId, `${sibling.uploadId}.json`].sort())
      for (const upload of gone) await expect(upload.uploadPart(2, "late")).rejects.toThrow(/NoSuchUpload/)
      expect(await new Response((await bucket.get("home/v1/conv_a/stored"))!.body!).text()).toBe("stored")
      await kept.complete([keptPart])
      expect(await bucket.abortMultipartUploads("home/v1/conv_a/")).toBe(0)
      // A bucket that never had an upload has nothing to abort.
      expect(await new FsBucket(join(root, "fresh")).abortMultipartUploads("home/")).toBe(0)
      // Never through a link: a record planted as a link is not an upload, and a linked .multipart is refused.
      const outside = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-outside-"))
      try {
        writeFileSync(join(outside, "record.json"), JSON.stringify({ key: "home/v1/conv_a/planted" }))
        symlinkSync(join(outside, "record.json"), join(root, ".multipart", `${"e".repeat(32)}.json`))
        expect(await bucket.abortMultipartUploads("home/v1/conv_a/")).toBe(0)
        expect(existsSync(join(outside, "record.json"))).toBe(true)
        const linked = join(root, "linked")
        mkdirSync(linked)
        symlinkSync(outside, join(linked, ".multipart"))
        await expect(new FsBucket(linked).abortMultipartUploads("home/")).rejects.toThrow(/symbolic link/)
        expect(existsSync(join(outside, "record.json"))).toBe(true)
      } finally {
        rmSync(outside, { recursive: true, force: true })
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it("aborts uploads by prefix only through the bucket's own .multipart: a linked directory, a linked record or a swap after the check is refused", async () => {
    const parent = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const outside = join(parent, "outside")
      mkdirSync(outside)
      const id = "a".repeat(32)
      const forged = JSON.stringify({ key: "home/v1/conv_a/x" })
      writeFileSync(join(outside, `${id}.json`), forged)
      mkdirSync(join(outside, id))
      writeFileSync(join(outside, id, "part.1"), "kept")

      // .multipart itself a link: refused, and nothing it points at is removed.
      const linkedRoot = join(parent, "linked")
      mkdirSync(linkedRoot)
      symlinkSync(outside, join(linkedRoot, ".multipart"))
      await expect(new FsBucket(linkedRoot).abortMultipartUploads("home/")).rejects.toThrow(/symbolic link/)

      // A record that is a link is not an upload.
      const root = join(parent, "bucket")
      const bucket = new FsBucket(root)
      const real = await bucket.createMultipartUpload("home/v1/conv_b/real")
      await real.uploadPart(1, "real part")
      symlinkSync(join(outside, `${id}.json`), join(root, ".multipart", `${id}.json`))
      expect(await bucket.abortMultipartUploads("home/v1/conv_a/")).toBe(0)

      // .multipart swapped for a link to a copy after the bucket checked it: refused, the copy and the real uploads untouched.
      const copy = join(parent, "copy")
      let swapped = false
      const swapping = new FsBucket(root, {
        afterPathCheck: () => {
          if (swapped) return
          swapped = true
          cpSync(join(root, ".multipart"), copy, { recursive: true, verbatimSymlinks: true })
          swapForLink(join(root, ".multipart"), copy)
        }
      })
      const before = snapshot(outside)
      await expect(swapping.abortMultipartUploads("home/v1/conv_b/")).rejects.toThrow(/symbolic link/)
      expect(swapped).toBe(true)
      expect(readdirSync(copy).sort()).toEqual([real.uploadId, `${real.uploadId}.json`, `${id}.json`].sort())
      restore(join(root, ".multipart"))
      expect(snapshot(outside)).toEqual(before)
      expect(await bucket.abortMultipartUploads("home/v1/conv_b/")).toBe(1)
      expect(readdirSync(join(root, ".multipart"))).toEqual([`${id}.json`])
      expect(readFileSync(join(outside, `${id}.json`), "utf8")).toBe(forged)
    } finally {
      rmSync(parent, { recursive: true, force: true })
    }
  })
  it("commits each write to a key whole: concurrent puts and completions never leave one write's bytes with another's metadata", async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-fs-bucket-"))
    try {
      const bucket = new FsBucket(root)
      const md5 = (text: string) => createHash("md5").update(text).digest("hex")
      /** What a reader sees is one write: the bytes, their size and their etag agree. */
      const whole = async (key: string, written: ReadonlyArray<string>) => {
        const head = await bucket.head(key)
        const got = await bucket.get(key)
        const text = await new Response(got!.body!).text()
        expect(written).toContain(text)
        expect([head!.size, head!.etag, got!.size, got!.etag]).toEqual([text.length, md5(text), text.length, md5(text)])
        expect((await bucket.list({ prefix: key })).objects.filter((o) => o.key === key).map((o) => [o.size, o.etag])).toEqual([[text.length, md5(text)]])
      }
      for (let round = 0; round < 20; round++) {
        // Bodies of different sizes, so a mismatch shows in the size as well as the etag.
        const bodies = Array.from({ length: 8 }, (_, i) => `${round}:${i}:${"x".repeat(i * 97 + 1)}`)
        await Promise.all(bodies.map((body) => bucket.put("home/v1/race", body)))
        await whole("home/v1/race", bodies)

        // A completion racing puts to its own key.
        const upload = await bucket.createMultipartUpload("home/v1/race-mp")
        const part = await upload.uploadPart(1, `mp:${round}`)
        const others = bodies.slice(0, 4)
        await Promise.all([upload.complete([part]), ...others.map((body) => bucket.put("home/v1/race-mp", body))])
        await whole("home/v1/race-mp", [`mp:${round}`, ...others])

        // Only one of several conditional puts to a new key wins; what is stored is that one, whole.
        const fresh = `home/v1/once-${round}`
        const results = await Promise.all(bodies.map((body) => bucket.put(fresh, body, { onlyIf: { etagDoesNotMatch: "*" } })))
        expect(results.filter((r) => r !== null)).toHaveLength(1)
        await whole(fresh, [bodies[results.findIndex((r) => r !== null)]!])
      }
      // No temp file is left beside the objects.
      expect(readdirSync(join(root, "home", "v1")).filter((name) => name.includes(".tmp-") || name.includes(".multipart-"))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
