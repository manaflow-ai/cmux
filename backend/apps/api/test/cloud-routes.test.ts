import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { cloudOpByName } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import vectors from "../../../catalog/cloud-vectors.json"

/**
 * CloudDO through the Worker: the live ops answer for real (fake provider), the other cloud.* ops
 * keep answering owner.unreachable, and every answer has the shape of the shared wire vectors
 * (backend/catalog/cloud-vectors.json): the same envelope keys, a value the op's result schema
 * decodes, and the same error tag and code.
 */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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
const call = async (path: string, t: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })
  return { status: res.status, body: (await res.json()) as any }
}
const op = (t: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", t, { op: name, params, idempotency_key: key, origin: "user" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })
const signedIn = async (sub: string) => {
  const t = await token(sub)
  const e = await op(t, "user.ensure", {})
  return { t, team: e.body.value.personal_team as string }
}

interface VectorResponse {
  readonly http: { readonly path: string; readonly status: number }
  readonly body: Record<string, unknown>
}
interface VectorCase {
  readonly name: string
  readonly op: string
  readonly responses: ReadonlyArray<VectorResponse>
}
const cases = (vectors as unknown as { cases: ReadonlyArray<VectorCase> }).cases
const vector = (name: string): VectorResponse => {
  const c = cases.find((x) => x.name === name)
  if (!c) throw new Error(`no vector ${name}`)
  return c.responses[0]!
}
const sortedKeys = (o: object) => Object.keys(o).sort()

/** The answer has the vector's status, envelope keys and error code; its value decodes with the op's result schema. */
const sameShape = (name: string, got: { status: number; body: any }) => {
  const v = vector(name)
  const c = cases.find((x) => x.name === name)!
  expect(got.status, JSON.stringify(got.body)).toBe(v.http.status)
  expect(sortedKeys(got.body)).toEqual(sortedKeys(v.body))
  if ("value" in v.body) {
    const def = cloudOpByName.get(c.op)!
    const decoded = Schema.decodeUnknownExit(def.result as Schema.Codec<unknown, unknown>)(got.body.value)
    expect(Exit.isSuccess(decoded), `${name}: ${String(Exit.isFailure(decoded) ? decoded.cause : "")}`).toBe(true)
    expect(sortedKeys(got.body.value)).toEqual(sortedKeys(v.body.value as object))
  }
  if ("error" in v.body) expect(got.body.error.code).toBe((v.body.error as { code: string }).code)
  if ("_tag" in v.body) expect([got.body._tag, got.body.code]).toEqual([v.body._tag, v.body.code])
  if ("stream" in v.body) expect(got.body.stream).toMatch(/^cloud:team_[a-z0-9]{20}$/)
}

describe("cloud ops through the Worker", { timeout: 60_000 }, () => {
  it("serves the live ops with the vector shapes", async () => {
    const { t, team } = await signedIn("cloud-route-1")
    sameShape("plan.get", await read(t, "cloud.plan.get"))
    const created = await op(t, "cloud.machine.create", { name: "new box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, "key-create-1")
    sameShape("machine.create", created)
    expect(created.body.stream).toBe(`cloud:${team}`)
    const replay = await op(t, "cloud.machine.create", { name: "new box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, "key-create-1")
    expect(replay.body).toMatchObject({ ok: true, replayed: true, value: { machine: { id: created.body.value.machine.id } } })
    const conflict = await op(t, "cloud.machine.create", { name: "other box", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, "key-create-1")
    sameShape("machine.create.conflict", conflict)
    const id = created.body.value.machine.id as string
    await op(t, "cloud.machine.create", { name: "second", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } })
    await op(t, "cloud.machine.create", { name: "third", size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } })
    const page1 = await read(t, "cloud.machine.list", { limit: 2 })
    sameShape("machine.list.first_page", page1)
    sameShape("machine.list.second_page", await read(t, "cloud.machine.list", { limit: 2, cursor: page1.body.value.next_cursor }))
    sameShape("machine.list.default", await read(t, "cloud.machine.list"))
    sameShape("machine.get", await read(t, "cloud.machine.get", { machine: id }))
    sameShape("machine.get.not_found", await read(t, "cloud.machine.get", { machine: "vm_00000000000000000009" }))
    sameShape("machine.rename", await op(t, "cloud.machine.rename", { machine: id, name: "renamed box" }))
    sameShape("machine.idle_policy.set", await op(t, "cloud.machine.idle_policy.set", { machine: id, idle_seconds: 3600 }))
    const del = await op(t, "cloud.machine.delete", { machine: id }, "key-delete-1")
    sameShape("machine.delete", del)
    sameShape("machine.delete.tombstone", await op(t, "cloud.machine.delete", { machine: id }, "key-delete-2"))
    sameShape("machine.get.gone", await read(t, "cloud.machine.get", { machine: id }))
    sameShape("machine.create.size_locked", await op(t, "cloud.machine.create", { name: "huge box", size: { cpu: 16, memory_mb: 65536, disk_mb: 262144 } }))
  })

  it("keeps answering owner.unreachable for the cloud ops that are not live yet", async () => {
    const { t } = await signedIn("cloud-route-2")
    for (const name of ["cloud.machine.start", "cloud.machine.pause", "cloud.snapshot.create", "cloud.billing.checkout", "cloud.machine.link_token"]) {
      const r = await op(t, name, {})
      expect([name, r.status, r.body.code]).toEqual([name, 503, "owner.unreachable"])
    }
    for (const name of ["cloud.snapshot.list", "cloud.machine.connect_info", "cloud.migration.status"]) {
      const r = await read(t, name, {})
      expect([name, r.status, r.body.code]).toEqual([name, 503, "owner.unreachable"])
    }
  })
})
