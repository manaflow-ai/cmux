import type { Env } from "./env.ts"
import { hmacHex, timingSafeEqual } from "./ingress/verify.ts"

/**
 * Collect secrets for `GET /v1/pair/wait` (plans/cmux-next/server.md 6.2).
 *
 * The secret is `<nonce>.<hex HMAC(K, "cmux-pair-collect\n<code>\n<nonce>")>`
 * with K = HKDF-SHA256 of the API signing key, domain-separated per
 * environment (the same derivation as the automation webhook secrets, with
 * its own salt). The Worker checks it without state, so a forged code or
 * secret is refused before any PairingDO wakes. The nonce makes every begin's
 * secret different, and PairingDO still compares the exact secret's hash, so a
 * code that is reused after expiry cannot be waited on with an old secret.
 * WebCrypto only (workerd).
 */

const NONCE = /^[A-Za-z0-9_-]{22}$/
const MAC = /^[0-9a-f]{64}$/

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const b64uDecode = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0))

const keys = new Map<string, Promise<Uint8Array>>()
const collectKey = (env: Env): Promise<Uint8Array> => {
  // Keyed by the key material itself, so a rotated signing key derives fresh secrets in a warm isolate.
  const cacheKey = `${env.ENVIRONMENT}:${env.JWT_PRIVATE_JWK}`
  let k = keys.get(cacheKey)
  if (!k) {
    k = (async () => {
      const d = (JSON.parse(env.JWT_PRIVATE_JWK) as { d?: string }).d
      if (!d) throw new Error("JWT_PRIVATE_JWK has no private part")
      const ikm = await crypto.subtle.importKey("raw", b64uDecode(d), "HKDF", false, ["deriveBits"])
      const bits = await crypto.subtle.deriveBits(
        { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("cmux-pair-collect-v1"), info: new TextEncoder().encode(env.ENVIRONMENT) },
        ikm,
        256
      )
      return new Uint8Array(bits)
    })()
    keys.set(cacheKey, k)
  }
  return k
}

const collectMac = async (env: Pick<Env, "ENVIRONMENT" | "JWT_PRIVATE_JWK">, code: string, nonce: string) =>
  hmacHex(await collectKey(env as Env), `cmux-pair-collect\n${code}\n${nonce}`)

/** A fresh collect secret for this code (begin). */
export const collectSecret = async (env: Pick<Env, "ENVIRONMENT" | "JWT_PRIVATE_JWK">, code: string): Promise<string> => {
  const nonce = b64u(crypto.getRandomValues(new Uint8Array(16)))
  return `${nonce}.${await collectMac(env, code, nonce)}`
}

/** Did this Worker issue `secret` for `code`? Constant-time on the MAC; no Durable Object call. */
export const collectSecretValid = async (env: Pick<Env, "ENVIRONMENT" | "JWT_PRIVATE_JWK">, code: string, secret: string): Promise<boolean> => {
  const parts = secret.split(".")
  if (parts.length !== 2 || !NONCE.test(parts[0]!) || !MAC.test(parts[1]!)) return false
  return timingSafeEqual(parts[1]!, await collectMac(env, code, parts[0]!))
}
