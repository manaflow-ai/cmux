import { MAX_ACTIVE_KIDS } from "./link-token.ts"

/**
 * The reference reader of a GET /v1/cloud/keyset answer, as the VM daemon must apply it
 * (schemas/link-token/keyset-vectors.json, CLOUD-LINK-FOLLOWUPS 1). Only a 200 with a well-formed
 * keyset replaces the held keyset; every other answer keeps it. Unknown fields are ignored.
 */
export type KeysetRead =
  | { readonly ok: true; readonly version: string; readonly kids: ReadonlyArray<string> }
  | { readonly ok: false; readonly error: "rate_limited" | "unavailable" | "malformed" | "too_many_kids" | "bad_key"; readonly keep_held: true; readonly retry_after_s?: number }

const KID = /^[A-Za-z0-9._-]{1,64}$/
const B64U32 = /^[A-Za-z0-9_-]{43}$/

export const parseKeysetAnswer = (a: { status: number; headers: Readonly<Record<string, string>>; body: unknown }): KeysetRead => {
  const header = (n: string) => Object.entries(a.headers).find(([k]) => k.toLowerCase() === n)?.[1]
  if (a.status === 429) {
    const s = Number(header("retry-after"))
    return { ok: false, error: "rate_limited", keep_held: true, retry_after_s: Number.isInteger(s) && s > 0 ? s : 60 }
  }
  if (a.status !== 200) return { ok: false, error: "unavailable", keep_held: true }
  const body = a.body as { ok?: unknown; value?: { version?: unknown; keys?: unknown } } | null
  const v = body?.ok === true ? body.value : undefined
  if (!v || typeof v.version !== "string" || !/^[0-9a-f]{16}$/.test(v.version) || !v.keys || typeof v.keys !== "object" || Array.isArray(v.keys)) return { ok: false, error: "malformed", keep_held: true }
  const entries = Object.entries(v.keys as Record<string, unknown>)
  if (entries.length < 1) return { ok: false, error: "malformed", keep_held: true }
  if (entries.length > MAX_ACTIVE_KIDS) return { ok: false, error: "too_many_kids", keep_held: true }
  for (const [kid, k] of entries) {
    const j = k as Record<string, unknown> | null
    if (!KID.test(kid) || !j || typeof j !== "object") return { ok: false, error: "malformed", keep_held: true }
    if (j.kty !== "OKP" || j.crv !== "Ed25519" || (j.alg !== undefined && j.alg !== "EdDSA") || typeof j.x !== "string" || !B64U32.test(j.x) || "d" in j || (j.kid !== undefined && j.kid !== kid))
      return { ok: false, error: "bad_key", keep_held: true }
  }
  return { ok: true, version: v.version, kids: entries.map(([kid]) => kid).sort() }
}
