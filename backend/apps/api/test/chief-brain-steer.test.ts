import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterEach, describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A message that arrives while a Cloud Chief turn runs joins that turn after its current model or
 * tool step (spec 7), instead of waiting for the turn to end (parity run 2026-10-16: "12 x 12" was
 * answered 155 s later, by a second turn). One run answers both; its one reply answers the later
 * message. Fake model (SLOW streams over a few seconds), real Worker boundary.
 */const testEnv = env as unknown as Record<string, any>
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

describe("a message sent while a Cloud Chief turn runs joins that turn", { timeout: 120_000 }, () => {
  it("answers the later message in the same run, not in a second turn after the first ends", async () => {
    const token = await sessionToken("brain-steer")
    const user = (await op(token, "user.ensure", {})).value.id as string
    const chief = (await op(token, "chief.create", { display_name: "Steer Chief" }, "chief-steer")).value as { id: string; main_conversation: string }
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    let on = { status: 0, json: {} as any }
    for (let i = 0; i < 20 && on.status !== 200; i++) [await fireAlarm(userDO), (on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true }))]
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
    const runs = async () => (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    // A slow first answer (the fake streams SLOW turns over a few seconds).
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "s1", parts: [{ type: "text", text: `SLOW tell me about ${"releases ".repeat(25)}` }] }, "s1")).ok).toBe(true)
    for (let i = 0; i < 300 && !(await runs()).some((r) => r.status === "running"); i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
    // While it runs: a second, short question.
    expect((await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: "s2", parts: [{ type: "text", text: "and 12 x 12?" }] }, "s2")).ok).toBe(true)
    for (let i = 0; i < 400 && !(await history(token, chief.main_conversation)).some((m) => m.author === chief.id); i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
    for (let i = 0; i < 50; i++) [await fireAlarm(conv), await new Promise((r) => setTimeout(r, 20))]
    const all = await runs()
    // One run answered both messages; its reply answers the later one.
    expect(all.map((r) => r.status), JSON.stringify(all.map((r) => ({ id: r.id, s: r.status, a: r.answers })))).toEqual(["done"])
    expect(all[0].answers).toHaveLength(2)
    const replies = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
    expect(replies).toHaveLength(1)
    expect(replies[0].parts[0].text).toContain("12 x 12")
  })
})
