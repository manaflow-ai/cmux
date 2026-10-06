/** Home link previews: a `link_preview` part's image is an ordinary attachment record the sender uploaded; receivers fetch it by hash or by the part. */
import { describe, expect, it } from "vitest"

import { group, op, sha, signIn, text, upload, urlFor, worker } from "./home-attachments-support.ts"

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new TextEncoder().encode(" the page's og:image")])
const linkPart = (image?: Record<string, unknown>) => ({ type: "link_preview", url: "https://example.com/post", title: "A post", site: "example.com", ...(image ? { image } : {}) })
const imageOf = (over: Record<string, unknown> = {}) => ({ hash: sha(JPEG), mime_type: "image/jpeg", byte_count: JPEG.byteLength, ...over })

describe("Home attachments: link preview images", { timeout: 120_000 }, () => {
  it("a preview commits only with the sender's matching record; every participant then reads the image", async () => {
    const alice = await signIn("att-link-alice")
    const bob = await signIn("att-link-bob")
    const g = await group(alice, [bob])
    const send = (who: typeof alice, parts: unknown, key: string) => op(who.token, "message.send", { conversation: g.id, client_msg_id: key, parts }, key)
    expect((await send(alice, [linkPart(imageOf())], "m0")).json.error.code).toBe("unknown_attachment")
    await upload(alice, g.id, JPEG, { mime_type: "image/jpeg", name: "link-preview.jpg", width: undefined, height: undefined })
    // Bob did not upload it and no message references it yet.
    expect((await send(bob, [linkPart(imageOf())], "b0")).json.error.code).toBe("unknown_attachment")
    expect((await send(alice, [linkPart(imageOf({ mime_type: "image/webp" }))], "m1")).json.error.code).toBe("attachment_mismatch")
    expect((await send(alice, [linkPart(imageOf({ byte_count: JPEG.byteLength + 1 }))], "m2")).json.error.code).toBe("attachment_mismatch")
    expect((await send(alice, [linkPart({ ...imageOf(), mime_type: "image/png" })], "m3")).json.error.code).toBe("invalid_parts")
    expect((await send(alice, [linkPart(), { ...linkPart(), url: "javascript:alert(1)" }], "m4")).json.error.code).toBe("invalid_parts")
    const sent = await send(alice, [text("look"), linkPart(imageOf())], "m5")
    expect(sent.json.ok).toBe(true)
    // By the part and by the hash alone.
    for (const at of [{ message_id: sent.json.value.message_id as string, part_index: 1 }, undefined]) {
      const minted = await urlFor(bob, g.id, sha(JPEG), at)
      expect(minted.status).toBe(200)
      const res = await worker.fetch(minted.json.value.url)
      expect(res.status).toBe(200)
      expect(res.headers.get("content-type")).toBe("image/jpeg")
      expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG)
    }
    // The text part at index 0 holds no such hash.
    expect((await urlFor(bob, g.id, sha(JPEG), { message_id: sent.json.value.message_id, part_index: 0 })).status).toBe(404)
    // A preview without an image needs no upload.
    expect((await send(bob, [linkPart()], "b1")).json.ok).toBe(true)
  })
})
