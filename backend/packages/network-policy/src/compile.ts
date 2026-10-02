import { cidrContains } from "./cidr.ts"
import { protosFor, resolveUser } from "./evaluate.ts"
import type { AgentClass, DestRef, Directory, DirectoryMachine, Policy, PrincipalRef, Proto } from "./types.ts"

/**
 * Compiles a policy against the directory into concrete allow rules between
 * network endpoints, plus the SSH projection for team machines. The output is
 * provider-neutral; freestyle-plan.ts binds endpoints to Freestyle ids.
 */

export type Endpoint =
  | { readonly kind: "device"; readonly install: string }
  | { readonly kind: "machine"; readonly id: string }
  | { readonly kind: "cidr"; readonly cidr: string }
  /** Everything on the team network (Freestyle `vpcId`, which includes attached tunnels). */
  | { readonly kind: "network" }

export interface CompiledRule {
  readonly src: Endpoint
  readonly dst: Endpoint
  readonly proto?: Proto
  readonly port?: number
  /** ACL indices that produced this rule, for previews. */
  readonly acls: ReadonlyArray<number>
}

export interface CompiledSshGrant {
  readonly machine: string
  /** `user_…`, or `class:mux@user_…` for an agent class acting for a user. */
  readonly principal: string
  readonly linuxUsers: ReadonlyArray<string>
  readonly action: "accept" | "check"
  readonly forceCommand?: string
  readonly ssh: ReadonlyArray<number>
}

export interface CompiledNetwork {
  readonly rules: ReadonlyArray<CompiledRule>
  readonly ssh: ReadonlyArray<CompiledSshGrant>
  /** Devices that should hold a tunnel into the team network (every active device of a member). */
  readonly devices: ReadonlyArray<string>
  readonly notes: ReadonlyArray<string>
}

interface Located {
  readonly endpoint: Endpoint
  /** The user whose device or personal machine this is, for autogroup:self. */
  readonly owner?: string
}

const activeDevices = (dir: Directory) => {
  const members = new Set(dir.members.map((m) => m.user))
  return dir.devices.filter((d) => !d.revoked && members.has(d.user))
}

const personalMachines = (dir: Directory, user: string) => dir.machines.filter((m) => m.tags.length === 0 && m.owner_user === user)

/** A user's endpoints: their devices and their untagged personal machines (tagged machines belong to their tags). */
const userEndpoints = (dir: Directory, user: string): Array<Located> => [
  ...activeDevices(dir)
    .filter((d) => d.user === user)
    .map((d) => ({ endpoint: { kind: "device" as const, install: d.install }, owner: user })),
  ...personalMachines(dir, user).map((m) => ({ endpoint: { kind: "machine" as const, id: m.id }, owner: user }))
]

const classEndpoints = (dir: Directory, cls: AgentClass): Array<Located> => [
  ...activeDevices(dir)
    .filter((d) => d.classes?.includes(cls))
    .map((d) => ({ endpoint: { kind: "device" as const, install: d.install }, owner: d.user })),
  ...dir.machines
    .filter((m) => m.classes?.includes(cls))
    .map((m) => ({ endpoint: { kind: "machine" as const, id: m.id }, ...(m.owner_user && m.tags.length === 0 ? { owner: m.owner_user } : {}) }))
]

const usersOfNode = (dir: Directory, path: string) =>
  Object.entries(dir.nodes ?? {})
    .filter(([p]) => p === path || p.startsWith(`${path}.`))
    .flatMap(([, users]) => users)

const machineMatchesCidr = (m: DirectoryMachine, cidr: string) => m.address !== undefined && cidrContains(cidr, m.address)

/** Every endpoint a selector stands for. */
const expand = (policy: Policy, dir: Directory, sel: PrincipalRef | DestRef, notes: Set<string>): Array<Located> => {
  switch (sel.kind) {
    case "any":
      return [{ endpoint: { kind: "network" } }]
    case "user": {
      const id = resolveUser(dir, sel.ref)
      if (!id) {
        notes.add(`user:${sel.ref} is not a team member; ignored`)
        return []
      }
      return userEndpoints(dir, id)
    }
    case "group":
      return (policy.groups[sel.name] ?? []).flatMap((r) => expand(policy, dir, r, notes))
    case "class":
      return classEndpoints(dir, sel.name)
    case "node":
      return [...new Set(usersOfNode(dir, sel.path))].flatMap((u) => userEndpoints(dir, u))
    case "tag":
      return dir.machines.filter((m) => m.tags.includes(sel.name)).map((m) => ({ endpoint: { kind: "machine" as const, id: m.id } }))
    case "autogroup":
      if (sel.name === "member") return dir.members.flatMap((m) => userEndpoints(dir, m.user))
      if (sel.name === "admin") return dir.members.filter((m) => m.role !== "member").flatMap((m) => userEndpoints(dir, m.user))
      return [] // self is expanded per source
    case "host":
    case "cidr": {
      const cidr = sel.kind === "host" ? policy.hosts[sel.name]! : sel.cidr
      // A CIDR that names known machines compiles to those machines (identity, robust to readdressing); otherwise to the range.
      const machines = dir.machines.filter((m) => machineMatchesCidr(m, cidr))
      return machines.length > 0 ? machines.map((m) => ({ endpoint: { kind: "machine" as const, id: m.id } })) : [{ endpoint: { kind: "cidr" as const, cidr } }]
    }
  }
}

export const endpointKey = (e: Endpoint): string => {
  switch (e.kind) {
    case "device":
      return `device:${e.install}`
    case "machine":
      return `machine:${e.id}`
    case "cidr":
      return `cidr:${e.cidr}`
    case "network":
      return "network"
  }
}

export const ruleKey = (r: Pick<CompiledRule, "src" | "dst" | "proto" | "port">): string => `${endpointKey(r.src)}>${endpointKey(r.dst)}|${r.proto ?? "*"}|${r.port ?? "*"}`

export const compileNetwork = (policy: Policy, dir: Directory): CompiledNetwork => {
  const notes = new Set<string>()
  const rules = new Map<string, { rule: Omit<CompiledRule, "acls">; acls: Set<number> }>()
  const add = (src: Endpoint, dst: Endpoint, proto: Proto | undefined, port: number | undefined, acl: number) => {
    if (endpointKey(src) === endpointKey(dst) && src.kind !== "network") return
    if (src.kind === "cidr" && dst.kind === "cidr") return notes.add(`acls[${acl}]: a rule between two address ranges admits nothing on the team network; ignored`)
    const rule = { src, dst, ...(proto ? { proto } : {}), ...(port !== undefined ? { port } : {}) }
    const key = ruleKey(rule)
    const entry = rules.get(key) ?? { rule, acls: new Set<number>() }
    entry.acls.add(acl)
    rules.set(key, entry)
  }

  for (const acl of policy.acls) {
    const sources = acl.src.flatMap((s) => expand(policy, dir, s, notes))
    for (const d of acl.dst) {
      const protos = protosFor(acl, d.ports)
      for (const src of sources) {
        const targets = d.target.kind === "autogroup" && d.target.name === "self" ? (src.owner ? userEndpoints(dir, src.owner) : []) : expand(policy, dir, d.target, notes)
        for (const dst of targets) {
          if (d.ports === "*") {
            // Every port: one rule with no port; with an explicit proto, one rule naming it.
            add(src.endpoint, dst.endpoint, acl.proto, undefined, acl.index)
          } else {
            for (const proto of protos) for (const range of d.ports) for (let port = range.from; port <= range.to; port++) add(src.endpoint, dst.endpoint, proto, proto === "icmp" ? undefined : port, acl.index)
          }
        }
      }
    }
  }

  const ssh = compileSsh(policy, dir, notes)
  const out = [...rules.values()].map(({ rule, acls }) => ({ ...rule, acls: [...acls].sort((a, b) => a - b) }))
  out.sort((a, b) => (ruleKey(a) < ruleKey(b) ? -1 : 1))
  return { rules: out, ssh, devices: activeDevices(dir).map((d) => d.install).sort(), notes: [...notes].sort() }
}

const CLASS_LINUX_SUFFIX: Record<AgentClass, string> = { mux: "-mux", agent: "-agents", run: "-runs" }

const compileSsh = (policy: Policy, dir: Directory, notes: Set<string>): Array<CompiledSshGrant> => {
  const grants = new Map<string, { machine: string; principal: string; users: Set<string>; action: "accept" | "check"; forceCommand?: string; ssh: Set<number> }>()
  const handleOf = (user: string) => dir.members.find((m) => m.user === user)?.handle

  for (const rule of policy.ssh) {
    // Principals: users, or (class, owner) pairs. A class rule applies to that class for every member.
    const principals: Array<{ user: string; cls?: AgentClass }> = []
    const addRef = (r: PrincipalRef): void => {
      switch (r.kind) {
        case "user": {
          const id = resolveUser(dir, r.ref)
          if (id) principals.push({ user: id })
          return
        }
        case "group":
          return (policy.groups[r.name] ?? []).forEach(addRef)
        case "class":
          return dir.members.forEach((m) => principals.push({ user: m.user, cls: r.name }))
        case "node":
          return [...new Set(usersOfNode(dir, r.path))].forEach((u) => principals.push({ user: u }))
        case "autogroup":
          return dir.members.filter((m) => r.name === "member" || m.role !== "member").forEach((m) => principals.push({ user: m.user }))
        case "any":
          return dir.members.forEach((m) => principals.push({ user: m.user }))
        default:
          notes.add(`ssh[${rule.index}]: ${r.kind} sources do not log in; ignored`)
      }
    }
    rule.src.forEach(addRef)

    for (const p of principals) {
      const handle = handleOf(p.user)
      if (!handle) {
        notes.add(`ssh[${rule.index}]: member ${p.user} has no handle (Linux user); skipped`)
        continue
      }
      const linuxUsers = rule.users.map((u) => (u.kind === "literal" ? u.name : u.kind === "nonroot" ? handle + (p.cls ? CLASS_LINUX_SUFFIX[p.cls] : "") : u.template.replaceAll("<owner>", handle)))
      const machines = rule.dst.flatMap((d) => (d.kind === "tag" ? dir.machines.filter((m) => m.tags.includes(d.name)) : personalMachines(dir, p.user)))
      for (const m of machines) {
        const principal = p.cls ? `class:${p.cls}@${p.user}` : p.user
        const key = `${m.id}|${principal}|${rule.action}|${rule.forceCommand ?? ""}`
        const g = grants.get(key) ?? { machine: m.id, principal, users: new Set<string>(), action: rule.action, ...(rule.forceCommand ? { forceCommand: rule.forceCommand } : {}), ssh: new Set<number>() }
        linuxUsers.forEach((u) => g.users.add(u))
        g.ssh.add(rule.index)
        grants.set(key, g)
      }
    }
  }
  return [...grants.values()]
    .map((g) => ({ machine: g.machine, principal: g.principal, linuxUsers: [...g.users].sort(), action: g.action, ...(g.forceCommand ? { forceCommand: g.forceCommand } : {}), ssh: [...g.ssh].sort((a, b) => a - b) }))
    .sort((a, b) => (`${a.machine}|${a.principal}|${a.action}` < `${b.machine}|${b.principal}|${b.action}` ? -1 : 1))
}
