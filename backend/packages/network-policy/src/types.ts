/**
 * The team network policy (spec/network-policy.md): a Tailscale-ACL-like
 * document owned by TeamDO. These are the validated, normalized shapes; the
 * parser turns the JSONC text into them and rejects anything else.
 */

export type Proto = "tcp" | "udp" | "icmp"

/** An inclusive port range; a single port is `{from: p, to: p}`. */
export interface PortRange {
  readonly from: number
  readonly to: number
}

/** `*` (every port, every protocol unless `proto` narrows it) or a set of ranges. */
export type Ports = "*" | ReadonlyArray<PortRange>

/**
 * A source or principal reference after parsing. Users are kept as written
 * (`user:<id or handle>`) and resolved against the directory.
 */
export type PrincipalRef =
  | { readonly kind: "user"; readonly ref: string }
  | { readonly kind: "group"; readonly name: string }
  | { readonly kind: "class"; readonly name: AgentClass }
  | { readonly kind: "node"; readonly path: string }
  | { readonly kind: "tag"; readonly name: string }
  | { readonly kind: "autogroup"; readonly name: "member" | "admin" }
  | { readonly kind: "host"; readonly name: string }
  | { readonly kind: "cidr"; readonly cidr: string }
  | { readonly kind: "any" }

/** A destination selector (the part before `:ports`). */
export type DestRef = Exclude<PrincipalRef, { kind: "autogroup" }> | { readonly kind: "autogroup"; readonly name: "member" | "admin" | "self" }

export interface Destination {
  readonly target: DestRef
  readonly ports: Ports
  /** Original text, kept for diagnostics and previews. */
  readonly text: string
}

export type AgentClass = "mux" | "agent" | "run"

export interface AclRule {
  readonly action: "accept"
  readonly src: ReadonlyArray<PrincipalRef>
  readonly dst: ReadonlyArray<Destination>
  /** Narrows the rule to one protocol. Unset: TCP for numbered ports, every protocol for `*`. */
  readonly proto?: Proto
  /** Index in the document, for diagnostics. */
  readonly index: number
}

export type SshUser =
  | { readonly kind: "literal"; readonly name: string }
  /** The caller's own Linux user (its handle). */
  | { readonly kind: "nonroot" }
  /** A template such as `<owner>-mux`: `<owner>` becomes the source principal's owner handle. */
  | { readonly kind: "template"; readonly template: string }

export interface SshRule {
  readonly action: "accept" | "check"
  readonly src: ReadonlyArray<PrincipalRef>
  /** Machines: `tag:…` or `autogroup:self`. */
  readonly dst: ReadonlyArray<{ readonly kind: "tag"; readonly name: string } | { readonly kind: "autogroup"; readonly name: "self" }>
  readonly users: ReadonlyArray<SshUser>
  readonly forceCommand?: string
  readonly index: number
}

export interface PolicyTest {
  readonly src: PrincipalRef
  readonly accept: ReadonlyArray<Destination>
  readonly deny: ReadonlyArray<Destination>
  readonly proto?: Proto
  readonly index: number
}

export interface Policy {
  readonly groups: Readonly<Record<string, ReadonlyArray<PrincipalRef>>>
  readonly tagOwners: Readonly<Record<string, ReadonlyArray<PrincipalRef>>>
  readonly hosts: Readonly<Record<string, string>>
  readonly acls: ReadonlyArray<AclRule>
  readonly ssh: ReadonlyArray<SshRule>
  readonly tests: ReadonlyArray<PolicyTest>
}

/** One problem with a document. `path` is a JSON path such as `acls[1].dst[0]`. */
export interface PolicyIssue {
  readonly path: string
  readonly message: string
}

export type Result<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly issues: ReadonlyArray<PolicyIssue> }

/**
 * What the policy is evaluated against: TeamDO's directory. Users are the
 * team's members; devices are installs that joined the network; machines are
 * VPC members (Cloud VMs, the team VM, streaming hosts).
 */
export interface Directory {
  readonly members: ReadonlyArray<DirectoryMember>
  readonly devices: ReadonlyArray<DirectoryDevice>
  readonly machines: ReadonlyArray<DirectoryMachine>
  /** Permission-hierarchy nodes (spec/team-vm.md): node path -> member user ids. Absent until the hierarchy ships. */
  readonly nodes?: Readonly<Record<string, ReadonlyArray<string>>>
}

export interface DirectoryMember {
  readonly user: string
  readonly role: "owner" | "admin" | "member"
  /** Linux user name and the readable policy handle (`user:lawrence`). */
  readonly handle?: string
}

export interface DirectoryDevice {
  readonly install: string
  readonly user: string
  /** Agent classes whose principals run on this device (a Mac running its owner's mux). */
  readonly classes?: ReadonlyArray<AgentClass>
  readonly revoked?: boolean
  /** WireGuard public key the install sent with network.device.join (the private key never leaves the device). */
  readonly wg_public_key?: string
}

export interface DirectoryMachine {
  readonly id: string
  /** Provider id (Freestyle `vm-…`); machines without one are compiled but not enforced yet. */
  readonly provider_id?: string
  /** Owner for untagged personal machines; tagged machines are identified by their tags. */
  readonly owner_user?: string
  readonly tags: ReadonlyArray<string>
  readonly classes?: ReadonlyArray<AgentClass>
  /** Private address inside the team VPC, when known (for `hosts` and CIDR matching in previews). */
  readonly address?: string
}
