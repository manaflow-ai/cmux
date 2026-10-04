import { EMPTY_ROWS, idFactory, type Domain, type OpFrame, type OwnerFrame, type Principal } from "@cmux/ownership"

/**
 * Decides an op on a domain's initial state without storage (OwnerDO.submit for an object that
 * does not exist yet). Returns the reject and settled frames when authorization or the reducer
 * refuses, or undefined when the op would commit (then the object is created). Nothing is
 * recorded: a refusal on an empty object is decided again the same way on a retry.
 */
export const refusalOnInitial = <S>(domain: Domain<S>, stream: string, principal: Principal, frame: OpFrame): Array<OwnerFrame> | undefined => {
  const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
  if (key.length === 0 || key.length > 128) return undefined
  const state = domain.initial()
  const refuse = (code: string, message: string, extra: { details?: unknown; retryable?: boolean } = {}): Array<OwnerFrame> => [
    { t: "reject", tx: "", idempotency_key: key, code, message, ...(extra.details === undefined ? {} : { details: extra.details }), retryable: extra.retryable ?? false, replayed: false },
    { t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok: false }
  ]
  const denied = domain.authorize?.(state, frame.op, frame.params as never, principal)
  if (denied) return refuse(denied.code, denied.message, denied)
  if (frame.expected_revision !== undefined && frame.expected_revision !== "0") return refuse("revision.conflict", "expected_revision does not match", { details: { expected: frame.expected_revision, actual: "0" } })
  const r = domain.reduce(state, frame.op, frame.params as never, { principal, origin: (typeof frame.origin === "string" ? frame.origin : "cli") as never, now: Date.now(), tx: "preflight", newId: idFactory("preflight"), rows: EMPTY_ROWS, idempotencyKey: key })
  return r.ok ? undefined : refuse(r.code, r.message, r)
}
