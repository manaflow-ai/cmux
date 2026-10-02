import { isCidrOrAddress, normalizeCidr } from "./cidr.ts"
import { parseJsonc } from "./jsonc.ts"
import type {
  AclRule,
  AgentClass,
  DestRef,
  Destination,
  Policy,
  PolicyIssue,
  PolicyTest,
  PortRange,
  Ports,
  PrincipalRef,
  Proto,
  Result,
  SshRule,
  SshUser
} from "./types.ts"

export const LIMITS = {
  documentBytes: 128 * 1024,
  rules: 500,
  testsPerPolicy: 200,
  entriesPerList: 200,
  /** Freestyle rules carry one port each, so a range expands into one rule per port. */
  portsPerRange: 64
} as const

const NAME = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/
const NODE = /^[a-z0-9-]+(\.[a-z0-9-]+)*$/
const USER_REF = /^[^\s:]{1,254}$/
const LINUX_USER = /^[a-z_][a-z0-9_-]{0,31}$/
const TEMPLATE_USER = /^(<owner>|[a-z_])[a-z0-9_<>-]{0,40}$/
const CLASSES: ReadonlyArray<AgentClass> = ["mux", "agent", "run"]
const TOP_KEYS = new Set(["groups", "tagOwners", "hosts", "acls", "ssh", "tests"])

class Issues {
  readonly list: Array<PolicyIssue> = []
  add(path: string, message: string) {
    this.list.push({ path, message })
  }
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)

const stringArray = (v: unknown, path: string, issues: Issues): ReadonlyArray<string> => {
  if (!Array.isArray(v)) {
    issues.add(path, "must be an array of strings")
    return []
  }
  if (v.length > LIMITS.entriesPerList) issues.add(path, `at most ${LIMITS.entriesPerList} entries`)
  return v.flatMap((e, i) => {
    if (typeof e !== "string" || e.length === 0) {
      issues.add(`${path}[${i}]`, "must be a non-empty string")
      return []
    }
    return [e]
  })
}

/** Parses one principal reference (a `src`, group member or tag owner). */
export const parsePrincipal = (text: string, hostNames: ReadonlySet<string>): PrincipalRef | string => {
  if (text === "*") return { kind: "any" }
  const colon = text.indexOf(":")
  if (colon > 0) {
    const prefix = text.slice(0, colon)
    const rest = text.slice(colon + 1)
    switch (prefix) {
      case "user":
        return USER_REF.test(rest) ? { kind: "user", ref: rest } : `invalid user reference ${JSON.stringify(text)}`
      case "group":
        return NAME.test(rest) ? { kind: "group", name: rest } : `invalid group name ${JSON.stringify(text)}`
      case "tag":
        return NAME.test(rest) ? { kind: "tag", name: rest } : `invalid tag name ${JSON.stringify(text)}`
      case "class":
        return (CLASSES as ReadonlyArray<string>).includes(rest) ? { kind: "class", name: rest as AgentClass } : `unknown agent class ${JSON.stringify(text)} (mux, agent, run)`
      case "node":
        return NODE.test(rest) ? { kind: "node", path: rest } : `invalid hierarchy node ${JSON.stringify(text)}`
      case "autogroup":
        if (rest === "member" || rest === "admin") return { kind: "autogroup", name: rest }
        if (rest === "self") return "autogroup:self is only valid as a destination"
        return `unknown autogroup ${JSON.stringify(text)} (member, admin; self as a destination)`
    }
  }
  if (hostNames.has(text)) return { kind: "host", name: text }
  if (isCidrOrAddress(text)) return { kind: "cidr", cidr: normalizeCidr(text) }
  return `unknown reference ${JSON.stringify(text)}`
}

const parsePorts = (text: string): Ports | string => {
  if (text === "*") return "*"
  const ranges: Array<PortRange> = []
  for (const part of text.split(",")) {
    const m = /^(\d{1,5})(?:-(\d{1,5}))?$/.exec(part)
    if (!m) return `invalid port ${JSON.stringify(part)}`
    const from = Number(m[1])
    const to = m[2] === undefined ? from : Number(m[2])
    if (from < 1 || to > 65535 || from > to) return `port out of range ${JSON.stringify(part)}`
    if (to - from + 1 > LIMITS.portsPerRange) return `port range ${part} is wider than ${LIMITS.portsPerRange} ports (Freestyle rules name single ports)`
    ranges.push({ from, to })
  }
  return mergeRanges(ranges)
}

export const mergeRanges = (ranges: ReadonlyArray<PortRange>): ReadonlyArray<PortRange> => {
  const sorted = [...ranges].sort((a, b) => a.from - b.from)
  const out: Array<PortRange> = []
  for (const r of sorted) {
    const last = out[out.length - 1]
    if (last && r.from <= last.to + 1) out[out.length - 1] = { from: last.from, to: Math.max(last.to, r.to) }
    else out.push(r)
  }
  return out
}

/** Parses `selector:ports`; IPv6 selectors are bracketed: `[fd00::1]:22`. */
export const parseDestination = (text: string, hostNames: ReadonlySet<string>): Destination | string => {
  let selector: string
  let portText: string
  if (text.startsWith("[")) {
    const close = text.indexOf("]:")
    if (close < 0) return `invalid destination ${JSON.stringify(text)} (IPv6 is written [addr]:ports)`
    selector = text.slice(1, close)
    portText = text.slice(close + 2)
  } else {
    const colon = text.lastIndexOf(":")
    if (colon <= 0) return `destination ${JSON.stringify(text)} needs ports, for example ${JSON.stringify(`${text}:*`)}`
    selector = text.slice(0, colon)
    portText = text.slice(colon + 1)
  }
  const ports = parsePorts(portText)
  if (typeof ports === "string" && ports !== "*") {
    if (typeof parsePrincipal(text, hostNames) !== "string") return `destination ${JSON.stringify(text)} needs ports, for example ${JSON.stringify(`${text}:*`)}`
    return `${ports} in ${JSON.stringify(text)}`
  }
  let target: DestRef | string
  if (selector === "autogroup:self") target = { kind: "autogroup", name: "self" }
  else target = parsePrincipal(selector, hostNames)
  if (typeof target === "string") return target
  return { target, ports, text }
}

const parseProto = (v: unknown, path: string, issues: Issues): Proto | undefined => {
  if (v === undefined) return undefined
  if (v === "tcp" || v === "udp" || v === "icmp") return v
  issues.add(path, "must be tcp, udp or icmp")
  return undefined
}

const principals = (v: unknown, path: string, hostNames: ReadonlySet<string>, issues: Issues) =>
  stringArray(v, path, issues).flatMap((s, i) => {
    const p = parsePrincipal(s, hostNames)
    if (typeof p === "string") {
      issues.add(`${path}[${i}]`, p)
      return []
    }
    return [p]
  })

const destinations = (v: unknown, path: string, hostNames: ReadonlySet<string>, issues: Issues) =>
  stringArray(v, path, issues).flatMap((s, i) => {
    const d = parseDestination(s, hostNames)
    if (typeof d === "string") {
      issues.add(`${path}[${i}]`, d)
      return []
    }
    return [d]
  })

const checkKeys = (o: Record<string, unknown>, allowed: ReadonlyArray<string>, path: string, issues: Issues) => {
  for (const k of Object.keys(o)) if (!allowed.includes(k)) issues.add(`${path}.${k}`, "unknown field")
}

/**
 * Structural parse plus reference checks that need no directory: every group,
 * tag and host named anywhere must be defined. Directory-dependent checks
 * (users, nodes, tests, admin lockout) live in validate.ts.
 */
export const parsePolicy = (input: string | unknown): Result<Policy> => {
  const issues = new Issues()
  let doc: unknown = input
  if (typeof input === "string") {
    if (new TextEncoder().encode(input).length > LIMITS.documentBytes) return { ok: false, issues: [{ path: "", message: `document larger than ${LIMITS.documentBytes} bytes` }] }
    const parsed = parseJsonc(input)
    if (!parsed.ok) return { ok: false, issues: [{ path: "", message: `not valid JSON: ${parsed.message}` }] }
    doc = parsed.value
  }
  if (!isObject(doc)) return { ok: false, issues: [{ path: "", message: "policy must be a JSON object" }] }
  for (const k of Object.keys(doc)) if (!TOP_KEYS.has(k)) issues.add(k, "unknown field")

  // hosts first: their names are valid selectors elsewhere.
  const hosts: Record<string, string> = {}
  if (doc.hosts !== undefined) {
    if (!isObject(doc.hosts)) issues.add("hosts", "must be an object")
    else
      for (const [name, value] of Object.entries(doc.hosts)) {
        if (!NAME.test(name)) issues.add(`hosts.${name}`, "host names are lowercase letters, digits and hyphens")
        else if (typeof value !== "string" || !isCidrOrAddress(value)) issues.add(`hosts.${name}`, "must be an IP address or CIDR")
        else hosts[name] = normalizeCidr(value)
      }
  }
  const hostNames = new Set(Object.keys(hosts))

  const groups: Record<string, ReadonlyArray<PrincipalRef>> = {}
  if (doc.groups !== undefined) {
    if (!isObject(doc.groups)) issues.add("groups", "must be an object")
    else
      for (const [key, members] of Object.entries(doc.groups)) {
        const path = `groups["${key}"]`
        if (!key.startsWith("group:") || !NAME.test(key.slice(6))) {
          issues.add(path, "group keys are group:<name>")
          continue
        }
        const refs = principals(members, path, hostNames, issues)
        refs.forEach((r, i) => {
          // Tailscale semantics: groups hold identities, not other groups, tags or addresses.
          if (r.kind !== "user" && r.kind !== "class" && r.kind !== "node") issues.add(`${path}[${i}]`, "groups hold user:, class: and node: entries only")
        })
        groups[key.slice(6)] = refs
      }
  }

  const tagOwners: Record<string, ReadonlyArray<PrincipalRef>> = {}
  if (doc.tagOwners !== undefined) {
    if (!isObject(doc.tagOwners)) issues.add("tagOwners", "must be an object")
    else
      for (const [key, owners] of Object.entries(doc.tagOwners)) {
        const path = `tagOwners["${key}"]`
        if (!key.startsWith("tag:") || !NAME.test(key.slice(4))) {
          issues.add(path, "tag keys are tag:<name>")
          continue
        }
        const refs = principals(owners, path, hostNames, issues)
        refs.forEach((r, i) => {
          if (r.kind !== "user" && r.kind !== "group" && r.kind !== "class" && r.kind !== "autogroup") issues.add(`${path}[${i}]`, "tag owners are users, groups, classes or autogroups")
        })
        tagOwners[key.slice(4)] = refs
      }
  }

  const acls: Array<AclRule> = []
  if (doc.acls !== undefined) {
    if (!Array.isArray(doc.acls)) issues.add("acls", "must be an array")
    else {
      if (doc.acls.length > LIMITS.rules) issues.add("acls", `at most ${LIMITS.rules} rules`)
      doc.acls.forEach((r, index) => {
        const path = `acls[${index}]`
        if (!isObject(r)) return issues.add(path, "must be an object")
        checkKeys(r, ["action", "src", "dst", "proto"], path, issues)
        if (r.action !== "accept") issues.add(`${path}.action`, 'must be "accept" (rules only add access; everything else is denied)')
        const src = principals(r.src, `${path}.src`, hostNames, issues)
        const dst = destinations(r.dst, `${path}.dst`, hostNames, issues)
        const proto = parseProto(r.proto, `${path}.proto`, issues)
        if (src.length === 0) issues.add(`${path}.src`, "needs at least one source")
        if (dst.length === 0) issues.add(`${path}.dst`, "needs at least one destination")
        acls.push({ action: "accept", src, dst, ...(proto ? { proto } : {}), index })
      })
    }
  }

  const ssh: Array<SshRule> = []
  if (doc.ssh !== undefined) {
    if (!Array.isArray(doc.ssh)) issues.add("ssh", "must be an array")
    else
      doc.ssh.forEach((r, index) => {
        const path = `ssh[${index}]`
        if (!isObject(r)) return issues.add(path, "must be an object")
        checkKeys(r, ["action", "src", "dst", "users", "forceCommand"], path, issues)
        if (r.action !== "accept" && r.action !== "check") issues.add(`${path}.action`, 'must be "accept" or "check"')
        const src = principals(r.src, `${path}.src`, hostNames, issues)
        const dst = stringArray(r.dst, `${path}.dst`, issues).flatMap((s, i): Array<SshRule["dst"][number]> => {
          if (s === "autogroup:self") return [{ kind: "autogroup", name: "self" }]
          if (s.startsWith("tag:") && NAME.test(s.slice(4))) return [{ kind: "tag", name: s.slice(4) }]
          issues.add(`${path}.dst[${i}]`, "SSH destinations are tag:<name> or autogroup:self")
          return []
        })
        const users = stringArray(r.users, `${path}.users`, issues).flatMap((s, i): Array<SshUser> => {
          if (s === "autogroup:nonroot") return [{ kind: "nonroot" }]
          if (s === "root") {
            issues.add(`${path}.users[${i}]`, "root logins are not allowed on team machines")
            return []
          }
          if (s.includes("<")) {
            if (!TEMPLATE_USER.test(s) || s.replaceAll("<owner>", "").includes("<")) {
              issues.add(`${path}.users[${i}]`, "the only template is <owner>, for example <owner>-mux")
              return []
            }
            return [{ kind: "template", template: s }]
          }
          if (!LINUX_USER.test(s)) {
            issues.add(`${path}.users[${i}]`, "invalid Linux user name")
            return []
          }
          return [{ kind: "literal", name: s }]
        })
        if (r.forceCommand !== undefined && (typeof r.forceCommand !== "string" || r.forceCommand.length === 0 || r.forceCommand.length > 512))
          issues.add(`${path}.forceCommand`, "must be a non-empty string up to 512 characters")
        if (src.length === 0) issues.add(`${path}.src`, "needs at least one source")
        if (dst.length === 0) issues.add(`${path}.dst`, "needs at least one destination")
        if (users.length === 0) issues.add(`${path}.users`, "needs at least one user")
        ssh.push({
          action: r.action === "check" ? "check" : "accept",
          src,
          dst,
          users,
          ...(typeof r.forceCommand === "string" ? { forceCommand: r.forceCommand } : {}),
          index
        })
      })
  }

  const tests: Array<PolicyTest> = []
  if (doc.tests !== undefined) {
    if (!Array.isArray(doc.tests)) issues.add("tests", "must be an array")
    else {
      if (doc.tests.length > LIMITS.testsPerPolicy) issues.add("tests", `at most ${LIMITS.testsPerPolicy} tests`)
      doc.tests.forEach((t, index) => {
        const path = `tests[${index}]`
        if (!isObject(t)) return issues.add(path, "must be an object")
        checkKeys(t, ["src", "accept", "deny", "proto"], path, issues)
        if (typeof t.src !== "string") return issues.add(`${path}.src`, "must be a string")
        const src = parsePrincipal(t.src, hostNames)
        if (typeof src === "string") return issues.add(`${path}.src`, src)
        if (src.kind === "any" || src.kind === "cidr" || src.kind === "host" || src.kind === "group" || src.kind === "autogroup")
          return issues.add(`${path}.src`, "a test source is one identity: user:, class:, tag: or node:")
        const accept = t.accept === undefined ? [] : destinations(t.accept, `${path}.accept`, hostNames, issues)
        const deny = t.deny === undefined ? [] : destinations(t.deny, `${path}.deny`, hostNames, issues)
        const proto = parseProto(t.proto, `${path}.proto`, issues)
        if (accept.length + deny.length === 0) issues.add(path, "needs accept or deny")
        tests.push({ src, accept, deny, ...(proto ? { proto } : {}), index })
      })
    }
  }

  // Every group, tag and host referenced must be defined.
  const checkRef = (r: PrincipalRef | DestRef, path: string) => {
    if (r.kind === "group" && !(r.name in groups)) issues.add(path, `unknown group group:${r.name}`)
    if (r.kind === "tag" && !(r.name in tagOwners)) issues.add(path, `unknown tag tag:${r.name} (declare it in tagOwners)`)
  }
  for (const [g, refs] of Object.entries(groups)) refs.forEach((r, i) => checkRef(r, `groups["group:${g}"][${i}]`))
  for (const [t, refs] of Object.entries(tagOwners)) refs.forEach((r, i) => checkRef(r, `tagOwners["tag:${t}"][${i}]`))
  for (const a of acls) {
    a.src.forEach((r, i) => checkRef(r, `acls[${a.index}].src[${i}]`))
    a.dst.forEach((d, i) => checkRef(d.target, `acls[${a.index}].dst[${i}]`))
  }
  for (const s of ssh) {
    s.src.forEach((r, i) => checkRef(r, `ssh[${s.index}].src[${i}]`))
    s.dst.forEach((d, i) => checkRef(d, `ssh[${s.index}].dst[${i}]`))
  }
  for (const t of tests) {
    checkRef(t.src, `tests[${t.index}].src`)
    t.accept.forEach((d, i) => checkRef(d.target, `tests[${t.index}].accept[${i}]`))
    t.deny.forEach((d, i) => checkRef(d.target, `tests[${t.index}].deny[${i}]`))
  }

  if (issues.list.length > 0) return { ok: false, issues: issues.list }
  return { ok: true, value: { groups, tagOwners, hosts, acls, ssh, tests } }
}
