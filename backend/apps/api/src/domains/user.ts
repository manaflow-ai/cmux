import { createHash } from "node:crypto"
import type { Domain, Principal, ReduceResult } from "@cmux/ownership"
import { InstallRegister, InstallRename, InstallRevoke, type Grant, type Install, type UserProfile as UserProfileSchema } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"
import { reducePushTarget, type PushTargetsState } from "./user-push.ts"

type UserProfile = typeof UserProfileSchema.Type
type Mutable<T> = { -readonly [K in keyof T]: T[K] }

export interface UserState extends PushTargetsState {
  readonly user: UserProfile | null
  readonly installs: Readonly<Record<string, typeof Install.Type>>
  readonly grants: Readonly<Record<string, typeof Grant.Type>>
}

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

export const grantFor = (state: UserState, p: Principal) => (p.grant ? state.grants[p.grant] : undefined)

/** True when the principal's install exists and is not revoked. */
export const installActive = (state: UserState, p: Principal) => {
  if (p.kind === "session") return true
  const inst = p.install ? state.installs[p.install] : undefined
  return Boolean(inst && inst.revoked_at === null && inst.grant === p.grant)
}

/**
 * Revokes an install in one commit: the install, its grant and its push targets (so no push
 * reaches a revoked device). Shared by install.revoke, install.sign_out and install.revoke_by_team.
 */
const revokeInstall = (state: UserState, cur: typeof Install.Type, now: number): ReduceResult<UserState> => {
  if (cur.revoked_at !== null) return { ok: true, state, value: cur, changed: false }
  const next = { ...cur, revoked_at: now }
  const g = state.grants[cur.grant]
  return {
    ok: true,
    state: {
      ...state,
      push_targets: Object.fromEntries(Object.entries(state.push_targets ?? {}).filter(([, t]) => t.install !== cur.id)),
      installs: { ...state.installs, [cur.id]: next },
      grants: g ? { ...state.grants, [g.id]: { ...g, revoked_at: now } } : state.grants
    },
    value: next,
    outbox: [{ kind: "install.upsert", entity: cur.id, payload: { ...next, public_jwk: undefined, user: state.user?.id } }]
  }
}

/** Default grant per install kind: the iPhone app gets read and mutate-own (L14-1); execute and riskier classes need their own grant. */
const defaultClasses = (kind: string): ReadonlyArray<(typeof INSTALL_CLASSES)[number]> => (kind === "ios" ? ["read", "mutate-own"] : INSTALL_CLASSES)

export const userDomain: Domain<UserState> = {
  initial: () => ({ user: null, installs: {}, grants: {} }),

  authorize: (state, op, _params, principal) => {
    // A system principal exists only inside a DO (TeamDO's revoke of a bound install); internal ops only. Also push.target.drop.
    if (principal.kind === "system") return admit("cloud:UserDO", op, principal, () => undefined, Date.now())
    if (state.user && principal.user !== state.user.id) return { code: "auth.forbidden", message: "not this user" }
    if (!installActive(state, principal)) return { code: "auth.forbidden", message: "install revoked or unknown" }
    return admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "user.ensure": {
        if (!p.user || !p.stack_user_id || !p.team) return reject("auth.forbidden", "user.ensure needs a Stack session")
        const profile: UserProfile = {
          id: p.user,
          stack_user_id: p.stack_user_id,
          email: p.email ?? null,
          email_verified: p.email_verified === true,
          display_name: p.display_name ?? p.email?.split("@")[0] ?? "cmux user",
          personal_team: p.team
        }
        const same = JSON.stringify(state.user) === JSON.stringify(profile)
        return {
          ok: true,
          state: { ...state, user: profile },
          value: profile,
          changed: !same,
          outbox: same ? [] : [{ kind: "user.upsert", entity: profile.id, payload: profile }]
        }
      }
      case "install.register": {
        if (!state.user) return reject("validation.invalid", "call user.ensure first")
        const d = decodeParams<typeof InstallRegister.params.Type>(InstallRegister, params)
        if (!d.ok) return d
        const v = d.value
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
          public_jwk: v.public_jwk,
          thumbprint,
          grant,
          created_at: ctx.now,
          revoked_at: null,
          ...(v.bound_team ? { bound_team: v.bound_team } : {})
        }
        return {
          ok: true,
          state: { ...state, installs: { ...state.installs, [install]: i }, grants: { ...state.grants, [grant]: g } },
          value: i,
          outbox: [{ kind: "install.upsert", entity: install, payload: { ...i, public_jwk: undefined, user: state.user.id } }]
        }
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
      case "push.target.register":
      case "push.target.remove":
      case "push.target.drop":
        return reducePushTarget(state, op, params, ctx)
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}

export { ALL_CLASSES }
