import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * Export mode of GET /v1/chiefs/<id>/memory (routes.ts): the owner reads its Cloud Chief's memory back out,
 * page by page, so the Chief can move from the cloud to a Mac (chief-migration-DESIGN.md 4b).
 */
const testEnv = env as unknown as Record<string, any>
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
  await op(token, "user.ensure", {})
  const chief = (await op(token, "chief.create", { display_name: "Export Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const url = `/v1/chiefs/${chief.id}/memory?conversation=${chief.main_conversation}`
  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
  for (let tries = 0; tries < 50; tries++) {
    if ((await http("GET", url, token)).status === 200) break
    await new Promise((r) => setTimeout(r, 20))
  }
  return { token, url, brain }
}

const lines = (n: number) =>
  Array.from({ length: n }, (_, i) => JSON.stringify({ i, kind: i % 2 ? "talk" : "user", text: `message ${i}`, size: `message ${i}`.length, date: `2026-11-0${1 + (i % 2)}T10:00:0${i % 10}.000Z` }))

describe("memory export mode", () => {
  it("pages the messages in id order and gives the nodes on the first page", async () => {
    const { token, url } = await setup("export-a")
    const main = lines(5)
    const tree = [JSON.stringify({ l: 1, i: 0, text: "summary of 0 and 1", size: 18 })]
    const put = await http("PUT", url, token, { after: 0, main, tree, done: true })
    expect(put.status, JSON.stringify(put.json)).toBe(200)
    const first = await http("GET", `${url}&export=1&after=-1&limit=3`, token)
    expect(first.status, JSON.stringify(first.json)).toBe(200)
    expect(first.json.value.count).toBe(5)
    expect(first.json.value.messages.map((m: { i: number }) => m.i)).toEqual([0, 1, 2])
    // The copy keeps the node it was given (the fold after `done` may add more).
    expect(first.json.value.nodes).toContainEqual({ l: 1, i: 0, text: "summary of 0 and 1", size: 18 })
    const next = await http("GET", `${url}&export=1&after=2&limit=3`, token)
    expect(next.json.value.messages.map((m: { i: number; text: string }) => [m.i, m.text])).toEqual([[3, "message 3"], [4, "message 4"]])
    expect(next.json.value.nodes).toEqual([])
  })

  it("answers only the Chief's owner", async () => {
    const { url } = await setup("export-b")
    const other = await sessionToken("export-b-other")
    await op(other, "user.ensure", {})
    const r = await http("GET", `${url}&export=1&after=-1&limit=10`, other)
    expect(r.status).toBe(403)
  })

  it("refuses a bad page", async () => {
    const { token, url } = await setup("export-c")
    expect((await http("GET", `${url}&export=1&after=x&limit=10`, token)).status).toBe(400)
  })
})
