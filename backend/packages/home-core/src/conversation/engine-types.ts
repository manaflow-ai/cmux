/**
 * Mirror of the @cmux/ownership types this package needs, as of PR 16827
 * (row-backed domains, DO-to-DO outbox). Replace with the import after it
 * merges; keep the shapes identical until then.
 */

export interface Principal {
  readonly identity: string
  readonly user?: string
  readonly team?: string
  readonly install?: string
  readonly agent?: string
  readonly grant?: string
  readonly kind?: "session" | "install" | "agent" | "system"
  readonly email?: string | null
  /** True only when Stack verified `email`; owners must not trust `email` without it (requested of PR 16827). */
  readonly email_verified?: boolean
  readonly display_name?: string
  readonly grant_classes?: ReadonlyArray<string>
}

export interface StoredRow<T = unknown> {
  readonly key: string
  /** Order within the table (for example the message seq); null when unordered. */
  readonly n: number | null
  readonly row: T
}

export interface RowRange {
  readonly after?: number
  readonly before?: number
  readonly limit: number
  readonly desc?: boolean
}

export interface RowReader {
  get<T>(table: string, key: string): StoredRow<T> | undefined
  range<T>(table: string, range: RowRange): Array<StoredRow<T>>
}

export type RowWrite =
  | { readonly table: string; readonly op: "upsert"; readonly key: string; readonly n?: number | null; readonly row: unknown }
  | { readonly table: string; readonly op: "delete"; readonly key: string }

export interface OutboxItem {
  readonly kind: string
  readonly entity: string
  readonly payload: unknown
  readonly target?: { readonly class: string; readonly name: string; readonly coalesce?: string }
}

export interface Reject {
  readonly code: string
  readonly message: string
  readonly details?: unknown
  readonly retryable?: boolean
}

export interface ReduceContext {
  readonly principal: Principal
  readonly now: number
  readonly tx: string
  readonly newId: (prefix: string) => string
  readonly rows: RowReader
}

export type ReduceResult<S> =
  | {
      readonly ok: true
      readonly state: S
      readonly value: unknown
      readonly changed?: boolean
      readonly outbox?: ReadonlyArray<OutboxItem>
      readonly writes?: ReadonlyArray<RowWrite>
    }
  | ({ readonly ok: false } & Reject)

export interface Domain<S, P = unknown> {
  readonly initial: () => S
  readonly reduce: (state: S, op: string, params: P, ctx: ReduceContext) => ReduceResult<S>
  readonly authorize?: (state: S, op: string, params: P, principal: Principal) => Reject | undefined
}
