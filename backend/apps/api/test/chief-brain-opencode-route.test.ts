import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, describe, expect, it } from "vitest"
import { OpencodeBrainDO } from "../src/chief-brain-opencode/brain-do.ts"
import { MODEL_UNAVAILABLE_NOTICE } from "../src/chief-brain/brain-gateway.ts"
import { messagesEffectAuthorized } from "../src/chief-brain/effect-policy.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Wake routing by brain_impl, through the product boundary (POST /v1/ops, PUT /v1/chiefs/<agent>/brain-impl):
 * with the opencode brain on (CHIEF_OPENCODE_ENABLED), a pi Chief's wake goes straight to the pi brain and never
 * calls the opencode brain object, which can take seconds on its first call (staging: send to wake 2.0-4.8 s on
 * pi Chiefs while every wake went through it first). A Chief switched to opencode is woken there; with no
 * container on this deployment it falls back to the pi brain and still answers.
 */
const testEnv = env as unknown as { CHIEF_OPENCODE_CONTAINER?: string; CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA?: string; OPENCODE_BRAIN_DO: DurableObjectNamespace; STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
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

// Every call of the opencode brain's wake, by Chief.
const woken: Array<string> = []
const realWake = OpencodeBrainDO.prototype.wake
OpencodeBrainDO.prototype.wake = async function (this: OpencodeBrainDO, w) {
  woken.push(w.agent)
  return realWake.call(this, w)
}
afterAll(() => void (OpencodeBrainDO.prototype.wake = realWake))

const ownerWithChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const chief = (await op(token, "chief.create", { display_name: "Route Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20; i++) {
    await fireAlarm(userDO)
    if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
  }
  expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
  return { token, chief }
}

/** Sends one DM and waits (bounded) for the Chief's n-th reply. */
const dmAndReply = async (token: string, chief: { id: string; main_conversation: string }, text: string, n: number) => {
  const key = `route-${text.replace(/[^a-z0-9]+/g, "-")}`
  const sent = await op(token, "message.send", { conversation: chief.main_conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
  expect(sent.ok, JSON.stringify(sent)).toBe(true)
  const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(chief.main_conversation))
  for (let i = 0; i < 200; i++) {
    if ((await history(token, chief.main_conversation)).filter((m) => m.author === chief.id).length >= n) return
    await fireAlarm(conv)
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no reply ${n} from ${chief.id}`)
}

describe("Chief wake routing by brain_impl", { timeout: 120_000 }, () => {
  it("taints effects from every non-owner message returned to an OpenCode turn", () => {
    const owner = "user_owner"
    expect(messagesEffectAuthorized([
      { author: { id: owner, kind: "person" } },
      { author: { id: "chief_1", kind: "self" } }
    ], owner)).toBe(true)
    expect(messagesEffectAuthorized([
      { author: { id: owner, kind: "person" } },
      { author: { id: "user_teammate", kind: "person" } }
    ], owner)).toBe(false)
  })

  it("a pi Chief is woken without the opencode brain; an opencode Chief is woken there and falls back without a container", async () => {
    const { token, chief } = await ownerWithChief("route-impl")

    // pi (the default): the wake never reaches the opencode brain object.
    await dmAndReply(token, chief, "pi one", 1)
    await dmAndReply(token, chief, "pi two", 2)
    expect(woken.filter((a) => a === chief.id)).toHaveLength(0)

    // The owner picks opencode: the next wake goes to the opencode brain (once), which has no container here,
    // so the pi brain answers.
    const set = await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "opencode" })
    expect(set.status, JSON.stringify(set.json)).toBe(200)
    expect((await http("GET", `/v1/chiefs/${chief.id}/brain-impl`, token)).json.value).toEqual({ impl: "opencode" })
    await dmAndReply(token, chief, "o one", 3)
    expect(woken.filter((a) => a === chief.id)).toHaveLength(1)

    // Back to pi: the opencode brain is out of the path again.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "pi" })).status).toBe(200)
    await dmAndReply(token, chief, "pi three", 4)
    expect(woken.filter((a) => a === chief.id)).toHaveLength(1)
  })

  // With a container (CHIEF_OPENCODE_CONTAINER), an opencode Chief's turns run on brainModel (opencode/host.ts): a model
  // that is not Claude or OpenRouter runs as claude-opus-5-5, a paid model only the allow-listed owners may use.
  const withContainer = async <T>(f: () => Promise<T>): Promise<T> => {
    const saved = [testEnv.CHIEF_OPENCODE_CONTAINER, testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA] as const
    testEnv.CHIEF_OPENCODE_CONTAINER = "1"
    try {
      return await f()
    } finally {
      saved[0] === undefined ? delete testEnv.CHIEF_OPENCODE_CONTAINER : (testEnv.CHIEF_OPENCODE_CONTAINER = saved[0])
      saved[1] === undefined ? delete testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA : (testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = saved[1])
    }
  }
  const allow = async (sub: string) => {
    const user = (await op(await sessionToken(sub), "user.ensure", {})).value.id as string
    testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  }
  /** A Chief whose brain is still off, its record already in the brain's reach. */
  const offChief = async (sub: string) => {
    const token = await sessionToken(sub)
    const user = (await op(token, "user.ensure", {})).value.id as string
    const chief = (await op(token, "chief.create", { display_name: "O Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
    const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    for (let i = 0; i < 20; i++) {
      await fireAlarm(userDO)
      if ((await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation: chief.main_conversation, limit: 1 } })).status === 200) break
    }
    return { token, chief }
  }

  it("turning on an opencode Chief checks the model its turns really use: refused off the allow-list, allowed on it", async () => {
    await withContainer(async () => {
      for (const [sub, listed] of [["oc-enable-off", false], ["oc-enable-on", true]] as const) {
        if (listed) await allow(sub)
        const { token, chief } = await offChief(sub)
        expect((await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "opencode" })).status).toBe(200)
        const on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })
        if (listed) expect(on.status, JSON.stringify(on.json)).toBe(200)
        else [expect(on.status, JSON.stringify(on.json)).toBe(409), expect(on.json.error.code).toBe("chief_claude_unavailable")]
      }
    })
  })

  it("moving a Chief that is on to opencode is refused off the allow-list where turns run in a container, allowed where the pi brain answers", async () => {
    const { token, chief } = await ownerWithChief("oc-switch-off")
    await withContainer(async () => {
      const moved = await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "opencode" })
      expect(moved.status, JSON.stringify(moved.json)).toBe(409)
      expect(moved.json.error.code).toBe("chief_claude_unavailable")
      expect((await http("GET", `/v1/chiefs/${chief.id}/brain-impl`, token)).json.value).toEqual({ impl: "pi" })
    })
    // No container: the pi brain answers on the Chief's own (free) model, so the move is fine.
    expect((await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "opencode" })).status).toBe(200)
  })

  it("a refused opencode turn tells the person the model is not available for their team", async () => {
    await withContainer(async () => {
      const saved = testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA
      await allow("oc-delisted")
      const { token, chief } = await offChief("oc-delisted")
      expect((await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true })).status).toBe(200)
      expect((await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, token, { impl: "opencode" })).status).toBe(200)
      // This deployment binds no container: the opencode brain object gets one that is never reached (the refusal comes first).
      await runInDurableObject(testEnv.OPENCODE_BRAIN_DO.get(testEnv.OPENCODE_BRAIN_DO.idFromName(chief.id)), async (instance) => {
        const o = instance as unknown as { ctx: DurableObjectState }
        const real = o.ctx
        o.ctx = new Proxy(real, { get: (t, k) => (k === "container" ? {} : ((v) => (typeof v === "function" ? v.bind(t) : v))(Reflect.get(t, k, t))) })
      })
      // Off the list at the turn.
      saved === undefined ? delete testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA : (testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = saved)
      await dmAndReply(token, chief, "o refused", 1)
      const mine = (await history(token, chief.main_conversation)).filter((m) => m.author === chief.id)
      expect(mine.map((m) => m.parts[0].text)).toEqual([MODEL_UNAVAILABLE_NOTICE])
      expect(woken.filter((a) => a === chief.id)).toHaveLength(1)
    })
  })
})
