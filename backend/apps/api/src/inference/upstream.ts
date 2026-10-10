import type { Env } from "../env.ts"
import type { ModelEntry, ProviderRoute } from "./catalog.ts"
import { parseUsage, providerTarget, type UpstreamUsage } from "./providers.ts"
import { runWorkersAi } from "./workers-ai.ts"

/**
 * One upstream attempt. Fallback is allowed only before the first byte reaches the client: a
 * connect error, a header timeout, or a retryable status (401/403 of our key, 408, 409, 429, 5xx)
 * is "failed" and the router tries the next provider. A client error (other 4xx) is answered to
 * the client as is. After the first byte the stream is the answer; a mid-stream break ends it.
 *
 * Usage is read from the stream's `usage` chunk (stream_options.include_usage) or the JSON body.
 * The bytes pass to the client unchanged. `onDone` runs once, after the last byte or a break,
 * inside waitUntil so a client that leaves early still settles the spend.
 */

const HEADER_TIMEOUT_MS = 60_000
const MAX_STREAM_MS = 15 * 60_000
const MAX_ERROR_BYTES = 4_096

export interface DoneInfo {
  readonly usage?: UpstreamUsage
  /** Time to first byte; null when the attempt broke after the first byte. */
  readonly ttfbMs: number | null
  readonly status: string
  /** No usage seen: "none" = nothing was generated (a client error), "full" = charge the reservation. */
  readonly charged: "none" | "full"
}

export type Outcome = { readonly kind: "response"; readonly response: Response } | { readonly kind: "failed"; readonly status: number | string }

export interface Attempt {
  readonly id: string
  readonly model: ModelEntry
  readonly route: ProviderRoute
  readonly body: Record<string, unknown>
  readonly onDone: (d: DoneInfo) => Promise<void>
}

const retryable = (status: number) => status === 401 || status === 403 || status === 408 || status === 409 || status === 429 || status >= 500

const headersOut = (id: string, contentType: string) => ({ "content-type": contentType, "cache-control": "no-cache", "x-cmux-request-id": id })

export const callUpstream = async (env: Env, ctx: ExecutionContext, a: Attempt): Promise<Outcome> => {
  const target = providerTarget(env, a.route.provider)
  if (!target) return { kind: "failed", status: "not_configured" }
  const started = Date.now()
  if (target.kind === "workers-ai") {
    try {
      const r = await runWorkersAi(target.ai, a.model, a.route.id, a.body, a.id)
      const ttfb = Date.now() - started
      ctx.waitUntil(a.onDone({ ...(r.usage ? { usage: r.usage } : {}), ttfbMs: ttfb, status: "ok", charged: "full" }))
      const h = new Headers(r.response.headers)
      h.set("x-cmux-request-id", a.id)
      return { kind: "response", response: new Response(r.response.body, { status: 200, headers: h }) }
    } catch (e) {
      console.warn(JSON.stringify({ msg: "inference.workers_ai.error", id: a.id, error: String(e).slice(0, 300) }))
      return { kind: "failed", status: "workers_ai_error" }
    }
  }

  const abort = new AbortController()
  const headerTimer = setTimeout(() => abort.abort("header timeout"), HEADER_TIMEOUT_MS)
  let upstream: Response
  try {
    upstream = await fetch(target.url, {
      method: "POST",
      headers: { authorization: `Bearer ${target.key}`, "content-type": "application/json", ...target.extraHeaders },
      body: JSON.stringify({ ...a.body, ...target.extraBody, model: a.route.id }),
      signal: abort.signal
    })
  } catch (e) {
    clearTimeout(headerTimer)
    return { kind: "failed", status: abort.signal.aborted ? "header_timeout" : "connect_error" }
  } finally {
    clearTimeout(headerTimer)
  }
  if (!upstream.ok) {
    if (retryable(upstream.status)) {
      await upstream.body?.cancel()
      return { kind: "failed", status: upstream.status }
    }
    // A client error: pass the provider's message (bounded), never its headers.
    const text = (await upstream.text()).slice(0, MAX_ERROR_BYTES)
    ctx.waitUntil(a.onDone({ ttfbMs: Date.now() - started, status: `client_error_${upstream.status}`, charged: "none" }))
    return { kind: "response", response: new Response(text, { status: upstream.status, headers: headersOut(a.id, "application/json") }) }
  }
  const ttfb = Date.now() - started
  const streaming = a.body.stream === true

  if (!streaming) {
    let text: string
    try {
      text = await upstream.text()
    } catch {
      return { kind: "failed", status: "body_error" }
    }
    let usage: UpstreamUsage | undefined
    try {
      usage = parseUsage((JSON.parse(text) as { usage?: unknown }).usage)
    } catch {
      return { kind: "failed", status: "invalid_json" }
    }
    ctx.waitUntil(a.onDone({ ...(usage ? { usage } : {}), ttfbMs: ttfb, status: "ok", charged: "full" }))
    return { kind: "response", response: new Response(text, { status: 200, headers: headersOut(a.id, "application/json") }) }
  }

  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>()
  const writer = writable.getWriter()
  const reader = upstream.body!.getReader()
  const streamTimer = setTimeout(() => abort.abort("stream limit"), MAX_STREAM_MS)
  ctx.waitUntil(
    (async () => {
      const decoder = new TextDecoder()
      let pending = ""
      let usage: UpstreamUsage | undefined
      let status = "ok"
      const scan = (text: string) => {
        pending += text
        let nl: number
        while ((nl = pending.indexOf("\n")) >= 0) {
          const line = pending.slice(0, nl).trim()
          pending = pending.slice(nl + 1)
          if (!line.startsWith("data:")) continue
          const data = line.slice(5).trim()
          if (data === "[DONE]" || !data.includes('"usage"')) continue
          try {
            usage = parseUsage((JSON.parse(data) as { usage?: unknown }).usage) ?? usage
          } catch {
            // Not JSON: passed through, not metered.
          }
        }
      }
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          scan(decoder.decode(value, { stream: true }))
          try {
            await writer.write(value)
          } catch {
            status = "client_gone"
            await reader.cancel().catch(() => {})
            break
          }
        }
      } catch {
        status = abort.signal.aborted ? "stream_limit" : "upstream_broken"
      } finally {
        clearTimeout(streamTimer)
        await writer.close().catch(() => {})
        await a.onDone({ ...(usage ? { usage } : {}), ttfbMs: status === "upstream_broken" ? null : ttfb, status, charged: "full" })
      }
    })()
  )
  return { kind: "response", response: new Response(readable, { status: 200, headers: headersOut(a.id, "text/event-stream; charset=utf-8") }) }
}
