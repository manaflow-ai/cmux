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
