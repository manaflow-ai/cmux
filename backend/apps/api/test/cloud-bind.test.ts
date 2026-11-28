import { runInDurableObject } from "cloudflare:test"
import { HostId } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, createdAndBound, DAEMON, ensureUser, frame, person, post, reply, SIZE, vmKey, WG_KEY } from "./cloud-bind-support.ts"

/** The VM's bind request through the API Worker (the token is the credential; no bearer). */
const bindRoute = async (body: Record<string, unknown>) => {
  const r = await post("/v1/cloud/bind", undefined, body)
  return r.body.ok ? r.body : { ok: false, code: r.body?.error?.code ?? r.body?.code, status: r.status }
}

/**
 * Part 1 (create mints host id, epoch 1 and a one-time bind token written into the VM) and part 2
 * (the bind agent's POST /v1/cloud/bind), state-placement.md 5.8 items 1 and 2.
 */

const dumpSqlite = (stub: unknown) =>
  (runInDurableObject as unknown as <T>(s: unknown, fn: (i: unknown, st: DurableObjectState) => Promise<T>) => Promise<T>)(stub, async (_i, state) => {
    const tables = state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table'`).toArray() as Array<{ name: string }>
    // The fake provider's own tables stand for the VM (it holds the file); everything else is CloudDO's.
    return tables
      .filter((t) => !t.name.startsWith("cloud_fake_") && !t.name.startsWith("_cf"))
      .map((t) => JSON.stringify(state.storage.sql.exec(`SELECT * FROM "${t.name}"`).toArray()))
      .join("\n")
  })

describe("part 2: bind", { timeout: 60_000 }, () => {

  it("POST /v1/cloud/bind refuses a spent token, a wrong token, an expired token and a malformed key", async () => {
    const x = person()
    await ensureUser(x)
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const { json } = await bindFile(x.stub, machine)
    const body = { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk }
    expect(await bindRoute({ ...body, wg_public_key: "AAAA" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await bindRoute({ ...body, bind_token: "x".repeat(43) })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await bindRoute(body)).toMatchObject({ ok: true, value: { epoch: 1 } })
    expect(await bindRoute(body)).toMatchObject({ ok: false, code: "auth.forbidden" })

    const late = person()
    await ensureUser(late)
    const m2 = reply(await late.stub.submit(late.team, late.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    const f2 = await bindFile(late.stub, m2)
    await late.stub.fakeControl({ advance_ms: 16 * 60_000 })
    expect(await bindRoute({ team: late.team, machine: m2, bind_token: f2.json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("POST /v1/cloud/bind needs no bearer (the token is the credential) and answers the same refusals", async () => {
    const x = person()
    await ensureUser(x)
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const { json } = await bindFile(x.stub, machine)
    const ok = await post("/v1/cloud/bind", undefined, { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })
    expect(ok.status, JSON.stringify(ok.body)).toBe(200)
    expect(ok.body).toMatchObject({ ok: true, value: { machine, epoch: 1, keyset: { version: expect.any(String) } } })
    const again = await post("/v1/cloud/bind", undefined, { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })
    expect(again).toMatchObject({ status: 403, body: { ok: false, error: { code: "auth.forbidden" } } })
    expect((await post("/v1/cloud/bind", undefined, { team: x.team, machine })).status).toBe(400)
    // A team nobody created answers the same refusal and creates no object.
    const nobody = await post("/v1/cloud/bind", undefined, { team: "team_00000000000000000777", machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })
    expect(nobody.status).toBe(403)
    const stubNobody = cloudStub("team_00000000000000000777") as unknown as { readOp: (e: string, p: unknown, o: string, q: unknown) => Promise<{ revision?: string }> }
    expect((await stubNobody.readOp("team_00000000000000000777", { identity: "user:x", user: "user_00000000000000000777", team: "team_00000000000000000777", kind: "session" }, "cloud.machine.list", {})).revision).toBe("0")
  })
})
