import type { Principal } from "@cmux/ownership"
import { createLocalJWKSet, createRemoteJWKSet, decodeJwt, importJWK, jwtVerify, SignJWT, type JWK, type JWTVerifyGetKey } from "jose"
import { personalTeamIdFor, userIdFor } from "./domains/user.ts"
import type { Env } from "./env.ts"

const STACK_API = "https://api.stack-auth.com"
export const ACCESS_TOKEN_TTL_SECONDS = 600

const stackKeySets = new Map<string, JWTVerifyGetKey>()
const stackKeys = (env: Env): JWTVerifyGetKey => {
  if (env.ENVIRONMENT === "test" && env.STACK_TEST_JWKS) return createLocalJWKSet(JSON.parse(env.STACK_TEST_JWKS) as { keys: Array<JWK> })
  let keys = stackKeySets.get(env.STACK_PROJECT_ID)
  if (!keys) {
    keys = createRemoteJWKSet(new URL(`${STACK_API}/api/v1/projects/${env.STACK_PROJECT_ID}/.well-known/jwks.json`), {
      cacheMaxAge: 10 * 60_000,
      cooldownDuration: 30_000
    })
    stackKeySets.set(env.STACK_PROJECT_ID, keys)
  }
  return keys
}

export const issuer = (env: Env) => `https://cmux-api/${env.ENVIRONMENT}`

/** A Stack access token: a human session. */
const sessionPrincipal = async (env: Env, token: string): Promise<Principal | undefined> => {
  try {
    const { payload } = await jwtVerify(token, stackKeys(env), {
      algorithms: ["ES256"],
      issuer: `${STACK_API}/api/v1/projects/${env.STACK_PROJECT_ID}`,
      audience: env.STACK_PROJECT_ID,
      clockTolerance: 60
    })
    if (typeof payload.sub !== "string" || !payload.sub || payload.is_anonymous === true) return undefined
    const user = userIdFor(env.STACK_PROJECT_ID, payload.sub)
    const email = typeof payload.email === "string" ? payload.email : null
    // Only an explicit `true` counts: absent, false or any other value means unverified.
    const emailVerified = email !== null && payload.email_verified === true
    const name = typeof payload.name === "string" && payload.name ? payload.name : undefined
    return {
      kind: "session",
      identity: `session:${user}`,
      user,
      team: personalTeamIdFor(user),
      stack_user_id: payload.sub,
      email,
      email_verified: emailVerified,
      ...(typeof payload.exp === "number" ? { expires_at: payload.exp * 1000 } : {}),
      ...(name ? { display_name: name } : {}),
      // SSO is never read from the token (Stack tokens carry no custom claims); policy-gate.ts
      // resolves it from TeamDO's record of the sessions our OIDC callback created.
      ...(typeof payload.refresh_token_id === "string" && payload.refresh_token_id ? { stack_session: payload.refresh_token_id } : {})
    }
  } catch {
    return undefined
  }
}

let signingKey: { key: CryptoKey; kid: string } | undefined
const privateJwk = (env: Env) => JSON.parse(env.JWT_PRIVATE_JWK) as JWK & { kid?: string }

export const publicJwks = (env: Env) => {
  const { d: _d, ...pub } = privateJwk(env)
  return { keys: [{ ...pub, alg: "ES256", use: "sig" }] }
}

const signer = async (env: Env) => {
  if (!signingKey) {
    const jwk = privateJwk(env)
    signingKey = { key: (await importJWK(jwk, "ES256")) as CryptoKey, kid: jwk.kid ?? "k1" }
  }
  return signingKey
}

export interface InstallClaims {
  readonly user: string
  readonly team: string
  readonly install: string
  readonly grant: string
  /** The team whose SSO session registered the install, if any (P17-4). */
  readonly sso_team?: string
}

export const mintAccessToken = async (env: Env, c: InstallClaims) => {
  const { key, kid } = await signer(env)
  const now = Math.floor(Date.now() / 1000)
  const exp = now + ACCESS_TOKEN_TTL_SECONDS
  const token = await new SignJWT({ team: c.team, inst: c.install, grant: c.grant, ...(c.sso_team ? { sso_team: c.sso_team } : {}) })
    .setProtectedHeader({ alg: "ES256", kid, typ: "JWT" })
    .setIssuer(issuer(env))
    .setAudience("api")
    .setSubject(c.user)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(key)
  return { token, expires_at: exp * 1000 }
}

const installPrincipal = async (env: Env, token: string): Promise<Principal | undefined> => {
  try {
    const { payload } = await jwtVerify(token, createLocalJWKSet(publicJwks(env) as { keys: Array<JWK> }), {
      algorithms: ["ES256"],
      issuer: issuer(env),
      audience: "api",
      clockTolerance: 30
    })
    const { sub, team, inst, grant, exp, sso_team } = payload as { sub?: unknown; team?: unknown; inst?: unknown; grant?: unknown; exp?: unknown; sso_team?: unknown }
    if (typeof sub !== "string" || typeof team !== "string" || typeof inst !== "string" || typeof grant !== "string") return undefined
    return { kind: "install", identity: inst, user: sub, team, install: inst, grant, ...(typeof exp === "number" ? { expires_at: exp * 1000 } : {}), ...(typeof sso_team === "string" ? { sso_team } : {}) }
  } catch {
    return undefined
  }
}

/**
 * For owners other than UserDO: asks the grant's owner whether the install is
 * active and what its grant allows, and carries the classes on the principal.
 * Undefined means refuse (revoked, unknown, or expired grant).
 */
export const withGrantClasses = async (env: Env, p: Principal): Promise<Principal | undefined> => {
  if (p.kind === "session") return p
  if (!p.user || !p.install || !p.grant) return undefined
  const stub = env.USER_DO.get(env.USER_DO.idFromName(p.user))
  const r = (await stub.installGrant(p.user, p.install, p.grant)) as
    | { ok: true; op_classes: ReadonlyArray<string>; kind: string; email: string | null; email_verified: boolean }
    | { ok: false }
  return r.ok ? { ...p, grant_classes: [...r.op_classes], install_kind: r.kind, email: r.email, email_verified: r.email_verified } : undefined
}

/** Resolves the bearer token: our install JWT, else a Stack session token. */
export const authenticate = async (env: Env, token: string | undefined): Promise<Principal | undefined> => {
  if (!token) return undefined
  let iss: unknown
  try {
    iss = decodeJwt(token).iss
  } catch {
    return undefined
  }
  return iss === issuer(env) ? installPrincipal(env, token) : sessionPrincipal(env, token)
}

/**
 * DER ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) to raw r||s for P-256, or null when
 * malformed. iOS Security.framework (.ecdsaSignatureMessageX962SHA256) signs in DER.
 */
export const derToRawP256 = (der: Uint8Array): Uint8Array | null => {
  if (der.length < 8 || der.length > 72 || der[0] !== 0x30 || der[1] !== der.length - 2) return null
  const out = new Uint8Array(64)
  let at = 2
  for (const slot of [0, 32]) {
    if (at + 2 > der.length || der[at] !== 0x02) return null
    const len = der[at + 1]!
    const start = at + 2
    if (len < 1 || len > 33 || start + len > der.length) return null
    let v = der.subarray(start, start + len)
    // Minimal, non-negative INTEGERs only: no high bit without a pad, and a leading zero
    // only to pad a high bit. A 33-byte value must be such a pad.
    if (v[0]! & 0x80) return null
    if (v.length > 1 && v[0] === 0 && (v[1]! & 0x80) === 0) return null
    if (v.length === 33) v = v.subarray(1)
    out.set(v, slot + 32 - v.length)
    at = start + len
  }
  return at === der.length ? out : null
}

/** Verifies an ES256 signature (raw r||s, or DER from iOS), base64url, with an install's public JWK. */
export const verifyInstallSignature = async (jwk: JsonWebKey, message: string, signatureB64u: string): Promise<boolean> => {
  try {
    const key = await crypto.subtle.importKey("jwk", { ...jwk, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"])
    const bytes = Uint8Array.from(atob(signatureB64u.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(signatureB64u.length / 4) * 4, "=")), (c) => c.charCodeAt(0))
    const data = new TextEncoder().encode(message)
    const verify = (sig: Uint8Array) => crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, data)
    // 64 bytes is raw r||s, except a rare 64-byte DER signature: try raw, then DER.
    if (bytes.length === 64 && (await verify(bytes))) return true
    const der = derToRawP256(bytes)
    return der ? await verify(der) : false
  } catch {
    return false
  }
}
