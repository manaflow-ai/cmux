import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import linkVectors from "../../../../schemas/link-token/vectors.json"
import { verifyLinkToken } from "../src/link-token.ts"
import { bindFile, createdAndBound, DAEMON, frame, installOf, person, post, reply, SIZE, WG_KEY } from "./cloud-bind-support.ts"

/** Security review of the bind branch (2026-10-04): P2-1, P2-2, P2-4, P3-1, P3-3, P3-4, P3-5. */

const inDo = runInDurableObject as unknown as <T>(s: unknown, fn: (i: unknown, st: DurableObjectState) => Promise<T>) => Promise<T>
const tables = (stub: unknown) => inDo(stub, async (_i, st) => (st.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table'`).toArray() as Array<{ name: string }>).map((t) => t.name).filter((n) => !n.startsWith("_cf")))
const ledgerRows = (stub: unknown) => inDo(stub, async (_i, st) => Number((st.storage.sql.exec(`SELECT count(*) AS n FROM own_ledger`).one() as { n: number }).n))

describe("link-token vectors catch a verifier that skips the signature, alg, typ, lifetime or the exp boundary", () => {
  it("has the refusal cases, and the reference verifier agrees with each", async () => {
    const doc = linkVectors as unknown as { keysets: Record<string, Record<string, any>>; cases: Array<{ name: string; token: string; verify: Array<{ aud: string; epoch: number; now: number; keyset: string; seen: Array<string>; expect: { ok: boolean; error?: string } }> }> }
    const want: Record<string, string> = { bad_signature: "bad_signature", alg_none: "malformed", wrong_typ: "typ", lifetime: "lifetime", exp_boundary: "expired" }
    for (const [name, error] of Object.entries(want)) {
      const c = doc.cases.find((x) => x.name === name)
      expect(c, name).toBeDefined()
      expect(c!.verify.some((v) => v.expect.ok === false && v.expect.error === error), name).toBe(true)
      for (const v of c!.verify) {
        const r = await verifyLinkToken(c!.token, { aud: v.aud, epoch: v.epoch, now: v.now, keyset: doc.keysets[v.keyset]!, seen: new Set(v.seen) })
        expect(r.ok ? { ok: true } : { ok: false, error: r.error }, name).toEqual(v.expect)
      }
    }
  })
})

describe("a refused bind costs the team nothing", { timeout: 60_000 }, () => {
  it("writes no ledger row for a wrong token, and the real token still binds afterwards", async () => {
    const x = person()
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const file = await bindFile(x.stub, machine)
    const before = await ledgerRows(x.stub)
    for (let i = 0; i < 5; i++) expect(await x.stub.bindMachine(x.team, { team: x.team, machine, bind_token: "y".repeat(43), wg_public_key: WG_KEY, daemon: DAEMON })).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(await ledgerRows(x.stub)).toBe(before)
    expect(await x.stub.bindMachine(x.team, { team: x.team, machine, bind_token: file.json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON })).toMatchObject({ ok: true })
  })
})

describe("link_token on an object nobody created writes nothing", () => {
  it("creates no table", async () => {
    const x = person()
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p), { host: "host_h0000000000000000009", services: ["ssh"] })).toMatchObject({ ok: false })
    expect(await tables(x.stub)).toEqual([])
  })
})

describe("bind request limits", { timeout: 60_000 }, () => {
  it("refuses a body above 4 KB before parsing it", async () => {
    const x = person()
    const r = await post("/v1/cloud/bind", undefined, { team: x.team, machine: "vm_00000000000000000001", bind_token: "z".repeat(43), wg_public_key: WG_KEY, daemon: DAEMON, pad: "p".repeat(5000) })
    expect([r.status, r.body.error?.code]).toEqual([400, "validation.invalid"])
  })
  it("refuses a daemon version or capability that is not printable ASCII", async () => {
    const x = person()
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const file = await bindFile(x.stub, machine)
    const body = { team: x.team, machine, bind_token: file.json.bind_token, wg_public_key: WG_KEY }
    expect(await x.stub.bindMachine(x.team, { ...body, daemon: { version: "0.41.0\u001b[31m", capabilities: [] } })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(await x.stub.bindMachine(x.team, { ...body, daemon: { version: "0.41.0", capabilities: ["files\n"] } })).toMatchObject({ ok: false, code: "validation.invalid" })
  })
})

describe("link_token refuses a machine that is being deleted", { timeout: 60_000 }, () => {
  it("answers cloud.machine.not_bound while the delete is pending", async () => {
    const x = person()
    const { machine, host } = await createdAndBound(x)
    await x.stub.fakeControl({ fail_next: 3 } as never)
    reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.delete", { machine })))
    const read = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    expect(read.value?.status, JSON.stringify(read)).toBe("deleting")
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "cloud.machine.not_bound" })
  })
})

describe("missing bind-file configuration fails before any VM exists, and link_token never signs an unknown iss", { timeout: 60_000 }, () => {
  it("a create without CLOUD_API_ORIGIN fails final and makes no VM (review P3-a)", async () => {
    const x = person()
    await x.stub.fakeControl({ unset: ["CLOUD_API_ORIGIN"] } as never)
    const before = (await x.stub.fakeControl({})) as unknown as { creates: number }
    const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
    const machine = created.value.machine.id as string
    const after = (await x.stub.fakeControl({})) as unknown as { creates: number }
    expect(after.creates).toBe(before.creates)
    const got = await x.stub.readOp(x.team, x.p, "cloud.machine.get", { machine })
    expect(got.value?.status, JSON.stringify(got)).toBe("failed")
  })
  it("link_token refuses with owner.unreachable when the environment has no tag (review P3-b)", async () => {
    const x = person()
    const { host } = await createdAndBound(x)
    await x.stub.fakeControl({ unset: ["ENVIRONMENT_TAG"] } as never)
    expect(await x.stub.mintLinkToken(x.team, installOf(x.p), { host, services: ["ssh"] })).toMatchObject({ ok: false, code: "owner.unreachable" })
  })
})
