/**
 * Shared limits for the mobile control plane's expensive control-plane paths.
 *
 * These are Cloudflare RateLimit bindings rather than per-isolate maps: a phone
 * reconnecting to another HostDO, or switching from the HTTP TURN route to the
 * socket read, still spends the same identity budget. Production call sites
 * require the binding; isolated unit tests may omit it explicitly.
 */

export const MOBILE_RATE_LIMITED = "signal.rate_limited"
export const MOBILE_RATE_RETRY_SECONDS = 60

/** TURN credentials live for 15 minutes; six mints/minute tolerates retries while bounding provider calls. */
export const MOBILE_TURN_LIMIT = 6
/** Pending-key snapshots are repair traffic; 120/minute allows reconnects without an owner flood. */
export const MOBILE_PENDING_LIMIT = 120

export type MobileRateBinding = Pick<RateLimit, "limit">

export const mobileRateKey = (kind: "turn" | "pending", identity: string): string => `${kind}:${identity}`

/** Returns false when a configured binding cannot answer, so an outage cannot disable the guard. */
export const takeMobileRate = async (binding: MobileRateBinding | undefined, key: string, required = false): Promise<boolean> => {
  if (!binding) return !required
  try {
    return (await binding.limit({ key })).success
  } catch {
    return false
  }
}
