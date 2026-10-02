import { useCallback, useSyncExternalStore } from "react"
import { refresh, type Tokens } from "./server"

/**
 * Browser-side session: Stack tokens in localStorage (internal dashboard, phase 1).
 * Access tokens are short-lived; `withToken` refreshes once on a 401.
 */
const KEY = "cmux-next-dashboard.tokens"
const listeners = new Set<() => void>()

const load = (): Tokens | null => {
  if (typeof window === "undefined") return null
  try {
    const raw = window.localStorage.getItem(KEY)
    return raw ? (JSON.parse(raw) as Tokens) : null
  } catch {
    return null
  }
}

let cached: Tokens | null | undefined
const snapshot = () => {
  if (cached === undefined) cached = load()
  return cached
}

export const setTokens = (t: Tokens | null) => {
  cached = t
  try {
    if (t) window.localStorage.setItem(KEY, JSON.stringify(t))
    else window.localStorage.removeItem(KEY)
  } catch {}
  listeners.forEach((l) => l())
}

export const useTokens = () =>
  useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    snapshot,
    () => null
  )

/** Runs `fn` with the access token; on 401 refreshes once and retries. */
export const useWithToken = () => {
  const tokens = useTokens()
  return useCallback(
    async <T extends { status: number }>(fn: (token: string) => Promise<T>): Promise<T> => {
      if (!tokens) throw new Error("signed out")
      const first = await fn(tokens.access_token)
      if (first.status !== 401) return first
      const r = await refresh({ data: { refresh_token: tokens.refresh_token } })
      if ("error" in r) {
        setTokens(null)
        return first
      }
      setTokens({ ...tokens, access_token: r.access_token })
      return fn(r.access_token)
    },
    [tokens]
  )
}

export const newKey = () => `dash:${crypto.randomUUID()}`
