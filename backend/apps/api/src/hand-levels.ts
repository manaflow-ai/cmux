import { verifyInstallSignature } from "./auth.ts"
import type { Env } from "./env.ts"
import type { HandCaller, Profile } from "./hand-wire.ts"

/**
 * A hand's permission level (Lawrence 2026-10-16), set by its owner; a Chief may only lower it.
 *
 *   full       no classifier, no approvals; only the hand's integrity guard (its own key, config,
 *              binary) stays: it protects the account, not the person's files. Sandbox default.
 *   auto       the classifier's verdict; risky actions ask; the hand's hard denies. Mac default.
 *   ask        every write, program run and agent session asks.
 *   read-only  reads only.
 *
 * The integrity guard on the hand only stops mistakes and plain attempts (a path check and an argv
 * word check); at `full` a program the person allowed can still read the hand's files. The real
 * boundary is the person's choice of level.
 *
 * Raising a level (to a looser one) needs the OWNER's presence proof: a signature over a single-use
 * challenge by the PRESENCE key of one of the owner's active app installs (kind mac or ios). The app
 * makes that key in the Secure Enclave with the userPresence access-control flag (Touch ID / Face ID
 * on every signature) and registers it here, signed by its install key (registerPresenceKey). A
 * person's session alone does not raise, and a Chief never does. An approval answer (allow) uses the
 * plain install key: no prompt per request. Lowering needs no proof. An owner default per profile
 * (the index) applies to hands minted after it is set, under the same rules.
 */
export const LEVELS = ["full", "auto", "ask", "read-only"] as const
export type Level = (typeof LEVELS)[number]
export const isLevel = (v: unknown): v is Level => typeof v === "string" && (LEVELS as ReadonlyArray<string>).includes(v)

/** Looser to stricter: a higher rank allows more. */
const RANK: Readonly<Record<Level, number>> = { "read-only": 0, ask: 1, auto: 2, full: 3 }
export const raises = (from: Level, to: Level) => RANK[to] > RANK[from]
export const defaultLevel = (profile: Profile | null): Level => (profile === "mac" ? "auto" : "full")
/** Reads, and the controls that only stop or refuse agent work (they never need an approval). */
export const READ_ACTIONS: ReadonlySet<string> = new Set(["fs.read", "fs.list", "fs.glob", "fs.grep", "agent.events", "agent.cancel", "agent.stop", "agent.deny"])

const CHALLENGE_TTL_MS = 5 * 60_000

/** The text a person's app signs to raise `target` (a hand id, or `default:<profile>`) to `level`. */
export const proofMessage = (env: Env, target: string, level: Level, nonce: string) => `cmux-hand-level:${env.ENVIRONMENT ?? "local"}:${target}:${level}:${nonce}`

export const createLevelTables = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_level_challenge (nonce TEXT PRIMARY KEY, target TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
}

export const issueChallenge = (sql: SqlStorage, target: string): { nonce: string; expires_at: number } => {
  const now = Date.now()
  sql.exec(`DELETE FROM hand_level_challenge WHERE expires_at < ?`, now)
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(24)), (b) => b.toString(16).padStart(2, "0")).join("")
  sql.exec(`INSERT INTO hand_level_challenge (nonce, target, expires_at) VALUES (?, ?, ?)`, nonce, target, now + CHALLENGE_TTL_MS)
  return { nonce, expires_at: now + CHALLENGE_TTL_MS }
}

export interface Proof {
  readonly install: string
  readonly nonce: string
  readonly signature: string
}

/**
 * Checks a raise: the caller is the owner's own session, the nonce was issued for `target` and is
 * spent now (single use, also when the signature fails), and one of the owner's active app installs
 * signed the message. An error text, or null when it holds.
 */
export const checkRaise = async (env: Env, sql: SqlStorage, caller: HandCaller, owner: string, target: string, level: Level, proof: Proof | undefined, presenceOf: (install: string) => Promise<JsonWebKey | null>): Promise<string | null> => {
  if (caller.kind !== "owner" || caller.user !== owner) return "only the owner raises a hand's level"
  if (!proof) return "raising a level needs the owner's app proof (install, nonce, signature)"
  const row = sql.exec<{ target: string; expires_at: number }>(`SELECT target, expires_at FROM hand_level_challenge WHERE nonce = ?`, proof.nonce).toArray()[0]
  sql.exec(`DELETE FROM hand_level_challenge WHERE nonce = ?`, proof.nonce)
  if (!row || row.target !== target || row.expires_at < Date.now()) return "the challenge is unknown, used or expired"
  // The install must still be active, and its registered presence key signs.
  const user = env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as { personKey(entity: string, install: string): Promise<JsonWebKey | null> }
  if (!(await user.personKey(owner, proof.install).catch(() => null))) return "that install is not one of the owner's active Mac or iPhone apps"
  const presence = await presenceOf(proof.install).catch(() => null)
  if (!presence) return "that install has no presence key (Touch ID / Face ID) registered for hand levels"
  return (await verifyInstallSignature(presence, proofMessage(env, target, level, proof.nonce), proof.signature)) ? null : "bad signature"
}

// --- Presence keys (in the owner index object) ---

export const createPresenceTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_presence_key (install TEXT PRIMARY KEY, jwk TEXT NOT NULL, at INTEGER NOT NULL)`)

export const presenceKey = (sql: SqlStorage, install: string): JsonWebKey | null => {
  try {
    const row = sql.exec<{ jwk: string }>(`SELECT jwk FROM hand_presence_key WHERE install = ?`, install).toArray()[0]
    return row ? (JSON.parse(row.jwk) as JsonWebKey) : null
  } catch {
    return null
  }
}

/** The text an install key signs to register its presence key (binds the presence key to that install). */
export const presenceRegistration = (env: Env, install: string, jwk: { x: string; y: string }) => `cmux-hand-presence-key:${env.ENVIRONMENT ?? "local"}:${install}:${jwk.x}:${jwk.y}`

export const proofOf = (b: Record<string, unknown> | null): Proof | undefined =>
  b && typeof b.install === "string" && typeof b.nonce === "string" && typeof b.signature === "string" ? { install: b.install, nonce: b.nonce, signature: b.signature } : undefined

/** The text a person's app signs to allow one waiting hand request (single use: an approval is answered once). */
export const approvalMessage = (env: Env, hand: string, approval: string) => `cmux-hand-approval:${env.ENVIRONMENT ?? "local"}:${hand}:${approval}:allow`

/** Checks an allow: the owner's own session and a signature by one of the owner's active app installs. */
export const checkApproval = async (env: Env, caller: HandCaller, owner: string, hand: string, approval: string, install: string | undefined, signature: string | undefined): Promise<string | null> => {
  if (caller.kind !== "owner" || caller.user !== owner) return "only the owner allows a hand request"
  if (!install || !signature) return "allowing needs the owner's app proof (install, signature)"
  const user = env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as { personKey(entity: string, install: string): Promise<JsonWebKey | null> }
  const jwk = await user.personKey(owner, install).catch(() => null)
  if (!jwk) return "that install is not one of the owner's active Mac or iPhone apps"
  return (await verifyInstallSignature(jwk, approvalMessage(env, hand, approval), signature)) ? null : "bad signature"
}
