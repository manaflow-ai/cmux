import { describe, expect, it } from "vitest"
import { connect, drain, human, inboxEntry, joinTeam, op, read, send, signIn, type Person } from "./setup/home-people.ts"

/**
 * A group past 64 members end to end (plans/cmux-next/home-dm-group-chats/DESIGN.md section 3):
 * the owner promotes it to the large tier, members deep in the list still subscribe, read and
 * post, a message bumps only its sender and the people it mentions, every other inbox pulls its
 * row (unread included) when it lists, `conversation.members` pages everyone, and a removed
 * member's socket closes.
 */
describe("Home large group, end to end", { timeout: 120_000 }, () => {
  it("80 people: promote, pull inbox rows, mentions, members page, own cursor, removal", async () => {
    const ann = await signIn("large-ann", "Ann Lee")
    const people: Array<Person> = []
    for (let n = 0; n < 79; n++) people.push(await signIn(`large-p${n}`, `Person ${n}`))
    for (const p of people) await joinTeam(ann, p)

    const created = await op(ann.token, "conversation.create", { title: "Everyone", participants: [human(ann), ...people.slice(0, 20).map(human)] })
    expect(created.error).toBeUndefined()
    const group = created.value.conversation.id as string
    for (const p of people.slice(20)) expect((await op(ann.token, "participants.add", { conversation: group, participant: human(p) })).error).toBeUndefined()

    const deep = people[78]!
    const mentioned = people[50]!
    const gone = people[60]!

    // Every page of members, in join order.
    const first = await read(deep.token, "conversation.members", { conversation: group, limit: 50 })
    expect(first.value.member_count).toBe(80)
    const second = await read(deep.token, "conversation.members", { conversation: group, after: first.value.next, limit: 50 })
    expect([...first.value.members, ...second.value.members].map((m: { id: string }) => m.id)).toContain(deep.user)
    expect(first.value.members.length + second.value.members.length).toBe(80)

    // The head is a roster; the snapshot adds the caller's own record.
    const snap = await read(deep.token, "conversation.snapshot", { conversation: group, tail: 0 })
    expect(snap.value.state.tier).toBe("large")
    expect(snap.value.state.participants.length).toBeLessThan(30)
    expect(snap.value.state.participants.some((p: { id: string }) => p.id === deep.user)).toBe(true)

    // A member deep in the list subscribes and sees messages live.
    const live = await connect(group, deep)
    const from = live.frames.length
    await send(people[3]!, group, "hello everyone")
    await live.until((f) => f.t === "event", from)

    // A mention bumps the person it names; the others pull from the conversation.
    await send(people[4]!, group, "@ look at this", [{ start: 0, length: 1, mention: mentioned.user }])
    await drain(group)
    const pinged = await inboxEntry(mentioned, group, (e) => (e?.mentions ?? 0) >= 1)
    expect(pinged?.mentions).toBe(1)
    const quiet = await inboxEntry(deep, group, (e) => (e?.unread ?? 0) >= 2)
    expect(quiet?.unread).toBe(2)
    expect(quiet?.preview).toContain("look at this")

    // Reading moves the reader's own cursor, and its pulled row follows.
    expect((await op(deep.token, "read_cursor.set", { conversation: group, seq: quiet!.last_seq })).error).toBeUndefined()
    expect((await inboxEntry(deep, group, (e) => e?.unread === 0))?.unread).toBe(0)
    expect((await read(deep.token, "conversation.snapshot", { conversation: group, tail: 0 })).value.state.read_cursors[deep.user]).toBe(quiet!.last_seq)

    // Posting from deep in the list works; a removed member's socket closes and its row goes.
    await send(deep, group, "thanks")
    const watching = await connect(group, gone)
    expect((await op(ann.token, "participants.remove", { conversation: group, participant: gone.user })).error).toBeUndefined()
    expect((await watching.closed).reason).toContain("not a participant")
    expect((await op(gone.token, "message.send", { conversation: group, client_msg_id: "x", parts: [{ type: "text", text: "hi?" }] }, "x")).error?.code).toBe("not_participant")
    await drain(group)
    const listed = await read(gone.token, "inbox.list", { limit: 200 })
    expect((listed.value.entries as Array<{ conversation: string }>).some((e) => e.conversation === group)).toBe(false)
    expect((await read(ann.token, "conversation.members", { conversation: group, limit: 1 })).value.member_count).toBe(79)
    live.ws.close()
  })
})
