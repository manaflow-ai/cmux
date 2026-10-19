import { afterEach, describe, expect, it, vi } from "vitest"
import { b64u, beginPairing, call, runAlarm, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

const MESH = "mesh_00000000000000000000000000"
const DEVICE = "dev_00000000000000000000000000"
const CODE = "msc_00000000000000000000000000"
const NATIVE = "https://vm.test"
afterEach(() => { vi.restoreAllMocks() })

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
    expect(used.has(body.nonce)).toBe(false)
    used.add(body.nonce)
    const message = ["cmux-mesh-v1", "overlay-server-policy", DEVICE, "", point, "", String(body.signedAt), body.nonce].join("\n")
    const signature = Uint8Array.from(atob(body.signature), (c) => c.charCodeAt(0))
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, begun.pair.publicKey, signature, new TextEncoder().encode(message))).toBe(true)
    return Response.json(policy)
  })
  const approved = await call("/v1/ops", team.creator.token, {
    op: "server.pair.approve", params: { code: begun.res.json.code, team: team.team, name: "Studio", ...(network ? { mesh: MESH } : {}) }, idempotency_key: crypto.randomUUID(), origin: "cli"
  }, { "x-cmux-team": team.team })
  expect(approved.json.ok).toBe(true)
  const paired = approved.json.value as { host: string; team: string; user: string; install: string }
  const challenge = await call("/v1/auth/challenge", undefined, { user: paired.user, install: paired.install })
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const token = await call("/v1/auth/token", undefined, { user: paired.user, install: paired.install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(token.status).toBe(200)
  const directory = async () => (await call("/v1/read", team.creator.token, { op: "team.directory", params: {} }, { "x-cmux-team": team.team })).json.value
  const proof = async () => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", "overlay-server-policy", DEVICE, "", point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  const confirm = async (key = crypto.randomUUID()) => call("/v1/ops", token.json.access_token, {
    op: "server.network.confirm", params: { host: paired.host, mesh: MESH, device: DEVICE, proof: await proof() }, idempotency_key: key, origin: "cli"
  })
  return { team, begun, paired, reservation, directory, proof, confirm, nativeCalls }
}

describe("server network binding to the approved host and install", () => {
  it("keeps the approved reservation in TeamDO after the temporary pairing owner expires", async () => {
    const f = await fixture()
    const pairing = testEnv.PAIRING_DO.get(testEnv.PAIRING_DO.idFromName(f.begun.res.json.code))
    expect(await runAlarm(pairing)).toBe(true)
    const preview = await call("/v1/read", f.team.creator.token, { op: "server.pair.preview", params: { code: f.begun.res.json.code } }, { "x-cmux-team": f.team.team })
    expect(preview.status).toBe(404)
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
    expect((await f.confirm()).json.ok).toBe(false)
    expect(f.nativeCalls).toHaveLength(0)
    const host = (await f.directory()).hosts.find((h: { id: string }) => h.id === f.paired.host)
    expect(host).not.toHaveProperty("network")
  })
})
