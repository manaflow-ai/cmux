import { CloudConnectInfo, overlayAddress } from "@cmux/protocol"
import { env } from "cloudflare:workers"
import { Exit, Schema } from "effect"
import type { SubmitResult } from "../src/owner-do.ts"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, createdAndBound, DAEMON, ensureUser, frame, person, post, reply, signedInWithInstall, SIZE, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { SHARED_TEAM } from "./setup/cloud-teams.ts"

/**
 * Part 3: cloud.machine.connect_info (state-placement.md 5.8 items 3-4, contract 1.7, decision
 * CLOUD-CONNECT-ACCESS): exactly one of machine|host, not_bound before bind, the overlay address
 * from the host id (transport.md 3.1), services from team policy (cloud.connectServices), personal
 * machines for their creator only, every call audited without secrets.
 */

describe("overlay address (transport.md 3.1)", () => {
  it("is fd7c:6d78::/32 plus the first 96 bits of sha256(id), the same as cmux-link's overlay_addr.rs", async () => {
    // Reference values from the Rust derivation's algorithm (RFC 5952 text form).
    expect(await overlayAddress("inst_1")).toBe("fd7c:6d78:f4a0:cf32:b1d:3887:6548:15e5")
    expect(await overlayAddress("host_0123456789abcdef0123")).toBe("fd7c:6d78:f88f:f2d3:66e:5b72:7958:91e2")
  })
})

describe("part 3: connect_info", { timeout: 60_000 }, () => {
  it("answers the bound machine by machine or by host, with no credential", async () => {
    const x = person()
    const { machine, host } = await createdAndBound(x)
    for (const params of [{ machine }, { host }]) {
      const r = await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", params)
      expect(r.ok, JSON.stringify(r)).toBe(true)
      expect(Exit.isSuccess(Schema.decodeUnknownExit(CloudConnectInfo as Schema.Codec<unknown, unknown>)(r.value))).toBe(true)
      expect(r.value).toMatchObject({
        machine,
        host,
        epoch: 1,
        state: "running",
        peer: { wg_public_key: WG_KEY, overlay_address: await overlayAddress(host), vpc_endpoint: null, public_ipv6: null },
        gateway: null,
        services: ["daemon", "ssh"],
        daemon: DAEMON
      })
      expect(JSON.stringify(r.value)).not.toMatch(/token/i)
    }
  })

  it("refuses both or neither selector, answers not_found and not_bound", async () => {
    const x = person()
    const { machine, host } = await createdAndBound(x)
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", { machine, host })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", {})).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", { machine: "vm_00000000000000000009" })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", { host: "host_00000000000000000009" })).toMatchObject({ ok: false, code: "cloud.machine.not_found" })
    const unbound = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    expect(await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", { machine: unbound })).toMatchObject({ ok: false, code: "cloud.machine.not_bound" })
  })

  it("a personal machine is for its creator only; a team machine for every member", async () => {
    const alice = person()
    const { machine } = await createdAndBound(alice)
    const bob = { ...person().p, team: alice.team }
    expect(await alice.stub.readOp(alice.team, bob, "cloud.machine.connect_info", { machine })).toMatchObject({ ok: false, code: "auth.forbidden" })

    // A team machine binds only while its creator is a member of the team (cx-44j.51): TeamDO must list
    // the owner. team.ensure_personal is the one op that seeds a member row without an invite flow.
    const owner = person(SHARED_TEAM)
    const teams = (env as unknown as { TEAM_DO: DurableObjectNamespace }).TEAM_DO
    const teamDO = teams.get(teams.idFromName(SHARED_TEAM)) as unknown as { submit(e: string, p: unknown, f: unknown): Promise<SubmitResult> }
    expect(reply(await teamDO.submit(SHARED_TEAM, owner.p, { t: "op", op: "team.ensure_personal", params: {}, idempotency_key: `seed:${owner.user}`, origin: "cli" })).t).toBe("result")
    const shared = await createdAndBound(owner)
    const member = { ...person().p, team: SHARED_TEAM }
    const r = await owner.stub.readOp(SHARED_TEAM, member, "cloud.machine.connect_info", { machine: shared.machine })
    expect(r).toMatchObject({ ok: true, value: { services: ["daemon", "ssh"] } })
  })

  it("audits every call (who, when, which machine), never a secret", async () => {
    const x = person()
    const { machine, host } = await createdAndBound(x)
    const file = await bindFile(x.stub, machine)
    await x.stub.readOp(x.team, x.p, "cloud.machine.connect_info", { host })
    const audit = (await x.stub.fakeControl({})).audit.filter((a) => a.op === "connect_info")
    expect(audit).toEqual([expect.objectContaining({ op: "connect_info", machine, host, by: x.p.identity, user: x.p.user, at: expect.any(Number) })])
    expect(JSON.stringify(audit)).not.toContain(file.json.bind_token)
  })
})

describe("part 3 through the Worker: team policy cloud.connectServices", { timeout: 60_000 }, () => {
  it("lists only the services the team policy allows; none = auth.forbidden", async () => {
    const a = await signedInWithInstall("cloud-bind-1")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(created.body.ok, JSON.stringify(created.body)).toBe(true)
    const machine = created.body.value.machine.id as string
    const stub = cloudStub(a.team)
    const { json } = await bindFile(stub, machine)
    expect((await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })).status).toBe(200)
    const full = await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine } })
    expect(full.status, JSON.stringify(full.body)).toBe(200)
    expect(full.body.value.services).toEqual(["daemon", "ssh"])
    const set = await post("/v1/ops", a.session, {
      op: "team.policy.update",
      params: { changes: [{ key: "cloud.connectServices", value: { value: ["ssh"], mode: "enforced" } }], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    expect(set.body.ok, JSON.stringify(set.body)).toBe(true)
    expect((await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine } })).body.value.services).toEqual(["ssh"])
    const none = await post("/v1/ops", a.session, {
      op: "team.policy.update",
      params: { changes: [{ key: "cloud.connectServices", value: { value: [], mode: "enforced" } }], expected_version: 1 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    expect(none.body.ok, JSON.stringify(none.body)).toBe(true)
    expect((await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine } })).status).toBe(403)
    const notBound = await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine: "vm_00000000000000000009" } })
    expect([notBound.status, notBound.body.code]).toEqual([400, "cloud.machine.not_found"])
  })
})
