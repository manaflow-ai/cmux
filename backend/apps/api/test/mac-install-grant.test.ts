import { defaultInstallClasses } from "../src/domains/user.ts"
import { describe, expect, it } from "vitest"
import { post, sessionToken, signedInWithInstall } from "./cloud-bind-support.ts"

/**
 * cx-wb5.64 (chief decision 2026-10-08): the Mac app's install grant is read, mutate-own,
 * mutate-shared and cloud-link. It never gets execute (no terminal input, code or CUA acts from a
 * stolen Mac install token). The server enforces it; a client narrowing at register is not a
 * boundary. money and destructive stay session-only for every install (G8 approvals, cx-wb5.65).
 */

const register = async (session: string, kind: string, op_classes?: ReadonlyArray<string>) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return post("/v1/ops", session, {
    op: "install.register",
    params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: kind, device_name: kind, platform: "macos", ...(op_classes ? { op_classes } : {}) },
    idempotency_key: crypto.randomUUID(),
    origin: "user"
  })
}

describe("the Mac install grant", { timeout: 60_000 }, () => {
  it("defaults to read, mutate-own, mutate-shared and cloud-link, never execute", () => {
    expect([...defaultInstallClasses("mac")].sort()).toEqual(["cloud-link", "mutate-own", "mutate-shared", "read"])
  })

  it("a mac register that asks for execute is refused", async () => {
    const session = await sessionToken("mac-grant-1")
    await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
    const refused = await register(session, "mac", ["read", "execute"])
    expect(refused.body, JSON.stringify(refused.body)).toMatchObject({ ok: false, error: { code: "validation.invalid" } })
    const narrowed = await register(session, "mac", ["read"])
    expect(narrowed.body, JSON.stringify(narrowed.body)).toMatchObject({ ok: true })
  })

  it("a real mac install token is refused an execute op and can still read", async () => {
    const mac = await signedInWithInstall("mac-grant-2", "mac")
    const upgrade = await post("/v1/ops", mac.installToken, { op: "cloud.machine.upgrade", params: { machine: "vm_00000000000000000000000000" }, idempotency_key: crypto.randomUUID(), origin: "cli" })
    expect(upgrade.body, JSON.stringify(upgrade.body)).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    const list = await post("/v1/read", mac.installToken, { op: "cloud.machine.list", params: {} })
    expect(list.body, JSON.stringify(list.body)).toMatchObject({ ok: true })
  })
})
