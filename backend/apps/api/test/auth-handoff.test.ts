import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { HANDOFF_TTL_MS, MINT_LIMIT, MINT_WINDOW_MS } from "../src/auth-handoff.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

/**
 * Sign-in hand-off (auth-handoff.ts, auth-handoff-routes.ts): a signed-in app's human Stack session mints a
 * one-time code; another device redeems it once for a NEW Stack session of the same user. Stack is faked
 * on the person's personal TeamDO. The SSO refusal is in team-sso-login.test.ts (it needs that file's IdP).
 */
const testEnv = env as unknown as Env & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any

const session = async (sub: string, refreshTokenId = `rtid-${sub}`) =>
  new SignJWT({ email: `${sub}@example.dev`, email_verified: true, name: sub, refresh_token_id: refreshTokenId })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const op = async (token: string, name: string, params: unknown) =>
  (await (await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" }) })).json()) as any

/** A fresh client IP per request, so the shared per-IP limiter never trips across tests. */
const ip = () => ({ "cf-connecting-ip": `203.0.113.${Math.floor(Math.random() * 250)}-${crypto.randomUUID()}` })

const mint = (bearer: string | undefined, body: unknown = { device: "air-blue" }) =>
  worker.fetch("https://api.test/v1/auth/handoffs", {
    method: "POST",
    headers: { "content-type": "application/json", ...(bearer ? { authorization: `Bearer ${bearer}` } : {}), ...ip() },
    body: JSON.stringify(body)
  })
const redeem = (body: unknown) =>
  worker.fetch("https://api.test/v1/auth/handoffs/redeem", { method: "POST", headers: { "content-type": "application/json", ...ip() }, body: JSON.stringify(body) })

/** A person with a personal team, a fake Stack on it and a record of every audit the team took. */
const person = async (opts: { failStack?: boolean; slowStack?: boolean } = {}) => {
  const sub = `stack-handoff-${crypto.randomUUID().slice(0, 8)}`
  const token = await session(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  const team = personalTeamIdFor(user)
  const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as DurableObjectStub
  const sessions: Array<string> = []
  const audits: Array<{ op: string; params: Record<string, unknown> }> = []
  await inDO(stub, async (instance) => {
    instance.stack = {
      createSession: async (stackUser: string) => {
        if (opts.slowStack) await new Promise((r) => setTimeout(r, 30))
        if (opts.failStack) throw new Error("stack 500")
        sessions.push(stackUser)
        return { access_token: `access-${stackUser}-${sessions.length}`, refresh_token: `refresh-${stackUser}-${sessions.length}` }
      }
    }
    const submit = instance.submitSystem.bind(instance)
    instance.submitSystem = (name: string, params: Record<string, unknown>, key: string) => {
      if (name.startsWith("auth.handoff.")) audits.push({ op: name, params })
      return submit(name, params, key)
    }
  })
  const auditCount = async () => {
    let n = 0
    await inDO(stub, async (instance) => {
      n = instance.boundEngine.currentState.audit_count ?? 0
    })
    return n
  }
  return { sub, token, user, team, stub, sessions, audits, auditCount }
}

describe("sign-in hand-off (workerd)", { timeout: 30_000 }, () => {
  it("mints with the app's own session and redeems once into a new session for the same user; a replay is refused", async () => {
    const p = await person()
    const before = await p.auditCount()
    const res = await mint(p.token)
    expect(res.status).toBe(201)
    expect(res.headers.get("cache-control")).toBe("no-store")
    const minted = (await res.json()) as { code: string; expires_at: number; user: string; email: string; device: string }
    expect(minted.code).toMatch(new RegExp(`^cmh_${p.team}\\.[A-Za-z0-9_-]{43}$`))
    expect(minted).toMatchObject({ user: p.user, email: `${p.sub}@example.dev`, device: "air-blue" })
    expect(minted.expires_at - Date.now()).toBeLessThanOrEqual(HANDOFF_TTL_MS)
    expect(minted.expires_at - Date.now()).toBeGreaterThan(HANDOFF_TTL_MS - 10_000)

    const ok = await redeem({ code: minted.code, device: "cosmic-gray" })
    expect(ok.status).toBe(200)
    expect(await ok.json()).toEqual({
      already_signed_in: false,
      access_token: `access-${p.sub}-1`,
      refresh_token: `refresh-${p.sub}-1`,
      user: p.user,
      stack_user: p.sub,
      email: `${p.sub}@example.dev`,
      device: "cosmic-gray",
      minted_device: "air-blue"
    })
    // A NEW session for the minting user, made by Stack's server API.
    expect(p.sessions).toEqual([p.sub])

    // Replay: one answer for spent, unknown and expired; no second session.
    const again = await redeem({ code: minted.code, device: "cosmic-gray" })
    expect(again.status).toBe(400)
    expect(((await again.json()) as any).error.code).toBe("auth_handoff.invalid")
    expect(p.sessions).toHaveLength(1)

    // Every step is audited on the person's team, by a hash prefix, never the code.
    expect(p.audits.map((a) => a.op)).toEqual(["auth.handoff.minted", "auth.handoff.redeemed", "auth.handoff.refused"])
    expect(p.audits[0]!.params).toMatchObject({ device: "air-blue", session: `rtid-${p.sub}` })
    expect(p.audits[1]!.params).toMatchObject({ device: "cosmic-gray", minted_device: "air-blue" })
    expect(p.audits[2]!.params).toMatchObject({ stage: "redeem", reason: "spent" })
    expect(JSON.stringify(p.audits)).not.toContain(minted.code.split(".")[1]!)
    expect(await p.auditCount()).toBe(before + 3)
  })

  it("two concurrent redeems of one code: exactly one session", async () => {
    const p = await person({ slowStack: true })
    const { code } = (await (await mint(p.token)).json()) as { code: string }
    const answers = await Promise.all([redeem({ code }), redeem({ code }), redeem({ code })])
    expect(answers.map((a) => a.status).sort()).toEqual([200, 400, 400])
    expect(p.sessions).toHaveLength(1)
  })

  it("an expired code is refused and makes no session", async () => {
    const p = await person()
    const { code } = (await (await mint(p.token)).json()) as { code: string }
    await inDO(p.stub, async (_instance, state) => {
      state.storage.sql.exec(`UPDATE auth_handoffs1 SET expires_at = ?`, Date.now() - 1)
    })
    const res = await redeem({ code })
    expect(res.status).toBe(400)
    expect(((await res.json()) as any).error.code).toBe("auth_handoff.invalid")
    expect(p.sessions).toHaveLength(0)
    expect(p.audits.at(-1)).toMatchObject({ op: "auth.handoff.refused", params: { stage: "redeem", reason: "expired" } })
  })

  it("a device signed in as another account is refused without spending the code; the right one then redeems", async () => {
    const p = await person()
    const { code } = (await (await mint(p.token)).json()) as { code: string }
    const wrong = await redeem({ code, device: "cmux16", expected_user: "someone-else" })
    expect(wrong.status).toBe(409)
    expect(((await wrong.json()) as any).error.code).toBe("auth_handoff.other_user")
    expect(p.sessions).toHaveLength(0)
    expect(p.audits.at(-1)).toMatchObject({ op: "auth.handoff.refused", params: { stage: "redeem", reason: "other_user", device: "cmux16" } })
    // Not spent: once that device signs out, it redeems the same code.
    const right = await redeem({ code, device: "cmux16" })
    expect(right.status).toBe(200)
    expect(p.sessions).toEqual([p.sub])
  })

  it("a device already signed in as the same user spends the code and gets no extra session", async () => {
    const p = await person()
    const { code } = (await (await mint(p.token)).json()) as { code: string }
    const same = await redeem({ code, device: "cmux16", expected_user: p.sub })
    expect(same.status).toBe(200)
    const answer = (await same.json()) as Record<string, unknown>
    expect(answer).toMatchObject({ already_signed_in: true, user: p.user, stack_user: p.sub, device: "cmux16" })
    expect(answer.refresh_token).toBeUndefined()
    expect(answer.access_token).toBeUndefined()
    expect(p.sessions).toHaveLength(0)
    expect(p.audits.at(-1)).toMatchObject({ op: "auth.handoff.redeemed", params: { reason: "already_signed_in" } })
    expect((await redeem({ code })).status).toBe(400)
  })

  it("never mints with an install token, an agent's token, no token or a bad one", async () => {
    const p = await person()
    // A real install of this person (install.register), so its token authenticates and reaches the human-session check.
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await op(p.token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: "cli", device_name: "laptop", platform: "macos" })
    expect(reg.ok, JSON.stringify(reg)).toBe(true)
    const install = (await mintAccessToken(testEnv, { user: p.user, team: p.team, install: reg.value.id, grant: reg.value.grant })).token
    const installRes = await mint(install)
    expect(installRes.status).toBe(403)
    expect(((await installRes.json()) as any).error.code).toBe("auth_handoff.human_session_required")
    // An agent's token on that install: refused either at the grant (401) or as not human (403), never minted.
    const agent = (await mintAccessToken(testEnv, { user: p.user, team: p.team, install: reg.value.id, grant: reg.value.grant, agent: "agent_x" })).token
    expect([401, 403]).toContain((await mint(agent)).status)
    expect((await mint(undefined)).status).toBe(401)
    expect((await mint("not-a-token")).status).toBe(401)
    expect(p.audits.filter((a) => a.op === "auth.handoff.minted")).toHaveLength(0)
  })

  it(`mints at most ${MINT_LIMIT} codes per person per ${MINT_WINDOW_MS / 60_000} minutes`, async () => {
    const p = await person()
    for (let i = 0; i < MINT_LIMIT; i++) expect((await mint(p.token)).status).toBe(201)
    const sixth = await mint(p.token)
    expect(sixth.status).toBe(429)
    expect(((await sixth.json()) as any).error.code).toBe("auth_handoff.rate_limited")
    expect(p.audits.at(-1)).toMatchObject({ op: "auth.handoff.refused", params: { stage: "mint", reason: "rate_limited" } })
    // Another person is not limited by this one.
    const q = await person()
    expect((await mint(q.token)).status).toBe(201)
    // Once the window has passed, minting works again.
    await inDO(p.stub, async (_instance, state) => {
      state.storage.sql.exec(`UPDATE auth_handoffs1 SET minted_at = ?`, Date.now() - MINT_WINDOW_MS - 1)
    })
    expect((await mint(p.token)).status).toBe(201)
  })

  it("refuses malformed codes before any Durable Object, and a Stack failure spends the code", async () => {
    for (const code of ["", "cmh_", "cmh_team_0000.x", `cmh_team_${"a".repeat(20)}.${"b".repeat(42)}`, 7]) {
      const res = await redeem({ code })
      expect(res.status).toBe(400)
      expect(((await res.json()) as any).error.code).toBe("auth_handoff.invalid")
    }
    // A code of another person's team that was never minted: one answer, no session.
    const p = await person({ failStack: true })
    const forged = await redeem({ code: `cmh_${p.team}.${"A".repeat(43)}` })
    expect(forged.status).toBe(400)
    const { code } = (await (await mint(p.token)).json()) as { code: string }
    const failed = await redeem({ code })
    expect(failed.status).toBe(503)
    expect(((await failed.json()) as any).error.code).toBe("auth_handoff.unavailable")
    expect(p.audits.at(-1)).toMatchObject({ op: "auth.handoff.refused", params: { stage: "redeem", reason: "stack_failed" } })
    // Fail closed: the code is spent, so a retry needs a new code.
    expect((await redeem({ code })).status).toBe(400)
  })

  it("validates the device label and expected_user", async () => {
    const p = await person()
    expect((await mint(p.token, { device: "x".repeat(65) })).status).toBe(400)
    expect((await mint(p.token, { device: "bad\nname" })).status).toBe(400)
    expect((await mint(p.token, { device: 3 })).status).toBe(400)
    const none = await mint(p.token, {})
    expect(none.status).toBe(201)
    const { code, device } = (await none.json()) as { code: string; device: string | null }
    expect(device).toBeNull()
    expect((await redeem({ code, expected_user: 5 })).status).toBe(400)
    expect((await redeem({ code, device: "y".repeat(65) })).status).toBe(400)
    // The bad requests spent nothing.
    expect((await redeem({ code })).status).toBe(200)
  })
})
