import { customFetch, errors, exportJWK, generateKeyPair, jwtVerify, SignJWT, type JWK, type JWTVerifyGetKey } from "jose"
import { describe, expect, it } from "vitest"
import { resilientKeys, stackRemoteKeys, StackKeysUnreachable } from "../src/auth.ts"

// own-machines-e2e run 43972821480: a fresh Stack token, then `user.ensure` answered 401 auth.unauthenticated.
// jose refetches Stack's key set once its cache is 10 min old and throws when that fetch fails, though the keys it
// holds still verify; every such blip told a signed-in person to sign in again.
const URL_ = new URL("https://api.stack-auth.com/api/v1/projects/p/.well-known/jwks.json")

const keyPair = async (kid: string) => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true })
  const jwk = { ...(await exportJWK(publicKey)), kid, alg: "ES256", use: "sig" } as JWK
  const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid }).setSubject("u").setIssuedAt().setExpirationTime("10m").sign(privateKey)
  return { jwk, token }
}

/** A key-set fetch that answers from `answers` in turn: a key set, an HTTP status, or a thrown error. */
const fetchFrom = (answers: Array<{ keys: JWK[] } | number | Error>) => {
  const seen = { calls: 0 }
  const fetch = async () => {
    const a = answers[Math.min(seen.calls++, answers.length - 1)]
    if (a instanceof Error) throw a
    if (typeof a === "number") return new Response("nope", { status: a })
    return new Response(JSON.stringify(a), { status: 200, headers: { "content-type": "application/json" } })
  }
  return { seen, fetch }
}

const verify = (token: string, keys: JWTVerifyGetKey) => jwtVerify(token, keys, { algorithms: ["ES256"] })

describe("Stack's key set through a failed refresh", () => {
  it("keeps verifying with the keys it holds when a refresh fails (timeout, network, non-200)", async () => {
    const { jwk, token } = await keyPair("k1")
    for (const fault of [new DOMException("timed out", "TimeoutError"), new TypeError("Network connection lost"), 503]) {
      const { seen, fetch } = fetchFrom([{ keys: [jwk] }, fault])
      // cacheMaxAge 0: every lookup refreshes, as the first one after 10 min does in production.
      const keys = stackRemoteKeys(URL_, { cacheMaxAge: 0, [customFetch]: fetch })
      expect((await verify(token, keys)).payload.sub).toBe("u")
      expect((await verify(token, keys)).payload.sub).toBe("u")
      expect(seen.calls).toBeGreaterThanOrEqual(2)
    }
  })

  it("fetches once more when it holds no keys yet (a cold isolate), and verifies when that answers", async () => {
    const { jwk, token } = await keyPair("k1")
    const { seen, fetch } = fetchFrom([503, { keys: [jwk] }])
    expect((await verify(token, stackRemoteKeys(URL_, { [customFetch]: fetch }))).payload.sub).toBe("u")
    expect(seen.calls).toBe(2)
  })

  it("says the keys were unreachable, never that the token is bad, when no fetch answers", async () => {
    const { token } = await keyPair("k1")
    const { seen, fetch } = fetchFrom([new TypeError("Network connection lost")])
    await expect(verify(token, stackRemoteKeys(URL_, { [customFetch]: fetch }))).rejects.toBeInstanceOf(StackKeysUnreachable)
    expect(seen.calls).toBe(2)
  })

  it("refuses a token whose key the set lacks, with one fetch and no retry", async () => {
    const { jwk } = await keyPair("k1")
    const { token: other } = await keyPair("k2")
    const { seen, fetch } = fetchFrom([{ keys: [jwk] }])
    await expect(verify(other, stackRemoteKeys(URL_, { [customFetch]: fetch }))).rejects.toBeInstanceOf(errors.JWKSNoMatchingKey)
    expect(seen.calls).toBe(1)
  })

  it("passes a lookup's own refusal through resilientKeys untouched", async () => {
    const refusal = new errors.JWKSMultipleMatchingKeys()
    let calls = 0
    const remote = Object.assign(async () => { calls++; throw refusal }, { jwks: () => undefined })
    await expect(resilientKeys(remote)({ alg: "ES256" }, { payload: "", signature: "" } as never)).rejects.toBe(refusal)
    expect(calls).toBe(1)
  })
})
