import { EMPTY_ROWS, idFactory, type Domain, type OpFrame, type OwnerFrame, type Principal, type SqlStore } from "@cmux/ownership"

/** The entity an owner object is bound to, or null for an object nobody created (reads only). */
export const boundEntityOf = (store: SqlStore): string | null => {
  if (store.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'do_entity'`).length === 0) return null
  return store.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]?.entity ?? null
}

/** True when the object exists for `entity`; throws for an object bound to another entity. */
export const isBoundTo = (store: SqlStore, entity: string): boolean => {
  const row = boundEntityOf(store)
  if (row !== null && row !== entity) throw new Error(`object bound to ${row}, not ${entity}`)
  return row !== null
}

/** Creates an owner object's binding tables (the first write of a new object). */
export const createBinding = (store: SqlStore, entity: string): void => {
  store.exec(`CREATE TABLE IF NOT EXISTS do_entity (id INTEGER PRIMARY KEY CHECK (id = 1), entity TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)`)
  store.exec(`CREATE TABLE IF NOT EXISTS do_wake (id INTEGER PRIMARY KEY CHECK (id = 1), attempts INTEGER NOT NULL)`)
  store.exec(`INSERT INTO do_entity (id, entity) VALUES (1, ?)`, entity)
}

/**
 * Decides an op on a domain's initial state without storage (OwnerDO.submit for an object that
 * does not exist yet). Returns the reject and settled frames when authorization or the reducer
 * refuses, or undefined when the op would commit (then the object is created). Nothing is
 * recorded: a refusal on an empty object is decided again the same way on a retry.
 */
export const refusalOnInitial = <S>(domain: Domain<S>, stream: string, principal: Principal, frame: OpFrame): Array<OwnerFrame> | undefined => {
  const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
  const refuse = (code: string, message: string, extra: { details?: unknown; retryable?: boolean } = {}): Array<OwnerFrame> => [
    { t: "reject", tx: "", idempotency_key: key, code, message, ...(extra.details === undefined ? {} : { details: extra.details }), retryable: extra.retryable ?? false, replayed: false },
    { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false }
  ]
  if (key.length === 0 || key.length > 128) return refuse("validation.invalid", "idempotency_key is required (1 to 128 characters)")
  const state = domain.initial()
  const denied = domain.authorize?.(state, frame.op, frame.params as never, principal)
  if (denied) return refuse(denied.code, denied.message, denied)
  if (frame.expected_revision !== undefined && frame.expected_revision !== "0") return refuse("revision.conflict", "expected_revision does not match", { details: { expected: frame.expected_revision, actual: "0" } })
  const r = domain.reduce(state, frame.op, frame.params as never, { principal, origin: (typeof frame.origin === "string" ? frame.origin : "cli") as never, now: Date.now(), tx: "preflight", newId: idFactory("preflight"), rows: EMPTY_ROWS, idempotencyKey: key })
  return r.ok ? undefined : refuse(r.code, r.message, r)
}
