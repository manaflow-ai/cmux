import { cidrContains } from "./cidr.ts"
import { classEndpoints, endpointKey, userEndpoints, usersOfNode, type CompiledNetwork, type Endpoint } from "./compile.ts"
import { describeRef, resolveUser, type TestFailure } from "./evaluate.ts"
import type { DestRef, Directory, Policy, PortRange, PrincipalRef, Proto } from "./types.ts"

/**
 * The `deny` half of the policy's tests, checked against the COMPILED rules
 * and today's directory. The symbolic evaluator reasons about identities; the
 * compiler resolves addresses and co-located identities (a host alias that
 * contains a tagged machine, a class running on a tagged machine). A deny
 * test must hold in both, or a test could pass while the enforced rules
 * admit the traffic.
 */

const machineAddress = (dir: Directory, id: string) => dir.machines.find((m) => m.id === id)?.address

const endpointsOf = (policy: Policy, dir: Directory, ref: PrincipalRef | DestRef, self?: string): Array<Endpoint> => {
  switch (ref.kind) {
    case "user": {
      const id = resolveUser(dir, ref.ref)
      return id ? userEndpoints(dir, id).map((l) => l.endpoint) : []
    }
    case "class":
      return classEndpoints(dir, ref.name).map((l) => l.endpoint)
    case "tag":
      return dir.machines.filter((m) => m.tags.includes(ref.name)).map((m) => ({ kind: "machine" as const, id: m.id }))
    case "node":
      return [...new Set(usersOfNode(dir, ref.path))].flatMap((u) => userEndpoints(dir, u).map((l) => l.endpoint))
    case "host":
    case "cidr": {
      const cidr = ref.kind === "host" ? policy.hosts[ref.name]! : ref.cidr
      return [{ kind: "cidr", cidr }, ...dir.machines.filter((m) => m.address && cidrContains(cidr, m.address)).map((m) => ({ kind: "machine" as const, id: m.id }))]
    }
    case "autogroup":
      return ref.name === "self" && self ? userEndpoints(dir, self).map((l) => l.endpoint) : []
    default:
      return []
  }
}

/** Whether a compiled endpoint (rule side) covers a concrete endpoint. */
const covers = (dir: Directory, rule: Endpoint, e: Endpoint): boolean => {
  if (rule.kind === "network") return true
  if (endpointKey(rule) === endpointKey(e)) return true
  if (rule.kind === "cidr") {
    if (e.kind === "cidr") return cidrContains(rule.cidr, e.cidr) || cidrContains(e.cidr, rule.cidr)
    if (e.kind === "machine") {
      const a = machineAddress(dir, e.id)
      return a !== undefined && cidrContains(rule.cidr, a)
    }
  }
  if (e.kind === "cidr" && rule.kind === "machine") {
    const a = machineAddress(dir, rule.id)
    return a !== undefined && cidrContains(e.cidr, a)
  }
  return false
}

const portHit = (port: number | undefined, want: ReadonlyArray<PortRange> | "*") => port === undefined || want === "*" || want.some((r) => r.from <= port && port <= r.to)

export const concreteDenyFailures = (policy: Policy, dir: Directory, compiled: CompiledNetwork): ReadonlyArray<TestFailure> => {
  const failures: Array<TestFailure> = []
  for (const t of policy.tests) {
    if (t.deny.length === 0) continue
    const proto: Proto = t.proto ?? "tcp"
    const self = t.src.kind === "user" ? resolveUser(dir, t.src.ref) : undefined
    const srcs = endpointsOf(policy, dir, t.src)
    t.deny.forEach((d, i) => {
      const dsts = endpointsOf(policy, dir, d.target, self)
      const hit = compiled.rules.find(
        (r) =>
          (r.proto === undefined || r.proto === proto) &&
          portHit(r.port, d.ports) &&
          srcs.some((s) => covers(dir, r.src, s)) &&
          dsts.some((x) => covers(dir, r.dst, x)) &&
          // A rule that would let an endpoint reach itself admits nothing.
          !(srcs.length === 1 && dsts.length === 1 && endpointKey(srcs[0]!) === endpointKey(dsts[0]!))
      )
      if (hit)
        failures.push({
          path: `tests[${t.index}].deny[${i}]`,
          message: `expected ${describeRef(t.src)} to be denied ${d.text} (${proto}); compiled rule ${endpointKey(hit.src)} -> ${endpointKey(hit.dst)}${hit.port ? `:${hit.port}` : ""} from acls ${hit.acls.join(",")} allows it`
        })
    })
  }
  return failures
}
