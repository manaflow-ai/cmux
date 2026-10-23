import { afterEach, describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
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
})
