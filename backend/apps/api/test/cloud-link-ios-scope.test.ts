import { cloudOps, OpClass } from "@cmux/protocol"
import { Schema } from "effect"
import { defaultInstallClasses } from "../src/domains/user.ts"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, createdAndBound, DAEMON, installOf, person, post, SIZE, signedInWithInstall, WG_KEY } from "./cloud-bind-support.ts"

/**
 * CLOUD-LINK-FOLLOWUPS (5): the iPhone install gets one narrow grant class, `cloud-link`, that
 * covers cloud.machine.link_token and nothing else. iOS never gets general execute.
 */

describe("cloud-link grant class", { timeout: 60_000 }, () => {
  it("is a grant class that no op declares as its risk, so it opens no other op", () => {
    expect(Schema.is(OpClass)("cloud-link")).toBe(true)
    expect(cloudOps.filter((d) => (d.risk as string) === "cloud-link").map((d) => d.name)).toEqual([])
  })

  it("an install with only cloud-link mints a link token; without execute or cloud-link it is refused", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p, ["cloud-link"], "ios"), { host, services: ["ssh"] })).toMatchObject({ ok: true })
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p, ["read", "mutate-own"], "ios"), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "auth.forbidden" })
    // cloud-link does not cover a read: connect_info and list still need read.
    expect(await x.stub.readOp(x.team, installOf(x.p, ["cloud-link"], "ios"), "cloud.machine.list", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("a real iPhone install's default grant mints a link token through the Worker, and gets no execute", async () => {
    const a = await signedInWithInstall("cloud-bind-5", "ios")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    const host = bound.body.value.host as string
    const minted = await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" })
    expect(minted.body, JSON.stringify(minted.body)).toMatchObject({ ok: true })
    // The iPhone default grant: read, mutate-own and cloud-link; never execute.
    expect([...defaultInstallClasses("ios")].sort()).toEqual(["cloud-link", "mutate-own", "read"])
  })
})
