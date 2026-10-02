import { describe, expect, it } from "vitest"
import {
  cidrContains,
  compileNetwork,
  coverage,
  mayAssignTag,
  normalizeCidr,
  parsePolicy,
  previewPolicy,
  ruleKey,
  stripJsonc,
  tagFacets,
  userFacets,
  validatePolicy,
  type Directory
} from "../src/index.ts"
import { AUSTIN, AZIZ, LAWRENCE, directory, specPolicy } from "./fixtures.ts"

const policyOf = (src: string) => {
  const p = parsePolicy(src)
  if (!p.ok) throw new Error(JSON.stringify(p.issues))
  return p.value
}

describe("jsonc and cidr", () => {
  it("strips comments and trailing commas but keeps strings", () => {
    expect(JSON.parse(stripJsonc(`{"a": "x // not a comment", /* c */ "b": [1,2,], // tail\n}`))).toEqual({ a: "x // not a comment", b: [1, 2] })
  })
  it("normalizes and contains", () => {
    expect(normalizeCidr("10.16.0.7")).toBe("10.16.0.7/32")
    expect(normalizeCidr("10.16.0.7/24")).toBe("10.16.0.0/24")
    expect(normalizeCidr("FD00:0:0::1/64")).toBe("fd00::/64")
    expect(cidrContains("10.16.0.0/16", "10.16.3.4")).toBe(true)
    expect(cidrContains("10.16.0.0/16", "10.17.0.1")).toBe(false)
    expect(cidrContains("fd00::/8", "fd12::1")).toBe(true)
    expect(cidrContains("10.0.0.0/8", "fd00::1")).toBe(false)
  })
})

describe("parse", () => {
  it("parses the spec example", () => {
    const p = policyOf(specPolicy)
    expect(Object.keys(p.groups)).toEqual(["admins", "web", "muxes", "agents"])
    expect(p.acls).toHaveLength(4)
    expect(p.acls[1]!.dst[0]!.ports).toEqual([
      { from: 22, to: 22 },
      { from: 443, to: 443 }
    ])
    expect(p.ssh[2]).toMatchObject({ action: "check", forceCommand: "cmux team", users: [{ kind: "template", template: "<owner>-agents" }] })
  })

  it("rejects unknown groups, tags, fields, deny actions and root", () => {
    const r = parsePolicy({
      tagOwners: { "tag:a": ["group:nope"] },
      acls: [
        { action: "deny", src: ["group:ghost"], dst: ["tag:b:22"] },
        { action: "accept", src: ["*"], dst: ["tag:a"], extra: 1 }
      ],
      ssh: [{ action: "accept", src: ["*"], dst: ["tag:a"], users: ["root"] }],
      bogus: true
    })
    expect(r.ok).toBe(false)
    if (r.ok) return
    const messages = r.issues.map((i) => `${i.path}: ${i.message}`)
    expect(messages).toEqual(
      expect.arrayContaining([
        "bogus: unknown field",
        'acls[0].action: must be "accept" (rules only add access; everything else is denied)',
        "acls[0].src[0]: unknown group group:ghost",
        "acls[0].dst[0]: unknown tag tag:b (declare it in tagOwners)",
        'acls[1].dst[0]: destination "tag:a" needs ports, for example "tag:a:*"',
        "acls[1].extra: unknown field",
        "ssh[0].users[0]: root logins are not allowed on team machines",
        'tagOwners["tag:a"][0]: unknown group group:nope'
      ])
    )
  })

  it("parses IPv6 destinations, ranges and refuses wide ranges", () => {
    const ok = policyOf(`{"tagOwners":{"tag:x":["autogroup:admin"]},"acls":[{"action":"accept","src":["*"],"dst":["[fd00::1]:22","tag:x:8000-8003,22"]}]}`)
    expect(ok.acls[0]!.dst[0]!.target).toEqual({ kind: "cidr", cidr: "fd00::1/128" })
    expect(ok.acls[0]!.dst[1]!.ports).toEqual([
      { from: 22, to: 22 },
      { from: 8000, to: 8003 }
    ])
    const wide = parsePolicy(`{"tagOwners":{"tag:x":["autogroup:admin"]},"acls":[{"action":"accept","src":["*"],"dst":["tag:x:1000-2000"]}]}`)
    expect(wide.ok).toBe(false)
  })
})

describe("evaluate and validate", () => {
  it("runs the spec's own tests and passes the lockout guard", () => {
    const v = validatePolicy(specPolicy, directory)
    expect(v.ok ? v.value.tests.passed : v.issues).toBe(2)
  })

  it("is default deny", () => {
    const p = policyOf(`{"tagOwners":{"tag:team-vm":["autogroup:admin"]}}`)
    expect(coverage(p, directory, userFacets(p, directory, AZIZ), tagFacets(["team-vm"]), "tcp")).toEqual([])
  })

  it("autogroup:self reaches only the caller's own untagged machines", () => {
    const p = policyOf(specPolicy)
    const aziz = userFacets(p, directory, AZIZ)
    expect(coverage(p, directory, aziz, userFacets(p, directory, AZIZ), "tcp")).toEqual([{ from: 1, to: 65535 }])
    expect(coverage(p, directory, aziz, userFacets(p, directory, AUSTIN), "tcp")).toEqual([])
  })

  it("fails a policy whose tests fail", () => {
    const bad = specPolicy.replace(`"deny": ["tag:sandbox:22"]`, `"deny": ["tag:team-vm:443"]`)
    const v = validatePolicy(bad, directory)
    expect(v.ok).toBe(false)
    if (!v.ok) expect(v.issues.map((i) => i.message)).toContain("test failed: expected user:aziz to be denied tag:team-vm:443 (tcp); the policy allows it")
  })

  it("refuses a policy that locks the owner out of the team VM", () => {
    const locked = `{
      "groups": {"group:admins": ["user:lawrence"]},
      "tagOwners": {"tag:team-vm": ["group:admins"], "tag:sandbox": ["group:admins"], "tag:streaming": ["group:admins"]},
      "acls": [{"action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm:443"]}],
      "ssh": [{"action": "check", "src": ["autogroup:member"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"]}]
    }`
    const v = validatePolicy(locked, directory)
    expect(v.ok).toBe(false)
    if (!v.ok)
      expect(v.issues.map((i) => i.message)).toEqual(
        expect.arrayContaining(["lockout guard: admin lawrence would lose tcp/22 to tag:team-vm", "lockout guard: admin lawrence would lose SSH (accept) to tag:team-vm"])
      )
  })

  it("rejects unknown users", () => {
    const v = validatePolicy(specPolicy.replace(`"user:austin", "node:acme.web"`, `"user:mallory"`), directory)
    expect(v.ok ? [] : v.issues.map((i) => i.message)).toContain("user:mallory is not a team member")
  })

  it("rejects removing a tag that is still on a machine", () => {
    const p = specPolicy.replace(`"tag:streaming":  ["group:admins"]`, `"tag:other": ["group:admins"]`).replace(`,\n    {"src": "class:agent", "deny": ["tag:streaming:*"]}`, "")
    const v = validatePolicy(p, directory)
    expect(v.ok ? [] : v.issues.map((i) => i.message)).toContain("tag:streaming is still assigned to machine mach_stream; untag it before removing the tag")
  })

  it("checks tag ownership", () => {
    const p = policyOf(specPolicy)
    expect(mayAssignTag(p, directory, { user: LAWRENCE }, "team-vm")).toBe(true)
    expect(mayAssignTag(p, directory, { user: AZIZ }, "team-vm")).toBe(false)
    expect(mayAssignTag(p, directory, { user: AZIZ, cls: "mux" }, "sandbox")).toBe(true)
  })
})

describe("compile", () => {
  const compiled = compileNetwork(policyOf(specPolicy), directory)
  const keys = new Set(compiled.rules.map(ruleKey))

  it("compiles members' devices to the team VM on 22 and 443 only", () => {
    expect(keys.has("device:inst_zmac0000000000000000>machine:mach_teamvm|tcp|22")).toBe(true)
    expect(keys.has("device:inst_zmac0000000000000000>machine:mach_teamvm|tcp|443")).toBe(true)
    expect(keys.has("device:inst_zmac0000000000000000>machine:mach_sandbox|tcp|22")).toBe(false)
  })

  it("never compiles a revoked device", () => {
    expect([...keys].some((k) => k.includes("inst_zold"))).toBe(false)
    expect(compiled.devices).not.toContain("inst_zold0000000000000000")
  })

  it("compiles admins to the whole network and self to own machines", () => {
    expect(keys.has("device:inst_lmac0000000000000000>network|*|*")).toBe(true)
    expect(keys.has("device:inst_zmac0000000000000000>machine:mach_azizvm|*|*")).toBe(true)
    expect(keys.has("device:inst_amac0000000000000000>machine:mach_azizvm|*|*")).toBe(false)
  })

  it("compiles agent machines (class:agent) to the team VM", () => {
    expect(keys.has("machine:mach_sandbox>machine:mach_teamvm|tcp|22")).toBe(true)
    expect([...keys].some((k) => k.startsWith("machine:mach_sandbox>machine:mach_stream"))).toBe(false)
  })

  it("compiles SSH principals to Linux users", () => {
    expect(compiled.ssh).toEqual(
      expect.arrayContaining([
        { machine: "mach_teamvm", principal: AZIZ, linuxUsers: ["aziz"], action: "accept", ssh: [0] },
        { machine: "mach_teamvm", principal: `class:mux@${LAWRENCE}`, linuxUsers: ["lawrence-mux"], action: "accept", ssh: [1] },
        { machine: "mach_teamvm", principal: `class:agent@${AUSTIN}`, linuxUsers: ["austin-agents"], action: "check", forceCommand: "cmux team", ssh: [2] }
      ])
    )
  })

  it("is deterministic", () => {
    expect(compileNetwork(policyOf(specPolicy), directory)).toEqual(compiled)
  })
})

describe("preview", () => {
  it("diffs against the current version and lists affected principals", () => {
    const next = specPolicy.replace(`"dst": ["tag:team-vm:22,443"]`, `"dst": ["tag:team-vm:22"]`)
    const r = previewPolicy(specPolicy, next, directory)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.diff.firewall.added).toEqual([])
    expect(r.diff.firewall.removed.map((c) => c.key)).toContain("device:inst_zmac0000000000000000>machine:mach_teamvm|tcp|443")
    // Lawrence keeps 443 through his admin rule (device -> whole network); the redundant per-VM rule still goes.
    expect(r.diff.firewall.removed.map((c) => c.key)).toContain("device:inst_lmac0000000000000000>machine:mach_teamvm|tcp|443")
    expect(r.diff.affected.users).toEqual(expect.arrayContaining([AUSTIN, AZIZ]))
    expect(r.diff.affected.machines).toContain("mach_teamvm")
  })

  it("previews a first policy against nothing", () => {
    const r = previewPolicy(null, specPolicy, directory)
    expect(r.ok && r.diff.firewall.removed.length === 0 && r.diff.devices.added.length === 3).toBe(true)
  })

  it("previews with an empty directory", () => {
    const empty: Directory = { members: [{ user: LAWRENCE, role: "owner", handle: "lawrence" }], devices: [], machines: [] }
    const p = specPolicy.replace(`"user:austin", "node:acme.web"`, `"user:lawrence"`).replace(`"user:aziz"`, `"user:lawrence"`).replace(`"deny": ["tag:sandbox:22"]`, `"deny": []`)
    const r = previewPolicy(null, p, empty)
    expect(r.ok ? r.compiled.rules : r.issues).toBe(0)
  })
})

describe("review regressions", () => {
  const dir: Directory = {
    members: [
      { user: LAWRENCE, role: "owner", handle: "lawrence" },
      { user: AUSTIN, role: "member", handle: "austin" }
    ],
    devices: [{ install: "inst_austin00000000000000", user: AUSTIN, wg_public_key: `${"A".repeat(43)}=` }],
    machines: [
      { id: "mach_vm", provider_id: "vm-1", tags: ["team-vm"] },
      { id: "mach_prod", provider_id: "vm-p", tags: ["prod"], address: "10.0.0.9" },
      { id: "mach_agent", provider_id: "vm-a", tags: [], owner_user: AUSTIN, classes: ["agent"] }
    ]
  }
  const base = (acls: string, tests: string) => `{
    "groups": {"group:admins": ["user:lawrence"]},
    "tagOwners": {"tag:team-vm": ["group:admins"], "tag:prod": ["group:admins"]},
    "hosts": {"db": "10.0.0.9"},
    "acls": [{"action": "accept", "src": ["group:admins"], "dst": ["*:*"]}${acls}],
    "ssh": [{"action": "accept", "src": ["group:admins"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"]}],
    "tests": [${tests}]
  }`

  it("an agent VM does not inherit its owner's access", () => {
    const v = validatePolicy(base(`, {"action": "accept", "src": ["user:austin"], "dst": ["tag:prod:22"]}`, `{"src": "class:agent", "deny": ["tag:prod:22"]}`), dir)
    expect(v.ok ? "ok" : v.issues).toBe("ok")
    if (v.ok) expect(compileNetwork(v.value.policy, dir).rules.map(ruleKey).some((k) => k.startsWith("machine:mach_agent"))).toBe(false)
  })

  it("a host alias that contains a tagged machine cannot slip past a tag deny test", () => {
    const v = validatePolicy(base(`, {"action": "accept", "src": ["user:austin"], "dst": ["db:5432"]}`, `{"src": "user:austin", "deny": ["tag:prod:5432"]}`), dir)
    expect(v.ok).toBe(false)
  })

  it("prototype names are unknown groups and tags", () => {
    expect(parsePolicy(`{"acls":[{"action":"accept","src":["group:constructor"],"dst":["tag:constructor:22"]}]}`).ok).toBe(false)
    const p = policyOf(base("", ""))
    expect(mayAssignTag(p, dir, { user: LAWRENCE }, "constructor")).toBe(false)
  })

  it("caps ports per destination after merging ranges, and requires brackets for IPv6", () => {
    const ranges = Array.from({ length: 4 }, (_, i) => `${i * 64 + 1}-${i * 64 + 64}`).join(",")
    expect(parsePolicy(base(`, {"action": "accept", "src": ["*"], "dst": ["tag:prod:${ranges}"]}`, "")).ok).toBe(false)
    expect(parsePolicy(base(`, {"action": "accept", "src": ["*"], "dst": ["2001:db8::1:443"]}`, "")).ok).toBe(false)
  })

  it("an SSH accept with a forceCommand does not satisfy the lockout guard", () => {
    const v = validatePolicy(base("", "").replace(`"users": ["autogroup:nonroot"]}`, `"users": ["autogroup:nonroot"], "forceCommand": "/bin/false"}`), dir)
    expect(v.ok ? [] : v.issues.map((i) => i.message)).toContain("lockout guard: admin lawrence would lose SSH (accept) to tag:team-vm")
  })
})
