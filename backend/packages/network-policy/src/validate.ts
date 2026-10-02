import { classFacets, coverage, resolveUser, runTests, selectorMatches, userFacets, type TestFailure } from "./evaluate.ts"
import { parseJsonc } from "./jsonc.ts"
import { parsePolicy } from "./parse.ts"
import type { AgentClass, DestRef, Directory, Policy, PolicyIssue, PrincipalRef } from "./types.ts"

/** The tag every team VM carries; the lockout guard keeps admins able to reach it. */
export const TEAM_VM_TAG = "team-vm"

export interface ValidatedPolicy {
  readonly policy: Policy
  /** Canonical JSON (sorted keys, no comments): what is hashed and compiled. */
  readonly canonical: string
  /** The editor text, comments kept, for round-tripping. */
  readonly source: string
  readonly tests: { readonly passed: number; readonly failed: ReadonlyArray<TestFailure> }
}

export type ValidateResult = { ok: true; value: ValidatedPolicy } | { ok: false; issues: ReadonlyArray<PolicyIssue>; tests?: ReadonlyArray<TestFailure> }

/** Sorted-key JSON, the same canonical form the ownership engine hashes. */
export const canonicalJson = (value: unknown): string =>
  JSON.stringify(value, (_k, v: unknown) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : v
  ) ?? "null"

const refsOf = (p: Policy): Array<{ ref: PrincipalRef | DestRef; path: string }> => [
  ...Object.entries(p.groups).flatMap(([g, rs]) => rs.map((ref, i) => ({ ref, path: `groups["group:${g}"][${i}]` }))),
  ...Object.entries(p.tagOwners).flatMap(([t, rs]) => rs.map((ref, i) => ({ ref, path: `tagOwners["tag:${t}"][${i}]` }))),
  ...p.acls.flatMap((a) => [
    ...a.src.map((ref, i) => ({ ref, path: `acls[${a.index}].src[${i}]` })),
    ...a.dst.map((d, i) => ({ ref: d.target, path: `acls[${a.index}].dst[${i}]` }))
  ]),
  ...p.ssh.flatMap((s) => s.src.map((ref, i) => ({ ref, path: `ssh[${s.index}].src[${i}]` })))
]

/** Users the lockout guard protects: team owners and admins, plus everyone in group:admins. */
export const protectedAdmins = (policy: Policy, dir: Directory): ReadonlyArray<string> => {
  const ids = new Set(dir.members.filter((m) => m.role === "owner" || m.role === "admin").map((m) => m.user))
  for (const r of policy.groups["admins"] ?? []) {
    if (r.kind !== "user") continue
    const id = resolveUser(dir, r.ref)
    if (id) ids.add(id)
  }
  return [...ids].sort()
}

/**
 * The built-in invariant (spec "Risks"): every protected admin can reach
 * tag:team-vm on TCP 22 and holds an SSH `accept` rule into it. A policy that
 * breaks it is refused, whatever its own tests say.
 */
export const lockoutIssues = (policy: Policy, dir: Directory): ReadonlyArray<PolicyIssue> => {
  const issues: Array<PolicyIssue> = []
  const vm = { classes: [], tags: [TEAM_VM_TAG], nodes: [], groups: [], member: false, admin: false }
  for (const admin of protectedAdmins(policy, dir)) {
    const f = userFacets(policy, dir, admin)
    const name = dir.members.find((m) => m.user === admin)?.handle ?? admin
    const tcp = coverage(policy, dir, f, vm, "tcp")
    if (!tcp.some((r) => r.from <= 22 && r.to >= 22)) issues.push({ path: "acls", message: `lockout guard: admin ${name} would lose tcp/22 to tag:${TEAM_VM_TAG}` })
    const ssh = policy.ssh.some((s) => s.action === "accept" && s.dst.some((d) => d.kind === "tag" && d.name === TEAM_VM_TAG) && s.src.some((src) => selectorMatches(policy, dir, src, f)))
    if (!ssh) issues.push({ path: "ssh", message: `lockout guard: admin ${name} would lose SSH (accept) to tag:${TEAM_VM_TAG}` })
  }
  return issues
}

/**
 * Full validation for preview and apply: structure, references against the
 * directory, tags still in use, the policy's own tests, and the lockout guard.
 */
export const validatePolicy = (source: string, dir: Directory): ValidateResult => {
  const parsed = parsePolicy(source)
  if (!parsed.ok) return { ok: false, issues: parsed.issues }
  const policy = parsed.value
  const issues: Array<PolicyIssue> = []

  for (const { ref, path } of refsOf(policy)) {
    if (ref.kind === "user" && !resolveUser(dir, ref.ref)) issues.push({ path, message: `user:${ref.ref} is not a team member` })
    if (ref.kind === "node" && !(dir.nodes && ref.path in dir.nodes)) issues.push({ path, message: `node:${ref.path} is not in the permission hierarchy` })
  }
  const handles = new Map<string, number>()
  for (const m of dir.members) if (m.handle) handles.set(m.handle, (handles.get(m.handle) ?? 0) + 1)
  for (const [h, n] of handles) if (n > 1) issues.push({ path: "", message: `handle ${h} is shared by ${n} members; refer to them by user id` })

  for (const m of dir.machines)
    for (const t of m.tags) if (!(t in policy.tagOwners)) issues.push({ path: "tagOwners", message: `tag:${t} is still assigned to machine ${m.id}; untag it before removing the tag` })

  const failed = runTests(policy, dir)
  issues.push(...lockoutIssues(policy, dir))
  if (issues.length > 0 || failed.length > 0) return { ok: false, issues: [...issues, ...failed.map((f) => ({ path: f.path, message: `test failed: ${f.message}` }))], tests: failed }

  const raw = parseJsonc(source)
  return {
    ok: true,
    value: { policy, canonical: canonicalJson(raw.ok ? raw.value : {}), source, tests: { passed: policy.tests.length, failed: [] } }
  }
}

/** Whether `actor` (a user, or an agent class acting for one) may assign `tag` (network.machine.tag). */
export const mayAssignTag = (policy: Policy, dir: Directory, actor: { readonly user: string; readonly cls?: AgentClass }, tag: string): boolean => {
  const owners = policy.tagOwners[tag]
  if (!owners) return false
  const f = actor.cls ? classFacets(policy, dir, actor.cls, actor.user) : userFacets(policy, dir, actor.user)
  return owners.some((o) => selectorMatches(policy, dir, o, f))
}
