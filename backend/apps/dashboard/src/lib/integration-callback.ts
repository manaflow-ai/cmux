/**
 * Reads only the team claim from an integration state's JWT for request routing.
 *
 * The state is signed by the API and remains opaque to the dashboard. This hint
 * is deliberately untrusted: the API verifies the signature, user, connection
 * and team again when it handles integration.complete.
 */
export const integrationTeamHint = (state: string | undefined): string | undefined => {
  if (!state || state.length > 4096) return undefined
  const parts = state.split(".")
  if (parts.length !== 3) return undefined
  try {
    const encoded = parts[1]!.replace(/-/g, "+").replace(/_/g, "/")
    const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4)
    const payload = JSON.parse(
      new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))),
    ) as { team?: unknown }
    return typeof payload.team === "string" && /^team_[0-9a-f]{20}$/.test(payload.team)
      ? payload.team
      : undefined
  } catch {
    return undefined
  }
}

/** The `ret` claim of an integration state's JWT, unverified (the API verifies the state when the app completes it). */
const stateReturnHint = (state: string | undefined): string | undefined => {
  if (!state || state.length > 4096) return undefined
  const parts = state.split(".")
  if (parts.length !== 3) return undefined
  try {
    const encoded = parts[1]!.replace(/-/g, "+").replace(/_/g, "/")
    const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4)
    const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)))) as { ret?: unknown }
    return typeof payload.ret === "string" ? payload.ret : undefined
  } catch {
    return undefined
  }
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
