import { createHash } from "node:crypto"
import type { Domain, OutboxItem, Principal, ReduceResult } from "@cmux/ownership"
import { InstallRegister, InstallRename, InstallRevoke, type CloudOpDef, type Grant, type Install, type UserProfile as UserProfileSchema } from "@cmux/protocol"
import { admit, decodeParams, InstallRegisterServerParams, reject } from "./common.ts"
import { reducePushTarget, type PushTargetsState } from "./user-push.ts"
import { user as homeUser } from "@cmux/home-core"
import { confirmEnv, PREVIOUS_EMAIL_WINDOW_MS, reduceConfirm, revokePresenceKey, USER_CONFIRM_OPS } from "./user-confirm.ts"
import { chiefActive, CHIEF_OPS, reduceChief, type ChiefsState } from "./user-chief.ts"

type UserProfile = typeof UserProfileSchema.Type
type Mutable<T> = { -readonly [K in keyof T]: T[K] }

/** Most teams one user's index holds (the user head is one SQLite row). */
export const MAX_TEAM_INDEX = 1_000
const TEAM_ROLES: ReadonlySet<string> = new Set(["owner", "admin", "member"])
const TEAM_KINDS: ReadonlySet<string> = new Set(["personal", "stack"])

export interface UserState extends PushTargetsState, ChiefsState {
  readonly user: UserProfile | null
  /** Text confirmation level and presence keys (home-core user/), absent until first used. */
  readonly confirm?: homeUser.UserConfirmState
  /** Home settings (home-messaging.md section 4.2), absent until the first home.settings.set. */
  readonly home_settings?: homeUser.HomeSettings
  readonly installs: Readonly<Record<string, typeof Install.Type>>
  readonly grants: Readonly<Record<string, typeof Grant.Type>>
  /** One-time migrations already done on this user (CLOUD-LINK-FOLLOWUPS decision 2). */
  readonly migrations?: { readonly ios_cloud_link?: true }
  /**
   * Revoked installs whose team SSH certificates still need a KRL entry in each team's TeamDO
   * (plans/cmux-next/team-vm-plan.md S4). UserDO's alarm delivers them and clears each one.
   */
  readonly ssh_revoke_pending?: Readonly<Record<string, { readonly user: string; readonly teams: ReadonlyArray<string>; readonly at: number }>>
  /**
   * Verified addresses this account had before an email change, with the change time (cx-44j.45):
   * security notices also go to each one for PREVIOUS_EMAIL_WINDOW_MS (14 days), so a takeover
   * that starts by changing the email still reaches the owner. Entries past the window are dropped
   * at the next change.
   */
  readonly previous_emails?: ReadonlyArray<{ readonly email: string; readonly changed_at: number }>
  /** The address the last email change replaced, and when (the stale-token guard reads it). */
  readonly last_email_change?: { readonly email: string; readonly at: number }
  /** Every team this user belongs to, written only by that team's TeamDO (user.team_index; DM reach reads it). */
  readonly team_index?: Readonly<Record<string, { readonly role: string; readonly kind: string }>>
}

/** At most this many previous addresses are kept (the earliest win: the owner's address is never evicted). */
export const MAX_PREVIOUS_EMAILS = 5
/** A claim of the address just replaced is ignored this long after a change (older access tokens). */
export const EMAIL_REVERT_GUARD_MS = 15 * 60_000
/** Addresses compare without case or surrounding spaces; mail goes to the address as stored. */
export const sameEmail = (a: string | null | undefined, b: string | null | undefined) => !!a && !!b && a.trim().toLowerCase() === b.trim().toLowerCase()

const hex20 = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 20)

/** Stable public ids derived from the Stack identity, so routing needs no lookup. */
export const userIdFor = (stackProjectId: string, stackUserId: string) => `user_${hex20(`stack:${stackProjectId}:${stackUserId}`)}`
export const personalTeamIdFor = (userId: string) => `team_${hex20(`personal:${userId}`)}`

/** RFC 7638 thumbprint of an EC P-256 JWK. */
export const jwkThumbprint = (jwk: { crv: string; kty: string; x: string; y: string }) =>
  createHash("sha256").update(`{"crv":"${jwk.crv}","kty":"${jwk.kty}","x":"${jwk.x}","y":"${jwk.y}"}`).digest("base64url")

const ALL_CLASSES = ["read", "mutate-own", "mutate-shared", "execute", "send-external", "money", "destructive"] as const
/** An install's default grant: its own user's interactive rights, minus account management (destructive). */
const INSTALL_CLASSES = ["read", "mutate-own", "mutate-shared", "execute"] as const
/** Install kinds only the server creates (CLOUD-LINK-FOLLOWUPS 4). */
const SERVER_INSTALL_KINDS: ReadonlySet<string> = new Set(["vm", "daemon"])

export const grantFor = (state: UserState, p: Principal) => (p.grant ? state.grants[p.grant] : undefined)

/** The old iPhone default (before cloud-link): a grant within it is an unchanged iPhone default. */
const OLD_IOS_CLASSES: ReadonlyArray<string> = ["read", "mutate-own"]
/**
 * When the cloud-link iPhone default landed on feat-cmux-next (2cef2ebaf0a). Only installs made
 * before it are migrated; a later install's grant is what its client asked for (review P2).
 */
export const IOS_CLOUD_LINK_CUTOFF = Date.parse("2026-10-05T00:00:54Z")
/**
 * CLOUD-LINK-FOLLOWUPS (decision 2, 2026-10-05): grants of active ios installs, within the old iPhone
 * default, that lack the narrow cloud-link class. install.ios_cloud_link_migrate adds it to these.
 */
export const iosGrantsToMigrate = (state: UserState): Array<string> =>
  state.migrations?.ios_cloud_link
    ? []
    : Object.values(state.installs)
    .filter((i) => i.kind === "ios" && i.revoked_at === null && i.created_at < IOS_CLOUD_LINK_CUTOFF)
    .map((i) => state.grants[i.grant])
    .filter((g): g is NonNullable<typeof g> => !!g && g.revoked_at === null && !g.op_classes.includes("cloud-link") && g.op_classes.every((c) => OLD_IOS_CLASSES.includes(c)))
    .map((g) => g.id)

/**
 * Inbox calls come from this user only, through an active install whose grant covers the op
 * (the catalog check other owners apply).
 */
export const inboxRefusalFor = (state: UserState, entity: string, principal: Principal, op: string): { code: string; message: string } | undefined => {
  if (principal.user !== entity) return { code: "auth.forbidden", message: "not this user's inbox" }
  if (!userPathAllowed(state, principal)) return { code: "auth.forbidden", message: "install revoked or unknown" }
  return admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
}

/** True when the principal's install exists and is not revoked. */
export const installActive = (state: UserState, p: Principal) => {
  if (p.kind === "session") return true
  const inst = p.install ? state.installs[p.install] : undefined
  if (!inst || inst.revoked_at !== null || inst.grant !== p.grant) return false
  // A chief token (principal.agent): the chief must be this user's and not archived (instant chief revocation).
  return p.agent === undefined || chiefActive(state, p.agent)
}

/** installActive, and not a VM install: a VM install (kind vm) never reads or changes its creator's account (review P1). */
export const userPathAllowed = (state: UserState, p: Principal) => installActive(state, p) && (p.install === undefined || state.installs[p.install]?.kind !== "vm")

/** True for an unarchived chief of this user. */
export { chiefActive }

/**
 * Revokes an install in one commit: the install, its grant and its push targets (so no push
 * reaches a revoked device). Shared by install.revoke, install.sign_out and install.revoke_by_team.
 */
const revokeInstall = (state: UserState, cur: typeof Install.Type, now: number): ReduceResult<UserState> => {
  if (cur.revoked_at !== null) return { ok: true, state, value: cur, changed: false }
  const next = { ...cur, revoked_at: now }
  const g = state.grants[cur.grant]
  // Install tokens carry the personal team; a bound server's team may also have signed for it.
  const teams = state.user ? [...new Set([state.user.personal_team, ...(cur.bound_team ? [cur.bound_team] : [])])] : []
  const pending = teams.length > 0 && state.user ? { ...state.ssh_revoke_pending, [cur.id]: { user: state.user.id, teams, at: now } } : state.ssh_revoke_pending
  return {
    ok: true,
    state: {
      ...revokePresenceKey(state, cur.id, now),
      ...(pending ? { ssh_revoke_pending: pending } : {}),
      push_targets: Object.fromEntries(Object.entries(state.push_targets ?? {}).filter(([, t]) => t.install !== cur.id)),
      installs: { ...state.installs, [cur.id]: next },
      grants: g ? { ...state.grants, [g.id]: { ...g, revoked_at: now } } : state.grants
    },
    value: next,
    outbox: [{ kind: "install.upsert", entity: cur.id, payload: { ...next, public_jwk: undefined, user: state.user?.id } }]
  }
}

/**
 * home-core's caller rules read `install_kind` (owner device = mac or ios install). UserDO owns
 * the installs, so it stamps the kind from its own record, never from the token.
 */
const withInstallKind = (state: UserState, p: Principal): Principal => {
  if (p.kind !== "install" || !p.install) return p
  const kind = state.installs[p.install]?.kind
  return kind ? { ...p, install_kind: kind } : p
}

/**
 * Default grant per install kind: the iPhone app gets read, mutate-own (L14-1) and the narrow
 * cloud-link class (link_token only, CLOUD-LINK-FOLLOWUPS 5); execute and riskier classes need their own grant.
 */
export const defaultInstallClasses = (kind: string): ReadonlyArray<(typeof INSTALL_CLASSES)[number] | "cloud-link" | "vm-self"> =>
  kind === "ios" ? ["read", "mutate-own", "cloud-link"] : kind === "vm" ? ["vm-self"] : INSTALL_CLASSES
const defaultClasses = defaultInstallClasses

export const makeUserDomain = (appIdHash: string): Domain<UserState> => ({
  initial: () => ({ user: null, installs: {}, grants: {} }),

  authorize: (state, op, _params, principal) => {
    // A system principal is built only by server code (a DO, or the Worker for pairing's install.register_server, sent by DO RPC that only Worker code reaches); internal ops only. Also push.target.drop.
    const confirm = USER_CONFIRM_OPS.has(op)
    const confirmRefused = () =>
      confirm && !homeUser.authorizeUserConfirm(op, withInstallKind(state, principal), confirmEnv(state, appIdHash, Date.now())) ? { code: "auth.forbidden", message: `${op} is not allowed for this caller` } : undefined
    if (principal.kind === "system") return admit("cloud:UserDO", op, principal, () => undefined, Date.now()) ?? confirmRefused()
    if (state.user && principal.user !== state.user.id) return { code: "auth.forbidden", message: "not this user" }
    if (!userPathAllowed(state, principal)) return { code: "auth.forbidden", message: "install revoked or unknown" }
    return admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now()) ?? confirmRefused()
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    if (CHIEF_OPS.has(op)) return reduceChief(state, op, (params ?? {}) as Record<string, unknown>, ctx)
    if (USER_CONFIRM_OPS.has(op)) return reduceConfirm(state, op, params, { ...ctx, principal: withInstallKind(state, p) }, appIdHash)
    switch (op) {
      case "user.ensure": {
        if (!p.user || !p.stack_user_id || !p.team) return reject("auth.forbidden", "user.ensure needs a Stack session")
        const claimed: UserProfile = {
          id: p.user,
          stack_user_id: p.stack_user_id,
          email: p.email ?? null,
          email_verified: p.email_verified === true,
          display_name: p.display_name ?? p.email?.split("@")[0] ?? "cmux user",
          personal_team: p.team
        }
        // A token minted before an email change still carries the old email until it expires
        // (minutes). Within EMAIL_REVERT_GUARD_MS of a change, a claim of the address just
        // replaced keeps the current email, so devices with older tokens cannot flap it.
        const last = state.last_email_change
        const stale = state.user !== null && last !== undefined && ctx.now < last.at + EMAIL_REVERT_GUARD_MS && sameEmail(claimed.email, last.email)
        const profile: UserProfile = stale && state.user
          ? { ...claimed, email: state.user.email, email_verified: state.user.email_verified, display_name: p.display_name ?? state.user.display_name }
          : claimed
        const same = JSON.stringify(state.user) === JSON.stringify(profile)
        // A verified address that is replaced (or stops being verified) keeps getting security
        // notices for 14 days (cx-44j.45); a replaced one is also told of the change (never the new
        // address). Earliest entries are kept, so later changes cannot evict the owner's address.
        const oldVerified = state.user?.email_verified && state.user.email ? state.user.email : null
        const newVerified = profile.email_verified && profile.email ? profile.email : null
        let next: UserState = { ...state, user: profile }
        let notices: ReadonlyArray<OutboxItem> = []
        if (oldVerified && !sameEmail(oldVerified, newVerified)) {
          // The replaced address always stays (its window starts now); the others keep their
          // times, and when the list is full the newest of them go, never the earliest.
          const others = (state.previous_emails ?? [])
            .filter((e) => ctx.now < e.changed_at + PREVIOUS_EMAIL_WINDOW_MS && !sameEmail(e.email, newVerified) && !sameEmail(e.email, oldVerified))
            .sort((a, b) => a.changed_at - b.changed_at)
            .slice(0, MAX_PREVIOUS_EMAILS - 1)
          next = { ...next, previous_emails: [...others, { email: oldVerified, changed_at: ctx.now }], last_email_change: { email: oldVerified, at: ctx.now } }
          // The same mailbox in other letter case is no change of address: no notice.
          if (!sameEmail(oldVerified, profile.email)) {
            notices = homeUser.emailChangedNotice({ user: profile.id, locale: "en", emails: [oldVerified, ...others.map((e) => e.email)] }, ctx.now)
          }
        }
        return {
          ok: true,
          state: next,
          value: profile,
          changed: !same,
          outbox: same ? [] : [{ kind: "user.upsert", entity: profile.id, payload: profile }, ...notices]
        }
      }
      case "install.register":
      case "install.register_server": {
        if (!state.user) return reject("validation.invalid", "call user.ensure first")
        const d = op === "install.register_server" ? decodeParams<typeof InstallRegisterServerParams.Type>({ params: InstallRegisterServerParams } as unknown as CloudOpDef, params) : decodeParams<typeof InstallRegister.params.Type>(InstallRegister, params)
        if (!d.ok) return d
        const v = d.value as typeof InstallRegisterServerParams.Type
        // Server kinds are created only by the server (pairing, Cloud bind), never declared by a client.
        const reserved = SERVER_INSTALL_KINDS.has(v.kind)
        if (op === "install.register" && reserved) return reject("install.kind_reserved", `install kind ${v.kind} is created by the server, not registered by a client`)
        if (op === "install.register_server" && (!reserved || p.kind !== "system")) return reject("validation.invalid", "install.register_server takes only a server kind from the server")
        // A VM install speaks for exactly one machine; no other install names one.
        if ((v.kind === "vm") !== (v.bound_machine !== undefined) || (v.kind === "vm" && v.bound_team === undefined)) return reject("validation.invalid", "a vm install names its bound team and machine; no other install does")
        const thumbprint = jwkThumbprint(v.public_jwk)
        if (Object.values(state.installs).some((i) => i.thumbprint === thumbprint && i.revoked_at === null)) {
          return reject("validation.invalid", "this public key is already registered")
        }
        const install = ctx.newId("inst")
        const grant = ctx.newId("grant")
        const device = v.device ?? ctx.newId("dev")
        // A caller may narrow the default grant (a paired server asks for read and mutate-own), never widen it.
        const allowed = defaultClasses(v.kind)
        const requested = v.op_classes ?? allowed
        if (requested.some((c) => !(allowed as ReadonlyArray<string>).includes(c))) return reject("validation.invalid", "op_classes may only narrow the default install grant")
        const g: typeof Grant.Type = {
          id: grant,
          grantee: install,
          op_classes: [...new Set(requested)],
          approval: "none",
          expires_at: null,
          revoked_at: null,
          created_from: "install"
        }
        const i: typeof Install.Type = {
          id: install,
          device,
          kind: v.kind,
          name: v.name,
          device_name: v.device_name,
          platform: v.platform,
          ...((p.kind === "session" || (op === "install.register_server" && p.kind === "system")) && p.sso_team ? { sso_team: p.sso_team } : {}),
          public_jwk: v.public_jwk,
          thumbprint,
          grant,
          created_at: ctx.now,
          revoked_at: null,
          ...(v.bound_team ? { bound_team: v.bound_team } : {}),
          ...(v.bound_machine ? { bound_machine: v.bound_machine } : {}),
          ...(v.capabilities?.length ? { capabilities: [...v.capabilities] } : {})
        }
        return {
          ok: true,
          state: { ...state, installs: { ...state.installs, [install]: i }, grants: { ...state.grants, [grant]: g } },
          value: i,
          outbox: [{ kind: "install.upsert", entity: install, payload: { ...i, public_jwk: undefined, user: state.user.id } }]
        }
      }
      case "install.ios_cloud_link_migrate": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        const ids = iosGrantsToMigrate(state)
        if (state.migrations?.ios_cloud_link) return { ok: true, state, value: { migrated: 0 }, changed: false }
        const grants = { ...state.grants }
        for (const id of ids) grants[id] = { ...grants[id]!, op_classes: [...grants[id]!.op_classes, "cloud-link"] }
        // Done once per user: later iPhone installs keep the grant their client asked for.
        return { ok: true, state: { ...state, grants, migrations: { ...state.migrations, ios_cloud_link: true } }, value: { migrated: ids.length } }
      }
      case "install.rename": {
        const d = decodeParams<typeof InstallRename.params.Type>(InstallRename, params)
        if (!d.ok) return d
        const cur = state.installs[d.value.install]
        if (!cur) return reject("selector.not_found", "install not found")
        // Single writer: an install renames only itself; the human session may rename any.
        if (p.kind !== "session" && p.install !== cur.id) return reject("auth.forbidden", "an install may rename only itself", { owner: cur.id })
        if (cur.revoked_at !== null) return reject("validation.invalid", "install is revoked")
        const next: Mutable<typeof Install.Type> = { ...cur, name: d.value.name }
        if (cur.name === next.name) return { ok: true, state, value: cur, changed: false }
        return {
          ok: true,
          state: { ...state, installs: { ...state.installs, [cur.id]: next } },
          value: next,
          outbox: [{ kind: "install.upsert", entity: cur.id, payload: { ...next, public_jwk: undefined, user: state.user?.id } }]
        }
      }
      case "install.revoke_by_team": {
        // Only the bound team's TeamDO (system:team:<team>), when that team revoked the server.
        const v = params as { install: string; team: string; by: string }
        if (p.kind !== "system" || p.identity !== `system:team:${v.team}`) return reject("auth.forbidden", "internal op of the bound team")
        const cur = state.installs[v.install]
        if (!cur) return reject("selector.not_found", "install not found")
        if (cur.bound_team !== v.team) return reject("auth.forbidden", "install is not bound to this team")
        return revokeInstall(state, cur, ctx.now)
      }
      case "user.team_left": {
        // Only the team's own TeamDO (system:team:<id>) after it removed this user (cx-44j.47).
        const { team, at } = (params ?? {}) as { team?: unknown; at?: unknown }
        if (typeof team !== "string" || p.kind !== "system" || p.identity !== `system:team:${team}`) return reject("auth.forbidden", "internal op of the team's TeamDO")
        // Only installs that existed at the removal: a late delivery after a re-join keeps the new ones.
        const before = typeof at === "number" ? at : ctx.now
        let next = state
        const outbox: Array<OutboxItem> = []
        const revoked: Array<string> = []
        for (const cur of Object.values(state.installs)) {
          // Bound to the team, or authorized by the team's SSO: no authority derived from the team survives the removal.
          // (an install bound to another team, such as that team's VM, keeps the other team's authority).
          const fromTeam = cur.bound_team === team || (cur.bound_team === undefined && cur.sso_team === team)
          if (!fromTeam || cur.revoked_at !== null || cur.created_at > before) continue
          const r = revokeInstall(next, next.installs[cur.id]!, ctx.now)
          if (!r.ok) return r
          next = r.state
          outbox.push(...(r.outbox ?? []))
          revoked.push(cur.id)
        }
        if (revoked.length === 0) return { ok: true, state, value: { revoked }, changed: false }
        return { ok: true, state: next, value: { revoked }, outbox }
      }
      case "user.team_index": {
        // Only the team's own TeamDO (its outbox delivers as system:team:<id>) indexes that team.
        const v = params as { team?: unknown; role?: unknown; kind?: unknown }
        if (typeof v.team !== "string" || p.kind !== "system" || p.identity !== `system:team:${v.team}`) return reject("auth.forbidden", "internal op of the team's TeamDO")
        const cur = state.team_index?.[v.team]
        if (v.role === null) {
          if (!cur) return { ok: true, state, value: null, changed: false }
          const { [v.team]: _gone, ...rest } = state.team_index ?? {}
          return { ok: true, state: { ...state, team_index: rest }, value: null }
        }
        if (!TEAM_ROLES.has(v.role as string) || !TEAM_KINDS.has(v.kind as string)) return reject("validation.invalid", "role must be owner, admin or member; kind personal or stack")
        const role = v.role as string
        const kind = v.kind as string
        if (cur && cur.role === role && cur.kind === kind) return { ok: true, state, value: cur, changed: false }
        // The user head is one row: a user in more than MAX_TEAM_INDEX teams is refused (logged by the sender).
        if (!cur && Object.keys(state.team_index ?? {}).length >= MAX_TEAM_INDEX) return reject("user.team_index_full", `a user belongs to at most ${MAX_TEAM_INDEX} teams`)
        return { ok: true, state: { ...state, team_index: { ...(state.team_index ?? {}), [v.team]: { role, kind } } }, value: { role, kind } }
      }
      case "install.ssh_revoke_done": {
        // UserDO's own alarm, after every team in the notice confirmed the KRL entries.
        if (p.kind !== "system" || p.identity !== "system:user") return reject("auth.forbidden", "internal op of this UserDO")
        const install = (params as { install: string }).install
        if (!state.ssh_revoke_pending?.[install]) return { ok: true, state, value: { install }, changed: false }
        const { [install]: _done, ...rest } = state.ssh_revoke_pending
        return { ok: true, state: { ...state, ssh_revoke_pending: rest }, value: { install } }
      }
      case "install.revoke": {
        const d = decodeParams<typeof InstallRevoke.params.Type>(InstallRevoke, params)
        if (!d.ok) return d
        const cur = state.installs[d.value.install]
        if (!cur) return reject("selector.not_found", "install not found")
        return revokeInstall(state, cur, ctx.now)
      }
      case "install.sign_out": {
        // The calling install only (L14-2): sign-out leaves nothing usable on the device.
        const cur = p.install ? state.installs[p.install] : undefined
        if (!cur || p.kind !== "install") return reject("auth.forbidden", "only an install signs itself out")
        return revokeInstall(state, cur, ctx.now)
      }
      case "home.settings.set": {
        if (p.kind !== "session") return reject("auth.forbidden", "home.settings.set needs a user session")
        const r = homeUser.reduceHomeSettings(state.home_settings, params)
        if (!r.ok) return reject("validation.invalid", r.code)
        if (JSON.stringify(state.home_settings) === JSON.stringify(r.settings)) return { ok: true, state, value: r.settings, changed: false }
        return { ok: true, state: { ...state, home_settings: r.settings }, value: r.settings }
      }
      case "push.target.register":
      case "push.target.remove":
      case "push.target.drop":
        return reducePushTarget(state, op, params, ctx)
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
})

/** The domain without an App Attest app id (tests, and deployments where IOS_APP_ID is unset). */
export const userDomain = makeUserDomain("")

export { ALL_CLASSES }
