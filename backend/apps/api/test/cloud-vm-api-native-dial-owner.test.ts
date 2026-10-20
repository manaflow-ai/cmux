import { decodeJwt } from "jose"
import type { Principal } from "@cmux/ownership"
import { CloudMachineLinkToken } from "@cmux/protocol"
import { Schema } from "effect"
import { afterEach, expect, it, vi } from "vitest"
import { b64u, call } from "./pairing-harness.ts"
import { MESH, VM, withMeshMachine, type MeshOptions } from "./cloud-vm-api-machine-mesh-support.ts"

const DEVICE = "dev_" + "0".repeat(26)
type World = Parameters<Parameters<typeof withMeshMachine>[1]>[0]
afterEach(() => vi.restoreAllMocks())

/** Register and bind through the Worker. Do not replace any owner or grant check. */
const client = async (f: World) => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing client key pair")
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  if (jwk instanceof ArrayBuffer || !jwk.x || !jwk.y) throw new Error("unexpected client key encoding")
  const headers = { "x-cmux-team": f.team }
  const sessionOp = (op: string, params: unknown) => call("/v1/ops", f.session, { op, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, headers)
  const registered = await sessionOp("install.register", {
    public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "Dial client", device_name: "Dial client", platform: "macos"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user: f.user, install, team: f.team })
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const issued = await call("/v1/auth/token", undefined, { user: f.user, install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(issued.status).toBe(200)
  expect(issued.json.team).toBe(f.team)
  const token = issued.json.access_token as string, grant = issued.json.grant as string
  const op = (name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, headers)
  const enrolled = await op("host.enroll", { name: "Dial client", platform: "macos" })
  expect(enrolled.json.ok).toBe(true)
  const host = enrolled.json.value.id as string
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey)
  if (!(raw instanceof ArrayBuffer)) throw new Error("unexpected public point encoding")
  const point = btoa(String.fromCharCode(...new Uint8Array(raw)))
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  let allowed = true, reads = 0, onRead: (() => Promise<void>) | undefined
  const used = new Set<string>()
  f.setNativeRead(async (request) => {
    if (new URL(request.url).pathname !== `/v1/devices/${DEVICE}/signed/overlay-policy`) return undefined
    expect(request.method).toBe("POST")
    expect(request.redirect).toBe("manual")
    expect(request.headers.has("authorization")).toBe(false)
    expect(request.headers.has("cookie")).toBe(false)
    const proof = await request.json() as { signedAt: number; nonce: string; signature: string }
    expect(Object.keys(proof).sort()).toEqual(["nonce", "signature", "signedAt"])
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(proof.signedAt), proof.nonce].join("\n")
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey,
      Uint8Array.from(atob(proof.signature), (c) => c.charCodeAt(0)), new TextEncoder().encode(message))
    if (!valid) return Response.json({}, { status: 403 })
    if (used.has(proof.nonce)) return Response.json({}, { status: 409 })
    used.add(proof.nonce); reads++
    const hook = onRead; onRead = undefined; await hook?.()
    return Response.json({ tenantId: f.tenant, meshId: MESH, deviceId: DEVICE, wgPublicKey: wg, installPublicKey: point,
      aclVersion: 1, policyDigest: "a".repeat(64), peers: [],
      vms: [{ kind: "vm", id: VM, address: "10.128.0.5", allow: allowed ? [{ protocol: "tcp", port: 22 }] : [] }] })
  })
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signed = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signed))) }
  }
  const bound = await op("host.network.bind", { host, mesh: MESH, device: DEVICE, wg_public_key: wg, proof: await proof() })
  expect(bound.json).toMatchObject({ ok: true, value: { host, network: { state: "confirmed", install_grant: grant } } })
  const principal: Principal = { kind: "install", identity: `install:${install}`, user: f.user, team: f.team, install, grant,
    install_kind: "mac", grant_classes: ["read", "mutate-own", "execute"] }
  return { principal, proof, token, host, wg, reads: () => reads, deny: () => { allowed = false },
    onRead: (hook: () => Promise<void>) => { onRead = hook },
    revoke: async () => { expect((await sessionOp("install.revoke", { install })).json.ok).toBe(true) } }
}

it("mints through CloudDO, TeamDO and UserDO after real client and VM binding, and never audits credentials", async () => {
  await withMeshMachine({}, async (f) => {
    await f.create()
    const info = await f.connect() as { host: string }
    const c = await client(f), proof = await c.proof()
    await f.readyReceiver()
    const mint = (native_proof: unknown) => f.owner().mintLinkToken(f.team, c.principal, { host: info.host, services: ["ssh"], native_proof })
    const first = await mint(proof)
    expect(first).toMatchObject({ ok: true, value: { host: info.host, services: ["ssh"], epoch: 1 } })
    if (!first.ok) throw new Error(first.code)
    const firstGrant = Schema.decodeUnknownSync(CloudMachineLinkToken.result)(first.value)
    expect(decodeJwt(firstGrant.token).network).toMatchObject({ version: 1, tenant: f.tenant, mesh: MESH, device: DEVICE, host: c.host, user: f.user, wg_public_key: c.wg, authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
    expect(await mint(proof)).toMatchObject({ ok: false, code: "validation.invalid" })
    const second = await mint(await c.proof())
    expect(second.ok).toBe(true)
    if (!second.ok) throw new Error(second.code)
    const secondGrant = Schema.decodeUnknownSync(CloudMachineLinkToken.result)(second.value)
    expect(secondGrant.token).not.toBe(firstGrant.token)
    const audit = (await f.owner().fakeControl({})).audit.filter((entry) => entry.op === "link_token")
    expect(audit).toHaveLength(2)
    const saved = JSON.stringify(audit)
    for (const secret of [proof.signature, firstGrant.token, secondGrant.token, c.token]) expect(saved).not.toContain(secret)
    expect(c.reads()).toBe(3) // one bind and two successful, fresh policy reads
  })
})

it.each(["policy", "revoked", "wrong-grant", "wrong-allocation"] as const)("refuses %s through the actual owner path without recording a mint", async (change) => {
  const options: MeshOptions = {}
  await withMeshMachine(options, async (f) => {
    await f.create()
    const info = await f.connect() as { host: string }, c = await client(f)
    await f.readyReceiver()
    if (change === "policy") c.deny()
    if (change === "revoked") c.onRead(c.revoke)
    if (change === "wrong-allocation") options.badVmLookup = true
    const principal = change === "wrong-grant" ? { ...c.principal, grant: "grant_" + "9".repeat(20) } : c.principal
    const answer = await f.owner().mintLinkToken(f.team, principal, { host: info.host, services: ["ssh"], native_proof: await c.proof() })
    expect(answer).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect((await f.owner().fakeControl({})).audit.filter((entry) => entry.op === "link_token")).toHaveLength(0)
    expect(c.reads()).toBe(change === "wrong-grant" || change === "wrong-allocation" ? 1 : 2)
  })
})
