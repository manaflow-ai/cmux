import { Schema } from "effect"
import { TeamId, UserId } from "./schemas.ts"

/**
 * App store shapes (spec app-platform.md sections 3, 9 to 12; contract v1
 * "Store ops"). Owners: AppDO per app id (listing, versions, tier, yanks),
 * UserDO (personal installs, grants, approvals), TeamDO (team installs, team
 * app policy). Times are ms since the epoch.
 */

const Text = (max: number) => Schema.String.check(Schema.isMaxLength(max))
const NonEmptyText = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))

/** `<publisher>/<name>`; publisher = the repository's GitHub owner. `local/` is for sideloads and never in the store. */
export const APP_ID_PATTERN = /^(local|[a-z0-9](?:[a-z0-9-]{0,38}))\/[a-z0-9][a-z0-9-]{0,63}$/
export const AppId = Schema.String.check(Schema.isPattern(APP_ID_PATTERN)).annotate({
  identifier: "AppId",
  description: "Stable app id `<publisher>/<name>` (publisher = GitHub owner of the repository)."
})

/** Semantic version 2.0.0 (no leading zeros; optional prerelease and build). */
export const SEMVER_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/
export const AppVersion = Schema.String.check(Schema.isMaxLength(64), Schema.isPattern(SEMVER_PATTERN)).annotate({
  identifier: "AppVersion",
  description: "Semantic version; equals the release tag without the leading v."
})

/** A version range: `*`, an exact version, `^1.2`, `~1.2.3`, `>=1.0.0`, `1.x`. */
export const VersionRange = NonEmptyText(64).annotate({ identifier: "VersionRange" })

/** `family:detail`, for example `workspace:read`, `net:api.github.com`, `integration:github`. */
export const SCOPE_PATTERN = /^[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._*/-]{1,200}$/
export const AppScope = Schema.String.check(Schema.isPattern(SCOPE_PATTERN)).annotate({
  identifier: "AppScope",
  description: "A scope an app requests, `family:detail` (spec section 10, contract scopes.json)."
})

export const AppTier = Schema.Literals(["first-party", "verified", "unverified"]).annotate({
  identifier: "AppTier",
  description: "Review tier: first-party (cmux), verified, or unverified third-party. Unverified apps are never searchable."
})
export type AppTier = typeof AppTier.Type

export const InstallScope = Schema.Literals(["user", "team"]).annotate({ identifier: "InstallScope" })

/** One published version of an app, as the store records it. */
export const AppVersionRecord = Schema.Struct({
  version: AppVersion,
  tag: Schema.String,
  engines: Schema.Struct({ cmux: Schema.String }),
  /** Required scopes with their reasons (shown at consent). */
  scopes: Schema.Record(Schema.String, Schema.String),
  optional_scopes: Schema.Record(Schema.String, Schema.String),
  /** Scopes this version adds over the previous version (the consent diff). */
  added_scopes: Schema.Array(Schema.String),
  bundle_url: Schema.String,
  bundle_sha256: Schema.String,
  attestation_digest: Schema.NullOr(Schema.String),
  published_at: Schema.Int,
  /** Owner state only; never in public views (app.info). */
  published_by: Schema.optionalKey(UserId),
  yanked: Schema.Boolean,
  yanked_at: Schema.NullOr(Schema.Int),
  yank_reason: Schema.NullOr(Schema.String)
}).annotate({ identifier: "AppVersionRecord" })
export type AppVersionRecord = typeof AppVersionRecord.Type

/** Store listing (contract "Listing shape"). `versions` only from app.info. */
export const AppListing = Schema.Struct({
  id: AppId,
  name: Schema.String,
  description: Schema.String,
  publisher: Schema.Struct({ name: Schema.String, github_owner: Schema.String, verified: Schema.Boolean }),
  repository: Schema.String,
  icon_url: Schema.optionalKey(Schema.NullOr(Schema.String)),
  categories: Schema.Array(Schema.String),
  tier: AppTier,
  latest_version: Schema.NullOr(AppVersion),
  install_count: Schema.Int,
  versions: Schema.optionalKey(Schema.Array(AppVersionRecord))
}).annotate({ identifier: "AppListing" })
export type AppListing = typeof AppListing.Type

/**
 * The release an owner resolved from AppDO before deciding an install, update
 * or approval. Pinned by `app_revision` (AppDO's sequence when it answered).
 * Never sent by clients: the owner passes it to its reducer (ownership
 * engine `SubmitOptions.resolved`), so the reducer stays pure.
 */
export const ResolvedRelease = Schema.Struct({
  app: AppId,
  version: AppVersion,
  tier: AppTier,
  publisher_team: TeamId,
  scopes: Schema.Array(Schema.String),
  optional_scopes: Schema.Array(Schema.String),
  engines: Schema.Struct({ cmux: Schema.String }),
  bundle_url: Schema.String,
  bundle_sha256: Schema.String,
  yanked: Schema.Boolean,
  app_revision: Schema.String
}).annotate({ identifier: "ResolvedRelease" })
export type ResolvedRelease = typeof ResolvedRelease.Type

/** One install of an app in a user's or a team's set. Grants are per install. */
export const AppInstall = Schema.Struct({
  app: AppId,
  scope: InstallScope,
  version: AppVersion,
  version_range: VersionRange,
  tier: AppTier,
  /** Scopes the user granted (required plus the optional ones accepted). */
  scopes_granted: Schema.Array(Schema.String),
  /** The installed version's required and optional scopes (grant changes stay within them). */
  version_scopes: Schema.Array(Schema.String),
  version_optional_scopes: Schema.Array(Schema.String),
  bundle_url: Schema.String,
  bundle_sha256: Schema.String,
  app_revision: Schema.String,
  installed_by: Schema.String,
  installed_at: Schema.Int,
  updated_at: Schema.Int,
  /**
   * Hidden by the user: the app still runs and answers granted calls; clients
   * drop its sidebar, palette and menu entries. Not disable, not remove.
   */
  hidden: Schema.Boolean,
  /** A first-party app installed for everyone by default (nothing is recorded until the user changes it). */
  by_default: Schema.optionalKey(Schema.Boolean)
}).annotate({ identifier: "AppInstall" })
export type AppInstall = typeof AppInstall.Type

export const ApprovalId = Schema.String.check(Schema.isPattern(/^appr_[a-z0-9]{20}$/)).annotate({
  identifier: "ApprovalId",
  description: "A pending request by an agent that a human decides (D48)."
})

/** An agent's install or scope growth, held until the user (or a team admin) decides. */
export const AppApproval = Schema.Struct({
  id: ApprovalId,
  kind: Schema.Literals(["install", "update"]),
  app: AppId,
  scope: InstallScope,
  version: AppVersion,
  version_range: VersionRange,
  /** The scopes the install would hold after approval; `added` are the new ones the human is asked about. */
  scopes: Schema.Array(Schema.String),
  added: Schema.Array(Schema.String),
  /** The installed version the request was based on (null = not installed); approval is refused if it changed. */
  base_version: Schema.NullOr(AppVersion),
  requested_by: Schema.Struct({ identity: Schema.String, install: Schema.NullOr(Schema.String), agent: Schema.NullOr(Schema.String), origin: Schema.String }),
  status: Schema.Literals(["pending", "approved", "denied", "expired"]),
  created_at: Schema.Int,
  expires_at: Schema.Int,
  decided_by: Schema.NullOr(Schema.String),
  decided_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "AppApproval" })
export type AppApproval = typeof AppApproval.Type

/** Team app policy (spec section 10 "Team admins can restrict installs to tiers or an allowlist"). */
export const AppPolicy = Schema.Struct({
  /** Null = every tier except `unverified` (a team admits unverified apps only by listing the tier). */
  allowed_tiers: Schema.NullOr(Schema.Array(AppTier)),
  /** Null = any app the tiers allow; a list = only these app ids. */
  allowlist: Schema.NullOr(Schema.Array(AppId)),
  blocklist: Schema.Array(AppId)
}).annotate({ identifier: "AppPolicy" })
export type AppPolicy = typeof AppPolicy.Type

/** Result of app.install and app.update: done, or held for a human (actor is an agent). */
export const AppInstallOutcome = Schema.Union([
  Schema.Struct({ status: Schema.Literal("installed"), install: AppInstall }),
  Schema.Struct({ status: Schema.Literal("approval_required"), approval: AppApproval })
]).annotate({ identifier: "AppInstallOutcome" })

/** Manifest essentials the registry checks (full schema: cmux-app.schema.json, contract "Manifest"). */
export const ManifestEssentials = Schema.Struct({
  manifestVersion: Schema.Literal(1),
  id: AppId,
  name: Schema.Union([NonEmptyText(80), Schema.Record(Schema.String, NonEmptyText(80))]),
  version: AppVersion,
  description: Text(500),
  publisher: Schema.Struct({ name: NonEmptyText(80), url: Schema.optionalKey(Text(300)) }),
  repository: Schema.optionalKey(Text(300)),
  categories: Schema.optionalKey(Schema.Array(NonEmptyText(32)).check(Schema.isMaxLength(8))),
  engines: Schema.Struct({ cmux: VersionRange }),
  scopes: Schema.Record(Schema.String, NonEmptyText(300)),
  optionalScopes: Schema.optionalKey(Schema.Record(Schema.String, NonEmptyText(300)))
}).annotate({ identifier: "ManifestEssentials" })
export type ManifestEssentials = typeof ManifestEssentials.Type
