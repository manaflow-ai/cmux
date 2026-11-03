import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teleportTools } from "../src/chief-brain/brain-teleport.ts"
import type { Env } from "../src/env.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A Cloud Chief's move request (chief-brain/brain-teleport.ts): the brain config field `teleport`
 * ({to, id, at} or null) that the person's Mac reads from GET /v1/chiefs/<agent>/brain and acts on.
 * The owner sets or clears it with PUT; the Cloud Chief sets it with its `teleport` tool.
 */
const testEnv = env as unknown as Env & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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

const setup = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const agent = ((await op(token, "chief.create", { display_name: "Teleport Chief" }, `chief-${sub}`)).value as { id: string }).id
  const url = `/v1/chiefs/${agent}/brain`
  for (let i = 0; i < 20 && (await http("GET", url, token)).status !== 200; i++) await fireAlarm(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)))
  return { token, user, agent, url }
}
const teleportOf = async (token: string, url: string) => (await http("GET", url, token)).json.value.config.teleport

const SLOW_DO = 20_000

describe("brain config teleport", () => {
  it("round-trips through PUT and GET, survives other changes, and clears with null", async () => {
    const { token, url } = await setup("teleport-a")
    expect(await teleportOf(token, url)).toBeNull()
    const t = { to: "home", id: "tp_1", at: "2026-11-03T10:00:00.000Z" }
    const put = await http("PUT", url, token, { teleport: t })
    expect(put.status, JSON.stringify(put.json)).toBe(200)
    expect(put.json.value.teleport).toEqual(t)
    expect(await teleportOf(token, url)).toEqual(t)
    expect((await http("PUT", url, token, { role: "Lead" })).status).toBe(200)
    expect(await teleportOf(token, url)).toEqual(t)
    for (const to of ["ssh:cmux-mini-7", "ssh:cmux-mini-7:/Users/me/chief", "local:/Users/me/chief"]) {
      const r = await http("PUT", url, token, { teleport: { ...t, to } })
      expect(r.status, `${to}: ${JSON.stringify(r.json)}`).toBe(200)
      expect((await teleportOf(token, url)).to).toBe(to)
    }
    expect((await http("PUT", url, token, { teleport: null })).status).toBe(200)
    expect(await teleportOf(token, url)).toBeNull()
  }, SLOW_DO)

  it("refuses a bad request", async () => {
    const { token, url } = await setup("teleport-b")
    const t = { to: "home", id: "tp_1", at: "2026-11-03T10:00:00.000Z" }
    const bad: Array<unknown> = [
      "home",
      { ...t, to: "elsewhere" },
      { ...t, to: "ssh:" },
      { ...t, to: "ssh:-oProxyCommand=x" },
      { ...t, to: "local:relative/dir" },
      { ...t, to: "ssh:mini\n" },
      { ...t, to: `local:/${"a".repeat(256)}` },
      { ...t, id: "" },
      { ...t, id: "a b" },
      { ...t, id: "a".repeat(65) },
      { to: "home", id: "tp_1" },
      { ...t, at: "yesterday" },
      { ...t, extra: 1 }
    ]
    for (const teleport of bad) {
      const r = await http("PUT", url, token, { teleport })
      expect(r.status, JSON.stringify(teleport)).toBe(400)
    }
    expect(await teleportOf(token, url)).toBeNull()
  }, SLOW_DO)

  it("answers only the Chief's owner", async () => {
    const { url } = await setup("teleport-c")
    const other = await sessionToken("teleport-c-other")
    await op(other, "user.ensure", {})
    expect((await http("GET", url, other)).status).toBe(403)
    expect((await http("PUT", url, other, { teleport: { to: "home", id: "x", at: "2026-11-03T10:00:00.000Z" } })).status).toBe(403)
  }, SLOW_DO)
})

describe("the Cloud Chief's teleport tool", () => {
  const call = (tool: ReturnType<typeof teleportTools>[0], to: string, callId: string) =>
    (tool.execute as (a: unknown, b: unknown) => unknown)({ to }, { callId }) as Promise<{ content: Array<{ type: string; text: string }> }>

  it("sets the request on the Chief's settings and says goodbye", async () => {
    const { token, user, agent, url } = await setup("teleport-d")
    const [tool] = teleportTools(testEnv, () => ({ agent, owner: user }), () => true)
    expect(tool.name).toBe("teleport")
    const before = Date.now()
    const r = await call(tool, "ssh:cmux-mini-7", "call-1")
    expect(r.content[0]!.text).toMatch(/after this turn/i)
    expect(r.content[0]!.text).toMatch(/goodbye/i)
    const t = await teleportOf(token, url)
    expect(t.to).toBe("ssh:cmux-mini-7")
    expect(t.id).toMatch(/^[A-Za-z0-9_-]{1,64}$/)
    expect(Date.parse(t.at)).toBeGreaterThanOrEqual(before - 1000)
    await call(tool, "home", "call-2")
    const again = await teleportOf(token, url)
    expect(again.to).toBe("home")
    expect(again.id).not.toBe(t.id)
  }, SLOW_DO)

  it("refuses a bad destination and a turn without the owner's word", async () => {
    const { token, user, agent, url } = await setup("teleport-e")
    const [tool] = teleportTools(testEnv, () => ({ agent, owner: user }), () => true)
    expect((await call(tool, "the moon", "call-1")).content[0]!.text).toMatch(/home|ssh:/)
    expect(await teleportOf(token, url)).toBeNull()
    const [unauthorized] = teleportTools(testEnv, () => ({ agent, owner: user }), () => false)
    expect((await call(unauthorized, "home", "call-2")).content[0]!.text).toMatch(/owner approval required/i)
    expect(await teleportOf(token, url)).toBeNull()
  }, SLOW_DO)
})
