import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A peer Chief's message (the user, 2026-10-21: "make it so it's possible for you to talk to the
 * cloud chief"): the owner's install forwards a message from the agent hub to POST
 * /v1/chiefs/<agent>/peer, and the Cloud Chief answers it in its main conversation as a woken turn.
 * Fake model only (it echoes its input).
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace; MUX_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
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
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>

/** An owner with one chief whose MuxDO is bound and whose main conversation exists. */
const ownerWithChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  const chief = (await op(token, "chief.create", { display_name: "Release Chief" }, `chief-${sub}`)).value
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  return { token, user, team: ensured.personal_team as string, chief: chief as { id: string; main_conversation: string } }
}

/** Drives the conversation's outbox (wake to MuxDO, which forwards to the brain) until the chief has answered `n` times. */
const chiefReplies = async (token: string, conversation: string, chief: string, n: number) => {
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation))
  // The chief's brain for this conversation (its own alarm runs post retries after the loop guard's 2 s gap).
  const brains = (env as unknown as { CHIEF_BRAIN_DO: DurableObjectNamespace }).CHIEF_BRAIN_DO
  const brain = brains.get(brains.idFromName(`${chief}/${conversation}`))
  for (let i = 0; i < 200; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await fireAlarm(conv)
    if (i % 10 === 9) await fireAlarm(brain)
    await new Promise((r) => setTimeout(r, 50))
  }
  const dump = await runInDurableObject(brain, async (_i, state) => ({
    turns: state.storage.sql.exec("SELECT id, status, reason, post, post_tries, last_seq FROM cb_turn").toArray(),
    inbox: state.storage.sql.exec("SELECT n, seq, state, turn FROM cb_inbox").toArray(),
    cursor: state.storage.sql.exec("SELECT * FROM cb_cursor").toArray()
  }))
  throw new Error(`the chief did not answer ${n} time(s) in ${conversation}: ${JSON.stringify(dump)}`)
}

describe("Chief brain peer notes", { timeout: 120_000 }, () => {
  it("wakes the chief on its owner's forward of a peer Chief's message, once per key", async () => {
    const { token, chief } = await ownerWithChief("brain-peer")
    const other = await sessionToken("brain-peer-other")
    await op(other, "user.ensure", {})
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)

    const note = { from: "mac-chief", text: "ping from the Mac Chief", key: "hub-1" }
    // Only the owner forwards; a bad body is refused.
    expect((await http("POST", `/v1/chiefs/${chief.id}/peer`, other, note)).status).toBe(403)
    expect((await http("POST", `/v1/chiefs/${chief.id}/peer`, token, { ...note, from: "Mac Chief" })).json.error.code).toBe("validation.invalid")
    expect((await http("GET", `/v1/chiefs/${chief.id}/peer`, token)).status).toBe(405)

    const sent = await http("POST", `/v1/chiefs/${chief.id}/peer`, token, note)
    expect(sent.status, JSON.stringify(sent.json)).toBe(200)
    expect(sent.json.value).toEqual({ conversation: chief.main_conversation, queued: true })
    const [reply] = await chiefReplies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).toContain("[chief:mac-chief] ping from the Mac Chief")
    expect(reply.parts[0].text).toContain("not the person's word")

    // A retried forward with the same key queues nothing.
    expect((await http("POST", `/v1/chiefs/${chief.id}/peer`, token, note)).json.value.queued).toBe(false)
  })
})
