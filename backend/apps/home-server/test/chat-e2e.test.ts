import { afterEach, describe, expect, it } from "bun:test"
import { client, PEERS, startServer, type TestServer } from "./support.ts"

/**
 * The self-hosted chat server end to end: the cloud owners on the local runtime, reached over
 * HTTP and WebSocket as tailnet peers (fake WhoIs). Same scenarios as the Workers tests
 * (home-dm-group-e2e.test.ts): DM, group, send and receive, idempotent resend, reply, tapback,
 * read cursor and unread, typing, resume after a drop, restart with data kept, refusals.
 */
let server: TestServer | undefined
afterEach(() => {
  server?.stop()
  server = undefined
})

const text = (t: string) => [{ type: "text", text: t }]

describe("self-hosted chat server", () => {
  it("refuses tagged nodes, non-tailnet addresses, its own address and logins not allowed", async () => {
    server = startServer()
    for (const peer of [PEERS.tagged, PEERS.outside, PEERS.self, PEERS.carol]) {
      const r = await client(server, peer).info()
      expect(r.status).toBe(403)
      expect(r.json.message).toBe("not_allowed")
    }
    const alice = await client(server, PEERS.alice).info()
    expect(alice.status).toBe(200)
    expect(alice.json.kind).toBe("selfhost")
    expect(alice.json.login).toBe("alice@example.com")
    expect(alice.json.user_id).toMatch(/^user_[0-9a-f]{20}$/)
  })

  it("DM: open, send, receive on the other socket, resend, reply, tapback, read cursor, unread, typing", async () => {
    server = startServer()
    const alice = client(server, PEERS.alice)
    const bob = client(server, PEERS.bob)
    const [a, b] = [(await alice.info()).json, (await bob.info()).json]
    const opened = await alice.op("dm.open", { peer: b.user_id })
    expect(opened.json.ok).toBe(true)
    const dm = opened.json.value.conversation.id as string
    expect(dm).toMatch(/^conv_dm_/)
    // Bob opens the same DM from his side.
    expect((await bob.op("dm.open", { peer: a.user_id })).json.value.conversation.id).toBe(dm)

    const bobSocket = await bob.socket(`/v1/wire/conv/${dm}`)
    await bobSocket.next((f) => f.t === "welcome")
    bobSocket.send({ t: "subscribe" })
    await bobSocket.next((f) => f.t === "snapshot" || f.state !== undefined)

    const key = crypto.randomUUID()
    const sent = await alice.op("message.send", { conversation: dm, client_msg_id: key, parts: text("hi bob") }, key)
    expect(sent.json.ok).toBe(true)
    const event = await bobSocket.next((f) => f.t === "event" && JSON.stringify(f).includes("hi bob"))
    expect(event.t).toBe("event")

    // A resend with the same key replays: one message only.
    const again = await alice.op("message.send", { conversation: dm, client_msg_id: key, parts: text("hi bob") }, key)
    expect(again.json.ok).toBe(true)
    expect(again.json.replayed).toBe(true)
    const history = (await bob.read("conversation.history", { conversation: dm, limit: 50 })).json.value
    expect(history.messages.map((m: any) => m.parts[0].text)).toEqual(["hi bob"])
    const first = history.messages[0]

    // Bob's inbox shows one unread message from Alice (after the outbox drained to his UserDO).
    await server.runtime.runtime.quiesce()
    const inbox = (await bob.read("inbox.list", { limit: 50 })).json.value
    const row = inbox.entries.find((e: any) => e.conversation === dm)
    expect(row.unread).toBe(1)

    // Reply, tapback, read cursor.
    const rk = crypto.randomUUID()
    expect((await bob.op("message.send", { conversation: dm, client_msg_id: rk, parts: text("hey alice"), reply_to: { message_id: first.id, part_index: 0 } }, rk)).json.ok).toBe(true)
    expect((await bob.op("reaction.add", { conversation: dm, message_id: first.id, part_index: 0, reaction: { tapback: "love" } })).json.ok).toBe(true)
    expect((await bob.op("read_cursor.set", { conversation: dm, seq: first.seq })).json.ok).toBe(true)
    const after = (await alice.read("conversation.history", { conversation: dm, limit: 50 })).json.value.messages
    expect(after[0].reactions.map((r: any) => r.kind)).toEqual([{ tapback: "love" }])
    expect(after[1].reply_to).toEqual({ message_id: first.id, part_index: 0 })
    await server.runtime.runtime.quiesce()
    const bobRow = (await bob.read("inbox.list", { limit: 50 })).json.value.entries.find((e: any) => e.conversation === dm)
    expect(bobRow.unread).toBe(0)

    // Typing reaches the other member.
    const aliceSocket = await alice.socket(`/v1/wire/conv/${dm}`)
    await aliceSocket.next((f) => f.t === "welcome")
    aliceSocket.send({ t: "subscribe" })
    aliceSocket.send({ t: "typing", on: true })
    const typing = await bobSocket.next((f) => f.t === "conversation-typing")
    expect(typing).toMatchObject({ conversation: dm, participant: a.user_id, on: true })
    aliceSocket.close()
    bobSocket.close()
  })

  it("group: create with two people, both send, resume after a drop with after_seq, a stranger cannot subscribe", async () => {
    server = startServer(undefined, { owner: "alice@example.com", allow: ["bob@example.com", "carol@example.com"] })
    const alice = client(server, PEERS.alice)
    const bob = client(server, PEERS.bob)
    const carol = client(server, PEERS.carol)
    const [a, b] = [(await alice.info()).json, (await bob.info()).json]
    await carol.info()
    const created = await alice.op("conversation.create", {
      title: "Weekend",
      participants: [
        { id: a.user_id, kind: "human", display_name: "Alice Example" },
        { id: b.user_id, kind: "human", display_name: "Bob Example" }
      ]
    })
    expect(created.json.ok).toBe(true)
    const group = created.json.value.conversation.id as string
    // Carol is on the server but not in the group: no socket.
    await expect(carol.socket(`/v1/wire/conv/${group}`)).rejects.toThrow()

    const bobSocket = await bob.socket(`/v1/wire/conv/${group}`)
    await bobSocket.next((f) => f.t === "welcome")
    bobSocket.send({ t: "subscribe" })
    const snap = await bobSocket.next((f) => f.t === "snapshot" || f.state !== undefined)
    const seq0 = snap.seq ?? snap.sequence ?? 0
    bobSocket.close()

    // While Bob is offline, Alice sends twice.
    for (const t of ["one", "two"]) {
      const k = crypto.randomUUID()
      expect((await alice.op("message.send", { conversation: group, client_msg_id: k, parts: text(t) }, k)).json.ok).toBe(true)
    }
    const back = await bob.socket(`/v1/wire/conv/${group}`)
    await back.next((f) => f.t === "welcome")
    back.send({ t: "subscribe", after_seq: seq0 })
    await back.next((f) => JSON.stringify(f).includes('"two"'))
    const k = crypto.randomUUID()
    expect((await bob.op("message.send", { conversation: group, client_msg_id: k, parts: text("three") }, k)).json.ok).toBe(true)
    const messages = (await alice.read("conversation.history", { conversation: group, limit: 50 })).json.value.messages
    expect(messages.map((m: any) => m.parts[0].text)).toEqual(["one", "two", "three"])
    back.close()
  })

  it("keeps conversations across a restart (one SQLite file per object)", async () => {
    server = startServer()
    const dataDir = server.dataDir
    const alice = client(server, PEERS.alice)
    const b = (await client(server, PEERS.bob).info()).json
    const dm = (await alice.op("dm.open", { peer: b.user_id })).json.value.conversation.id as string
    const k = crypto.randomUUID()
    expect((await alice.op("message.send", { conversation: dm, client_msg_id: k, parts: text("still here") }, k)).json.ok).toBe(true)
    server.stop()
    server = startServer(dataDir)
    const history = (await client(server, PEERS.bob).read("conversation.history", { conversation: dm, limit: 50 })).json.value.messages
    expect(history.map((m: any) => m.parts[0].text)).toEqual(["still here"])
  })
})
