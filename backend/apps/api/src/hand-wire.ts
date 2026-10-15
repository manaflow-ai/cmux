/**
 * The hand wire (cmux-tui/crates/acpmux/src/hand/link.rs is the other end). One hand is one
 * installed `acpmux hand` (installed as `cmux-hand`) that dials out to `/v1/hands/<id>/socket`
 * with its own key. Frames are JSON text:
 *
 *   Cloud -> hand  {t:"req", id, action, params}          a request
 *                  {t:"approval", id, allow}              the owner's answer to an `approve`
 *   hand -> Cloud  {t:"hello", version, profile, roots, agent_policy, harnesses, os, arch, hostname}
 *                  {t:"res", id, ok:true, value} | {t:"res", id, ok:false, error:{code, message, detail}}
 *                  {t:"approve", id, req, summary}         a `mac` hand asks the owner
 *                  {t:"event", session, seq, event}        an agent session event (summary)
 *
 * The hand checks every request against its own local policy (roots, profile, allow rules); the
 * Cloud checks who may call it. Neither trusts the other alone.
 */

export const HAND_ID = /^hand_[a-z2-7]{20}$/
/** A pairing code: `<hand id>.<secret>`; the hand id routes it, the secret is the credential. */
export const PAIR_CODE = /^(hand_[a-z2-7]{20})\.([a-z2-7]{24})$/
export const PAIR_TTL_MS = 10 * 60_000

export const HAND_ACTIONS = [
  "fs.read",
  "fs.write",
  "fs.edit",
  "fs.patch",
  "fs.list",
  "fs.glob",
  "fs.grep",
  "exec",
  "agent.start",
  "agent.send",
  "agent.cancel",
  "agent.deny",
  "agent.events"
] as const
export type HandAction = (typeof HAND_ACTIONS)[number]
export const isHandAction = (a: unknown): a is HandAction => typeof a === "string" && (HAND_ACTIONS as ReadonlyArray<string>).includes(a)

export type Profile = "sandbox" | "mac"

export interface HandSummary {
  readonly hand: string
  readonly name: string
  readonly profile: Profile | null
  readonly created_at: number
  readonly paired_at: number | null
  readonly revoked_at: number | null
  readonly last_seen: number | null
  readonly online: boolean
}

export interface HandError {
  readonly code: string
  readonly message: string
  readonly detail?: unknown
}

export type HandReply<A = unknown> = { readonly ok: true; readonly value: A } | { readonly ok: false; readonly error: HandError }

/** One agent session event as the hand summarizes it (agent.rs summarize). */
export type AgentEvent =
  | { readonly kind: "text"; readonly text: string }
  | { readonly kind: "tool"; readonly update: boolean; readonly id?: string; readonly title?: string; readonly tool_kind?: string; readonly status?: string }
  | { readonly kind: "turn_start" }
  | { readonly kind: "turn_end"; readonly stop_reason?: string }
  | { readonly kind: "error"; readonly message?: string; readonly code?: number }
  | { readonly kind: "permission"; readonly permission_id?: string; readonly title?: string }

export interface StoredEvent {
  readonly seq: number
  readonly session: string
  readonly at: number
  readonly event: AgentEvent
}

/** A refused or failed hand request, as the brain's Hands service reports it. */
export class HandsError extends Error {
  readonly _tag = "HandsError"
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

/** Who calls a hand: the owner (a person's session) or one of the owner's Chiefs. */
export interface HandCaller {
  readonly kind: "owner" | "chief"
  readonly user: string
  readonly agent?: string
}

export const callerLabel = (c: HandCaller) => (c.kind === "owner" ? `session:${c.user}` : `agent:${c.agent}`)

const B32 = "abcdefghijklmnopqrstuvwxyz234567"
export const randomB32 = (n: number): string => {
  const bytes = crypto.getRandomValues(new Uint8Array(n))
  return Array.from(bytes, (b) => B32[b & 31]).join("")
}

export const sha256Hex = async (text: string): Promise<string> => {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("")
}

/** Constant-time compare of two hex strings of the same length. */
export const sameHex = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}
