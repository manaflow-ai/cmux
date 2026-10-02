import { Schema } from "effect"
import {
  AppApproval,
  AppId,
  AppInstall,
  AppInstallOutcome,
  AppListing,
  AppPolicy,
  AppScope,
  AppTier,
  AppVersion,
  ApprovalId,
  InstallScope,
  VersionRange
} from "./apps.ts"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { Revision } from "./schemas.ts"

/**
 * App store ops (spec app-platform.md section 11, contract v1 "Store ops").
 * CLI path `apps <verb>` (the Rust CLI reserves `app` for the running cmux app). MCP: search/info/list by default,
 * remove opt-in, everything that publishes, grants, yanks or decides never.
 *
 * Phase 1 (Lawrence, 2026-10-02): app.install, scope-growing app.update and
 * app.approval.decide answer `app.install.user_only` unless origin is
 * `user` (the App Store in the app or the web store); not MCP tools. The
 * approval path below stays in code and reopens when owners stamp the actor.
 *
 * Agents (D48, later): when the actor is an agent (an `agent` principal or a request
 * with origin `mcp`), `app.install` and any `app.update` that grows the scope
 * set do not apply; they return `{status: "approval_required", approval}` and
 * store the request in the owner. A human decides it with the session-only
 * `app.approval.decide`; the owner re-resolves the release then, so a version
 * yanked in between is refused.
 */

const scopeOwners = { user: "cloud:UserDO", team: "cloud:TeamDO" } as const
const ScopeParam = Schema.optionalKey(InstallScope.annotate({ description: "Whose set: the caller's (user, default) or the caller's team (team; team admins)." }))
const Scopes = Schema.Array(AppScope).check(Schema.isMaxLength(64))

const InstallsView = Schema.Struct({
  installs: Schema.Array(AppInstall),
  approvals: Schema.Array(AppApproval),
  policy: Schema.NullOr(AppPolicy),
  /** Scope all: each owner's revision (the envelope's `revision` is the user one). */
  revisions: Schema.optionalKey(Schema.Struct({ user: Schema.optionalKey(Revision), team: Schema.optionalKey(Revision) }))
}).annotate({ identifier: "AppInstallsView" })

export const AppSearch = def({
  name: "app.search",
  owner: "cloud:planetscale",
  class: "read",
  risk: "read",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({
    query: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200))),
    category: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(32))),
    tier: Schema.optionalKey(AppTier),
    limit: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 50 }))),
    cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(32)))
  }),
  result: Schema.Struct({ apps: Schema.Array(AppListing), next_cursor: Schema.NullOr(Schema.String) }),
  errors: ["auth.unauthenticated", "validation.invalid", "owner.unreachable"],
  docs: "Search the app store (word-prefix match on name, id, publisher and description). Unverified apps are never listed. Reads the PlanetScale projection, so a new release can take a moment to appear.",
  cli: { path: "apps search", visible: true },
  mcp: { expose: "default", group: "app" }
})

export const AppInfo = def({
  name: "app.info",
  owner: "cloud:AppDO",
  class: "read",
  risk: "read",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({ app: AppId, version: Schema.optionalKey(AppVersion) }),
  result: AppListing,
  errors: ["auth.unauthenticated", "selector.not_found"],
  docs: "Read one app's listing with its versions (scopes with reasons, engines, yanks). `version` narrows `versions` to that one.",
  cli: { path: "apps info", visible: true },
  mcp: { expose: "default", group: "app" }
})

export const AppList = def({
  name: "app.list",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "read",
  risk: "read",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({ scope: Schema.optionalKey(Schema.Literals(["user", "team", "all"])) }),
  result: InstallsView,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List installed apps (with `hidden`; first-party apps installed by default carry `by_default`) and pending approvals: the caller's (user), the team's (team, with the team app policy) or both (all, default).",
  cli: { path: "apps list", visible: true },
  mcp: { expose: "default", group: "app" }
})

export const AppInstallOp = def({
  name: "app.install",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "mutation",
  risk: "mutate-own",
  teamRisk: "mutate-shared",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({
    app: AppId,
    version_range: Schema.optionalKey(VersionRange),
    scopes: Scopes,
    scope: ScopeParam,
    accept_unverified: Schema.optionalKey(Schema.Boolean)
  }),
  result: AppInstallOutcome,
  errors: [...mutationErrors, "app.install.user_only", "selector.not_found", "app.yanked", "app.unverified", "scope.invalid", "policy.denied", "approval.limit"],
  docs: "Install an app: the newest non-yanked version in `version_range` (default any), granting `scopes` (every required scope, plus any optional ones). Team installs (risk mutate-shared) need a team admin and pass the team app policy. Phase 1: origin user only (the App Store); other origins and agents get app.install.user_only.",
  cli: { path: "apps install", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppUpdate = def({
  name: "app.update",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "mutation",
  risk: "mutate-own",
  teamRisk: "mutate-shared",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({
    app: AppId,
    version: Schema.optionalKey(AppVersion),
    accept_scopes: Schema.optionalKey(Scopes),
    scope: ScopeParam
  }),
  result: AppInstallOutcome,
  errors: [...mutationErrors, "app.install.user_only", "selector.not_found", "app.yanked", "scope.consent_required", "scope.invalid", "policy.denied", "approval.limit"],
  docs: "Move an installed app to `version` (default: newest non-yanked in its range). New required scopes must be in `accept_scopes`. Phase 1: an update that grows the scope set needs origin user (else app.install.user_only).",
  cli: { path: "apps update", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppRemove = def({
  name: "app.remove",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "mutation",
  risk: "mutate-own",
  teamRisk: "mutate-shared",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({ app: AppId, scope: ScopeParam }),
  result: Schema.Struct({ app: AppId, removed: Schema.Boolean }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove an installed app and its grant. A first-party app installed by default stays removed until installed again.",
  cli: { path: "apps remove", visible: true },
  mcp: { expose: "opt_in", group: "app" }
})

const hideOp = (name: "app.hide" | "app.unhide", verb: "hide" | "unhide", docs: string) =>
  def({
    name,
    owner: "cloud:UserDO",
    class: "mutation",
    risk: "mutate-own",
    target: "app",
    principals: ["session", "install"],
    params: Schema.Struct({ app: AppId }),
    result: Schema.Struct({ app: AppId, hidden: Schema.Boolean }),
    errors: [...mutationErrors, "selector.not_found"],
    docs,
    cli: { path: `apps ${verb}`, visible: true },
    mcp: { expose: "opt_in", group: "app" }
  })

/** Hiding grants nothing, so any origin may do it (no user-origin requirement). Personal installs only for now. */
export const AppHide = hideOp(
  "app.hide",
  "hide",
  "Hide an installed app (personal installs, including first-party apps installed by default): it keeps running and answering granted calls, and clients drop its sidebar, palette and menu entries. Idempotent."
)
export const AppUnhide = hideOp("app.unhide", "unhide", "Show a hidden app's entries again. Idempotent.")

export const AppGrantSet = def({
  name: "app.grant.set",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "mutation",
  risk: "mutate-own",
  teamRisk: "mutate-shared",
  target: "app",
  principals: ["session"],
  params: Schema.Struct({ app: AppId, scopes: Scopes, scope: ScopeParam }),
  result: AppInstall,
  errors: [...mutationErrors, "selector.not_found", "scope.invalid"],
  docs: "Set an installed app's granted scopes (every required scope, plus optional ones). Human sessions with origin user only.",
  cli: { path: "apps grant", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppApprovalDecide = def({
  name: "app.approval.decide",
  owner: "cloud:UserDO",
  scopeOwners,
  class: "mutation",
  risk: "mutate-own",
  teamRisk: "mutate-shared",
  target: "app",
  principals: ["session"],
  params: Schema.Struct({ approval: ApprovalId, decision: Schema.Literals(["approve", "deny"]), scope: ScopeParam }),
  result: Schema.Struct({ approval: AppApproval, install: Schema.NullOr(AppInstall) }),
  errors: [...mutationErrors, "app.install.user_only", "selector.not_found", "approval.decided", "approval.stale", "app.yanked", "policy.denied"],
  docs: "Approve or deny an agent's pending app install or scope growth. Human sessions only, never from an MCP client. An expired request is marked expired (status in the result); a request whose install changed since is refused as stale.",
  cli: { path: "apps approval decide", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppPolicySet = def({
  name: "app.policy.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    allowed_tiers: Schema.optionalKey(Schema.NullOr(Schema.Array(AppTier))),
    allowlist: Schema.optionalKey(Schema.NullOr(Schema.Array(AppId).check(Schema.isMaxLength(500)))),
    blocklist: Schema.optionalKey(Schema.Array(AppId).check(Schema.isMaxLength(500)))
  }),
  result: AppPolicy,
  errors: [...mutationErrors],
  docs: "Change the team app policy (team admins): allowed tiers, allowlist, blocklist. Applies to later team installs, updates and approvals.",
  cli: { path: "apps policy set", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppVersionSubmit = def({
  name: "app.version.submit",
  owner: "cloud:AppDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({
    repo: Schema.String.check(Schema.isMaxLength(300)),
    tag: Schema.String.check(Schema.isMaxLength(80)),
    manifest: Schema.Unknown,
    bundle_url: Schema.String.check(Schema.isMaxLength(1000)),
    bundle_sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
    attestation_digest: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200)))
  }),
  result: AppListing,
  errors: [...mutationErrors, "app.claim_forbidden", "app.not_publisher", "version.exists", "version.limit", "manifest.invalid"],
  docs: "Register a release: the manifest at tag `v<version>` of a public GitHub repository owned by the app's publisher. A version is never reused, even after a yank; build metadata (`+…`) is refused. At most 100 versions per app for now.",
  cli: { path: "apps publish", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppVersionYank = def({
  name: "app.version.yank",
  owner: "cloud:AppDO",
  class: "mutation",
  risk: "destructive",
  target: "app",
  principals: ["session", "install"],
  params: Schema.Struct({ app: AppId, version: AppVersion, reason: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(500)) }),
  result: AppListing,
  errors: [...mutationErrors, "selector.not_found", "app.not_publisher"],
  docs: "Yank a version (its publisher or cmux staff). Clients on it move to the newest non-yanked compatible version or disable the app with the reason.",
  cli: { path: "apps yank", visible: true },
  mcp: { expose: "never", group: "app" }
})

export const AppListingSetTier = def({
  name: "app.listing.set_tier",
  owner: "cloud:AppDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "app",
  principals: ["session"],
  params: Schema.Struct({ app: AppId, tier: AppTier }),
  result: AppListing,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Set an app's review tier. cmux staff only (APP_STORE_STAFF); first-party only for reserved publishers.",
  cli: { path: "apps tier", visible: false },
  mcp: { expose: "never", group: "app" }
})

export const appOps = [
  AppSearch,
  AppInfo,
  AppList,
  AppInstallOp,
  AppUpdate,
  AppRemove,
  AppHide,
  AppUnhide,
  AppGrantSet,
  AppApprovalDecide,
  AppPolicySet,
  AppVersionSubmit,
  AppVersionYank,
  AppListingSetTier
] as const satisfies ReadonlyArray<CloudOpDef>
