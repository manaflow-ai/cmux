import type { Principal } from "@cmux/ownership"
import { inbox as homeInbox } from "@cmux/home-core"
import type { SecondaryStream } from "./secondary-stream.ts"

/**
 * One-time migration of an inbox written before the list order index (home-core order.ts):
 * reads the entry keys once, in key windows, and commits them as `inbox.reindex` system ops.
 * Batch keys name their contents, so a rerun after a crash replays what committed. The caller
 * schedules the alarm for the outbox drain.
 */
export const reindexInbox = (inbox: SecondaryStream<homeInbox.InboxHead>, entity: string): void => {
  const engine = inbox.open(entity)
  const keys: Array<string> = []
  for (let window = engine.rows.keyRange(homeInbox.TABLE_ENTRY, { limit: 1000 }); window.length > 0; window = engine.rows.keyRange(homeInbox.TABLE_ENTRY, { after: keys[keys.length - 1]!, limit: 1000 })) {
    keys.push(...window.map((r) => r.key))
  }
  const principal: Principal = { identity: "system:inbox", kind: "system" }
  for (const batch of homeInbox.inboxReindexBatches(keys)) {
    inbox.submit(principal, { t: "op", op: "inbox.reindex", params: batch.params, idempotency_key: batch.key, origin: "script" }, () => {})
  }
}
