import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { messageKey } from "../src/chief-brain/memory-import.ts"

/**
 * Append mode of PUT /v1/chiefs/<id>/memory (memory-import.ts): an incremental sync of another Chief's
 * memory into a memory that already has messages (the Cloud Chief after the Oct 19 copy).
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
  const chief = (await op(token, "chief.create", { display_name: "Append Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const url = `/v1/chiefs/${chief.id}/memory?conversation=${chief.main_conversation}`
  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${chief.id}/${chief.main_conversation}`))
  const rows = (sql: string) => runInDurableObject(brain as DurableObjectStub, async (_i, s) => s.storage.sql.exec(sql).toArray() as Array<Record<string, any>>)
  return { token, url, brain, rows }
}
const item = async (kind: string, text: string, date: string, source = "mac-chief") => ({ key: await messageKey(kind, date, text), kind, text, date, source })

describe("memory append mode", () => {
  it("appends new items as notes, and the same items again add nothing", async () => {
    const { token, url, rows } = await setup("append-a")
    const items = [await item("user", "I prefer Rust for hosts", "2026-10-21T10:00:00.000Z"), await item("talk", "Noted", "2026-10-21T10:00:05.000Z")]
    const first = await http("PUT", url, token, { mode: "append", dry_run: false, items })
    expect(first.json.value).toMatchObject({ added: 2, duplicate: 0, rejected: 0 })
    const again = await http("PUT", url, token, { mode: "append", dry_run: false, items })
    expect(again.json.value).toMatchObject({ added: 0, duplicate: 2 })
    const stored = await rows(`SELECT kind, text FROM oc_message ORDER BY i`)
    expect(stored).toHaveLength(2)
    expect(stored[0]!.kind).toBe("note")
    expect(stored[0]!.text).toContain("[imported from mac-chief · user · 2026-10-21T10:00:00.000Z]")
  })

  it("keeps the messages already stored and counts one that an earlier copy brought as a duplicate", async () => {
    const { token, url, brain, rows } = await setup("append-b")
    await runInDurableObject(brain as DurableObjectStub, async (_i, s) => {
      s.storage.sql.exec(`CREATE TABLE IF NOT EXISTS oc_message (i INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, size INTEGER NOT NULL, date TEXT NOT NULL)`)
      s.storage.sql.exec(`INSERT INTO oc_message (i, kind, text, size, date) VALUES (0, 'user', 'copied on Oct 19', 20, '2026-10-19T09:00:00.000Z')`)
    })
    const items = [await item("user", "copied on Oct 19", "2026-10-19T09:00:00.000Z"), await item("user", "newer than the copy", "2026-10-22T09:00:00.000Z")]
    const r = await http("PUT", url, token, { mode: "append", dry_run: false, items })
    expect(r.json.value).toMatchObject({ added: 1, duplicate: 1 })
    const stored = await rows(`SELECT i, kind, text FROM oc_message ORDER BY i`)
    expect(stored[0]).toMatchObject({ i: 0, kind: "user", text: "copied on Oct 19" })
    expect(stored).toHaveLength(2)
  })

  it("drops items that look like credentials and writes nothing on a dry run", async () => {
    const { token, url, rows } = await setup("append-c")
    const items = [await item("note", `token ghp_${"a1".repeat(15)}`, "2026-10-22T10:00:00.000Z"), await item("note", "plain", "2026-10-22T10:00:01.000Z")]
    const dry = await http("PUT", url, token, { mode: "append", dry_run: true, items })
    expect(dry.json.value).toMatchObject({ added: 1, rejected: 1 })
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_message`)).toEqual([{ n: 0 }])
    await http("PUT", url, token, { mode: "append", dry_run: false, items })
    const all = (await rows(`SELECT text FROM oc_message`)).map((r) => r.text).join("\n")
    expect(all).not.toContain("ghp_")
  })
})
