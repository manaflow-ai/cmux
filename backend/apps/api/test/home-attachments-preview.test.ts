/** Home attachments: one small preview image per image slot and the URL route's `variant=preview` (home-messaging.md section 10.1). */
import { describe, expect, it } from "vitest"

import { attachmentPart, bytesOf, group, intent, op, post, put, runInDurableObject, sha, signIn, testEnv, urlFor, worker, type Who } from "./home-attachments-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

const VIDEO = { mime_type: "video/mp4", name: "clip.mp4", duration_ms: 1500 }
const previewOf = (b: Uint8Array, mime = "image/webp") => ({ sha256: sha(b), byte_count: b.byteLength, mime_type: mime })
const previewPart = (b: Uint8Array, mime = "image/webp") => ({ hash: sha(b), byte_count: b.byteLength, mime_type: mime })
const previewUrl = (who: Who, conversation: string, hash: string, extra: Record<string, unknown> = {}) => post("/v1/home/attachments/url", who.token, { conversation, hash, variant: "preview", ...extra })
const storedBytes = (who: Who) =>
  runInDurableObject(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(who.user)), async (_i, state) => Number((state.storage.sql.exec("SELECT COALESCE(SUM(bytes), 0) AS b FROM home_attachment_stored").toArray()[0] as { b: number }).b))

/** Intent with a preview, preview PUT, image PUT: the image's hash. */
const uploadWithPreview = async (who: Who, conversation: string, img: Uint8Array, preview: Uint8Array) => {
  const r = await intent(who, conversation, img, { preview: previewOf(preview) })
  expect(r.status).toBe(200)
  expect((await put(r.json.value.preview_upload.upload_url, preview)).status).toBe(200)
  expect((await put(r.json.value.upload_url, img)).status).toBe(200)
  return sha(img)
}

describe("Home attachments: image previews", { timeout: 120_000 }, () => {
  it("an image slot takes one preview upload; commit records it; variant=preview signs and serves the preview inline", async () => {
    const alice = await signIn("att-preview-alice")
    const bob = await signIn("att-preview-bob")
    const g = await group(alice, [bob])
    const img = bytesOf("full size png bytes with a preview")
    const preview = bytesOf("RIFF small webp preview")
    const r = await intent(alice, g.id, img, { preview: previewOf(preview) })
    expect(r.status).toBe(200)
    expect(r.json.value.preview_upload).toMatchObject({ method: "PUT", headers: { "content-length": String(preview.byteLength) } })
    expect(r.json.value.poster_upload).toBeUndefined()
    const previewPut = r.json.value.preview_upload.upload_url as string
    expect(previewPut).not.toContain(sha(preview))
    // The image waits for its declared preview; the slot stays usable.
    const early = await put(r.json.value.upload_url, img)
    expect(early.status).toBe(409)
    expect(((await early.json()) as any).error.code).toBe("attachment.preview_missing")
    // The upload token is per purpose: the image token is not a preview token.
    expect((await put(r.json.value.upload_url.replace("/upload/", "/preview/"), preview)).status).toBe(403)
    expect((await put(previewPut, bytesOf("RIFF forged webp preview"))).status).toBe(400)
    expect((await put(previewPut, preview)).status).toBe(200)
    expect((await put(previewPut, preview)).status).toBe(403)
    const done = await put(r.json.value.upload_url, img)
    expect(done.status).toBe(200)
    expect(((await done.json()) as any).value.attachment).toMatchObject({ hash: sha(img), preview: previewPart(preview) })
    // The preview object sits next to the image under the same key.
    const keys = (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${g.id}/` })).objects.map((o) => o.key)
    expect(keys.filter((k) => k.endsWith(".preview"))).toHaveLength(1)

    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(sha(img), img, { preview: previewPart(preview) })] }, "m1")
    expect(sent.json.ok).toBe(true)
    const at = { message_id: sent.json.value.message_id, part_index: 0 }
    const minted = await previewUrl(bob, g.id, sha(img), at)
    expect(minted.status).toBe(200)
    expect(new URL(minted.json.value.url).searchParams.get("variant")).toBe("preview")
    const res = await worker.fetch(minted.json.value.url)
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toBe("image/webp")
    expect(res.headers.get("content-disposition")).toMatch(/^inline/)
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(preview)
    // Without a variant the same part serves the original.
    const main = await worker.fetch((await urlFor(bob, g.id, sha(img), at)).json.value.url)
    expect(new Uint8Array(await main.arrayBuffer())).toEqual(img)
    // The variant is signed: neither dropping it nor swapping it to poster changes what the URL serves.
    const stripped = new URL(minted.json.value.url)
    stripped.searchParams.delete("variant")
    expect((await worker.fetch(stripped.toString())).status).toBe(403)
    stripped.searchParams.set("variant", "poster")
    expect((await worker.fetch(stripped.toString())).status).toBe(403)
  })

  it("a preview on a video is refused (a video uses poster); preview type and size are checked; parts must match the record", async () => {
    const alice = await signIn("att-preview-video-alice")
    const g = await group(alice)
    const preview = bytesOf("\xff\xd8 preview jpeg")
    const onVideo = await intent(alice, g.id, bytesOf("video bytes with a preview"), { ...VIDEO, preview: previewOf(preview, "image/jpeg") })
    expect(onVideo.status).toBe(400)
    expect(onVideo.json.error.code).toBe("attachment.preview_refused")
    const onFile = await intent(alice, g.id, bytesOf("%PDF with a preview"), { mime_type: "application/pdf", name: "doc.pdf", width: undefined, height: undefined, preview: previewOf(preview) })
    expect(onFile.json.error.code).toBe("attachment.preview_refused")
    const png = await intent(alice, g.id, bytesOf("image with a png preview"), { preview: previewOf(preview, "image/png") })
    expect(png.status).toBe(415)
    expect(png.json.error.code).toBe("attachment.type_refused")
    const huge = await intent(alice, g.id, bytesOf("image with a huge preview"), { preview: { ...previewOf(preview), byte_count: 512_001 } })
    expect(huge.status).toBe(413)
    expect(huge.json.error.code).toBe("attachment.too_large")
    // A video part never claims a preview; an image part claims only the preview its record holds.
    const video = bytesOf("plain video")
    const v = await intent(alice, g.id, video, VIDEO)
    expect((await put(v.json.value.upload_url, video)).status).toBe(200)
    const videoPart = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(sha(video), video, { ...VIDEO, preview: previewPart(preview, "image/jpeg") })] }, "m1")
    expect(videoPart.json.error.code).toBe("invalid_parts")
    const img = bytesOf("plain image, no preview")
    const i = await intent(alice, g.id, img)
    expect((await put(i.json.value.upload_url, img)).status).toBe(200)
    const claimed = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m2", parts: [attachmentPart(sha(img), img, { preview: previewPart(preview, "image/jpeg") })] }, "m2")
    expect(claimed.json.error.code).toBe("attachment_mismatch")
  })

  it("variant=preview without a preview is a typed 404, never the original; a non-member is refused", async () => {
    const alice = await signIn("att-preview-none-alice")
    const eve = await signIn("att-preview-none-eve")
    const g = await group(alice)
    const img = bytesOf("image without a preview")
    const i = await intent(alice, g.id, img)
    expect((await put(i.json.value.upload_url, img)).status).toBe(200)
    const none = await previewUrl(alice, g.id, sha(img))
    expect(none.status).toBe(404)
    expect(none.json.error.code).toBe("attachment.no_preview")
    // A video with a poster has no preview either.
    const video = bytesOf("video with a poster, asked for a preview")
    const poster = bytesOf("\xff\xd8 poster")
    const v = await intent(alice, g.id, video, { ...VIDEO, poster: { sha256: sha(poster), byte_count: poster.byteLength, mime_type: "image/jpeg" } })
    expect((await put(v.json.value.poster_upload.upload_url, poster)).status).toBe(200)
    expect((await put(v.json.value.upload_url, video)).status).toBe(200)
    const onVideo = await previewUrl(alice, g.id, sha(video))
    expect(onVideo.status).toBe(404)
    expect(onVideo.json.error.code).toBe("attachment.no_preview")
    // A previewed image asked for a poster is no_poster.
    const withPreview = await uploadWithPreview(alice, g.id, bytesOf("member-only image"), bytesOf("RIFF member-only preview"))
    expect((await post("/v1/home/attachments/url", alice.token, { conversation: g.id, hash: withPreview, variant: "poster" })).json.error.code).toBe("attachment.no_poster")
    expect((await previewUrl(alice, g.id, withPreview)).status).toBe(200)
    const stranger = await previewUrl(eve, g.id, withPreview)
    expect(stranger.status).toBe(403)
    expect(stranger.json.error.code).toBe("auth.forbidden")
  })

  it("the slot's quota charge and the uploader's stored bytes include the preview; the sweep deletes the preview with its image", async () => {
    const alice = await signIn("att-preview-quota-alice")
    const g = await group(alice)
    const img = bytesOf("image counted with its preview")
    const preview = bytesOf("RIFF preview counted too")
    const hash = await uploadWithPreview(alice, g.id, img, preview)
    expect(await storedBytes(alice)).toBe(img.byteLength + preview.byteLength)
    const doStub = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(g.id))
    const left = async () => (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${g.id}/` })).objects.map((o) => o.key)
    expect(await left()).toHaveLength(2)
    expect((await previewUrl(alice, g.id, hash)).status).toBe(200)
    await runInDurableObject(doStub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_objects SET created_at = ?", Date.now() - 25 * 3_600_000))
    await fireAlarm(doStub)
    expect(await left()).toEqual([])
    expect(await storedBytes(alice)).toBe(0)
  })
})
