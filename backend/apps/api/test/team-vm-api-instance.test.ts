import { env } from "cloudflare:workers"
import { inDO } from "./team-ssh-support.ts"
import { expect, it } from "vitest"
import { bindMessage, checkProof, TeamVmBinds, type BindProof } from "../src/team-vm-bind.ts"
import { vmApiInstanceMatches } from "../src/team-vm-api-instance.ts"
import { instanceFingerprint } from "../../../../libs/vm-instance-identity/src/identity.ts"
import { BindRunner } from "../src/team-vm-bind-run.ts"
import { TeamVmDO } from "../src/team-vm-do.ts"
import { FakeDriver } from "../src/team-vm-driver.ts"
import { parseEnrollArgs } from "../src/team-vm-bind.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"
import type { Env } from "../src/env.ts"

const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const b64u = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

it("binds a public VM allocation only after its actual signed instance is verified", async () => {
  const stub = ns.get(ns.idFromName("team_00000000000000811000"))
  await inDO(stub, async (owner) => {
    const binds = new TeamVmBinds(owner.sqlStore), now = Date.now()
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
    const key = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
    const vm = "vm_0123456789abcdefghjkmnpqrs", instance = "vm-native-111", team = "team_t", epoch = 1
    const nonce = binds.mint(epoch, vm, now)
    const proof: BindProof = { instance_id: instance, public_jwk: { kty: "EC", crv: "P-256", x: key.x!, y: key.y! }, signature: b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(bindMessage(team, epoch, instance, nonce)))) }
    let checked = ""
    const verifyInstance = async (id: string) => { checked = id; return id === instance }
    const result = await checkProof(binds, proof, { team, epoch, vm, nonce }, now, verifyInstance)
    expect(result).toEqual({ ok: true })
    expect(checked).toBe(instance)
    expect(await checkProof(binds, proof, { team, epoch, vm, nonce }, now, verifyInstance)).toEqual({ ok: false, code: "team_vm.bind_nonce" })
  })
})

const VM = "vm_0123456789abcdefghjkmnpqrs"
const SETTINGS = { origin: "https://vm.test", key: "test-service-key", image: { id: "team-vm", revision: "v1" } }

it("uses the authenticated tenant API allocation and refuses wrong or old receipts", async () => {
  const fingerprint = await instanceFingerprint("vm-native-111")
  for (const receipt of [
    { id: VM, scheme: "sha256-v1", fingerprint },
    { id: "vm_00000000000000000000000000", scheme: "sha256-v1", fingerprint },
    { id: VM, scheme: "other", fingerprint },
    { id: VM, scheme: "sha256-v1", fingerprint: "0".repeat(64) },
  ]) {
    let calls = 0
    const matches = vmApiInstanceMatches(SETTINGS, "stack-team", async (input, init) => {
      const r = new Request(input, init)
      expect(r.url).toBe(`https://vm.test/v1/vms/${VM}/identity`)
      expect(r.headers.get("authorization")).toBe("Bearer test-service-key")
      expect(r.headers.get("x-cmux-team-id")).toBe("stack-team")
      expect(r.redirect).toBe("manual")
      calls++
      return Response.json(receipt)
    })
    expect(await matches(VM, "vm-native-111")).toBe(receipt.id === VM && receipt.scheme === "sha256-v1" && receipt.fingerprint === fingerprint)
    expect(calls).toBe(1)
  }
})

it("keeps signature, expiry and one-use checks after an API identity await", async () => {
  const stub = ns.get(ns.idFromName("team_00000000000000811001"))
  await inDO(stub, async (owner) => {
    const binds = new TeamVmBinds(owner.sqlStore), now = Date.now(), team = "team_t", epoch = 1, instance = "vm-native-111"
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
    const key = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
    const make = async (nonce: string, signedNonce = nonce): Promise<BindProof> => ({ instance_id: instance, public_jwk: { kty: "EC", crv: "P-256", x: key.x!, y: key.y! }, signature: b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(bindMessage(team, epoch, instance, signedNonce)))) })
    const n1 = binds.mint(epoch, VM, now)
    expect(await checkProof(binds, await make(n1, "wrong-nonce"), { team, epoch, vm: VM, nonce: n1 }, now, async () => true)).toEqual({ ok: false, code: "team_vm.bind_signature" })
    const n2 = binds.mint(epoch, VM, now)
    expect(await checkProof(binds, await make(n2), { team, epoch, vm: VM, nonce: n2 }, now, async () => true, () => now + 5 * 60_000 + 1)).toEqual({ ok: false, code: "team_vm.bind_nonce" })
    const n3 = binds.mint(epoch, VM, now)
    expect(await checkProof(binds, await make(n3), { team, epoch, vm: VM, nonce: n3 }, now, async () => { throw new Error("private provider failure") })).toEqual({ ok: false, code: "team_vm.bind_instance_unavailable" })
    expect(binds.consume(n3, epoch, VM, now)).toBe(false)
  })
})

it("refuses missing allocations and uncertain API answers without identity fallback", async () => {
  for (const status of [404, 403, 503]) {
    const matches = vmApiInstanceMatches(SETTINGS, "stack-team", async () => Response.json({ message: "private service detail" }, { status }))
    if (status === 404) expect(await matches(VM, "vm-native-111")).toBe(false)
    else await expect(matches(VM, "vm-native-111")).rejects.toThrow("could not be confirmed")
  }
})

it.each([false, true])("runs the real bind owner with an API identity receipt; rebuild during verification=%s", async (rebuild) => {
  const session = await sessionToken(`api-instance-${crypto.randomUUID()}`)
  const ensured = await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
  const { id: user, personal_team: team } = ensured.body.value as { id: string; personal_team: string }
  const principal = { identity: `user:${user}`, kind: "session" as const, user, team }
  const stub = ns.get(ns.idFromName(team))
  await inDO(stub, async (_instance, storage) => {
    // The real owner/reducer/UserDO remain; only its external VM driver is injected into the bind runner.
    const owner = new TeamVmDO(storage, { ...(env as Env), TEAM_VM_BIND_ENABLED: "0" })
    const internal = Reflect.get(owner, "submitSystem").bind(owner) as (op: string, p: unknown, key: string) => import("../src/owner-do.ts").SubmitResult
    const current = () => Reflect.get(owner, "boundEngine")?.currentState
    await owner.submit(team, principal, { t: "op", op: "team_vm.ensure_awake", params: { reason: "ssh" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    internal("team_vm.driver_result", { action: "create", epoch: 0, ok: true, vm: VM, slug: "cmuxnp-dev-tvm-instance", observed: "running" }, "created")
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
    const key = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
    const jwk = { kty: "EC", crv: "P-256", x: key.x!, y: key.y! }
    let commits = 0, checks = 0
    const driver = Object.assign(new FakeDriver(owner.sqlStore), {
      instanceMatches: vmApiInstanceMatches(SETTINGS, "stack-team", async () => {
        checks++
        if (rebuild) internal("team_vm.rebuild_requested", { epoch: 1, by: user }, "rebuild")
        return Response.json({ id: VM, scheme: "sha256-v1", fingerprint: await instanceFingerprint("vm-native-111") })
      }),
      exec: async (_id: string, command: string) => {
        const args = parseEnrollArgs(command)
        if (!args) throw new Error("invalid enroll command")
        if (args.commit) { commits++; return { code: 0, stdout: "" } }
        const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(bindMessage(team, 1, "vm-native-111", args.nonce))))
        return { code: 0, stdout: JSON.stringify({ instance_id: "vm-native-111", public_jwk: jwk, signature }) }
      }
    })
    const runner = new BindRunner(owner.sqlStore, { env: { ...(env as Env), TEAM_VM_BIND_ENABLED: "1", CLOUD_API_ORIGIN: "https://api.test" }, driver: () => driver, state: current, submitSystem: internal, now: () => Date.now() }, () => {})
    const result = await runner.pass() as { bound?: string; error?: string }
    expect(checks).toBe(1)
    if (rebuild) {
      expect(result).toEqual({ error: "team_vm.stale_epoch" })
      expect(runner.binds.installFor(1)).toBeNull()
      expect(commits).toBe(0)
    } else {
      expect(result.bound).toMatch(/^inst_/)
      expect(current().vm_install).toBe(result.bound)
      expect(runner.binds.installFor(1)).toMatchObject({ owner: user, committed: true })
      expect(commits).toBe(1)
      const challenge = await post("/v1/auth/challenge", undefined, { user, install: result.bound })
      const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(challenge.body.nonce)))
      const token = await post("/v1/auth/token", undefined, { user, install: result.bound, nonce: challenge.body.nonce, signature })
      expect(token.status).toBe(200)
      expect((await post("/v1/read", token.body.access_token, { op: "team_vm.ssh_ca", params: {} })).status).toBe(200)
      expect((await post("/v1/read", token.body.access_token, { op: "install.list", params: {} })).status).toBe(403)
    }
  })
})
