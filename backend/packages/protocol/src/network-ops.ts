import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { InstallId, UserId } from "./schemas.ts"

/**
 * Network policy ops (spec network-policy.md "Ops"). Owner: the TeamDO of the
 * caller's team. The policy document is JSONC text; the owner parses and
 * validates it with @cmux/network-policy and answers with JSON-path issues.
 */

/** A WireGuard public key: 32 bytes, standard base64 (44 characters ending in `=`). */
export const WireGuardPublicKey = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9+/]{43}=$/)).annotate({
  identifier: "WireGuardPublicKey",
  description: "Curve25519 public key, base64. The private key never leaves the device."
})

export const MachineId = Schema.String.check(Schema.isPattern(/^mach_[a-z0-9_]{1,40}$/)).annotate({ identifier: "MachineId", description: "A VPC member machine in the team directory." })
export const TagName = Schema.String.check(Schema.isPattern(/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/))
export const PolicyDocument = Schema.String.check(Schema.isMinLength(2), Schema.isMaxLength(128 * 1024)).annotate({
  identifier: "PolicyDocument",
  description: "The network policy as JSON (comments and trailing commas allowed)."
})

export const PolicyIssue = Schema.Struct({ path: Schema.String, message: Schema.String }).annotate({ identifier: "PolicyIssue" })

export const PolicyVersion = Schema.Struct({
  version: Schema.Int,
  source: Schema.String,
  canonical: Schema.String,
  applied_by: Schema.String,
  applied_at: Schema.Int,
  tests_passed: Schema.Int,
  rollback_of: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "NetworkPolicyVersion" })

export const DeviceTunnel = Schema.Struct({
  tunnel_id: Schema.String,
  client_config: Schema.String,
  endpoint: Schema.NullOr(Schema.String),
  address_v4: Schema.NullOr(Schema.String),
  address_v6: Schema.NullOr(Schema.String),
  server_public_key: Schema.String,
  ready_at: Schema.Int
}).annotate({ identifier: "NetworkDeviceTunnel", description: "WireGuard config with a blank PrivateKey (the device fills it in) and PersistentKeepalive." })

export const NetworkDevice = Schema.Struct({
  install: InstallId,
  user: UserId,
  wg_public_key: WireGuardPublicKey,
  joined_at: Schema.Int,
  revoked_at: Schema.NullOr(Schema.Int),
  status: Schema.Literals(["pending", "ready", "revoked"]),
  tunnel: Schema.NullOr(DeviceTunnel)
}).annotate({ identifier: "NetworkDevice" })

export const NetworkMachine = Schema.Struct({
  id: MachineId,
  provider_id: Schema.NullOr(Schema.String),
  owner_user: Schema.NullOr(UserId),
  tags: Schema.Array(TagName),
  classes: Schema.Array(Schema.Literals(["mux", "agent", "run"])),
  address: Schema.NullOr(Schema.String)
}).annotate({ identifier: "NetworkMachine" })

const PreviewResult = Schema.Struct({
  ok: Schema.Boolean,
  issues: Schema.optionalKey(Schema.Array(PolicyIssue)),
  canonical: Schema.optionalKey(Schema.String),
  diff: Schema.optionalKey(Schema.Unknown),
  compiled: Schema.optionalKey(Schema.Struct({ rules: Schema.Int, ssh: Schema.Int })),
  notes: Schema.optionalKey(Schema.Array(Schema.String))
})

export const NetworkPolicyGet = def({
  name: "network.policy.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ version: Schema.optionalKey(Schema.Int) }),
  result: Schema.Struct({ policy: PolicyVersion, effective_default: Schema.Boolean, versions: Schema.Array(Schema.Struct({ version: Schema.Int, applied_by: Schema.String, applied_at: Schema.Int, rollback_of: Schema.NullOr(Schema.Int) })), reconcile: Schema.Unknown }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read the team network policy (current or a given version), its version list and the reconciler status. Without an applied policy the built-in default is returned.",
  cli: { path: "network policy get", visible: true },
  mcp: { expose: "default", group: "network" }
})

export const NetworkPolicyPreview = def({
  name: "network.policy.preview",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ document: PolicyDocument }),
  result: PreviewResult,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Validate a policy, run its tests and the lockout guard, compile it and diff the compiled rules per enforcement point against the current version. Changes nothing. Team owners and admins only.",
  cli: { path: "network policy preview", visible: true },
  mcp: { expose: "opt_in", group: "network" }
})

export const NetworkPolicyApply = def({
  name: "network.policy.apply",
  owner: "cloud:TeamDO",
  class: "mutation",
  // Any policy change can cut a device's access, so apply is destructive (needs that grant class or a human session).
  risk: "destructive",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ document: PolicyDocument, expected_version: Schema.NullOr(Schema.Int) }),
  result: PolicyVersion,
  errors: [...mutationErrors, "policy.invalid", "version.conflict"],
  docs: "Validate, test and commit a new policy version (team owners and admins). expected_version is the version the editor started from (null when none was applied); a different current version is a version.conflict. The reconciler then converges Freestyle.",
  cli: { path: "network policy apply", visible: true },
  mcp: { expose: "never", group: "network" }
})

export const NetworkPolicyRollback = def({
  name: "network.policy.rollback",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ version: Schema.Int }),
  result: PolicyVersion,
  errors: [...mutationErrors, "selector.not_found", "policy.invalid"],
  docs: "Apply an earlier version as a new version (it is validated again against today's directory).",
  cli: { path: "network policy rollback", visible: true },
  mcp: { expose: "never", group: "network" }
})

export const NetworkDeviceJoin = def({
  name: "network.device.join",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "network",
  principals: ["install"],
  params: Schema.Struct({ wg_public_key: WireGuardPublicKey }),
  result: NetworkDevice,
  errors: [...mutationErrors, "network.no_access"],
  docs: "Join the calling install to the team network with its WireGuard public key. Returns the device; the tunnel config arrives when the reconciler has created the tunnel (status ready, network.device.get or the team stream).",
  cli: { path: "network join", visible: false },
  mcp: { expose: "never", group: "network" }
})

export const NetworkDeviceRevoke = def({
  name: "network.device.revoke",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ install: InstallId }),
  result: NetworkDevice,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove a device from the team network: its tunnel and rules are deleted. The device's user or a team admin.",
  cli: { path: "network device revoke", visible: true },
  mcp: { expose: "never", group: "network" }
})

export const NetworkDeviceGet = def({
  name: "network.device.get",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ install: Schema.optionalKey(InstallId) }),
  result: Schema.Struct({ devices: Schema.Array(NetworkDevice) }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The caller's network devices (an install sees itself unless it names another of its user's installs; admins see every device).",
  cli: { path: "network device list", visible: true },
  mcp: { expose: "default", group: "network" }
})

export const NetworkMachineRegister = def({
  name: "network.machine.register",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({
    machine: MachineId,
    provider_id: Schema.NullOr(Schema.String),
    owner_user: Schema.NullOr(UserId),
    tags: Schema.Array(TagName),
    classes: Schema.optionalKey(Schema.Array(Schema.Literals(["mux", "agent", "run"]))),
    address: Schema.optionalKey(Schema.NullOr(Schema.String))
  }),
  result: NetworkMachine,
  errors: [...mutationErrors, "tag.forbidden"],
  docs: "Record a VPC member machine in the team directory (team admins; tags need tag ownership). The Cloud VM lifecycle will call this when it ports.",
  cli: { path: "network machine register", visible: false },
  mcp: { expose: "never", group: "network" }
})

export const NetworkMachineTag = def({
  name: "network.machine.tag",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ machine: MachineId, tags: Schema.Array(TagName) }),
  result: NetworkMachine,
  errors: [...mutationErrors, "selector.not_found", "tag.forbidden"],
  docs: "Replace a machine's tags. The caller must own every tag added or removed (tagOwners).",
  cli: { path: "network machine tag", visible: true },
  mcp: { expose: "opt_in", group: "network" }
})

export const NetworkMachineRemove = def({
  name: "network.machine.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "network",
  principals: ["session", "install"],
  params: Schema.Struct({ machine: MachineId }),
  result: Schema.Struct({ machine: MachineId }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove a machine from the team directory (team admins).",
  cli: { path: "network machine remove", visible: false },
  mcp: { expose: "never", group: "network" }
})

export const networkOps = [
  NetworkPolicyGet,
  NetworkPolicyPreview,
  NetworkPolicyApply,
  NetworkPolicyRollback,
  NetworkDeviceJoin,
  NetworkDeviceRevoke,
  NetworkDeviceGet,
  NetworkMachineRegister,
  NetworkMachineTag,
  NetworkMachineRemove
] as const

export const ReconcileRecordParams = Schema.Struct({
  desired_seq: Schema.Int,
  started_at: Schema.Int,
  ms: Schema.Int,
  converged: Schema.Boolean,
  configured: Schema.Boolean,
  actions: Schema.Array(Schema.Struct({ op: Schema.String, ok: Schema.Boolean, ms: Schema.Int, error: Schema.optionalKey(Schema.String) })),
  drift: Schema.Array(Schema.String),
  deferred: Schema.Int,
  vpc_id: Schema.NullOr(Schema.String),
  tunnels: Schema.Array(Schema.Struct({ install: InstallId, tunnel: DeviceTunnel })),
  error: Schema.optionalKey(Schema.String)
})

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-own",
    target: "network",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** Ops only TeamDO itself submits (its reconciler, UserDO revocation notices). Not exported to the catalog. */
export const networkInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("network.reconcile.record", ReconcileRecordParams, "Internal: the reconciler's result for one desired state."),
  internal("network.install.revoked", Schema.Struct({ install: InstallId }), "Internal: UserDO revoked an install; drop its device.")
]
