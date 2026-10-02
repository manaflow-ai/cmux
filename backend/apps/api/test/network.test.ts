import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { FakeFreestyle } from "@cmux/network-policy/testing"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const sessionToken = async (stackUser: string) => {
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

const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })

const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** A signed-in user with one registered install and its access token. */
const signedInWithInstall = async (stackUser: string) => {
  const session = await sessionToken(stackUser)
  const ensure = await op(session, "user.ensure", {})
  const user = ensure.json.value.id as string
  const team = ensure.json.value.personal_team as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac app", device_name: "mac", platform: "macos" })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
  return { session, jwt: tok.json.access_token as string, user, team, install }
}

interface TeamInternals {
  networkApiFactory: (() => unknown) | null
  onWake(now: number): Promise<void>
}
const inTeam = (team: string, fn: (t: TeamInternals) => Promise<void>) =>
  (runInDurableObject as unknown as (stub: unknown, cb: (instance: unknown) => Promise<void>) => Promise<void>)(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), (i) => fn(i as TeamInternals))

const WG_KEY = `${"Q".repeat(43)}=`

describe("network policy end to end (workerd)", () => {
  it("reads the default, previews, applies, refuses conflicts, and keeps internal ops off HTTP", async () => {
    const { session } = await signedInWithInstall("net-user-1")
    const get0 = await read(session, "network.policy.get")
    expect(get0.json.value).toMatchObject({ effective_default: true, versions: [] })

    const bad = await read(session, "network.policy.preview", { document: `{"acls":[{"action":"accept","src":["group:nope"],"dst":["tag:x:22"]}]}` })
    expect(bad.json.value.ok).toBe(false)
    expect(bad.json.value.issues.map((i: any) => i.path)).toEqual(expect.arrayContaining(["acls[0].src[0]", "acls[0].dst[0]"]))

    const doc = `{
      // admins everywhere, members to the team VM
      "tagOwners": {"tag:team-vm": ["autogroup:admin"]},
      "acls": [{"action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"]}],
      "ssh": [{"action": "accept", "src": ["autogroup:admin"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"]}],
    }`
    const pv = await read(session, "network.policy.preview", { document: doc })
    expect(pv.json.value).toMatchObject({ ok: true, compiled: { rules: 0 } })

    const applied = await op(session, "network.policy.apply", { document: doc, expected_version: null }, "apply-1")
    expect(applied.json).toMatchObject({ ok: true, value: { version: 1 } })
    const replay = await op(session, "network.policy.apply", { document: doc, expected_version: null }, "apply-1")
    expect(replay.json).toMatchObject({ ok: true, replayed: true })
    const conflict = await op(session, "network.policy.apply", { document: doc, expected_version: null })
    expect(conflict.json.error.code).toBe("version.conflict")
    const get1 = await read(session, "network.policy.get")
    expect(get1.json.value).toMatchObject({ effective_default: false, policy: { version: 1 } })

    const internal = await op(session, "network.reconcile.record", { desired_seq: 99 })
    expect(internal.status).toBe(400)
  })

  it("joins a Mac, reconciles a tunnel, and drops it when the install is revoked", async () => {
    const { session, jwt, team, install } = await signedInWithInstall("net-user-2")
    const join = await op(jwt, "network.device.join", { wg_public_key: WG_KEY })
    expect(join.json).toMatchObject({ ok: true, value: { install, status: "pending" } })

    const fake = new FakeFreestyle()
    await inTeam(team, async (t) => {
      t.networkApiFactory = () => fake
      await t.onWake(Date.now())
    })
    expect(fake.vpcs.size).toBe(1)
    expect(fake.tunnels.size).toBe(1)
    const dev = await read(jwt, "network.device.get")
    expect(dev.json.value.devices[0]).toMatchObject({ install, status: "ready" })
    expect(dev.json.value.devices[0].tunnel.client_config).toContain("PersistentKeepalive = 25")
    const status = await read(session, "network.policy.get")
    expect(status.json.value.reconcile).toMatchObject({ applied_seq: 1, desired_seq: 1, last: { converged: true, configured: true } })

    // Revoking the install in UserDO tells TeamDO; the next wake deletes the tunnel.
    const revoke = await op(session, "install.revoke", { install })
    expect(revoke.json.ok).toBe(true)
    let device: any
    for (let i = 0; i < 20; i++) {
      device = (await read(session, "network.device.get")).json.value.devices[0]
      if (device.status === "revoked") break
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(device).toMatchObject({ status: "revoked", tunnel: null })
    await inTeam(team, async (t) => {
      t.networkApiFactory = () => fake
      await t.onWake(Date.now())
    })
    expect(fake.tunnels.size).toBe(0)
  })

  it("records 'not configured' once when no Freestyle key is set", async () => {
    const { session, jwt, team } = await signedInWithInstall("net-user-3")
    await op(jwt, "network.device.join", { wg_public_key: WG_KEY })
    await inTeam(team, async (t) => {
      t.networkApiFactory = () => null
      await t.onWake(Date.now())
      await t.onWake(Date.now())
    })
    const s = await read(session, "network.policy.get")
    expect(s.json.value.reconcile).toMatchObject({ applied_seq: 1, last: { configured: false } })
  })
})
