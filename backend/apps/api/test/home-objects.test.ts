import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { conversation, invites } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { fireAlarm } from "./setup/alarm.ts"

const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
/** DO RPC stubs erase method types; these tests call the methods the classes define. */
type Stub = { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string }> }>; readOp(e: string, p: Principal, op: string, params: unknown): Promise<unknown>; readInbox(e: string, p: Principal, op: string, params: unknown): Promise<unknown>; submitInbox(e: string, p: Principal, f: unknown): Promise<unknown>; card(e: string): Promise<{ first_name: string } | null> }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const stub = (ns: any, name: string): Stub & DurableObjectStub => ns.get(ns.idFromName(name))

const stackToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: "Alice Example" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const session = (user: string): Principal => ({ kind: "session", identity: `session:${user}`, user, team: personalTeamIdFor(user), display_name: "Alice Example", email: "a@example.com", email_verified: true })

let n = 0
const convId = () => `conv_01J0000000000000000HOME${String(n++).padStart(2, "0")}`.slice(0, 31)

describe("Home objects: ConversationDO fan-out to the UserDO inbox stream (E2, E4)", () => {

  it("the inbox stream works on the user socket: subscribe gets a snapshot, a bump arrives as an event", async () => {
    const sub = "home-wire"
    const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
    const token = await stackToken(sub)
    await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: "ensure" }) })
    const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
    const ws = res.webSocket!
    const frames: Array<any> = []
    let wake: (() => void) | undefined
    ws.addEventListener("message", (e) => {
      frames.push(JSON.parse(e.data as string))
      wake?.()
    })
    ws.accept()
    const until = async (pred: () => boolean) => {
      while (!pred()) await new Promise<void>((r) => (wake = r))
    }
    ws.send(JSON.stringify({ t: "subscribe", stream: `inbox:${user}`, pending: [] }))
    await until(() => frames.some((f) => f.t === "snapshot" && f.stream === `inbox:${user}`))

    const id = convId()
    const conv = stub(testEnv.CONVERSATION_DO, id)
    await conv.submit(id, session(user), { t: "op", op: "conversation.create", params: { id, kind: "group", title: "Wire", participants: [{ id: user, kind: "human", display_name: "Alice Example" }] }, idempotency_key: "c" })
    await conv.submit(id, session(user), { t: "op", op: "message.send", params: { client_msg_id: "w1", parts: [{ type: "text", text: "over the wire" }] }, idempotency_key: "w1" })
    await fireAlarm(conv)
    await until(() => frames.some((f) => f.t === "event" && f.stream === `inbox:${user}` && f.op === "inbox.bump"))
    // The primary stream's events never leak into the inbox subscription and vice versa.
    expect(frames.filter((f) => f.t === "event").every((f) => f.stream === `inbox:${user}`)).toBe(true)
    ws.close()
  })
})

