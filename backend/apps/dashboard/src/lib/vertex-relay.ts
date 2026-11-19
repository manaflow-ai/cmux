/**
 * The Vertex AI relay (user 2026-11-19: "use gemini neon with cmux pro, set up our gcp for that
 * properly"). The cmux API Worker runs on Cloudflare, where no Google identity exists; this project
 * runs on Vercel, where each function call carries a Vercel OIDC token. The relay trades that token for
 * a short-lived Google access token through Workload Identity Federation (pool `vercel-manaflow`,
 * provider `vercel-dashboard` in GCP project cmux-489202, which trusts only the cmux-next-dashboard and
 * cmux-next-dashboard-staging projects' production tokens), impersonates the Vertex-only service account
 * `cmux-model-router` (roles/aiplatform.user, nothing else), and forwards the Worker's OpenAI
 * chat/completions body to Vertex AI's OpenAI-compatible endpoint. No Google key is stored anywhere.
 *
 * Like the AI Gateway relay, the Worker keeps auth, the allowlist, caps and metering; the relay checks
 * the relay key, the body size and that the model is a Google one, so a leaked relay key can spend only
 * on Gemini (rotate INFERENCE_VERCEL_RELAY_KEY on both sides if it leaks).
 */

export const VERTEX_PROJECT = "cmux-489202"
/** Gemini 4 models are served from the global endpoint only (us-central1 answers 404 for gemini-4-neon). */
export const VERTEX_LOCATION = "global"
export const VERTEX_URL = `https://aiplatform.googleapis.com/v1/projects/${VERTEX_PROJECT}/locations/${VERTEX_LOCATION}/endpoints/openapi/chat/completions`
export const WIF_AUDIENCE = "//iam.googleapis.com/projects/899604712422/locations/global/workloadIdentityPools/vercel-manaflow/providers/vercel-dashboard"
export const SERVICE_ACCOUNT = "cmux-model-router@cmux-489202.iam.gserviceaccount.com"
const STS_URL = "https://sts.googleapis.com/v1/token"
const IMPERSONATE_URL = `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SERVICE_ACCOUNT}:generateAccessToken`
const SCOPE = "https://www.googleapis.com/auth/cloud-platform"
const MAX_BODY_BYTES = 32 * 1024 * 1024
const RELAY_MODEL_PREFIXES = ["google/"]
/** Refresh this long before the Google token expires, so an in-flight stream never starts on a dying token. */
const REFRESH_MARGIN_MS = 5 * 60_000

export interface VertexRelayDeps {
  /** The shared key the Worker sends as `Authorization: Bearer`. Unset: the relay is off (404). */
  readonly relayKey: string | undefined
  /** This call's Vercel OIDC token. */
  readonly oidcToken: string | undefined
  readonly fetch: typeof fetch
  readonly now?: () => number
}

interface CachedToken {
  readonly token: string
  readonly expiresAt: number
}

/** One Google token per warm function instance, reused until shortly before it expires. */
let cached: CachedToken | undefined

/** Test hook: forget the cached Google token. */
export const resetVertexTokenCache = () => {
  cached = undefined
}

const json = (status: number, code: string, message: string) => Response.json({ error: { code, message } }, { status })

/** Same-length compare that does not stop at the first differing byte. */
const sameKey = (a: string, b: string) => {
  const x = new TextEncoder().encode(a)
  const y = new TextEncoder().encode(b)
  let diff = x.length ^ y.length
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0)
  return diff === 0
}

/** Vercel OIDC token -> federated token (STS) -> the service account's access token (IAM Credentials). */
export const googleAccessToken = async (oidcToken: string, deps: Pick<VertexRelayDeps, "fetch" | "now">): Promise<string> => {
  const now = (deps.now ?? Date.now)()
  if (cached && cached.expiresAt - REFRESH_MARGIN_MS > now) return cached.token
  const sts = await deps.fetch(STS_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grantType: "urn:ietf:params:oauth:grant-type:token-exchange",
      audience: WIF_AUDIENCE,
      scope: SCOPE,
      requestedTokenType: "urn:ietf:params:oauth:token-type:access_token",
      subjectTokenType: "urn:ietf:params:oauth:token-type:jwt",
      subjectToken: oidcToken
    })
  })
  if (!sts.ok) throw new Error(`sts ${sts.status}`)
  const federated = ((await sts.json()) as { access_token?: unknown }).access_token
  if (typeof federated !== "string" || !federated) throw new Error("sts: no access_token")
  const sa = await deps.fetch(IMPERSONATE_URL, {
    method: "POST",
    headers: { authorization: `Bearer ${federated}`, "content-type": "application/json" },
    body: JSON.stringify({ scope: [SCOPE], lifetime: "3600s" })
  })
  if (!sa.ok) throw new Error(`impersonate ${sa.status}`)
  const out = (await sa.json()) as { accessToken?: unknown; expireTime?: unknown }
  if (typeof out.accessToken !== "string" || !out.accessToken) throw new Error("impersonate: no accessToken")
  const expiresAt = typeof out.expireTime === "string" && !Number.isNaN(Date.parse(out.expireTime)) ? Date.parse(out.expireTime) : now + 3_600_000
  cached = { token: out.accessToken, expiresAt }
  return out.accessToken
}

export const relayVertexChat = async (request: Request, deps: VertexRelayDeps): Promise<Response> => {
  if (!deps.relayKey) return json(404, "not_found", "not found")
  const auth = request.headers.get("authorization") ?? ""
  if (!auth.toLowerCase().startsWith("bearer ") || !sameKey(auth.slice(7).trim(), deps.relayKey)) return json(401, "auth.invalid", "bad relay key")
  if (!deps.oidcToken) return json(503, "oidc.missing", "no Vercel OIDC token on this deployment")
  const bytes = await request.arrayBuffer()
  if (bytes.byteLength > MAX_BODY_BYTES) return json(413, "validation.too_large", "request body is too large")
  let model: unknown
  try {
    model = (JSON.parse(new TextDecoder().decode(bytes)) as { model?: unknown }).model
  } catch {
    return json(400, "validation.invalid", "body must be JSON")
  }
  if (typeof model !== "string" || !RELAY_MODEL_PREFIXES.some((p) => model.startsWith(p))) return json(403, "model.not_allowed", "the Vertex relay serves only Google models")
  let token: string
  try {
    token = await googleAccessToken(deps.oidcToken, deps)
  } catch (e) {
    // A 502 is retryable for the Worker (it tries the next route); the cause stays in our logs only.
    console.warn(JSON.stringify({ msg: "vertex_relay.token_failed", error: String(e).slice(0, 200) }))
    return json(502, "upstream.auth_failed", "could not get a Google access token")
  }
  const upstream = await deps.fetch(VERTEX_URL, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: bytes })
  // A rejected token (revoked, clock skew) must not stick for the instance's lifetime.
  if (upstream.status === 401) resetVertexTokenCache()
  const headers = new Headers({ "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-cache" })
  return new Response(upstream.body, { status: upstream.status, headers })
}
