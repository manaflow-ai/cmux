import type { Env } from "../env.ts"
import { ProviderError } from "./provider-core.ts"

/**
 * One users.stop per mailbox (review of 9eda094b7a4). A Gmail watch belongs
 * to the mailbox, and every connection of that mailbox shares it, so when
 * several connections of one mailbox end together only one of them sends the
 * stop. The mailbox's AccountIndexDO (keyed by the alias) holds the claim: the
 * first claimer stops, the others skip; a failed stop releases the claim; a
 * claim that is still running after an hour is free again; a new link of the
 * mailbox clears it.
 */

/**
 * A failure that a retry cannot fix: Google refused the token (401) or the
 * grant is gone (invalid_grant at refresh). Recorded at once, never retried.
 */
export const permanentStopFailure = (e: unknown) => e instanceof ProviderError && (e.code === "needs_reauth" || e.status === 401)

/** A claim this old is free again (a crashed claimer); far below the drain's 6 h window. */
export const STOP_CLAIM_LEASE_MS = 5 * 60_000
/** A finished stop covers this mailbox for this long; then a new stop may be sent (a second stop is harmless). */
export const STOP_DONE_TTL_MS = 10 * 60_000

export const stopMailboxOnce = async (env: Env, alias: string, connection: string, stop: () => Promise<unknown>): Promise<"stopped" | "skipped"> => {
  const index = env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(alias))
  const claim = await index.claimStop(connection, Date.now())
  if (claim === "done") return "skipped"
  if (claim === "busy") throw new ProviderError("provider.error", "another connection of this mailbox is stopping its watch", true)
  try {
    await stop()
  } catch (e) {
    await index.finishStop(connection, false).catch(() => undefined)
    throw e
  }
  // The stop happened: a lost bookkeeping call must not turn it into a retried failure.
  await index.finishStop(connection, true).catch((e) => console.error(JSON.stringify({ msg: "stop claim finish failed", connection, error: e instanceof Error ? e.name : "unknown" })))
  return "stopped"
}
