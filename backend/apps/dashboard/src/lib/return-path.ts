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

/**
 * The console route that starts Sign in with cmux and comes back to `returnTo` (a same-origin path;
 * the server validates it again, lib/sign-in-flow.ts safeReturnPath). Invite pages pass "/": their
 * secret fragment stays in sessionStorage and the sign-in page resumes it (takeReturnPath).
 */
export const signInHref = (returnTo: string): string => `/auth/sign-in?return_to=${encodeURIComponent(returnTo)}`

const AUTO_KEY = "cmux.signin.auto"
const AUTO_INTERVAL_MS = 2 * 60_000

type StorageLike = Pick<Storage, "getItem" | "setItem">

/**
 * Where a signed-out page goes on its own to sign in and come back to itself (path and query), or
 * null when it should show a Sign in link instead: still loading, signed in, or it already started
 * one in the last two minutes (a session the API refuses must not loop through cmux.com).
 */
export const autoSignInHref = (signedIn: boolean | null, location: { pathname: string; search: string }, storage: StorageLike | null, now = Date.now()): string | null => {
  if (signedIn !== false || !storage) return null
  try {
    const last = Number(storage.getItem(AUTO_KEY) ?? "0")
    if (Number.isFinite(last) && now - last < AUTO_INTERVAL_MS && now >= last) return null
    storage.setItem(AUTO_KEY, String(now))
  } catch {
    // Storage unavailable: no loop guard, so do not start on our own.
    return null
  }
  return signInHref(`${location.pathname}${location.search}`)
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
