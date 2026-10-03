import { user } from "@cmux/home-core"
import { describe, expect, it } from "vitest"

/**
 * home-core's device proofs use node:crypto (createPublicKey with a JWK, verify with
 * ieee-p1363 and der encodings) and Buffer base64url. This runs them inside workerd
 * (nodejs_compat), where the UserDO will run them, not only under Node or Bun.
 */
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const sha256 = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", b))
const toDer = (raw: Uint8Array): Uint8Array => {
  const int = (b: Uint8Array) => {
    let i = 0
    while (i < b.length - 1 && b[i] === 0) i++
    const v = b.slice(i)
    return v[0]! & 0x80 ? Uint8Array.of(0, ...v) : v
  }
  const r = int(raw.slice(0, 32))
  const s = int(raw.slice(32))
  return Uint8Array.of(0x30, r.length + s.length + 4, 0x02, r.length, ...r, 0x02, s.length, ...s)
}
/** CBOR map {authenticatorData: bytes, signature: bytes} (definite lengths). */
const cborBytes = (b: Uint8Array) => (b.length < 24 ? Uint8Array.of(0x40 | b.length, ...b) : b.length < 256 ? Uint8Array.of(0x58, b.length, ...b) : Uint8Array.of(0x59, b.length >> 8, b.length & 255, ...b))
const cborText = (s: string) => Uint8Array.of(0x60 | s.length, ...new TextEncoder().encode(s))
const cborMap = (entries: Array<[string, Uint8Array]>) => Uint8Array.from([0xa0 | entries.length, ...entries.flatMap(([k, v]) => [...cborText(k), ...cborBytes(v)])])

const newKey = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { pair, jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! } }
}
const sign = async (pair: CryptoKeyPair, data: Uint8Array) => new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, data))

const payload: user.ProofPayload = { op: user.LOWER_OP, user: "user_x", install: "inst_x", new_level: "none", nonce: "n-1", expires_at: 1_900_000_000_000 }

describe("home-core device proofs run in workerd", () => {
  it("Buffer base64url round-trips", () => {
    const bytes = Uint8Array.from([0, 250, 251, 252, 253, 254, 255])
    const enc = Buffer.from(bytes).toString("base64url")
    expect(enc).toBe(b64u(bytes))
    expect([...Buffer.from(enc, "base64url")]).toEqual([...bytes])
  })

  it("verifyPresence: createPublicKey(jwk) + verify(ieee-p1363) accept a valid raw signature and refuse a changed payload", async () => {
    const { pair, jwk } = await newKey()
    const sig = b64u(await sign(pair, new Uint8Array(user.proofMessage(payload))))
    expect(user.verifyPresence(jwk, payload, sig)).toBe(true)
    expect(user.verifyPresence(jwk, { ...payload, new_level: "all" }, sig)).toBe(false)
    expect(user.verifyPresence({ ...jwk, d: "x" }, payload, sig)).toBe(false)
  })

  it("verifyAppAttest: verify(der) over sha256(authData || clientDataHash), app id hash and counter", async () => {
    const { pair, jwk } = await newKey()
    const appIdHash = await sha256(new TextEncoder().encode("TEAMID1234.com.cmuxterm.ios"))
    const authData = Uint8Array.from([...appIdHash, 0x40, 0, 0, 0, 7])
    const clientDataHash = await sha256(new Uint8Array(user.proofMessage(payload)))
    const nonce = await sha256(Uint8Array.from([...authData, ...clientDataHash]))
    // WebCrypto hashes its input, so signing `nonce` yields ECDSA over sha256(nonce), as Apple does.
    const assertion = b64u(cborMap([["authenticatorData", authData], ["signature", toDer(await sign(pair, nonce))]]))
    const key = { jwk, app_id_hash: b64u(appIdHash), counter: 6 }
    expect(user.verifyAppAttest(key, payload, assertion)).toEqual({ ok: true, counter: 7 })
    expect(user.verifyAppAttest({ ...key, counter: 7 }, payload, assertion)).toEqual({ ok: false })
    expect(user.verifyAppAttest(key, { ...payload, nonce: "n-2" }, assertion)).toEqual({ ok: false })
  })
})
