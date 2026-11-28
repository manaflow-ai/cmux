import { verifyAttestation } from "./app-attest.ts"
import { verifyInstallSignature } from "./auth.ts"
import { jwkThumbprint } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { presenceKey, presenceRegistration } from "./hand-levels.ts"
import type { HandCaller } from "./hand-wire.ts"

/**
 * The presence key (Touch ID / Face ID, Secure Enclave) of one of the owner's app installs: the key
 * that signs a hand level raise (hand-levels.ts). The rule (#13742, hq-6d, accepted 2026-10-17):
 *
 * - The install key signs every registration (`presenceRegistration`), so a session alone never
 *   registers a key.
 * - The FIRST key of an install needs only that.
 * - A REPLACEMENT (the install already has another key) also needs one of: a signature by the
 *   CURRENT presence key over `presenceReplacement` (this install's registration count, the old
 *   and the new key's thumbprints, so an old signature never counts again: no rollback replay), or
 *   a fresh sign-in (the session's Stack sign-in is at most HAND_PRESENCE_FRESH_MINUTES old,
 *   default 10). GET /v1/hands/presence-key?install= gives the client the count and thumbprint.
 * - The presence key is never the install key itself (then Touch ID would protect nothing).
 * - An App Attest attestation is accepted where the client sends one (client data: the new key's
 *   thumbprint, as in user-presence-key.ts); a bad one is refused, a good one is recorded.
 * - Every registration is recorded (hand_presence_event) and audited; a replacement also sends the
 *   owner's devices a `hand-presence-key` wire event ("a new Touch ID key was registered on
 *   <install>").
 */

/** The text the current presence key signs to let a new key replace it. */
export const presenceReplacement = (env: Env, install: string, gen: number, oldThumb: string, newThumb: string) =>
  `cmux-hand-presence-replace:${env.ENVIRONMENT ?? "local"}:${install}:${gen}:${oldThumb}:${newThumb}`

/** How many keys this install has registered (the replacement text's count) and its current key's thumbprint. */
export const presenceState = (sql: SqlStorage, install: string): { gen: number; thumbprint: string | null } => {
  const gen = sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM hand_presence_event WHERE install = ? AND by != 'unchanged'`, install).toArray()[0]?.n ?? 0
  const k = presenceKey(sql, install) as { x?: string; y?: string } | null
  return { gen, thumbprint: k?.x && k.y ? jwkThumbprint({ kty: "EC", crv: "P-256", x: k.x, y: k.y }) : null }
}

export interface PresenceInput {
  readonly install: string
  readonly jwk: unknown
  /** The install key's signature over presenceRegistration(install, new key). */
  readonly signature: string
  /** The current presence key's signature over presenceReplacement (a replacement). */
  readonly current_signature?: string
  /** App Attest (iOS): the attestation object and key id over the new key's thumbprint. */
  readonly attestation?: string
  readonly key_id?: string
  /** When the caller's session was signed in (Stack session created_at, ms), when known. */
  readonly signed_in_at?: number | null
}

export type PresenceResult =
  | { readonly ok: false; readonly why: string }
  | { readonly ok: true; readonly by: "first" | "unchanged" | "current_key" | "fresh_sign_in"; readonly attested: boolean; readonly replaced: boolean }

export const createPresenceEventTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_presence_event (id TEXT PRIMARY KEY, install TEXT NOT NULL, thumbprint TEXT NOT NULL, by TEXT NOT NULL, attested INTEGER NOT NULL, key_id TEXT, attest_key TEXT, at INTEGER NOT NULL)`)

const freshMs = (env: Env) => {
  const m = Number(env.HAND_PRESENCE_FRESH_MINUTES ?? "10")
  return (Number.isFinite(m) && m > 0 && m <= 60 ? m : 10) * 60_000
}

export const registerPresence = async (env: Env, sql: SqlStorage, caller: HandCaller, owner: string, input: PresenceInput, now = Date.now()): Promise<PresenceResult> => {
  const no = (why: string): PresenceResult => ({ ok: false, why })
  if (caller.kind !== "owner" || caller.user !== owner) return no("only the owner registers a presence key")
  const k = input.jwk as { kty?: unknown; crv?: unknown; x?: unknown; y?: unknown } | null
  if (!k || k.kty !== "EC" || k.crv !== "P-256" || typeof k.x !== "string" || typeof k.y !== "string") return no("the presence key is a P-256 public JWK")
  const pub = { kty: "EC", crv: "P-256", x: k.x, y: k.y }
  const user = env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as { personKey(entity: string, install: string): Promise<JsonWebKey | null> }
  const installKey = await user.personKey(owner, input.install).catch(() => null)
  if (!installKey) return no("that install is not one of the owner's active Mac or iPhone apps")
  const ik = installKey as { x?: string; y?: string }
  if (ik.x === pub.x && ik.y === pub.y) return no("the presence key must be its own Secure Enclave key, not the install key")
  const text = presenceRegistration(env, input.install, pub)
  if (!(await verifyInstallSignature(installKey, text, input.signature))) return no("bad signature")
  const thumbprint = jwkThumbprint(pub)
  let attested = false
  let attestKey: string | null = null
  if (input.attestation !== undefined) {
    if (!env.IOS_APP_ID) return no("App Attest is not configured on this deployment")
    if (typeof input.attestation !== "string" || typeof input.key_id !== "string") return no("an attestation needs its key_id")
    const r = verifyAttestation({ attestation: input.attestation, keyId: input.key_id, clientData: new TextEncoder().encode(thumbprint), appId: env.IOS_APP_ID, allowDevelopment: env.IOS_APP_ATTEST_DEVELOPMENT === "true", now })
    if (!r.ok) return no(`attestation refused (${r.reason})`)
    attested = true
    attestKey = JSON.stringify(r.key)
  }
  // Every check that waits comes first; the read and the write below run with no await between
  // them, so a replacement checked against a key that changed meanwhile never writes.
  const before = presenceState(sql, input.install)
  const fresh = typeof input.signed_in_at === "number" && now - input.signed_in_at >= 0 && now - input.signed_in_at <= freshMs(env)
  const current = presenceKey(sql, input.install) as { x?: string; y?: string } | null
  const byKey = current && before.thumbprint && input.current_signature
    ? await verifyInstallSignature(current as JsonWebKey, presenceReplacement(env, input.install, before.gen, before.thumbprint, thumbprint), input.current_signature)
    : false
  const after = presenceState(sql, input.install)
  if (after.gen !== before.gen || after.thumbprint !== before.thumbprint) return no("the presence key changed while this registration was checked; try again")
  let by: "first" | "unchanged" | "current_key" | "fresh_sign_in" = "first"
  if (before.thumbprint === thumbprint) by = "unchanged"
  else if (before.thumbprint) {
    if (byKey) by = "current_key"
    else if (fresh) by = "fresh_sign_in"
    else {
      const when = typeof input.signed_in_at === "number" ? `this session signed in ${Math.round((now - input.signed_in_at) / 60_000)} min ago` : "this session's sign-in time is not known"
      return no(`this install already has a presence key: replacing it needs a signature by the current key, or a sign-in in the last ${freshMs(env) / 60_000} minutes (${when})`)
    }
  }
  if (by !== "unchanged") sql.exec(`INSERT INTO hand_presence_key (install, jwk, at) VALUES (?, ?, ?) ON CONFLICT(install) DO UPDATE SET jwk = excluded.jwk, at = excluded.at`, input.install, JSON.stringify(pub), now)
  sql.exec(`INSERT INTO hand_presence_event (id, install, thumbprint, by, attested, key_id, attest_key, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, crypto.randomUUID(), input.install, thumbprint, by, attested ? 1 : 0, attested ? (input.key_id ?? null) : null, attestKey, now)
  return { ok: true, by, attested, replaced: by === "current_key" || by === "fresh_sign_in" }
}
