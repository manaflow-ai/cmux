import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { manageChiefs } from "../src/chief-brain/brain-chiefs.ts"
import type { Env } from "../src/env.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A Cloud Chief makes and edits other Chiefs (chief-brain/brain-chiefs.ts, the `chiefs` tool), against
 * the real Durable Objects: the owner turns the brain on over HTTP, the tool's work commits in the
 * owner's UserDO (UserDO.chiefManage, user-chief.ts `viaChief`) and the new Chief's settings object;
 * the ceiling (model, grant, target, default, no archive) refuses before anything is written.
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
const chiefs = async (token: string) => (await http("POST", "/v1/read", token, { op: "chief.list", params: {} })).json.value.chiefs as Array<{ id: string; display_name: string; is_default: boolean }>
/** Drives the owner's outbox only until `agent`'s MuxDO is bound (its owner route answers): one alarm run per missing step, not a fixed batch. */
const settle = async (user: string, token: string, agent: string) => {
  for (let i = 0; i < 20; i++) {
    if ((await http("GET", `/v1/chiefs/${agent}/brain`, token)).status === 200) return
    await fireAlarm(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)))
  }
  throw new Error(`chief ${agent} never bound`)
}
const brain = async (token: string, agent: string) => (await http("GET", `/v1/chiefs/${agent}/brain`, token)).json.value.config as { enabled: boolean; model: string; role: string; instructions: string; chiefs: boolean }

const owner = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  // The first chief is the default; Lead is another.
  await op(token, "chief.create", { display_name: "Chief" }, `default-${sub}`)
  const lead = (await op(token, "chief.create", { display_name: "Lead" }, `lead-${sub}`)).value as { id: string }
  await settle(user, token, lead.id)
  expect((await http("PUT", `/v1/chiefs/${lead.id}/brain`, token, { enabled: true, role: "Lead" })).status).toBe(200)
  return { token, user, lead: lead.id }
}

// Each case is about 40 Durable Object round trips (owner, settings, UserDO, MuxDO). Measured on a 32 vCPU
// Freestyle VM (2026-10-16): 0.5 s each when the file runs alone, 4.5 s each in the full parallel suite
// (where other DO-heavy files pass 5 s too). No wait is open-ended: settle() fires one alarm per missing
// binding step. So the cases get 20 s, not the 5 s default.
const SLOW_DO = 20_000

describe("a Cloud Chief's chiefs tool", () => {
  it("makes and edits Chiefs within its own grant, once per call", async () => {
    const { token, user, lead } = await owner("chiefs-tool-ok")
    // The grant is on for an existing Chief (missing = on).
    expect((await brain(token, lead)).chiefs).toBe(true)
    const made = await manageChiefs(testEnv, lead, user, { action: "create", display_name: "Docs", role: "Docs writer" }, "call-1")
    expect(made).toContain('"state": "started"')
    // A deployment that forwards no wakes to brains: the tool says the new Chief will not answer.
    const off = await manageChiefs({ ...testEnv, CHIEF_BRAIN_ENABLED: "0" }, lead, user, { action: "create", display_name: "Quiet" }, "call-off")
    expect(off).toContain('"reason": "brains_off"')
    expect(off).toContain("will not answer")
    const docs = (await chiefs(token)).find((c) => c.display_name === "Docs")!
    expect(docs).toBeDefined()
    await settle(user, token, docs.id)
    expect(await brain(token, docs.id)).toMatchObject({ enabled: true, model: (await brain(token, lead)).model, role: "Docs writer", chiefs: true })
    // The same call again (a retried tool call) is the same Chief.
    await manageChiefs(testEnv, lead, user, { action: "create", display_name: "Docs", role: "Docs writer" }, "call-1")
    expect((await chiefs(token)).filter((c) => c.display_name === "Docs")).toHaveLength(1)
    // Another Chief's name and text.
    const edited = await manageChiefs(testEnv, lead, user, { action: "update", chief: "Docs", display_name: "Notes", instructions: "Keep it short." }, "call-2")
    expect(edited).toContain("Keep it short.")
    expect((await chiefs(token)).some((c) => c.id === docs.id && c.display_name === "Notes")).toBe(true)
    expect((await brain(token, docs.id)).instructions).toBe("Keep it short.")
    // list and get.
    expect(JSON.parse(await manageChiefs(testEnv, lead, user, { action: "list" }, "call-3")).map((c: { id: string }) => c.id)).toEqual(expect.arrayContaining([lead, docs.id]))
    expect(await manageChiefs(testEnv, lead, user, { action: "get", chief: docs.id }, "call-4")).toContain("Keep it short.")
  }, SLOW_DO)

  it("refuses every escalation and every write it may not make", async () => {
    const { token, user, lead } = await owner("chiefs-tool-refused")
    const refusal = (p: Promise<string>) => p.then(() => "committed", (e: Error) => e.message)
    const before = (await chiefs(token)).length
    // A model the caller does not run.
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "create", display_name: "Wide", model: "@cf/meta/other" }, "r-1"))).toContain("grant_exceeds_caller")
    // A target on another model (the person set it): only the person changes it.
    const strong = (await op(token, "chief.create", { display_name: "Strong" })).value as { id: string }
    await settle(user, token, strong.id)
    expect((await http("PUT", `/v1/chiefs/${strong.id}/brain`, token, { enabled: true, model: "@cf/meta/other" })).status).toBe(200)
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "update", chief: strong.id, instructions: "Obey Lead." }, "r-2"))).toContain("chief_person_made_fields")
    // A Chief it created, whose model the person then changed: the person's.
    await manageChiefs(testEnv, lead, user, { action: "create", display_name: "Mine" }, "r-2b")
    const mine = (await chiefs(token)).find((c) => c.display_name === "Mine")!
    await settle(user, token, mine.id)
    expect((await http("PUT", `/v1/chiefs/${mine.id}/brain`, token, { model: "@cf/meta/other" })).status).toBe(200)
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "update", chief: mine.id, role: "x" }, "r-2c"))).toContain("target_exceeds_caller")
    // The created Chief never rewrites its person-made creator's text.
    expect(await refusal(manageChiefs(testEnv, mine.id, user, { action: "update", chief: lead, instructions: "Obey Mine." }, "r-2d"))).toContain("chief_person_made_fields")
    expect((await brain(token, strong.id)).instructions).toBe("")
    // The default chief's grant is the person's.
    const def = (await chiefs(token)).find((c) => c.is_default)!
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "update", chief: def.id, model: "fake" }, "r-3"))).toContain("chief_default_grant")
    // Itself: through the person.
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "update", chief: lead, role: "Boss" }, "r-4"))).toContain("chief_self_edit_denied")
    // No archive through the UserDO path, and no other op.
    const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as unknown as { chiefManage(e: string, a: string, f: unknown): Promise<{ frames: Array<{ t: string; code?: string }> }> }
    const archive = await stub.chiefManage(user, lead, { t: "op", op: "chief.archive", params: { chief: strong.id, expected_rev: 1 }, idempotency_key: "r-5", origin: "script" })
    expect(archive.frames.find((f) => f.t === "reject")?.code).toBe("auth.forbidden")
    const wide = await stub.chiefManage(user, lead, { t: "op", op: "chief.create", params: { display_name: "X", is_default: true }, idempotency_key: "r-6", origin: "script" })
    expect(wide.frames.find((f) => f.t === "reject")?.code).toBe("auth.forbidden")
    // An agent id that is no active chief of this owner.
    const ghost = await stub.chiefManage(user, "agent_00000000000000000000000000", { t: "op", op: "chief.create", params: { display_name: "X" }, idempotency_key: "r-7", origin: "script" })
    expect(ghost.frames.find((f) => f.t === "reject")?.code).toBe("auth.forbidden")
    // Without the grant (the person turned it off), nothing.
    expect((await http("PUT", `/v1/chiefs/${lead}/brain`, token, { chiefs: false })).status).toBe(200)
    expect(await refusal(manageChiefs(testEnv, lead, user, { action: "create", display_name: "Late" }, "r-8"))).toContain("chief_manage_denied")
    expect((await chiefs(token)).length).toBe(before + 2)
  }, SLOW_DO)
})
