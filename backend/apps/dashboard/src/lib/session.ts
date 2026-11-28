import { useSyncExternalStore } from "react"
import { sessionState } from "./server"

/**
 * Browser-side session state: only "signed in or not". The tokens stay in
 * HttpOnly cookies that server functions read; page script never sees them.
 */
let signedIn: boolean | null = null
let loading: Promise<void> | null = null
const listeners = new Set<() => void>()

const emit = () => listeners.forEach((l) => l())

export const setSignedIn = (v: boolean) => {
  signedIn = v
  emit()
}

const ensureLoaded = () => {
  if (signedIn !== null || loading || typeof window === "undefined") return
  loading = sessionState().then(
    (s) => setSignedIn(s.signedIn),
    () => setSignedIn(false)
  )
}

/** null while the first check runs, then true or false. */
export const useSignedIn = (): boolean | null =>
  useSyncExternalStore(
    (l) => {
      listeners.add(l)
      ensureLoaded()
      return () => listeners.delete(l)
    },
    () => signedIn,
    () => null
  )

export const newKey = () => `dash:${crypto.randomUUID()}`
