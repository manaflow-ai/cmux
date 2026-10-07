import type { Env } from "../env.ts"
import { aadFor, open, seal, type SealedSecret } from "./crypto.ts"
import { KmsError, kmsDecrypt, kmsEncrypt, type KmsConfig } from "./kms.ts"
import { ProviderError, type Credential, type Http } from "./provider-core.ts"

/**
 * Sealing of provider credentials (spec integrations.md "Credentials";
 * integrations-plan.md G6; CASA control C2). A fresh AES-256-GCM data key per
 * secret encrypts the credential with AAD = connection, owner, provider,
 * generation. The data key is wrapped by AWS KMS when the deployment has a
 * KMS key (stored shape v2), else by the INTEGRATIONS_KEK Worker secret (v1).
 * Both shapes stay readable; every new seal uses KMS when it is configured,
 * so v1 rows move to v2 on their next refresh or re-link.
 */

export interface SealedSecretV2 {
  readonly v: 2
  /** Which key wrapped the data key, for example `kms:arn:aws:kms:...`. */
  readonly kid: string
  readonly iv: string
  readonly ct: string
  /** KMS CiphertextBlob of the data key (base64). */
  readonly wdek: string
}

type Sealed = SealedSecret | SealedSecretV2

export interface CredentialAddress {
  readonly connection: string
  readonly owner: string
  readonly provider: string
  readonly generation: number
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
const enc = new TextEncoder()

let partialLogged = false
export const kmsConfig = (env: Env): KmsConfig | undefined => {
  const parts = [env.INTEGRATIONS_KMS_KEY_ARN, env.INTEGRATIONS_KMS_REGION, env.INTEGRATIONS_KMS_ACCESS_KEY_ID, env.INTEGRATIONS_KMS_SECRET_ACCESS_KEY]
  // A key ARN, never an alias: Decrypt names the stored key, so blobs of an alias's earlier key would fail.
  if (parts.every(Boolean) && /^arn:aws[a-z-]*:kms:[^:]+:\d+:key\/./.test(env.INTEGRATIONS_KMS_KEY_ARN!)) return { keyArn: env.INTEGRATIONS_KMS_KEY_ARN!, region: env.INTEGRATIONS_KMS_REGION!, accessKeyId: env.INTEGRATIONS_KMS_ACCESS_KEY_ID!, secretAccessKey: env.INTEGRATIONS_KMS_SECRET_ACCESS_KEY! }
  if (parts.some(Boolean) && !partialLogged) {
    partialLogged = true
    console.error(JSON.stringify({ msg: "INTEGRATIONS_KMS_* is only partly set or is not a key ARN; credentials are sealed with INTEGRATIONS_KEK" }))
  }
  return undefined
}

/** Key ARNs whose v2 rows this deployment may open: the current one and INTEGRATIONS_KMS_PREVIOUS_KEY_ARNS (comma separated). */
const openableArns = (env: Env, kms: KmsConfig) => [kms.keyArn, ...(env.INTEGRATIONS_KMS_PREVIOUS_KEY_ARNS ?? "").split(",").map((a) => a.trim()).filter(Boolean)]

/** The KMS encryption context: the key policy allows exactly these keys. */
const contextOf = (a: CredentialAddress) => ({ connection: a.connection, owner: a.owner, provider: a.provider, generation: String(a.generation) })
const aadOf = (a: CredentialAddress) => aadFor(a.connection, a.owner, a.provider, a.generation)

const kmsFailure = (e: unknown, what: string) =>
  e instanceof KmsError ? new ProviderError("integration.unavailable", `credential ${what}: ${e.message}`, e.retryable) : new ProviderError("integration.unavailable", `credential ${what} failed`)

/** Like sealCredential, and says whether KMS failed and the KEK sealed it instead. */
export const sealCredentialWithInfo = async (env: Env, http: Http, a: CredentialAddress, credential: Credential, allowFallback = true): Promise<{ sealed: Sealed; fallback: boolean }> => {
  let fallback = false
  const sealed = await sealInner(env, http, a, credential, () => (fallback = true), allowFallback)
  return { sealed, fallback }
}

export const sealCredential = (env: Env, http: Http, a: CredentialAddress, credential: Credential): Promise<Sealed> => sealInner(env, http, a, credential, () => undefined)

const sealInner = async (env: Env, http: Http, a: CredentialAddress, credential: Credential, onFallback: () => void, allowFallback = true): Promise<Sealed> => {
  const kms = kmsConfig(env)
  const plaintext = JSON.stringify(credential)
  if (!kms) {
    if (!env.INTEGRATIONS_KEK) throw new ProviderError("integration.unavailable", "integrations are not configured (no INTEGRATIONS_KEK)")
    return seal(env.INTEGRATIONS_KEK, plaintext, aadOf(a))
  }
  const dekRaw = crypto.getRandomValues(new Uint8Array(32))
  try {
    const dek = await crypto.subtle.importKey("raw", dekRaw, "AES-GCM", false, ["encrypt"])
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aadOf(a) }, dek, enc.encode(plaintext)))
    let wdek: string
    try {
      wdek = await kmsEncrypt(kms, http, dekRaw, contextOf(a))
    } catch (e) {
      // A KMS outage must not lose a fresh credential (a rotated refresh token is single use): seal it
      // under the KEK now; it moves to KMS on its next seal.
      if (!env.INTEGRATIONS_KEK || !allowFallback) throw kmsFailure(e, "seal")
      onFallback()
      // `fb` marks the row; storeCredential counts it and the re-seal job moves it to KMS later.
      return { ...(await seal(env.INTEGRATIONS_KEK, plaintext, aadOf(a))), fb: 1 } as SealedSecret
    }
    return { v: 2, kid: `kms:${kms.keyArn}`, iv: b64(iv), ct: b64(ct), wdek }
  } finally {
    dekRaw.fill(0)
  }
}

export const openCredential = async (env: Env, http: Http, a: CredentialAddress, sealedJson: string): Promise<Credential> => {
  const sealed = JSON.parse(sealedJson) as Sealed
  if (sealed.v === 1) {
    if (!env.INTEGRATIONS_KEK) throw new ProviderError("integration.unavailable", "integrations are not configured (no INTEGRATIONS_KEK)")
    return JSON.parse(await open(env.INTEGRATIONS_KEK, sealed, aadOf(a))) as Credential
  }
  if (sealed.v !== 2) throw new ProviderError("integration.unavailable", "unknown stored credential shape")
  const kms = kmsConfig(env)
  const arn = sealed.kid.startsWith("kms:") ? sealed.kid.slice(4) : ""
  if (!kms || !openableArns(env, kms).includes(arn)) throw new ProviderError("integration.unavailable", "the credential's KMS key is not configured on this deployment")
  // A previous key may live in another region: send Decrypt to the region in its ARN.
  const region = arn.split(":")[3] || kms.region
  const dekRaw = await kmsDecrypt({ ...kms, keyArn: arn, region }, http, sealed.wdek, contextOf(a)).catch((e) => {
    throw kmsFailure(e, "open")
  })
  try {
    const dek = await crypto.subtle.importKey("raw", dekRaw, "AES-GCM", false, ["decrypt"])
    return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.iv), additionalData: aadOf(a) }, dek, unb64(sealed.ct)))) as Credential
  } finally {
    dekRaw.fill(0)
  }
}

// ---------------------------------------------------------------- rows (ConnectionDO side tables)

/** Rows sealed under the KEK because KMS failed: counted (alerts read the `kms_fallback` event) and re-sealed later. */
export const createFallbackTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS kms_fallbacks (connection TEXT PRIMARY KEY, first_at INTEGER NOT NULL, count INTEGER NOT NULL, next_at INTEGER NOT NULL)`)

const RESEAL_RETRY_MS = 15 * 60_000

type Owned = { readonly id: string; readonly owner: string; readonly provider: string }
const addressOf = (c: Owned, generation: number): CredentialAddress => ({ connection: c.id, owner: c.owner, provider: c.provider, generation })

const generationOf = (sql: SqlStorage, connection: string): number | undefined => {
  const g = sql.exec<{ generation: number }>(`SELECT generation FROM credentials WHERE connection = ?`, connection).toArray()[0]?.generation
  return g === undefined ? undefined : Number(g)
}

/**
 * Seals into the `credentials` table with the next generation, and tracks a KMS fallback.
 * With `ifGeneration`, writes only when the row still has that generation after the (async) seal and
 * returns false otherwise: the re-seal job must never overwrite a credential stored while KMS answered
 * (a refresh in between may have rotated a single-use refresh token).
 */
export const storeCredential = async (sql: SqlStorage, env: Env, http: Http, c: Owned, credential: Credential, ifGeneration?: number): Promise<boolean> => {
  const before = ifGeneration ?? generationOf(sql, c.id) ?? 0
  const generation = before + 1
  // The re-seal job (ifGeneration set) never falls back: on a KMS failure it throws and retries later,
  // so only a new credential raises the kms_fallback alert.
  const { sealed, fallback } = await sealCredentialWithInfo(env, http, addressOf(c, generation), credential, ifGeneration === undefined)
  // No await between these checks and the writes below, so nothing can interleave in the object.
  const current = generationOf(sql, c.id)
  if (ifGeneration !== undefined && current !== ifGeneration) return false
  // A refresh whose row a disconnect deleted while KMS answered must not bring the credential back.
  if (before > 0 && current === undefined) return false
  sql.exec(
    `INSERT INTO credentials (connection, generation, sealed, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT (connection) DO UPDATE SET generation = excluded.generation, sealed = excluded.sealed, updated_at = excluded.updated_at`,
    c.id,
    generation,
    JSON.stringify(sealed),
    Date.now()
  )
  if (!fallback) {
    sql.exec(`DELETE FROM kms_fallbacks WHERE connection = ?`, c.id)
    return true
  }
  const now = Date.now()
  sql.exec(
    `INSERT INTO kms_fallbacks (connection, first_at, count, next_at) VALUES (?, ?, 1, ?)
     ON CONFLICT (connection) DO UPDATE SET count = kms_fallbacks.count + 1, next_at = excluded.next_at`,
    c.id,
    now,
    now + RESEAL_RETRY_MS
  )
  // The monitor `cmux-api-<env>-kms-fallback` (integrations-plan.md G6, step file 08) alerts on this event.
  console.error(JSON.stringify({ event: "kms_fallback", alert: true, msg: "KMS seal failed; credential sealed under INTEGRATIONS_KEK", connection: c.id, provider: c.provider }))
  return true
}

export const loadCredential = async (sql: SqlStorage, env: Env, http: Http, c: Owned): Promise<Credential> => {
  const row = sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM credentials WHERE connection = ?`, c.id).toArray()[0]
  if (!row) throw new ProviderError("needs_reauth", "no stored credential")
  return openCredential(env, http, addressOf(c, Number(row.generation)), row.sealed)
}

export const nextResealAt = (sql: SqlStorage): number | null => {
  const at = sql.exec<{ at: number | null }>(`SELECT MIN(next_at) AS at FROM kms_fallbacks`).toArray()[0]?.at
  return at === null || at === undefined ? null : Number(at)
}

/** The re-seal job: rows sealed by fallback move to KMS once it works again (alarm-driven). */
export const resealFallbacks = async (sql: SqlStorage, env: Env, http: Http, connections: Readonly<Record<string, Owned & { status: string }>>, now: number): Promise<void> => {
  for (const r of sql.exec<{ connection: string; count: number }>(`SELECT connection, count FROM kms_fallbacks WHERE next_at <= ?`, now).toArray()) {
    const c = connections[r.connection]
    const row = sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM credentials WHERE connection = ?`, r.connection).toArray()[0]
    // Nothing to move: the connection or its row is gone, KMS is off, or a later seal already used KMS.
    if (!c || !row || !kmsConfig(env) || (JSON.parse(row.sealed) as { fb?: number }).fb !== 1) {
      sql.exec(`DELETE FROM kms_fallbacks WHERE connection = ?`, r.connection)
      continue
    }
    try {
      // storeCredential clears the row when KMS sealed it, or counts another fallback and retries later.
      // A credential stored meanwhile wins: then this write is skipped and that store owns the record.
      const generation = Number(row.generation)
      await storeCredential(sql, env, http, c, await openCredential(env, http, addressOf(c, generation), row.sealed), generation)
    } catch (e) {
      sql.exec(`UPDATE kms_fallbacks SET next_at = ? WHERE connection = ?`, now + RESEAL_RETRY_MS, r.connection)
      console.error(JSON.stringify({ event: "kms_reseal_failed", connection: r.connection, error: e instanceof Error ? e.name : "unknown" }))
    }
  }
}
