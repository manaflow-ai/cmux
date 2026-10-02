import { compileNetwork, ruleKey, type CompiledNetwork, type CompiledRule, type CompiledSshGrant, type Endpoint } from "./compile.ts"
import type { TestFailure } from "./evaluate.ts"
import { parsePolicy } from "./parse.ts"
import type { Directory, PolicyIssue } from "./types.ts"
import { validatePolicy } from "./validate.ts"

/**
 * `network.policy.preview`: validate, run tests, compile, and diff the compiled
 * rules per enforcement point against the current version. Changes nothing.
 */

export interface RuleChange {
  readonly key: string
  readonly acls: ReadonlyArray<number>
}

export interface SshChange {
  readonly machine: string
  readonly principal: string
  readonly action: "accept" | "check"
  readonly linuxUsers: ReadonlyArray<string>
}

export interface PolicyDiff {
  readonly firewall: { readonly added: ReadonlyArray<RuleChange>; readonly removed: ReadonlyArray<RuleChange>; readonly unchanged: number }
  readonly ssh: { readonly added: ReadonlyArray<SshChange>; readonly removed: ReadonlyArray<SshChange> }
  readonly devices: { readonly added: ReadonlyArray<string>; readonly removed: ReadonlyArray<string> }
  /** Users, installs and machines whose reachability changes. */
  readonly affected: { readonly users: ReadonlyArray<string>; readonly devices: ReadonlyArray<string>; readonly machines: ReadonlyArray<string> }
}

export type PreviewResult =
  | { readonly ok: true; readonly canonical: string; readonly tests: { readonly passed: number }; readonly compiled: { readonly rules: number; readonly ssh: number }; readonly diff: PolicyDiff; readonly notes: ReadonlyArray<string> }
  | { readonly ok: false; readonly issues: ReadonlyArray<PolicyIssue>; readonly tests?: ReadonlyArray<TestFailure> }

const EMPTY: CompiledNetwork = { rules: [], ssh: [], devices: [], notes: [] }

const sshKey = (g: CompiledSshGrant) => `${g.machine}|${g.principal}|${g.action}|${g.forceCommand ?? ""}|${g.linuxUsers.join(",")}`

export const diffCompiled = (before: CompiledNetwork, after: CompiledNetwork, dir: Directory): PolicyDiff => {
  const b = new Map(before.rules.map((r) => [ruleKey(r), r]))
  const a = new Map(after.rules.map((r) => [ruleKey(r), r]))
  const added = [...a].filter(([k]) => !b.has(k)).map(([key, r]) => ({ key, acls: r.acls }))
  const removed = [...b].filter(([k]) => !a.has(k)).map(([key, r]) => ({ key, acls: r.acls }))
  const bs = new Map(before.ssh.map((g) => [sshKey(g), g]))
  const as = new Map(after.ssh.map((g) => [sshKey(g), g]))
  const toChange = (g: CompiledSshGrant): SshChange => ({ machine: g.machine, principal: g.principal, action: g.action, linuxUsers: g.linuxUsers })
  const sshAdded = [...as].filter(([k]) => !bs.has(k)).map(([, g]) => toChange(g))
  const sshRemoved = [...bs].filter(([k]) => !as.has(k)).map(([, g]) => toChange(g))

  const users = new Set<string>()
  const devices = new Set<string>()
  const machines = new Set<string>()
  const touch = (e: Endpoint) => {
    if (e.kind === "device") {
      devices.add(e.install)
      const d = dir.devices.find((x) => x.install === e.install)
      if (d) users.add(d.user)
    } else if (e.kind === "machine") machines.add(e.id)
  }
  const changed: Array<CompiledRule> = [...added.map((c) => a.get(c.key)!), ...removed.map((c) => b.get(c.key)!)]
  for (const r of changed) {
    touch(r.src)
    touch(r.dst)
  }
  for (const g of [...sshAdded, ...sshRemoved]) {
    machines.add(g.machine)
    users.add(g.principal.includes("@") ? g.principal.split("@")[1]! : g.principal)
  }
  const beforeDevices = new Set(before.devices)
  const afterDevices = new Set(after.devices)
  return {
    firewall: { added, removed, unchanged: after.rules.length - added.length },
    ssh: { added: sshAdded, removed: sshRemoved },
    devices: { added: [...afterDevices].filter((d) => !beforeDevices.has(d)), removed: [...beforeDevices].filter((d) => !afterDevices.has(d)) },
    affected: { users: [...users].sort(), devices: [...devices].sort(), machines: [...machines].sort() }
  }
}

/** Compiles the current version, or nothing when there is none or it no longer parses. */
export const compileSource = (source: string | null, dir: Directory): CompiledNetwork => {
  if (source === null) return EMPTY
  const p = parsePolicy(source)
  return p.ok ? compileNetwork(p.value, dir) : EMPTY
}

export const previewPolicy = (currentSource: string | null, nextSource: string, dir: Directory): PreviewResult => {
  const v = validatePolicy(nextSource, dir)
  if (!v.ok) return v
  const after = compileNetwork(v.value.policy, dir)
  const before = compileSource(currentSource, dir)
  return {
    ok: true,
    canonical: v.value.canonical,
    tests: { passed: v.value.tests.passed },
    compiled: { rules: after.rules.length, ssh: after.ssh.length },
    diff: diffCompiled(before, after, dir),
    notes: after.notes
  }
}
