import { describe, expect, it } from "bun:test"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { TeamForbidden, TeamPicker } from "../src/lib/team-picker.tsx"
import { isTeamForbidden, keepTeam, notMemberOf, parseTeamSearch, scopedApi, searchForTeam, selectedTeam, teamHeaders, type UserTeam } from "../src/lib/team-scope.ts"

const PERSONAL = "team_00000000000000000001"
const ACME = "team_aaaaaaaaaaaaaaaaaaaa"
const GHOST = "team_ffffffffffffffffffff"
const TEAMS: Array<UserTeam> = [
  { id: PERSONAL, display_name: "Personal", kind: "personal", role: "owner" },
  { id: ACME, display_name: "Acme Corp", kind: "stack", role: "member" }
]

const picker = (selected: string | undefined, locale: "en" | "ja" = "en") => renderToStaticMarkup(createElement(TeamPicker, { teams: TEAMS, selected, locale, onSelect: () => {} }))

/** cx-5xew: the dashboard team picker (user.teams.list), ?team=<id> in the URL, the team on every call. */
describe("team picker", () => {
  it("renders every team the server listed and selects the personal team by default", () => {
    const html = picker(undefined)
    expect(html).toContain("data-team-picker")
    expect(html).toContain(`value="${PERSONAL}"`)
    expect(html).toContain(`value="${ACME}"`)
    expect(html).toContain("Acme Corp (member)")
    expect(html).toContain("Personal (owner)")
    expect(html).toMatch(new RegExp(`value="${PERSONAL}" selected`))
    expect(picker(ACME)).toMatch(new RegExp(`value="${ACME}" selected`))
    // Japanese labels.
    const ja = picker(ACME, "ja")
    expect(ja).toContain("チーム")
    expect(ja).toContain("Acme Corp (メンバー)")
    expect(ja).toContain("個人 (オーナー)")
  })

  it("shows a team the URL names but the list does not, so the choice stays visible", () => {
    const html = picker(GHOST)
    expect(html).toMatch(new RegExp(`value="${GHOST}" selected`))
    expect(html).toContain(GHOST)
  })

  it("keeps the choice in ?team: the personal team drops the parameter; links keep it; a bad id is ignored", () => {
    expect(searchForTeam({ tab: "x" }, TEAMS, ACME)).toEqual({ tab: "x", team: ACME })
    expect(searchForTeam({ team: ACME, tab: "x" }, TEAMS, PERSONAL)).toEqual({ tab: "x" })
    expect(keepTeam({ team: ACME, state: "abc" })).toEqual({ team: ACME })
    expect(keepTeam({ state: "abc" })).toEqual({})
    expect(parseTeamSearch({ team: ACME })).toEqual({ team: ACME })
    expect(parseTeamSearch({ team: "team_x\r\nx-evil: 1" })).toEqual({})
    expect(parseTeamSearch({})).toEqual({})
    expect(selectedTeam(TEAMS, undefined)).toBe(PERSONAL)
    expect(selectedTeam(TEAMS, ACME)).toBe(ACME)
    expect(selectedTeam(undefined, ACME)).toBe(ACME)
  })

  it("passes the team to every client call (read, mutate, export) and to the API as x-cmux-team", async () => {
    const calls: Array<{ fn: string; data: unknown }> = []
    const fake = (fn: string) => async (a: { data: unknown }) => {
      calls.push({ fn, data: a.data })
      return { status: 200, body: {} }
    }
    const api = scopedApi(ACME, { read: fake("read"), mutate: fake("mutate"), exportTeamFiles: fake("export") })
    await api.read({ data: { op: "team.directory", params: {} } })
    await api.mutate({ data: { op: "team_vm.rebuild", params: {}, idempotency_key: "k" } })
    await api.exportTeamFiles({ data: { vm: "vm_1", idempotency_key: "k2" } })
    expect(calls).toEqual([
      { fn: "read", data: { op: "team.directory", params: {}, team: ACME } },
      { fn: "mutate", data: { op: "team_vm.rebuild", params: {}, idempotency_key: "k", team: ACME } },
      { fn: "export", data: { vm: "vm_1", idempotency_key: "k2", team: ACME } }
    ])
    // The personal team (no ?team) sends no team.
    calls.length = 0
    await scopedApi(undefined, { read: fake("read"), mutate: fake("mutate"), exportTeamFiles: fake("export") }).read({ data: { op: "install.list", params: {} } })
    expect(calls).toEqual([{ fn: "read", data: { op: "install.list", params: {} } }])
    expect(teamHeaders(ACME)).toEqual({ "x-cmux-team": ACME })
    expect(teamHeaders(undefined)).toEqual({})
    expect(() => teamHeaders("team_x\r\nx-evil: 1")).toThrow()
  })

  it("shows the not-a-member state when the server answers auth.forbidden for a team the list no longer has", () => {
    expect(isTeamForbidden({ status: 403, body: { _tag: "Forbidden", code: "auth.forbidden", message: "not a member of this team" } })).toBe(true)
    expect(isTeamForbidden({ status: 403, body: { error: { code: "auth.forbidden" } } })).toBe(true)
    expect(isTeamForbidden({ status: 200, body: {} })).toBe(false)
    expect(isTeamForbidden({ status: 401, body: { code: "auth.unauthenticated" } })).toBe(false)
    expect(notMemberOf(TEAMS, GHOST)).toBe(true)
    expect(notMemberOf(TEAMS, ACME)).toBe(false)
    expect(notMemberOf(TEAMS, undefined)).toBe(false)
    const html = renderToStaticMarkup(createElement(TeamForbidden, { team: GHOST, locale: "en", onPersonal: () => {} }))
    expect(html).toContain("data-team-forbidden")
    expect(html).toContain("You are not a member of this team")
    expect(html).toContain(GHOST)
    expect(html).toContain("Open my personal team")
    const ja = renderToStaticMarkup(createElement(TeamForbidden, { team: GHOST, locale: "ja", onPersonal: () => {} }))
    expect(ja).toContain("このチームのメンバーではありません")
  })
})
