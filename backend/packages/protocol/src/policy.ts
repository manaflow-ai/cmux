import { Schema } from "effect"
import { IntegrationProvider, RepoPattern } from "./integrations.ts"

/**
 * Team policy (spec/enterprise.md section 4): one typed record per team,
 * owned by TeamDO. Each key is absent (the product default applies and the
 * user decides) or a PolicyValue: `enforced` (owners refuse violating ops,
 * clients show the key as managed) or `default` (replaces the product default,
 * users may still change it).
 */
export const PolicyMode = Schema.Literals(["enforced", "default"]).annotate({ identifier: "PolicyMode" })

const policyValue = <S extends Schema.Top>(value: S) => Schema.Struct({ value, mode: PolicyMode })

const Int = Schema.Number.check(Schema.isInt())
const intBetween = (min: number, max: number) => Int.check(Schema.isGreaterThanOrEqualTo(min), Schema.isLessThanOrEqualTo(max))
const AppId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
const Version = Schema.String.check(Schema.isPattern(/^[0-9]+(\.[0-9]+){0,3}$/))

/** A cmux.json key path, as the settings catalog names it (`ui.animationSpeed`). */
const SettingPath = Schema.String.check(Schema.isPattern(/^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9-]+)+$/), Schema.isMaxLength(200))
const DeviceSetting = Schema.Struct({ value: Schema.Unknown, mode: PolicyMode })

/** Product maximums: a team may only shorten these retention periods (D19). */
export const RETENTION_MAX = { cuaEventsDays: 30, cuaFramesDays: 7 } as const
/** Audit retention may only lengthen above this floor. */
export const AUDIT_RETENTION_MIN_DAYS = 365

/**
 * Link services a policy or grant may give (FINDER-FS): unique, and `daemon` only together with `ssh`.
 * CloudDO's per-machine grants use the same rule (cloudServicesProblem).
 */
export const cloudServicesProblem = (services: ReadonlyArray<string>): string | undefined => {
  if (new Set(services).size !== services.length) return "services must be unique"
  if (services.includes("daemon") && !services.includes("ssh")) return "daemon (files and commands) requires ssh on the same machine"
  return undefined
}
export const CloudConnectServices = Schema.Array(Schema.Literals(["daemon", "ssh"]))
  .check(Schema.isMaxLength(2), Schema.makeFilter((services: ReadonlyArray<string>) => cloudServicesProblem(services) ?? true))
  .annotate({ identifier: "CloudConnectServices" })

/** The value schema of every policy key, by dotted key. */
export const policyKeySchemas = {
  // Same values as TeamIntegrationPolicy (integrations.ts), which ConnectionDO enforces as TeamDO's projection.
  "github.repoScope": Schema.Literals(["linking_user_repos", "installation"]),
  "github.requireOrgAdmin": Schema.Boolean,
  /** Extra limit on repositories: a list (empty = no extra limit), or "none" to deny every repository. */
  "github.repoAllowList": Schema.Union([Schema.Literal("none"), Schema.Array(RepoPattern).check(Schema.isMaxLength(500))]),
  "integrations.allowedProviders": Schema.Union([Schema.Literal("all"), Schema.Array(IntegrationProvider)]),
  "mcp.server": Schema.Literals(["user_choice", "disabled"]),
  "mcp.remoteTransport": Schema.Boolean,
  "apps.install": Schema.Literals(["any", "allow_list", "disabled"]),
  "apps.allowedTiers": Schema.Array(Schema.Literals(["first-party", "verified", "community", "unverified"])),
  "apps.allowList": Schema.Array(AppId).check(Schema.isMaxLength(500)),
  "apps.forcedInstalls": Schema.Array(AppId).check(Schema.isMaxLength(100)),
  "computerUse.allowed": Schema.Boolean,
  "browserAutomation.rawCdp": Schema.Boolean,
  "cloud.sandboxes": Schema.Boolean,
  /**
   * The `cmux link` services team members may dial on team Cloud machines (decision CLOUD-CONNECT-ACCESS).
   * FINDER-FS: files are reached only through `daemon`, which also runs commands, so `daemon` requires
   * `ssh`: a principal without a shell never gets one through the files path.
   */
  "cloud.connectServices": CloudConnectServices,
  "telemetry.level": Schema.Literals(["full", "crash_only", "off"]),
  "updates.channel": Schema.Literals(["stable", "nightly"]),
  "updates.minimumVersion": Version,
  "retention.cuaEventsDays": intBetween(1, RETENTION_MAX.cuaEventsDays),
  "retention.cuaFramesDays": intBetween(1, RETENTION_MAX.cuaFramesDays),
  "retention.transcriptDays": intBetween(1, 3650),
  "retention.auditDays": intBetween(AUDIT_RETENTION_MIN_DAYS, 3650),
  "sso.enforce": Schema.Boolean,
  "sso.enforceForOwners": Schema.Boolean,
  "sso.allowGuests": Schema.Boolean,
  "sso.sessionMaxAgeHours": intBetween(1, 24 * 90),
  "sso.idleTimeoutHours": intBetween(1, 24 * 90),
  "agents.allowedClasses": Schema.Array(Schema.Literals(["mux", "agent", "run"])),
  /**
   * cmux.json settings for managed devices, by key path, each enforced or a
   * default. The app keeps only keys its settings catalog lists. The outer
   * PolicyValue mode is ignored (each entry has its own).
   */
  "device.settings": Schema.Record(SettingPath, DeviceSetting).check(Schema.isMaxProperties(200))
} as const

export type PolicyKey = keyof typeof policyKeySchemas
export const policyKeys = Object.keys(policyKeySchemas) as ReadonlyArray<PolicyKey>

/** Product defaults (what an absent key means). Documented in spec/enterprise.md 4.2. */
export const policyProductDefaults: { readonly [K in PolicyKey]?: (typeof policyKeySchemas)[K]["Type"] } = {
  "github.repoScope": "linking_user_repos",
  "github.requireOrgAdmin": false,
  "github.repoAllowList": [],
  "integrations.allowedProviders": "all",
  "mcp.server": "user_choice",
  "mcp.remoteTransport": false,
  "apps.install": "any",
  "apps.allowedTiers": ["first-party", "verified", "community", "unverified"],
  "apps.allowList": [],
  "apps.forcedInstalls": [],
  "computerUse.allowed": true,
  "browserAutomation.rawCdp": true,
  "cloud.sandboxes": true,
  "cloud.connectServices": ["daemon", "ssh"],
  "telemetry.level": "full",
  "updates.channel": "stable",
  "retention.cuaEventsDays": RETENTION_MAX.cuaEventsDays,
  "retention.cuaFramesDays": RETENTION_MAX.cuaFramesDays,
  "retention.auditDays": 400,
  "sso.enforce": false,
  "sso.enforceForOwners": false,
  "sso.allowGuests": true,
  "agents.allowedClasses": ["mux", "agent", "run"]
}

/** Keys clients apply on a device (spec/enterprise.md 4.4); the rest are enforced by cloud owners. */
export const deviceScopedPolicyKeys: ReadonlySet<PolicyKey> = new Set<PolicyKey>([
  "mcp.server",
  "mcp.remoteTransport",
  "computerUse.allowed",
  "browserAutomation.rawCdp",
  "telemetry.level",
  "updates.channel"
])

export const PolicyKeyName = Schema.Literals(policyKeys as unknown as readonly [PolicyKey, ...Array<PolicyKey>]).annotate({
  identifier: "PolicyKey",
  description: "A team policy key (spec/enterprise.md 4.2)."
})

const fields = Object.fromEntries(policyKeys.map((k) => [k, Schema.optionalKey(policyValue(policyKeySchemas[k]))])) as {
  readonly [K in PolicyKey]: Schema.optionalKey<Schema.Struct<{ value: (typeof policyKeySchemas)[K]; mode: typeof PolicyMode }>>
}

export const TeamPolicyValues = Schema.Struct(fields).annotate({
  identifier: "TeamPolicyValues",
  description: "Set keys of a team policy; an absent key means the product default and the user's choice."
})

export const TeamPolicy = Schema.Struct({
  version: Int,
  values: TeamPolicyValues,
  updated_at: Schema.NullOr(Int),
  updated_by: Schema.NullOr(Schema.String)
}).annotate({ identifier: "TeamPolicy" })

export const TeamPolicyVersion = Schema.Struct({
  version: Int,
  values: TeamPolicyValues,
  changed: Schema.Array(PolicyKeyName),
  actor: Schema.NullOr(Schema.String),
  at: Int,
  reason: Schema.NullOr(Schema.String),
  rollback_of: Schema.NullOr(Int)
}).annotate({ identifier: "TeamPolicyVersion" })

export const PolicyChange = Schema.Struct({
  key: PolicyKeyName,
  /** The new value, or null to clear the key (product default, user's choice). */
  value: Schema.NullOr(Schema.Struct({ value: Schema.Unknown, mode: PolicyMode }))
}).annotate({ identifier: "PolicyChange" })

/** Decodes one key's PolicyValue with that key's schema. */
export const policyValueSchema = (key: PolicyKey) => policyValue(policyKeySchemas[key])
