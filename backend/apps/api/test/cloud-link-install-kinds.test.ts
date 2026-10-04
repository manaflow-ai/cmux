import { describe, expect, it } from "vitest"
import vectors from "../../../catalog/cloud-vectors.json"
import { createdAndBound, installOf, person, post, signedInWithInstall } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (2): only the cli, mac app and ios installs mint link tokens; vm, daemon and
 * web installs (and an install whose kind is unknown) get the typed cloud.link.install_refused.
 */

describe("link_token install kinds", { timeout: 60_000 }, () => {
  it("mints for cli, mac and ios installs and refuses vm, daemon, web and an unknown kind", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    for (const kind of ["cli", "mac", "ios"]) expect(await x.stub.mintLinkToken(x.team, installOf(x.p, undefined, kind), { host, services: ["ssh"] }), kind).toMatchObject({ ok: true })
    for (const kind of ["vm", "daemon", "web", ""]) {
      const r = await x.stub.mintLinkToken(x.team, installOf(x.p, undefined, kind), { host, services: ["ssh"] })
      expect(r, kind).toMatchObject({ ok: false, code: "cloud.link.install_refused" })
    }
  })

  it("answers the vector shape through the Worker for a vm install", async () => {
    const v = (vectors as unknown as { cases: Array<{ name: string; responses: Array<{ http: { status: number }; body: any }> }> }).cases.find((c) => c.name === "machine.link_token.install_refused")
    expect(v, "vector machine.link_token.install_refused").toBeDefined()
    const a = await signedInWithInstall("cloud-bind-4", "vm")
    const r = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host: "host_h0000000000000000009", services: ["ssh"] }, origin: "cli" })
    expect(r.status).toBe(v!.responses[0]!.http.status)
    expect(r.body.error).toMatchObject({ code: "cloud.link.install_refused", details: v!.responses[0]!.body.error.details })
  })
})
