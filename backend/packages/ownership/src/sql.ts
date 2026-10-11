/**
 * Synchronous SQL, shaped like Durable Object `ctx.storage.sql` so the same
 * engine runs in a DO, in node:sqlite or bun:sqlite tests and on a self-hosted server.
 */
export interface SqlStore {
  exec<T = Record<string, unknown>>(query: string, ...params: Array<unknown>): Array<T>
  /** Runs `fn` atomically. A throw rolls back every write. */
  transaction<T>(fn: () => T): T
}
