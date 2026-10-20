import { expect, vi } from "vitest"
import { b64u, beginPairing, call, testEnv, inDO } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

const MESH = "mesh_" + "0".repeat(26), NATIVE = "https://vm.test"
type Peer = { host: string; user: string; install: string; grant: string; token: string; device: string; wg: string; point: string; pair: CryptoKeyPair; daemon: boolean }
export type Allow = { protocol: "tcp" | "udp" | "icmp" | "any"; port?: number }

/** Real pairing, install grants, host binding and signatures; only Native HTTP is replaced. */
export const policyWorld = async () => {
  const team = await rolesTeam(), used = new Set<string>(), policies = new Map<string, Record<string, unknown>>()
  const keys = new Map<string, CryptoKeyPair>(), nativeCalls: string[] = []
  const begun = await beginPairing(Date.now(), false, crypto.randomUUID())
  const pointOf = async (pair: CryptoKeyPair) => {
    const raw = await crypto.subtle.exportKey("raw", pair.publicKey)
    if (!(raw instanceof ArrayBuffer)) throw new Error("unexpected public point")
    return btoa(String.fromCharCode(...new Uint8Array(raw)))
  }
  const serverDevice = "dev_" + "1".repeat(26), serverPoint = await pointOf(begun.pair)
  let beforeRead: (() => Promise<void>) | undefined
  const fallback = globalThis.fetch
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init), url = new URL(request.url)
    if (url.origin !== NATIVE) return fallback(input, init)
    expect(request.redirect).toBe("manual"); nativeCalls.push(`${request.method} ${url.pathname}`)
    if (url.pathname === `/v1/meshes/${MESH}/overlay-server-codes`) {
      const binding = await request.json()
      expect(binding).toEqual({ name: "Policy server", wgPublicKey: begun.wg, installPublicKey: serverPoint })
      return Response.json({ code: "msc_" + "0".repeat(26), tenantId: team.stackTeam, meshId: MESH, deviceId: serverDevice,
        binding, expiresAt: new Date(Date.now() + 600_000).toISOString() }, { status: 201 })
    }
    const match = /^\/v1\/(overlay-servers|devices)\/(dev_[0-9a-z]+)\/signed\/(policy|overlay-policy)$/.exec(url.pathname)
    if (!match) throw new Error("unexpected Native request")
    const device = match[2]!, policy = policies.get(device), pair = keys.get(device)
    if (!policy || !pair) return new Response(null, { status: 404 })
    expect(request.method).toBe("POST"); expect(request.headers.has("authorization")).toBe(false); expect(request.headers.has("cookie")).toBe(false)
    const proof = await request.json() as { signedAt: number; nonce: string; signature: string }
    const purpose = match[1] === "overlay-servers" ? "overlay-server-policy" : "overlay-policy"
    const message = ["cmux-mesh-v1", purpose, device, "", policy.installPublicKey, "", String(proof.signedAt), proof.nonce].join("\n")
    if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Uint8Array.from(atob(proof.signature), (c) => c.charCodeAt(0)), new TextEncoder().encode(message))) return new Response(null, { status: 403 })
    if (used.has(`${device}:${proof.nonce}`)) return new Response(null, { status: 409 })
    used.add(`${device}:${proof.nonce}`)
    const hook = beforeRead; beforeRead = undefined; await hook?.()
    return Response.json(policy)
  })
  const sessionOp = (op: string, params: unknown, token = team.creator.token) => call("/v1/ops", token, { op, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": team.team })
  const credentials = async (install: string, pair: CryptoKeyPair, user = team.creator.user, daemon = false) => {
    const challenge = await call("/v1/auth/challenge", undefined, { user, install, ...(daemon ? {} : { team: team.team }) })
    expect(challenge.status).toBe(200)
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
    const issued = await call("/v1/auth/token", undefined, { user, install, nonce: challenge.json.nonce, signature: b64u(signature) })
    expect(issued.status).toBe(200)
    return { token: issued.json.access_token as string, grant: issued.json.grant as string }
  }
  const addPolicy = (device: string, wg: string, point: string, pair: CryptoKeyPair) => {
    keys.set(device, pair); policies.set(device, { tenantId: team.stackTeam, meshId: MESH, deviceId: device, wgPublicKey: wg, installPublicKey: point,
      aclVersion: 1, policyDigest: "a".repeat(64), peers: [], accountCredential: team.creator.token })
  }
  const proof = async (peer: Peer) => {
    const signedAt = Date.now(), nonce = b64u(crypto.getRandomValues(new Uint8Array(16)).buffer)
    const message = ["cmux-mesh-v1", peer.daemon ? "overlay-server-policy" : "overlay-policy", peer.device, "", peer.point, "", String(signedAt), nonce].join("\n")
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, peer.pair.privateKey, new TextEncoder().encode(message))
    return { signedAt, nonce, signature: btoa(String.fromCharCode(...new Uint8Array(signature))) }
  }
  const approved = await sessionOp("server.pair.approve", { code: begun.res.json.code, team: team.team, name: "Policy server", mesh: MESH })
  expect(approved.json.ok).toBe(true)
  const server: Peer = { ...approved.json.value, ...await credentials(approved.json.value.install, begun.pair, team.creator.user, true), device: serverDevice, wg: begun.wg, point: serverPoint, pair: begun.pair, daemon: true }
  addPolicy(server.device, server.wg, server.point, server.pair)
  const confirmed = await call("/v1/ops", server.token, { op: "server.network.confirm", params: { host: server.host, mesh: MESH, device: server.device, proof: await proof(server) }, idempotency_key: crypto.randomUUID(), origin: "cli" })
  expect(confirmed.json.ok).toBe(true)
  const addClient = async (index = 2, owner: { user: string; token: string } = team.creator, existingPair?: CryptoKeyPair, existingWg?: string) => {
    const pair = existingPair ?? await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
    if (!("privateKey" in pair)) throw new Error("missing install key")
    const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
    const registered = await sessionOp("install.register", { public_jwk: jwk, kind: "mac", name: "Policy client", device_name: "Client", platform: "macos" }, owner.token)
    expect(registered.json.ok).toBe(true)
    const install = registered.json.value.id as string, auth = await credentials(install, pair, owner.user)
    const host = await call("/v1/ops", auth.token, { op: "host.enroll", params: { name: "Policy client", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": team.team })
    expect(host.json.ok).toBe(true)
    const client: Peer = { host: host.json.value.id, user: owner.user, install, ...auth, pair, device: "dev_" + String(index).repeat(26),
      wg: existingWg ?? btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))), point: await pointOf(pair), daemon: false }
    addPolicy(client.device, client.wg, client.point, client.pair)
    const bound = await call("/v1/ops", client.token, { op: "host.network.bind", params: { host: client.host, mesh: MESH, device: client.device, wg_public_key: client.wg, proof: await proof(client) }, idempotency_key: crypto.randomUUID(), origin: "cli" }, { "x-cmux-team": team.team })
    expect(bound.json.ok).toBe(true)
    return client
  }
  const client = await addClient()
  return { team, server, client, addClient, proof, policies, nativeCalls, sessionOp, dispose: () => spy.mockRestore(),
    read: async (peer = server, params: Record<string, unknown> = {}) => call("/v1/read", peer.token, { op: "host.network.policy", params: { host: peer.host, proof: await proof(peer), ...params } }, { "x-cmux-team": team.team }),
    nativePeer: (peer: Peer, inbound: Allow[], outbound: Allow[]) => ({ deviceId: peer.device, wgPublicKey: peer.wg, installPublicKey: peer.point, inbound, outbound }),
    onRead: (hook: () => Promise<void>) => { beforeRead = hook },
    directory: async () => (await call("/v1/read", team.creator.token, { op: "team.directory", params: {} }, { "x-cmux-team": team.team })).json.value,
    debug: async () => inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team.team)), async (owner) => owner.debug(team.team))
  }
}
