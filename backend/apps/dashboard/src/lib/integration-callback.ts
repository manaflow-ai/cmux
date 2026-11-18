/**
 * Reads only the team claim from an integration state's JWT for request routing.
 *
 * The state is signed by the API and remains opaque to the dashboard. This hint
 * is deliberately untrusted: the API verifies the signature, user, connection
 * and team again when it handles integration.complete.
 */
export const integrationTeamHint = (state: string | undefined): string | undefined => {
  const team = unverifiedStateClaims(state)?.team
  return typeof team === "string" && /^team_[0-9a-f]{20}$/.test(team) ? team : undefined
}

/** The state JWT's payload, decoded without verification (routing hints only). */
const unverifiedStateClaims = (state: string | undefined): Record<string, unknown> | undefined => {
  if (!state || state.length > 4096) return undefined
  const parts = state.split(".")
  if (parts.length !== 3) return undefined
  try {
    const encoded = parts[1]!.replace(/-/g, "+").replace(/_/g, "/")
    const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4)
    const payload: unknown = JSON.parse(
      new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))),
    )
    return payload && typeof payload === "object" && !Array.isArray(payload) ? (payload as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/**
 * The API environment that signed an integration state, from its issuer `https://cmux-api/<environment>`
 * (api src/integrations/state.ts). Untrusted, like the team hint: it only picks which API to ask, and that
 * API verifies the signature and issuer again.
 */
export const integrationEnvironmentHint = (state: string | undefined): string | undefined => {
  const iss = unverifiedStateClaims(state)?.iss
  const env = typeof iss === "string" ? /^https:\/\/cmux-api\/([a-z0-9-]{1,40})$/.exec(iss)?.[1] : undefined
  return env
}

/**
 * The development API Worker has no hosted console of its own. Its Connect redirects (wrangler.jsonc
 * env.development INTEGRATIONS_CALLBACK_ORIGIN) come back to the staging console, which signs in through
 * the same sign-in project, and this console sends that completion on to the development API.
 * Only the staging console does this: on any other console a development state goes to the console's own
 * API, which refuses it. test-server/integration-callback-route.test.ts pins both URLs to wrangler.jsonc.
 */
export const STAGING_API_URL = "https://cloud-api-staging.cmux.dev"
export const STAGING_CONSOLE_HOST = "console-staging.cmux.dev"
export const DEVELOPMENT_API_URL = "https://cmux-api-development.debussy.workers.dev"

/**
 * Which API finishes this completion: the console's own, or (staging console, development state) the development API.
 * The staging console is recognised by its API or by its own host, so a console API URL in another form still forwards.
 */
export const integrationCompletionApi = (at: { readonly api: string; readonly host?: string }, state: string | undefined): { readonly url: string; readonly environment?: "development" } => {
  const api = at.api.replace(/\/$/, "")
  const staging = api === STAGING_API_URL || at.host?.toLowerCase() === STAGING_CONSOLE_HOST
  return staging && integrationEnvironmentHint(state) === "development" ? { url: DEVELOPMENT_API_URL, environment: "development" } : { url: api }
}

/** The `ret` claim of an integration state's JWT, unverified (the API verifies the state when the app completes it). */
const stateReturnHint = (state: string | undefined): string | undefined => {
  const ret = unverifiedStateClaims(state)?.ret
  return typeof ret === "string" ? ret : undefined
}

/**
 * A connect the app started (#46018): the state's return link is the app's own `<scheme>://integration/complete`.
 * The provider's redirect goes straight on to it with `state`, `code`, `installation_id`, `setup_action` and `error`,
 * and the app finishes the connection with its own sign-in: no page here, no web session. Undefined for any other
 * connect (one started here, or from a chat), which this page finishes as before. The link is only a hint read from
 * the unverified state: the app sends the state back, and the API completes only a state signed for that person.
 */
export const integrationAppHandoff = (search: {
  state?: string
  code?: string
  installation_id?: string
  setup_action?: string
  error?: string
}): string | undefined => {
  const ret = stateReturnHint(search.state)
  if (!ret || ret.length > 512 || !RETURN_TO_PATTERN.test(ret) || !ret.endsWith("://integration/complete")) return undefined
  const query = new URLSearchParams()
  for (const key of ["state", "code", "installation_id", "setup_action", "error"] as const) {
    const value = search[key]
    if (value) query.set(key, value)
  }
  return `${ret}?${query.toString()}`
}

export const integrationCompletionRequest = (state: string, extra: { code?: string; installation_id?: string; setup_action?: string } = {}) => ({
  params: {
    state,
    ...(extra.code ? { code: extra.code } : {}),
    ...(extra.installation_id ? { installation_id: extra.installation_id } : {}),
    ...(extra.setup_action ? { setup_action: extra.setup_action } : {}),
  },
  team: integrationTeamHint(state),
  idempotency_key: `complete:${state.slice(-40)}`,
})

const RETURN_HEX = "[0-9a-f]{32}"
const RETURN_SESSION = "[A-Za-z0-9._-]{1,200}"
const RETURN_HINT = "(?:host|name|message)=[A-Za-z0-9._:%-]{1,128}"
/**
 * The cmux chat links a connect may return to: the same grammar as `CONNECT_RETURN_TO` in
 * @cmux/protocol (a test pins them equal). Checked again here, before the browser leaves the dashboard.
 */
export const RETURN_TO_PATTERN = new RegExp(
  `^(?:cmux|cmux-nightly|cmux-rc|cmux-dev(?:-[a-z0-9-]{1,40})?)://(?:` +
    `(?:workspace/ws_|pane/pane_|tab/tab_)${RETURN_HEX}(?:\\?machine=machine_${RETURN_HEX})?` +
    `|session/${RETURN_SESSION}(?:\\?machine=machine_${RETURN_HEX})?(?:#turn-${RETURN_SESSION})?` +
    `|agent/[a-z0-9-]{1,64}/[A-Za-z0-9._:-]{1,256}(?:\\?${RETURN_HINT}(?:&${RETURN_HINT}){0,2})?` +
    `|integration/complete` +
    `)$`,
)

/** The chat link a completed connect returns to, from the API's completion answer; anything else is dropped. */
export const integrationReturnLink = (value: unknown): string | undefined => {
  const link = (value as { return_to?: unknown } | null | undefined)?.return_to
  return typeof link === "string" && link.length <= 512 && RETURN_TO_PATTERN.test(link) ? link : undefined
}

/** An installation's settings page on GitHub (the API's `GITHUB_CONFIGURE_URL`). */
export const CONFIGURE_URL_PATTERN = /^https:\/\/github\.com\/(?:organizations\/[A-Za-z0-9-]{1,39}\/)?settings\/installations\/[0-9]{1,20}$/

/** The GitHub page to add the asked repository on, when the completion says the link left it out. */
export const integrationConfigureLink = (value: unknown): string | undefined => {
  const link = (value as { configure_url?: unknown } | null | undefined)?.configure_url
  return typeof link === "string" && CONFIGURE_URL_PATTERN.test(link) ? link : undefined
}
