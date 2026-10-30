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
  // The chief's main conversation is created behind chief.create: wait until the memory route can see it.
  for (let tries = 0; tries < 50; tries++) {
    if ((await http("GET", url, token)).status === 200) break
    await new Promise((r) => setTimeout(r, 20))
  }
  const rows = (sql: string) => runInDurableObject(brain as DurableObjectStub, async (_i, s) => s.storage.sql.exec(sql).toArray() as Array<Record<string, any>>)
  return { token, url, brain, rows }
}
const item = async (kind: string, text: string, date: string, source = "mac-chief") => ({ key: await messageKey(kind, date, text), kind, text, date, source })

describe("memory append mode", () => {
  it("appends new items as notes, and the same items again add nothing", async () => {
    const { token, url, rows } = await setup("append-a")
    const items = [await item("user", "I prefer Rust for hosts", "2026-10-21T10:00:00.000Z"), await item("talk", "Noted", "2026-10-21T10:00:05.000Z")]
    const first = await http("PUT", url, token, { mode: "append", dry_run: false, items })
    expect(first.json.value, JSON.stringify(first)).toMatchObject({ added: 2, duplicate: 0, rejected: 0 })
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
    expect(dry.json.value, JSON.stringify(dry)).toMatchObject({ added: 1, rejected: 1 })
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_message`)).toEqual([{ n: 0 }])
    await http("PUT", url, token, { mode: "append", dry_run: false, items })
    const all = (await rows(`SELECT text FROM oc_message`)).map((r) => r.text).join("\n")
    expect(all).not.toContain("ghp_")
  })
})

describe("memory import undo", () => {
  it("takes back a whole import batch (across requests) and lets it be imported again", async () => {
    const { token, url, rows } = await setup("undo-a")
    const live = [await item("user", "already here", "2026-10-20T10:00:00.000Z")]
    await http("PUT", url, token, { mode: "append", dry_run: false, items: live })
    const a = [await item("note", "one", "2026-10-21T10:00:00.000Z", "claude-code")]
    const b = [await item("note", "two", "2026-10-21T10:00:01.000Z", "claude-code")]
    const r1 = await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-1", items: a })
    const r2 = await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-1", items: b })
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_message`), JSON.stringify([r1, r2])).toEqual([{ n: 3 }])
    const undone = await http("PUT", url, token, { mode: "undo", batch: "run-1" })
    expect(undone.json.value).toMatchObject({ removed: 2, count: 1 })
    const left = await rows(`SELECT text FROM oc_message ORDER BY i`)
    expect(left).toHaveLength(1)
    expect(left[0]!.text).toContain("already here")
    const again = await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-2", items: [...a, ...b] })
    expect(again.json.value).toMatchObject({ added: 2, duplicate: 0 })
  })

  it("refuses to undo once something was appended after the batch, and an unknown batch", async () => {
    const { token, url, rows } = await setup("undo-b")
    await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-1", items: [await item("note", "first", "2026-10-21T10:00:00.000Z")] })
    await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-2", items: [await item("note", "second", "2026-10-21T10:00:01.000Z")] })
    const late = await http("PUT", url, token, { mode: "undo", batch: "run-1" })
    expect(late.status).toBe(409)
    expect(late.json.error.code).toBe("undo_not_tail")
    expect((await http("PUT", url, token, { mode: "undo", batch: "never" })).status).toBe(404)
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_message`)).toEqual([{ n: 2 }])
  })

  it("deletes the summaries that reach the removed rows and keeps the ones below", async () => {
    const { token, url, rows } = await setup("undo-c")
    await http("PUT", url, token, { mode: "append", dry_run: false, items: [await item("note", "a", "2026-10-20T10:00:00.000Z"), await item("note", "b", "2026-10-20T10:00:01.000Z")] })
    await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-1", items: [await item("note", "c", "2026-10-21T10:00:00.000Z"), await item("note", "d", "2026-10-21T10:00:01.000Z")] })
    await rows(`INSERT OR REPLACE INTO oc_node (l, i, text, size) VALUES (1, 0, 'sum ab', 6), (1, 1, 'sum cd', 6), (2, 0, 'sum abcd', 8)`)
    const undone = await http("PUT", url, token, { mode: "undo", batch: "run-1" })
    expect(undone.json.value).toMatchObject({ removed: 2, count: 2 })
    expect((await rows(`SELECT l, i FROM oc_node ORDER BY l, i`)).filter((n) => n.l === 1 && n.i === 0)).toHaveLength(1)
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_node WHERE (i + 1) * (1 << l) > 2`)).toEqual([{ n: 0 }])
  })
})

describe("memory import undo vs the compactor", () => {
  it("drops a summary that was being built over rows the undo removed", async () => {
    const { token, url, brain, rows } = await setup("undo-d")
    await http("PUT", url, token, { mode: "append", dry_run: false, batch: "run-1", items: [await item("note", "x", "2026-10-21T10:00:00.000Z"), await item("note", "y", "2026-10-21T10:00:01.000Z")] })
    // A model call started before the undo finishes after it.
    const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<boolean>) => Promise<boolean>
    const stale = await inDO(brain, async (instance) => {
      const generation = instance.memory.generation
      const undone = await instance.memoryImport({ mode: "undo", batch: "run-1" }, false)
      instance.memory.complete(1, 0, "summary of removed rows", generation)
      return undone.ok
    })
    expect(stale).toBe(true)
    expect(await rows(`SELECT COUNT(*) AS n FROM oc_node WHERE text = 'summary of removed rows'`)).toEqual([{ n: 0 }])
  })
})
