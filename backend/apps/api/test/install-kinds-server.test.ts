import { describe, expect, it } from "vitest"
import { post, sessionToken } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (4): a client never declares a server install. install.register refuses kind
 * "vm" and "daemon"; the server creates those itself (pairing makes the daemon install, the Cloud
 * bind flow will make the VM install), each with its fixed kind.
 */

const jwk = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { kty: "EC", crv: "P-256", x: j.x!, y: j.y! }
}

describe("server install kinds are never self-declared", { timeout: 60_000 }, () => {
  it("install.register refuses vm and daemon from a client, and still takes mac, cli and ios", async () => {
    const session = await sessionToken("install-kinds-server")
    await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
    const reg = async (kind: string) =>
      (await post("/v1/ops", session, { op: "install.register", params: { public_jwk: await jwk(), kind, name: kind, device_name: kind, platform: "linux" }, idempotency_key: crypto.randomUUID(), origin: "user" })).body
    for (const kind of ["vm", "daemon"]) expect(await reg(kind), kind).toMatchObject({ ok: false, error: { code: "install.kind_reserved" } })
    for (const kind of ["mac", "cli", "ios"]) expect((await reg(kind)).ok, kind).toBe(true)
  })
})
