import type { Env } from "./env.ts"
import { samePersonalMarker, validTenantId, type PersonalTenantMarker } from "./team-vm-api-personal-store.ts"

export interface PersonalTenantReceipt { readonly id: string; readonly marker: unknown }
export interface PersonalTenantStack {
  find(marker: PersonalTenantMarker): Promise<ReadonlyArray<PersonalTenantReceipt>>
  create(marker: PersonalTenantMarker): Promise<PersonalTenantReceipt>
  members(tenant: string): Promise<ReadonlyArray<string>>
}
/** Which Stack call failed and how: its HTTP status and Stack's known-error code, never a body or the key. */
export interface PersonalTenantStackFailure {
  readonly call: "find" | "create" | "join" | "members"
  readonly status?: number
  readonly code?: string
  readonly cause?: "network" | "body" | "shape"
}
export class PersonalTenantIdentityError extends Error {
  constructor(readonly definitelyUnsent: boolean, readonly failure?: PersonalTenantStackFailure) { super("personal tenant identity service unavailable") }
}
const knownError = (response: Response): string | undefined => {
  const code = response.headers.get("x-stack-known-error")
  return code && /^[A-Z0-9_]{1,80}$/.test(code) ? code : undefined
}
export const PERSONAL_TENANT_METADATA_KEY = "cmuxVmPersonalTenant"
const KEY = PERSONAL_TENANT_METADATA_KEY
const API = "https://api.stack-auth.com/api/v1"
interface Team { readonly id?: unknown; readonly server_metadata?: Record<string, unknown> | null }

/** Server-only metadata authenticates provenance. Client metadata, names and selected teams are ignored. */
export const personalTenantStack = (env: Env, http: (request: Request) => Promise<Response> = (r) => fetch(r)): PersonalTenantStack | undefined => {
  if (!env.STACK_SECRET_SERVER_KEY) return undefined
  const call = async <T>(what: PersonalTenantStackFailure["call"], method: string, path: string, body?: unknown, read = true): Promise<T> => {
    let response: Response
    try {
      response = await http(new Request(`${API}${path}`, { method, headers: { "content-type": "application/json", "x-stack-access-type": "server", "x-stack-project-id": env.STACK_PROJECT_ID, "x-stack-secret-server-key": env.STACK_SECRET_SERVER_KEY! }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: "manual", signal: AbortSignal.timeout(10_000) }))
    } catch { throw new PersonalTenantIdentityError(false, { call: what, cause: "network" }) }
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined)
      const code = knownError(response)
      throw new PersonalTenantIdentityError([400, 401, 403, 404, 429].includes(response.status), { call: what, status: response.status, ...(code ? { code } : {}) })
    }
    if (!read) { await response.body?.cancel().catch(() => undefined); return undefined as T }
    try { return await response.json() as T } catch { throw new PersonalTenantIdentityError(false, { call: what, status: response.status, cause: "body" }) }
  }
  const shape = (what: PersonalTenantStackFailure["call"]) => new PersonalTenantIdentityError(false, { call: what, cause: "shape" })
  const receipt = (team: Team, what: PersonalTenantStackFailure["call"]): PersonalTenantReceipt => {
    if (!validTenantId(team.id)) throw shape(what)
    return { id: team.id, marker: team.server_metadata?.[KEY] }
  }
  return {
    find: async (marker) => {
      const found: PersonalTenantReceipt[] = [], seen = new Set<string>()
      let cursor: string | undefined
      for (let page = 0; page < 1000; page++) {
        const q = new URLSearchParams({ user_id: marker.stack_user, limit: "100" })
        if (cursor) q.set("cursor", cursor)
        const answer = await call<{ items?: Team[]; pagination?: { next_cursor?: unknown } | null }>("find", "GET", `/teams?${q}`)
        if (!Array.isArray(answer.items)) throw shape("find")
        for (const team of answer.items) {
          const value = team.server_metadata?.[KEY]
          if (value && typeof value === "object" && (value as { nonce?: unknown }).nonce === marker.nonce) {
            if (!samePersonalMarker(value, marker)) throw shape("find")
            found.push(receipt(team, "find"))
          }
        }
        const next = answer.pagination?.next_cursor
        if (next === undefined || next === null) return found
        if (typeof next !== "string" || !next || seen.has(next)) throw shape("find")
        seen.add(next); cursor = next
      }
      throw shape("find")
    },
    // No creator_user_id: Stack grants a creator its admin defaults (invites included). The owner joins as a
    // plain member instead; a team the owner could not join is deleted so a later create starts clean.
    create: async (marker) => {
      const created = receipt(await call<Team>("create", "POST", "/teams", { display_name: "Personal", server_metadata: { [KEY]: marker } }), "create")
      try { await call("join", "POST", `/team-memberships/${encodeURIComponent(created.id)}/${encodeURIComponent(marker.stack_user)}`, {}, false) }
      catch (e) {
        const removed = await call("join", "DELETE", `/teams/${encodeURIComponent(created.id)}`, undefined, false).then(() => true, () => false)
        throw new PersonalTenantIdentityError(removed, e instanceof PersonalTenantIdentityError ? e.failure : { call: "join" })
      }
      return created
    },
    // Stack lists a team's members at /team-member-profiles (as stack-server.ts reads them); /team-memberships
    // only adds and removes one, so a GET there answers 404 and a found tenant never became ready.
    members: async (tenant) => {
      const out: string[] = [], seen = new Set<string>()
      let cursor: string | undefined
      for (let page = 0; page < 1000; page++) {
        // No limit: this route does not page and refuses an unknown query field (400 SCHEMA_ERROR).
        const q = new URLSearchParams({ team_id: tenant })
        if (cursor) q.set("cursor", cursor)
        const answer = await call<{ items?: Array<{ user_id?: unknown }>; pagination?: { next_cursor?: unknown } | null }>("members", "GET", `/team-member-profiles?${q}`)
        if (!Array.isArray(answer.items) || answer.items.some((m) => !validTenantId(m.user_id))) throw shape("members")
        for (const m of answer.items) if (typeof m.user_id === "string") out.push(m.user_id)
        const next = answer.pagination?.next_cursor
        if (next === undefined || next === null) return out
        if (typeof next !== "string" || !next || seen.has(next)) throw shape("members")
        seen.add(next); cursor = next
      }
      throw shape("members")
    }
  }
}
