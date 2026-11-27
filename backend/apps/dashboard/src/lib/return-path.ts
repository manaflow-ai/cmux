/**
 * Where to go after sign-in. Only invite paths and the integration callback on this origin are accepted (no open
 * redirect); kept in sessionStorage so the invite secret in the fragment never travels in a URL query or to the server.
 * The callback comes back so a connect finished while signed out goes on after sign-in instead of stranding the person
 * ("open the link again", Leo 2026-11-25: "it should already know").
 */
const KEY = "cmux.return"
const INVITE = /^\/i\/[dg][0-9A-HJKMNP-TV-Z]{26}#[0-9A-HJKMNP-TV-Z]{26}$/
const CALLBACK_KEYS = ["state", "code", "installation_id", "setup_action", "error"] as const
const CALLBACK = /^\/integrations\/callback\?(?:(?:state|code|installation_id|setup_action|error)=[A-Za-z0-9._~%-]{1,2048}&?){1,5}$/

const allowed = (path: string): boolean => path.length <= 8192 && (INVITE.test(path) || CALLBACK.test(path))

export const saveReturnPath = (path: string): void => {
  if (!allowed(path)) return
  try {
    sessionStorage.setItem(KEY, path)
  } catch {}
}

/** The callback page's own path, with only the provider's redirect fields, to come back to after sign-in. */
export const integrationCallbackReturnPath = (search: Partial<Record<(typeof CALLBACK_KEYS)[number], string>>): string | undefined => {
  const query = new URLSearchParams()
  for (const key of CALLBACK_KEYS) if (search[key]) query.set(key, search[key]!)
  if (!query.has("state")) return undefined
  const path = `/integrations/callback?${query.toString()}`
  return allowed(path) ? path : undefined
}

export const takeReturnPath = (): string | null => {
  try {
    const path = sessionStorage.getItem(KEY)
    sessionStorage.removeItem(KEY)
    return path && allowed(path) ? path : null
  } catch {
    return null
  }
}
