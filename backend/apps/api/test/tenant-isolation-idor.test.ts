import { beforeAll, describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { call, callOp, callRead, catalogOps, idsIn, makeTenant, post, sampleParams, shape, stable, succeeded, type Reply, type Tenant } from "./setup/tenant.ts"

/**
 * Tenant isolation, IDOR sweep (plans/cmux-next/tenant-isolation-DESIGN.md section 5.1). Tenant A owns real
 * resources: a machine, a snapshot, a group, a DM with a message, an automation, a chief, a feed item, an
 * install, a host. Tenant B then calls EVERY operation in the catalog (as a session and as an install token)
 * with A's ids in every id-typed parameter. Expected: no reply carries an A canary, no operation changes A's
 * own view, and an operation that answers ok for B with an A id is listed in ALLOWED_OK with its reason.
 */

/**
 * Operations that change the CALLER'S OWN state and take no foreign id as a way in, so the second call of a
 * real-vs-unknown pair differs only because the first call changed B (a revoked install, a second chief, a
 * rotated key, a pending approval). They are covered by their own tests; the existence-oracle comparison
 * would only report B's own state change.
 */
const OWN_STATE: ReadonlySet<string> = new Set(["install.sign_out", "install.register", "chief.create", "integration.connect", "team_vm.rebuild", "team_vm.ssh_ca.rotate", "cloud.machine.resize"])
/**
 * ACCEPTED RISK R1 (tenant-isolation-DESIGN.md 7): an op that CREATES at a client-chosen id answers `conversation_exists` for an id that exists,
 * whoever owns it. A creating call with a free id succeeds, so no answer can hide the difference. The id is a 130-bit random value that
 * is never listed to a non-member; the answer reveals nothing but that an id the caller already holds is taken. Pinned to this exact code,
 * so any other difference on these ops still fails the sweep.
 */
const ACCEPTED_EXISTS: ReadonlySet<string> = new Set(["conversation.import"])
const GROUPS: Array<string> = []
let a: Tenant
let a2: Tenant
let b: Tenant
const fixtures: Record<string, string> = {}
const created: Array<[string, Reply]> = []
const learn = (op: string, r: Reply) => {
  created.push([op, r])
  if (succeeded(r)) for (const [k, v] of Object.entries(idsIn(r.body))) fixtures[k] ??= v
}
const aView = async () => {
  const reads: Array<[string, unknown]> = [
    ["cloud.machine.list", {}],
    ["cloud.snapshot.list", {}],
    ["group.list", {}],
    ["inbox.list", { limit: 50 }],
    ["automation.list", {}],
    ["chief.list", {}],
    ["install.list", {}],
    ["feed.list", {}],
    ["team.hosts.list", {}],
    ["team.members.list", {}],
    ["team.directory", {}]
  ]
  const out: Record<string, unknown> = {}
  for (const [op, params] of reads) {
    const r = await callRead(a.session, op, params)
    out[op] = r.code ? `error:${r.code}` : stable(r.body)
  }
  const conv = fixtures.ConversationId
  if (conv) out["conversation.history"] = stable((await callRead(a.session, "conversation.history", { conversation: conv, limit: 50 })).body)
  return out
}

beforeAll(async () => {
  a = await makeTenant("a")
  a2 = await makeTenant("b") // a second account only to give A someone to talk to
  b = await makeTenant("c")
  fixtures.TeamId = a.team
  fixtures.UserId = a.user
  fixtures.InstallId = a.install
  const m = await callOp(a.session, "cloud.machine.create", { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 }, name: `${a.canary} machine` })
  learn("cloud.machine.create", m)
  if (fixtures.MachineId) {
    const { json } = await bindFile(cloudStub(a.team), fixtures.MachineId)
    const bound = await post("/v1/cloud/bind", undefined, { team: a.team, machine: fixtures.MachineId, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: (await vmKey()).jwk })
    created.push(["cloud.bind", bound])
  }
  if (fixtures.MachineId) learn("cloud.snapshot.create", await callOp(a.session, "cloud.snapshot.create", { machine: fixtures.MachineId, name: `${a.canary} snap` }))
  learn("group.create", await callOp(a.session, "group.create", { name: `${a.canary} group` }))
  const dm = await callOp(a.session, "dm.open", { peer: { email: a2.email } })
  learn("dm.open", dm)
  const conv = dm.body?.value?.conversation?.id as string | undefined
  if (conv) {
    fixtures.ConversationId = conv
    const key = crypto.randomUUID()
    learn("message.send", await callOp(a.session, "message.send", { conversation: conv, client_msg_id: key, parts: [{ type: "text", text: `${a.canary} secret message` }] }, key))
  }
  learn("automation.create", await callOp(a.session, "automation.create", sampleParams("automation.create", fixtures) as never))
  learn("chief.create", await callOp(a.session, "chief.create", {}))
  learn("feed.post", await callOp(a.session, "feed.post", { type: "notice", kind: "notice", title: `${a.canary} feed` }))
  learn("host.enroll", await callOp(a.installToken, "host.enroll", { name: `${a.canary} host`, platform: "macos" }))
}, 120_000)

describe("tenant fixtures", () => {
  it("tenant A really owns the resources B will probe (a sweep over nothing proves nothing)", () => {
    for (const k of ["MachineId", "SnapshotId", "ConversationId", "InstallId", "TeamId", "UserId"]) expect(fixtures[k], `${k}; created: ${JSON.stringify(created.map(([o, r]) => [o, r.code, r.code ? r.raw.slice(0, 300) : undefined]))}`).toBeTruthy()
  })
})

describe("IDOR sweep: B calls every operation with A's ids", { timeout: 300_000 }, () => {
  it("no reply to B carries an A marker, no op changes A's view, and A's ids answer exactly like ids that do not exist", async () => {
    const before = await aView()
    const leaks: Array<string> = []
    const oracle: Array<string> = []
    let reached = 0
    let invalid = 0
    const rows: Array<string> = []
    const missing: Record<string, string> = {}
    for (const [name, def] of Object.entries(catalogOps)) {
      const callers: Array<[string, string]> = []
      if (def.principals.includes("session")) callers.push(["session", b.session])
      if (def.principals.includes("install")) callers.push(["install", b.installToken])
      for (const [kind, token] of callers) {
        const sig = (r: Reply) => `${r.status} ${r.code ?? "ok"}`
        const differs = (real: Reply, control: Reply) => !OWN_STATE.has(name) && !(ACCEPTED_EXISTS.has(name) && real.code === "conversation_exists") && (sig(real) !== sig(control) || (real.code === undefined && shape(real.raw) !== shape(control.raw)))
        let real = await call(def.class, token, name, sampleParams(name, fixtures))
        // Control: the same call with ids that exist nowhere (fresh random ids of the same shape).
        let control = await call(def.class, token, name, sampleParams(name, missing))
        // Random ids can occasionally build a refused value; a real oracle differs every time, so two more draws must also differ.
        for (let retry = 0; retry < 2 && differs(real, control); retry++) {
          real = await call(def.class, token, name, sampleParams(name, fixtures))
          control = await call(def.class, token, name, sampleParams(name, missing))
        }
        if (real.code === "validation.invalid") invalid++
        else reached++
        if (real.raw.includes("CANARY-A-") || real.raw.includes(a.email)) leaks.push(`${name} (${kind}): ${real.raw.slice(0, 200)}`)
        // Existence oracle: A's real id must be indistinguishable from an unknown id (same status, code, shape).
        if (differs(real, control)) oracle.push(`${name} (${kind}): A-id -> ${sig(real)} ${real.raw.slice(0, 140)} | unknown-id -> ${sig(control)} ${control.raw.slice(0, 140)}`)
        rows.push(`${name}\t${kind}\t${real.status}\t${real.code ?? "ok"}`)
      }
    }
    const after = await aView()
    console.log(`IDOR sweep: ${rows.length} calls, ${reached} reached authorization, ${invalid} stopped at validation`)
    console.log(rows.join("\n"))
    expect(leaks, "A markers in B replies").toEqual([])
    expect(after, "A's own view changed").toEqual(before)
    if (oracle.length > 0) throw new Error(`A ids answered differently from unknown ids (${oracle.length}):\n${oracle.join("\n")}`)
    expect(reached / (reached + invalid)).toBeGreaterThan(0.6)
    void GROUPS
  })
})
