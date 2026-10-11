import type { Principal, ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { allocateLinuxName, KRL_GRACE_MS, linuxNameBase, MAX_CERT_MS } from "../src/domains/team-ssh.ts"
import { sshExternal } from "../src/team-ssh-ca.ts"
import { parseUserKey } from "../src/team-ssh-wire.ts"
import { api, b64, inDO, mutate, readCert, readKrl, setup, sshLine, unb64 } from "./team-ssh-support.ts"

// ---------- pure reducer ----------
const TEAM = "team_00000000000000000081"
const OWNER = "user_00000000000000000081"
const MEMBER = "user_00000000000000000082"
let txn = 0
const ctx = (p: Principal, now = 1_000_000): ReduceContext => ({ principal: p, now, tx: `tx${++txn}`, newId: (x) => `${x}_${String(txn).padStart(20, "0")}` })
const system: Principal = { identity: "system:team", kind: "system" }
const base = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: { [OWNER]: { user: OWNER, role: "owner", display_name: "Lawrence Chen" }, [MEMBER]: { user: MEMBER, role: "member", display_name: "Lawrence Q" } },
  hosts: {}
})
const sys = (s: TeamState, op: string, params: unknown, now?: number) => {
  const denied = teamDomain.authorize!(s, op, params, system)
  if (denied) throw new Error(`${denied.code}: ${denied.message}`)
  const r = teamDomain.reduce(s, op, params, ctx(system, now))
  if (!r.ok) return r
  return r
}
const ok = <T extends { ok: boolean }>(r: T) => {
  if (!r.ok) throw new Error(JSON.stringify(r))
  return r as Extract<T, { ok: true }>
}
const CA1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl cmux-team-ca-1"
const CA2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjRyY2ZB0yWdJmD2gOs4WQbXOAkd0hLrSyX0SvTBnQd cmux-team-ca-2"

describe("team SSH CA (TeamDO reducer)", () => {

  it("internal SSH ops refuse people: the public API does not run them", async () => {
    const t = await setup("stack-ssh-0000000011")
    for (const op of ["team_vm.ssh_ca_installed", "team_vm.ssh_certs_revoked", "team_vm.ssh_account_allocated"]) {
      const r = await mutate(t.token, op, { user: t.owner })
      expect(r.ok ?? false, op).toBe(false)
      expect(r.error?.code ?? r.code, op).toBe("validation.invalid")
    }
  })

})

describe("team SSH key parsing (workerd)", () => {
  it("accepts Ed25519 and P-256 keys and refuses RSA, certificates, extra bytes and bad points", async () => {
    const t = await setup("stack-ssh-0000000012")
    const cert = (public_key: string) => mutate(t.token, "team_vm.ssh_cert", { public_key, class: "agent" })
    expect((await cert(await sshLine("ed25519"))).ok).toBe(true)
    expect((await cert(await sshLine("p256"))).ok).toBe(true)
    const ed = (await sshLine("ed25519")).split(" ")[1]!
    const p = unb64((await sshLine("p256")).split(" ")[1]!)
    p.fill(0, p.length - 64)
    for (const line of ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 x", "ssh-ed25519-cert-v01@openssh.com AAAA x", `ssh-ed25519 ${b64(Uint8Array.from([...unb64(ed), 0]))}`, `ecdsa-sha2-nistp256 ${ed}`, `ecdsa-sha2-nistp256 ${b64(p)}`]) {
      const r = await cert(line)
      expect([line.slice(0, 40), r.ok ?? false]).toEqual([line.slice(0, 40), false])
    }
  })
})

describe("team SSH CA (TeamDO, workerd)", () => {
  it("a person's session that asks for the agent class gets a restricted certificate that ssh tools accept; a replay returns the same certificate", async () => {
    const t = await setup("stack-ssh-0000000001")
    const key = await sshLine("ed25519")
    const idem = crypto.randomUUID()
    const before = Date.now()
    const r = await mutate(t.token, "team_vm.ssh_cert", { public_key: key, class: "agent" }, idem)
    expect(r.ok).toBe(true)
    expect(r.value).toMatchObject({ class: "agent", principals: ["lawrence-agents"], ca_generation: 1, serial: 1 })
    const read = await api(t.token, "/v1/read", { op: "team_vm.ssh_ca", params: {} })
    expect(read.value.trusted_ca_keys).toEqual([r.value.ca_public_key])
    const c = await readCert(r.value.certificate, r.value.ca_public_key)
    expect(c.verified).toBe(true)
    expect(c.certType).toBe(1)
    expect(c.principals).toEqual(["lawrence-agents"])
    expect(c.keyId).toMatch(new RegExp(`^${t.owner}/session/session/[0-9a-f]{12}$`))
    expect(c.critical).toEqual({ "force-command": "/opt/cmux/current/bin/cmux team restricted-shell" })
    expect(c.extensions).toEqual({ "cmux-teams@cmux.dev": t.team })
    // A full shell needs a fresh presence proof (decision SSH-1), even from a signed-in session. A session asks for a
    // full shell unless it names the agent class, so it gets an explicit error (the CLI then asks for presence), never a silent agent certificate.
    expect((await mutate(t.token, "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_presence_required")
    expect((await mutate(t.token, "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_presence_required")
    expect(c.validBefore - c.validAfter).toBe(31 * 60)
    expect(c.validAfter * 1000).toBeLessThanOrEqual(before)
    const again = await mutate(t.token, "team_vm.ssh_cert", { public_key: key, class: "agent" }, idem)
    expect(again.replayed).toBe(true)
    expect(again.value.certificate).toBe(r.value.certificate)
    expect((await mutate(t.token, "team_vm.ssh_cert", { public_key: key, class: "agent", validity_minutes: 20 }, idem)).error!.code).toBe("idempotency.conflict")
    expect((await mutate(t.token, "team_vm.ssh_cert", { public_key: key, validity_minutes: 61 })).error!.code).toBe("validation.invalid")
    expect((await mutate(t.token, "team_vm.ssh_cert", { public_key: "ssh-rsa AAAAB3NzaC1yc2E x" })).error!.code).toBe("team_vm.ssh_key_invalid")
    // The CA private key is only in its sealed row: never in state, the op ledger or a reply (Ed25519 PKCS#8 starts MC4CAQAwBQYDK2Vw).
    const dump = await inDO(t.stub, async (instance, state) => {
      const rows = state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table'`).toArray() as Array<{ name: string }>
      const tables = rows.filter((x) => x.name !== "ssh_ca_keys" && !x.name.startsWith("_cf")).map((x) => JSON.stringify(state.storage.sql.exec(`SELECT * FROM "${x.name}"`).toArray()))
      const sealed = state.storage.sql.exec(`SELECT sealed FROM ssh_ca_keys`).toArray() as Array<{ sealed: string }>
      return { other: tables.join("\n") + JSON.stringify(instance.boundEngine.currentState), sealed: sealed.map((x) => x.sealed).join("\n") }
    })
    expect(dump.other).not.toContain("MC4CAQAwBQYDK2Vw")
    expect(dump.sealed).not.toContain("MC4CAQAwBQYDK2Vw")
    expect(JSON.parse(dump.sealed.split("\n")[0]!)).toMatchObject({ v: 1 })
  })

  it("installs get only the restricted agent class; a full shell needs a person's session; agents, servers and outsiders are refused", async () => {
    const t = await setup("stack-ssh-0000000002")
    const key = await sshLine("p256")
    const agent = await t.op(t.install(t.owner, ["read", "mutate-own", "cloud-link"]), "team_vm.ssh_cert", { public_key: key })
    expect(agent.value).toMatchObject({ class: "agent", principals: ["lawrence-agents"] })
    const c = await readCert(agent.value.certificate, agent.value.ca_public_key)
    expect(c.verified).toBe(true)
    expect(c.critical).toEqual({ "force-command": "/opt/cmux/current/bin/cmux team restricted-shell" })
    expect(c.extensions).toEqual({ "cmux-teams@cmux.dev": t.team })
    expect(c.keyId.startsWith(`${t.owner}/grant_00000000000000000081/inst_00000000000000000081/`)).toBe(true)
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "cloud-link"]), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], "vm"), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.install(t.owner, ["read", "cloud-link"]), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op({ ...t.ownerP, agent: "agent_x" }, "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    // Install tokens never mint a full shell, not even a Mac or CLI install with execute: only a person's session does.
    for (const kind of ["cli", "mac"]) expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], kind), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], "cli"), "team_vm.ssh_cert", { public_key: key })).value).toMatchObject({ class: "agent", principals: ["lawrence-agents"] })
    const aziz = await t.op(t.memberP, "team_vm.ssh_cert", { public_key: key, class: "agent" })
    expect(aziz.value.principals).toEqual(["aziz-agents"])
    const outsider: Principal = { identity: "session:user_00000000000000000777", kind: "session", user: "user_00000000000000000777", team: t.team }
    expect((await t.op(outsider, "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("auth.forbidden")
    // A team server's install never gets a certificate (server.md: servers have no SSH access).
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      const host = { id: "host_00000000000000000081", name: "mini", platform: "macos", owner_user: t.owner, enrolled_by: "inst_00000000000000000099", enrolled_at: 1, kind: "server" }
      engine.state = { ...engine.currentState, hosts: { ...engine.currentState.hosts, [host.id]: host } }
    })
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], "mac", "inst_00000000000000000099"), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_class_refused")
    // A removed server whose install revocation is still pending is refused too.
    await inDO(t.stub, async (instance) => {
      const engine = instance.boundEngine
      engine.state = { ...engine.currentState, server_revocations: { inst_00000000000000000098: { install: "inst_00000000000000000098", owner_user: t.owner, by: t.owner, at: 1 } } }
    })
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], "mac", "inst_00000000000000000098"), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_class_refused")
    // execute or cloud-link alone does not give the agent class (it needs mutate-own).
    expect((await t.op(t.install(t.owner, ["read", "execute"]), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_class_refused")
  })

  it("revocation lists serials in the KRL; members revoke only their own; owners revoke anyone's", async () => {
    const t = await setup("stack-ssh-0000000003")
    const key = await sshLine("ed25519")
    const mine = (await t.op(t.memberP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).value.serial as number
    const owners = (await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).value.serial as number
    expect((await t.op(t.memberP, "team_vm.ssh_cert.revoke", { serial: owners })).error!.code).toBe("auth.forbidden")
    expect((await t.op(t.memberP, "team_vm.ssh_cert.revoke", { user: t.owner })).error!.code).toBe("auth.forbidden")
    expect((await t.op(t.memberP, "team_vm.ssh_cert.revoke", { serial: mine, user: t.member })).error!.code).toBe("validation.invalid")
    // A long client idempotency key still fits the owner's ledger key (it is hashed).
    const r = await t.op(t.memberP, "team_vm.ssh_cert.revoke", { serial: mine, reason: "lost laptop" }, "k".repeat(120))
    expect(r.value.revoked).toEqual([mine])
    let krl = readKrl((await t.ca()).value.krl)
    expect(krl.serials).toEqual([mine])
    expect(krl.version).toBe((await t.ca()).value.krl_version)
    const all = await t.op(t.ownerP, "team_vm.ssh_cert.revoke", { user: t.owner })
    expect(all.value.revoked).toEqual([owners])
    krl = readKrl((await t.ca()).value.krl)
    expect(krl.serials.sort()).toEqual([mine, owners].sort())
    expect((await t.op(t.install(t.member, ["read", "mutate-own"]), "team_vm.ssh_cert.revoke", { serial: mine })).error!.code).toBe("auth.forbidden")
  })

  it("rotation: owners in a session only; the old CA stays trusted, or is revoked at once when compromised", async () => {
    const t = await setup("stack-ssh-0000000004")
    const key = await sshLine("ed25519")
    const first = (await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).value
    expect((await t.op(t.memberP, "team_vm.ssh_ca.rotate", {})).error!.code).toBe("auth.forbidden")
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "mutate-shared", "execute", "destructive"]), "team_vm.ssh_ca.rotate", {})).error!.code).toBe("auth.forbidden")
    const rot = await t.op(t.ownerP, "team_vm.ssh_ca.rotate", {})
    expect(rot.value.generation).toBe(2)
    expect((await t.ca()).value.trusted_ca_keys).toEqual([rot.value.ca_public_key, first.ca_public_key])
    const second = (await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).value
    expect(second.ca_generation).toBe(2)
    expect((await readCert(second.certificate, rot.value.ca_public_key)).verified).toBe(true)
    const hard = await t.op(t.ownerP, "team_vm.ssh_ca.rotate", { compromised: true })
    expect(hard.value.generation).toBe(3)
    const view = (await t.ca()).value
    expect(view.trusted_ca_keys).toEqual([hard.value.ca_public_key])
    expect(readKrl(view.krl).keys).toEqual([first.ca_public_key.split(" ")[1], rot.value.ca_public_key.split(" ")[1]])
    // Only the current key is stored, sealed.
    const gens = await inDO(t.stub, async (_i, state) => (state.storage.sql.exec(`SELECT generation FROM ssh_ca_keys`).toArray() as Array<{ generation: number }>).map((x) => x.generation))
    expect(gens).toEqual([3])
    // A sealed row left by a crashed attempt is never reused by a compromised rotation.
    const stale = await inDO(t.stub, async (_i, state) => {
      const row = state.storage.sql.exec(`SELECT sealed, public_key FROM ssh_ca_keys WHERE generation = 3`).toArray()[0] as { sealed: string; public_key: string }
      state.storage.sql.exec(`INSERT INTO ssh_ca_keys (generation, sealed, public_key) VALUES (4, ?, ?)`, row.sealed, row.public_key.replace("ca-3", "ca-4"))
      return row.public_key.replace("ca-3", "ca-4")
    })
    const fresh = await t.op(t.ownerP, "team_vm.ssh_ca.rotate", { compromised: true })
    expect(fresh.value.generation).toBe(4)
    expect(fresh.value.ca_public_key).not.toBe(stale)
  })

  it("refuses without a KEK and rate-limits issuance per caller", async () => {
    const t = await setup("stack-ssh-0000000005")
    const key = await sshLine("ed25519")
    const noKek = await inDO(t.stub, async (instance, state) =>
      sshExternal(
        {
          state: () => instance.boundEngine.currentState,
          rows: instance.boundEngine.rows,
          team: t.team,
          stream: `team:${t.team}`,
          kek: undefined,
          sql: state.storage.sql,
          now: () => Date.now(),
          submitSystem: (op, params, k) => instance.submitSystem(op, params, k),
          running: new Set()
        },
        t.ownerP,
        { op: "team_vm.ssh_cert", params: { public_key: key, class: "agent" }, idempotency_key: "no-kek" }
      )
    )
    expect(noKek.error?.code).toBe("team_vm.ssh_ca_not_configured")
    for (let i = 0; i < 30; i++) expect((await t.op(t.memberP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).ok).toBe(true)
    const limited = await t.op(t.memberP, "team_vm.ssh_cert", { public_key: key, class: "agent" })
    expect(limited.error).toMatchObject({ code: "team_vm.ssh_rate_limited", retryable: true })
    expect((await t.op(t.ownerP, "team_vm.ssh_cert", { public_key: key, class: "agent" })).ok).toBe(true)
    // Per person across installs: a second install gets 30 more, a third gets none.
    for (let i = 0; i < 30; i++) expect((await t.op(t.install(t.member, ["read", "mutate-own", "mutate-shared", "cloud-link"], "mac", "inst_00000000000000000082"), "team_vm.ssh_cert", { public_key: key })).ok).toBe(true)
    expect((await t.op(t.install(t.member, ["read", "mutate-own", "mutate-shared", "cloud-link"], "mac", "inst_00000000000000000083"), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_rate_limited")
  })
})
