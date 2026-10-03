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
  it("Linux names come from the display name, skip reserved and taken names, and fit sshd limits", () => {
    expect(linuxNameBase("Lawrence Chen")).toBe("lawrence")
    expect(linuxNameBase("Ángel Pérez")).toBe("angel")
    expect(linuxNameBase("42")).toBe("u42")
    expect(linuxNameBase("李")).toBe("u")
    expect(linuxNameBase("x".repeat(40)).length).toBe(20)
    expect(allocateLinuxName("Root", new Set())).toBe("root2")
    expect(allocateLinuxName("Lawrence", new Set(["lawrence", "lawrence2"]))).toBe("lawrence3")
  })

  it("allocates one account and UID block per member, never twice, members only", () => {
    const a = ok(sys(base(), "team_vm.ssh_account_allocated", { user: OWNER }))
    expect(a.value).toEqual({ name: "lawrence", uid: 20_000 })
    const b = ok(sys(a.state, "team_vm.ssh_account_allocated", { user: MEMBER }))
    expect(b.value).toEqual({ name: "lawrence2", uid: 20_004 })
    const again = ok(sys(b.state, "team_vm.ssh_account_allocated", { user: OWNER }))
    expect(again.changed).toBe(false)
    expect(sys(b.state, "team_vm.ssh_account_allocated", { user: "user_00000000000000000099" })).toMatchObject({ ok: false, code: "auth.forbidden" })
    // UIDs stop before the system range at the top (65534 is nobody).
    expect(sys({ ...a.state, vm_next_uid: 59_997 }, "team_vm.ssh_account_allocated", { user: MEMBER })).toMatchObject({ ok: false, code: "team_vm.ssh_accounts_full" })
    expect(allocateLinuxName("Git Lab", new Set())).toBe("git2")
  })

  it("internal SSH ops refuse people; the signing ops never enter the reducer or the wire", () => {
    const owner: Principal = { identity: `user:${OWNER}`, user: OWNER, team: TEAM, kind: "session" }
    for (const op of ["team_vm.ssh_ca_installed", "team_vm.ssh_certs_revoked", "team_vm.ssh_account_allocated"]) expect(teamDomain.authorize!(base(), op, {}, owner)).toBeTruthy()
    for (const op of ["team_vm.ssh_cert", "team_vm.ssh_cert.revoke", "team_vm.ssh_ca.rotate"]) expect(teamDomain.authorize!(base(), op, {}, owner)).toMatchObject({ code: "validation.invalid" })
  })

  it("a rotation keeps the old CA trusted for one maximum validity; a compromised one drops it and lists it in the KRL", () => {
    const s1 = ok(sys(base(), "team_vm.ssh_ca_installed", { generation: 1, public_key: CA1, compromised: false, by: OWNER }, 1_000)).state
    expect(s1.ssh_ca).toMatchObject({ generation: 1, public_key: CA1 })
    expect(s1.audit_count).toBe(1)
    expect(sys(s1, "team_vm.ssh_ca_installed", { generation: 3, public_key: CA2, compromised: false, by: OWNER })).toMatchObject({ ok: false, code: "revision.conflict" })
    expect(ok(sys(s1, "team_vm.ssh_ca_installed", { generation: 1, public_key: CA2, compromised: false, by: OWNER })).changed).toBe(false)
    const plain = ok(sys(s1, "team_vm.ssh_ca_installed", { generation: 2, public_key: CA2, compromised: false, by: OWNER }, 5_000)).state
    expect(plain.ssh_ca?.previous).toMatchObject({ generation: 1, trusted_until: 5_000 + MAX_CERT_MS })
    expect(plain.ssh_revoked_ca_keys).toBeUndefined()
    const hard = ok(sys(s1, "team_vm.ssh_ca_installed", { generation: 2, public_key: CA2, compromised: true, by: OWNER }, 5_000)).state
    expect(hard.ssh_ca?.previous?.trusted_until).toBe(5_000)
    expect(hard.ssh_revoked_ca_keys).toEqual([CA1])
    expect(hard.ssh_krl!.version).toBe(s1.ssh_krl!.version + 1)
  })

  it("revocations bump the KRL version, drop expired entries and ignore repeats", () => {
    const s1 = ok(sys(base(), "team_vm.ssh_ca_installed", { generation: 1, public_key: CA1, compromised: false, by: OWNER }, 1_000)).state
    const r = ok(sys(s1, "team_vm.ssh_certs_revoked", { serials: [{ serial: 4, valid_before: 9_000, generation: 1 }, { serial: 5, valid_before: 2_000, generation: 1 }], by: OWNER, reason: "" }, 2_000 + KRL_GRACE_MS))
    expect(r.value).toEqual({ revoked: [4], krl_version: 2 })
    expect(Object.keys(r.state.ssh_revoked!)).toEqual(["4"])
    expect(ok(sys(r.state, "team_vm.ssh_certs_revoked", { serials: [{ serial: 4, valid_before: 9_000, generation: 1 }], by: OWNER, reason: "" }, 2_500 + KRL_GRACE_MS)).changed).toBe(false)
    // A revoked serial stays listed for KRL_GRACE_MS past expiry (a team VM clock that runs behind).
    const graced = ok(sys(r.state, "team_vm.ssh_certs_revoked", { serials: [{ serial: 6, valid_before: 400_000, generation: 1 }], by: OWNER, reason: "" }, 9_000 + KRL_GRACE_MS - 1)).state
    expect(Object.keys(graced.ssh_revoked!).sort()).toEqual(["4", "6"])
    const later = ok(sys(graced, "team_vm.ssh_certs_revoked", { serials: [{ serial: 7, valid_before: 9e9, generation: 1 }], by: OWNER, reason: "" }, 400_000 + KRL_GRACE_MS)).state
    expect(Object.keys(later.ssh_revoked!)).toEqual(["7"])
  })

  it("a compromised rotation inside another rotation's grace window revokes both older CA keys", () => {
    const s1 = ok(sys(base(), "team_vm.ssh_ca_installed", { generation: 1, public_key: CA1, compromised: false, by: OWNER }, 1_000)).state
    const s2 = ok(sys(s1, "team_vm.ssh_ca_installed", { generation: 2, public_key: CA2, compromised: false, by: OWNER }, 2_000)).state
    const s3 = ok(sys(s2, "team_vm.ssh_ca_installed", { generation: 3, public_key: CA1.replace("ca-1", "ca-3"), compromised: true, by: OWNER }, 3_000)).state
    expect(s3.ssh_revoked_ca_keys).toEqual([CA1, CA2])
  })
})

describe("team SSH key parsing (workerd)", () => {
  it("accepts Ed25519 and P-256 lines and refuses RSA, certificates, extra bytes and bad points", async () => {
    expect((await parseUserKey(await sshLine("ed25519")))?.type).toBe("ssh-ed25519")
    expect((await parseUserKey(await sshLine("p256")))?.type).toBe("ecdsa-sha2-nistp256")
    expect(await parseUserKey("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 x")).toBeNull()
    expect(await parseUserKey("ssh-ed25519-cert-v01@openssh.com AAAA x")).toBeNull()
    const ed = (await sshLine("ed25519")).split(" ")[1]!
    expect(await parseUserKey(`ssh-ed25519 ${b64(Uint8Array.from([...unb64(ed), 0]))}`)).toBeNull()
    expect(await parseUserKey(`ecdsa-sha2-nistp256 ${ed}`)).toBeNull()
    const p = unb64((await sshLine("p256")).split(" ")[1]!)
    p.fill(0, p.length - 64)
    expect(await parseUserKey(`ecdsa-sha2-nistp256 ${b64(p)}`)).toBeNull()
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
    expect(c.critical).toEqual({ "force-command": "cmux team restricted-shell" })
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
    const agent = await t.op(t.install(t.owner, ["read", "mutate-own"]), "team_vm.ssh_cert", { public_key: key })
    expect(agent.value).toMatchObject({ class: "agent", principals: ["lawrence-agents"] })
    const c = await readCert(agent.value.certificate, agent.value.ca_public_key)
    expect(c.verified).toBe(true)
    expect(c.critical).toEqual({ "force-command": "cmux team restricted-shell" })
    expect(c.extensions).toEqual({ "cmux-teams@cmux.dev": t.team })
    expect(c.keyId.startsWith(`${t.owner}/grant_00000000000000000081/inst_00000000000000000081/`)).toBe(true)
    expect((await t.op(t.install(t.owner, ["read", "mutate-own"]), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.install(t.owner, ["read", "mutate-own", "execute"], "vm"), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    expect((await t.op(t.install(t.owner, ["read"]), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_class_refused")
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
    // execute alone does not give the agent class (it needs mutate-own).
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
          team: t.team,
          stream: `team:${t.team}`,
          kek: undefined,
          sql: state.storage.sql,
          now: () => Date.now(),
          submitSystem: (op, params, k) => instance.submitSystem(op, params, k)
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
    for (let i = 0; i < 30; i++) expect((await t.op(t.install(t.member, ["read", "mutate-own"], "mac", "inst_00000000000000000082"), "team_vm.ssh_cert", { public_key: key })).ok).toBe(true)
    expect((await t.op(t.install(t.member, ["read", "mutate-own"], "mac", "inst_00000000000000000083"), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("team_vm.ssh_rate_limited")
  })
})
