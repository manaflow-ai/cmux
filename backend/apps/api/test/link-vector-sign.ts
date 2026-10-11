import { importJWK, SignJWT, type JWK } from "jose"
import type { LinkClaims } from "../src/link-token.ts"

/**
 * TEST ONLY: signs link-token claims with jose directly, bypassing signLinkToken's lifetime guard
 * and fixed typ, so the shared vectors can hold refusal cases (wrong typ, lifetime above 300 s).
 * Used by backend/packages/protocol/scripts/export-link-token-vectors.ts; never by the Worker.
 */
export const rawSignLinkToken = async (c: LinkClaims, kid: string, typ: string, privateJwk: JWK): Promise<string> =>
  new SignJWT({ svc: [...c.svc], epoch: c.epoch, team: c.team })
    .setProtectedHeader({ alg: "EdDSA", kid, typ })
    .setIssuer(c.iss)
    .setAudience(c.aud)
    .setSubject(c.sub)
    .setIssuedAt(c.iat)
    .setExpirationTime(c.exp)
    .setJti(c.jti)
    .sign(await importJWK({ ...privateJwk, alg: "EdDSA" }, "EdDSA"))
