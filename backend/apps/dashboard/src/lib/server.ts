import { createServerFn } from "@tanstack/react-start"

/**
 * Server functions. They call only the cmux API Worker and Stack Auth's client
 * REST API (sign-in, refresh); never a database (spec D1). The user's Stack
 * access token travels as the bearer to the API.
 */

const apiUrl = () => {
  const url = process.env.CMUX_API_URL
  if (!url) throw new Error("CMUX_API_URL is not set")
  return url.replace(/\/$/, "")
}

const stackHeaders = () => {
  const project = process.env.CMUX_STACK_PROJECT_ID
  const key = process.env.CMUX_STACK_PUBLISHABLE_CLIENT_KEY
  if (!project || !key) throw new Error("Stack project is not configured")
  return {
    "content-type": "application/json",
    "x-stack-project-id": project,
    "x-stack-publishable-client-key": key,
    "x-stack-access-type": "client"
  }
}

export interface Tokens {
  readonly access_token: string
  readonly refresh_token: string
}

export const signIn = createServerFn({ method: "POST" })
  .validator((d: { email: string; password: string }) => d)
  .handler(async ({ data }): Promise<Tokens | { error: string }> => {
    const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
      method: "POST",
      headers: stackHeaders(),
      body: JSON.stringify({ email: data.email, password: data.password })
    })
    const body = (await res.json()) as { access_token?: string; refresh_token?: string; error?: string; code?: string }
    if (!res.ok || !body.access_token || !body.refresh_token) return { error: body.error ?? body.code ?? `sign-in failed (${res.status})` }
    return { access_token: body.access_token, refresh_token: body.refresh_token }
  })

export const refresh = createServerFn({ method: "POST" })
  .validator((d: { refresh_token: string }) => d)
  .handler(async ({ data }): Promise<{ access_token: string } | { error: string }> => {
    const res = await fetch("https://api.stack-auth.com/api/v1/auth/sessions/current/refresh", {
      method: "POST",
      headers: { ...stackHeaders(), "x-stack-refresh-token": data.refresh_token },
      body: "{}"
    })
    const body = (await res.json()) as { access_token?: string; error?: string }
    if (!res.ok || !body.access_token) return { error: body.error ?? `refresh failed (${res.status})` }
    return { access_token: body.access_token }
  })

/** JSON as it crosses the server-function boundary. */
export type Json = string | number | boolean | null | Array<Json> | { [k: string]: Json }

export interface OpResponse {
  readonly ok: boolean
  readonly op: string
  readonly value?: Json
  readonly error?: { code: string; message: string; retryable: boolean }
  readonly transaction: string
  readonly idempotency_key: string
  readonly revision?: string
  readonly replayed: boolean
  readonly stream: string
  readonly sequence: number
}

export type ApiResult<T> = { readonly status: number; readonly body: T }

const post = async <T,>(path: string, token: string, payload: unknown): Promise<ApiResult<T>> => {
  const res = await fetch(`${apiUrl()}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(payload)
  })
  return { status: res.status, body: (await res.json()) as T }
}

export const mutate = createServerFn({ method: "POST" })
  .validator((d: { token: string; op: string; params: Record<string, unknown>; idempotency_key: string }) => d)
  .handler(async ({ data }) =>
    post<OpResponse>("/v1/ops", data.token, { op: data.op, params: data.params, idempotency_key: data.idempotency_key, origin: "user" })
  )

export const read = createServerFn({ method: "POST" })
  .validator((d: { token: string; op: string; params: Record<string, unknown> }) => d)
  .handler(async ({ data }) => post<{ op: string; value: Json; stream: string; revision: string }>("/v1/read", data.token, { op: data.op, params: data.params }))

/** Public config for the browser (WebSocket origin); no secrets. */
export const publicConfig = createServerFn({ method: "GET" }).handler(async () => ({ apiUrl: apiUrl() }))
