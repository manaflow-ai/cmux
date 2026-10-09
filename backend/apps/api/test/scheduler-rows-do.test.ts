import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/** (g1) SchedulerDO paging and the one-time migration of an old JSON head, through the Worker. */
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const post = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const op = async (t: string, name: string, params: unknown) => {
  const r = await post("/v1/ops", t, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
  expect(r.ok, JSON.stringify(r)).toBe(true)
  return r.value
}
const read = async (t: string, name: string, params: unknown = {}) => {
  const r = await post("/v1/read", t, { op: name, params })
  expect(r._tag, JSON.stringify(r)).toBeUndefined()
  return r.value
}
const signedIn = async (sub: string) => {
  const t = await token(sub)
  const team = (await op(t, "user.ensure", {})).personal_team as string
  return { t, team, stub: testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team)) }
}
const steps = (text: string) => ({ type: "steps", steps: [{ type: "note", text }] })

describe("automation and run paging (g1)", { timeout: 120_000 }, () => {
  it("pages automations oldest first with a cursor that is stable under inserts", async () => {
    const { t } = await signedIn("sched-rows-page-1")
    const originals: Array<string> = []
    for (let i = 0; i < 25; i++) originals.push((await op(t, "automation.create", { name: `a${i}`, triggers: [{ type: "manual" }], body: steps(`a${i}`) })).id)
    const seen: Array<string> = []
    const inserted: Array<string> = []
    let cursor: string | undefined
    for (let page = 0; page < 10; page++) {
      const r = await read(t, "automation.list", { limit: 10, ...(cursor ? { cursor } : {}) })
      expect(r.automations.length).toBeLessThanOrEqual(10)
      seen.push(...r.automations.map((a: { id: string }) => a.id))
      cursor = r.next_cursor ?? undefined
      if (!cursor) break
      // Inserts between pages land after the cursor, never before it.
      for (let i = 0; i < 2; i++) inserted.push((await op(t, "automation.create", { name: `n${page}-${i}`, triggers: [{ type: "manual" }], body: steps(`n${page}`) })).id)
    }
    expect(seen).toEqual([...originals, ...inserted])
    // The first page without params is every automation (at most 100), with bodies (the live UI).
    const all = await read(t, "automation.list")
    expect(all.automations).toHaveLength(originals.length + inserted.length)
    expect(all.next_cursor).toBeNull()
    expect(all.automations[0].body).toEqual(steps("a0"))
    expect((await read(t, "automation.get", { automation: originals[3] })).body).toEqual(steps("a3"))
  })

  it("pages runs newest first, filters by automation and state, and run.get joins the body", async () => {
    const { t } = await signedIn("sched-rows-page-2")
    const a = (await op(t, "automation.create", { name: "a", triggers: [{ type: "manual" }], body: steps("a"), concurrency: { max: 1, on_limit: "queue" } })).id
    // b's first run sleeps, so it holds b's only slot and the rest stay queued.
    const slow = { type: "steps", steps: [{ type: "sleep", seconds: 3600 }] }
    const b = (await op(t, "automation.create", { name: "b", triggers: [{ type: "manual" }], body: slow, concurrency: { max: 1, on_limit: "queue" } })).id
    const originals: Array<string> = []
    for (let i = 0; i < 12; i++) originals.push((await op(t, "automation.run", { automation: a })).id)
    const others: Array<string> = []
    for (let i = 0; i < 4; i++) others.push((await op(t, "automation.run", { automation: b })).id)
    const seen: Array<string> = []
    let cursor: string | undefined
    for (let page = 0; page < 10; page++) {
      const r = await read(t, "run.list", { automation: a, limit: 5, ...(cursor ? { cursor } : {}) })
      seen.push(...r.runs.map((x: { id: string }) => x.id))
      cursor = r.next_cursor ?? undefined
      if (!cursor) break
      // A newer run never shows up on a later page of a newest-first listing.
      await op(t, "automation.run", { automation: a })
    }
    expect(seen).toEqual([...originals].reverse())
    // Disabling b cancels its queued runs; the state filter finds them.
    await op(t, "automation.update", { automation: b, enabled: false })
    const cancelled = await read(t, "run.list", { automation: b, state: "cancelled" })
    expect(cancelled.runs.length).toBeGreaterThanOrEqual(3)
    for (const r of cancelled.runs) expect(r).toMatchObject({ automation: b, state: "cancelled" })
    const one = await read(t, "run.get", { run: others[1] })
    expect(one).toMatchObject({ id: others[1], automation: b, body: slow })
    expect(one.dispatched).toBeUndefined()
    // The old listing still answers its first page.
    expect((await read(t, "automation.runs.list", { automation: b })).runs.map((r: { id: string }) => r.id)).toEqual([...others].reverse())
  })
})

describe("SchedulerDO migration of an old JSON head (g1)", { timeout: 120_000 }, () => {
  it("moves automations, runs and bodies to rows on wake, keeps every record, and is idempotent", async () => {
    const { t, team, stub } = await signedIn("sched-rows-migrate-1")
    const ids: Array<string> = []
    for (let i = 0; i < 3; i++) ids.push((await op(t, "automation.create", { name: `m${i}`, triggers: [{ type: "manual" }], body: steps(`m${i}`) })).id)
    const automations = await Promise.all(ids.map((automation) => read(t, "automation.get", { automation })))
    const owner = automations[0].owner as string
    const now = Date.now()
    const open = (st: string) => st === "running"
    const legacyRun = (n: number, automation: string, state: string, body: unknown) => ({
      id: `run_${String(n).padStart(20, "0")}`,
      automation,
      automation_version: 1,
      owner,
      trigger: { id: null, type: "manual" },
      state,
      step: 0,
      created_at: now - 1000 + n,
      started_at: now - 1000 + n,
      finished_at: open(state) ? null : now - 500 + n,
      error: null,
      outcome: null,
      dispatched: true,
      // A running run with its deadline a day away: the alarm leaves it alone during the test.
      ...(open(state) ? { deadline_at: now + 24 * 3600_000 } : {}),
      body
    })
    // Finished runs of an older body version, one finished and one running run of the current body.
    const runs = [
      legacyRun(1, ids[0]!, "succeeded", steps("old")),
      legacyRun(2, ids[0]!, "failed", steps("old")),
      legacyRun(3, ids[1]!, "succeeded", automations[1].body),
      legacyRun(4, ids[2]!, "running", automations[2].body)
    ]
    // Write an old-style head: automations and runs as maps (what deployed objects hold today).
    const seed = (keepRows: boolean) =>
      runIn(stub, async (instance, state) => {
        const sql = state.storage.sql
        const cur = JSON.parse(String(sql.exec("SELECT json FROM own_state WHERE id = 1").one().json))
        const { automation_count: _a, open_runs: _o, finished_count: _f, row_seq: _r, ...rest } = cur
        const legacy = { ...rest, automations: Object.fromEntries(automations.map((a) => [a.id, a])), runs: Object.fromEntries(runs.map((r) => [r.id, r])), chains: cur.chains ?? {} }
        sql.exec("UPDATE own_state SET json = ? WHERE id = 1", JSON.stringify(legacy))
        if (!keepRows) sql.exec("DELETE FROM own_rows WHERE tbl IN ('automation', 'run', 'body', 'finished')")
        // As after a deploy: the engine reopens from storage, and the next bind migrates.
        instance.engine = undefined
      })
    const check = async () => {
      // The first request binds the object, which migrates an old head.
      const listed = await read(t, "automation.list")
      expect(listed.automations).toEqual(automations)
      const head = await runIn(stub, async (_i, state) => JSON.parse(String(state.storage.sql.exec("SELECT json FROM own_state WHERE id = 1").one().json)))
      expect(head.automations).toBeUndefined()
      expect(head.runs).toBeUndefined()
      expect(head).toMatchObject({ automation_count: 3, finished_count: 3, open_runs: [runs[3]!.id] })
      for (const r of runs) {
        const { dispatched: _d, deadline_at: _dl, ...pub } = r as typeof r & { deadline_at?: number }
        expect(await read(t, "run.get", { run: r.id })).toEqual(pub)
      }
      const bodies = await runIn(stub, async (_i, state) =>
        state.storage.sql.exec("SELECT json FROM own_rows WHERE tbl = 'body'").toArray().map((x) => JSON.parse(String(x.json)) as { refs: number; body: unknown })
      )
      // m0, m1, m2 and the old body; refs count automations plus kept runs.
      expect(bodies).toHaveLength(4)
      expect(bodies.find((x) => JSON.stringify(x.body) === JSON.stringify(steps("old")))?.refs).toBe(2)
      expect(bodies.find((x) => JSON.stringify(x.body) === JSON.stringify(automations[1].body))?.refs).toBe(2)
      expect(bodies.reduce((n, x) => n + x.refs, 0)).toBe(3 + runs.length)
    }
    await seed(false)
    await check()
    // Live DO: the same key replays, a fresh key changes nothing, and no event is added.
    const before = await runIn(stub, async (instance, state) => {
      const seq = instance.boundEngine.currentSeq as number
      // The migration committed at seq, under the key of the head seq before it.
      const replay = instance.submitSystem("scheduler.rows_migrate", {}, `rows-migrate:${seq - 1}`)
      expect(replay.frames.find((f: { t: string }) => f.t === "result")).toMatchObject({ replayed: true })
      instance.submitSystem("scheduler.rows_migrate", {}, `rows-migrate-again:${seq}`)
      expect(instance.boundEngine.currentSeq).toBe(seq)
      return String(state.storage.sql.exec("SELECT json FROM own_state WHERE id = 1").one().json)
    })
    await check()
    expect(await runIn(stub, async (_i, state) => String(state.storage.sql.exec("SELECT json FROM own_state WHERE id = 1").one().json))).toBe(before)
    // A head that a rollback build refilled with maps (its rows still there) migrates again, without counting twice.
    await seed(true)
    await check()
    expect(team).toBe(owner)
  })
})
