/**
 * Just-in-time team membership after an SSO sign-in: cmux-platform's POST /v1/teams/{team}/sso/join
 * (cmux-platform src/api/TeamImport.ts TeamSsoApi, src/server/teams/TeamImportApi.ts), called over the
 * PLATFORM service binding as the person's own new Stack session (the access token the callback just
 * minted), the way platform-api.ts calls it with a caller's bearer. The platform checks back with this
 * TeamDO (ssoSession) that its SSO created that very session, so the session row must be recorded first.
 *
 * The platform decides who joins (a domain the team verified, a pending import row) and answers
 * `member` for someone already in the team, so a repeat sign-in is a no-op. A person the team removed
 * (SCIM, an import's undo) or its identity provider deactivated is refused there; the callback refuses
 * the sign-in too. Anything else that is not a join (no binding, an outage, not eligible) leaves the
 * sign-in as it was before this call existed.
 */
export type SsoJoin =
  | { readonly ok: true; readonly status: "joined" | "member"; readonly role?: string; readonly source?: string }
  | { readonly ok: false; readonly refused: boolean; readonly status: number; readonly code: string; readonly message: string }

/** Platform answers that end the sign-in for this team: the person was removed from it or deactivated. */
export const SSO_JOIN_REFUSALS: ReadonlySet<string> = new Set(["team_sso.removed", "team_sso.deactivated"])

const JOIN_TIMEOUT_MS = 5000

/** POST /v1/teams/{team}/sso/join on cmux-platform as `accessToken` (the person's Stack access token). */
export const platformSsoJoin = async (platform: Fetcher | undefined, origin: string, team: string, accessToken: string): Promise<SsoJoin> => {
  const unavailable = (message: string): SsoJoin => ({ ok: false, refused: false, status: 503, code: "team_sso.unavailable", message })
  if (!platform) return unavailable("this deployment has no PLATFORM binding")
  let response: Response
  try {
    response = await platform.fetch(new Request(new URL(`/v1/teams/${encodeURIComponent(team)}/sso/join`, origin), {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(JOIN_TIMEOUT_MS),
    }))
  } catch (e) {
    return unavailable(`the platform could not be reached: ${String(e).slice(0, 200)}`)
  }
  const parsed: unknown = await response.json().catch(() => null)
  const body = typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null
  if (response.ok) {
    const status = body?.status
    if (status !== "joined" && status !== "member") return unavailable("the platform's join answer was malformed")
    return {
      ok: true,
      status,
      ...(typeof body?.role === "string" ? { role: body.role } : {}),
      ...(typeof body?.source === "string" ? { source: body.source } : {}),
    }
  }
  // An HttpApi error is {_tag, code, message}; the forwarder's outage nests it under `error`.
  const e = (body && typeof body.error === "object" && body.error !== null ? body.error : body) as Record<string, unknown> | null
  const code = typeof e?.code === "string" ? e.code : `platform.${response.status}`
  return {
    ok: false,
    refused: response.status === 403 && SSO_JOIN_REFUSALS.has(code),
    status: response.status,
    code,
    message: typeof e?.message === "string" ? e.message.slice(0, 300) : `platform answered ${response.status}`,
  }
}
