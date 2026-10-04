import { decodeProtectedHeader, importJWK, jwtVerify, SignJWT, type JWK } from "jose"

/**
 * Link tokens (state-placement.md 5.8 item 6, decision LINK-TOKEN-FORMAT): compact JWS, EdDSA
 * (Ed25519) through the `jose` library on Workers WebCrypto, never hand-written crypto or string
 * building. Header {alg: "EdDSA", kid, typ: "cmux-link+jwt"}; claims iss, aud (host id), sub
 * (install id), svc, epoch, iat, exp (at most 300 s after iat), jti (128 random bits), team.
 *
 * The private keys come only from the per-environment Worker secret CLOUD_LINK_SIGNING_KEYS
 * ({active, keys: {kid: private JWK}, published_at?: {kid: ms}}, at most 2 kids; a kid signs only 24 h after publication). They are imported per call, never logged,
 * never put in a response, error, event or storage. The VM receives the public keyset at bind.
 */

export const LINK_TOKEN_TYP = "cmux-link+jwt"
export const LINK_TOKEN_MAX_TTL_S = 300
export const MAX_ACTIVE_KIDS = 2

export interface SigningKeys {
  readonly active: string
  readonly keys: Readonly<Record<string, JWK>>
  /** When each kid entered the public keyset (ms). Required for every kid once there are two. */
  readonly published_at: Readonly<Record<string, number>>
}

/**
 * CLOUD-LINK-FOLLOWUPS (1): a kid is in the public keyset at least this long before it signs, so a
 * VM that refetches the keyset once a day already holds it when the first token arrives.
 */
export const KID_PUBLISH_LEAD_MS = 24 * 3600_000

export interface PublicKeyset {
  /** First 16 hex of sha256 over the canonical public keyset: what the VM holds. */
  readonly version: string
  readonly keys: Readonly<Record<string, JWK>>
}

export interface LinkClaims {
  readonly iss: string
  readonly aud: string
  readonly sub: string
  readonly svc: ReadonlyArray<string>
  readonly epoch: number
  readonly iat: number
  readonly exp: number
  readonly jti: string
  readonly team: string
}

const KID = /^[A-Za-z0-9._-]{1,64}$/
const isEd25519Private = (k: unknown): k is JWK => {
  const j = k as Record<string, unknown> | null
  return !!j && j.kty === "OKP" && j.crv === "Ed25519" && typeof j.x === "string" && typeof j.d === "string"
}

/** The configured signing keys, or null when unset or malformed (no partial use of a bad secret). */
export const parseSigningKeys = (raw: string | undefined): SigningKeys | null => {
  if (!raw) return null
  let v: { active?: unknown; keys?: unknown }
  try {
    v = JSON.parse(raw) as { active?: unknown; keys?: unknown }
  } catch {
    return null
  }
  const keys = v.keys && typeof v.keys === "object" ? (v.keys as Record<string, unknown>) : null
  if (!keys || typeof v.active !== "string") return null
  const kids = Object.keys(keys)
  if (kids.length < 1 || kids.length > MAX_ACTIVE_KIDS || !kids.includes(v.active)) return null
  if (!kids.every((k) => KID.test(k) && isEd25519Private(keys[k]))) return null
  const pub = (v as { published_at?: unknown }).published_at
  const published: Record<string, number> = {}
  if (pub !== undefined) {
    if (!pub || typeof pub !== "object") return null
    for (const [k, t] of Object.entries(pub as Record<string, unknown>)) {
      if (!kids.includes(k) || typeof t !== "number" || !Number.isFinite(t)) return null
      published[k] = t
    }
  }
  // A rotation (two kids) must say when each kid was published; only a lone legacy kid may omit it.
  if (kids.length > 1 && !kids.every((k) => k in published)) return null
  return { active: v.active, keys: keys as Record<string, JWK>, published_at: published }
}

/**
 * The kid that signs at `now`: the active kid once it has been published KID_PUBLISH_LEAD_MS,
 * else another kid that has; null when none has (the mint then refuses). A lone kid without
 * published_at signs at once.
 */
export const signingKid = (k: SigningKeys, now: number): string | null => {
  const ready = (kid: string) => (k.published_at[kid] === undefined ? Object.keys(k.keys).length === 1 : k.published_at[kid]! + KID_PUBLISH_LEAD_MS <= now)
  if (ready(k.active)) return k.active
  return Object.keys(k.keys).find((kid) => kid !== k.active && ready(kid)) ?? null
}

const sortedJson = (v: unknown): string =>
  JSON.stringify(v, (_k, x: unknown) => (x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.entries(x as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : 1))) : x))

/** The public half of the keyset (no `d`), with its version. */
export const publicKeyset = async (k: SigningKeys): Promise<PublicKeyset> => {
  const keys = Object.fromEntries(Object.keys(k.keys).sort().map((kid) => [kid, { kty: "OKP", crv: "Ed25519", x: k.keys[kid]!.x!, kid, alg: "EdDSA", use: "sig" } as JWK]))
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sortedJson(keys))))
  return { version: [...digest.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join(""), keys }
}

/** Signs one link token with `jose` (deterministic for a fixed key and claims: Ed25519). */
export const signLinkToken = async (claims: LinkClaims, kid: string, privateJwk: JWK): Promise<string> => {
  if (claims.exp - claims.iat > LINK_TOKEN_MAX_TTL_S || claims.exp <= claims.iat) throw new Error("link token lifetime out of range")
  const key = await importJWK({ ...privateJwk, alg: "EdDSA" }, "EdDSA")
  return new SignJWT({ svc: [...claims.svc], epoch: claims.epoch, team: claims.team })
    .setProtectedHeader({ alg: "EdDSA", kid, typ: LINK_TOKEN_TYP })
    .setIssuer(claims.iss)
    .setAudience(claims.aud)
    .setSubject(claims.sub)
    .setIssuedAt(claims.iat)
    .setExpirationTime(claims.exp)
    .setJti(claims.jti)
    .sign(key)
}

/** 128 random bits, base64url. */
export const newJti = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

export type VerifyError = "malformed" | "unknown_kid" | "bad_signature" | "typ" | "expired" | "aud" | "epoch" | "lifetime" | "replay"
export type VerifyResult = { readonly ok: true; readonly claims: LinkClaims } | { readonly ok: false; readonly error: VerifyError }

/**
 * The reference verifier the VM daemon must match (and the shared vectors encode): signature by a
 * kid in the keyset, typ, exp at `now` (seconds), aud = this host, epoch = this epoch, lifetime at
 * most 300 s, and a jti not seen before within its exp (`seen` is the daemon's replay set).
 */
export const verifyLinkToken = async (token: string, v: { aud: string; epoch: number; now: number; keyset: Readonly<Record<string, JWK>>; seen?: Set<string> }): Promise<VerifyResult> => {
  let kid: string | undefined
  try {
    const h = decodeProtectedHeader(token)
    if (h.alg !== "EdDSA") return { ok: false, error: "malformed" }
    if (h.typ !== LINK_TOKEN_TYP) return { ok: false, error: "typ" }
    kid = h.kid
  } catch {
    return { ok: false, error: "malformed" }
  }
  const jwk = kid === undefined ? undefined : v.keyset[kid]
  if (!jwk) return { ok: false, error: "unknown_kid" }
  let payload: Record<string, unknown>
  try {
    const key = await importJWK({ ...jwk, alg: "EdDSA" }, "EdDSA")
    payload = (await jwtVerify(token, key, { algorithms: ["EdDSA"], typ: LINK_TOKEN_TYP, currentDate: new Date(v.now * 1000), clockTolerance: 0 })).payload as Record<string, unknown>
  } catch (e) {
    const code = (e as { code?: string }).code
    return { ok: false, error: code === "ERR_JWT_EXPIRED" ? "expired" : code === "ERR_JWS_SIGNATURE_VERIFICATION_FAILED" ? "bad_signature" : "malformed" }
  }
  const c = payload as unknown as LinkClaims
  if (c.aud !== v.aud) return { ok: false, error: "aud" }
  if (c.epoch !== v.epoch) return { ok: false, error: "epoch" }
  if (typeof c.iat !== "number" || typeof c.exp !== "number" || c.exp - c.iat > LINK_TOKEN_MAX_TTL_S) return { ok: false, error: "lifetime" }
  if (v.seen) {
    if (v.seen.has(c.jti)) return { ok: false, error: "replay" }
    v.seen.add(c.jti)
  }
  return { ok: true, claims: c }
}
