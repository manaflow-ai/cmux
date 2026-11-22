import { user } from "@cmux/home-core"
import { describe, expect, it } from "vitest"

/**
 * home-core's device proofs use node:crypto (createPublicKey with a JWK, verify with the
 * bare key and DER signatures; workerd has no dsaEncoding option) and Buffer base64url. This runs them inside workerd
 * (nodejs_compat), where the UserDO will run them, not only under Node or Bun.
 */
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const sha256 = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", b))
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
    const assertion = b64u(cborMap([["authenticatorData", authData], ["signature", user.rawToDer(await sign(pair, nonce))]]))
    const key = { jwk, app_id_hash: b64u(appIdHash), counter: 6 }
    expect(user.verifyAppAttest(key, payload, assertion)).toEqual({ ok: true, counter: 7 })
    expect(user.verifyAppAttest({ ...key, counter: 7 }, payload, assertion)).toEqual({ ok: false })
    expect(user.verifyAppAttest(key, { ...payload, nonce: "n-2" }, assertion)).toEqual({ ok: false })
  })

  it("rawToDer: fixed cases (zero-prefixed, high-bit and all-zero halves) are minimal DER", () => {
    const hex = (b: Uint8Array) => Buffer.from(b).toString("hex")
    const half = (lead: Array<number>) => Uint8Array.from([...lead, ...new Array(32 - lead.length).fill(0x11)])
    // r with two leading zero bytes, s with the high bit set (needs a 0x00 pad).
    const r = half([0x00, 0x00, 0x7f])
    const s = Uint8Array.from([0x80, ...new Array(31).fill(0x22)])
    const der = user.rawToDer(Uint8Array.from([...r, ...s]))
    expect(hex(der.subarray(0, 4))).toBe("3043021e")
    expect(hex(der.subarray(4, 5))).toBe("7f")
    expect(hex(der.subarray(34, 37))).toBe("022100")
    expect(der.length).toBe(69)
    // All-zero halves encode as INTEGER 0 (02 01 00); verify refuses them.
    expect(hex(user.rawToDer(new Uint8Array(64)))).toBe("3006020100020100")
  })

  it("verifyPresence refuses an all-zero signature and accepts signatures whose r starts with zero bytes", async () => {
    const { pair, jwk } = await newKey()
    expect(user.verifyPresence(jwk, payload, b64u(new Uint8Array(64)))).toBe(false)
    // Sign until r has a leading zero byte (about 1 in 256), so the minimal encoding path runs.
    for (let i = 0; i < 2000; i++) {
      const p = { ...payload, nonce: `n-${i}` }
      const raw = await sign(pair, new Uint8Array(user.proofMessage(p)))
      if (raw[0] !== 0) continue
      expect(user.verifyPresence(jwk, p, b64u(raw))).toBe(true)
      return
    }
    throw new Error("no zero-prefixed signature in 2000 tries")
  })
})
