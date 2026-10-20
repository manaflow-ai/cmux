import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { memberUpsert } from "../src/domains/team-members.ts"
import { userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Home DMs and group chats end to end (plans/cmux-next/home-dm-group-chats/AUDIT.md), the way the
 * Mac and iPhone use them: every step goes through the public routes (`POST /v1/ops`, `POST
 * /v1/read`, `GET /v1/wire/conv/<id>`) as a signed-in person, and every check reads the other
 * person's own view (their inbox and their history), never the sender's.
 *
 * - DM: two strangers. Ann reaches Ben by email (a message request), Ben accepts, both talk,
 *   unread and read cursors move in each inbox, mute, typing, and afterwards each reaches the
 *   other by user id at the same conversation.
 * - Group: Ann, Ben and Cat. Create with a name, mention, rename, add Dee, Ben leaves, the owner
 *   removes Cat, and each person's inbox follows.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sessionToken = async (sub: string, email: string, name: string) =>
  new SignJWT({ email, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return (await res.json().catch(() => null)) as any
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })

interface Person {
  readonly token: string
  readonly user: string
  readonly team: string
  readonly name: string
  readonly email: string
}
const signIn = async (tag: string, name: string): Promise<Person> => {
  const sub = `e2e-${tag}`
  const email = `${tag}@${tag}.test`
  const token = await sessionToken(sub, email, name)
  const ensured = await op(token, "user.ensure", {})
  expect(ensured.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub), team: ensured.value.personal_team as string, name, email }
}
/** `member` joins `owner`'s team (team invites are not built; TeamDO rows are seeded as in home-reach.test.ts). */
const joinTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    instance.boundEngine.rows.apply([memberUpsert({ user: member.user, role: "member", display_name: member.name })])
  })
}
const human = (p: Person) => ({ id: p.user, kind: "human", display_name: p.name })
const text = (body: string, runs?: unknown) => ({ type: "text", text: body, ...(runs ? { runs } : {}) })
const send = async (p: Person, conversation: string, body: string, runs?: unknown) => {
  const key = crypto.randomUUID()
  const sent = await op(p.token, "message.send", { conversation, client_msg_id: key, parts: [text(body, runs)] }, key)
  expect(sent.error).toBeUndefined()
  return sent.value as { message_id: string; seq: number }
}
const drain = (conversation: string) => fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation)))
type Entry = { conversation: string; kind: string; title: string; unread: number; mentions: number; muted: boolean; muted_until?: number; dm_peer?: string; preview: string; last_seq: number }
/** `who`'s own inbox entry for `conversation`, read once the outbox drained into it and `ready` holds. */
const inboxEntry = async (who: Person, conversation: string, ready: (e: Entry | undefined) => boolean = (e) => e !== undefined): Promise<Entry | undefined> => {
  let last: Entry | undefined
  for (let attempt = 0; attempt < 100; attempt++) {
    const listed = await read(who.token, "inbox.list", { limit: 200 })
    expect(listed.error).toBeUndefined()
    last = (listed.value.entries as Array<Entry>).find((e) => e.conversation === conversation)
    if (ready(last)) return last
    await drain(conversation)
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error(`${who.name}'s inbox never got there for ${conversation}: ${JSON.stringify(last)}`)
}
const history = async (who: Person, conversation: string) => {
  const page = await read(who.token, "conversation.history", { conversation, limit: 50 })
  expect(page.error).toBeUndefined()
  return page.value.messages as Array<{ author: string; seq: number; parts: Array<{ text?: string }> }>
}
const head = async (who: Person, conversation: string) => {
  const snap = await read(who.token, "conversation.snapshot", { conversation, tail: 0 })
  expect(snap.error).toBeUndefined()
  return snap.value.state as homeConversation.ConversationHead
}
const members = (state: homeConversation.ConversationHead) =>
  state.participants.filter((p) => p.left_at === undefined && p.kind === "human").map((p) => p.id).sort()

/** A conversation socket as the Mac's daemon opens it, with a wait for the next matching frame. */
const connect = async (conversation: string, who: Person) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${conversation}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${who.token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws.accept()
  const until = async (match: (f: any) => boolean, from = 0) => {
    for (;;) {
      const i = frames.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return frames[i]
      await new Promise<void>((r) => (wake = r))
    }
  }
  ws.send(JSON.stringify({ t: "subscribe" }))
  await until((f) => f.t === "snapshot")
  return { ws, until, send: (frame: unknown) => ws.send(JSON.stringify(frame)) }
}

describe("Home DM between two strangers, end to end", { timeout: 60_000 }, () => {
  it("email request, accept, talk both ways, unread and read cursors per inbox, mute, typing, then reach by id", async () => {
    const ann = await signIn("dm-ann", "Ann Lee")
    const ben = await signIn("dm-ben", "Ben Ross")

    // Strangers: no DM by user id (no team, no connection); the email path is the way in.
    expect((await op(ann.token, "dm.open", { peer: ben.user })).error?.code).toBe("not_reachable")
    const opened = await op(ann.token, "dm.open", { peer: { email: ben.email } })
    expect(opened.error).toBeUndefined()
    const dm = opened.value.conversation.id as string
    await send(ann, dm, "hi Ben, Ann here")

    // Ben sees a request (no id leaks), accepts it without the email link.
    let requests: Array<any> = []
    for (let attempt = 0; attempt < 100 && requests.length === 0; attempt++) {
      requests = (await read(ben.token, "home.requests.list", {})).value?.requests ?? []
      if (requests.length === 0) await drain(dm)
    }
    expect(requests).toHaveLength(1)
    expect(requests[0]).toMatchObject({ conversation: dm, inviter: "Ann Lee", kind: "dm", preview: "hi Ben, Ann here" })
    expect((await op(ben.token, "invite.accept_verified", { conversation: dm })).error).toBeUndefined()
    expect(members(await head(ben, dm))).toEqual([ann.user, ben.user].sort())

    // Ben's inbox: a DM with Ann, the one message unread.
    expect(await inboxEntry(ben, dm, (e) => e?.unread === 1)).toMatchObject({ kind: "dm", unread: 1, muted: false })

    // Ben opens the chat (the Mac moves the cursor while the newest row is on screen), then replies.
    expect((await op(ben.token, "read_cursor.set", { conversation: dm, seq: 1 }, "read:1")).error).toBeUndefined()
    await send(ben, dm, "hey Ann")
    const second = await send(ann, dm, "lunch tomorrow?")
    expect((await history(ben, dm)).map((m) => [m.author, m.parts[0]!.text])).toEqual([
      [ann.user, "hi Ben, Ann here"],
      [ben.user, "hey Ann"],
      [ann.user, "lunch tomorrow?"]
    ])
    // Ben's send moved his caught-up cursor to his own message; Ann's next one is unread.
    expect(await inboxEntry(ben, dm, (e) => e?.last_seq === second.seq)).toMatchObject({ unread: 1, preview: expect.stringContaining("lunch tomorrow?") })
    expect(await inboxEntry(ann, dm, (e) => (e?.last_seq ?? 0) >= 2)).toMatchObject({ kind: "dm", dm_peer: ben.user })

    // Reading clears Ben's count; Ann's count does not move.
    expect((await op(ben.token, "read_cursor.set", { conversation: dm, seq: second.seq }, `read:${second.seq}`)).error).toBeUndefined()
    expect(await inboxEntry(ben, dm, (e) => e?.unread === 0)).toMatchObject({ unread: 0 })

    // Mute over HTTP (the Mac's Hide Alerts): a past `until` is refused, a future one is kept, unmute clears.
    expect((await op(ben.token, "inbox.mute", { conversation: dm, muted: true, until: Date.now() - 1000 })).error?.code).toBe("invalid_params")
    const until = Date.now() + 3600_000
    expect((await op(ben.token, "inbox.mute", { conversation: dm, muted: true, until })).error).toBeUndefined()
    expect(await inboxEntry(ben, dm)).toMatchObject({ muted: true, muted_until: until })
    expect((await op(ben.token, "inbox.mute", { conversation: dm, muted: false })).error).toBeUndefined()
    const unmuted = await inboxEntry(ben, dm)
    expect(unmuted?.muted).toBe(false)
    expect(unmuted?.muted_until).toBeUndefined()

    // Typing reaches the other person's socket in a DM.
    const a = await connect(dm, ann)
    const b = await connect(dm, ben)
    a.send({ t: "typing", on: true })
    expect(await b.until((f) => f.t === "conversation-typing")).toEqual({ t: "conversation-typing", conversation: dm, participant: ann.user, on: true })
    a.ws.close()
    b.ws.close()

    // Connected now: each reaches the other by id, at the same conversation.
    expect((await op(ann.token, "dm.open", { peer: ben.user })).value?.conversation.id).toBe(dm)
    expect((await op(ben.token, "dm.open", { peer: ann.user })).value?.conversation.id).toBe(dm)
    // A DM has no leave and no rename (archive is the way out of the list).
    expect((await op(ben.token, "participants.remove", { conversation: dm, participant: ben.user })).error?.code).toBe("kind_forbids")
    expect((await op(ben.token, "title.set", { conversation: dm, title: "x" })).error).toBeDefined()
  })
})

describe("Home group chat, end to end", { timeout: 60_000 }, () => {
  it("create with a name, everyone's inbox, mention, rename, add, leave, remove, and who may do what", async () => {
    const ann = await signIn("grp-ann", "Ann Lee")
    const ben = await signIn("grp-ben", "Ben Ross")
    const cat = await signIn("grp-cat", "Cat Diaz")
    const dee = await signIn("grp-dee", "Dee Park")
    for (const member of [ben, cat, dee]) await joinTeam(ann, member)

    const created = await op(ann.token, "conversation.create", { kind: "group", title: "Trip", participants: [human(ann), human(ben), human(cat)] })
    expect(created.error).toBeUndefined()
    const group = created.value.conversation.id as string
    expect(members(await head(cat, group))).toEqual([ann.user, ben.user, cat.user].sort())
    const named = Object.fromEntries((await head(ben, group)).participants.map((p) => [p.id, p.display_name]))
    expect(named[ann.user]).toBe("Ann Lee")

    // Cat mentions Ann: Ann's own inbox counts one unread and one mention; Ben only the unread.
    const mention = await send(cat, group, "Ann can you book?", [{ start: 0, length: 3, mention: ann.user }])
    expect(await inboxEntry(ann, group, (e) => e?.last_seq === mention.seq)).toMatchObject({ kind: "group", title: "Trip", unread: 1, mentions: 1 })
    expect(await inboxEntry(ben, group, (e) => e?.last_seq === mention.seq)).toMatchObject({ unread: 1, mentions: 0 })

    // Any member renames; everyone's inbox shows the new name.
    expect((await op(ben.token, "title.set", { conversation: group, title: "Lisbon trip" })).error).toBeUndefined()
    expect(await inboxEntry(cat, group, (e) => e?.title === "Lisbon trip")).toMatchObject({ title: "Lisbon trip" })

    // Ben reaches only his own teams and contacts: Dee is Ann's teammate, not his, so he gets the
    // same answer as for a stranger (the Mac then offers an email invite). Ann adds her.
    expect((await op(ben.token, "participants.add", { conversation: group, participant: human(dee) })).error?.code).toBe("not_reachable")
    expect((await op(ann.token, "participants.add", { conversation: group, participant: human(dee) })).error).toBeUndefined()
    expect(await inboxEntry(dee, group)).toMatchObject({ kind: "group", title: "Lisbon trip" })
    await send(dee, group, "count me in")

    // Ben leaves: he can no longer send or read; the others see him gone.
    expect((await op(ben.token, "participants.remove", { conversation: group, participant: ben.user })).error).toBeUndefined()
    const after = await send(ann, group, "bye Ben")
    expect((await op(ben.token, "message.send", { conversation: group, client_msg_id: "late", parts: [text("wait")] }, "late")).error).toBeDefined()
    expect(members(await head(ann, group))).toEqual([ann.user, cat.user, dee.user].sort())
    expect(await inboxEntry(dee, group, (e) => e?.last_seq === after.seq)).toBeDefined()

    // Only the owner removes someone else: Dee cannot remove Cat, Ann can.
    expect((await op(dee.token, "participants.remove", { conversation: group, participant: cat.user })).error).toBeDefined()
    expect((await op(ann.token, "participants.remove", { conversation: group, participant: cat.user })).error).toBeUndefined()
    expect(members(await head(dee, group))).toEqual([ann.user, dee.user].sort())

    // Dee's history has every message from the start (history_visible defaults to all).
    expect((await history(dee, group)).map((m) => m.parts[0]?.text)).toEqual(["Ann can you book?", "count me in", "bye Ben"])
  })
})
