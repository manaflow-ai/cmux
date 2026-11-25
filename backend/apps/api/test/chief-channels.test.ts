import { env, exports } from "cloudflare:workers"

import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"

/** Chief channels (plans/cmux-next/chief-channels-DESIGN.md): a group conversation with its own scoped Chief. */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; MUX_DO: DurableObjectNamespace }
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
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
type MuxStub = { readOp(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean; value: any }> }

describe("chief channels", { timeout: 60_000 }, () => {
  it("channel.create makes a group conversation owned by the creator with its own Chief, scoped to it", async () => {
    const t = await sessionToken("channel-owner")
    const user = (await op(t, "user.ensure", {})).json.value.id as string
    await op(t, "chief.create", {}, "chief-default")
    const made = (await op(t, "channel.create", { title: "Launch", display_name: "Launch Chief" }, "channel-launch")).json
    expect(made.ok, JSON.stringify(made)).toBe(true)
    const chief = made.value
    expect(chief).toMatchObject({ display_name: "Launch Chief", is_default: false, owner_user: user, channel: { title: "Launch" } })
    expect(chief.channel.conversation).toMatch(/^conv_[0-9A-HJKMNP-TV-Z]{26}$/)
    expect(chief.main_conversation).toBe(chief.channel.conversation)
    // The same key replays the same channel.
    expect((await op(t, "channel.create", { title: "Launch", display_name: "Launch Chief" }, "channel-launch")).json).toMatchObject({ replayed: true, value: { id: chief.id } })

    // The outbox creates the conversation (a group the creator owns, the Chief a member) and binds the scoped MuxDO.
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief.id)) as unknown as MuxStub
    let snap: any = {}
    let head: { ok: boolean; value: any } = { ok: false, value: undefined }
    for (let i = 0; i < 20 && (!snap.value?.state || !head.ok); i++) {
      await fireAlarm(userDO)
      snap = (await call("/v1/read", t, { op: "conversation.snapshot", params: { conversation: chief.channel.conversation } })).json
      head = await mux.readOp(chief.id, { identity: `session:${user}`, kind: "session", user }, "mux.queue", {})
    }
    // A snapshot reply is {op, value: {t: "snapshot", state}}.
    const conv = snap.value?.state
    expect(conv, JSON.stringify(snap)).toBeDefined()
    expect(conv).toMatchObject({ id: chief.channel.conversation, kind: "group", title: "Launch", channel_chief: chief.id, created_by: user })
    expect(conv.participants.map((p: { id: string; role: string }) => [p.id, p.role]).sort()).toEqual([[chief.id, "member"], [user, "owner"]].sort())
    expect(head.value).toMatchObject({ agent: chief.id, owner_user: user, brain: "cloud", channel: chief.channel.conversation })

    // The owner talks in the channel; chief.list names the channel.
    expect((await op(t, "message.send", { conversation: conv.id, client_msg_id: "channel-hi", parts: [{ type: "text", text: "hi" }] }, "channel-hi")).json.ok).toBe(true)
    const list = (await call("/v1/read", t, { op: "chief.list", params: {} })).json.value.chiefs
    expect(list.find((c: { id: string }) => c.id === chief.id)).toMatchObject({ channel: { conversation: conv.id, title: "Launch" } })
  })

  it("refuses a channel without a title, and anyone but the user's own session", async () => {
    const t = await sessionToken("channel-bad")
    await op(t, "user.ensure", {})
    const bad = (await op(t, "channel.create", { title: "  " })).json
    expect(bad.ok).toBe(false)
    expect(bad.error.code).toBe("validation.invalid")
  })
})
