/**
 * Envelope encryption for provider credentials (spec integrations.md
 * "Credentials"): a fresh AES-256-GCM data key per secret, wrapped by the key
 * encryption key, both bound to AAD = connection | owner | provider |
 * generation. The KEK is the `INTEGRATIONS_KEK` Worker secret today; AWS KMS
 * replaces `wrap`/`unwrap` later without changing the stored shape.
 */

export interface SealedSecret {
  readonly v: 1
  readonly iv: string
  readonly ct: string
  readonly wiv: string
  readonly wdek: string
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
const enc = new TextEncoder()

export const aadFor = (connection: string, owner: string, provider: string, generation: number) => enc.encode(`cmux-conn-v1|${connection}|${owner}|${provider}|${generation}`)

const kekCache = new Map<string, Promise<CryptoKey>>()
const kek = (material: string) => {
  let k = kekCache.get(material)
  if (!k) {
    const raw = unb64(material)
    if (raw.byteLength !== 32) throw new Error("INTEGRATIONS_KEK must be 32 bytes, base64")
    k = crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"])
    kekCache.set(material, k)
  }
  return k
}

export const seal = async (kekMaterial: string, plaintext: string, aad: Uint8Array): Promise<SealedSecret> => {
  const dekRaw = crypto.getRandomValues(new Uint8Array(32))
  const dek = await crypto.subtle.importKey("raw", dekRaw, "AES-GCM", false, ["encrypt"])
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, dek, enc.encode(plaintext)))
  const wiv = crypto.getRandomValues(new Uint8Array(12))
  const wdek = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: wiv, additionalData: aad }, await kek(kekMaterial), dekRaw))
  dekRaw.fill(0)
  return { v: 1, iv: b64(iv), ct: b64(ct), wiv: b64(wiv), wdek: b64(wdek) }
}

export const open = async (kekMaterial: string, sealed: SealedSecret, aad: Uint8Array): Promise<string> => {
  const dekRaw = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.wiv), additionalData: aad }, await kek(kekMaterial), unb64(sealed.wdek)))
  const dek = await crypto.subtle.importKey("raw", dekRaw, "AES-GCM", false, ["decrypt"])
  dekRaw.fill(0)
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.iv), additionalData: aad }, dek, unb64(sealed.ct)))
}
