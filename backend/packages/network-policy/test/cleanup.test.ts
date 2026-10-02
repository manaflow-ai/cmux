import { describe, expect, it } from "vitest"
import { cleanupExpired, compileNetwork, parsePolicy, parseExpiry, reconcile, vpcSlug, type Directory, type NetworkScope } from "../src/index.ts"
import { FakeFreestyle } from "./fake-freestyle.ts"
import { TEAM, directory, specPolicy } from "./fixtures.ts"

const compiled = (dir: Directory = directory) => {
  const p = parsePolicy(specPolicy)
  if (!p.ok) throw new Error("bad fixture")
  return compileNetwork(p.value, dir)
}
const DAY = 24 * 3600_000
const T0 = Date.UTC(2026, 9, 2)

describe("dev/staging scopes and the expiry cleanup", () => {
  it("prefixes dev resources and stamps an expiry on every one", async () => {
    const fs = new FakeFreestyle()
    const scope: NetworkScope = { team: TEAM, env: "dev", now: () => T0 }
    await reconcile(fs, scope, compiled(), directory)
    const vpc = [...fs.vpcs.values()][0]!
    expect(vpc.slug).toBe(vpcSlug(scope))
    expect(vpc.slug!.startsWith("cmuxnp-dev-")).toBe(true)
    expect(parseExpiry(vpc.displayName)).toBe(Math.floor((T0 + 7 * DAY) / 1000))
    expect([...fs.tunnels.values()].every((t) => t.slug!.startsWith("cmuxnp-dev-") && parseExpiry(t.displayName) !== null)).toBe(true)
    expect([...fs.rules.values()].every((r) => r.description.startsWith("cmux-np/v1 env=dev team=") && parseExpiry(r.description) !== null)).toBe(true)
  })

  it("a reconcile refreshes expiries once less than half the window is left", async () => {
    const fs = new FakeFreestyle()
    await reconcile(fs, { team: TEAM, env: "dev", now: () => T0 }, compiled(), directory)
    const quiet = await reconcile(fs, { team: TEAM, env: "dev", now: () => T0 + DAY }, compiled(), directory)
    expect(quiet.outcomes).toEqual([])
    const later = await reconcile(fs, { team: TEAM, env: "dev", now: () => T0 + 4 * DAY }, compiled(), directory)
    expect(later.outcomes.map((o) => o.action.op).sort()).toEqual(["tunnel.refresh", "tunnel.refresh", "tunnel.refresh", "vpc.refresh"])
    expect(parseExpiry([...fs.vpcs.values()][0]!.displayName)).toBe(Math.floor((T0 + 11 * DAY) / 1000))
  })

  it("deletes only expired resources of its own environment", async () => {
    const fs = new FakeFreestyle()
    // An expired dev team, a live dev team, a staging team, a production team, and someone else's rule.
    await reconcile(fs, { team: TEAM, env: "dev", now: () => T0 }, compiled(), directory)
    await reconcile(fs, { team: "team_live0000000000000000", env: "dev", now: () => T0 + 10 * DAY }, compiled(), directory)
    await reconcile(fs, { team: "team_stag0000000000000000", env: "staging", now: () => T0 }, compiled(), directory)
    await reconcile(fs, "team_prod0000000000000000", compiled(), directory)
    fs.rules.set("fw-other", { id: "fw-other", source: { vpcId: "vpc-x" }, destination: { vpcId: "vpc-x" }, description: "cmux machines exp=1000000000" })
    fs.foreignRuleIds.add("fw-other")
    const before = { vpcs: fs.vpcs.size, tunnels: fs.tunnels.size }
    const out = await cleanupExpired(fs, "dev", T0 + 8 * DAY)
    expect(out.every((o) => o.ok)).toBe(true)
    const slugs = [...fs.vpcs.values()].map((v) => v.slug!)
    expect(slugs.filter((s) => s.startsWith("cmuxnp-dev-"))).toEqual([vpcSlug({ team: "team_live0000000000000000", env: "dev" })])
    expect(slugs.some((s) => s.startsWith("cmuxnp-staging-"))).toBe(true)
    expect(slugs).toContain(vpcSlug("team_prod0000000000000000"))
    expect(fs.vpcs.size).toBe(before.vpcs - 1)
    expect(fs.tunnels.size).toBe(before.tunnels - 3)
    expect(fs.rules.has("fw-other")).toBe(true)
    // Rules of the live dev team stay even if their own stamp is old.
    expect([...fs.rules.values()].some((r) => r.description.includes(`team=${vpcSlug({ team: "team_live0000000000000000", env: "dev" }).slice(11)}`))).toBe(true)
    await expect(cleanupExpired(fs, "prod" as "dev")).rejects.toThrow()
  })
})
