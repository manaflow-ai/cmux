import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { memberUpsert } from "../src/domains/team-members.ts"

/**
 * One Chief, several people (cmux#25569): the Chief's owner shares the Chief's own conversation with
 * teammates. Everything goes through the product routes as each person (POST /v1/ops, /v1/read, the
 * conversation socket); the fake model only.
 *
 * - Only the owner shares it, only with people of a shared team; nobody else reads it.
 * - A teammate sees what is said after they join, not the owner's earlier one-to-one history.
 * - Each member's socket gets the other's message live; every message carries its author.
 * - The Chief answers every person there, as a reply to the message it answers, with the author named.
 * - The Chief keeps its owner's grants: a teammate's effect request gets the owner-approval answer.
 * - The owner turns a teammate read-only or removes them; a removed teammate reads nothing more.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sessionToken = async (sub: string, name: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const read = (token: string, name: string, params: unknown) => http("POST", "/v1/read", token, { op: name, params })
const history = async (token: string, conversation: string) => {
  const res = await read(token, "conversation.history", { conversation, limit: 100 })
  expect(res.status, JSON.stringify(res.json)).toBe(200)
  return res.json.value.messages as Array<any>
}

interface Person { token: string; user: string; team: string; name: string }
const person = async (sub: string, name: string): Promise<Person> => {
  const token = await sessionToken(sub, name)
  const ensured = (await op(token, "user.ensure", {})).value
  return { token, user: ensured.id as string, team: ensured.personal_team as string, name }
}

const brainOf = (chief: string, conversation: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`))
const userDO = (user: string) => testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))

/** Drives the conversation outbox, the brain and the members' UserDOs until `pred` holds (bounded). */
const until = async <T,>(conversation: string, chief: string, users: ReadonlyArray<string>, probe: () => Promise<T>, pred: (v: T) => boolean, what: string): Promise<T> => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  let last: T | undefined
  for (let i = 0; i < 300; i++) {
    last = await probe()
    if (pred(last)) return last
    await fireAlarm(conv)
    if (i % 10 === 9) {
      await fireAlarm(brainOf(chief, conversation))
      for (const u of users) await fireAlarm(userDO(u))
    }
    await new Promise((r) => setTimeout(r, 40))
  }
  throw new Error(`${what}: ${JSON.stringify(last)?.slice(0, 2000)}`)
}

const connect = async (id: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${id}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  if (res.status !== 101) return { status: res.status, frames: [] as Array<any>, ws: undefined }
  const ws = res.webSocket!
  const frames: Array<any> = []
  ws.addEventListener("message", (e) => frames.push({ ...JSON.parse(e.data as string), _ms: Date.now() }))
  ws.accept()
  ws.send(JSON.stringify({ t: "subscribe" }))
  return { status: res.status, frames, ws }
}

const say = async (p: Person, conversation: string, text: string) => {
  const key = crypto.randomUUID()
  const sent = await op(p.token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
  expect(sent.ok, JSON.stringify(sent)).toBe(true)
  return sent.value as { message_id: string; seq: number }
}
const spawns = (chief: string, conversation: string) =>
  runInDurableObject(brainOf(chief, conversation), async (_i, state) => state.storage.sql.exec<{ task: string }>(`SELECT task FROM cb_spawn ORDER BY n`).toArray().map((r) => r.task))
const human = (p: Person) => ({ id: p.user, kind: "human", display_name: p.name })
const inboxEntry = async (p: Person, conversation: string) =>
  ((await read(p.token, "inbox.list", { limit: 50 })).json.value?.entries ?? []).find((e: any) => e.conversation === conversation) as { kind?: string; preview?: string; last_author?: string } | undefined

describe("Chief multiplayer: several people in one Chief's conversation", { timeout: 180_000 }, () => {
  it("the owner shares the Chief with teammates: live for each, attributed, answered by name, owner-only effects, no access for others", async () => {
    const ann = await person("share-ann", "Ann Lee")
    const ben = await person("share-ben", "Ben Ross")
    const carol = await person("share-carol", "Carol Diaz")
    const dave = await person("share-dave", "Dave Kim")
    // Ben and Carol are members of Ann's team (the Stack mirror's result); Dave is not.
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(ann.team)), async (instance) => {
      instance.boundEngine.rows.apply([memberUpsert({ user: ben.user, role: "member", display_name: ben.name }), memberUpsert({ user: carol.user, role: "member", display_name: carol.name })])
    })
    const chief = (await op(ann.token, "chief.create", { display_name: "Atlas" }, "chief-share-ann")).value as { id: string; main_conversation: string; display_name: string }
    const conversation = chief.main_conversation
    for (let i = 0; i < 20; i++) {
      await fireAlarm(userDO(ann.user))
      if ((await read(ann.token, "conversation.history", { conversation, limit: 1 })).status === 200) break
    }
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, ann.token, { enabled: true })).status).toBe(200)
    const members = [ann.user, ben.user]

    // Ann's one-to-one talk with her Chief before she shares it.
    const before = await say(ann, conversation, "private: my review notes")
    await until(conversation, chief.id, [ann.user], () => history(ann.token, conversation), (x) => x.some((m) => m.author === chief.id), "Atlas answers Ann alone")

    // Before it is shared nobody but Ann reads it, over the API or the socket.
    expect((await read(ben.token, "conversation.history", { conversation, limit: 10 })).status).not.toBe(200)
    expect((await connect(conversation, ben.token)).status).not.toBe(101)

    // Only Ann shares it, only inside a team, never as an admin and never another agent.
    expect((await op(ben.token, "participants.add", { conversation, participant: human(ben) })).ok).not.toBe(true)
    expect((await op(ann.token, "participants.add", { conversation, participant: human(dave) })).error?.code).toBe("not_reachable")
    expect((await op(ann.token, "participants.add", { conversation, participant: human(ben), role: "admin" })).ok).not.toBe(true)
    const shared = await op(ann.token, "participants.add", { conversation, participant: human(ben) })
    expect(shared.ok, JSON.stringify(shared)).toBe(true)
    // Ben cannot share it further.
    expect((await op(ben.token, "participants.add", { conversation, participant: human(carol) })).error?.code).toBe("forbidden")

    // Ann keeps it as her Chief; for Ben it is a group with someone else's Chief.
    const [annRow, benRow] = await until(conversation, chief.id, members, async () => [await inboxEntry(ann, conversation), await inboxEntry(ben, conversation)], (k) => k[0]?.kind === "chief" && k[1]?.kind === "group", "inbox kinds")
    // Ben's first row shows nothing from before he joined (since_join), not Ann's last private line.
    expect(JSON.stringify(benRow)).not.toContain("private")
    expect(annRow).toBeDefined()

    // Live: each member's socket gets the other's message within a second, with its author.
    const annLive = await connect(conversation, ann.token)
    const benLive = await connect(conversation, ben.token)
    expect([annLive.status, benLive.status]).toEqual([101, 101])
    const delivered = async (frames: Array<any>, id: string, sentAt: number) => {
      for (let i = 0; i < 100; i++) {
        const f = frames.find((x) => x.t === "event" && JSON.stringify(x).includes(id))
        if (f) return f._ms - sentAt
        await new Promise((r) => setTimeout(r, 10))
      }
      return Number.POSITIVE_INFINITY
    }
    let at = Date.now()
    const fromAnn = await say(ann, conversation, "morning, Ben is here too")
    expect(await delivered(benLive.frames, fromAnn.message_id, at)).toBeLessThan(1000)
    // The Chief answers Ann first (one turn at a time, so Ben's message gets its own turn below).
    await until(conversation, chief.id, members, () => history(ann.token, conversation), (x) => x.some((m) => m.author === chief.id && m.reply_to?.message_id === fromAnn.message_id), "Atlas answers Ann")
    at = Date.now()
    const fromBen = await say(ben, conversation, "hi Atlas, what is the release status?")
    expect(await delivered(annLive.frames, fromBen.message_id, at)).toBeLessThan(1000)

    // The Chief answers Ben (not only its owner) as a reply to Ben's message, and knows who wrote it.
    let h = await until(conversation, chief.id, members, () => history(ann.token, conversation), (x) => x.some((m) => m.author === chief.id && m.reply_to?.message_id === fromBen.message_id), "Atlas answers Ben")
    const toBen = h.find((m) => m.author === chief.id && m.reply_to?.message_id === fromBen.message_id)
    expect(toBen.parts[0].text).toContain("Ben Ross")
    expect(toBen.parts[0].text).not.toContain("Ben Ross (your owner)")
    expect(toBen.thread_root).toBeUndefined()
    // Every message names its author. Ben sees everything since he joined, and not Ann's earlier talk.
    expect(h.find((m) => m.id === fromAnn.message_id)?.author).toBe(ann.user)
    expect(h.find((m) => m.id === fromBen.message_id)?.author).toBe(ben.user)
    const benSees = (await history(ben.token, conversation)).map((m) => m.id)
    const annSees = (await history(ann.token, conversation)).map((m) => m.id)
    expect(benSees).toContain(fromAnn.message_id)
    expect(benSees).not.toContain(before.message_id)
    expect(annSees).toContain(before.message_id)
    expect(benSees.every((id) => annSees.includes(id))).toBe(true)

    // Ben asks the Chief for an effect: it is Ann's Chief, so it asks Ann and nothing runs.
    const benAsk = await say(ben, conversation, `tool:spawn ${JSON.stringify({ tasks: ["ben wants a deploy"] })}`)
    h = await until(conversation, chief.id, members, () => history(ann.token, conversation), (x) => x.some((m) => m.author === chief.id && m.reply_to?.message_id === benAsk.message_id), "Atlas answers Ben's request")
    expect(JSON.stringify(h.find((m) => m.author === chief.id && m.reply_to?.message_id === benAsk.message_id)?.parts)).toContain("owner approval required")
    expect(await spawns(chief.id, conversation)).toEqual([])
    // Ann's own request runs, and her message is marked as the owner's.
    const annAsk = await say(ann, conversation, `tool:spawn ${JSON.stringify({ tasks: ["ann's own task"] })}`)
    h = await until(conversation, chief.id, members, () => history(ann.token, conversation), (x) => x.some((m) => m.author === chief.id && m.reply_to?.message_id === annAsk.message_id), "Atlas answers Ann")
    expect(JSON.stringify(h.find((m) => m.author === chief.id && m.reply_to?.message_id === annAsk.message_id)?.parts)).not.toContain("owner approval required")
    expect(await spawns(chief.id, conversation)).toEqual(["ann's own task"])

    // Carol is on the team but was not added: she reads nothing.
    expect((await read(carol.token, "conversation.history", { conversation, limit: 10 })).status).not.toBe(200)
    expect((await connect(conversation, carol.token)).status).not.toBe(101)

    // Ann makes Ben read-only: he still sees it but cannot steer the Chief.
    expect((await op(ann.token, "participants.set_role", { conversation, participant: ben.user, role: "read_only" })).ok).toBe(true)
    const key = crypto.randomUUID()
    expect((await op(ben.token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text: "can I still talk?" }] }, key)).error?.code).toBe("read_only")
    expect((await read(ben.token, "conversation.history", { conversation, limit: 10 })).status).toBe(200)

    // Ann removes Ben: he reads nothing more, and the Chief and Ann stay.
    expect((await op(ann.token, "participants.remove", { conversation, participant: chief.id })).ok).not.toBe(true)
    expect((await op(ann.token, "participants.remove", { conversation, participant: ben.user })).ok).toBe(true)
    expect((await read(ben.token, "conversation.history", { conversation, limit: 10 })).status).not.toBe(200)
    annLive.ws?.close()
    benLive.ws?.close()
  })
})
