import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { memberUpsert } from "../src/domains/team-members.ts"

/**
 * Chief multiplayer (plans/cmux-next/chief-done.md checks 8 and 9, chief-group-chats-DESIGN.md): two
 * people of one team, each with their own Chief, in one group. Everything goes through the product
 * routes as each person (POST /v1/ops, /v1/read, PUT /v1/chiefs/<id>/brain); the fake model only.
 *
 * - Each person adds only their own Chief; nobody adds someone else's.
 * - The group's reply rule (wake_policy) decides who answers: auto = mentions only in a group,
 *   all = every Chief on every person's message, and a Chief's message never wakes the other Chief.
 * - Each Chief acts with its own owner's grants: its owner's request runs an effectful tool (spawn)
 *   with the owner as the child's owner; the other person's request to it gets the owner-approval
 *   answer and nothing runs; the owner's later confirmation runs it.
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
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 100 } })).json.value.messages as Array<any>

interface Person { token: string; user: string; team: string; name: string; chief: { id: string; main_conversation: string; display_name: string } }

const personWithChief = async (sub: string, name: string, chiefName: string): Promise<Person> => {
  const token = await sessionToken(sub, name)
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  const chief = (await op(token, "chief.create", { display_name: chiefName }, `chief-${sub}`)).value
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
  return { token, user, team: ensured.personal_team as string, name, chief }
}

const brainOf = (chief: string, conversation: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief}/${conversation}`))

/** Drives the conversation outbox and the brains until `pred` holds on the history (bounded). */
const until = async (token: string, conversation: string, chiefs: ReadonlyArray<string>, pred: (h: Array<any>) => boolean, what: string) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  for (let i = 0; i < 300; i++) {
    const h = await history(token, conversation)
    if (pred(h)) return h
    await fireAlarm(conv)
    if (i % 10 === 9) for (const c of chiefs) await fireAlarm(brainOf(c, conversation))
    await new Promise((r) => setTimeout(r, 40))
  }
  throw new Error(`${what}: ${JSON.stringify((await history(token, conversation)).map((m) => [m.author, m.parts?.[0]?.text?.slice(0, 80)]))}`)
}
/** Lets the outbox and both brains run a while, for checks that something did NOT happen. */
const settle = async (conversation: string, chiefs: ReadonlyArray<string>) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  for (let i = 0; i < 30; i++) {
    await fireAlarm(conv)
    if (i % 10 === 9) for (const c of chiefs) await fireAlarm(brainOf(c, conversation))
    await new Promise((r) => setTimeout(r, 40))
  }
}
const spawns = (chief: string, conversation: string) =>
  runInDurableObject(brainOf(chief, conversation), async (_i, state) => state.storage.sql.exec<{ task: string }>(`SELECT task FROM cb_spawn ORDER BY n`).toArray().map((r) => r.task))
const brainOwner = (chief: string, conversation: string) =>
  runInDurableObject(brainOf(chief, conversation), async (_i, state) => state.storage.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'owner'`).toArray()[0]?.value)
const by = (h: Array<any>, author: string) => h.filter((m) => m.author === author)
const mentionText = (chief: Person["chief"], text: string) => ({ type: "text", text: `@${chief.display_name} ${text}`, runs: [{ start: 0, length: chief.display_name.length + 1, mention: chief.id }] })
const say = async (p: Person, conversation: string, part: unknown) => {
  const key = crypto.randomUUID()
  const sent = await op(p.token, "message.send", { conversation, client_msg_id: key, parts: [part] }, key)
  expect(sent.ok, JSON.stringify(sent)).toBe(true)
  return sent.value as { message_id: string; seq: number }
}
const agentOf = (c: Person["chief"]) => ({ id: c.id, kind: "agent", agent_class: "mux", display_name: c.display_name })

describe("Chief multiplayer: two people, two Chiefs, one group", { timeout: 180_000 }, () => {
  it("each person brings their own Chief; the reply rule picks who answers; each Chief acts only on its own owner's word", async () => {
    const ann = await personWithChief("mp-ann", "Ann Lee", "Atlas")
    const ben = await personWithChief("mp-ben", "Ben Ross", "Bolt")
    // One team: Ben is a member of Ann's team (the Stack mirror's result).
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(ann.team)), async (instance) => {
      instance.boundEngine.rows.apply([memberUpsert({ user: ben.user, role: "member", display_name: ben.name })])
    })

    // Ann makes the group with Ben and her Chief. Ann cannot bring Ben's Chief; Ben can.
    const created = await op(ann.token, "conversation.create", {
      kind: "group",
      title: "Launch",
      participants: [{ id: ann.user, kind: "human", display_name: ann.name }, { id: ben.user, kind: "human", display_name: ben.name }, agentOf(ann.chief)]
    })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const group = created.value.conversation.id as string
    expect((await op(ann.token, "participants.add", { conversation: group, participant: agentOf(ben.chief) })).error?.code).toBe("forbidden")
    const added = await op(ben.token, "participants.add", { conversation: group, participant: agentOf(ben.chief) })
    expect(added.ok, JSON.stringify(added)).toBe(true)
    const head = (await http("POST", "/v1/read", ben.token, { op: "conversation.snapshot", params: { conversation: group, tail: 0 } })).json.value.state
    const owners = Object.fromEntries(head.participants.filter((p: any) => p.kind === "agent").map((p: any) => [p.id, p.owner_user]))
    expect(owners).toEqual({ [ann.chief.id]: ann.user, [ben.chief.id]: ben.user })
    const chiefs = [ann.chief.id, ben.chief.id]

    // auto (default) in a group of two people: a plain message wakes nobody; a mention wakes only that Chief.
    await say(ann, group, { type: "text", text: "morning all" })
    await settle(group, chiefs)
    expect((await history(ben.token, group)).filter((m) => chiefs.includes(m.author))).toHaveLength(0)
    await say(ben, group, mentionText(ben.chief, "what is on my plate?"))
    let h = await until(ann.token, group, chiefs, (x) => by(x, ben.chief.id).length >= 1, "Bolt answers its mention")
    expect(by(h, ann.chief.id)).toHaveLength(0)
    expect(by(h, ben.chief.id)[0].parts[0].text).toContain("what is on my plate?")

    // Ann asks Ben's Chief for an effect: it is Ben's Chief, so it asks Ben and nothing runs.
    await say(ann, group, mentionText(ben.chief, `tool:spawn ${JSON.stringify({ tasks: ["ann wants a deploy"] })}`))
    h = await until(ann.token, group, chiefs, (x) => by(x, ben.chief.id).length >= 2, "Bolt answers Ann")
    expect(by(h, ben.chief.id)[1].parts[0].text).toContain("owner approval required")
    expect(await spawns(ben.chief.id, group)).toEqual([])
    // Ann's own request to her own Chief runs, with Ann as the owner of what it starts.
    await say(ann, group, mentionText(ann.chief, `tool:spawn ${JSON.stringify({ tasks: ["ann's own task"] })}`))
    h = await until(ann.token, group, chiefs, (x) => by(x, ann.chief.id).length >= 1, "Atlas answers Ann")
    const atlas = JSON.stringify(by(h, ann.chief.id)[0].parts)
    expect(atlas, atlas).not.toContain("owner approval required")
    expect(await spawns(ann.chief.id, group)).toEqual(["ann's own task"])
    expect(await brainOwner(ann.chief.id, group)).toBe(ann.user)
    expect(await brainOwner(ben.chief.id, group)).toBe(ben.user)
    // A brain is idle with no queued or running message, no reply waiting to post, and every subagent reported.
    const idle = (chief: string) =>
      runInDurableObject(brainOf(chief, group), async (_i, state) => {
        const sql = state.storage.sql
        const busy = sql.exec(`SELECT 1 FROM cb_inbox WHERE state IN ('queued', 'running') UNION ALL SELECT 1 FROM cb_turn WHERE status = 'running' OR post = 'pending' UNION ALL SELECT 1 FROM cb_spawn WHERE state NOT IN ('reported', 'done', 'failed')`).toArray()
        return busy.length === 0
      })
    // Atlas finishes with its subagent first: the first round of answers to a person is free of the loop guard's
    // gap, so Atlas's thread posts can otherwise land after Ben's line and end Bolt's batch (the fake model acts
    // on a batch's last line).
    for (let i = 0; i < 60 && !(await idle(ann.chief.id)); i++) await settle(group, chiefs)
    expect(await idle(ann.chief.id)).toBe(true)
    // Ben confirms on his own Chief: now it runs, as Ben's.
    await say(ben, group, mentionText(ben.chief, `tool:spawn ${JSON.stringify({ tasks: ["approved by ben"] })}`))
    h = await until(ann.token, group, chiefs, (x) => by(x, ben.chief.id).length >= 3, "Bolt answers Ben's confirmation")
    const dump = await runInDurableObject(brainOf(ben.chief.id, group), async (_i, state) => ({
      inbox: state.storage.sql.exec("SELECT seq, woke, effect_authorized, state, turn, substr(text, 1, 90) AS text FROM cb_inbox ORDER BY n").toArray(),
      turns: state.storage.sql.exec("SELECT id, trigger_kind, effect_authorized, status, reason FROM cb_turn").toArray()
    }))
    expect(await spawns(ben.chief.id, group), JSON.stringify({ dump, bolt: by(h, ben.chief.id).map((m) => m.parts[0].text?.slice(0, 200)) })).toEqual(["approved by ben"])

    // Only the group owner (Ann) sets the reply rule; Ben is refused.
    expect((await op(ben.token, "conversation.settings.set", { conversation: group, wake_policy: "all" })).error).toBeDefined()
    expect((await op(ann.token, "conversation.settings.set", { conversation: group, wake_policy: "all" })).error).toBeUndefined()
    // all: one person's plain message wakes each Chief once (a Chief may answer it inside a running turn, with
    // a subagent's report), and no Chief's message wakes the other Chief: the group goes quiet.
    const status = await say(ben, group, { type: "text", text: "status, everyone?" })
    const took = (chief: string) =>
      runInDurableObject(brainOf(chief, group), async (_i, state) =>
        state.storage.sql.exec<{ woke: number; state: string; turn: string | null }>(`SELECT woke, state, turn FROM cb_inbox WHERE seq = ?`, status.seq).toArray())
    for (let i = 0; i < 300; i++) {
      const [a, b] = [await took(ann.chief.id), await took(ben.chief.id)]
      if (a[0]?.state === "done" && b[0]?.state === "done") break
      await settle(group, chiefs)
    }
    for (const chief of chiefs) {
      const rows = await took(chief)
      expect(rows, chief).toHaveLength(1)
      expect(rows[0], chief).toMatchObject({ woke: 1, state: "done" })
      const turn = rows[0]!.turn
      // That turn's reply reaches the group (both Chiefs answer the person at once: the gap starts after that round).
      const reply = await runInDurableObject(brainOf(chief, group), async (_i, state) => state.storage.sql.exec<{ reply: string }>(`SELECT substr(reply, 1, 120) AS reply FROM cb_turn WHERE id = ?`, turn).toArray()[0]?.reply)
      expect(reply, chief).toBeTruthy()
      await until(ann.token, group, chiefs, (x) => by(x, chief).some((m) => (m.parts[0]?.text ?? "").startsWith(reply!)), `${chief}'s answer to status is in the group`)
    }
    await settle(group, chiefs)
    h = await history(ann.token, group)
    const authorOf = new Map(h.map((m) => [m.id, m.author]))
    const crossTalk = h.filter((m) => chiefs.includes(m.author) && chiefs.includes(authorOf.get(m.reply_to?.message_id)) && authorOf.get(m.reply_to?.message_id) !== m.author)
    expect(crossTalk).toEqual([])
    // Quiet: once both brains are idle, nothing more comes.
    for (let i = 0; i < 60 && !((await idle(ann.chief.id)) && (await idle(ben.chief.id))); i++) await settle(group, chiefs)
    expect((await idle(ann.chief.id)) && (await idle(ben.chief.id))).toBe(true)
    const quiet = (await history(ann.token, group)).length
    await settle(group, chiefs)
    expect((await history(ann.token, group)).length).toBe(quiet)

    // Both people see the same transcript.
    expect((await history(ben.token, group)).map((m) => m.id)).toEqual((await history(ann.token, group)).map((m) => m.id))
  })
})
