import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { sshExternal } from "../src/team-ssh-ca.ts"
import { b64, inDO, readCert, setup, sshLine, testEnv, unb64, worker } from "./team-ssh-support.ts"

/**
 * team-vm-plan.md 3c, decision SSH-1 (S5 prerequisites): a full-shell (human) certificate needs a
 * fresh user-presence proof bound to that one request, made with the text confirmation's presence
 * keys (Face ID, Touch ID or the device passcode on the person's own device); and a request that
 * crashes replays the same certificate, never a second one.
 */

const b64u = (b: ArrayBuffer | Uint8Array) => b64(new Uint8Array(b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const fromB64u = (s: string) => unb64(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4))
const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return (await res.json()) as any
}
const ecKey = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { pair, jwk: { kty: "EC", crv: "P-256", x: j.x!, y: j.y! } }
}
const sign = async (key: CryptoKey, bytes: Uint8Array) => b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, bytes))
const thumbprint = async (jwk: { crv: string; kty: string; x: string; y: string }) =>
  b64u(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify({ crv: jwk.crv, kty: jwk.kty, x: jwk.x, y: jwk.y }))))

/** The owner's Mac install with a registered presence key past its 24 h cooldown. */
const presenceDevice = async (t: Awaited<ReturnType<typeof setup>>) => {
  const installKey = await ecKey()
  const reg = await call("/v1/ops", t.token, {
    op: "install.register",
    params: { public_jwk: installKey.jwk, kind: "mac", name: "mac", device_name: "mac", platform: "macos" },
    idempotency_key: crypto.randomUUID(),
    origin: "user"
  })
  const install = reg.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user: t.owner, install })
  const token = (await call("/v1/auth/token", undefined, { user: t.owner, install, nonce: ch.nonce, signature: await sign(installKey.pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`)) }))
    .access_token as string
  const presence = await ecKey()
  const message = `cmux-presence-key-v1\ntest\n${t.owner}\n${install}\n${await thumbprint(presence.jwk)}`
  const added = await call("/v1/presence-key", token, { platform: "mac", jwk: presence.jwk, signature: await sign(installKey.pair.privateKey, new TextEncoder().encode(message)) })
  expect(added.ok).toBe(true)
  // Skip the 24 h cooldown of a new key (tested in home-core).
  const users = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(t.owner))
  await inDO(users, async (instance) => {
    const engine = instance.boundEngine
    const c = engine.currentState.confirm
    engine.state = { ...engine.currentState, confirm: { ...c, presence_keys: { ...c.presence_keys, [install]: { ...c.presence_keys[install], usable_from: 0 } } } }
  })
  return { install, presence }
}

/** Approves a challenge on the device: signs the exact bytes the server returned. */
const approve = async (device: { install: string; presence: { pair: CryptoKeyPair } }, ch: { sign: { nonce: string }; message: string }) => ({
  install: device.install,
  nonce: ch.sign.nonce,
  signature: await sign(device.presence.pair.privateKey, fromB64u(ch.message))
})

describe("full-shell team SSH certificates need user presence", { timeout: 60_000 }, () => {
  it("a session gets a human certificate only with a fresh presence proof bound to that request", async () => {
    const t = await setup("stack-ssh-0000000011")
    const device = await presenceDevice(t)
    const key = await sshLine("ed25519")
    const idem = crypto.randomUUID()
    const ch = await t.op(t.ownerP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: idem })
    expect(ch.ok).toBe(true)
    // The device shows (and signs) the team, the Linux user, the key and the validity.
    const blob = unb64(key.split(" ")[1]!)
    const fingerprint = `SHA256:${b64(new Uint8Array(await crypto.subtle.digest("SHA-256", blob))).replace(/=+$/, "")}`
    expect(ch.value.sign).toMatchObject({ op: "team_vm.ssh_cert", team: t.team, request: idem, principal: "lawrence", key_fingerprint: fingerprint, validity_minutes: 30, class: "human", user: t.owner, install: device.install })
    const proof = await approve(device, ch.value)
    const cert = await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", presence: proof }, idem)
    expect(cert.value).toMatchObject({ class: "human", principals: ["lawrence"] })
    const c = await readCert(cert.value.certificate, cert.value.ca_public_key)
    expect(c.verified).toBe(true)
    expect(c.critical).toEqual({})
    expect(c.extensions).toEqual({ "cmux-teams@cmux.dev": t.team, "permit-port-forwarding": "", "permit-pty": "" })
    // The same request key replays the same certificate.
    const again = await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", presence: proof }, idem)
    expect(again.replayed).toBe(true)
    expect(again.value.certificate).toBe(cert.value.certificate)
    // One approval gives one certificate: the same proof under another request key is refused.
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", presence: proof })).error!.code).toBe("team_vm.ssh_presence_refused")
  })

  it("refuses a proof for another key, a bad signature (the nonce is spent), and callers that are not a person's session", async () => {
    const t = await setup("stack-ssh-0000000012")
    const device = await presenceDevice(t)
    const key = await sshLine("ed25519")
    const other = await sshLine("p256")
    // A proof for one key never signs another key.
    const idem1 = crypto.randomUUID()
    const ch1 = (await t.op(t.ownerP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: idem1 })).value
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: other, class: "human", presence: await approve(device, ch1) }, idem1)).error!.code).toBe("team_vm.ssh_presence_refused")
    // A wrong signature spends the nonce: a good one afterwards is refused too.
    const idem2 = crypto.randomUUID()
    const ch2 = (await t.op(t.ownerP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: idem2 })).value
    const forged = { install: device.install, nonce: ch2.sign.nonce, signature: await sign((await ecKey()).pair.privateKey, fromB64u(ch2.message)) }
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", presence: forged }, idem2)).error!.code).toBe("team_vm.ssh_presence_refused")
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", presence: await approve(device, ch2) }, idem2)).error!.code).toBe("team_vm.ssh_presence_refused")
    // A proof for another validity is refused.
    const idem3 = crypto.randomUUID()
    const ch3 = (await t.op(t.ownerP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: idem3, validity_minutes: 15 })).value
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "human", validity_minutes: 60, presence: await approve(device, ch3) }, idem3)).error!.code).toBe("team_vm.ssh_presence_refused")
    // Only a person's session asks: not an install token, not an agent, not another member for this device.
    const install: Principal = { identity: device.install, kind: "install", user: t.owner, team: t.team, install: device.install, grant: "grant_00000000000000000081", grant_classes: ["read", "mutate-own", "execute"], install_kind: "mac" }
    expect((await t.op(install, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: "x" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op({ ...t.ownerP, agent: "agent_x" }, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: "y" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.memberP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: "z" })).error!.code).toBe("team_vm.ssh_presence_refused")
    // A presence proof never comes with an agent certificate.
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "agent", presence: await approve(device, ch1) })).error!.code).toBe("validation.invalid")
  })
})

describe("a crash during a certificate request replays the same certificate", { timeout: 60_000 }, () => {
  /**
   * Runs one request whose object dies when it stores the reply: that write and every later one
   * are lost, as in a crash during the signing await (nothing after it reaches storage). Returns
   * the reply the dead request would have stored.
   */
  const crashOnce = async (t: Awaited<ReturnType<typeof setup>>, p: Principal, params: unknown, idem: string) =>
    inDO(t.stub, async (instance, state) => {
      let dead = false
      let lost: any = null
      const real = state.storage.sql
      const sql = {
        exec: (query: string, ...args: Array<unknown>) => {
          if (!dead && query.startsWith("UPDATE ssh_requests SET reply")) {
            dead = true
            lost = JSON.parse(args[0] as string)
          }
          if (dead) throw new Error("object reset")
          return real.exec(query, ...args)
        }
      } as unknown as SqlStorage
      const engine = instance.boundEngine
      await sshExternal(
        {
          state: () => instance.boundEngine.currentState,
          team: t.team,
          stream: engine.stream,
          kek: instance.env.INTEGRATIONS_KEK,
          sql,
          now: () => Date.now(),
          submitSystem: (op, prm, k) => instance.submitSystem(op, prm, k),
          presence: instance.presenceOwner?.(t.team)
        },
        p,
        { op: "team_vm.ssh_cert", params, idempotency_key: idem }
      ).catch(() => undefined)
      return lost as { certificate: string; serial: number }
    })

  const issued = (t: Awaited<ReturnType<typeof setup>>, identity: string) =>
    inDO(t.stub, async (_i, state) => (state.storage.sql.exec(`SELECT serial FROM ssh_certs WHERE identity = ?`, identity).toArray() as Array<{ serial: number }>).map((r) => r.serial))

  it("an install's request that crashed before its reply was stored gets the same serial and certificate at once", async () => {
    const t = await setup("stack-ssh-0000000013")
    const key = await sshLine("ed25519")
    const p = t.install(t.owner, ["read", "mutate-own"])
    const idem = crypto.randomUUID()
    const lost = await crashOnce(t, p, { public_key: key }, idem)
    expect(lost.serial).toBeGreaterThan(0)
    const retry = await t.op(p, "team_vm.ssh_cert", { public_key: key }, idem)
    expect(retry.ok).toBe(true)
    expect(retry.value.serial).toBe(lost.serial)
    expect(retry.value.certificate).toBe(lost.certificate)
    expect(await issued(t, p.identity)).toEqual([lost.serial])
    const replay = await t.op(p, "team_vm.ssh_cert", { public_key: key }, idem)
    expect(replay.replayed).toBe(true)
    expect(replay.value.certificate).toBe(lost.certificate)
  })

  it("a crashed request that became a team server's, or whose member left, never resumes its certificate", async () => {
    const t = await setup("stack-ssh-0000000015")
    const key = await sshLine("ed25519")
    const p = t.install(t.owner, ["read", "mutate-own"], "mac", "inst_00000000000000000097")
    const idem = crypto.randomUUID()
    const lost = await crashOnce(t, p, { public_key: key }, idem)
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      const host = { id: "host_00000000000000000097", name: "mini", platform: "macos", owner_user: t.owner, enrolled_by: p.install, enrolled_at: 1, kind: "server" }
      engine.state = { ...engine.currentState, hosts: { ...engine.currentState.hosts, [host.id]: host } }
    })
    expect((await t.op(p, "team_vm.ssh_cert", { public_key: key }, idem)).error!.code).toBe("team_vm.ssh_class_refused")
    // The prepared certificate is forgotten with its issued-log row: it never left the object.
    expect(await issued(t, p.identity)).not.toContain(lost.serial)
  })

  it("a full-shell request that crashed after its presence proof resumes without a second approval or certificate", async () => {
    const t = await setup("stack-ssh-0000000014")
    const device = await presenceDevice(t)
    const key = await sshLine("p256")
    const idem = crypto.randomUUID()
    const ch = (await t.op(t.ownerP, "team_vm.ssh_cert.challenge", { public_key: key, presence_install: device.install, request: idem })).value
    const params = { public_key: key, class: "human", presence: await approve(device, ch) }
    const lost = await crashOnce(t, t.ownerP, params, idem)
    const retry = await t.op(t.ownerP, "team_vm.ssh_cert", params, idem)
    expect(retry.value).toMatchObject({ class: "human", serial: lost.serial, certificate: lost.certificate })
    expect(await issued(t, t.ownerP.identity)).toEqual([lost.serial])
  })
})
