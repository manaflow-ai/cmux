import { afterEach, describe, expect, it, vi } from "vitest"
import { b64u, call, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

const MESH = "mesh_00000000000000000000000000"
const DEVICE = "dev_00000000000000000000000000"
const NATIVE = "https://vm.test"
afterEach(() => { vi.restoreAllMocks() })

/** The real app install registration, token exchange and enrolled host. */
const fixture = async () => {
  const team = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing app signing key")
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  if (jwk instanceof ArrayBuffer || !jwk.x || !jwk.y) throw new Error("unexpected app JWK encoding")
  const registered = await call("/v1/ops", team.creator.token, {
    op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "Laptop", device_name: "Laptop", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
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
  const enrolled = await op("host.enroll", { name: "Laptop", platform: "macos" })
  expect(enrolled.json.ok).toBe(true)
  const host = enrolled.json.value.id as string
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey)
  if (!(raw instanceof ArrayBuffer)) throw new Error("unexpected app key encoding")
  const point = btoa(String.fromCharCode(...new Uint8Array(raw)))
  const wg = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  const policy = { tenantId: team.stackTeam, meshId: MESH, deviceId: DEVICE, wgPublicKey: wg, installPublicKey: point, aclVersion: 0, policyDigest: "a".repeat(64), peers: [], accountCredential: "not-for-the-owner-ledger" }
  const requests: string[] = [], used = new Set<string>()
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
    return Response.json(policy)
  })
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  const bind = async (key = crypto.randomUUID()) => op("host.network.bind", { host, mesh: MESH, device: DEVICE, wg_public_key: wg, proof: await proof() }, key)
  const directory = async () => (await call("/v1/read", team.creator.token, { op: "team.directory", params: {} }, { "x-cmux-team": team.team })).json.value
  return { team, install, host, token, grant, wg, policy, proof, bind, op, directory, requests }
}

describe("app host network identity binding", () => {
  it("binds the Native identity to the actual app host without persisting proof or policy material", async () => {
    const f = await fixture()
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
  })

  it("recovers a lost reply with a fresh proof under the same logical operation key", async () => {
    const f = await fixture(), key = crypto.randomUUID()
    const first = await f.bind(key), retry = await f.bind(key)
    expect(first.json.ok).toBe(true)
    expect(retry.json).toMatchObject({ ok: true, replayed: true, transaction: first.json.transaction, value: first.json.value })
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
})
