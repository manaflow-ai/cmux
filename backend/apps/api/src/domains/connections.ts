import type { Domain, OutboxItem, Principal } from "@cmux/ownership"
import { connectionInternalOps, IntegrationConnect, IntegrationRevoke, type Connection } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"

/**
 * ConnectionDO's reducer (spec integrations.md): the integration connections
 * of one owner team. Credentials are not here (they are sealed in a DO table
 * outside entity state); this holds only what every team member may see.
 */

export interface ConnectionsState {
  readonly owner: string | null
  readonly connections: Readonly<Record<string, Connection>>
}

export const MAX_CONNECTIONS = 50
const internalByName = new Map(connectionInternalOps.map((d) => [d.name, d]))

/** Who may see and use a connection: private ones only their creator; team ones every member. */
export const mayUse = (c: Connection, p: Principal) => c.sharing === "team" || c.created_by === p.user

const outbox = (c: Connection): OutboxItem => ({ kind: "connection.upsert", entity: c.id, payload: c })

export const connectionsDomain: Domain<ConnectionsState> = {
  initial: () => ({ owner: null, connections: {} }),

  authorize: (state, op, _params, principal) => {
    if (principal.kind === "system") {
      if (!internalByName.has(op)) return { code: "auth.forbidden", message: `${op} is not an internal op` }
      return admit("cloud:ConnectionDO", op, principal, () => undefined, Date.now())
    }
    if (!principal.team) return { code: "auth.forbidden", message: "needs a team" }
    if (state.owner && state.owner !== principal.team) return { code: "auth.forbidden", message: "not this team's connections" }
    return admit("cloud:ConnectionDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "integration.connect": {
        const d = decodeParams<typeof IntegrationConnect.params.Type>(IntegrationConnect, params)
        if (!d.ok) return d
        const owner = state.owner ?? p.team
        if (!owner || !p.user) return reject("auth.forbidden", "integration.connect needs a user in a team")
        if (Object.values(state.connections).filter((c) => c.status !== "revoked").length >= MAX_CONNECTIONS) {
          return reject("integration.limit", `at most ${MAX_CONNECTIONS} connections per team`)
        }
        const c: Connection = {
          id: ctx.newId("conn"),
          owner,
          created_by: p.user,
          provider: d.value.provider,
          account: null,
          scopes_requested: [...(d.value.scopes ?? [])],
          scopes_granted: [],
          status: "pending",
          sharing: d.value.sharing ?? "private",
          created_at: ctx.now,
          updated_at: ctx.now
        }
        return { ok: true, state: { owner, connections: { ...state.connections, [c.id]: c } }, value: c, outbox: [outbox(c)] }
      }

      case "integration.revoke": {
        const d = decodeParams<typeof IntegrationRevoke.params.Type>(IntegrationRevoke, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c || !mayUse(c, p)) return reject("selector.not_found", "connection not found")
        // Phase 1 knows no team roles here: only the creator disconnects (team admins come with Stack teams).
        if (c.created_by !== p.user) return reject("auth.forbidden", "only the person who connected it may disconnect it")
        if (c.status === "revoked") return { ok: true, state, value: c, changed: false }
        const next: Connection = { ...c, status: "revoked", updated_at: ctx.now }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: next } }, value: next, outbox: [outbox(next)] }
      }

      case "connection.activate": {
        const d = decodeParams<{ connection: string; account: { key: string; name: string; url?: string }; scopes_granted: Array<string> }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c) return reject("selector.not_found", "connection not found")
        if (c.status === "revoked") return reject("validation.invalid", "connection was revoked")
        if (c.account && c.account.key !== d.value.account.key) return reject("validation.invalid", "a connection cannot move to another provider account")
        const next: Connection = { ...c, account: d.value.account, scopes_granted: d.value.scopes_granted, status: "active", updated_at: ctx.now }
        const { status_detail: _sd, ...clean } = next as Connection & { status_detail?: string }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: clean } }, value: clean, outbox: [outbox(clean)] }
      }

      case "connection.status": {
        const d = decodeParams<{ connection: string; status: "active" | "needs_reauth" | "error"; detail?: string }>(internalByName.get(op)!, params)
        if (!d.ok) return d
        const c = state.connections[d.value.connection]
        if (!c) return reject("selector.not_found", "connection not found")
        if (c.status === "revoked" || c.status === "pending") return { ok: true, state, value: c, changed: false }
        if (c.status === d.value.status && c.status_detail === d.value.detail) return { ok: true, state, value: c, changed: false }
        const { status_detail: _old, ...rest } = c
        const next: Connection = { ...rest, status: d.value.status, ...(d.value.detail ? { status_detail: d.value.detail } : {}), updated_at: ctx.now }
        return { ok: true, state: { ...state, connections: { ...state.connections, [c.id]: next } }, value: next, outbox: [outbox(next)] }
      }

      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}
