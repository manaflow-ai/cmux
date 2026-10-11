import { useMemo, useSyncExternalStore } from "react"

export interface Scheduler {
  readonly now: () => number
  readonly setTimeout: (fn: () => void, ms: number) => unknown
  readonly clearTimeout: (handle: unknown) => void
}

const browser: Scheduler = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (h) => globalThis.clearTimeout(h as ReturnType<typeof setTimeout>)
}

/** setTimeout's largest delay (about 24.8 days); a later expiry re-arms when the first timer fires. */
const MAX_DELAY = 2 ** 31 - 1

/**
 * A store that turns true at `at`: each subscriber arms ONE timeout to that exact time (no
 * polling) and clears it on unsubscribe. Nothing is armed once the time has passed.
 */
export const expiryStore = (at: number, s: Scheduler = browser) => ({
  getSnapshot: () => s.now() >= at,
  subscribe: (onChange: () => void) => {
    let handle: unknown = null
    const arm = () => {
      const left = at - s.now()
      if (left <= 0) {
        handle = null
        return onChange()
      }
      handle = s.setTimeout(arm, Math.min(left, MAX_DELAY))
    }
    if (at > s.now()) handle = s.setTimeout(arm, Math.min(at - s.now(), MAX_DELAY))
    return () => {
      if (handle !== null) s.clearTimeout(handle)
    }
  }
})

/** True from `at` on; re-renders the caller exactly at `at`. */
export const useExpired = (at: number): boolean => {
  const store = useMemo(() => expiryStore(at), [at])
  return useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot)
}
