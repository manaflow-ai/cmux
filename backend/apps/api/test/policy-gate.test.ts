import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { clearSignInRules, ssoRefusal, versionAtLeast } from "../src/policy-gate.ts"

/** Enterprise P17-4: sso.enforce, updates.minimumVersion and agents.allowedClasses enforced by the server. */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string, extra: Record<string, unknown> = {}) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub, ...extra })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string | undefined, body: unknown, headers: Record<string, string> = {}) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const setPolicy = async (token: string, version: number, changes: Array<{ key: string; value: unknown }>) => {
  const r = await op(token, "team.policy.update", { changes: changes.map((c) => ({ key: c.key, value: { value: c.value, mode: "enforced" } })), expected_version: version, reason: "test" })
  expect(r.json.error).toBeUndefined()
  clearSignInRules()
}

describe("team sign-in policy (P17-4)", { timeout: 60_000 }, () => {
  it("SSO rule for installs: only installs registered from the team's SSO session pass", () => {
    const rules = { sso_required: true, minimum_version: null, allowed_classes: [] }
    const inst = { identity: "inst_1", kind: "install" as const, user: "user_u", team: "team_t", install: "inst_1" }
    expect(ssoRefusal(inst, rules)?.code).toBe("auth.sso_required")
    expect(ssoRefusal({ ...inst, sso_team: "team_t" }, rules)).toBeUndefined()
  })

  it("SSO rule: a session without the team's SSO claim is refused (enabling sso.enforce needs a live connection, so the rule is tested directly)", () => {
    const rules = { sso_required: true, minimum_version: null, allowed_classes: [] }
    const base = { identity: "session:u", kind: "session" as const, user: "user_u", team: "team_t" }
    expect(ssoRefusal(base, rules)?.code).toBe("auth.sso_required")
    expect(ssoRefusal({ ...base, sso_team: "team_other" }, rules)?.code).toBe("auth.sso_required")
    expect(ssoRefusal({ ...base, sso_team: "team_t" }, rules)).toBeUndefined()
    expect(ssoRefusal(base, { ...rules, sso_required: false })).toBeUndefined()
  })

  it("compares client versions", () => {
    expect(versionAtLeast("1.2.3", "1.2.3")).toBe(true)
    expect(versionAtLeast("1.10.0", "1.9.9")).toBe(true)
    expect(versionAtLeast("1.2.2", "1.2.3")).toBe(false)
    expect(versionAtLeast(null, "1.0.0")).toBe(false)
    expect(versionAtLeast("garbage", "1.0.0")).toBe(false)
  })

  it("minimum version on token mint and wire connects, allowed classes on chief.create", async () => {
    const session = await sessionToken("gate-owner")
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "m", device_name: "m", platform: "macos" })).json.value.id as string
    const mint = async (version?: string) => {
      const ch = await call("/v1/auth/challenge", undefined, { user, install })
      const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
      return call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) }, version ? { "x-cmux-client-version": version } : {})
    }
    // No policy: no header needed.
    expect((await mint()).status).toBe(200)

    await setPolicy(session, 0, [{ key: "updates.minimumVersion", value: "2.4.0" }, { key: "agents.allowedClasses", value: ["agent", "run"] }])
    const old = await mint("2.3.9")
    expect(old.status).toBe(403)
    expect(old.json).toMatchObject({ code: "client.too_old", minimum_version: "2.4.0" })
    expect((await mint()).json.code).toBe("client.too_old")
    expect((await mint("2.4.1")).status).toBe(200)
    const wire = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${session}`, "x-cmux-client-version": "1.0.0" } })
    expect(wire.status).toBe(403)
    expect((await op(session, "chief.create", {}, "chief-default")).json.code).toBe("policy.denied")
    // The user socket refuses chief.create (it would skip the class gate).
    const sock = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${session}`, "x-cmux-client-version": "2.4.0" } })
    expect(sock.status).toBe(101)
    const ws = sock.webSocket!
    const frames: Array<any> = []
    let wake: (() => void) | undefined
    ws.addEventListener("message", (e) => { frames.push(JSON.parse(e.data as string)); wake?.() })
    ws.accept()
    ws.send(JSON.stringify({ t: "op", op: "chief.create", params: {}, idempotency_key: "sock-chief" }))
    while (!frames.some((f) => f.idempotency_key === "sock-chief")) await new Promise<void>((r) => (wake = r))
    expect(frames.find((f) => f.idempotency_key === "sock-chief").t).toBe("reject")
    ws.close()

  })
})

