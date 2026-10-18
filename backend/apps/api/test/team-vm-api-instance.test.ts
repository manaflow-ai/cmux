import { env } from "cloudflare:workers"
import { inDO } from "./team-ssh-support.ts"
import { expect, it } from "vitest"
import { bindMessage, checkProof, TeamVmBinds, type BindProof } from "../src/team-vm-bind.ts"

const ns = (env as unknown as { TEAM_VM_DO: DurableObjectNamespace }).TEAM_VM_DO
const b64u = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

it("binds a public VM allocation only after its actual signed instance is verified", async () => {
  const stub = ns.get(ns.idFromName("team_00000000000000811000"))
  await inDO(stub, async (owner) => {
    const binds = new TeamVmBinds(owner.sqlStore), now = Date.now()
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
    const key = await crypto.subtle.exportKey("jwk", pair.publicKey)
    const vm = "vm_0123456789abcdefghjkmnpqrs", instance = "vm-native-111", team = "team_t", epoch = 1
    const nonce = binds.mint(epoch, vm, now)
    const proof: BindProof = { instance_id: instance, public_jwk: { kty: "EC", crv: "P-256", x: key.x!, y: key.y! }, signature: b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(bindMessage(team, epoch, instance, nonce)))) }
    let checked = ""
    const verifyInstance = async (id: string) => { checked = id; return id === instance }
    const result = await Reflect.apply(checkProof, undefined, [binds, proof, { team, epoch, vm, nonce }, now, verifyInstance])
    expect(result).toEqual({ ok: true })
    expect(checked).toBe(instance)
    expect(await Reflect.apply(checkProof, undefined, [binds, proof, { team, epoch, vm, nonce }, now, verifyInstance])).toEqual({ ok: false, code: "team_vm.bind_nonce" })
  })
})
