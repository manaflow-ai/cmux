import type { Http } from "./provider-core.ts"

/**
 * AWS KMS for credential data keys (integrations-plan.md G6, decision I5,
 * CASA control C2). Only Encrypt and Decrypt of a 32-byte data key, with an
 * encryption context that names the connection, owner, provider and
 * generation; the key policy allows nothing else. Requests are signed with
 * AWS Signature Version 4 through Web Crypto, so this runs in workerd.
 */

export interface KmsConfig {
  readonly region: string
  readonly keyArn: string
  readonly accessKeyId: string
  readonly secretAccessKey: string
}

const enc = new TextEncoder()
const hex = (b: ArrayBuffer | Uint8Array) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("")
const sha256Hex = async (data: string | Uint8Array) => hex(await crypto.subtle.digest("SHA-256", typeof data === "string" ? enc.encode(data) : data))
const hmac = async (key: Uint8Array, data: string) =>
  new Uint8Array(await crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), enc.encode(data)))

/** The SigV4 signing key for one day, region and service. */
export const signingKey = async (secret: string, date: string, region: string, service: string) =>
  hmac(await hmac(await hmac(await hmac(enc.encode(`AWS4${secret}`), date), region), service), "aws4_request")

/**
 * The Authorization header of AWS Signature Version 4 for one request.
 * `headers` are the signed headers (lowercase names); `amzDate` is
 * `YYYYMMDDTHHMMSSZ` and must also be the `x-amz-date` header.
 */
export const sigv4 = async (p: {
  readonly method: string
  readonly url: string
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
  readonly region: string
  readonly service: string
  readonly accessKeyId: string
  readonly secretAccessKey: string
  readonly amzDate: string
}): Promise<{ authorization: string; canonicalRequestHash: string }> => {
  const u = new URL(p.url)
  const query = [...u.searchParams.entries()]
    .map(([k, v]) => [encodeURIComponent(k), encodeURIComponent(v)] as const)
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : 1) : a[0] < b[0] ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`)
    .join("&")
  const names = Object.keys(p.headers)
    .map((h) => h.toLowerCase())
    .sort()
  const canonicalHeaders = names.map((n) => `${n}:${String(p.headers[n] ?? "").trim().replace(/\s+/g, " ")}\n`).join("")
  const signed = names.join(";")
  const canonical = [p.method, u.pathname || "/", query, canonicalHeaders, signed, await sha256Hex(p.body)].join("\n")
  const canonicalRequestHash = await sha256Hex(canonical)
  const date = p.amzDate.slice(0, 8)
  const scope = `${date}/${p.region}/${p.service}/aws4_request`
  const toSign = ["AWS4-HMAC-SHA256", p.amzDate, scope, canonicalRequestHash].join("\n")
  const signature = hex(await hmac(await signingKey(p.secretAccessKey, date, p.region, p.service), toSign))
  return { authorization: `AWS4-HMAC-SHA256 Credential=${p.accessKeyId}/${scope}, SignedHeaders=${signed}, Signature=${signature}`, canonicalRequestHash }
}

export class KmsError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean
  ) {
    super(message)
  }
}

const TRANSIENT: ReadonlySet<string> = new Set(["ThrottlingException", "KMSInternalException", "DependencyTimeoutException", "KeyUnavailableException"])

const amzNow = () => new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "")
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))

const call = async (cfg: KmsConfig, http: Http, target: "Encrypt" | "Decrypt", payload: Record<string, unknown>): Promise<Record<string, unknown>> => {
  const host = `kms.${cfg.region}.amazonaws.com`
  const url = `https://${host}/`
  const body = JSON.stringify(payload)
  const amzDate = amzNow()
  const headers = { "content-type": "application/x-amz-json-1.1", host, "x-amz-date": amzDate, "x-amz-target": `TrentService.${target}` }
  const { authorization } = await sigv4({ method: "POST", url, headers, body, region: cfg.region, service: "kms", accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, amzDate })
  let res: Response
  try {
    res = await http(new Request(url, { method: "POST", headers: { ...headers, authorization }, body, signal: AbortSignal.timeout(10_000) }))
  } catch {
    throw new KmsError(`kms ${target}: network error`, true)
  }
  const out = (await res.json().catch(() => ({}))) as Record<string, unknown>
  // Never echo the body: the error type is enough and holds no key material.
  if (!res.ok) {
    const type = String(out.__type ?? "").split("#").pop()?.slice(0, 60) ?? ""
    // KMS answers throttling and its own transient faults with HTTP 400 and a type, not 429 or 5xx.
    throw new KmsError(`kms ${target} failed: HTTP ${res.status} ${type}`, res.status >= 500 || res.status === 429 || TRANSIENT.has(type))
  }
  return out
}

/** Wraps a data key under the KMS key, bound to the encryption context. Returns the ciphertext blob (base64). */
export const kmsEncrypt = async (cfg: KmsConfig, http: Http, plaintext: Uint8Array, context: Readonly<Record<string, string>>): Promise<string> => {
  const out = await call(cfg, http, "Encrypt", { KeyId: cfg.keyArn, Plaintext: b64(plaintext), EncryptionContext: context })
  if (typeof out.CiphertextBlob !== "string") throw new KmsError("kms Encrypt returned no CiphertextBlob", false)
  return out.CiphertextBlob
}

/** Unwraps a data key. KMS refuses a blob with another context or from another key. */
export const kmsDecrypt = async (cfg: KmsConfig, http: Http, blob: string, context: Readonly<Record<string, string>>): Promise<Uint8Array> => {
  const out = await call(cfg, http, "Decrypt", { KeyId: cfg.keyArn, CiphertextBlob: blob, EncryptionContext: context })
  if (typeof out.Plaintext !== "string") throw new KmsError("kms Decrypt returned no Plaintext", false)
  return unb64(out.Plaintext)
}
