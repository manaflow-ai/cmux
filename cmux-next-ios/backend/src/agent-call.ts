// Agent Calls (PROTOCOL.md "Agent calls", cmux-next-ios/verify/agent-alarms.md): a cmux phone number calls the
// person and reads out what needs them, for the same events and under the same 30 second rule as the iPhone's
// Agent Alarms. It rides the Mac's notify (`POST /v1/devices/:macId/notify`), so it needs no app open, and
// the call itself needs no data connection on the phone, only a phone line.
//
// What is said is what the Worker already knows: the kind, the Mac's name, and the agent's name when the Mac
// sent one (a sealed push carries none). Never a prompt, a command or a path.
//
// Provider: Twilio Programmable Voice (the Calls API with inline TwiML; no webhook to host). Voice: MeloTTS
// (`@cf/myshell-ai/melotts`, MIT) on Workers AI, served from `GET /v1/agent-call/audio/:token`; with no AI
// binding the call falls back to Twilio's own `<Say>`. Secrets: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN,
// TWILIO_FROM_NUMBER (the cmux number), AGENT_CALL_AUDIO_KEY (signs audio links). Without them nothing is
// called and the routes say `configured: false`.

import type { Env } from "./env.ts"
import type { NotifyEvent } from "./push.ts"

export const AGENT_CALL_TRIGGERS = ["permission", "question", "needsInput", "agentFailed"] as const
export type AgentCallTrigger = (typeof AGENT_CALL_TRIGGERS)[number]

/** The user's rule, shared with the iPhone's `AgentAlarmGate.debounce`: at most one call in any 30 seconds. */
export const AGENT_CALL_DEBOUNCE_MS = 30_000
/** How long an event is remembered, so its lead and a retry call once (the iPhone keeps a day too). */
export const AGENT_CALL_SEEN_MS = 24 * 60 * 60_000
/** A verification code: 6 digits, 10 minutes, 5 tries, and at most 3 code calls an hour. */
export const VERIFY_TTL_MS = 10 * 60_000
export const VERIFY_TRIES = 5
export const VERIFY_CALLS_PER_HOUR = 3
/** An audio link lives as long as Twilio needs to fetch it. */
export const AUDIO_TTL_MS = 10 * 60_000
export const TTS_MODEL = "@cf/myshell-ai/melotts"

/** The trigger a notify rings, or null. The same table as the iPhone's `AgentAlarmTrigger(payload:)`. */
export const callTrigger = (e: Pick<NotifyEvent, "kind" | "state">): AgentCallTrigger | null => {
  switch (e.kind) {
    case "permission":
      return "permission"
    case "question":
      return "question"
    case "failed":
      return "agentFailed"
    case "terminal":
      return e.state === "waiting" ? "needsInput" : e.state === "failed" ? "agentFailed" : null
    default:
      return null
  }
}

/** One event's key: the ask's permission id, as on the iPhone (`ask:<id>`), else the Mac's event id. */
export const callKey = (macId: string, e: Pick<NotifyEvent, "permissionId" | "eventId">): string =>
  e.permissionId ? `ask:${e.permissionId}` : `event:${macId}:${e.eventId}`

const speakable = (text: string | undefined, max: number): string | undefined => {
  const t = text?.replace(/[^\p{L}\p{N} .,'’()-]/gu, " ").replace(/\s+/g, " ").trim().slice(0, max)
  return t ? t : undefined
}

/** What the call says: one sentence, then how to answer, spoken twice by the TwiML. */
export const callScript = (trigger: AgentCallTrigger, macName: string, agent?: string): string => {
  const who = speakable(agent, 40) ?? "An agent"
  const mac = speakable(macName, 40) ?? "your Mac"
  const what = {
    permission: `${who} on ${mac} needs your permission.`,
    question: `${who} on ${mac} has a question for you.`,
    needsInput: `${who} on ${mac} is waiting for you in its terminal.`,
    agentFailed: `${who} on ${mac} stopped and needs you.`
  }[trigger]
  return `Hi, this is cmux. ${what} Open cmux to answer.`
}

export const verifyScript = (code: string): string => {
  const spaced = code.split("").join(", ")
  return `Hi, this is cmux. Your verification code is ${spaced}. Again, ${spaced}.`
}

export const testScript = (): string => "Hi, this is cmux. This is a test of agent calls. When an agent needs you, cmux will call you like this."

/** E.164: a plus, a country code and 7 to 15 digits in all. */
export const E164 = /^\+[1-9]\d{6,14}$/
export const normalizeNumber = (raw: unknown): string | null => {
  if (typeof raw !== "string") return null
  const n = raw.replace(/[\s().-]/g, "")
  return E164.test(n) ? n : null
}
/** A number as the app shows it once saved: the last four digits only. */
export const maskNumber = (n: string): string => `${n.slice(0, Math.min(3, n.length - 4))}••• ••${n.slice(-4)}`

const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")

/** The call: the audio twice with a pause, or Twilio's own voice when there is no audio link. */
export const twiml = (text: string, audioUrl?: string): string => {
  const say = audioUrl ? `<Play>${xml(audioUrl)}</Play>` : `<Say>${xml(text)}</Say>`
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/>${say}<Pause length="1"/>${say}</Response>`
}

export interface TwilioConfig {
  readonly accountSid: string
  readonly authToken: string
  readonly from: string
}

export const twilioConfig = (env: Env): TwilioConfig | null =>
  env.TWILIO_ACCOUNT_SID && env.TWILIO_AUTH_TOKEN && env.TWILIO_FROM_NUMBER
    ? { accountSid: env.TWILIO_ACCOUNT_SID, authToken: env.TWILIO_AUTH_TOKEN, from: env.TWILIO_FROM_NUMBER }
    : null

/** Twilio's Calls API request (a form POST with Basic auth; the TwiML inline, so no webhook is hosted). */
export const twilioRequest = (config: TwilioConfig, to: string, body: string): Request => {
  const form = new URLSearchParams({ To: to, From: config.from, Twiml: body, Timeout: "30" })
  return new Request(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(config.accountSid)}/Calls.json`, {
    method: "POST",
    headers: {
      authorization: `Basic ${btoa(`${config.accountSid}:${config.authToken}`)}`,
      "content-type": "application/x-www-form-urlencoded"
    },
    body: form.toString()
  })
}

export type CallOutcome = { readonly placed: true; readonly sid?: string } | { readonly placed: false; readonly reason: string }

export const placeCall = async (
  config: TwilioConfig,
  to: string,
  body: string,
  send: (r: Request) => Promise<Response> = (r) => fetch(r)
): Promise<CallOutcome> => {
  try {
    const res = await send(twilioRequest(config, to, body))
    if (res.ok) {
      const j = (await res.json().catch(() => ({}))) as { sid?: string }
      return { placed: true, sid: j.sid }
    }
    const j = (await res.json().catch(() => ({}))) as { code?: number; message?: string }
    return { placed: false, reason: `twilio ${res.status}${j.code ? ` ${j.code}` : ""}` }
  } catch (e) {
    return { placed: false, reason: `twilio unreachable: ${String(e).slice(0, 80)}` }
  }
}

// ---- Signed audio links: the text rides in the link, signed, so nothing is stored -------------------------

const b64url = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64url = (s: string): Uint8Array => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))

const hmacKey = (secret: string) => crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"])

export const audioToken = async (secret: string, text: string, now: number): Promise<string> => {
  const body = b64url(new TextEncoder().encode(JSON.stringify({ t: text, e: now + AUDIO_TTL_MS })))
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), new TextEncoder().encode(body)))
  return `${body}.${b64url(sig)}`
}

/** The text of a valid, unexpired token, or null. */
export const audioText = async (secret: string, token: string, now: number): Promise<string | null> => {
  const [body, sig] = token.split(".")
  if (!body || !sig || token.length > 2048) return null
  try {
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), unb64url(sig), new TextEncoder().encode(body))
    if (!ok) return null
    const { t, e } = JSON.parse(new TextDecoder().decode(unb64url(body))) as { t?: unknown; e?: unknown }
    return typeof t === "string" && typeof e === "number" && e > now ? t : null
  } catch {
    return null
  }
}

/** MeloTTS on Workers AI: MP3 bytes, or null (no binding, or the model failed). */
export const synthesize = async (env: Env, text: string): Promise<Uint8Array | null> => {
  if (!env.AI) return null
  try {
    const out = (await env.AI.run(TTS_MODEL, { prompt: text, lang: "en" })) as { audio?: string } | ReadableStream | ArrayBuffer
    if (out instanceof ArrayBuffer) return new Uint8Array(out)
    if (out && typeof out === "object" && "audio" in out && typeof out.audio === "string") return unb64url(out.audio.replace(/\+/g, "-").replace(/\//g, "_"))
    if (out instanceof ReadableStream) return new Uint8Array(await new Response(out).arrayBuffer())
    return null
  } catch (e) {
    console.log(JSON.stringify({ msg: "agent call tts failed", error: String(e).slice(0, 120) }))
    return null
  }
}

/** The TwiML of one call: MeloTTS through a signed link when the Worker can make one, else `<Say>`. */
export const callTwiml = async (env: Env, origin: string, text: string, now: number): Promise<string> => {
  if (!env.AI || !env.AGENT_CALL_AUDIO_KEY) return twiml(text)
  return twiml(text, `${origin}/v1/agent-call/audio/${await audioToken(env.AGENT_CALL_AUDIO_KEY, text, now)}`)
}

// ---- What the user hub keeps (team-hub.ts) ----------------------------------------------------------------

export interface AgentCallSettings {
  readonly enabled: boolean
  readonly triggers: ReadonlyArray<AgentCallTrigger>
  /** Verified number, E.164; null until a code was confirmed. */
  readonly number: string | null
  /** A number waiting for its code. */
  readonly pendingNumber: string | null
}

export type AgentCallDecision = "call" | "off" | "trigger_off" | "no_number" | "duplicate" | "debounced"

export interface AgentCallClaim {
  readonly decision: AgentCallDecision
  readonly number?: string
  /** Debounced: milliseconds left of the window. */
  readonly waitMs?: number
}

/** The gate, pure: what the hub decides for one event, given what it holds. */
export const decideCall = (
  s: AgentCallSettings,
  trigger: AgentCallTrigger,
  seen: boolean,
  lastCallAt: number | null,
  now: number
): AgentCallClaim => {
  if (!s.enabled) return { decision: "off" }
  if (!s.number) return { decision: "no_number" }
  if (!s.triggers.includes(trigger)) return { decision: "trigger_off" }
  if (seen) return { decision: "duplicate" }
  if (lastCallAt !== null) {
    const since = now - lastCallAt
    // A clock moved back counts as just called, as on the iPhone.
    if (since < AGENT_CALL_DEBOUNCE_MS) return { decision: "debounced", waitMs: AGENT_CALL_DEBOUNCE_MS - Math.max(since, 0) }
  }
  return { decision: "call", number: s.number }
}

export const parseTriggers = (raw: unknown): Array<AgentCallTrigger> | null =>
  Array.isArray(raw) && raw.every((t) => (AGENT_CALL_TRIGGERS as ReadonlyArray<unknown>).includes(t)) ? [...new Set(raw as Array<AgentCallTrigger>)] : null

export const newCode = (): string => {
  const n = (crypto.getRandomValues(new Uint32Array(1))[0] ?? 0) % 1_000_000
  return n.toString().padStart(6, "0")
}
