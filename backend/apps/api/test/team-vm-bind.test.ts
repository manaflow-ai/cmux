import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { decodeJwt } from "jose"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { describe, expect, it, vi } from "vitest"
import { teamVmDomain } from "../src/domains/team-vm.ts"
import { FreestyleDriver } from "../src/team-vm-driver.ts"
import { bindMessage, checkProof, commitCommand, enrollCommand, NONCE_TTL_MS, parseProof, TeamVmBinds } from "../src/team-vm-bind.ts"
import type { FakeGuestMode } from "../src/team-vm-fake-guest.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"

/** The team VM bind (vm-image.md 6b) against the fake provider and its fake guest. */

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
interface Stub {
  fakeControl(cmd: { guest_mode?: FakeGuestMode; delete_all?: boolean }): Promise<unknown>
  fakeGuest(vm: string): Promise<{ guest: { private_jwk: JsonWebKey; public_jwk: JsonWebKey; committed: Record<string, string> | null; enrolls: number } | null; last_error: string | null }>
  fakeAlarm(aheadMs: number): Promise<void>
}
const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const stubFor = (team: string) => ns.get(ns.idFromName(team)) as unknown as Stub
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const op = (session: string, name: string, params: unknown) => post("/v1/ops", session, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })

let n = 0
/** A signed-in owner of a personal team, with a fake guest mode set before the first wake. */
const owner = async (mode: FakeGuestMode = "honest") => {
  const session = await sessionToken(`tvm-bind-${++n}-${crypto.randomUUID().slice(0, 8)}`)
  const ensured = (await op(session, "user.ensure", {})).body.value as { id: string; personal_team: string }
  const stub = stubFor(ensured.personal_team)
  await stub.fakeControl({ guest_mode: mode })
  return { session, user: ensured.id, team: ensured.personal_team, stub }
}
const wake = async (session: string) => {
  const r = await op(session, "team_vm.ensure_awake", { reason: "ssh" })
  expect(r.body.ok, JSON.stringify(r.body)).toBe(true)
  return r.body.value as { vm: string; epoch: number; status: string }
}

/** Acts as the VM: signs the auth challenge with the guest's install key. */
const vmToken = async (guest: { private_jwk: JsonWebKey }, user: string, install: string) => {
  const ch = await post("/v1/auth/challenge", undefined, { user, install })
  if (ch.status !== 200) return { status: ch.status, token: null }
  const key = await crypto.subtle.importKey("jwk", guest.private_jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"])
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await post("/v1/auth/token", undefined, { user, install, nonce: ch.body.nonce, signature: b64u(sig) })
  return { status: tok.status, token: (tok.body.access_token as string | undefined) ?? null }
}

describe("team VM bind commands and proofs", () => {
  it("builds commands only from shell-safe values", () => {
    expect(enrollCommand("team_x", 3, "abc-_1")).toBe("/opt/cmux/current/bin/cmux host team-enroll --team team_x --epoch 3 --nonce abc-_1")
    expect(enrollCommand("team_x; rm -rf /", 3, "n")).toBeNull()
    expect(enrollCommand("team_x", 3, "n$(id)")).toBeNull()
    const ok = { team: "team_x", epoch: "3", user: "user_y", install: "inst_z", api: "https://cloud-api-staging.cmux.dev", env: "stg" }
    expect(commitCommand(ok)).toContain("--commit --team team_x --epoch 3 --user user_y --install inst_z --api https://cloud-api-staging.cmux.dev --env stg")
    expect(commitCommand({ ...ok, api: "http://evil.example" })).toBeNull()
    expect(commitCommand({ ...ok, api: "https://x.dev/$(id)" })).toBeNull()
    expect(commitCommand({ ...ok, env: "qa" })).toBeNull()
  })

  it("takes only a well-formed P-256 proof from the last output line", () => {
    const good = { instance_id: "vm-1", public_jwk: { kty: "EC", crv: "P-256", x: "AAAA", y: "BBBB" }, signature: "c2ln" }
    expect(parseProof(`noise\n${JSON.stringify(good)}\n`)).toEqual(good)
    expect(parseProof(JSON.stringify({ ...good, public_jwk: { ...good.public_jwk, crv: "P-384" } }))).toBeNull()
    expect(parseProof(JSON.stringify({ ...good, instance_id: "vm 1" }))).toBeNull()
    expect(parseProof("not json")).toBeNull()
  })

  it("team_vm.bind_install refuses a bind that names another VM of the epoch", () => {
    const sys: Principal = { identity: "system:team_vm", kind: "system" }
    const ctx = (now: number): ReduceContext => ({ principal: sys, now, tx: `tx${now}`, newId: (x) => `${x}_${now}` })
    const s = { ...teamVmDomain.initial(), team: "team_t", vm: "vm-a", epoch: 1, status: "running" as const }
    expect(teamVmDomain.reduce(s, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-b" }, ctx(1))).toMatchObject({ ok: false, code: "team_vm.stale_epoch" })
    expect(teamVmDomain.reduce(s, "team_vm.bind_install", { install: "inst_00000000000000000001", epoch: 1, vm: "vm-a" }, ctx(2))).toMatchObject({ ok: true })
  })

  it("a nonce is single use, bound to its epoch and VM, and expires", async () => {
    const stub = ns.get(ns.idFromName("team_00000000000000000990"))
    await runInDurableObject(stub, async (i) => {
      const b = new TeamVmBinds(i.sqlStore)
      const t = 1_000_000
      const n1 = b.mint(1, "vm-a", t)
      expect(b.consume(n1, 1, "vm-a", t + 1)).toBe(true)
      expect(b.consume(n1, 1, "vm-a", t + 2)).toBe(false)
      const n2 = b.mint(1, "vm-a", t)
      expect(b.consume(n2, 2, "vm-a", t + 1)).toBe(false)
      expect(b.consume(n2, 1, "vm-a", t + 1)).toBe(false)
      expect(b.consume(b.mint(1, "vm-a", t), 1, "vm-b", t + 1)).toBe(false)
      expect(b.consume(b.mint(1, "vm-a", t), 1, "vm-a", t + NONCE_TTL_MS + 1)).toBe(false)
    })
  })

  it("a proof for another instance, nonce or key is refused", async () => {
    const stub = ns.get(ns.idFromName("team_00000000000000000991"))
    await runInDurableObject(stub, async (i) => {
      const b = new TeamVmBinds(i.sqlStore)
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
      const pub = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
      const jwk = { kty: "EC" as const, crv: "P-256" as const, x: pub.x!, y: pub.y! }
      const sign = async (m: string) => b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(m)))
      const want = (nonce: string) => ({ team: "team_t", epoch: 1, vm: "vm-a", nonce })
      let nonce = b.mint(1, "vm-a", Date.now())
      expect(await checkProof(b, { instance_id: "vm-a", public_jwk: jwk, signature: await sign(bindMessage("team_t", 1, "vm-a", nonce)) }, want(nonce), Date.now())).toEqual({ ok: true })
      nonce = b.mint(1, "vm-a", Date.now())
      expect(await checkProof(b, { instance_id: "vm-b", public_jwk: jwk, signature: await sign(bindMessage("team_t", 1, "vm-b", nonce)) }, want(nonce), Date.now())).toEqual({ ok: false, code: "team_vm.bind_instance" })
      nonce = b.mint(1, "vm-a", Date.now())
      expect(await checkProof(b, { instance_id: "vm-a", public_jwk: jwk, signature: await sign(bindMessage("team_t", 2, "vm-a", nonce)) }, want(nonce), Date.now())).toEqual({ ok: false, code: "team_vm.bind_signature" })
      expect(await checkProof(b, { instance_id: "vm-a", public_jwk: jwk, signature: await sign(bindMessage("team_t", 1, "vm-a", nonce)) }, want(nonce), Date.now())).toEqual({ ok: false, code: "team_vm.bind_nonce" })
    })
  })
})

describe("TeamVmDO binds its VM through the provider exec", { timeout: 60_000 }, () => {
  it("an honest VM gets a team-bound install with read + mutate-own and fetches team_vm.ssh_ca itself", async () => {
    const o = await owner()
    const vm = (await wake(o.session)).vm
    const { guest, last_error } = await o.stub.fakeGuest(vm)
    expect(last_error).toBeNull()
    expect(guest?.committed).toMatchObject({ team: o.team, epoch: "1", user: o.user, api: "https://api.test", env: "dev" })
    const install = guest!.committed!.install!
    const t = await vmToken(guest!, o.user, install)
    expect(t.status).toBe(200)
    expect(decodeJwt(t.token!)).toMatchObject({ team: o.team, inst: install })
    const ca = await post("/v1/read", t.token!, { op: "team_vm.ssh_ca", params: {} })
    expect(ca.body, JSON.stringify(ca)).toMatchObject({ op: "team_vm.ssh_ca", value: { team: o.team, krl_version: 0 } })
    // The bound install is the journal writer; the grant never reaches execute (no SSH certificates).
    expect((await post("/v1/read", t.token!, { op: "team_vm.journal.high_water", params: { stream: "tasks" } })).body).toMatchObject({ value: { stream: "tasks" } })
    const cert = await op(t.token!, "team_vm.ssh_cert", { public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOvKqkQ2yW6t8mTq3xH2b9cT0v5e3dPpYk1uZzQwYk1u x", class: "agent" })
    expect(JSON.stringify(cert.body)).toContain("auth.forbidden")
    // A team-vm install is not its owner's client: no owner reads, no other team or user ops, no socket.
    for (const [path, name] of [["/v1/read", "install.list"], ["/v1/read", "team.directory"], ["/v1/ops", "team_vm.ensure_awake"], ["/v1/ops", "user.ensure"]] as const) {
      const r = path === "/v1/read" ? await post(path, t.token!, { op: name, params: {} }) : await op(t.token!, name, { reason: "x" })
      expect(r.status, `${name}: ${JSON.stringify(r.body)}`).toBe(403)
    }
  })

  for (const [mode, code] of [
    ["wrong_instance", "team_vm.bind_instance"],
    ["bad_signature", "team_vm.bind_signature"],
    ["absent", "team_vm.bind_exec"]
  ] as const) {
    it(`a VM that answers ${mode} is not bound (${code})`, async () => {
      const o = await owner(mode)
      const vm = (await wake(o.session)).vm
      const { guest, last_error } = await o.stub.fakeGuest(vm)
      expect(last_error).toBe(code)
      expect(guest?.committed ?? null).toBeNull()
      // No install exists for the VM key: the owner has only the session-made installs (none here).
      const installs = await post("/v1/read", o.session, { op: "install.list", params: {} })
      expect(JSON.stringify(installs.body)).not.toContain("Team VM")
    })
  }

  it("a replayed proof (signed over an earlier nonce) is refused; a later honest answer binds", async () => {
    const o = await owner("bad_signature")
    const vm = (await wake(o.session)).vm
    await o.stub.fakeControl({ guest_mode: "old_nonce" })
    await o.stub.fakeAlarm(10 * 60_000)
    expect((await o.stub.fakeGuest(vm)).last_error).toBe("team_vm.bind_signature")
    await o.stub.fakeControl({ guest_mode: "honest" })
    await o.stub.fakeAlarm(20 * 60_000)
    expect((await o.stub.fakeGuest(vm)).guest?.committed).toMatchObject({ team: o.team, user: o.user })
  })

  it("a failed commit is retried by the alarm until the VM has its ids", async () => {
    const o = await owner("commit_fails")
    const vm = (await wake(o.session)).vm
    expect((await o.stub.fakeGuest(vm)).last_error).toBe("team_vm.bind_commit")
    await o.stub.fakeControl({ guest_mode: "honest" })
    await o.stub.fakeAlarm(10 * 60_000)
    expect((await o.stub.fakeGuest(vm)).guest?.committed).toMatchObject({ team: o.team })
  })

  it("a replaced VM binds a new install under the next epoch and the old install is revoked", async () => {
    const o = await owner()
    const first = await wake(o.session)
    const old = (await o.stub.fakeGuest(first.vm)).guest!
    const oldInstall = old.committed!.install!
    expect((await vmToken(old, o.user, oldInstall)).status).toBe(200)
    await o.stub.fakeControl({ delete_all: true })
    const second = await wake(o.session)
    expect(second.epoch).toBe(2)
    const fresh = (await o.stub.fakeGuest(second.vm)).guest!
    expect(fresh.committed).toMatchObject({ epoch: "2" })
    expect(fresh.committed!.install).not.toBe(oldInstall)
    expect((await vmToken(fresh, o.user, fresh.committed!.install!)).status).toBe(200)
    expect((await vmToken(old, o.user, oldInstall)).token).toBeNull()
  })
})

describe("the Freestyle exec the bind uses", () => {
  it("runs the command as root on exactly that VM (the default exec user cannot write the VM's state)", async () => {
    const seen: Array<{ url: string; body: any }> = []
    const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push({ url: String(input), body: JSON.parse(String(init?.body ?? "{}")) })
      return Response.json({ statusCode: 0, stdout: "x".repeat(20_000) + "\nlast\n", stderr: "" })
    })
    try {
      const out = await new FreestyleDriver("k", "https://api.freestyle.example", "snap").exec("vm-abc", "/opt/cmux/current/bin/cmux host team-enroll --team t --epoch 1 --nonce n", 30_000)
      expect(seen).toEqual([{ url: "https://api.freestyle.example/v5/vms/vm-abc/exec-await", body: { command: "/opt/cmux/current/bin/cmux host team-enroll --team t --epoch 1 --nonce n", timeoutMs: 30_000, linuxUser: "root" } }])
      expect(out.code).toBe(0)
      expect(out.stdout.endsWith("\nlast\n")).toBe(true)
      expect(out.stdout.length).toBeLessThanOrEqual(16_384)
    } finally {
      spy.mockRestore()
    }
  })
})
