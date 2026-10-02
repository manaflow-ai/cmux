import type { Env } from "./env.ts"

export type PlanetscaleReadResult = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly code: string; readonly message: string }

export interface ReadQuery {
  query<R>(text: string, values: Array<unknown>): Promise<{ rows: Array<R> }>
}

/**
 * Reads owned by `cloud:planetscale`: PlanetScale `cmux-next` through the
 * read-only Hyperdrive binding (HYPERDRIVE_READ, a role that may only
 * SELECT). These reads never write; projections are written only by outbox
 * drains (projection.ts). One short-lived client per request (Hyperdrive pools).
 */
export const withReadClient = async <T>(env: Env, fn: (q: ReadQuery) => Promise<T>): Promise<T> => {
  if (!env.HYPERDRIVE_READ) throw new Error("HYPERDRIVE_READ binding missing: app search is not configured on this deployment")
  // Loaded on first use only: keeps pg (CommonJS, node:net) off other request paths and out of unit tests.
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: env.HYPERDRIVE_READ.connectionString })
  await client.connect()
  try {
    return await fn(client as unknown as ReadQuery)
  } finally {
    await client.end()
  }
}
