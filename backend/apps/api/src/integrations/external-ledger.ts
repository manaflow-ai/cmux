import { createHash } from "node:crypto"
import { canonicalJson } from "@cmux/ownership"
import type { ExternalReply } from "./external.ts"
import { ProviderError } from "./providers.ts"

/** Synchronous, so the ledger check and insert happen in one turn with no await between. */
const sha256 = (s: string) => createHash("sha256").update(s).digest("base64url")

/**
 * The ConnectionDO's ledger for ops with external effects (provider calls, OAuth completion):
 * a decided key replays its stored reply, a key whose call was cut off answers
 * `mutation.indeterminate` instead of calling twice, and a retryable failure (rate limit,
 * provider 5xx) releases the key so the same request may run again.
 */
export const runLedgered = async (
  sql: SqlStorage,
  engine: { readonly stream: string; readonly currentSeq: number; txTag(identity: string, key: string): string },
  op: string,
  params: Record<string, unknown>,
  identity: string,
  key: string,
  call: () => Promise<unknown>
): Promise<ExternalReply> => {
  const base = { op, transaction: engine.txTag(identity, key), idempotency_key: key, stream: engine.stream, sequence: 0 }
  const fail = (code: string, message: string, retryable = false, replayed = false): ExternalReply => ({ ...base, ok: false, error: { code, message, retryable }, replayed })
  const hash = sha256(canonicalJson({ op, params }))
  const prior = sql.exec<{ params_hash: string; status: string; reply: string | null }>(`SELECT params_hash, status, reply FROM external_calls WHERE identity = ? AND idempotency_key = ?`, identity, key).toArray()[0]
  if (prior) {
    if (prior.params_hash !== hash) return fail("idempotency.conflict", "idempotency key reused with different params")
    if (prior.status === "done" && prior.reply) return { ...(JSON.parse(prior.reply) as ExternalReply), replayed: true }
    return fail("mutation.indeterminate", "an earlier attempt with this key was interrupted; check the provider before retrying with a new key", false, true)
  }
  sql.exec(`INSERT INTO external_calls (identity, idempotency_key, op, params_hash, status, reply, created_at) VALUES (?, ?, ?, ?, 'pending', NULL, ?)`, identity, key, op, hash, Date.now())

  let reply: ExternalReply
  try {
    const value = await call()
    // Plain JSON only: a provider field that is absent (undefined) must not break the HTTP encoder.
    reply = { ...base, ok: true, value: JSON.parse(JSON.stringify(value ?? null)) as unknown, replayed: false, sequence: engine.currentSeq }
  } catch (e) {
    if (e instanceof ProviderError) reply = fail(e.code === "needs_reauth" ? "integration.unavailable" : e.code, e.message, e.retryable && e.code !== "mutation.indeterminate")
    else {
      console.error(JSON.stringify({ msg: "external op failed", op, stream: engine.stream, error: e instanceof Error ? e.name : "unknown" }))
      reply = fail("operation.failed", "the operation failed")
    }
  }
  if (!reply.ok && reply.error?.retryable) sql.exec(`DELETE FROM external_calls WHERE identity = ? AND idempotency_key = ?`, identity, key)
  else sql.exec(`UPDATE external_calls SET status = 'done', reply = ? WHERE identity = ? AND idempotency_key = ?`, JSON.stringify(reply), identity, key)
  return reply
}
