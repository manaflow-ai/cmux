import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { cloudOpByName, cloudOps, Grant, Install, mutationErrors, PublicJwk } from "../src/index.ts"

// The cloud operation catalog is the contract for the API Worker, MCP, the CLI and the generated
// clients (catalog:export). These checks hold for every op, so a new op cannot break them silently.
describe("cloud operation catalog", () => {
  it("names are unique, dotted, and all reachable by name", () => {
    const names = cloudOps.map((o) => o.name)
    expect(new Set(names).size).toBe(names.length)
    expect(cloudOpByName.size).toBe(names.length)
    for (const name of names) expect([name, /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_-]*)+$/.test(name)]).toEqual([name, true])
  })

  it("never exposes a system op, and every op names its callers and has docs", () => {
    for (const op of cloudOps) {
      expect([op.name, (op.principals as ReadonlyArray<string>).includes("system")]).toEqual([op.name, false])
      expect([op.name, op.principals.length > 0, op.docs.trim().length > 0]).toEqual([op.name, true, true])
    }
  })

  it("class and risk agree, and every mutation declares the shared mutation errors", () => {
    // revision.conflict applies only to revisioned state; Home ops (conversations, DMs) have none.
    const shared = mutationErrors.filter((code) => code !== "revision.conflict")
    for (const op of cloudOps) {
      expect([op.name, op.class === "read" ? op.risk === "read" : op.risk !== "read"]).toEqual([op.name, true])
      if (op.class === "mutation") for (const code of shared) expect([op.name, code, op.errors.includes(code)]).toEqual([op.name, code, true])
    }
  })

  it("only an install-only mutation may opt out of the idempotency key, and it says why", () => {
    for (const op of cloudOps) {
      if (op.idempotency !== "none") continue
      expect([op.name, op.class, op.principals]).toEqual([op.name, "mutation", ["install"]])
      expect([op.name, /No idempotency key/.test(op.docs)]).toEqual([op.name, true])
    }
  })

  it("visible CLI paths are unique", () => {
    const visible = cloudOps.filter((o) => o.cli.visible).map((o) => o.cli.path)
    expect(visible.filter((p) => !p)).toEqual([])
    expect(visible.filter((p, i) => visible.indexOf(p) !== i)).toEqual([])
  })

  it("every params schema refuses null (the Worker never passes it through)", () => {
    for (const op of cloudOps) {
      const exit = Schema.decodeUnknownExit(op.params as Schema.Codec<unknown, unknown>)(null)
      expect([op.name, exit._tag]).toEqual([op.name, "Failure"])
    }
  })
})

describe("shared schemas round-trip", () => {
  const jwk = { kty: "EC", crv: "P-256", x: "a".repeat(43), y: "b".repeat(43) } as const
  const grant = { id: `grant_${"a".repeat(20)}`, grantee: "install_1", op_classes: ["read"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" } as const

  it("PublicJwk decodes an ES256 key, encodes it back unchanged, and refuses another curve", () => {
    const decoded = Schema.decodeUnknownSync(PublicJwk)(jwk)
    expect(Schema.encodeSync(PublicJwk)(decoded)).toEqual(jwk)
    expect(Schema.decodeUnknownExit(PublicJwk)({ ...jwk, crv: "P-384" })._tag).toBe("Failure")
    expect(Schema.decodeUnknownExit(PublicJwk)({ ...jwk, x: "short" })._tag).toBe("Failure")
  })

  it("Grant round-trips and refuses an unknown approval", () => {
    const decoded = Schema.decodeUnknownSync(Grant)(grant)
    expect(Schema.encodeSync(Grant)(decoded)).toEqual(grant)
    expect(Schema.decodeUnknownExit(Grant)({ ...grant, approval: "always" })._tag).toBe("Failure")
  })

  it("Install refuses a record without its public key", () => {
    expect(Schema.decodeUnknownExit(Install)({ id: "install_1" })._tag).toBe("Failure")
  })
})
