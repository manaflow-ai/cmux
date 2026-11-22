import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { idFactory, MemoryRows, type Principal, type ReduceContext } from "@cmux/ownership"
import { decodeJwt, decodeProtectedHeader, exportPKCS8, generateKeyPair, importJWK, SignJWT, type JWK } from "jose"
import { beforeAll, describe, expect, it } from "vitest"
import { precheckCodeOp } from "../src/code-check.ts"
import { CodeStorage, teamRepoName, type CodeStorageEnv } from "../src/code-storage.ts"
import { MAX_DEPLOYS_PER_DAY } from "../src/domains/scheduler-code.ts"
import { schedulerDomain, type SchedulerState } from "../src/domains/scheduler.ts"

/** Code automations, slice 1 (plans/cmux-next/automations-plan.md): code refs, deploy, the daily limit, the code.storage check. */

const user: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
let txn = 0
const ctx = (now: number): ReduceContext => {
  const tx = `tx${txn++}`
  return { principal: user, now, tx, newId: idFactory(tx), rows: new MemoryRows() }
}
const apply = (s: SchedulerState, op: string, params: unknown, now: number) => {
  const denied = schedulerDomain.authorize!(s, op, params, user)
  if (denied) return { ok: false as const, code: denied.code }
  return schedulerDomain.reduce(s, op, params, ctx(now))
}
const ok = (r: ReturnType<typeof apply>) => {
  if (!r.ok) throw new Error(`refused: ${r.code}`)
  return r
}

const T0 = Date.UTC(2026, 9, 3, 10, 0, 0)
const sha = (n: number) => n.toString(16).padStart(40, "0")
const codeBody = (commit: string) => ({ type: "code", ref: { path: "automations/daily-digest", commit } })

describe("code bodies in the SchedulerDO reducer", () => {
  it("creates a code automation and deploys another commit, bumping the version", () => {
    const created = ok(apply(schedulerDomain.initial(), "automation.create", { name: "digest", triggers: [{ type: "manual" }], body: codeBody(sha(1)) }, T0))
    const a = created.value as { id: string; version: number; body: unknown }
    expect(a.body).toEqual(codeBody(sha(1)))
    expect(created.state.deploys).toEqual({ day: "2026-10-03", count: 1 })

    const deployed = ok(apply(created.state, "automation.deploy", { automation: a.id, commit: sha(2), expected_version: 1 }, T0 + 1000))
    expect(deployed.value).toMatchObject({ version: 2, body: codeBody(sha(2)) })
    expect(deployed.state.deploys).toEqual({ day: "2026-10-03", count: 2 })
    expect(deployed.outbox).toHaveLength(1)

    // The same commit again changes nothing and counts nothing.
    const same = ok(apply(deployed.state, "automation.deploy", { automation: a.id, commit: sha(2) }, T0 + 2000))
    expect(same.changed).toBe(false)
    expect(same.state.deploys?.count).toBe(2)

    const stale = apply(deployed.state, "automation.deploy", { automation: a.id, commit: sha(3), expected_version: 1 }, T0 + 3000)
    expect(stale).toMatchObject({ ok: false, code: "version.conflict" })
  })

  it("refuses deploys of non-code automations, short ids and foreign paths", () => {
    const created = ok(apply(schedulerDomain.initial(), "automation.create", { name: "steps", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } }, T0))
    const id = (created.value as { id: string }).id
    expect(apply(created.state, "automation.deploy", { automation: id, commit: sha(1) }, T0)).toMatchObject({ ok: false, code: "body.not_code" })
    expect(apply(created.state, "automation.deploy", { automation: id, commit: "abc1234" }, T0)).toMatchObject({ ok: false, code: "validation.invalid" })
    const outside = apply(schedulerDomain.initial(), "automation.create", { name: "x", triggers: [{ type: "manual" }], body: { type: "code", ref: { path: "apps/notes", commit: sha(1) } } }, T0)
    expect(outside).toMatchObject({ ok: false, code: "validation.invalid" })
    const traversal = apply(schedulerDomain.initial(), "automation.create", { name: "x", triggers: [{ type: "manual" }], body: { type: "code", ref: { path: "automations/../x", commit: sha(1) } } }, T0)
    expect(traversal).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("limits code changes per team per UTC day, counting create, update and deploy, and resets the next day", () => {
    let s = ok(apply(schedulerDomain.initial(), "automation.create", { name: "digest", triggers: [{ type: "manual" }], body: codeBody(sha(1)) }, T0)).state
    const id = Object.keys(s.automations)[0]!
    // An update that changes the ref counts like a deploy.
    s = ok(apply(s, "automation.update", { automation: id, body: codeBody(sha(2)) }, T0)).state
    // A change that does not touch the code counts nothing.
    s = ok(apply(s, "automation.update", { automation: id, name: "renamed" }, T0)).state
    expect(s.deploys?.count).toBe(2)
    for (let i = 3; i <= MAX_DEPLOYS_PER_DAY; i++) s = ok(apply(s, "automation.deploy", { automation: id, commit: sha(i) }, T0)).state
    expect(s.deploys?.count).toBe(MAX_DEPLOYS_PER_DAY)
    expect(apply(s, "automation.deploy", { automation: id, commit: sha(999) }, T0)).toMatchObject({ ok: false, code: "deploy.limit" })
    expect(apply(s, "automation.update", { automation: id, body: codeBody(sha(998)) }, T0)).toMatchObject({ ok: false, code: "deploy.limit" })
    expect(apply(s, "automation.create", { name: "second", triggers: [{ type: "manual" }], body: codeBody(sha(997)) }, T0)).toMatchObject({ ok: false, code: "deploy.limit" })
    const tomorrow = ok(apply(s, "automation.deploy", { automation: id, commit: sha(999) }, T0 + 24 * 3600_000))
    expect(tomorrow.state.deploys).toEqual({ day: "2026-10-04", count: 1 })
  })
})

describe("code.storage check (fake HTTP)", () => {
  let codeEnv: CodeStorageEnv
  beforeAll(async () => {
    const k = await generateKeyPair("ES256", { extractable: true })
    codeEnv = { ENVIRONMENT: "staging", CODE_STORAGE_ORG: "cmux-test-org", CODE_STORAGE_PRIVATE_KEY: await exportPKCS8(k.privateKey) }
  })
  const team = "team_aaaaaaaaaaaaaaaaaaaa"
  const repo = teamRepoName("staging", team)

  /** A fake code.storage: one repository with the given commits and files ("<sha>:<path>"). */
  const fake = (commits: ReadonlyArray<string>, files: ReadonlyArray<string>, status?: number) => {
    const calls: Array<{ url: URL; claims: Record<string, unknown>; alg: unknown; range: string | null }> = []
    const http = async (input: string, init?: RequestInit) => {
      const url = new URL(input)
      const auth = new Headers(init?.headers).get("authorization") ?? ""
      const jwt = auth.replace(/^Bearer /, "")
      calls.push({ url, claims: decodeJwt(jwt) as Record<string, unknown>, alg: decodeProtectedHeader(jwt).alg, range: new Headers(init?.headers).get("range") })
      if (status) return new Response(JSON.stringify({ code: "service_unavailable" }), { status })
      if (url.host !== "api.cmux-test-org.code.storage") return new Response("wrong host", { status: 500 })
      const [, , , name, what] = url.pathname.split("/")
      if (decodeURIComponent(name!) !== repo) return Response.json({ code: "repository_not_found" }, { status: 404 })
      if (what === "commit") {
        const s = url.searchParams.get("sha")!
        return commits.includes(s) ? Response.json({ commit: { sha: s } }) : Response.json({ code: "ref_not_found" }, { status: 404 })
      }
      if (what === "file") {
        const key = `${url.searchParams.get("ref")}:${url.searchParams.get("path")}`
        return files.includes(key) ? new Response("e", { status: 206, headers: { etag: '"blob1"' } }) : Response.json({ code: "not_found" }, { status: 404 })
      }
      return new Response("no route", { status: 404 })
    }
    return { http, calls }
  }
  const noRead = async () => undefined

  it("passes when the commit and its bundle exist, with a one-repository read token", async () => {
    const f = fake([sha(1)], [`${sha(1)}:automations/daily-digest/dist/index.js`])
    const res = await precheckCodeOp(codeEnv, team, "automation.create", { body: codeBody(sha(1)) }, noRead, f.http)
    expect(res).toBeUndefined()
    expect(f.calls).toHaveLength(2)
    for (const c of f.calls) {
      expect(c.alg).toBe("ES256")
      expect(c.claims).toMatchObject({ iss: "cmux-test-org", repo, scopes: ["git:read"] })
      expect((c.claims.exp as number) - (c.claims.iat as number)).toBeLessThanOrEqual(300)
    }
    // The bundle check reads one byte, not the bundle.
    expect(f.calls[1]!.range).toBe("bytes=0-0")
  })

  it("refuses a missing commit, a missing bundle, and maps service errors to code.unavailable", async () => {
    const f = fake([sha(1)], [])
    expect(await precheckCodeOp(codeEnv, team, "automation.create", { body: codeBody(sha(2)) }, noRead, f.http)).toMatchObject({ code: "code.not_found" })
    const missing = await precheckCodeOp(codeEnv, team, "automation.create", { body: codeBody(sha(1)) }, noRead, f.http)
    expect(missing).toMatchObject({ code: "code.not_found" })
    expect(missing!.message).toContain("dist/index.js")
    const down = fake([sha(1)], [], 503)
    expect(await precheckCodeOp(codeEnv, team, "automation.create", { body: codeBody(sha(1)) }, noRead, down.http)).toMatchObject({ code: "code.unavailable", retryable: true })
    const unconfigured = await precheckCodeOp({ ENVIRONMENT: "staging" }, team, "automation.create", { body: codeBody(sha(1)) }, noRead, f.http)
    expect(unconfigured).toMatchObject({ code: "code.unavailable", retryable: false })
  })

  it("skips the check when an update repeats the stored ref", async () => {
    const down = fake([], [], 503)
    const read = async () => ({ body: codeBody(sha(1)) })
    expect(await precheckCodeOp(codeEnv, team, "automation.update", { automation: "auto_x", body: codeBody(sha(1)) }, read, down.http)).toBeUndefined()
    expect(down.calls).toHaveLength(0)
    expect(await precheckCodeOp(codeEnv, team, "automation.update", { automation: "auto_x", body: codeBody(sha(2)) }, read, down.http)).toMatchObject({ code: "code.unavailable" })
  })

  it("never accepts a different commit than the one named", async () => {
    const http = async () => Response.json({ commit: { sha: sha(7) } })
    expect(await new CodeStorage(codeEnv, http).commit(repo, sha(1))).toMatchObject({ ok: false, code: "code.not_found" })
  })

  it("checks a deploy against the automation's own path, and leaves other ops alone", async () => {
    const f = fake([sha(2)], [`${sha(2)}:automations/daily-digest/dist/index.js`])
    const read = async () => ({ body: codeBody(sha(1)) })
    expect(await precheckCodeOp(codeEnv, team, "automation.deploy", { automation: "auto_x", commit: sha(2) }, read, f.http)).toBeUndefined()
    expect(f.calls.map((c) => c.url.searchParams.get("path"))).toEqual([null, "automations/daily-digest/dist/index.js"])
    expect(await precheckCodeOp(codeEnv, team, "automation.deploy", { automation: "auto_x", commit: sha(3) }, read, f.http)).toMatchObject({ code: "code.not_found" })
    const before = f.calls.length
    expect(await precheckCodeOp(codeEnv, team, "automation.run", { automation: "auto_x" }, read, f.http)).toBeUndefined()
    expect(await precheckCodeOp(codeEnv, team, "automation.update", { automation: "auto_x", name: "n" }, read, f.http)).toBeUndefined()
    expect(f.calls.length).toBe(before)
  })
})

describe("code automations through the API Worker", () => {
  const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
  const worker = (exports as unknown as { default: Fetcher }).default
  const token = async (stackUser: string) => {
    const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
    return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
      .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
      .setAudience(testEnv.STACK_PROJECT_ID)
      .setSubject(stackUser)
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(key)
  }
  const op = async (t: string, name: string, params: unknown) => {
    const res = await worker.fetch("https://api.test/v1/ops", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${t}` },
      body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
    })
    return (await res.json()) as { ok: boolean; error?: { code: string; retryable: boolean } }
  }

  it("answers a decided key from the ledger and a denied principal with auth.forbidden, never with a new code check", async () => {
    const t = await token("code-user-2")
    const ensured = (await op(t, "user.ensure", {})) as unknown as { value: { personal_team: string } }
    const team = ensured.value.personal_team
    const ns = (env as unknown as { SCHEDULER_DO: DurableObjectNamespace }).SCHEDULER_DO
    const stub = ns.get(ns.idFromName(team))
    const principal: Principal = { identity: `session:${team}-user`, kind: "session", user: "user_cccccccccccccccccccc", team }
    const frame = { t: "op" as const, op: "automation.create", params: { name: "digest", triggers: [{ type: "manual" }], body: codeBody(sha(1)) }, idempotency_key: "k-replay", origin: "cli" as const }
    await (runInDurableObject as unknown as (s: unknown, cb: (i: any) => Promise<void>) => Promise<void>)(stub, async (instance) => {
      // Decide the key without the check (as if code.storage had accepted it), then retry through the checked path.
      const first = await instance.submit(team, principal, frame)
      expect(first.frames.find((f: { t: string }) => f.t === "result")).toBeDefined()
      const retry = await instance.submitCode(team, principal, frame)
      expect("refusal" in retry).toBe(false)
      expect(retry.frames.find((f: { t: string }) => f.t === "result")).toMatchObject({ replayed: true })
      // A fresh key on this deployment (no code storage) is checked and refused.
      const fresh = await instance.submitCode(team, principal, { ...frame, idempotency_key: "k-fresh" })
      expect(fresh).toMatchObject({ refusal: { code: "code.unavailable" } })
      // Another team's principal is denied before any check.
      const stranger: Principal = { identity: "session:stranger", kind: "session", user: "user_dddddddddddddddddddd", team: "team_dddddddddddddddddddd" }
      const denied = await instance.submitCode(team, stranger, { ...frame, idempotency_key: "k-stranger" })
      expect(denied.frames.find((f: { t: string }) => f.t === "reject")).toMatchObject({ code: "auth.forbidden" })
    })
  })

  it("refuses to pin code on a deployment without code storage, and steps bodies still work", async () => {
    const t = await token("code-user-1")
    expect((await op(t, "user.ensure", {})).ok).toBe(true)
    const refused = await op(t, "automation.create", { name: "digest", triggers: [{ type: "manual" }], body: codeBody(sha(1)) })
    expect(refused).toMatchObject({ ok: false, error: { code: "code.unavailable", retryable: false } })
    const steps = await op(t, "automation.create", { name: "plain", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    expect(steps.ok).toBe(true)
  })
})
