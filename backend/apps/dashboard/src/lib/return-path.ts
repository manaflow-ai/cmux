/**
 * Where to go after sign-in. Only invite paths on this origin are accepted (no open
 * redirect); kept in sessionStorage so the invite secret in the fragment never
 * travels in a URL query or to the server.
 */
const KEY = "cmux.return"
const ALLOWED = /^\/i\/[dg][0-9A-HJKMNP-TV-Z]{26}#[0-9A-HJKMNP-TV-Z]{26}$/

export const saveReturnPath = (path: string): void => {
  if (!ALLOWED.test(path)) return
  try {
    sessionStorage.setItem(KEY, path)
  } catch {}
}

export const takeReturnPath = (): string | null => {
  try {
    const path = sessionStorage.getItem(KEY)
    sessionStorage.removeItem(KEY)
    return path && ALLOWED.test(path) ? path : null
  } catch {
    return null
  }
}
