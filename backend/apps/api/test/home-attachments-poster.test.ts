/** Home attachments: one poster image per video slot, the URL route's `variant=poster`, and no overwrite after commit (home-messaging.md section 10.1). */
import { describe, expect, it } from "vitest"
import { attachmentPart, bytesOf, group, intent, op, post, put, sha, signIn, testEnv, urlFor, worker, type Who } from "./home-attachments-support.ts"

const VIDEO = { mime_type: "video/mp4", name: "clip.mp4", duration_ms: 1500 }
const posterOf = (b: Uint8Array, mime = "image/jpeg") => ({ sha256: sha(b), byte_count: b.byteLength, mime_type: mime })
const posterPart = (b: Uint8Array, mime = "image/jpeg") => ({ hash: sha(b), byte_count: b.byteLength, mime_type: mime })
const keyOfPresigned = (uploadUrl: string) => decodeURIComponent(new URL(uploadUrl).pathname).split("/").slice(2).join("/")
const posterUrl = (who: Who, conversation: string, hash: string, extra: Record<string, unknown> = {}) => post("/v1/home/attachments/url", who.token, { conversation, hash, variant: "poster", ...extra })

describe("Home attachments: video posters", { timeout: 120_000 }, () => {
  it("a video slot takes one poster upload; commit records it; variant=poster signs the poster object", async () => {
    const alice = await signIn("att-poster-alice")
    const bob = await signIn("att-poster-bob")
    const g = await group(alice, [bob])
    const video = bytesOf("fake mp4 bytes for a poster test")
    const poster = bytesOf("\xff\xd8 fake jpeg poster")
    const r = await intent(alice, g.id, video, { ...VIDEO, poster: posterOf(poster) })
    expect(r.status).toBe(200)
    expect(r.json.value.poster_upload).toMatchObject({ method: "PUT", headers: { "content-length": String(poster.byteLength) } })
    const posterPut = r.json.value.poster_upload.upload_url as string
    expect(posterPut).not.toContain(sha(poster))
    // The video cannot commit before its declared poster is stored; the slot stays usable.
    const early = await put(r.json.value.upload_url, video)
    expect(early.status).toBe(409)
    expect(((await early.json()) as any).error.code).toBe("attachment.poster_missing")
    // Wrong poster bytes are refused; the right ones are stored once.
    expect((await put(posterPut, bytesOf("\xff\xd8 forged jpeg poster"))).status).toBe(400)
    const stored = await put(posterPut, poster)
    expect(stored.status).toBe(200)
    expect((await put(posterPut, poster)).status).toBe(403)
    const done = await put(r.json.value.upload_url, video)
    expect(done.status).toBe(200)
    expect(((await done.json()) as any).value.attachment).toMatchObject({ hash: sha(video), poster: posterPart(poster) })

    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(sha(video), video, { ...VIDEO, width: undefined, height: undefined, poster: posterPart(poster) })] }, "m1")
    expect(sent.json.ok).toBe(true)
    const at = { message_id: sent.json.value.message_id, part_index: 0 }
    const minted = await posterUrl(bob, g.id, sha(video), at)
    expect(minted.status).toBe(200)
    const res = await worker.fetch(minted.json.value.url)
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toBe("image/jpeg")
    expect(res.headers.get("content-disposition")).toMatch(/^inline/)
    expect(new URL(minted.json.value.url).searchParams.get("variant")).toBe("poster")
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(poster)
    // Without a variant the same part serves the video.
    const main = await worker.fetch((await urlFor(bob, g.id, sha(video), at)).json.value.url)
    expect(new Uint8Array(await main.arrayBuffer())).toEqual(video)
    // The variant is signed: dropping it from a poster URL does not turn it into a video URL.
    const stripped = new URL(minted.json.value.url)
    stripped.searchParams.delete("variant")
    expect((await worker.fetch(stripped.toString())).status).toBe(403)
  })

  it("a presigned video takes its poster through the Worker; commit waits for it and records it", async () => {
    const alice = await signIn("att-poster-big-alice")
    const g = await group(alice)
    const big = new Uint8Array(33_000_000).fill(4)
    const poster = bytesOf("RIFF fake webp poster")
    const r = await intent(alice, g.id, big, { ...VIDEO, width: undefined, height: undefined, poster: posterOf(poster, "image/webp") })
    expect(r.json.value.mode).toBe("presigned")
    await testEnv.HOME_ATTACHMENTS.put(keyOfPresigned(r.json.value.upload_url), big, { sha256: sha(big) })
    const commit = () => post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot: r.json.value.slot })
    const early = await commit()
    expect(early.status).toBe(409)
    expect(early.json.error.code).toBe("attachment.poster_missing")
    expect((await put(r.json.value.poster_upload.upload_url, poster)).status).toBe(200)
    const done = await commit()
    expect(done.status).toBe(200)
    expect(done.json.value.attachment.poster).toEqual(posterPart(poster, "image/webp"))
    const got = await worker.fetch((await posterUrl(alice, g.id, sha(big))).json.value.url)
    expect(got.headers.get("content-type")).toBe("image/webp")
    expect(got.headers.get("content-disposition")).toMatch(/^inline/)
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(poster)
  })

  it("a poster for a non-video attachment is refused at intent and in a message part; poster type and size are checked", async () => {
    const alice = await signIn("att-poster-image-alice")
    const g = await group(alice)
    const img = bytesOf("png bytes with a poster")
    const poster = bytesOf("\xff\xd8 poster for an image")
    const refused = await intent(alice, g.id, img, { poster: posterOf(poster) })
    expect(refused.status).toBe(400)
    expect(refused.json.error.code).toBe("attachment.poster_refused")
    for (const mime of ["image/gif", "image/png"]) {
      const odd = await intent(alice, g.id, bytesOf("video bytes"), { ...VIDEO, poster: posterOf(poster, mime) })
      expect(odd.status).toBe(415)
      expect(odd.json.error.code).toBe("attachment.type_refused")
    }
    const huge = await intent(alice, g.id, bytesOf("video bytes"), { ...VIDEO, poster: { ...posterOf(poster), byte_count: 2_000_001 } })
    expect(huge.status).toBe(413)
    expect(huge.json.error.code).toBe("attachment.too_large")
    // An image part that claims a poster is not a valid part.
    const r = await intent(alice, g.id, img)
    expect((await put(r.json.value.upload_url, img)).status).toBe(200)
    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(sha(img), img, { poster: posterPart(poster) })] }, "m1")
    expect(sent.json.ok).toBe(false)
    expect(sent.json.error.code).toBe("invalid_parts")
    // A video part may only claim the poster its record holds.
    const video = bytesOf("video without poster")
    const v = await intent(alice, g.id, video, VIDEO)
    expect((await put(v.json.value.upload_url, video)).status).toBe(200)
    const claimed = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m2", parts: [attachmentPart(sha(video), video, { ...VIDEO, poster: posterPart(poster) })] }, "m2")
    expect(claimed.json.error.code).toBe("attachment_mismatch")
  })

  it("variant=poster without a poster is a typed error, never the video; a non-member and an unknown variant are refused", async () => {
    const alice = await signIn("att-poster-none-alice")
    const eve = await signIn("att-poster-none-eve")
    const g = await group(alice)
    const video = bytesOf("video with no poster at all")
    const v = await intent(alice, g.id, video, VIDEO)
    expect((await put(v.json.value.upload_url, video)).status).toBe(200)
    const none = await posterUrl(alice, g.id, sha(video))
    expect(none.status).toBe(404)
    expect(none.json.error.code).toBe("attachment.no_poster")
    const img = bytesOf("an image, not a video")
    const i = await intent(alice, g.id, img)
    expect((await put(i.json.value.upload_url, img)).status).toBe(200)
    const onImage = await posterUrl(alice, g.id, sha(img))
    expect(onImage.status).toBe(404)
    expect(onImage.json.error.code).toBe("attachment.no_poster")
    // Unknown variant.
    const odd = await post("/v1/home/attachments/url", alice.token, { conversation: g.id, hash: sha(video), variant: "thumbnail" })
    expect(odd.status).toBe(400)
    expect(odd.json.error.code).toBe("validation.invalid")
    // A non-member cannot mint a poster URL for a video that has one.
    const withPoster = bytesOf("video that has a poster")
    const poster = bytesOf("\xff\xd8 member-only poster")
    const p = await intent(alice, g.id, withPoster, { ...VIDEO, poster: posterOf(poster) })
    expect((await put(p.json.value.poster_upload.upload_url, poster)).status).toBe(200)
    expect((await put(p.json.value.upload_url, withPoster)).status).toBe(200)
    expect((await posterUrl(alice, g.id, sha(withPoster))).status).toBe(200)
    const stranger = await posterUrl(eve, g.id, sha(withPoster))
    expect(stranger.status).toBe(403)
    expect(stranger.json.error.code).toBe("auth.forbidden")
  })

  it("a presigned URL cannot overwrite the object after commit: the PUT is conditional and downloads stay pinned", async () => {
    const alice = await signIn("att-overwrite-alice")
    const g = await group(alice)
    const big = new Uint8Array(33_000_000).fill(6)
    const r = await intent(alice, g.id, big, { ...VIDEO, width: undefined, height: undefined })
    const url = new URL(r.json.value.upload_url)
    // `if-none-match: *` is signed: R2 refuses any PUT to a key that already holds an object, and the client cannot drop the header.
    expect(r.json.value.headers["if-none-match"]).toBe("*")
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toBe("content-length;host;if-none-match;x-amz-checksum-sha256")
    const key = keyOfPresigned(r.json.value.upload_url)
    await testEnv.HOME_ATTACHMENTS.put(key, big, { sha256: sha(big) })
    expect((await post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot: r.json.value.slot })).status).toBe(200)
    const minted = (await urlFor(alice, g.id, sha(big))).json.value.url as string
    // Even if other bytes reached the key (here through the binding, which skips the S3 condition), they are never served.
    await testEnv.HOME_ATTACHMENTS.put(key, new Uint8Array(33_000_000).fill(7))
    const res = await worker.fetch(minted, { headers: { range: "bytes=0-3" } })
    if (res.status === 206) expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array(4).fill(6))
    else expect(res.status).toBe(404)
  })
})
