import { describe, expect, it } from "vitest"
import { compileNetwork, parsePolicy, reconcile, teardown, tunnelSlug, withKeepalive, type Directory } from "../src/index.ts"
import { FakeFreestyle } from "./fake-freestyle.ts"
import { TEAM, directory, specPolicy } from "./fixtures.ts"

const compiled = (dir: Directory = directory) => {
  const p = parsePolicy(specPolicy)
  if (!p.ok) throw new Error("bad fixture")
  return compileNetwork(p.value, dir)
}

describe("reconcile against an in-memory Freestyle", () => {
  it("creates the VPC, one tunnel per active device and the rules, then converges", async () => {
    const fs = new FakeFreestyle()
    const r = await reconcile(fs, TEAM, compiled(), directory)
    expect(r.converged).toBe(true)
    expect(fs.vpcs.size).toBe(1)
    expect(fs.tunnels.size).toBe(3)
    expect(r.tunnels.map((t) => t.install)).toEqual(["inst_amac0000000000000000", "inst_lmac0000000000000000", "inst_zmac0000000000000000"])
    expect(r.tunnels[0]!.clientConfig).toContain("PersistentKeepalive = 25")
    expect(fs.rules.size).toBe(compiled().rules.length)
    const vpc = [...fs.vpcs.values()][0]!
    const aziz = r.tunnels.find((t) => t.install === "inst_zmac0000000000000000")!.tunnelId
    expect(fs.allows(aziz, "vm-team", 22, vpc.id)).toBe(true)
    expect(fs.allows(aziz, "vm-sandbox", 22, vpc.id)).toBe(false)
    // A second run is a no-op.
    const again = await reconcile(fs, TEAM, compiled(), directory, { expectConverged: true })
    expect(again.outcomes).toEqual([])
    expect(again.drift).toEqual([])
  })

  it("revokes a device: its tunnel goes first and its rules die with it", async () => {
    const fs = new FakeFreestyle()
    await reconcile(fs, TEAM, compiled(), directory)
    const revoked: Directory = { ...directory, devices: directory.devices.map((d) => (d.install === "inst_zmac0000000000000000" ? { ...d, revoked: true } : d)) }
    const r = await reconcile(fs, TEAM, compiled(revoked), revoked, { expectConverged: true })
    expect(r.outcomes[0]!.action.op).toBe("tunnel.delete")
    expect(r.outcomes.filter((o) => o.action.op === "rule.delete")).toEqual([])
    expect([...fs.tunnels.values()].some((t) => t.slug === tunnelSlug(TEAM, "inst_zmac0000000000000000"))).toBe(false)
    expect(fs.rules.size).toBe(compiled(revoked).rules.length)
  })

  it("detects and repairs drift (a rule deleted out of band) without touching foreign rules", async () => {
    const fs = new FakeFreestyle()
    fs.rules.set("fw-foreign", { id: "fw-foreign", source: { vpcId: "vpc-x" }, destination: { vpcId: "vpc-x" }, description: "someone else" })
    fs.foreignRuleIds.add("fw-foreign")
    await reconcile(fs, TEAM, compiled(), directory)
    const victim = [...fs.rules.keys()].find((k) => k !== "fw-foreign")!
    fs.rules.delete(victim)
    const r = await reconcile(fs, TEAM, compiled(), directory, { expectConverged: true })
    expect(r.drift.map((a) => a.op)).toEqual(["rule.create"])
    expect(r.converged).toBe(true)
    expect(fs.rules.has("fw-foreign")).toBe(true)
  })

  it("settles indeterminate failures by reading back (no duplicates)", async () => {
    const fs = new FakeFreestyle()
    fs.failNext("createVpc", "after")
    fs.failNext("createTunnel", "after")
    fs.failNext("createRule", "after")
    fs.failNext("createRule", "before", 500)
    const r = await reconcile(fs, TEAM, compiled(), directory)
    expect(r.converged).toBe(true)
    expect(fs.vpcs.size).toBe(1)
    expect(fs.tunnels.size).toBe(3)
    expect(fs.rules.size).toBe(compiled().rules.length)
    expect(r.outcomes.filter((o) => !o.ok).length).toBe(2)
  })

  it("reports unmanaged rules that grant access to team resources, without touching them", async () => {
    const fs = new FakeFreestyle()
    await reconcile(fs, TEAM, compiled(), directory)
    const vpc = [...fs.vpcs.values()][0]!
    fs.rules.set("fw-legacy", { id: "fw-legacy", source: { vpcId: "vpc-elsewhere" }, destination: { vmId: "vm-team" }, description: "" })
    fs.rules.set("fw-egress", { id: "fw-egress", source: { vmId: "vm-team" }, destination: { public: true }, description: "" })
    fs.rules.set("fw-unrelated", { id: "fw-unrelated", source: { vpcId: "vpc-x" }, destination: { vpcId: "vpc-x" }, description: "" })
    fs.foreignRuleIds.add("fw-legacy").add("fw-egress").add("fw-unrelated")
    const r = await reconcile(fs, TEAM, compiled(), directory, { expectConverged: true })
    expect(r.foreign.map((x) => x.id)).toEqual(["fw-legacy"])
    expect(r.outcomes).toEqual([])
    expect(vpc.id).toBeTruthy()
  })

  it("never names a VM that is not on the team VPC, and deletes duplicate rules", async () => {
    const fs = new FakeFreestyle()
    fs.autoMember = false
    fs.vmVpcs.set("vm-team", ["vpc-someone-else"])
    const r = await reconcile(fs, TEAM, compiled(), directory)
    expect([...fs.rules.values()].some((x) => x.destination.vmId || x.source.vmId)).toBe(false)
    expect(r.deferred.some((d) => d.reason.includes("not") || d.reason.includes("team VPC"))).toBe(true)
    // A duplicate of a managed rule is removed on the next run.
    const one = [...fs.rules.values()][0]!
    fs.rules.set("fw-dup", { ...one, id: "fw-dup" })
    await reconcile(fs, TEAM, compiled(), directory)
    expect([...fs.rules.values()].filter((x) => x.description === one.description && JSON.stringify(x.source) === JSON.stringify(one.source)).length).toBe(1)
  })

  it("rotates a tunnel key when the device sends a new one", async () => {
    const fs = new FakeFreestyle()
    await reconcile(fs, TEAM, compiled(), directory)
    const rekeyed: Directory = { ...directory, devices: directory.devices.map((d) => (d.install === "inst_amac0000000000000000" ? { ...d, wg_public_key: "B".repeat(43) + "=" } : d)) }
    const r = await reconcile(fs, TEAM, compiled(rekeyed), rekeyed)
    expect(r.outcomes.map((o) => o.action.op)).toEqual(["tunnel.rotate"])
  })

  it("tears down only what it made", async () => {
    const fs = new FakeFreestyle()
    fs.rules.set("fw-foreign", { id: "fw-foreign", source: { vpcId: "vpc-x" }, destination: { vpcId: "vpc-x" }, description: "cmux-np/v1 team=000000000000 rule=x" })
    fs.foreignRuleIds.add("fw-foreign")
    await reconcile(fs, TEAM, compiled(), directory)
    await teardown(fs, TEAM)
    expect(fs.vpcs.size).toBe(0)
    expect(fs.tunnels.size).toBe(0)
    expect([...fs.rules.keys()]).toEqual(["fw-foreign"])
  })
})

describe("withKeepalive", () => {
  it("adds PersistentKeepalive inside [Peer] once", () => {
    const c = "[Interface]\nPrivateKey = \n\n[Peer]\nPublicKey = X\nEndpoint = e:51820\n"
    const out = withKeepalive(c)
    expect(out).toBe("[Interface]\nPrivateKey = \n\n[Peer]\nPublicKey = X\nEndpoint = e:51820\nPersistentKeepalive = 25\n")
    expect(withKeepalive(out)).toBe(out)
  })
})
