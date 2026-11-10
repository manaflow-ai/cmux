/**
 * A typed client of cmux-platform's HTTP API over the PLATFORM service binding, as the caller's own bearer: the
 * platform authenticates the token itself, as it does for a request platformForward (platform-forward.ts) hands it.
 * The shapes are the platform's (cmux-platform src/api/CloudOps.ts: ReadRequest, ReadResponse and its errors).
 */
export type PlatformRead =
  | { readonly ok: true; readonly value: unknown; readonly revision: string }
  | { readonly ok: false; readonly status: number; readonly code: string; readonly message: string; readonly retryable: boolean }

/** Statuses below 500 that a retry can clear. */
const TRANSIENT: ReadonlySet<number> = new Set([408, 425, 429])

const outage = (message: string): PlatformRead => ({ ok: false, status: 503, code: "owner.unreachable", message, retryable: true })

/** POST /v1/read {op, params} on cmux-platform, answering as `authorization` (the caller's `Bearer ...` header). */
export const platformRead = async (
  platform: Fetcher | undefined,
  origin: string,
  authorization: string,
  op: string,
  params: unknown
): Promise<PlatformRead> => {
  if (!platform) return outage("this deployment has no PLATFORM binding (Cloud is served by cmux-platform)")
  let response: Response
  try {
    response = await platform.fetch(new Request(new URL("/v1/read", origin), {
      method: "POST",
      headers: { authorization, "content-type": "application/json" },
      body: JSON.stringify({ op, params }),
    }))
  } catch (e) {
    return outage(`the platform could not be reached: ${String(e).slice(0, 200)}`)
  }
  const parsed: unknown = await response.json().catch(() => null)
  // Only an object is an answer; null, a number, a string or an array is a malformed one.
  const body = typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null
  if (response.ok) {
    if (body === null || !("value" in body) || typeof body.revision !== "string") return outage("the platform's read answer was malformed")
    return { ok: true, value: body.value, revision: body.revision }
  }
  // An HttpApi error is {_tag, code, message, retryable?}; the forwarder's outage nests it under `error`.
  const e = (body && typeof body.error === "object" && body.error !== null ? body.error : body) as Record<string, unknown> | null
  // A timeout (408), too early (425), rate limit (429) or server error (5xx) is transient whatever its body says.
  const transient = TRANSIENT.has(response.status) || response.status >= 500
  const code = typeof e?.code === "string" ? e.code : transient ? "owner.unreachable" : "platform.refused"
  return {
    ok: false,
    status: response.status,
    code,
    message: typeof e?.message === "string" ? e.message : `platform answered ${response.status}`,
    retryable: transient || e?.retryable === true || code === "owner.unreachable",
  }
}
