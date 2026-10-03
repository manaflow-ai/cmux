import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/** Chief records in UserDO (chief-mac.md section 9) through the API, and their MuxDO binding. */
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

describe("chief records", { timeout: 60_000 }, () => {
  it("one default, update moves it, archive refuses the default, restore within 30 days, list", async () => {
    const t = await sessionToken("chief-owner")
    const user = (await op(t, "user.ensure", {})).json.value.id as string
    const first = (await op(t, "chief.create", {}, "chief-default")).json
    expect(first.ok).toBe(true)
    expect(first.value).toMatchObject({ display_name: "Chief", is_default: true, brain: "cloud", rev: 1, owner_user: user, archived_at: null, main_conversation: null })
    expect(first.value.id).toMatch(/^agent_[0-9A-HJKMNP-TV-Z]{26}$/)
    // The fixed key replays the same default chief.
    expect((await op(t, "chief.create", {}, "chief-default")).json).toMatchObject({ replayed: true, value: { id: first.value.id } })
    const second = (await op(t, "chief.create", { display_name: "Research" })).json.value
    expect(second.is_default).toBe(false)

    expect((await op(t, "chief.archive", { chief: first.value.id, expected_rev: 1 })).json.error.code).toBe("chief_is_default")
    expect((await op(t, "chief.update", { chief: second.id, expected_rev: 9, is_default: true })).json.error.code).toBe("revision.conflict")
    const moved = (await op(t, "chief.update", { chief: second.id, expected_rev: 1, is_default: true })).json.value
    expect(moved).toMatchObject({ is_default: true, rev: 2 })
    const archived = (await op(t, "chief.archive", { chief: first.value.id, expected_rev: 2 })).json
    expect(archived.value).toMatchObject({ is_default: false })
    expect(archived.value.archived_at).not.toBeNull()
    expect((await call("/v1/read", t, { op: "chief.list", params: {} })).json.value.chiefs.map((c: { id: string }) => c.id)).toEqual([second.id])
    const restored = (await op(t, "chief.update", { chief: first.value.id, expected_rev: 3, archived: false })).json.value
    expect(restored.archived_at).toBeNull()
    const list = (await call("/v1/read", t, { op: "chief.list", params: {} })).json.value
    expect(list.chiefs.map((c: { id: string; is_default: boolean }) => [c.id, c.is_default])).toEqual([[second.id, true], [first.value.id, false]])
  })

  it("a new chief's MuxDO is bound to its owner and receives the user's level", async () => {
    const t = await sessionToken("chief-mux")
    const user = (await op(t, "user.ensure", {})).json.value.id as string
    const chief = (await op(t, "chief.create", {}, "chief-default")).json.value
    // The outbox drains on UserDO's alarm; the binding lands on the chief's MuxDO.
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    const mux = testEnv.MUX_DO.get(testEnv.MUX_DO.idFromName(chief.id)) as unknown as { readOp(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean; value: unknown }> }
    let read = { ok: false, value: undefined as unknown }
    for (let i = 0; i < 20 && !read.ok; i++) {
      await runDurableObjectAlarm(userDO)
      read = await mux.readOp(chief.id, { identity: `session:${user}`, kind: "session", user }, "mux.queue", {})
    }
    expect(read.ok).toBe(true)
    const head = read.value
    expect(head).toMatchObject({ agent: chief.id, owner_user: user, brain: "cloud" })
    // A safer level set by the user reaches the chief (sync on change only; strict is already in effect, so no new rev).
    const view = (await call("/v1/read", t, { op: "user.text_confirm.get", params: {} })).json.value
    expect(view.level).toBe("strict")
  })
})
