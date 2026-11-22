/**
 * The Vercel AI Gateway OIDC relay (user 2026-10-28: "do oidc for this"). The cmux API Worker runs
 * on Cloudflare, where no Vercel OIDC token exists; this project runs on Vercel, where each function
 * call carries one (`x-vercel-oidc-token`, or VERCEL_OIDC_TOKEN). The Worker posts an OpenAI
 * chat/completions body here with the shared relay key; the relay forwards it to AI Gateway with the
 * OIDC token and streams the answer back unchanged. No gateway key is stored anywhere.
 *
 * The Worker keeps auth, the model allowlist, caps and metering; the relay only checks the relay
 * key, the body size and that the model is one the Worker may ask for (RELAY_MODEL_PREFIXES), so a
 * leaked relay key cannot spend on other models.
 */

export const GATEWAY_URL = "https://ai-gateway.vercel.sh/v1/chat/completions"
const MAX_BODY_BYTES = 8 * 1024 * 1024
const RELAY_MODEL_PREFIXES = ["deepseek/"]

export interface RelayDeps {
  /** The shared key the Worker sends as `Authorization: Bearer`. Unset: the relay is off (404). */
  readonly relayKey: string | undefined
  /** This call's Vercel OIDC token. */
  readonly oidcToken: string | undefined
  readonly fetch: typeof fetch
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

export const relayChat = async (request: Request, deps: RelayDeps): Promise<Response> => {
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
  if (typeof model !== "string" || !RELAY_MODEL_PREFIXES.some((p) => model.startsWith(p))) return json(403, "model.not_allowed", "the relay serves only DeepSeek models")
  const upstream = await deps.fetch(GATEWAY_URL, { method: "POST", headers: { authorization: `Bearer ${deps.oidcToken}`, "content-type": "application/json" }, body: bytes })
  const headers = new Headers({ "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-cache" })
  return new Response(upstream.body, { status: upstream.status, headers })
}
