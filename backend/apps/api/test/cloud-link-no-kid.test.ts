import { describe, expect, it } from "vitest"
import { exportJWK, generateKeyPair } from "jose"
import { bindFile, cloudStub, DAEMON, post, SIZE, signedInWithInstall, WG_KEY } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (2026-10-05 rotation rules): when no kid has been published 24 h, the Worker
 * answers link_token with owner.unreachable (retryable) and mints nothing.
 */

const priv = async () => {
  const { privateKey } = await generateKeyPair("EdDSA", { crv: "Ed25519", extractable: true })
  const j = await exportJWK(privateKey)
  return { kty: j.kty, crv: j.crv, x: j.x, d: j.d }
}

describe("no signing kid ready", { timeout: 60_000 }, () => {
  it("answers owner.unreachable through the Worker", async () => {
    const a = await signedInWithInstall("cloud-bind-6", "mac")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const stub = cloudStub(a.team)
    const { json } = await bindFile(stub, machine)
    const host = (await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })).body.value.host as string
    const now = Date.now()
    await stub.fakeControl({ link_keys: JSON.stringify({ active: "n2", keys: { n1: await priv(), n2: await priv() }, published_at: { n1: now, n2: now } }) } as never)
    const r = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" })
    expect(r.body).toMatchObject({ ok: false, error: { code: "owner.unreachable", retryable: true } })
  })
})
