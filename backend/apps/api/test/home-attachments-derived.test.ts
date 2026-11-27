/** Home attachments: a derived image (poster or preview) stays bound to its variant (home-messaging.md section 10.1). */
import { createHmac } from "node:crypto"
import { describe, expect, it } from "vitest"
import { bytesOf, group, intent, put, sha, signIn, testEnv } from "./home-attachments-support.ts"

const VIDEO = { mime_type: "video/mp4", name: "clip.mp4", duration_ms: 1500 }
const image = (b: Uint8Array, mime = "image/webp") => ({ sha256: sha(b), byte_count: b.byteLength, mime_type: mime })
const derivedKeys = async (conversation: string) =>
  (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${conversation}/` })).objects.map((o) => o.key).filter((k) => k.endsWith(".poster") || k.endsWith(".preview"))
/** A correctly signed token of `variant` for the slot in `url` (as a minting bug would issue it): the server key, never a client. */
const forged = (url: string, variant: "poster" | "preview") => {
  const parts = new URL(url).pathname.split("/")
  const [slot, kid] = parts[parts.length - 1]!.split(".")
  const conversation = parts[parts.length - 2]!
  const sig = createHmac("sha256", testEnv.HOME_ATTACHMENT_KEY!).update([`home-attachment-${variant}-upload`, kid, conversation, slot].join("\u0000")).digest("base64url")
  parts[parts.length - 3] = variant
  parts[parts.length - 1] = `${slot}.${kid}.${sig}`
  return `https://api.test${parts.join("/")}`
}

describe("Home attachments: derived image variants", { timeout: 120_000 }, () => {
  it("a poster token on /preview/ and a preview token on /poster/ are refused; nothing is stored and the slots stay usable", async () => {
    const alice = await signIn("att-derived-swap-alice")
    const g = await group(alice)
    const video = bytesOf("video whose poster token is swapped")
    const poster = bytesOf("\xff\xd8 swapped poster")
    const v = await intent(alice, g.id, video, { ...VIDEO, poster: image(poster, "image/jpeg") })
    expect(v.status).toBe(200)
    const img = bytesOf("image whose preview token is swapped")
    const preview = bytesOf("RIFF swapped preview")
    const i = await intent(alice, g.id, img, { preview: image(preview) })
    expect(i.status).toBe(200)
    const posterUrl = v.json.value.poster_upload.upload_url as string
    const previewUrl = i.json.value.preview_upload.upload_url as string
    expect((await put(posterUrl.replace("/poster/", "/preview/"), poster)).status).toBe(403)
    expect((await put(previewUrl.replace("/preview/", "/poster/"), preview)).status).toBe(403)
    expect(await derivedKeys(g.id)).toEqual([])
    // Neither refusal used a slot: both main PUTs still wait for their derived image.
    expect(((await (await put(v.json.value.upload_url, video)).json()) as any).error.code).toBe("attachment.poster_missing")
    expect(((await (await put(i.json.value.upload_url, img)).json()) as any).error.code).toBe("attachment.preview_missing")
    expect((await put(posterUrl, poster)).status).toBe(200)
    expect((await put(previewUrl, preview)).status).toBe(200)
  })

  it("a validly signed token of the wrong variant for the slot's type is refused (the slot's type is checked too)", async () => {
    const alice = await signIn("att-derived-forged-alice")
    const g = await group(alice)
    const video = bytesOf("video given a preview token")
    const poster = bytesOf("\xff\xd8 poster sent as a preview")
    const v = await intent(alice, g.id, video, { ...VIDEO, poster: image(poster, "image/jpeg") })
    expect((await put(forged(v.json.value.poster_upload.upload_url, "preview"), poster)).status).toBe(403)
    const img = bytesOf("image given a poster token")
    const preview = bytesOf("RIFF preview sent as a poster")
    const i = await intent(alice, g.id, img, { preview: image(preview) })
    expect((await put(forged(i.json.value.preview_upload.upload_url, "poster"), preview)).status).toBe(403)
    expect(await derivedKeys(g.id)).toEqual([])
    expect(((await (await put(v.json.value.upload_url, video)).json()) as any).error.code).toBe("attachment.poster_missing")
    expect(((await (await put(i.json.value.upload_url, img)).json()) as any).error.code).toBe("attachment.preview_missing")
  })

  it("first upload wins, including its derived image: a later intent declaring a preview gets the stored record, without a preview or preview_upload", async () => {
    const alice = await signIn("att-derived-first-alice")
    const g = await group(alice)
    const img = bytesOf("image stored first without a preview")
    const first = await intent(alice, g.id, img)
    expect((await put(first.json.value.upload_url, img)).status).toBe(200)
    const again = await intent(alice, g.id, img, { preview: image(bytesOf("RIFF late preview")) })
    expect(again.status).toBe(200)
    expect(again.json.value).toEqual({ state: "exists", attachment: { hash: sha(img), mime_type: "image/png", byte_count: img.byteLength } })
    expect(again.json.value.preview_upload).toBeUndefined()
    expect(await derivedKeys(g.id)).toEqual([])
  })
})
