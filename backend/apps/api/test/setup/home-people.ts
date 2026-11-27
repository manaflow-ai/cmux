import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation as homeConversation } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { expect } from "vitest"
import { memberUpsert } from "../../src/domains/team-members.ts"
import { userIdFor } from "../../src/domains/user.ts"
import { fireAlarm } from "./alarm.ts"

/**
 * Signed-in people for the Home DM and group end-to-end tests: each one calls the public routes
 * (`POST /v1/ops`, `POST /v1/read`, `GET /v1/wire/conv/<id>`) with its own fake Stack session.
 */
export const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
export const worker = (exports as unknown as { default: Fetcher }).default
export const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
export const sessionToken = async (sub: string, email: string, name: string) =>
  new SignJWT({ email, email_verified: true, name })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
export const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return (await res.json().catch(() => null)) as any
}
export const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
export const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })

export interface Person {
  readonly token: string
  readonly user: string
  readonly team: string
  readonly name: string
  readonly email: string
}
export const signIn = async (tag: string, name: string): Promise<Person> => {
  const sub = `e2e-${tag}`
  const email = `${tag}@${tag}.test`
  const token = await sessionToken(sub, email, name)
  const ensured = await op(token, "user.ensure", {})
  expect(ensured.ok).toBe(true)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub), team: ensured.value.personal_team as string, name, email }
}
/** `member` joins `owner`'s team (team invites are not built; TeamDO rows are seeded as in home-reach.test.ts). */
export const joinTeam = async (owner: Person, member: Person) => {
  await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(owner.team)), async (instance) => {
    instance.boundEngine.rows.apply([memberUpsert({ user: member.user, role: "member", display_name: member.name })])
  })
}
export const human = (p: Person) => ({ id: p.user, kind: "human", display_name: p.name })
export const text = (body: string, runs?: unknown) => ({ type: "text", text: body, ...(runs ? { runs } : {}) })
export const send = async (p: Person, conversation: string, body: string, runs?: unknown) => {
  const key = crypto.randomUUID()
  const sent = await op(p.token, "message.send", { conversation, client_msg_id: key, parts: [text(body, runs)] }, key)
  expect(sent.error).toBeUndefined()
  return sent.value as { message_id: string; seq: number }
}
export const drain = (conversation: string) => fireAlarm(testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation)))
export type Entry = { conversation: string; kind: string; title: string; unread: number; mentions: number; muted: boolean; muted_until?: number; dm_peer?: string; preview: string; last_seq: number }
/** `who`'s own inbox entry for `conversation`, read once the outbox drained into it and `ready` holds. */
export const inboxEntry = async (who: Person, conversation: string, ready: (e: Entry | undefined) => boolean = (e) => e !== undefined): Promise<Entry | undefined> => {
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
export const history = async (who: Person, conversation: string) => {
  const page = await read(who.token, "conversation.history", { conversation, limit: 50 })
  expect(page.error).toBeUndefined()
  return page.value.messages as Array<{ author: string; seq: number; parts: Array<{ text?: string }> }>
}
export const head = async (who: Person, conversation: string) => {
  const snap = await read(who.token, "conversation.snapshot", { conversation, tail: 0 })
  expect(snap.error).toBeUndefined()
  return snap.value.state as homeConversation.ConversationHead
}
export const members = (state: homeConversation.ConversationHead) =>
  state.participants.filter((p) => p.left_at === undefined && p.kind === "human").map((p) => p.id).sort()

/** A conversation socket as the Mac's daemon opens it, with a wait for the next matching frame. */
export const connect = async (conversation: string, who: Person) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${conversation}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${who.token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  const closed = new Promise<{ code: number; reason: string }>((resolve) => ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })))
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
  return { ws, until, closed, frames, send: (frame: unknown) => ws.send(JSON.stringify(frame)) }
}
