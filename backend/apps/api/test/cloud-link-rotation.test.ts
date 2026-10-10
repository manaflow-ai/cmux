import { describe, expect, it } from "vitest"
import { generateKeyPair, exportJWK } from "jose"
import { parseSigningKeys, signingKid, KID_PUBLISH_LEAD_MS } from "../src/link-token.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (1), publication rule: a new kid is in the public keyset at least 24 h before
 * it signs, so a VM that refetches once a day already holds it. With two kids every kid names its
 * published_at; one legacy kid without published_at may sign at once.
 */

const priv = async () => {
  const { privateKey } = await generateKeyPair("EdDSA", { crv: "Ed25519", extractable: true })
  const j = await exportJWK(privateKey)
  return { kty: j.kty, crv: j.crv, x: j.x, d: j.d }
}

describe("link signing key publication lead", () => {

  it("two kids without published_at are refused; one legacy kid signs at once", async () => {
    const [a, b] = [await priv(), await priv()]
    expect(parseSigningKeys(JSON.stringify({ active: "k1", keys: { k1: a, k2: b } }))).toBeNull()
    const one = parseSigningKeys(JSON.stringify({ active: "k1", keys: { k1: a } }))!
    expect(signingKid(one, Date.now())).toBe("k1")
  })

})
