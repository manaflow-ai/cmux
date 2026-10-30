/**
 * The OAuth provider navigates away from the dashboard and back to a fresh
 * document. Scope the return state by the provider's opaque state value so
 * two tabs cannot restore one another's team.
 */
export const INTEGRATION_RETURN_TEAM_KEY = "cmux.integration.return-team"

export const integrationReturnTeamKey = (state: string | undefined): string =>
  state ? `${INTEGRATION_RETURN_TEAM_KEY}:${state}` : INTEGRATION_RETURN_TEAM_KEY

export const integrationReturnPath = (team: string | null | undefined): string =>
  team ? `/integrations?team=${encodeURIComponent(team)}` : "/integrations"
