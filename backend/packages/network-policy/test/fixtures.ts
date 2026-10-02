import type { Directory } from "../src/index.ts"

export const LAWRENCE = "user_aaaaaaaaaaaaaaaaaaaa"
export const AUSTIN = "user_bbbbbbbbbbbbbbbbbbbb"
export const AZIZ = "user_cccccccccccccccccccc"
export const TEAM = "team_tttttttttttttttttttt"

export const directory: Directory = {
  members: [
    { user: LAWRENCE, role: "owner", handle: "lawrence" },
    { user: AUSTIN, role: "member", handle: "austin" },
    { user: AZIZ, role: "member", handle: "aziz" }
  ],
  devices: [
    { install: "inst_lmac0000000000000000", user: LAWRENCE, classes: ["mux"], wg_public_key: "L".repeat(43) + "=" },
    { install: "inst_amac0000000000000000", user: AUSTIN, wg_public_key: "A".repeat(43) + "=" },
    { install: "inst_zmac0000000000000000", user: AZIZ, wg_public_key: "Z".repeat(43) + "=" },
    { install: "inst_zold0000000000000000", user: AZIZ, revoked: true, wg_public_key: "O".repeat(43) + "=" }
  ],
  machines: [
    { id: "mach_teamvm", provider_id: "vm-team", tags: ["team-vm"], address: "10.16.0.10" },
    { id: "mach_sandbox", provider_id: "vm-sandbox", tags: ["sandbox"], classes: ["agent"], address: "10.16.0.11" },
    { id: "mach_stream", provider_id: "vm-stream", tags: ["streaming"], address: "10.16.0.12" },
    { id: "mach_azizvm", provider_id: "vm-aziz", owner_user: AZIZ, tags: [], address: "10.16.0.13" }
  ],
  nodes: { acme: [LAWRENCE, AUSTIN, AZIZ], "acme.web": [AUSTIN] }
}

/** The spec's example (spec/network-policy.md "Policy document"), with comments and a trailing comma. */
export const specPolicy = `{
  "groups": {
    "group:admins":   ["user:lawrence"],
    "group:web":      ["user:austin", "node:acme.web"],   // the team permission hierarchy
    "group:muxes":    ["class:mux"],
    "group:agents":   ["class:agent"],
  },
  "tagOwners": {
    "tag:team-vm":    ["group:admins"],
    "tag:sandbox":    ["group:admins", "group:muxes"],
    "tag:streaming":  ["group:admins"]
  },
  "hosts": { "ci-runner": "10.16.0.40" },
  "acls": [
    {"action": "accept", "src": ["group:admins"], "dst": ["*:*"]},
    {"action": "accept", "src": ["autogroup:member", "group:muxes", "group:agents"], "dst": ["tag:team-vm:22,443"]},
    {"action": "accept", "src": ["group:web", "group:muxes"], "dst": ["tag:sandbox:*"]},
    {"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"]}
  ],
  "ssh": [
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"]},
    {"action": "accept", "src": ["group:muxes"], "dst": ["tag:team-vm"], "users": ["<owner>-mux"]},
    {"action": "check",  "src": ["group:agents"], "dst": ["tag:team-vm"], "users": ["<owner>-agents"], "forceCommand": "cmux team"}
  ],
  /* built-in tests */
  "tests": [
    {"src": "user:aziz", "accept": ["tag:team-vm:22"], "deny": ["tag:sandbox:22"]},
    {"src": "class:agent", "deny": ["tag:streaming:*"]}
  ]
}`
