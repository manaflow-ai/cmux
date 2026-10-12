/**
 * Team scope (cx-5xew): which team the dashboard acts in. The choice lives in the URL
 * (`?team=<id>`, absent = the personal team), so links and reloads keep it. Every API call
 * carries it to the API as `x-cmux-team`; the API asks that team's TeamDO on each request,
 * so the URL is a choice, never an authority. Pure: tests run it without a router or a server.
 */

export const TEAM_HEADER = "x-cmux-team"
const TEAM_ID = /^team_[0-9a-f]{20}$/

/** One team of user.teams.list. */
export interface UserTeam {
  readonly id: string
  readonly display_name: string
  readonly kind: "personal" | "stack"
  /** The caller's role; a newer server may answer a role this build does not name (shown as is). */
  readonly role: "owner" | "admin" | "member" | (string & {})
  /** The team requires its SSO and this session did not sign in through it (the API answers auth.sso_required there). */
  readonly sso_required: boolean
}

export interface TeamsList {
  readonly teams: ReadonlyArray<UserTeam>
  readonly incomplete: boolean
}

export type TeamSearch = { team?: string }

/** The root route's validateSearch: keeps `team` only when it is a team id. */
export const parseTeamSearch = (search: Record<string, unknown>): TeamSearch =>
  typeof search.team === "string" && TEAM_ID.test(search.team) ? { team: search.team } : {}

/** The search after picking `id`: the personal team drops the parameter (it is the default). */
export const searchForTeam = <S extends Record<string, unknown>>(prev: S, teams: ReadonlyArray<UserTeam> | undefined, id: string): Record<string, unknown> => {
  const { team: _old, ...rest } = prev
  const personal = teams?.find((t) => t.kind === "personal")?.id
  return id === personal ? rest : { ...rest, team: id }
}

/** Search for header links: the team choice crosses pages, page parameters do not. */
export const keepTeam = (prev: Record<string, unknown>): TeamSearch => parseTeamSearch(prev)

/** The team the page acts in: the URL's team, else the personal team (undefined until the list loads). */
export const selectedTeam = (teams: ReadonlyArray<UserTeam> | undefined, requested: string | undefined): string | undefined =>
  requested ?? teams?.find((t) => t.kind === "personal")?.id

/** True when the server's list (TeamDO-confirmed) does not have `team`: the caller is not a member now. */
export const notMemberOf = (teams: ReadonlyArray<UserTeam>, team: string | undefined): boolean => team !== undefined && !teams.some((t) => t.id === team)

/** Headers for the API call: x-cmux-team for a named team. Refuses anything but a team id. */
export const teamHeaders = (team: string | undefined): Record<string, string> => {
  if (team === undefined) return {}
  if (!TEAM_ID.test(team)) throw new Error("team must be a team id")
  return { [TEAM_HEADER]: team }
}

/** The API refused the request's team itself (HTTP 403 team.not_member), never a role or op refusal inside it. */
export const isNotTeamMember = (r: { readonly status: number; readonly body: unknown }): boolean => {
  if (r.status !== 403 || !r.body || typeof r.body !== "object") return false
  const b = r.body as { code?: unknown; error?: { code?: unknown } }
  return (b.code ?? b.error?.code) === "team.not_member"
}

/** A server function: an options object whose data type each one declares. */
type Call = (a: { data: any }) => Promise<unknown>
export interface ApiFns {
  readonly read: Call
  readonly mutate: Call
  readonly exportTeamFiles: Call
}

/** The client calls with `team` added to each request (the server functions send it as x-cmux-team); same types as `fns`. */
export const scopedApi = <F extends ApiFns>(team: string | undefined, fns: F) => {
  const scope = (a: { data: object }) => ({ data: team ? { ...a.data, team } : a.data })
  return {
    team,
    read: ((a: { data: object }) => fns.read(scope(a))) as unknown as F["read"],
    mutate: ((a: { data: object }) => fns.mutate(scope(a))) as unknown as F["mutate"],
    exportTeamFiles: ((a: { data: object }) => fns.exportTeamFiles(scope(a))) as unknown as F["exportTeamFiles"]
  }
}
