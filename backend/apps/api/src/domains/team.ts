import type { Domain } from "@cmux/ownership"
import { HostEnroll, HostRemove, type Host, type TeamMember } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"

export interface TeamState {
  readonly team: { readonly id: string; readonly kind: "personal" | "stack"; readonly display_name: string } | null
  readonly members: Readonly<Record<string, typeof TeamMember.Type>>
  readonly hosts: Readonly<Record<string, typeof Host.Type>>
}

/**
 * TeamDO's reducer: the account directory (U2). Phase 1 knows personal teams
 * only; Stack teams arrive by webhook ops once the Stack webhook is configured.
 * Grants for team ops are checked by UserDO when it mints the token; TeamDO
 * checks membership and the op's principal kind.
 */
export const teamDomain: Domain<TeamState> = {
  initial: () => ({ team: null, members: {}, hosts: {} }),

  authorize: (state, op, _params, principal) => {
    if (op !== "team.ensure_personal") {
      if (!principal.user || !state.members[principal.user]) return { code: "auth.forbidden", message: "not a member of this team" }
    }
    // The grant lives in UserDO. The Worker asks UserDO on every install call
    // (revocation and grant) and passes the grant's classes; none means refuse.
    return admit("cloud:TeamDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "team.ensure_personal": {
        if (!p.user || !p.team) return reject("auth.forbidden", "needs a user session")
        if (state.team && state.team.id !== p.team) return reject("auth.forbidden", "not this team")
        const name = p.display_name ?? "Personal"
        const member: typeof TeamMember.Type = { user: p.user, role: "owner", display_name: name }
        const team = { id: p.team, kind: "personal" as const, display_name: name }
        const same = JSON.stringify(state.team) === JSON.stringify(team) && JSON.stringify(state.members[p.user]) === JSON.stringify(member)
        if (same) return { ok: true, state, value: team, changed: false }
        return {
          ok: true,
          state: { ...state, team, members: { ...state.members, [p.user]: member } },
          value: team,
          outbox: [
            { kind: "team.upsert", entity: team.id, payload: team },
            { kind: "membership.upsert", entity: `${team.id}:${p.user}`, payload: { team: team.id, ...member } }
          ]
        }
      }
      case "host.enroll": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        const d = decodeParams<typeof HostEnroll.params.Type>(HostEnroll, params)
        if (!d.ok) return d
        if (!p.install || !p.user) return reject("auth.forbidden", "host.enroll needs an install token")
        const existing = Object.values(state.hosts).find((h) => h.enrolled_by === p.install)
        const id = existing?.id ?? ctx.newId("host")
        const host: typeof Host.Type = { id, name: d.value.name, platform: d.value.platform, owner_user: p.user, enrolled_by: p.install, enrolled_at: existing?.enrolled_at ?? ctx.now }
        if (existing && JSON.stringify(existing) === JSON.stringify(host)) return { ok: true, state, value: host, changed: false }
        return {
          ok: true,
          state: { ...state, hosts: { ...state.hosts, [id]: host } },
          value: host,
          outbox: [{ kind: "host.upsert", entity: id, payload: { ...host, team: state.team.id } }]
        }
      }
      case "host.remove": {
        const d = decodeParams<typeof HostRemove.params.Type>(HostRemove, params)
        if (!d.ok) return d
        const host = state.hosts[d.value.host]
        if (!host) return reject("selector.not_found", "host not found")
        const role = p.user ? state.members[p.user]?.role : undefined
        if (host.owner_user !== p.user && role !== "owner" && role !== "admin") return reject("auth.forbidden", "only the host owner or a team admin may remove it")
        const { [host.id]: _gone, ...rest } = state.hosts
        return {
          ok: true,
          state: { ...state, hosts: rest },
          value: { host: host.id },
          outbox: [{ kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }]
        }
      }
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}
