import { sha256Hex } from "../src/domains/pairing.ts"
import { afterEach, describe, expect, it, vi } from "vitest"
import { b64u, beginPairing, call, inDO, runAlarm, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"
import { deliver } from "./team-stack-support.ts"

const MESH = "mesh_00000000000000000000000000"
const DEVICE = "dev_00000000000000000000000000"
const CODE = "msc_00000000000000000000000000"
const NATIVE = "https://vm.test"
afterEach(() => { vi.restoreAllMocks() })

const daemonToken = async (paired: { user: string; install: string }, key: CryptoKey) => {
  const challenge = await call("/v1/auth/challenge", undefined, { user: paired.user, install: paired.install })
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const token = await call("/v1/auth/token", undefined, { user: paired.user, install: paired.install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(token.status).toBe(200)
  return { value: token.json.access_token as string, grant: token.json.grant as string }
}

/** Actual pairing, daemon-token issuance and independent Native signature verification. */
const fixture = async (network = true) => {
  const team = await rolesTeam()
  const begun = await beginPairing(Date.now(), false, crypto.randomUUID())
  const raw = await crypto.subtle.exportKey("raw", begun.pair.publicKey)
  if (!(raw instanceof ArrayBuffer)) throw new Error("unexpected public key encoding")
  const point = btoa(String.fromCharCode(...new Uint8Array(raw)))
  const reservation = { state: "reserved", tenant: team.stackTeam, mesh: MESH, device: DEVICE }
  const grant = { code: CODE, deviceId: DEVICE, meshId: MESH, tenantId: team.stackTeam, expiresAt: new Date(Date.now() + 600_000).toISOString(), binding: { name: "Studio", wgPublicKey: begun.wg, installPublicKey: point } }
  const policy = { tenantId: team.stackTeam, meshId: MESH, deviceId: DEVICE, wgPublicKey: begun.wg, installPublicKey: point, peers: [], policyDigest: "fixture-policy", accountCredential: team.creator.token }
  const nativeCalls: string[] = []
  const used = new Set<string>()
  let policyStatus = 200
  let policyResponse: unknown = policy
  let beforePolicy: (() => Promise<void>) | undefined
  const fallback = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init)
    if (!request.url.startsWith(`${NATIVE}/`)) return fallback(input, init)
    nativeCalls.push(request.url)
    expect(request.redirect).toBe("manual")
    if (request.url === `${NATIVE}/v1/meshes/${MESH}/overlay-server-codes`) {
      expect(request.headers.get("authorization")).toBe(`Bearer ${team.creator.token}`)
      expect(await request.json()).toEqual(grant.binding)
      return Response.json(grant, { status: 201 })
    }
    expect(request.url).toBe(`${NATIVE}/v1/overlay-servers/${DEVICE}/signed/policy`)
    expect(request.headers.has("authorization")).toBe(false)
    expect(request.headers.has("cookie")).toBe(false)
    const body = await request.json() as { signedAt: number; nonce: string; signature: string }
    expect(Object.keys(body).sort()).toEqual(["nonce", "signature", "signedAt"])
    expect(Math.abs(Date.now() - body.signedAt)).toBeLessThan(120_000)
    if (used.has(body.nonce)) return Response.json({ message: "replayed proof" }, { status: 409 })
    used.add(body.nonce)
    const message = ["cmux-mesh-v1", "overlay-server-policy", DEVICE, "", point, "", String(body.signedAt), body.nonce].join("\n")
    const signature = Uint8Array.from(atob(body.signature), (c) => c.charCodeAt(0))
    if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, begun.pair.publicKey, signature, new TextEncoder().encode(message))) return Response.json({ message: "bad proof" }, { status: 403 })
    const pending = beforePolicy; beforePolicy = undefined
    await pending?.()
    return policyStatus === 302 ? new Response(null, { status: 302, headers: { location: "https://forbidden.test/proof" } }) : Response.json(policyResponse, { status: policyStatus })
  })
  const approved = await call("/v1/ops", team.creator.token, {
    op: "server.pair.approve", params: { code: begun.res.json.code, team: team.team, name: "Studio", ...(network ? { mesh: MESH } : {}) }, idempotency_key: crypto.randomUUID(), origin: "cli"
  }, { "x-cmux-team": team.team })
  expect(approved.json.ok).toBe(true)
  const paired = approved.json.value as { host: string; team: string; user: string; install: string }
  const credentials = await daemonToken(paired, begun.pair.privateKey), token = credentials.value
  const directory = async () => (await call("/v1/read", team.creator.token, { op: "team.directory", params: {} }, { "x-cmux-team": team.team })).json.value
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-server-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  const confirm = async (options: { key?: string; token?: string; params?: Record<string, unknown> } = {}) => call("/v1/ops", options.token ?? token, {
    op: "server.network.confirm", params: { host: paired.host, mesh: MESH, device: DEVICE, proof: await proof(), ...options.params }, idempotency_key: options.key ?? crypto.randomUUID(), origin: "cli"
  })
  const anotherDaemon = async () => {
    const other = await beginPairing(Date.now(), false, crypto.randomUUID())
    const approved = await call("/v1/ops", team.creator.token, { op: "server.pair.approve", params: { code: other.res.json.code, team: team.team, name: "Other" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": team.team })
    expect(approved.json.ok).toBe(true)
    return (await daemonToken(approved.json.value, other.pair.privateKey)).value
  }
  return { team, begun, paired, reservation, directory, proof, confirm, nativeCalls, policy, token, grant: credentials.grant, anotherDaemon,
    setPolicy: (value: unknown) => { policyResponse = value }, setStatus: (value: number) => { policyStatus = value },
    onPolicy: (callback: () => Promise<void>) => { beforePolicy = callback } }
}

describe("server network binding to the approved host and install", () => {
  it("retains the actual daemon grant rather than a caller-supplied grant", async () => {
    const f = await fixture()
    const result = await f.confirm({ params: { install_grant: "grant_00000000000000000000" } })
    expect(result.json.ok).toBe(true)
    expect(result.json.value.network).toMatchObject({ install_grant: f.grant })
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host.network).toMatchObject({ install_grant: f.grant })
  })

  it("refreshes a legacy daemon receipt through fresh verification instead of replaying metadata without a grant", async () => {
    const f = await fixture(), key = crypto.randomUUID()
    const legacyKey = `server-network:${await sha256Hex(`${f.paired.user}:${f.paired.install}:${key}`)}`
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team))
    await inDO(owner, async (instance) => {
      instance.submitSystem("server.network.confirmed", {
        host: f.paired.host, install: f.paired.install, owner_user: f.paired.user,
        wg_public_key: f.policy.wgPublicKey, network: f.reservation
      }, legacyKey)
    })
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host).network).not.toHaveProperty("install_grant")
    const refreshed = await f.confirm({ key }), retry = await f.confirm({ key })
    expect(refreshed.json.ok).toBe(true)
    expect(refreshed.json.value.network).toMatchObject({ install_grant: f.grant })
    expect(refreshed.json.replayed).toBe(false)
    expect(retry.json).toMatchObject({ ok: true, replayed: true, value: refreshed.json.value })
    expect(f.nativeCalls).toHaveLength(3)
  })

  it("keeps the approved reservation in TeamDO after the temporary pairing owner expires", async () => {
    const f = await fixture()
    const pairing = testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(f.begun.res.json.code))
    expect(await runAlarm(pairing)).toBe(true)
    const preview = await call("/v1/read", f.team.creator.token, { op: "server.pair.preview", params: { code: f.begun.res.json.code } }, { "x-cmux-team": f.team.team })
    expect(preview.status).toBe(400)
    expect(preview.json.code ?? preview.json.error?.code).toBe("selector.not_found")
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host.network).toEqual(f.reservation)
    expect(f.nativeCalls).toHaveLength(1)
  })

  it("confirms its reserved Native identity with the actual daemon key and keeps proof material out of owner state", async () => {
    const f = await fixture()
    const result = await f.confirm()
    expect(result.json.ok).toBe(true)
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host.network).toMatchObject({ ...f.reservation, state: "confirmed" })
    expect(host.network.confirmed_at).toBeGreaterThan(0)
    expect(host.tags).toEqual(["tag:server"])
    expect(f.nativeCalls).toHaveLength(2)
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const state = JSON.stringify(await owner.debug(f.team.team))
    for (const secret of [CODE, f.team.creator.token, "signature", "nonce", "accountCredential"]) expect(state.includes(secret)).toBe(false)
  })

  it("does not let a basic paired daemon choose an unapproved network merely by holding a matching key", async () => {
    const f = await fixture(false)
    expect((await f.confirm()).json.ok === true).toBe(false)
    expect(f.nativeCalls).toHaveLength(0)
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host).not.toHaveProperty("network")
  })

  it("uses server revocation when its human owner removes it through the generic host entrypoint", async () => {
    const f = await fixture()
    const removed = await call("/v1/ops", f.team.creator.token, {
      op: "host.remove", params: { host: f.paired.host }, idempotency_key: crypto.randomUUID(), origin: "cli"
    }, { "x-cmux-team": f.team.team })
    expect(removed.json.ok).toBe(true)
    const challenge = await call("/v1/auth/challenge", undefined, { user: f.paired.user, install: f.paired.install })
    expect(challenge.status).toBe(403)
    expect((await f.directory()).hosts.some((h: { id: string }) => h.id === f.paired.host)).toBe(false)
  })

  it.each(["tenantId", "meshId", "deviceId", "wgPublicKey", "installPublicKey"] as const)("does not confirm a policy with a mismatched %s", async (field) => {
    const f = await fixture()
    f.setPolicy({ ...f.policy, [field]: "different-identity" })
    expect((await f.confirm()).json.error?.code).toBe("auth.forbidden")
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host.network).toEqual(f.reservation)
  })

  it("refuses another daemon and a human session before making a signed network request", async () => {
    const f = await fixture(), other = await f.anotherDaemon()
    for (const token of [other, f.team.creator.token]) expect((await f.confirm({ token })).json.error?.code).toBe("auth.forbidden")
    expect(f.nativeCalls).toHaveLength(1)
    expect((await f.confirm({ params: { mesh: "mesh_11111111111111111111111111" } })).json.error?.code).toBe("auth.forbidden")
    expect(f.nativeCalls).toHaveLength(1)
  })

  it("lets Native verify the actual proof, and retries confirmation with a fresh nonce under one logical key", async () => {
    const f = await fixture(), key = crypto.randomUUID()
    const wrong = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
    if (!("privateKey" in wrong)) throw new Error("no signing key")
    const bad = await f.proof()
    bad.signature = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, wrong.privateKey, new TextEncoder().encode("not the reserved install")))))
    expect((await f.confirm({ key, params: { proof: bad } })).json.error?.code).toBe("auth.forbidden")
    const first = await f.confirm({ key }), retry = await f.confirm({ key })
    expect(first.json.ok).toBe(true)
    expect(retry.json).toMatchObject({ ok: true, replayed: true, transaction: first.json.transaction, value: first.json.value })
    expect(f.nativeCalls).toHaveLength(4)
  })

  it.each([302, 404, 503])("preserves the reservation after a %s from the fixed Native endpoint", async (status) => {
    const f = await fixture()
    f.setStatus(status)
    expect((await f.confirm()).json.ok).toBe(false)
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host).network).toEqual(f.reservation)
    expect(f.nativeCalls).toHaveLength(2)
    f.setStatus(200)
    expect((await f.confirm()).json.ok).toBe(true)
  })

  it("bounds policy responses without exposing response fields or changing the reservation", async () => {
    const f = await fixture()
    f.setPolicy({ ...f.policy, padding: "x".repeat(1_048_577) })
    expect((await f.confirm()).json.error?.code).toBe("owner.unreachable")
    expect((await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host).network).toEqual(f.reservation)
  })

  it.each(["team", "project"])("does not contact Native through a confused owner %s mapping", async (field) => {
    const f = await fixture(), owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team))
    await inDO(owner, async (instance) => { instance.vmApiTenant = async () => ({ team: field === "team" ? "wrong-team" : f.team.team, tenant: f.reservation.tenant, project: field === "project" ? "wrong-project" : testEnv.STACK_PROJECT_ID }) })
    expect((await f.confirm()).json.error?.code).toBe("auth.forbidden")
    expect(f.nativeCalls).toHaveLength(1)
  })

  it.each(["server", "install", "membership"])("rechecks %s revocation that commits during the Native read", async (kind) => {
    const f = await fixture()
    f.onPolicy(async () => {
      if (kind === "membership") {
        f.team.w.perms.set(`${f.team.stackTeam}:${f.team.creator.stackUser}`, ["cmux:guest"])
        expect((await deliver("team_permission.created", { id: "cmux:guest", team_id: f.team.stackTeam, user_id: f.team.creator.stackUser })).status).toBe(200)
      } else {
        const revoked = await call("/v1/ops", f.team.creator.token, { op: kind === "server" ? "server.revoke" : "install.revoke", params: kind === "server" ? { host: f.paired.host } : { install: f.paired.install }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": f.team.team })
        expect(revoked.json.ok).toBe(true)
      }
    })
    expect((await f.confirm()).json.error?.code).toBe("auth.forbidden")
    const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    expect(JSON.stringify(await owner.debug(f.team.team)).includes('"state":"confirmed"')).toBe(false)
  })

  it("refuses the raw owner entrypoint before hashing or storing the transient proof", async () => {
    const f = await fixture(), owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(f.team.team)) as any
    const before = await owner.debug(f.team.team), proof = await f.proof()
    const result = await owner.submit(f.team.team, { kind: "install", identity: `install:${f.paired.install}`, user: f.paired.user, team: f.team.team, install: f.paired.install, grant: f.grant, install_kind: "daemon", grant_classes: ["read", "mutate-own"] }, {
      t: "op", op: "server.network.confirm", params: { host: f.paired.host, mesh: MESH, device: DEVICE, proof }, idempotency_key: crypto.randomUUID(), origin: "remote"
    })
    expect(result.frames.find((frame: { t: string }) => frame.t === "reject")?.code).toBe("validation.invalid")
    const after = await owner.debug(f.team.team)
    expect(after.ledger.length).toBe(before.ledger.length)
    expect(after.seq).toBe(before.seq)
    for (const value of [proof.nonce, proof.signature]) expect(JSON.stringify(after).includes(value)).toBe(false)
    expect(f.nativeCalls).toHaveLength(1)
  })
})
