import type { IntegrationProvider } from "@cmux/protocol"

/** Shapes the ConnectionDO shares with the Worker routes. */

/** The HTTP shape of one op result (http.ts OpResponse). */
export interface ExternalReply {
  readonly ok: boolean
  readonly op: string
  readonly value?: unknown
  readonly error?: { readonly code: string; readonly message: string; readonly retryable: boolean }
  readonly transaction: string
  readonly idempotency_key: string
  readonly replayed: boolean
  readonly stream: string
  readonly sequence: number
}

export interface ProviderEvent {
  readonly provider: IntegrationProvider
  readonly account: string
  readonly delivery_id: string
  readonly event: string
  readonly payload: unknown
}
