import { cloudOpMeta, type CloudMutationName, type CloudOps, type CloudReadName, type MutationResult } from "./generated.ts"

/** Error shape of the cmux Cloud API (wire conventions, backend.md "APIs"). */
export interface CloudOpError {
  readonly code: string
  readonly message: string
  readonly details?: unknown
  readonly retryable: boolean
}

/** Outcome of one mutation, always with its write barrier (request-settled). */
export type CloudMutationOutcome<T> =
  | ({ readonly ok: true } & MutationResult<T> & CloudSettle)
  | ({ readonly ok: false; readonly error: CloudOpError; readonly transaction: string; readonly replayed: boolean } & CloudSettle)

export interface CloudSettle {
  readonly idempotency_key: string
  readonly stream: string
  readonly sequence: number
}

export class CloudHttpError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown
  ) {
    super(`cmux Cloud API ${status}`)
  }
}

export interface CloudClientOptions {
  /** API origin, for example https://cloud-api.cmux.dev */
  readonly baseUrl: string
  /** Bearer token for each call: a Stack session token or an install token. */
  readonly token: () => string | Promise<string>
  readonly fetch?: typeof fetch
}

/**
 * Typed transport for cloud ops. Mutations always carry an idempotency key
 * (reuse the same key to retry; the owner replays the original result).
 */
export const createCloudClient = (options: CloudClientOptions) => {
  const doFetch = options.fetch ?? fetch
  const base = options.baseUrl.replace(/\/$/, "")
  const post = async (path: string, body: unknown) => {
    const res = await doFetch(`${base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${await options.token()}` },
      body: JSON.stringify(body)
    })
    const json: unknown = await res.json().catch(() => undefined)
    if (!res.ok) throw new CloudHttpError(res.status, json)
    return json
  }
  return {
    async mutate<K extends CloudMutationName>(
      op: K,
      params: CloudOps[K]["params"],
      opts: { idempotencyKey?: string; expectedRevision?: string; origin?: "user" | "cli" | "mcp" | "script" | "remote" } = {}
    ): Promise<CloudMutationOutcome<CloudOps[K]["result"]>> {
      const r = (await post("/v1/ops", {
        op,
        params,
        idempotency_key: opts.idempotencyKey ?? crypto.randomUUID(),
        origin: opts.origin ?? "user",
        ...(opts.expectedRevision ? { expected_revision: opts.expectedRevision } : {})
      })) as Record<string, unknown>
      return r.ok
        ? ({ ok: true, value: r.value, revision: r.revision, transaction: r.transaction, replayed: r.replayed, idempotency_key: r.idempotency_key, stream: r.stream, sequence: r.sequence } as CloudMutationOutcome<CloudOps[K]["result"]>)
        : ({ ok: false, error: r.error, transaction: r.transaction, replayed: r.replayed, idempotency_key: r.idempotency_key, stream: r.stream, sequence: r.sequence } as CloudMutationOutcome<CloudOps[K]["result"]>)
    },
    async read<K extends CloudReadName>(op: K, params: CloudOps[K]["params"]): Promise<{ value: CloudOps[K]["result"]; stream: string; revision: string }> {
      const r = (await post("/v1/read", { op, params })) as { value: CloudOps[K]["result"]; stream: string; revision: string }
      return r
    },
    /**
     * WebSocket to an owner stream (`cmux.wire/1` frames). Browsers cannot set headers,
     * so the token travels as a subprotocol, never in the URL.
     */
    async openWire(scope: "user" | "team"): Promise<WebSocket> {
      return new WebSocket(`${base.replace(/^http/, "ws")}/v1/wire/${scope}`, ["cmux.wire.v1", `bearer.${await options.token()}`])
    },
    meta: cloudOpMeta
  }
}

export type CloudClient = ReturnType<typeof createCloudClient>
