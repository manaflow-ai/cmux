import { describe, expect, it } from "vitest"
import { connect, drain, head, human, inboxEntry, joinTeam, op, read, send, signIn, text } from "./setup/home-people.ts"

/**
 * Group roles and revocation end to end through the public routes
 * (plans/cmux-next/home-dm-group-chats/DESIGN.md sections 4 and 8). Ann owns the group and makes
 * Ben an admin; Ben removes and bans Cat. Cat's open socket closes at once, every op and read she
 * tries is refused, her inbox row goes, and nobody can add her back until an admin unbans her.
 * Then Ann hands the group to Ben.
 */
describe("Home group roles and a revoked member, end to end", { timeout: 60_000 }, () => {
  it("admin, remove with ban, closed socket, refused ops and reads, unban, transfer", async () => {
    const ann = await signIn("roles-ann", "Ann Lee")
    const ben = await signIn("roles-ben", "Ben Ross")
    const cat = await signIn("roles-cat", "Cat Diaz")
    const dee = await signIn("roles-dee", "Dee Park")
    for (const p of [ben, cat, dee]) await joinTeam(ann, p)

    const created = await op(ann.token, "conversation.create", { title: "Ops", participants: [human(ann), human(ben), human(cat), human(dee)] })
    expect(created.error).toBeUndefined()
    const group = created.value.conversation.id as string
    await send(cat, group, "hi all")

    // Only the owner makes an admin; a member cannot.
    expect((await op(dee.token, "participants.set_role", { conversation: group, participant: ben.user, role: "admin" })).error?.code).toBe("forbidden")
    expect((await op(ann.token, "participants.set_role", { conversation: group, participant: ben.user, role: "admin" })).error).toBeUndefined()
    expect((await head(ann, group)).participants.find((p) => p.id === ben.user)?.role).toBe("admin")

    // A read-only member reads but cannot post.
    expect((await op(ben.token, "participants.set_role", { conversation: group, participant: dee.user, role: "read_only" })).error).toBeUndefined()
    expect((await op(dee.token, "message.send", { conversation: group, client_msg_id: "ro", parts: [text("may I?")] }, "ro")).error?.code).toBe("read_only")
    expect((await read(dee.token, "conversation.history", { conversation: group, limit: 10 })).error).toBeUndefined()

    // Cat is watching when the admin removes and bans her.
    const watching = await connect(group, cat)
    expect((await op(ben.token, "participants.remove", { conversation: group, participant: cat.user, ban: true })).error).toBeUndefined()
    const closed = await watching.closed
    expect(closed.reason).toContain("not a participant")

    // Everything she tries is refused, and no read leaks history.
    expect((await op(cat.token, "message.send", { conversation: group, client_msg_id: "late", parts: [text("still here?")] }, "late")).error?.code).toBe("not_participant")
    expect((await op(cat.token, "read_cursor.set", { conversation: group, seq: 1 })).error?.code).toBe("not_participant")
    expect((await op(cat.token, "title.set", { conversation: group, title: "mine" })).error?.code).toBe("not_participant")
    // A refused read answers { code } and no messages.
    expect((await read(cat.token, "conversation.history", { conversation: group, limit: 10 })).code).toBe("auth.forbidden")
    expect((await read(cat.token, "conversation.snapshot", { conversation: group, tail: 5 })).code).toBe("auth.forbidden")
    expect((await read(cat.token, "conversation.members", { conversation: group })).code).toBe("auth.forbidden")
    const reopened = await fetchSocketStatus(group, cat.token)
    expect(reopened).not.toBe(101)

    // Her inbox row goes; a later message never reaches her.
    await send(ann, group, "after Cat")
    await drain(group)
    const listed = await read(cat.token, "inbox.list", { limit: 200 })
    expect((listed.value.entries as Array<{ conversation: string }>).some((e) => e.conversation === group)).toBe(false)

    // Banned: nobody adds her back until an admin unbans her.
    expect((await op(ann.token, "participants.add", { conversation: group, participant: human(cat) })).error?.code).toBe("banned")
    expect((await op(ben.token, "participants.unban", { conversation: group, participant: cat.user })).error).toBeUndefined()
    expect((await op(ann.token, "participants.add", { conversation: group, participant: human(cat) })).error).toBeUndefined()
    expect((await inboxEntry(cat, group))?.title).toBe("Ops")

    // Ann hands the group to Ben and stays as an admin.
    expect((await op(ben.token, "ownership.transfer", { conversation: group, participant: dee.user })).error?.code).toBe("forbidden")
    expect((await op(ann.token, "ownership.transfer", { conversation: group, participant: ben.user })).error).toBeUndefined()
    const roles = Object.fromEntries((await head(ann, group)).participants.filter((p) => p.left_at === undefined).map((p) => [p.id, p.role]))
    expect(roles[ben.user]).toBe("owner")
    expect(roles[ann.user]).toBe("admin")
  })
})

const fetchSocketStatus = async (conversation: string, token: string) => {
  const { worker } = await import("./setup/home-people.ts")
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${conversation}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  if (res.status !== 101) return res.status
  // An upgrade that is accepted must refuse the subscription.
  const ws = res.webSocket!
  ws.accept()
  const answer = new Promise<string>((resolve) => {
    ws.addEventListener("message", (e) => resolve(JSON.parse(e.data as string).t))
    ws.addEventListener("close", () => resolve("closed"))
  })
  ws.send(JSON.stringify({ t: "subscribe" }))
  const first = await answer
  ws.close()
  return first === "snapshot" ? 101 : 403
}
