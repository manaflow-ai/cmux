import { afterEach, describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
import { readdirSync } from "node:fs"
import { join } from "node:path"
import type { FsBucket } from "../src/fs-bucket.ts"
import { client, PEERS, startServer, type TestServer } from "./support.ts"

/** Media in a self-hosted DM: intent, verified PUT, a message with the part, a signed download by the other member. */
let server: TestServer | undefined
afterEach(() => {
  server?.stop()
  server = undefined
})

const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex")
const post = async (s: TestServer, peer: string, path: string, body: unknown) => {
  const r = await fetch(`${s.base}${path}`, { method: "POST", headers: { "content-type": "application/json", "x-test-peer": peer }, body: JSON.stringify(body) })
  return { status: r.status, json: (await r.json().catch(() => null)) as any }
}

describe("self-hosted attachments", () => {
  it("uploads a file in a DM; the other member downloads the same bytes; a stranger cannot mint a URL", async () => {
    server = startServer(undefined, { owner: "alice@example.com", allow: ["bob@example.com", "carol@example.com"] })
    const alice = client(server, PEERS.alice)
    const bob = client(server, PEERS.bob)
    const b = (await bob.info()).json
    await client(server, PEERS.carol).info()
    const dm = (await alice.op("dm.open", { peer: b.user_id })).json.value.conversation.id as string
    const body = new TextEncoder().encode("notes from the weekend\n")
    const hash = sha(body)
    const intent = await post(server, PEERS.alice, "/v1/home/attachments/intent", { conversation: dm, sha256: hash, byte_count: body.byteLength, mime_type: "text/plain", name: "notes.txt" })
    expect(intent.status).toBe(200)
    expect(intent.json.value.state).toBe("upload")
    const put = await fetch(intent.json.value.upload_url, { method: "PUT", body, headers: { "content-length": String(body.byteLength), "x-test-peer": PEERS.alice } })
    expect(put.status).toBe(200)
    const k = crypto.randomUUID()
    const sent = await alice.op("message.send", { conversation: dm, client_msg_id: k, parts: [{ type: "attachment", hash, name: "notes.txt", mime_type: "text/plain", byte_count: body.byteLength }] }, k)
    expect(sent.json.ok).toBe(true)
    const message = sent.json.value.message_id as string
    const minted = await post(server, PEERS.bob, "/v1/home/attachments/url", { conversation: dm, hash, message_id: message, part_index: 0 })
    expect(minted.status).toBe(200)
    const download = await fetch(new URL(minted.json.value.url, server.base).toString(), { headers: { "x-test-peer": PEERS.bob } })
    expect(download.status).toBe(200)
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(body)
    const stranger = await post(server, PEERS.carol, "/v1/home/attachments/url", { conversation: dm, hash })
    expect(stranger.status).toBe(403)
  })
  it("deleting a conversation's storage also ends its open multipart uploads, so no parts stay on disk", async () => {
    server = startServer()
    const alice = client(server, PEERS.alice)
    const b = (await client(server, PEERS.bob).info()).json
    const dm = (await alice.op("dm.open", { peer: b.user_id })).json.value.conversation.id as string
    const other = `conv_${"0".repeat(26)}`
    const bucket = server.runtime.env.HOME_ATTACHMENTS as FsBucket
    // An upload the client abandoned after its first part, and one in another conversation.
    const abandoned = await bucket.createMultipartUpload(`home/v1/${dm}/abandoned`)
    await abandoned.uploadPart(1, "a part nobody will complete")
    const kept = await bucket.createMultipartUpload(`home/v1/${other}/kept`)
    await kept.uploadPart(1, "still uploading")
    await bucket.put(`home/v1/${dm}/stored`, "stored")

    const conv = server.runtime.runtime.stub("CONVERSATION_DO", dm) as unknown as { deleteAttachmentStorage(e: string): Promise<number> }
    await conv.deleteAttachmentStorage(dm)
    expect(await bucket.head(`home/v1/${dm}/stored`)).toBeNull()
    // Only the other conversation's upload is left under .multipart.
    expect(readdirSync(join(server.dataDir, "blobs", ".multipart")).sort()).toEqual([kept.uploadId, `${kept.uploadId}.json`].sort())
    await expect(abandoned.uploadPart(2, "late")).rejects.toThrow(/NoSuchUpload/)
  })
})

describe("self-hosted attachments: conversation storage deletion", () => {
  it("aborts the conversation's open multipart uploads on disk, an upload no slot names included, and keeps other conversations' uploads", async () => {
    server = startServer(undefined, { owner: "alice@example.com", allow: ["bob@example.com"] })
    const alice = client(server, PEERS.alice)
    const b = (await client(server, PEERS.bob).info()).json
    const dm = (await alice.op("dm.open", { peer: b.user_id })).json.value.conversation.id as string
    const body = new Uint8Array(32 * 1024 * 1024 + 17).map((_, i) => i % 211)
    const intent = await post(server, PEERS.alice, "/v1/home/attachments/intent", { conversation: dm, sha256: sha(body), byte_count: body.byteLength, mime_type: "application/octet-stream", name: "a.bin", multipart: true })
    expect(intent.json.value).toMatchObject({ mode: "multipart", part_count: 2 })
    const size = intent.json.value.part_size as number
    const part = await fetch(intent.json.value.upload_url, { method: "PUT", body: body.subarray(0, size), headers: { "content-length": String(size), "x-cmux-part-number": "1", "x-test-peer": PEERS.alice } })
    expect(part.status).toBe(200)
    const bucket = server.runtime.env.HOME_ATTACHMENTS as FsBucket
    // An upload under the conversation's prefix that no slot names (its slot lost), and one of another conversation.
    const orphan = await bucket.createMultipartUpload(`home/v1/${dm}/orphan`)
    await orphan.uploadPart(1, "orphan part")
    const other = await bucket.createMultipartUpload("home/v1/conv_01JZZZZZZZZZZZZZZZZZZZZZZZ/kept")
    const multipartDir = join(server.dataDir, "blobs", ".multipart")
    expect(readdirSync(multipartDir).filter((n) => n.endsWith(".json"))).toHaveLength(3)
    const ns = server.runtime.env.CONVERSATION_DO as { idFromName(n: string): unknown; get(id: unknown): { deleteAttachmentStorage(e: string): Promise<number> } }
    await ns.get(ns.idFromName(dm)).deleteAttachmentStorage(dm)
    expect(readdirSync(multipartDir).sort()).toEqual([`${other.uploadId}.json`])
    await expect(orphan.uploadPart(2, "late")).rejects.toThrow(/NoSuchUpload/)
  })
})
