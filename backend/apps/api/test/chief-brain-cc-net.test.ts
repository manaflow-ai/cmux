import { describe, expect, it } from "vitest"
import { CC_NET_DEFAULT, netScript, patchNet, readNet } from "../src/chief-brain-cc/net.ts"

/**
 * The network settings of a Cloud Chief's turn machine (chief-brain-cc/net.ts): what the agent user may
 * reach, the patch the Chief's `chief-net` tool sends, and the root script that applies them in the guest.
 * The script itself is proven on a real VM by backend/chief-cc/net-check.sh.
 */
describe("Cloud Chief turn machine network settings", () => {
  it("defaults to the public Internet over IPv4 and IPv6 with DNS and the tailnet open, loopback closed", () => {
    expect(CC_NET_DEFAULT).toEqual({ internet: true, dns: true, tailnet: true, local: false, allow: [], deny: [] })
    // The tailnet includes its DNS (100.100.100.100) and the IPv6 range.
    expect(netScript(CC_NET_DEFAULT)).toContain("ip daddr 100.64.0.0/10 accept")
    expect(netScript(CC_NET_DEFAULT)).toContain("ip6 daddr fd7a:115c:a1e0::/48 accept")
    expect(readNet(undefined)).toEqual(CC_NET_DEFAULT)
    expect(readNet("not json")).toEqual(CC_NET_DEFAULT)
  })

  it("applies a patch: switches, whole lists, reset; entries normalized and deduplicated", () => {
    const off = patchNet(CC_NET_DEFAULT, { internet: false, allow: ["GitHub.com", "140.82.112.0/20", "github.com", "2606:50c0:8000::153"] })
    expect(off).toEqual({ ok: true, net: { ...CC_NET_DEFAULT, internet: false, allow: ["github.com", "140.82.112.0/20", "2606:50c0:8000::153"] } })
    if (!off.ok) return
    expect(patchNet(off.net, { tailnet: false, deny: ["10.0.0.0/8"] })).toEqual({ ok: true, net: { ...off.net, tailnet: false, deny: ["10.0.0.0/8"] } })
    expect(patchNet(off.net, { reset: true })).toEqual({ ok: true, net: CC_NET_DEFAULT })
    expect(readNet(JSON.stringify(off.net))).toEqual(off.net)
  })

  it.each([
    [{ internet: "yes" }, "internet"],
    [{ allow: ["github.com; curl evil"] }, "allow"],
    [{ deny: ["10.0.0.0/33"] }, "deny"],
    [{ allow: "github.com" }, "allow"],
    [{ allow: Array.from({ length: 65 }, (_, i) => `h${i}.example.com`) }, "allow"],
    [{ speed: "fast" }, "speed"],
    [null, "object"]
  ])("refuses a bad patch %j and names %s", (patch, word) => {
    const r = patchNet(CC_NET_DEFAULT, patch)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.error).toContain(word)
  })

  it("writes one atomic nftables table for the agent user that matches the settings", () => {
    const open = netScript(CC_NET_DEFAULT)
    // Replaced in one transaction, the model forward and the network tool always reachable, then the Internet.
    expect(open).toContain("delete table inet chiefcc")
    expect(open).toContain("tcp dport { 4017, 4018 } accept")
    expect(open).toMatch(/ip daddr \{[^}]*10\.0\.0\.0\/8[^}]*\} reject/)
    expect(open).toMatch(/ip6 daddr \{[^}]*fc00::\/7[^}]*\} reject/)
    expect(open).toContain(`meta skuid $uid accept`)
    expect(open.trimEnd().endsWith("echo net ok")).toBe(true)
    const closed = netScript({ ...CC_NET_DEFAULT, internet: false, dns: false, allow: ["github.com", "140.82.112.0/20"] })
    expect(closed).not.toContain(`meta skuid $uid accept`)
    expect(closed).toContain("'github.com'")
    expect(closed).toContain("'140.82.112.0/20'")
    expect(netScript({ ...CC_NET_DEFAULT, tailnet: true })).toContain("100.64.0.0/10")
    expect(netScript({ ...CC_NET_DEFAULT, tailnet: false })).not.toMatch(/ip daddr 100\.64\.0\.0\/10 accept/)
  })
})
