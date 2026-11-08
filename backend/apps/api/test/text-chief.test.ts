import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { invites } from "@cmux/home-core"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { chiefPrincipal } from "../src/chief-brain/brain-io.ts"
import { handleSendblueHook } from "../src/home-text.ts"
import { fireAlarm } from "./setup/alarm.ts"

/** Texting Chief on one shared SendBlue line (text-chief.ts): sender -> primary Chief -> reply as a text. */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; HOME_ADDRESS_KEY: string; ADDRESS_DO: any; CONVERSATION_DO: any; USER_DO: any }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: "Text Owner" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: key, origin: "user" }) })
  return (await res.json()) as any
}

const LINE = "+14155550199"
const SECRET = "whsec-text-chief-test"
const ON = { TEXT_CHIEF: "on", SENDBLUE_API_KEY: "sb_key", SENDBLUE_API_SECRET: "sb_secret", SENDBLUE_FROM_NUMBER: LINE, SENDBLUE_WEBHOOK_SECRET: SECRET }

interface Sent { url: string; body: { number: string; from_number: string; content?: string } }

/** A person with two Chiefs, their phone allowed by TEXT_CHIEF_PEOPLE, and fakes for SendBlue. */
const setup = async (sub: string, phone: string) => {
  const token = await sessionToken(sub)
  await op(token, "user.ensure", {})
  const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
  const main = (await op(token, "chief.create", { display_name: "Chief" })).value as { id: string; main_conversation: string }
  const muse = (await op(token, "chief.create", { display_name: "Muse" })).value as { id: string; main_conversation: string }
  const people = JSON.stringify({ [phone]: user })
  const cfg = { ...ON, TEXT_CHIEF_PEOPLE: people }
  const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(phone) as invites.Address)
  const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
  const sent: Array<Sent> = []
  await runInDurableObject(addr, async (i) => {
    i.env = { ...i.env, ...cfg }
    i.fetcher = async (url: string, init: { body: string }) => {
      sent.push({ url, body: JSON.parse(init.body) })
      return { status: 200, json: async () => ({ message_handle: `out-${sent.length}`, status: "QUEUED" }) }
    }
  })
  const convOf = (id: string) => testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
  const userDo = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 5; i++) await fireAlarm(userDo)
  for (const c of [main, muse]) await runInDurableObject(convOf(c.main_conversation), async (i) => void (i.env = { ...i.env, ...cfg }))
  // SendBlue's own record of each handle (the route reads it back; the webhook body is not trusted).
  const records = new Map<string, Record<string, unknown>>()
  const sendblueApi = (async (url: string) => {
    const handle = String(url).split("/").pop()!
    const r = records.get(handle)
    return r ? new Response(JSON.stringify(r), { status: 200 }) : new Response("{}", { status: 404 })
  }) as unknown as typeof fetch
  let n = 0
  const text = async (content: string, from = phone) => {
    const handle = `${sub}-in-${++n}`
    records.set(handle, { message_handle: handle, status: "RECEIVED", number: from, is_outbound: false, content, opted_out: false, to_number: LINE, service: "iMessage", date_sent: new Date().toISOString() })
    const req = new Request("https://api.test/v1/hooks/sendblue", { method: "POST", headers: { "sb-signing-secret": SECRET, "content-type": "application/json" }, body: JSON.stringify({ message_handle: handle }) })
    const res = await handleSendblueHook(req, { ...(env as never as object), ...cfg } as never, sendblueApi)
    return { res, handle }
  }
  const messages = (conv: string) => runInDurableObject(convOf(conv), async (i) => (i.boundEngine.rows.range("msg", { limit: 50 }) as Array<{ row: { id: string; author: string; parts: Array<{ text?: string }> } }>).map((r) => r.row))
  const chiefSays = (c: { id: string; main_conversation: string }, words: string) => {
    const key = crypto.randomUUID()
    return convOf(c.main_conversation).submit(c.main_conversation, chiefPrincipal(c.id, user), { t: "op", op: "message.send", params: { client_msg_id: key, parts: [{ type: "text", text: words }] }, idempotency_key: key, origin: "script" })
  }
  const settle = () => runInDurableObject(addr, async () => undefined)
  return { token, user, main, muse, sent, text, messages, chiefSays, settle, records, convOf }
}

describe("texting Chief on one shared line", { timeout: 60_000 }, () => {
  it("a text reaches the primary Chief's conversation; the Chief's reply goes back as a text, once", async () => {
    const p = await setup("text-chief-1", "+14155550301")
    const { res } = await p.text("what's on today?")
    expect(res.status).toBe(200)
    const msgs = await p.messages(p.main.main_conversation)
    expect(msgs.some((m) => m.author === p.user && m.parts[0]?.text === "what's on today?")).toBe(true)
    // The iMessage typing bubble went out first.
    expect(p.sent.some((s) => s.url.endsWith("/api/send-typing-indicator") && s.body.number === "+14155550301")).toBe(true)
    await p.chiefSays(p.main, "Two meetings and a dentist.")
    // ConversationDO forwards replies in waitUntil; an AddressDO no-op can arrive first.
    await expect.poll(() => p.sent.filter((s) => s.url.endsWith("/api/send-message")), { timeout: 5_000 }).toHaveLength(1)
    const replies = p.sent.filter((s) => s.url.endsWith("/api/send-message"))
    expect(replies[0]!.body).toMatchObject({ number: "+14155550301", from_number: LINE, content: "Two meetings and a dentist." })
  })

  it("a repeated webhook for the same handle is routed once", async () => {
    const p = await setup("text-chief-2", "+14155550302")
    const { handle } = await p.text("hello")
    const req = new Request("https://api.test/v1/hooks/sendblue", { method: "POST", headers: { "sb-signing-secret": SECRET }, body: JSON.stringify({ message_handle: handle }) })
    const sendblueApi = (async () => new Response(JSON.stringify(p.records.get(handle)), { status: 200 })) as unknown as typeof fetch
    await handleSendblueHook(req, { ...(env as never as object), ...ON, TEXT_CHIEF_PEOPLE: JSON.stringify({ "+14155550302": p.user }) } as never, sendblueApi)
    const msgs = await p.messages(p.main.main_conversation)
    expect(msgs.filter((m) => m.parts[0]?.text === "hello")).toHaveLength(1)
  })

  it("@name asks another Chief once, its reply carries its name, and the primary stays", async () => {
    const p = await setup("text-chief-3", "+14155550303")
    await p.text("@muse a haiku about CI")
    expect((await p.messages(p.muse.main_conversation)).some((m) => m.parts[0]?.text === "a haiku about CI")).toBe(true)
    await p.chiefSays(p.muse, "green checks bloom")
    await expect.poll(() => p.sent.filter((s) => s.url.endsWith("/api/send-message")).at(-1)?.body.content, { timeout: 5_000 }).toBe("Muse: green checks bloom")
    await p.text("and the weather?")
    expect((await p.messages(p.main.main_conversation)).some((m) => m.parts[0]?.text === "and the weather?")).toBe(true)
  })

  it("/primary muse makes Muse primary: later texts go to Muse", async () => {
    const p = await setup("text-chief-4", "+14155550304")
    await p.text("/primary muse")
    expect(p.sent.filter((s) => s.url.endsWith("/api/send-message")).at(-1)!.body.content).toMatch(/Muse is now your primary Chief/)
    const read = await testEnv.USER_DO.get(testEnv.USER_DO.idFromName(p.user)).readOp(p.user, { identity: `session:${p.user}`, kind: "session", user: p.user }, "chief.list", {})
    const list = read.value as { chiefs: Array<{ id: string; is_default: boolean }> }
    expect(list.chiefs.find((c) => c.id === p.muse.id)?.is_default).toBe(true)
    await p.text("hi muse")
    expect((await p.messages(p.muse.main_conversation)).some((m) => m.parts[0]?.text === "hi muse")).toBe(true)
  })

  it("an unknown sender gets one polite reply and nothing else", async () => {
    const p = await setup("text-chief-5", "+14155550305")
    const stranger = "+14155550399"
    const address = invites.addressId(testEnv.HOME_ADDRESS_KEY, invites.normalizePhone(stranger) as invites.Address)
    const addr = testEnv.ADDRESS_DO.get(testEnv.ADDRESS_DO.idFromName(address))
    const sent: Array<Sent> = []
    await runInDurableObject(addr, async (i) => {
      i.env = { ...i.env, ...ON }
      i.fetcher = async (url: string, init: { body: string }) => (sent.push({ url, body: JSON.parse(init.body) }), { status: 200, json: async () => ({ message_handle: "x", status: "QUEUED" }) })
    })
    await p.text("hey who is this", stranger)
    await p.text("hello??", stranger)
    expect(sent).toHaveLength(1)
    expect(sent[0]!.body.content).toMatch(/not linked to a cmux account/)
  })

  it("after the person writes in the app, the Chief's replies stay in the app", async () => {
    const p = await setup("text-chief-6", "+14155550306")
    await p.text("ping")
    expect((await op(p.token, "message.send", { conversation: p.main.main_conversation, client_msg_id: "app-1", parts: [{ type: "text", text: "at my desk" }] }, "app-1")).ok).toBe(true)
    await p.chiefSays(p.main, "ok")
    await p.settle()
    expect(p.sent.filter((s) => s.url.endsWith("/api/send-message"))).toHaveLength(0)
  })
})
