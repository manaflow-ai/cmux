import { createHash, createHmac } from "node:crypto"

/**
 * AWS Signature Version 4 query presigning (S3 API), for R2's S3 endpoint. Pure and
 * synchronous: no network, so tests check it against the AWS documented example and the Worker
 * can inject a fake. Payload is UNSIGNED-PAYLOAD; every header in `headers` (plus host) is signed,
 * so the client must send exactly those values (R2 refuses anything else).
 */
export interface PresignInput {
  readonly method: string
  /** Full URL; the path must already be URI-encoded per S3 rules. */
  readonly url: string
  /** `auto` for R2. */
  readonly region: string
  readonly service?: string
  readonly accessKeyId: string
  readonly secretAccessKey: string
  /** Extra signed headers (lowercase names). */
  readonly headers: Readonly<Record<string, string>>
  readonly expiresSec: number
  readonly now: number
}

export type Presigner = (input: PresignInput) => string

const rfc3986 = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
const hmac = (key: string | Buffer, data: string) => createHmac("sha256", key).update(data).digest()

export const presignUrl: Presigner = (i) => {
  const u = new URL(i.url)
  const service = i.service ?? "s3"
  const amzDate = new Date(i.now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "")
  const date = amzDate.slice(0, 8)
  const scope = `${date}/${i.region}/${service}/aws4_request`
  const headers: Record<string, string> = { host: u.host }
  for (const [k, v] of Object.entries(i.headers)) headers[k.toLowerCase()] = v
  const names = Object.keys(headers).sort()
  const signedHeaders = names.join(";")
  const query: Record<string, string> = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${i.accessKeyId}/${scope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": String(i.expiresSec),
    "X-Amz-SignedHeaders": signedHeaders
  }
  const canonicalQuery = Object.keys(query)
    .sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(query[k]!)}`)
    .join("&")
  const canonicalHeaders = names.map((k) => `${k}:${headers[k]!.trim()}\n`).join("")
  const canonical = [i.method, u.pathname, canonicalQuery, canonicalHeaders, signedHeaders, "UNSIGNED-PAYLOAD"].join("\n")
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, createHash("sha256").update(canonical).digest("hex")].join("\n")
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${i.secretAccessKey}`, date), i.region), service), "aws4_request")
  return `${u.origin}${u.pathname}?${canonicalQuery}&X-Amz-Signature=${createHmac("sha256", signingKey).update(toSign).digest("hex")}`
}
