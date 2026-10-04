import type { JWK } from "jose"
import { decodeProtectedHeader } from "jose"
import { describe, expect, it } from "vitest"
import { verifyLinkToken } from "../src/link-token.ts"
import vectors from "../../../../schemas/link-token/vectors.json"
import { signLinkToken, type LinkClaims } from "../src/link-token.ts"
import { bindFile, cloudStub, createdAndBound, DAEMON, installOf, person, post, signedInWithInstall, SIZE, WG_KEY } from "./cloud-bind-support.ts"

/**
 * Part 4: cloud.machine.link_token (state-placement.md 5.8 items 5-6, LINK-TOKEN-OP and
 * LINK-TOKEN-FORMAT) and part 5: the shared vectors schemas/link-token/vectors.json.
 */

const now = () => Math.floor(Date.now() / 1000)

describe("part 4: link_token in CloudDO", { timeout: 60_000 }, () => {
  it("mints a verifiable EdDSA token for one host, one install, the asked services and this epoch", async () => {
    const x = person()
    const { host, keyset } = await createdAndBound(x)
    const inst = installOf(x.p)
    const before = (await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).revision
    const r = await x.stub.mintLinkToken(x.team, inst, { host, services: ["daemon", "ssh"] })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    expect(r.value).toMatchObject({ host, epoch: 1, services: ["daemon", "ssh"] })
    expect(decodeProtectedHeader(r.value.token)).toEqual({ alg: "EdDSA", kid: "test-link-2", typ: "cmux-link+jwt" })
    const v = await verifyLinkToken(r.value.token, { aud: host, epoch: 1, now: now(), keyset: keyset.keys })
    expect(v.ok, JSON.stringify(v)).toBe(true)
    if (!v.ok) return
    expect(v.claims).toMatchObject({ iss: "cmux:cloud:test", aud: host, sub: inst.install, svc: ["daemon", "ssh"], epoch: 1, team: x.team })
    expect(v.claims.exp - v.claims.iat).toBe(300)
    expect(v.claims.jti).toMatch(/^[A-Za-z0-9_-]{22}$/)
    expect(r.value.expires_at).toBe(v.claims.exp * 1000)
    // A mint commits no stream event, and a second call is a fresh token.
    expect((await x.stub.readOp(x.team, x.p, "cloud.plan.get", {})).revision).toBe(before)
    const again = await x.stub.mintLinkToken(x.team, inst, { host, services: ["ssh"] })
    expect(again.value.token).not.toBe(r.value.token)
    // Audited without the token.
    const audit = (await x.stub.fakeControl({})).audit.filter((a) => a.op === "link_token")
    expect(audit.length).toBe(2)
    expect(audit[1]).toMatchObject({ host, by: inst.identity, install: inst.install, kid: "test-link-2", jti: v.claims.jti, svc: ["daemon", "ssh"], exp: v.claims.exp })
    expect(JSON.stringify(audit)).not.toContain(r.value.token)
  })

  it("refuses a session, an agent, a grant without execute, an unknown host and services the caller may not dial", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    const inst = installOf(x.p)
    expect(await x.stub.mintLinkToken(x.team, x.p, { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await x.stub.mintLinkToken(x.team, { ...inst, agent: "agent_chief01" }, { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p, ["read", "mutate-own"]), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await x.stub.mintLinkToken(x.team, inst, { host: "host_00000000000000000009", services: ["ssh"] })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    expect(await x.stub.mintLinkToken(x.team, inst, { host, services: ["ssh", "ssh"] })).toMatchObject({ ok: false, code: "validation.invalid" })
    const bob = installOf({ ...person().p, team: x.team })
    expect(await x.stub.mintLinkToken(x.team, bob, { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })
})

describe("part 4 through the Worker", { timeout: 60_000 }, () => {
  it("install only, no client idempotency key, services within connect_info, mint envelope without stream or key", async () => {
    const a = await signedInWithInstall("cloud-bind-2")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    const host = bound.body.value.host as string
    const ok = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["daemon", "ssh"] }, origin: "cli" })
    expect(ok.status, JSON.stringify(ok.body)).toBe(200)
    expect(ok.body).toMatchObject({ ok: true, op: "cloud.machine.link_token", idempotency_key: "", replayed: false, stream: "", sequence: 0, value: { host, epoch: 1 } })
    expect(await verifyLinkToken(ok.body.value.token, { aud: host, epoch: 1, now: now(), keyset: bound.body.value.keyset.keys })).toMatchObject({ ok: true })
    const keyed = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, idempotency_key: "client-key", origin: "cli" })
    expect([keyed.status, keyed.body.code]).toEqual([400, "validation.invalid"])
    const session = await post("/v1/ops", a.session, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" })
    expect(session.status === 403 || session.body.error?.code === "auth.forbidden", JSON.stringify(session.body)).toBe(true)
    // Team policy without daemon: daemon is not mintable, ssh is.
    await post("/v1/ops", a.session, {
      op: "team.policy.update",
      params: { changes: [{ key: "cloud.connectServices", value: { value: ["ssh"], mode: "enforced" } }], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    const daemon = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["daemon", "ssh"] }, origin: "cli" })
    expect(daemon.body).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    expect((await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" })).body.ok).toBe(true)
  })
})

interface VectorCase {
  readonly name: string
  readonly make: string | null
  readonly kid: string
  readonly sign_with: string
  readonly claims: LinkClaims
  readonly token: string
  readonly verify: ReadonlyArray<{ readonly aud: string; readonly epoch: number; readonly now: number; readonly keyset: string; readonly seen: ReadonlyArray<string>; readonly expect: { ok: boolean; error?: string } }>
}
const V = vectors as unknown as { test_keys: Record<string, JWK>; keysets: Record<string, Record<string, JWK>>; cases: ReadonlyArray<VectorCase> }

describe("part 5: shared link-token vectors", () => {
  it("re-signing every case with the fixed test key gives the identical compact token (Ed25519 is deterministic)", async () => {
    for (const c of V.cases.filter((x) => !x.make)) expect(await signLinkToken(c.claims, c.kid, V.test_keys[c.sign_with]!), c.name).toBe(c.token)
  })

  it("the reference verifier gives every expected result", async () => {
    const names = new Set(V.cases.map((c) => c.name))
    for (const n of ["valid", "expired", "wrong_aud", "wrong_epoch", "replay", "unknown_kid", "rotated_kid"]) expect(names.has(n), n).toBe(true)
    for (const c of V.cases)
      for (const v of c.verify) {
        const r = await verifyLinkToken(c.token, { aud: v.aud, epoch: v.epoch, now: v.now, keyset: V.keysets[v.keyset]!, seen: new Set(v.seen) })
        expect(r.ok ? { ok: true } : { ok: false, error: r.error }, `${c.name} ${v.keyset}`).toEqual(v.expect)
      }
  })
})
