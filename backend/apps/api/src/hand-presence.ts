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
 *   CURRENT presence key over the same registration text (the new key's text), or a fresh sign-in
 *   (the session's Stack sign-in is at most HAND_PRESENCE_FRESH_MINUTES old, default 10).
 * - An App Attest attestation is accepted where the client sends one (client data: the new key's
 *   thumbprint, as in user-presence-key.ts); a bad one is refused, a good one is recorded.
 * - Every registration is recorded (hand_presence_event) and audited; a replacement also sends the
 *   owner's devices a `hand-presence-key` wire event ("a new Touch ID key was registered on
 *   <install>").
 */

export interface PresenceInput {
  readonly install: string
  readonly jwk: unknown
  /** The install key's signature over presenceRegistration(install, new key). */
  readonly signature: string
  /** The current presence key's signature over the same text (a replacement). */
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
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_presence_event (id TEXT PRIMARY KEY, install TEXT NOT NULL, thumbprint TEXT NOT NULL, by TEXT NOT NULL, attested INTEGER NOT NULL, key_id TEXT, at INTEGER NOT NULL)`)

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
  const text = presenceRegistration(env, input.install, pub)
  if (!(await verifyInstallSignature(installKey, text, input.signature))) return no("bad signature")
  const thumbprint = jwkThumbprint(pub)
  let attested = false
  if (input.attestation !== undefined) {
    if (!env.IOS_APP_ID) return no("App Attest is not configured on this deployment")
    if (typeof input.attestation !== "string" || typeof input.key_id !== "string") return no("an attestation needs its key_id")
    const r = verifyAttestation({ attestation: input.attestation, keyId: input.key_id, clientData: new TextEncoder().encode(thumbprint), appId: env.IOS_APP_ID, allowDevelopment: env.IOS_APP_ATTEST_DEVELOPMENT === "true", now })
    if (!r.ok) return no(`attestation refused (${r.reason})`)
    attested = true
  }
  const current = presenceKey(sql, input.install) as { x?: string; y?: string } | null
  let by: "first" | "unchanged" | "current_key" | "fresh_sign_in" = "first"
  if (current && current.x === pub.x && current.y === pub.y) by = "unchanged"
  else if (current) {
    if (input.current_signature && (await verifyInstallSignature(current as JsonWebKey, text, input.current_signature))) by = "current_key"
    else if (typeof input.signed_in_at === "number" && now - input.signed_in_at >= 0 && now - input.signed_in_at <= freshMs(env)) by = "fresh_sign_in"
    else return no(`this install already has a presence key: replacing it needs a signature by the current key, or a sign-in in the last ${freshMs(env) / 60_000} minutes`)
  }
  if (by !== "unchanged") sql.exec(`INSERT INTO hand_presence_key (install, jwk, at) VALUES (?, ?, ?) ON CONFLICT(install) DO UPDATE SET jwk = excluded.jwk, at = excluded.at`, input.install, JSON.stringify(pub), now)
  sql.exec(`INSERT INTO hand_presence_event (id, install, thumbprint, by, attested, key_id, at) VALUES (?, ?, ?, ?, ?, ?, ?)`, crypto.randomUUID(), input.install, thumbprint, by, attested ? 1 : 0, attested ? (input.key_id ?? null) : null, now)
  return { ok: true, by, attested, replaced: by === "current_key" || by === "fresh_sign_in" }
}
