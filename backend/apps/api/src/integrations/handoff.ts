import { createHash } from "node:crypto"
import { INTEGRATION_ATTEMPT_PATTERN, isConnectReturnTo, isDevReturnTo, isIntegrationCompleteReturnTo } from "@cmux/protocol"
import type { Env } from "../env.ts"
import { open, seal, type SealedSecret } from "./crypto.ts"
import { STATE_TTL_SECONDS, verifyState } from "./state.ts"

/**
 * A connect the cmux app started finishes in two halves, so the provider's `code` never leaves HTTPS:
 *
 * 1. The provider redirects the person's browser to the console's callback. The console verifies the state and posts
 *    the provider's answer here (`POST /v1/integrations/handoff`, no session: a person who started the connect in the
 *    app need not be signed in to the console). The ConnectionDO keeps it sealed under the state's connection and
 *    answers a single-use handoff value. The browser then opens `<scheme>://integration/complete?connection=&handoff=`.
 * 2. The app that started the connect (it holds the attempt secret whose hash the state carries, and remembers the
 *    connection) sends `integration.complete {state, handoff, attempt}` with its own session. Only then does the
 *    ConnectionDO redeem the code at the provider, as that person, for that connection.
 *
 * Neither half alone finishes anything: the handoff value reaches only the browser the provider redirected (and the
 * app on that machine); the attempt secret and session stay in the app that started the connect. A redirect that
 * lands in someone else's browser therefore cannot be finished by the person who started it, and a link handed to
 * another app finishes nothing.
 */
export const INTEGRATION_HANDOFF_PATH = "/v1/integrations/handoff"

/** What the Worker hands the ConnectionDO about a verified state for integration.complete. */
export interface CompletionState {
  readonly conn: string
  readonly provider: string
  /** When the state was signed (seconds). */
  readonly issued_at: number
  /** An app-started connect: the handoff value its completion link carried (the secret was checked by the Worker). */
  readonly handoff?: string
}

/** base64url SHA-256: an attempt secret's hash as the state carries it, a state's or handoff value's storage key. */
export const attemptHashOf = (secret: string): string => createHash("sha256").update(secret).digest("base64url")

/** integration.connect's optional repo, return link and app attempt (the op's schema already checked their shape). */
export const connectAsk = (environment: string, params: unknown): { repo?: string; return_to?: string; attempt_hash?: string } => {
  const p = (params ?? {}) as { repo?: unknown; return_to?: unknown; attempt_hash?: unknown }
  // cmux-dev links are for development builds: dropped on production, the app's completion link included.
  const link = isConnectReturnTo(p.return_to) && !(environment === "production" && isDevReturnTo(p.return_to)) ? p.return_to : undefined
  const attempt = typeof p.attempt_hash === "string" && INTEGRATION_ATTEMPT_PATTERN.test(p.attempt_hash) ? p.attempt_hash : undefined
  // The app's completion link goes only with the app's attempt hash: without it the connect is an ordinary one the
  // signed-in console finishes, and the hash never goes without that link.
  const returned = link === undefined ? {} : isIntegrationCompleteReturnTo(link) ? (attempt ? { return_to: link, attempt_hash: attempt } : {}) : { return_to: link }
  return { ...(typeof p.repo === "string" ? { repo: p.repo } : {}), ...returned }
}

/** The provider's answer the console hands over (the callback's query, never more). */
export interface HandoffAnswer {
  readonly code?: string
  readonly installation_id?: string
  readonly setup_action?: string
}

/** What the ConnectionDO keeps for one handed-over state until the app finishes it. */
interface Stashed extends HandoffAnswer {
  readonly handoff: string
}

/** The ConnectionDO's tables: handed-over provider answers (sealed, single use) and the states already used. */
export const createHandoffTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS integration_handoffs (state_hash TEXT PRIMARY KEY, conn TEXT NOT NULL, answer_hash TEXT NOT NULL, sealed TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS integration_states_used (state_hash TEXT PRIMARY KEY, conn TEXT NOT NULL, used_at INTEGER NOT NULL)`)
}

/** Forgets handed-over answers past their state's lifetime, and used states once no signature on them could still verify. */
export const pruneHandoffs = (sql: SqlStorage, now: number) => {
  sql.exec(`DELETE FROM integration_handoffs WHERE expires_at < ?`, now)
  sql.exec(`DELETE FROM integration_states_used WHERE used_at < ?`, now - 2 * STATE_TTL_SECONDS * 1000)
}

export const stateUsed = (sql: SqlStorage, stateHash: string): boolean =>
  sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM integration_states_used WHERE state_hash = ?`, stateHash).toArray()[0]!.n > 0

/** Marks a state used before its code goes to the provider; `release` undoes it when the call may run again. */
export const markStateUsed = (sql: SqlStorage, stateHash: string, conn: string, now: number) => {
  sql.exec(`INSERT INTO integration_states_used (state_hash, conn, used_at) VALUES (?, ?, ?)`, stateHash, conn, now)
  return { release: () => void sql.exec(`DELETE FROM integration_states_used WHERE state_hash = ?`, stateHash) }
}

const aad = (owner: string, conn: string, stateHash: string) => new TextEncoder().encode(`cmux-handoff-v1|${owner}|${conn}|${stateHash}`)
const answerHash = (a: HandoffAnswer) => attemptHashOf(JSON.stringify([a.code ?? null, a.installation_id ?? null, a.setup_action ?? null]))
const randomValue = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/**
 * Keeps `answer` for `stateHash` (sealed) and answers its handoff value. The same answer again (a reload of the
 * callback) answers the same value; another answer for the same state is refused: a state hands over once.
 */
export const stashHandoff = async (sql: SqlStorage, kek: string, at: { owner: string; conn: string; stateHash: string; expiresAt: number }, answer: HandoffAnswer): Promise<{ ok: true; handoff: string } | { ok: false; message: string }> => {
  const hash = answerHash(answer)
  const prior = sql.exec<{ conn: string; answer_hash: string; sealed: string }>(`SELECT conn, answer_hash, sealed FROM integration_handoffs WHERE state_hash = ?`, at.stateHash).toArray()[0]
  if (prior) {
    if (prior.conn !== at.conn || prior.answer_hash !== hash) return { ok: false, message: "this connection link was already used; start again from Connect" }
    const kept = JSON.parse(await open(kek, JSON.parse(prior.sealed) as SealedSecret, aad(at.owner, at.conn, at.stateHash))) as Stashed
    return { ok: true, handoff: kept.handoff }
  }
  const handoff = randomValue()
  const sealed = await seal(kek, JSON.stringify({ ...answer, handoff } satisfies Stashed), aad(at.owner, at.conn, at.stateHash))
  // A concurrent handoff of the same state may have landed during the await: the first one stands.
  if (sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM integration_handoffs WHERE state_hash = ?`, at.stateHash).toArray()[0]!.n > 0) return stashHandoff(sql, kek, at, answer)
  sql.exec(`INSERT INTO integration_handoffs (state_hash, conn, answer_hash, sealed, expires_at) VALUES (?, ?, ?, ?, ?)`, at.stateHash, at.conn, hash, JSON.stringify(sealed), at.expiresAt)
  return { ok: true, handoff }
}

/** The answer handed over for `stateHash` when `handoff` is its value; undefined otherwise. Does not remove it. */
export const readHandoff = async (sql: SqlStorage, kek: string, at: { owner: string; conn: string; stateHash: string }, handoff: string, now: number): Promise<HandoffAnswer | undefined> => {
  const row = sql.exec<{ conn: string; sealed: string; expires_at: number }>(`SELECT conn, sealed, expires_at FROM integration_handoffs WHERE state_hash = ?`, at.stateHash).toArray()[0]
  if (!row || row.conn !== at.conn || row.expires_at < now) return undefined
  const kept = JSON.parse(await open(kek, JSON.parse(row.sealed) as SealedSecret, aad(at.owner, at.conn, at.stateHash))) as Stashed
  // Compared as hashes, so the comparison's timing says nothing about the stored value.
  if (attemptHashOf(kept.handoff) !== attemptHashOf(handoff)) return undefined
  return { ...(kept.code ? { code: kept.code } : {}), ...(kept.installation_id ? { installation_id: kept.installation_id } : {}), ...(kept.setup_action ? { setup_action: kept.setup_action } : {}) }
}

export const dropHandoff = (sql: SqlStorage, stateHash: string) => void sql.exec(`DELETE FROM integration_handoffs WHERE state_hash = ?`, stateHash)

/** What the ConnectionDO's `handoff` RPC answers. */
export type HandoffReply = { ok: true; handoff: string } | { ok: false; code: string; message: string }

const str = (v: unknown, max: number, pattern?: RegExp): string | undefined | null =>
  v === undefined ? undefined : typeof v === "string" && v.length > 0 && v.length <= max && (!pattern || pattern.test(v)) ? v : null

const refuse = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message, retryable: false } }, { status, headers: { "cache-control": "no-store" } })

/**
 * POST /v1/integrations/handoff {state, code?, installation_id?, setup_action?}: the console's callback hands an
 * app-started connect's provider answer to the API. No session: the signed state is the authority, and the answer
 * is only kept; it is redeemed when the app that started the connect finishes it. Answers
 * `{ok: true, value: {connection, return_to, handoff}}`.
 */
export const handleIntegrationHandoff = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return refuse(405, "validation.invalid", "POST only")
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null
  if (!body || typeof body !== "object") return refuse(400, "validation.invalid", "a JSON body is required")
  const state = str(body.state, 4000)
  const code = str(body.code, 2000)
  const installation = str(body.installation_id, 20, /^[0-9]{1,20}$/)
  const setup = str(body.setup_action, 40)
  if (!state || code === null || installation === null || setup === null) return refuse(400, "validation.invalid", "state, code, installation_id or setup_action is malformed")
  const st = await verifyState(env, state)
  const invalid = (message: string) => refuse(400, "integration.state_invalid", message)
  if (!st) return invalid("the connection link expired or is not valid")
  // Only a connect the app started, with its attempt hash, hands over; any other is finished by the signed-in console.
  if (st.attempt_hash === undefined || st.return_to === undefined || !isIntegrationCompleteReturnTo(st.return_to)) return invalid("this connection is finished on the console")
  if (env.ENVIRONMENT === "production" && isDevReturnTo(st.return_to)) return invalid("a development build cannot finish a production connection")
  if (st.installation !== undefined && installation !== undefined && installation !== String(st.installation)) return invalid("the redirect names another GitHub installation than this connection attempt")
  if (!env.INTEGRATIONS_KEK) return refuse(400, "integration.not_configured", "integrations are not configured on this deployment")
  const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(st.team))
  const reply = (await stub.handoff(st.team, { conn: st.conn, user: st.user, provider: st.provider, issued_at: st.issued_at, state_hash: attemptHashOf(state) }, {
    ...(code ? { code } : {}),
    ...(installation ? { installation_id: installation } : {}),
    ...(setup ? { setup_action: setup } : {})
  })) as HandoffReply
  if (!reply.ok) return refuse(400, reply.code, reply.message)
  return Response.json({ ok: true, value: { connection: st.conn, return_to: st.return_to, handoff: reply.handoff } }, { headers: { "cache-control": "no-store" } })
}
