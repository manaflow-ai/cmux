/**
 * The @cmux/ownership types home-core builds on (row-backed domains, DO-to-DO
 * outbox, PR 16827), re-exported so every module imports one place.
 */
export type {
  Domain,
  OutboxItem,
  Principal,
  Reject,
  ReduceContext,
  ReduceResult,
  RowRange,
  RowReader,
  RowWrite,
  StoredRow
} from "@cmux/ownership"

import type { ReduceContext as Ctx, RowReader as Reader } from "@cmux/ownership"

const NO_ROWS: Reader = { get: () => undefined, range: () => [] }

/** The op's row reader; JSON-only owners pass none, which reads as empty tables. */
export const rowsOf = (ctx: Ctx): Reader => ctx.rows ?? NO_ROWS
