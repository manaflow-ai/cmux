import type { SqlStore } from "@cmux/ownership"

/** Adapt Durable Object SQLite's synchronous API to the OwnerEngine store contract. */
export const doSql = (storage: DurableObjectStorage): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => storage.sql.exec(q, ...params).toArray() as Array<T>,
  transaction: <T>(fn: () => T): T => storage.transactionSync(fn)
})
