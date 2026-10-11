import { useSearch } from "@tanstack/react-router"
import { createContext, useContext, useMemo } from "react"
import { exportTeamFiles, mutate, read } from "./server"
import { parseTeamSearch, scopedApi, type TeamsList } from "./team-scope"

/**
 * The API client for the team in the URL (cx-5xew): read, mutate and exportTeamFiles with `team`
 * added, so every call of a page acts in the picked team. Use `api.team` in useLoad keys, so a
 * new pick loads again.
 */
export const useTeamApi = () => {
  const team = parseTeamSearch(useSearch({ strict: false }) as Record<string, unknown>).team
  return useMemo(() => scopedApi(team, { read, mutate, exportTeamFiles }), [team])
}

/** The user.teams.list answer the header loaded, and a reload (after a page saw team.not_member). */
export const TeamsContext = createContext<{ readonly list: TeamsList | undefined; readonly reload: () => void }>({ list: undefined, reload: () => {} })
export const useTeams = () => useContext(TeamsContext)
