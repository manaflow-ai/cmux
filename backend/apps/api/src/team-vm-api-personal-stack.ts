import type { Env } from "./env.ts"
import { samePersonalMarker, validTenantId, type PersonalTenantMarker } from "./team-vm-api-personal-store.ts"

export interface PersonalTenantReceipt { readonly id: string; readonly marker: unknown }
export interface PersonalTenantStack {
  find(marker: PersonalTenantMarker): Promise<ReadonlyArray<PersonalTenantReceipt>>
  create(marker: PersonalTenantMarker): Promise<PersonalTenantReceipt>
  members(tenant: string): Promise<ReadonlyArray<string>>
}
export class PersonalTenantIdentityError extends Error {
  constructor(readonly definitelyUnsent: boolean) { super("personal tenant identity service unavailable") }
}
const KEY = "cmuxVmPersonalTenant"
const API = "https://api.stack-auth.com/api/v1"
interface Team { readonly id?: unknown; readonly server_metadata?: Record<string, unknown> | null }

/** Server-only metadata authenticates provenance. Client metadata, names and selected teams are ignored. */
export const personalTenantStack = (env: Env, http: (request: Request) => Promise<Response> = (r) => fetch(r)): PersonalTenantStack | undefined => {
  if (!env.STACK_SECRET_SERVER_KEY) return undefined
  const call = async <T>(method: string, path: string, body?: unknown): Promise<T> => {
    let response: Response
    try {
      response = await http(new Request(`${API}${path}`, { method, headers: { "content-type": "application/json", "x-stack-access-type": "server", "x-stack-project-id": env.STACK_PROJECT_ID, "x-stack-secret-server-key": env.STACK_SECRET_SERVER_KEY! }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: "manual", signal: AbortSignal.timeout(10_000) }))
    } catch { throw new PersonalTenantIdentityError(false) }
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined)
      throw new PersonalTenantIdentityError([400, 401, 403, 404, 429].includes(response.status))
    }
    try { return await response.json() as T } catch { throw new PersonalTenantIdentityError(false) }
  }
  const receipt = (team: Team): PersonalTenantReceipt => {
    if (!validTenantId(team.id)) throw new PersonalTenantIdentityError(false)
    return { id: team.id, marker: team.server_metadata?.[KEY] }
  }
  return {
    find: async (marker) => {
      const found: PersonalTenantReceipt[] = [], seen = new Set<string>()
      let cursor: string | undefined
      for (let page = 0; page < 1000; page++) {
        const q = new URLSearchParams({ user_id: marker.stack_user, limit: "100" })
        if (cursor) q.set("cursor", cursor)
        const answer = await call<{ items?: Team[]; pagination?: { next_cursor?: unknown } | null }>("GET", `/teams?${q}`)
        if (!Array.isArray(answer.items)) throw new PersonalTenantIdentityError(false)
        for (const team of answer.items) {
          const value = team.server_metadata?.[KEY]
          if (value && typeof value === "object" && (value as { nonce?: unknown }).nonce === marker.nonce) {
            if (!samePersonalMarker(value, marker)) throw new PersonalTenantIdentityError(false)
            found.push(receipt(team))
          }
        }
        const next = answer.pagination?.next_cursor
        if (next === undefined || next === null) return found
        if (typeof next !== "string" || !next || seen.has(next)) throw new PersonalTenantIdentityError(false)
        seen.add(next); cursor = next
      }
      throw new PersonalTenantIdentityError(false)
    },
    create: async (marker) => receipt(await call<Team>("POST", "/teams", { display_name: "Personal", creator_user_id: marker.stack_user, server_metadata: { [KEY]: marker } })),
    members: async (tenant) => {
      const out: string[] = [], seen = new Set<string>()
      let cursor: string | undefined
      for (let page = 0; page < 1000; page++) {
        const q = new URLSearchParams({ team_id: tenant, limit: "100" })
        if (cursor) q.set("cursor", cursor)
        const answer = await call<{ items?: Array<{ user_id?: unknown }>; pagination?: { next_cursor?: unknown } | null }>("GET", `/team-memberships?${q}`)
        if (!Array.isArray(answer.items) || answer.items.some((m) => !validTenantId(m.user_id))) throw new PersonalTenantIdentityError(false)
        for (const m of answer.items) if (typeof m.user_id === "string") out.push(m.user_id)
        const next = answer.pagination?.next_cursor
        if (next === undefined || next === null) return out
        if (typeof next !== "string" || !next || seen.has(next)) throw new PersonalTenantIdentityError(false)
        seen.add(next); cursor = next
      }
      throw new PersonalTenantIdentityError(false)
    }
  }
}
