import { runInDurableObject } from "cloudflare:test"
import { HostId } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, createdAndBound, DAEMON, frame, person, post, reply, SIZE, WG_KEY } from "./cloud-bind-support.ts"

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

describe("part 1: create mints the host id, epoch 1 and a one-time bind token", { timeout: 60_000 }, () => {
  it("writes {team, machine, bind_token} into the VM (0600) and stores only the token's sha256", async () => {
    const x = person()
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    expect(created.t, JSON.stringify(created)).toBe("result")
    const machine = created.value.machine.id as string
    // Not bound yet: the public host stays null.
    expect(created.value.machine.host).toBeNull()
    const file = await bindFile(x.stub, machine)
    expect(file.mode).toBe(0o600)
    expect(file.json).toMatchObject({ team: x.team, machine })
    expect(file.json.bind_token).toMatch(/^[A-Za-z0-9_-]{43}$/)
    const dump = await dumpSqlite(x.stub)
    expect(dump).not.toContain(file.json.bind_token)
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(file.json.bind_token)))
    const hex = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("")
    expect(dump).toContain(hex)
  })
})

describe("part 2: bind", { timeout: 60_000 }, () => {
  it("binds once: records host, epoch 1, key and daemon, emits the host, and returns the public keyset", async () => {
    const x = person()
    const { machine, host, keyset } = await createdAndBound(x)
    expect(Exit.isSuccess(Schema.decodeUnknownExit(HostId)(host))).toBe(true)
    const got = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    expect(got).toMatchObject({ ok: true, value: { host, status: "running", image: { daemon_version: DAEMON.version } } })
    const kids = Object.keys(keyset.keys)
    expect(kids.length).toBeGreaterThanOrEqual(1)
    expect(kids.length).toBeLessThanOrEqual(2)
    for (const k of kids) {
      expect(keyset.keys[k]).toMatchObject({ kty: "OKP", crv: "Ed25519" })
      expect(keyset.keys[k]).not.toHaveProperty("d")
    }
    expect(keyset.version).toMatch(/^[0-9a-f]{16}$/)
  })

  it("refuses a spent token, a wrong token, an expired token and a malformed key", async () => {
    const x = person()
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const { json } = await bindFile(x.stub, machine)
    const body = { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON }
    expect(await x.stub.bindMachine(x.team, { ...body, wg_public_key: "AAAA" })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await x.stub.bindMachine(x.team, { ...body, bind_token: "x".repeat(43) })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await x.stub.bindMachine(x.team, body)).toMatchObject({ ok: true, value: { epoch: 1 } })
    expect(await x.stub.bindMachine(x.team, body)).toMatchObject({ ok: false, code: "auth.forbidden" })

    const late = person()
    const m2 = reply(await late.stub.submit(late.team, late.p, frame("cloud.machine.create", { size: SIZE }))).value.machine.id as string
    const f2 = await bindFile(late.stub, m2)
    await late.stub.fakeControl({ advance_ms: 16 * 60_000 })
    expect(await late.stub.bindMachine(late.team, { team: late.team, machine: m2, bind_token: f2.json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })).toMatchObject({ ok: false, code: "auth.forbidden" })
  })

  it("POST /v1/cloud/bind needs no bearer (the token is the credential) and answers the same refusals", async () => {
    const x = person()
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const { json } = await bindFile(x.stub, machine)
    const ok = await post("/v1/cloud/bind", undefined, { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    expect(ok.status, JSON.stringify(ok.body)).toBe(200)
    expect(ok.body).toMatchObject({ ok: true, value: { machine, epoch: 1, keyset: { version: expect.any(String) } } })
    const again = await post("/v1/cloud/bind", undefined, { team: x.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    expect(again).toMatchObject({ status: 403, body: { ok: false, error: { code: "auth.forbidden" } } })
    expect((await post("/v1/cloud/bind", undefined, { team: x.team, machine })).status).toBe(400)
    // A team nobody created answers the same refusal and creates no object.
    const nobody = await post("/v1/cloud/bind", undefined, { team: "team_00000000000000000777", machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })
    expect(nobody.status).toBe(403)
    const stubNobody = cloudStub("team_00000000000000000777") as unknown as { readOp: (e: string, p: unknown, o: string, q: unknown) => Promise<{ revision?: string }> }
    expect((await stubNobody.readOp("team_00000000000000000777", { identity: "user:x", user: "user_00000000000000000777", team: "team_00000000000000000777", kind: "session" }, "cloud.machine.list", {})).revision).toBe("0")
  })
})
