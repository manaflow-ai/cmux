import type { Domain, OutboxItem, Principal } from "@cmux/ownership"
import {
  AppListingSetTier,
  AppVersionSubmit,
  AppVersionYank,
  ManifestEssentials,
  SCOPE_PATTERN,
  type AppListing,
  type AppTier,
  type AppVersionRecord,
  type ResolvedRelease
} from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { admit, decodeParams, reject } from "./common.ts"
import { compareVersions, isValidRange, maxSatisfying } from "./semver.ts"

/**
 * AppDO: one object per app id. Owns the listing (publisher, repository,
 * current metadata, tier) and every version with its yank state (spec
 * app-platform.md section 11). Pure reducer; deployment facts (environment,
 * staff allowlist) come in through `AppConfig`, and the object's own app id
 * through `params.resolved.entity` (ownership engine `SubmitOptions`), never
 * from the client.
 */

export interface AppListingState {
  readonly id: string
  readonly name: string
  readonly description: string
  readonly publisher: { readonly name: string; readonly github_owner: string; readonly verified: boolean }
  readonly publisher_team: string
  readonly repository: string
  readonly categories: ReadonlyArray<string>
  readonly tier: AppTier
  readonly latest_version: string | null
  readonly claimed_by: string
  readonly created_at: number
  readonly updated_at: number
}

export interface AppState {
  readonly listing: AppListingState | null
  readonly versions: Readonly<Record<string, AppVersionRecord>>
}

export interface AppConfig {
  /** Worker ENVIRONMENT: ids may be claimed freely only in development, local and test. */
  readonly environment: string
  /** User ids of cmux staff (APP_STORE_STAFF): claim any id, yank any version, set tiers. */
  readonly staff: ReadonlySet<string>
}

/** First-party publishers: only staff claim their ids; their apps are `first-party`. */
export const RESERVED_PUBLISHERS: ReadonlySet<string> = new Set(["cmux", "manaflow-ai"])
const OPEN_CLAIM_ENVIRONMENTS: ReadonlySet<string> = new Set(["development", "local", "test"])
const MANIFEST_MAX_BYTES = 64 * 1024
const jsonBytes = (v: unknown) => new TextEncoder().encode(JSON.stringify(v) ?? "").length

const isStaff = (config: AppConfig, p: Principal) => p.kind === "session" && Boolean(p.user && config.staff.has(p.user))

/** `https://github.com/<owner>/<repo>` (optionally `.git` or a trailing slash) -> lowercased parts. */
export const parseGithubRepo = (url: string): { owner: string; repo: string } | null => {
  const m = /^https:\/\/github\.com\/([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100}?)(?:\.git)?\/?$/.exec(url)
  return m ? { owner: m[1]!.toLowerCase(), repo: m[2]!.toLowerCase() } : null
}

const entityOf = (params: unknown): string | undefined => {
  const r = (params as { resolved?: { entity?: unknown } } | null)?.resolved
  return typeof r?.entity === "string" ? r.entity : undefined
}

const displayName = (name: ManifestEssentials["name"]): string => (typeof name === "string" ? name : (name.en ?? Object.values(name)[0] ?? ""))

/** Newest non-yanked version, prereleases only when nothing else exists. */
export const latestOf = (versions: Readonly<Record<string, AppVersionRecord>>): string | null => {
  const live = Object.values(versions).filter((v) => !v.yanked).map((v) => v.version)
  return maxSatisfying(live, "*") ?? live.sort(compareVersions).at(-1) ?? null
}

export const listingView = (state: AppState, installCount = 0, withVersions?: { only?: string }): AppListing | null => {
  const l = state.listing
  if (!l) return null
  const versions = Object.values(state.versions)
    .filter((v) => withVersions?.only === undefined || v.version === withVersions.only)
    .sort((a, b) => compareVersions(b.version, a.version))
  return {
    id: l.id,
    name: l.name,
    description: l.description,
    publisher: l.publisher,
    repository: l.repository,
    icon_url: null,
    categories: [...l.categories],
    tier: l.tier,
    latest_version: l.latest_version,
    install_count: installCount,
    ...(withVersions ? { versions } : {})
  }
}

/** The release an install resolves to: exact `version`, else the newest non-yanked in `range`. */
export const resolveRelease = (state: AppState, seq: number, sel: { version?: string; range?: string }): ResolvedRelease | null => {
  const l = state.listing
  if (!l) return null
  const ver =
    sel.version !== undefined
      ? state.versions[sel.version]?.version
      : maxSatisfying(
          Object.values(state.versions)
            .filter((v) => !v.yanked)
            .map((v) => v.version),
          sel.range ?? "*"
        )
  const rec = ver === undefined || ver === null ? undefined : state.versions[ver]
  if (!rec) return null
  return {
    app: l.id,
    version: rec.version,
    tier: l.tier,
    publisher_team: l.publisher_team,
    scopes: Object.keys(rec.scopes).sort(),
    optional_scopes: Object.keys(rec.optional_scopes).sort(),
    engines: rec.engines,
    bundle_url: rec.bundle_url,
    bundle_sha256: rec.bundle_sha256,
    yanked: rec.yanked,
    app_revision: String(seq)
  }
}

const listingOutbox = (l: AppListingState): OutboxItem => ({ kind: "app.upsert", entity: l.id, payload: l })

const versionOutbox = (appId: string, v: AppVersionRecord, manifest?: unknown): OutboxItem => ({
  kind: "app_version.upsert",
  entity: `${appId}@${v.version}`,
  payload: { app: appId, ...v, ...(manifest === undefined ? {} : { manifest }) }
})

/** Manifest checks beyond the schema: scope names, overlap, engines range, size. */
const manifestProblems = (m: ManifestEssentials, raw: unknown): Array<string> => {
  const problems: Array<string> = []
  if (jsonBytes(raw) > MANIFEST_MAX_BYTES) problems.push("manifest is larger than 64 KiB")
  const required = Object.keys(m.scopes)
  const optional = Object.keys(m.optionalScopes ?? {})
  for (const s of [...required, ...optional]) if (!SCOPE_PATTERN.test(s)) problems.push(`scope ${JSON.stringify(s)} is not family:detail`)
  for (const s of optional) if (required.includes(s)) problems.push(`scope ${s} is both required and optional`)
  if (required.length + optional.length > 64) problems.push("at most 64 scopes")
  if (!isValidRange(m.engines.cmux)) problems.push(`engines.cmux ${JSON.stringify(m.engines.cmux)} is not a version range`)
  return problems
}

export const makeAppDomain = (config: AppConfig): Domain<AppState> => ({
  initial: () => ({ listing: null, versions: {} }),

  // Reads are public to every authenticated principal; writes check publisher or staff in the reducer.
  authorize: (_state, op, _params, principal) => admit("cloud:AppDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now()),

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    const entity = entityOf(params)
    if (!entity) return reject("validation.invalid", "the owner did not bind this request to an app")
    switch (op) {
      case "app.version.submit": {
        const d = decodeParams<typeof AppVersionSubmit.params.Type>(AppVersionSubmit, params)
        if (!d.ok) return d
        const v = d.value
        const me = Schema.decodeUnknownExit(ManifestEssentials)(v.manifest)
        if (Exit.isFailure(me)) return reject("manifest.invalid", "manifest does not match cmux-app.json essentials", String(me.cause))
        const m = me.value
        if (m.id !== entity) return reject("manifest.invalid", `manifest id ${m.id} is not this app (${entity})`)
        const [publisher] = m.id.split("/") as [string, string]
        if (publisher === "local") return reject("manifest.invalid", "local/ ids are for sideloads and never in the store")
        const repo = parseGithubRepo(v.repo)
        if (!repo) return reject("validation.invalid", "repo must be https://github.com/<owner>/<repo>")
        // The publisher segment is the repository's GitHub owner (spec section 3 rules).
        if (repo.owner !== publisher) return reject("manifest.invalid", `publisher ${publisher} is not the repository owner ${repo.owner}`)
        if (m.repository !== undefined) {
          const declared = parseGithubRepo(m.repository)
          if (!declared || declared.owner !== repo.owner || declared.repo !== repo.repo) return reject("manifest.invalid", "manifest repository differs from repo")
        }
        if (v.tag !== `v${m.version}`) return reject("manifest.invalid", `tag ${v.tag} must be v${m.version}`)
        if (!/^https:\/\//.test(v.bundle_url)) return reject("validation.invalid", "bundle_url must be https")
        const problems = manifestProblems(m, v.manifest)
        if (problems.length > 0) return reject("manifest.invalid", problems.join("; "), { problems })
        if (!p.user || !p.team) return reject("auth.forbidden", "publishing needs a signed-in user")

        const staff = isStaff(config, p)
        let listing = state.listing
        if (!listing) {
          // Id claim. Until publisher verification against the GitHub owner exists (GitHub App or
          // OAuth, spec section 11 "Publisher identity" in TeamDO), only development-like
          // environments and staff may claim; reserved publishers are staff only everywhere.
          if (RESERVED_PUBLISHERS.has(publisher) ? !staff : !(staff || OPEN_CLAIM_ENVIRONMENTS.has(config.environment))) {
            return reject("app.claim_forbidden", `claiming ${m.id} needs a verified publisher (not available yet) or cmux staff`)
          }
          listing = {
            id: m.id,
            name: displayName(m.name),
            description: m.description,
            publisher: { name: m.publisher.name, github_owner: publisher, verified: false },
            publisher_team: p.team,
            repository: `https://github.com/${repo.owner}/${repo.repo}`,
            categories: [...(m.categories ?? [])],
            tier: RESERVED_PUBLISHERS.has(publisher) ? "first-party" : "unverified",
            latest_version: null,
            claimed_by: p.user,
            created_at: ctx.now,
            updated_at: ctx.now
          }
        } else if (listing.publisher_team !== p.team && !staff) {
          return reject("app.not_publisher", "only the publishing team may submit versions of this app")
        } else if (`https://github.com/${repo.owner}/${repo.repo}` !== listing.repository) {
          return reject("manifest.invalid", `this app is published from ${listing.repository}`)
        }
        // Versions are immutable and never reused, also after a yank.
        if (state.versions[m.version]) return reject("version.exists", `version ${m.version} was already published`, { version: m.version })

        const previous = latestOf(state.versions)
        const prevScopes = previous ? Object.keys(state.versions[previous]!.scopes).concat(Object.keys(state.versions[previous]!.optional_scopes)) : []
        const rec: AppVersionRecord = {
          version: m.version,
          tag: v.tag,
          engines: { cmux: m.engines.cmux },
          scopes: { ...m.scopes },
          optional_scopes: { ...(m.optionalScopes ?? {}) },
          added_scopes: Object.keys(m.scopes).concat(Object.keys(m.optionalScopes ?? {})).filter((s) => !prevScopes.includes(s)).sort(),
          bundle_url: v.bundle_url,
          bundle_sha256: v.bundle_sha256,
          attestation_digest: v.attestation_digest ?? null,
          published_at: ctx.now,
          published_by: p.user,
          yanked: false,
          yanked_at: null,
          yank_reason: null
        }
        const versions = { ...state.versions, [rec.version]: rec }
        const latest = latestOf(versions)
        // Listing metadata follows the newest version.
        const newest = latest === rec.version
        const next: AppListingState = {
          ...listing,
          ...(newest ? { name: displayName(m.name), description: m.description, categories: [...(m.categories ?? [])], publisher: { ...listing.publisher, name: m.publisher.name } } : {}),
          latest_version: latest,
          updated_at: ctx.now
        }
        const nextState: AppState = { listing: next, versions }
        return { ok: true, state: nextState, value: listingView(nextState, 0, {}), outbox: [listingOutbox(next), versionOutbox(next.id, rec, v.manifest)] }
      }
      case "app.version.yank": {
        const d = decodeParams<typeof AppVersionYank.params.Type>(AppVersionYank, params)
        if (!d.ok) return d
        const l = state.listing
        if (!l || d.value.app !== entity) return reject("selector.not_found", "app not found")
        const rec = state.versions[d.value.version]
        if (!rec) return reject("selector.not_found", `version ${d.value.version} not found`)
        if (l.publisher_team !== p.team && !isStaff(config, p)) return reject("app.not_publisher", "only the publisher or cmux staff may yank")
        if (rec.yanked) return { ok: true, state, value: listingView(state, 0, {}), changed: false }
        const yanked: AppVersionRecord = { ...rec, yanked: true, yanked_at: ctx.now, yank_reason: d.value.reason }
        const versions = { ...state.versions, [rec.version]: yanked }
        const next: AppListingState = { ...l, latest_version: latestOf(versions), updated_at: ctx.now }
        const nextState: AppState = { listing: next, versions }
        return { ok: true, state: nextState, value: listingView(nextState, 0, {}), outbox: [listingOutbox(next), versionOutbox(l.id, yanked)] }
      }
      case "app.listing.set_tier": {
        const d = decodeParams<typeof AppListingSetTier.params.Type>(AppListingSetTier, params)
        if (!d.ok) return d
        const l = state.listing
        if (!l || d.value.app !== entity) return reject("selector.not_found", "app not found")
        if (!isStaff(config, p)) return reject("auth.forbidden", "only cmux staff may set tiers")
        const reserved = RESERVED_PUBLISHERS.has(l.publisher.github_owner)
        if ((d.value.tier === "first-party") !== reserved) return reject("validation.invalid", reserved ? "reserved publishers are first-party" : "first-party is for reserved publishers only")
        if (l.tier === d.value.tier) return { ok: true, state, value: listingView(state, 0, {}), changed: false }
        const next: AppListingState = { ...l, tier: d.value.tier, updated_at: ctx.now }
        const nextState: AppState = { ...state, listing: next }
        return { ok: true, state: nextState, value: listingView(nextState, 0, {}), outbox: [listingOutbox(next)] }
      }
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
})
