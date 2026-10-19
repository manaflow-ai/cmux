import { afterEach, describe, expect, it, vi } from "vitest"
import { b64u, beginPairing, call, inDO, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"
import { deliver } from "./team-stack-support.ts"
import { hostNetworkExternal } from "../src/host-network-bind.ts"
import { sha256Hex } from "../src/domains/pairing.ts"

const MESH = "mesh_00000000000000000000000000"
const DEVICE = "dev_00000000000000000000000000"
const NATIVE = "https://vm.test"
afterEach(() => { vi.restoreAllMocks() })

/** The real app install registration, token exchange and enrolled host. */
const fixture = async (kind: "mac" | "cli" = "mac") => {
  const team = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing app signing key")
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  if (jwk instanceof ArrayBuffer || !jwk.x || !jwk.y) throw new Error("unexpected app JWK encoding")
  const registered = await call("/v1/ops", team.creator.token, {
    op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind, name: "Laptop", device_name: "Laptop", platform: kind === "cli" ? "linux" : "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user: team.creator.user, install, team: team.team })
  expect(challenge.status).toBe(200)
  expect(challenge.json.message_prefix).toBe(`cmux-auth-team-v1\n${testEnv.ENVIRONMENT}\n${install}\n${team.team}\n`)
  const signed = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const tokenReply = await call("/v1/auth/token", undefined, { user: team.creator.user, install, nonce: challenge.json.nonce, signature: b64u(signed) })
  expect(tokenReply.status).toBe(200)
  expect(tokenReply.json.team).toBe(team.team)
  const token = tokenReply.json.access_token as string, grant = tokenReply.json.grant as string
  const op = (name: string, params: unknown, key = crypto.randomUUID()) => call("/v1/ops", token, {
    op: name, params, idempotency_key: key, origin: "cli"
  }, { "x-cmux-team": team.team })
  const enrolled = await op("host.enroll", { name: "Laptop", platform: kind === "cli" ? "linux" : "macos" })
  expect(enrolled.json.ok).toBe(true)
  const host = enrolled.json.value.id as string
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey)
  if (!(raw instanceof ArrayBuffer)) throw new Error("unexpected app key encoding")
  const point = btoa(String.fromCharCode(...new Uint8Array(raw)))
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  const policy = { tenantId: team.stackTeam, meshId: MESH, deviceId: DEVICE, wgPublicKey: wg, installPublicKey: point, aclVersion: 0, policyDigest: "a".repeat(64), peers: [], accountCredential: "not-for-the-owner-ledger" }
  const requests: string[] = [], used = new Set<string>()
  let policyResponse: unknown = policy
  let status = 200
  let onRead: (() => Promise<void>) | undefined
  const fallback = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init)
    if (!request.url.startsWith(`${NATIVE}/`)) return fallback(input, init)
    requests.push(request.url)
    expect(request.url).toBe(`${NATIVE}/v1/devices/${DEVICE}/signed/overlay-policy`)
    expect(request.redirect).toBe("manual")
    expect(request.headers.has("authorization")).toBe(false)
    expect(request.headers.has("cookie")).toBe(false)
    const proof = await request.json() as { signedAt: number; nonce: string; signature: string }
    expect(Object.keys(proof).sort()).toEqual(["nonce", "signature", "signedAt"])
    if (used.has(proof.nonce)) return Response.json({}, { status: 409 })
    used.add(proof.nonce)
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(proof.signedAt), proof.nonce].join("\n")
    const signature = Uint8Array.from(atob(proof.signature), (c) => c.charCodeAt(0))
    if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, signature, new TextEncoder().encode(message))) return Response.json({}, { status: 403 })
    const pending = onRead; onRead = undefined
    await pending?.()
    return status === 302 ? new Response(null, { status, headers: { location: "https://forbidden.test/proof" } }) : Response.json(policyResponse, { status })
  })
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  const bind = async (key = crypto.randomUUID(), params: Record<string, unknown> = {}, credential = token, revision?: string) => call("/v1/ops", credential, {
    op: "host.network.bind", params: { host, mesh: MESH, device: DEVICE, wg_public_key: wg, proof: await proof(), ...params }, idempotency_key: key, origin: "cli", ...(revision === undefined ? {} : { expected_revision: revision })
  }, { "x-cmux-team": team.team })
  const directory = async () => (await call("/v1/read", team.creator.token, { op: "team.directory", params: {} }, { "x-cmux-team": team.team })).json.value
  const anotherDaemon = async () => {
    const begun = await beginPairing()
    const approved = await call("/v1/ops", team.creator.token, { op: "server.pair.approve", params: { code: begun.res.json.code, team: team.team, name: "Server" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": team.team })
    expect(approved.json.ok).toBe(true)
    const paired = approved.json.value
    const ch = await call("/v1/auth/challenge", undefined, { user: paired.user, install: paired.install })
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const tok = await call("/v1/auth/token", undefined, { user: paired.user, install: paired.install, nonce: ch.json.nonce, signature: b64u(sig) })
    expect(tok.status).toBe(200)
    return tok.json.access_token as string
  }
  return { team, install, host, token, grant, wg, policy, proof, bind, op, directory, requests, anotherDaemon,
    setPolicy: (value: unknown) => { policyResponse = value }, setStatus: (value: number) => { status = value },
    onRead: (callback: () => Promise<void>) => { onRead = callback } }
}

describe("app host network identity binding", () => {
  it.each(["mac", "cli"] as const)("retains the exact %s install grant rather than a caller-supplied grant", async (kind) => {
    const f = await fixture(kind)
    const result = await f.bind(undefined, { install_grant: "grant_00000000000000000000" })
    expect(result.json.ok).toBe(true)
    expect(result.json.value.network).toMatchObject({ install_grant: f.grant })
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)
    expect(host.network).toMatchObject({ install_grant: f.grant })
  })

  it.each(["mac", "cli"] as const)("refreshes a legacy %s receipt only after a new verified read, then replays the grant-bound receipt", async (kind) => {
    const f = await fixture(kind), key = crypto.randomUUID()
    const legacyKey = `host-network:${await sha256Hex(`${f.team.creator.user}:${f.install}:${key}`)}`
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team))
    await inDO(owner, async (instance) => {
      instance.submitSystem("host.network.bound", {
        host: f.host, install: f.install, owner_user: f.team.creator.user, wg_public_key: f.wg,
        network: { tenant: f.team.stackTeam, mesh: MESH, device: DEVICE }
      }, legacyKey)
    })
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host).network).not.toHaveProperty("install_grant")
    const refreshed = await f.bind(key), retry = await f.bind(key)
    expect(refreshed.json.ok).toBe(true)
    expect(refreshed.json.value.network).toMatchObject({ install_grant: f.grant })
    expect(refreshed.json.replayed).toBe(false)
    expect(retry.json).toMatchObject({ ok: true, replayed: true, value: refreshed.json.value })
    expect(f.requests).toHaveLength(2)
  })

  it.each(["mac", "cli"] as const)("binds the Native identity to the actual %s host without persisting proof or policy material", async (kind) => {
    const f = await fixture(kind)
    const reply = await f.bind()
    expect(reply.json.ok).toBe(true)
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)
    expect(host).toMatchObject({ id: f.host, enrolled_by: f.install, owner_user: f.team.creator.user, wg_public_key: f.wg, network: { state: "confirmed", tenant: f.team.stackTeam, mesh: MESH, device: DEVICE } })
    expect(host.network.confirmed_at).toBeGreaterThan(0)
    expect(host.kind).not.toBe("server")
    expect(host.tags ?? []).not.toContain("tag:server")
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const state = JSON.stringify(await owner.debug(f.team.team))
    for (const secret of [f.token, "signature", "nonce", "accountCredential", f.policy.accountCredential]) expect(state.includes(secret)).toBe(false)
    expect(f.requests).toHaveLength(1)
    const audit = await call("/v1/read", f.team.creator.token, { op: "team.audit.list", params: {} }, { "x-cmux-team": f.team.team })
    expect(audit.json.value.entries.find((a: { op: string }) => a.op === "host.network.bind")).toMatchObject({ actor: f.install, detail: { host: f.host, owner_user: f.team.creator.user } })
  })

  it("recovers a lost reply with a fresh proof under the same logical operation key", async () => {
    const f = await fixture(), key = crypto.randomUUID()
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const revision = String((await owner.debug(f.team.team)).seq)
    const first = await f.bind(key, {}, f.token, revision), retry = await f.bind(key, {}, f.token, revision)
    expect(first.json.ok).toBe(true)
    expect(retry.json).toMatchObject({ ok: true, replayed: true, transaction: first.json.transaction, value: first.json.value })
    expect(f.requests).toHaveLength(2)
  })

  it("honors the owner revision when another mutation commits during the signed read", async () => {
    const f = await fixture(), owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const key = crypto.randomUUID()
    const revision = String((await owner.debug(f.team.team)).seq)
    f.onRead(async () => { expect((await f.op("host.enroll", { name: "Concurrent rename", platform: "macos" })).json.ok).toBe(true) })
    const first = await f.bind(key, {}, f.token, revision)
    expect(first.json.error?.code).toBe("revision.conflict")
    const retry = await f.bind(key, {}, f.token, revision)
    expect(retry.json).toMatchObject({ ok: false, transaction: first.json.transaction, replayed: true, error: { code: "revision.conflict" } })
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).toMatchObject({ name: "Concurrent rename" })
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).not.toHaveProperty("network")
  })

  it("verifies a key rotation for the same device and refuses network retargeting", async () => {
    const f = await fixture()
    expect((await f.bind()).json.ok).toBe(true)
    const rotated = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
    f.setPolicy({ ...f.policy, wgPublicKey: rotated })
    expect((await f.bind(undefined, { wg_public_key: rotated })).json.ok).toBe(true)
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host).wg_public_key).toBe(rotated)
    expect((await f.bind(undefined, { device: "dev_11111111111111111111111111", wg_public_key: rotated })).json.error?.code).toBe("auth.forbidden")
    expect(f.requests).toHaveLength(2)
  })

  it("keeps the verified network binding when the same app re-enrolls to rename its host", async () => {
    const f = await fixture()
    expect((await f.bind()).json.ok).toBe(true)
    const before = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)
    const renamed = await f.op("host.enroll", { name: "Laptop renamed", platform: "macos" })
    expect(renamed.json.ok).toBe(true)
    expect(renamed.json.value).toMatchObject({ id: f.host, name: "Laptop renamed", wg_public_key: f.wg, network: before.network })
    const after = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)
    expect(after.network).toEqual(before.network)
  })

  it.each(["tenantId", "meshId", "deviceId", "wgPublicKey", "installPublicKey"] as const)("refuses a policy with mismatched %s", async (field) => {
    const f = await fixture()
    f.setPolicy({ ...f.policy, [field]: "different-identity" })
    expect((await f.bind()).json.error?.code).toBe("auth.forbidden")
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).not.toHaveProperty("network")
  })

  it("refuses an older response without the tenant binding", async () => {
    const f = await fixture()
    const { tenantId: _absent, ...oldPolicy } = f.policy
    f.setPolicy(oldPolicy)
    expect((await f.bind()).json.error?.code).toBe("auth.forbidden")
  })

  it("rejects sessions, daemons, other host ids, agents and a wrong grant before contacting the network service", async () => {
    const f = await fixture(), daemon = await f.anotherDaemon()
    for (const token of [f.team.creator.token, daemon]) expect((await f.bind(undefined, {}, token)).json.error?.code).toBe("auth.forbidden")
    expect((await f.bind(undefined, { host: "host_00000000000000000001" })).json.error?.code).toBe("auth.forbidden")
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const principal = { kind: "install", identity: f.install, user: f.team.creator.user, team: f.team.team, install: f.install, grant: f.grant, install_kind: "mac", grant_classes: ["read", "mutate-own"] }
    const frame = { op: "host.network.bind", params: { host: f.host, mesh: MESH, device: DEVICE, wg_public_key: f.wg, proof: await f.proof() }, idempotency_key: crypto.randomUUID() }
    expect((await owner.hostNetworkBind(f.team.team, { ...principal, agent: "agent_unapproved" }, frame)).error?.code).toBe("auth.forbidden")
    expect((await owner.hostNetworkBind(f.team.team, { ...principal, grant: "grant_wrong" }, frame)).error?.code).toBe("auth.forbidden")
    expect(f.requests).toHaveLength(0)
  })

  it.each(["host", "install", "membership"])("rechecks %s revocation committed during the signed read", async (kind) => {
    const f = await fixture()
    f.onRead(async () => {
      if (kind === "membership") {
        f.team.w.perms.set(`${f.team.stackTeam}:${f.team.creator.stackUser}`, ["cmux:guest"])
        expect((await deliver("team_permission.created", { id: "cmux:guest", team_id: f.team.stackTeam, user_id: f.team.creator.stackUser })).status).toBe(200)
      } else {
        const removed = await call("/v1/ops", f.team.creator.token, { op: kind === "host" ? "host.remove" : "install.revoke", params: kind === "host" ? { host: f.host } : { install: f.install }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": f.team.team })
        expect(removed.json.ok).toBe(true)
      }
    })
    expect((await f.bind()).json.error?.code).toBe("auth.forbidden")
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    expect(JSON.stringify(await owner.debug(f.team.team))).not.toContain('"state":"confirmed"')
  })

  it.each(["team", "project"])("rechecks the owner %s mapping after the signed read", async (field) => {
    const f = await fixture(), owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team))
    let target = { team: f.team.team, tenant: f.team.stackTeam, project: testEnv.STACK_PROJECT_ID }
    f.onRead(async () => { target = { ...target, [field]: `wrong-${field}` } })
    const principal = { kind: "install" as const, identity: f.install, user: f.team.creator.user, team: f.team.team, install: f.install, grant: f.grant, install_kind: "mac", grant_classes: ["read", "mutate-own"] }
    const frame = { op: "host.network.bind", params: { host: f.host, mesh: MESH, device: DEVICE, wg_public_key: f.wg, proof: await f.proof() }, idempotency_key: crypto.randomUUID() }
    let result: any, commits = 0
    // Inject only the routing authority. Keep actual host state, install-key RPC, signed read and reducer.
    await inDO(owner, async (instance) => {
      const engine = instance.boundEngine
      result = await hostNetworkExternal({
        team: f.team.team, project: testEnv.STACK_PROJECT_ID, origin: NATIVE, stream: engine.stream,
        state: () => engine.currentState, rows: engine.rows, tenant: async () => target, http: globalThis.fetch, now: Date.now,
        key: (user, install, grant) => (testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as any).deviceKey(user, install, grant),
        submitSystem: (op, params, key, revision) => { commits++; return instance.submitSystem(op, params, key, undefined, revision) }
      }, principal, frame)
    })
    expect(result.error?.code).toBe("auth.forbidden")
    expect(commits).toBe(0)
    expect(f.requests).toHaveLength(1)
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).not.toHaveProperty("network")
  })

  it.each([302, 404, 503])("keeps the host unbound after a %s and retries with a fresh proof", async (status) => {
    const f = await fixture(), key = crypto.randomUUID()
    f.setStatus(status)
    expect((await f.bind(key)).json.ok).toBe(false)
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).not.toHaveProperty("network")
    f.setStatus(200)
    expect((await f.bind(key)).json.ok).toBe(true)
  })

  it("rejects an oversized policy without storing response material", async () => {
    const f = await fixture()
    f.setPolicy({ ...f.policy, padding: "x".repeat(1_048_577) })
    expect((await f.bind()).json.error?.code).toBe("owner.unreachable")
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.host)).not.toHaveProperty("network")
  })

  it("rejects raw owner submission before the transient proof reaches its ledger", async () => {
    const f = await fixture(), owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const before = await owner.debug(f.team.team), proof = await f.proof()
    const result = await owner.submit(f.team.team, { kind: "install", identity: f.install, user: f.team.creator.user, team: f.team.team, install: f.install, grant: f.grant, install_kind: "mac", grant_classes: ["read", "mutate-own"] }, {
      t: "op", op: "host.network.bind", params: { host: f.host, mesh: MESH, device: DEVICE, wg_public_key: f.wg, proof }, idempotency_key: crypto.randomUUID(), origin: "remote"
    })
    expect(result.frames.find((frame: { t: string }) => frame.t === "reject")?.code).toBe("validation.invalid")
    const after = await owner.debug(f.team.team)
    expect(after.seq).toBe(before.seq)
    expect(after.ledger.length).toBe(before.ledger.length)
    for (const secret of [proof.nonce, proof.signature]) expect(JSON.stringify(after)).not.toContain(secret)
    expect(f.requests).toHaveLength(0)
  })
})
