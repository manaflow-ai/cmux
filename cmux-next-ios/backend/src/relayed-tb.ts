/**
 * Relayed-terabyte counter verdict (RFD 0163 row 33, "no PoP capex ahead of traffic"): a relay box is added
 * when the bytes the relays carried (not the direct or hole-punched ones) pass a tier threshold, never ahead
 * of traffic. Probe-based relay choice is placement.ts; this is the pure judge of the counter, so the alert
 * and the capex decision read one rule. Wiring it to the relay's byte counters is the next slice.
 */
export const TB = 1e12

/** Tier-2 threshold: relayed bytes in a calendar month at which one more relay box is justified. */
export const TIER2_RELAYED_BYTES = 50 * TB
/** Warn at this share of the threshold, so the box is ordered before the day it is needed. */
export const WARN_SHARE = 0.8

export type RelayedTbVerdict = "ok" | "warn" | "add_box"

/** The verdict for `relayedBytes` this month against `threshold` (bytes; positive, finite). */
export const judgeRelayedTb = (relayedBytes: number, threshold = TIER2_RELAYED_BYTES): RelayedTbVerdict => {
  if (!Number.isFinite(threshold) || threshold <= 0) throw new RangeError("threshold must be a positive number")
  if (!Number.isFinite(relayedBytes) || relayedBytes < 0) throw new RangeError("relayedBytes must be a non-negative number")
  if (relayedBytes >= threshold) return "add_box"
  return relayedBytes >= threshold * WARN_SHARE ? "warn" : "ok"
}
