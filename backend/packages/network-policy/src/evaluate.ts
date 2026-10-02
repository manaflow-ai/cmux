import { cidrContains } from "./cidr.ts"
import { mergeRanges } from "./parse.ts"
import type { AclRule, AgentClass, DestRef, Destination, Directory, Policy, PortRange, Ports, PrincipalRef, Proto } from "./types.ts"

/**
 * Symbolic evaluation: does the policy accept a given identity reaching a given
 * kind of destination? Used by the `tests` block and the admin lockout guard.
 * It needs only memberships from the directory, not machines or devices, so a
 * policy can be checked before any machine exists.
 */

/** Every fact about a source or destination identity that a selector can match. */
export interface Facets {
  readonly user?: string
  readonly classes: ReadonlyArray<AgentClass>
  readonly tags: ReadonlyArray<string>
  readonly nodes: ReadonlyArray<string>
  readonly groups: ReadonlyArray<string>
  readonly member: boolean
  readonly admin: boolean
  /** Address or CIDR, for host and CIDR selectors. */
  readonly address?: string
}

export const ALL_PORTS: ReadonlyArray<PortRange> = [{ from: 1, to: 65535 }]

/** Resolves `user:<ref>` to a member id: an exact id, or a handle. */
export const resolveUser = (dir: Pick<Directory, "members">, ref: string): string | undefined => {
  const byId = dir.members.find((m) => m.user === ref)
  if (byId) return byId.user
  return dir.members.find((m) => m.handle !== undefined && m.handle === ref)?.user
}

const nodesOf = (dir: Pick<Directory, "nodes">, user: string) =>
  Object.entries(dir.nodes ?? {})
    .filter(([, users]) => users.includes(user))
    .map(([path]) => path)

/** Groups that contain an identity directly, through a node, or through a class. */
const groupsFor = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, f: { user?: string; classes: ReadonlyArray<AgentClass>; nodes: ReadonlyArray<string> }) =>
  Object.entries(policy.groups)
    .filter(([, refs]) =>
      refs.some(
        (r) =>
          (r.kind === "user" && f.user !== undefined && resolveUser(dir, r.ref) === f.user) ||
          (r.kind === "class" && f.classes.includes(r.name)) ||
          (r.kind === "node" && f.nodes.some((n) => n === r.path || n.startsWith(`${r.path}.`)))
      )
    )
    .map(([g]) => g)

export const userFacets = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, user: string, classes: ReadonlyArray<AgentClass> = []): Facets => {
  const m = dir.members.find((x) => x.user === user)
  const nodes = nodesOf(dir, user)
  return {
    user,
    classes,
    tags: [],
    nodes,
    groups: groupsFor(policy, dir, { user, classes, nodes }),
    // An agent principal acting for a user is not itself a member (spec rule 2 lists classes separately).
    member: m !== undefined && classes.length === 0,
    admin: m !== undefined && classes.length === 0 && (m.role === "owner" || m.role === "admin")
  }
}

export const classFacets = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, cls: AgentClass, owner?: string): Facets => ({
  ...(owner ? { user: owner } : {}),
  classes: [cls],
  tags: [],
  nodes: [],
  groups: groupsFor(policy, dir, { classes: [cls], nodes: [] }),
  member: false,
  admin: false
})

export const tagFacets = (tags: ReadonlyArray<string>, address?: string): Facets => ({
  classes: [],
  tags,
  nodes: [],
  groups: [],
  member: false,
  admin: false,
  ...(address ? { address } : {})
})

const addressFacets = (address: string): Facets => ({ classes: [], tags: [], nodes: [], groups: [], member: false, admin: false, address })

/** Whether a selector matches an identity. `self` is the source user for `autogroup:self`. */
export const selectorMatches = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, sel: PrincipalRef | DestRef, f: Facets, self?: string): boolean => {
  switch (sel.kind) {
    case "any":
      return true
    case "user":
      return f.classes.length === 0 && f.user !== undefined && resolveUser(dir, sel.ref) === f.user
    case "group":
      return f.groups.includes(sel.name)
    case "class":
      return f.classes.includes(sel.name)
    case "node":
      return f.classes.length === 0 && f.nodes.some((n) => n === sel.path || n.startsWith(`${sel.path}.`))
    case "tag":
      return f.tags.includes(sel.name)
    case "autogroup":
      if (sel.name === "member") return f.member
      if (sel.name === "admin") return f.admin
      // A person's own devices and untagged machines; never a tagged machine.
      return self !== undefined && f.user === self && f.tags.length === 0
    case "host": {
      const cidr = policy.hosts[sel.name]
      return cidr !== undefined && f.address !== undefined && cidrContains(cidr, f.address)
    }
    case "cidr":
      return f.address !== undefined && cidrContains(sel.cidr, f.address)
  }
}

/** Protocols a destination entry admits: the rule's proto, else TCP for numbered ports and all for `*`. */
export const protosFor = (rule: Pick<AclRule, "proto">, ports: Ports): ReadonlyArray<Proto> => (rule.proto ? [rule.proto] : ports === "*" ? ["tcp", "udp", "icmp"] : ["tcp"])

/** Port coverage the policy grants from `src` to `dst` for one protocol. */
export const coverage = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, src: Facets, dst: Facets, proto: Proto): ReadonlyArray<PortRange> => {
  const ranges: Array<PortRange> = []
  for (const rule of policy.acls) {
    if (!rule.src.some((s) => selectorMatches(policy, dir, s, src))) continue
    for (const d of rule.dst) {
      if (!protosFor(rule, d.ports).includes(proto)) continue
      if (!selectorMatches(policy, dir, d.target, dst, src.user)) continue
      ranges.push(...(d.ports === "*" ? ALL_PORTS : d.ports))
    }
  }
  return mergeRanges(ranges)
}

const covers = (have: ReadonlyArray<PortRange>, want: ReadonlyArray<PortRange>) => want.every((w) => have.some((h) => h.from <= w.from && h.to >= w.to))
const intersects = (have: ReadonlyArray<PortRange>, want: ReadonlyArray<PortRange>) => want.some((w) => have.some((h) => h.from <= w.to && h.to >= w.from))

export type IdentityResolution = { ok: true; facets: Facets } | { ok: false; message: string }

/** Facets for a test source (one identity). */
export const sourceFacets = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, ref: PrincipalRef): IdentityResolution => {
  switch (ref.kind) {
    case "user": {
      const id = resolveUser(dir, ref.ref)
      return id ? { ok: true, facets: userFacets(policy, dir, id) } : { ok: false, message: `user:${ref.ref} is not a team member` }
    }
    case "class":
      return { ok: true, facets: classFacets(policy, dir, ref.name) }
    case "tag":
      return { ok: true, facets: tagFacets([ref.name]) }
    case "node": {
      if (!dir.nodes || !Object.hasOwn(dir.nodes, ref.path)) return { ok: false, message: `node:${ref.path} is not in the permission hierarchy` }
      return { ok: true, facets: { classes: [], tags: [], nodes: [ref.path], groups: groupsFor(policy, dir, { classes: [], nodes: [ref.path] }), member: false, admin: false } }
    }
    default:
      return { ok: false, message: "a test source is one identity" }
  }
}

/** Facets for a test destination target. */
export const destinationFacets = (policy: Policy, dir: Pick<Directory, "members" | "nodes">, target: DestRef, src: Facets): IdentityResolution => {
  switch (target.kind) {
    case "tag":
      return { ok: true, facets: tagFacets([target.name]) }
    case "host":
      return { ok: true, facets: addressFacets(policy.hosts[target.name]!) }
    case "cidr":
      return { ok: true, facets: addressFacets(target.cidr) }
    case "user": {
      const id = resolveUser(dir, target.ref)
      return id ? { ok: true, facets: userFacets(policy, dir, id) } : { ok: false, message: `user:${target.ref} is not a team member` }
    }
    case "class":
      return { ok: true, facets: classFacets(policy, dir, target.name) }
    case "autogroup":
      if (target.name === "self" && src.user && src.classes.length === 0) return { ok: true, facets: userFacets(policy, dir, src.user) }
      return { ok: false, message: `autogroup:${target.name} is not a single destination in a test` }
    default:
      return { ok: false, message: "test destinations are tag:, user:, class:, host aliases, addresses or autogroup:self" }
  }
}

export interface TestFailure {
  readonly path: string
  readonly message: string
}

/** Runs the policy's own `tests` block. */
export const runTests = (policy: Policy, dir: Pick<Directory, "members" | "nodes">): ReadonlyArray<TestFailure> => {
  const failures: Array<TestFailure> = []
  for (const t of policy.tests) {
    const path = `tests[${t.index}]`
    const src = sourceFacets(policy, dir, t.src)
    if (!src.ok) {
      failures.push({ path: `${path}.src`, message: src.message })
      continue
    }
    const proto = t.proto ?? "tcp"
    const check = (d: Destination, i: number, expect: "accept" | "deny") => {
      const dst = destinationFacets(policy, dir, d.target, src.facets)
      if (!dst.ok) return failures.push({ path: `${path}.${expect}[${i}]`, message: dst.message })
      const have = coverage(policy, dir, src.facets, dst.facets, proto)
      const want = proto === "icmp" || d.ports === "*" ? ALL_PORTS : d.ports
      if (expect === "accept" && !(proto === "icmp" ? have.length > 0 : covers(have, want)))
        failures.push({ path: `${path}.accept[${i}]`, message: `expected ${describeRef(t.src)} to reach ${d.text} (${proto}); the policy does not allow it` })
      if (expect === "deny" && intersects(have, want))
        failures.push({ path: `${path}.deny[${i}]`, message: `expected ${describeRef(t.src)} to be denied ${d.text} (${proto}); the policy allows it` })
      return undefined
    }
    t.accept.forEach((d, i) => check(d, i, "accept"))
    t.deny.forEach((d, i) => check(d, i, "deny"))
  }
  return failures
}

export const describeRef = (r: PrincipalRef | DestRef): string => {
  switch (r.kind) {
    case "any":
      return "*"
    case "user":
      return `user:${r.ref}`
    case "group":
    case "class":
    case "tag":
    case "autogroup":
      return `${r.kind}:${r.name}`
    case "node":
      return `node:${r.path}`
    case "host":
      return r.name
    case "cidr":
      return r.cidr
  }
}
