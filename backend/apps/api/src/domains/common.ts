import type { Principal, Reject } from "@cmux/ownership"
import { cloudInternalOps, cloudOpByName, InstallRegister, connectionInternalOps, DisplayName, feedInternalOps, pushInternalOps, userConfirmInternalOps, InstallId, Platform, schedulerInternalOps, teamSshInternalOps, teamVmInternalOps, TeamId, UserId, WgPublicKey, type CloudOpDef } from "@cmux/protocol"
import { Exit, Schema } from "effect"

export const reject = (code: string, message: string, details?: unknown): { ok: false } & Reject => ({
  ok: false,
  code,
  message,
  ...(details === undefined ? {} : { details })
})

/** Decodes params with the op's Effect Schema (pure; runs on owner and mirrors alike). */
export const decodeParams = <T>(op: CloudOpDef, params: unknown): { ok: true; value: T } | ({ ok: false } & Reject) => {
  const exit = Schema.decodeUnknownExit(op.params as Schema.Codec<T, unknown>)(params ?? {})
  return Exit.isSuccess(exit) ? { ok: true, value: exit.value } : reject("validation.invalid", "invalid params", String(exit.cause))
}

export interface GrantLike {
  readonly op_classes: ReadonlyArray<string>
  readonly revoked_at: number | null
  readonly expires_at: number | null
}

/**
 * Generic op admission shared by every cloud owner: the op exists for this
 * owner, the principal kind may call it, and an install's grant covers the
 * op's risk class. Ownership-specific checks stay in each reducer.
 */
export const admit = (
  owner: CloudOpDef["owner"],
  opName: string,
  principal: Principal,
  grantFor: (principal: Principal) => GrantLike | undefined,
  now: number
): Reject | undefined => {
  const def = cloudOpByName.get(opName) ?? internalOps.get(opName)
  if (!def || def.owner !== owner) return { code: "validation.invalid", message: `unknown op ${opName} for ${owner}` }
  const kind = principal.kind ?? "install"
  if (!def.principals.includes(kind === "agent" ? "install" : kind)) {
    return { code: "auth.forbidden", message: `${opName} is not allowed for ${kind} principals` }
  }
  // A system principal is built only by server code (a DO, or the Worker over DO RPC) and calls only internal ops (checked above).
  if (kind === "system") return undefined
  if (kind !== "session") {
    const grant = grantFor(principal)
    if (!grant) return { code: "auth.forbidden", message: "grant not found" }
    if (grant.revoked_at !== null) return { code: "auth.forbidden", message: "grant revoked" }
    if (grant.expires_at !== null && grant.expires_at <= now) return { code: "auth.forbidden", message: "grant expired" }
    if (!grant.op_classes.includes(def.risk)) return { code: "auth.forbidden", message: `grant does not cover ${def.risk}` }
  }
  return undefined
}

/** Ops the Worker sends that are not part of the public catalog. */
export const internalOps: ReadonlyMap<string, CloudOpDef> = new Map([
  [
    "team.ensure_personal",
    {
      name: "team.ensure_personal",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-own",
      target: "team",
      principals: ["session"],
      params: Schema.Struct({}),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: create the caller's personal team.",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "sso.signed_in",
    {
      name: "sso.signed_in",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "team",
      principals: ["system"],
      params: Schema.Struct({ connection: Schema.String, subject: Schema.String, stack_user: Schema.String, linked: Schema.Boolean }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: a person signed in through an SSO connection (audit; subject is a hash of connection and IdP subject).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "domain.rechecked",
    {
      name: "domain.rechecked",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "team",
      principals: ["system"],
      params: Schema.Struct({ domain: Schema.String, record_value: Schema.String, ok: Schema.Boolean, at: Schema.Number }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: one weekly DNS re-check of a verified domain.",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  ...(["sso.connection.secret_set", "sso.connection.activated"] as const).map(
    (name) =>
      [
        name,
        {
          name,
          owner: "cloud:TeamDO",
          class: "mutation",
          risk: "mutate-shared",
          target: "team",
          principals: ["system"],
          params:
            name === "sso.connection.secret_set"
              ? Schema.Struct({ connection: Schema.String, generation: Schema.Number, by: Schema.optionalKey(Schema.String) })
              : Schema.Struct({
                  connection: Schema.String,
                  authorization_endpoint: Schema.String,
                  token_endpoint: Schema.String,
                  jwks_uri: Schema.String,
                  by: Schema.optionalKey(Schema.String),
                  expected_updated_at: Schema.Number
                }),
          result: Schema.Unknown,
          errors: [],
          docs: name === "sso.connection.secret_set" ? "Internal: the connection's client secret was sealed (never in params)." : "Internal: discovery succeeded; the connection is active.",
          cli: { path: "", visible: false },
          mcp: { expose: "never", group: "internal" }
        } as CloudOpDef
      ] as const
  ),
  ...(["domain.mark_verified", "domain.mark_released", "domain.mark_lost"] as const).map(
    (name) =>
      [
        name,
        {
          name,
          owner: "cloud:TeamDO",
          class: "mutation",
          risk: "mutate-shared",
          target: "team",
          principals: ["system"],
          params:
            name === "domain.mark_verified"
              ? Schema.Struct({ domain: Schema.String, record_value: Schema.String, verified_at: Schema.Number, by: Schema.optionalKey(Schema.String) })
              : Schema.Struct({ domain: Schema.String, by: Schema.optionalKey(Schema.String) }),
          result: Schema.Unknown,
          errors: [],
          docs:
            name === "domain.mark_verified"
              ? "Internal: DomainDO made this team the domain's owner."
              : name === "domain.mark_lost"
                ? "Internal: DomainDO refused a re-check; another team owns the domain."
                : "Internal: DomainDO dropped this team's claim.",
          cli: { path: "", visible: false },
          mcp: { expose: "never", group: "internal" }
        } as CloudOpDef
      ] as const
  ),
  ...(["team.policy.integration_lock", "team.integration.release_done"] as const).map(
    (name) =>
      [
        name,
        {
          name,
          owner: "cloud:TeamDO",
          class: "mutation",
          risk: "mutate-shared",
          target: "team_policy",
          principals: ["system"],
          params:
            name === "team.policy.integration_lock"
              ? Schema.Struct({
                  managed_by: Schema.NullOr(Schema.Literals(["sso", "mdm"])),
                  version: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)),
                  epoch: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64)))
                })
              : Schema.Struct({ request: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)) }),
          result: Schema.Unknown,
          errors: [],
          docs:
            name === "team.policy.integration_lock"
              ? "Internal: ConnectionDO's SSO/MDM lock changed (notice with ConnectionDO's lock version)."
              : "Internal: ConnectionDO released the lock for this release request.",
          cli: { path: "", visible: false },
          mcp: { expose: "never", group: "internal" }
        } as CloudOpDef
      ] as const
  ),
  ...(["team.policy.integration_seed", "team.policy.integration_synced"] as const).map(
    (name) =>
      [
        name,
        {
          name,
          owner: "cloud:TeamDO",
          class: "mutation",
          risk: "mutate-shared",
          target: "team_policy",
          principals: ["system"],
          params:
            name === "team.policy.integration_seed"
              ? Schema.Struct({ policy: Schema.Unknown, managed_by: Schema.optionalKey(Schema.NullOr(Schema.Literals(["sso", "mdm"]))) })
              : Schema.Struct({
                  version: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)),
                  slice_hash: Schema.String,
                  managed_by: Schema.optionalKey(Schema.NullOr(Schema.Literals(["sso", "mdm"]))),
                  lock_version: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))),
                  lock_epoch: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64)))
                }),
          result: Schema.Unknown,
          errors: [],
          docs:
            name === "team.policy.integration_seed"
              ? "Internal: copy ConnectionDO's integration policy into TeamPolicy before the first push."
              : "Internal: ConnectionDO acknowledged this integration slice.",
          cli: { path: "", visible: false },
          mcp: { expose: "never", group: "internal" }
        } as CloudOpDef
      ] as const
  ),
  [
    "user.team_index",
    {
      name: "user.team_index",
      owner: "cloud:UserDO",
      class: "mutation",
      risk: "mutate-own",
      target: "user",
      principals: ["system"],
      params: Schema.Struct({ team: Schema.String, role: Schema.NullOr(Schema.String), kind: Schema.optionalKey(Schema.String) }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: a TeamDO records (or with role null removes) this user's membership in the UserDO team index ((f) step 5).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "team.rows_migrate",
    {
      name: "team.rows_migrate",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "team",
      principals: ["system"],
      params: Schema.Struct({}),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: moves an old head's members and hosts maps into rows ((f), DO audit F-1).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "team.policy.runs_synced",
    {
      name: "team.policy.runs_synced",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "team_policy",
      principals: ["system"],
      params: Schema.Struct({ version: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0)), runs_allowed: Schema.Boolean }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: SchedulerDO acknowledged whether the team allows automation runs (agents.allowedClasses run).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "install.ios_cloud_link_migrate",
    {
      name: "install.ios_cloud_link_migrate",
      owner: "cloud:UserDO",
      class: "mutation",
      risk: "mutate-own",
      target: "install",
      principals: ["system"],
      params: Schema.Struct({}),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: UserDO adds the narrow cloud-link class once to its iPhone grants (read, mutate-own) made before the cloud-link default, on bind, then marks the migration done (CLOUD-LINK-FOLLOWUPS decision 2).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "install.register_server",
    {
      name: "install.register_server",
      owner: "cloud:UserDO",
      class: "mutation",
      risk: "mutate-own",
      target: "install",
      principals: ["system"],
      params: InstallRegister.params,
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: the server registers a server install (kind vm or daemon) for a user: pairing and the Cloud bind flow. A client never declares these kinds (CLOUD-LINK-FOLLOWUPS 4).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "install.revoke_by_team",
    {
      name: "install.revoke_by_team",
      owner: "cloud:UserDO",
      class: "mutation",
      risk: "destructive",
      target: "install",
      principals: ["system"],
      params: Schema.Struct({ install: InstallId, team: TeamId, by: UserId }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: the bound team's TeamDO revokes a paired server's install (plans/cmux-next/server.md 6.5).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "install.ssh_revoke_done",
    {
      name: "install.ssh_revoke_done",
      owner: "cloud:UserDO",
      class: "mutation",
      risk: "mutate-own",
      target: "install",
      principals: ["system"],
      params: Schema.Struct({ install: InstallId }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: every team confirmed the KRL entries for a revoked install's SSH certificates.",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "server.install_revoked",
    {
      name: "server.install_revoked",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "host",
      principals: ["system"],
      params: Schema.Struct({ install: InstallId }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: UserDO confirmed the revocation of a removed server's install.",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  [
    "server.enrolled",
    {
      name: "server.enrolled",
      owner: "cloud:TeamDO",
      class: "mutation",
      risk: "mutate-shared",
      target: "host",
      principals: ["system"],
      params: Schema.Struct({
        install: InstallId,
        name: DisplayName,
        platform: Platform,
        wg_public_key: WgPublicKey,
        owner_user: UserId,
        approved_by: UserId
      }),
      result: Schema.Unknown,
      errors: [],
      docs: "Internal: an approved pairing adds the server to the directory (plans/cmux-next/server.md 6.2).",
      cli: { path: "", visible: false },
      mcp: { expose: "never", group: "internal" }
    } as CloudOpDef
  ],
  ...schedulerInternalOps.map((d) => [d.name, d] as const),
  ...connectionInternalOps.map((d) => [d.name, d] as const),
  ...feedInternalOps.map((d) => [d.name, d] as const),
  ...pushInternalOps.map((d) => [d.name, d] as const),
  ...userConfirmInternalOps.map((d) => [d.name, d] as const),
  ...teamVmInternalOps.map((d) => [d.name, d] as const),
  ...cloudInternalOps.map((d) => [d.name, d] as const),
  ...teamSshInternalOps.map((d) => [d.name, d] as const)
])

/**
 * Team-admin ops (policy, team settings) accept any member only because every
 * team is personal today: the member is the owner. A shared team has no roles
 * here yet, so it is refused until roles land (tested; do not relax this
 * without a role check).
 */
export const requirePersonalTeamAdmin = (p: Principal, personalTeamId: (user: string) => string): Reject | undefined =>
  p.user && p.team && p.team === personalTeamId(p.user)
    ? undefined
    : { code: "team.roles_required", message: "team admin ops need team roles, which shared teams do not have yet" }
