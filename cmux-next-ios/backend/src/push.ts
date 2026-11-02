import { importPKCS8, SignJWT } from "jose"
import type { Env } from "./env.ts"
import { PUSH_KINDS, type PushKind, type PushRegistration } from "./store.ts"

/**
 * APNs for Feed-worthy agent events (PROTOCOL.md `POST /v1/devices/:deviceId/notify`). A deployed Worker's
 * fetch reaches APNs over HTTP/2 through Cloudflare's edge. Secrets: APNS_KEY_P8 (PKCS#8 PEM), APNS_KEY_ID,
 * APNS_TEAM_ID. Without them `notify` answers `configured:false` and sends nothing.
 */
export interface ApnsConfig {
  readonly keyP8: string
  readonly keyId: string
  readonly teamId: string
}

export const apnsConfig = (env: Env): ApnsConfig | null =>
  env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID ? { keyP8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID } : null

/** The bundle ids a phone may register a token for (APNS_TOPICS, comma separated). */
export const apnsTopics = (env: Env): ReadonlySet<string> =>
  new Set(
    (env.APNS_TOPICS ?? "")
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean)
  )

export interface CloudAttentionPush {
  readonly recipient: string
  readonly kind: "question" | "permission" | "done"
  readonly event_id: string
  readonly team_id: string
  readonly machine_id: string
  readonly session_id: string
  readonly deep_link: string
}

export interface CloudAttentionSendResult {
  readonly token: string
  readonly outcome: ApnsOutcome | "retry_later"
  readonly status: number
  readonly reason?: string
  /** APNs' opaque receipt id; safe to return to the caller, unlike the device token. */
  readonly apns_id?: string
}

const CLOUD_ATTENTION_KINDS = ["question", "permission", "done"] as const

/** A stable, full-width APNs collapse id; truncating event ids could merge unrelated events. */
export const cloudAttentionCollapseId = async (event: CloudAttentionPush): Promise<string> => {
  const input = JSON.stringify({ event_id: event.event_id, team_id: event.team_id, machine_id: event.machine_id, session_id: event.session_id, kind: event.kind })
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

/** Sends a Cloud attention banner to the owner's registered phones. Text stays out of APNs. */
export const sendCloudAttention = async (
  config: ApnsConfig,
  targets: ReadonlyArray<PushRegistration>,
  event: CloudAttentionPush,
  now: number,
  fetcher: typeof fetch = fetch,
): Promise<ReadonlyArray<CloudAttentionSendResult>> => {
  if (!CLOUD_ATTENTION_KINDS.includes(event.kind)) throw new Error("invalid Cloud attention kind")
  const token = await providerToken(config, now)
  const collapseId = await cloudAttentionCollapseId(event)
  const title = event.kind === "question" ? "Cloud chat has a question" : event.kind === "permission" ? "Cloud chat needs permission" : "Cloud chat finished"
  const body = JSON.stringify({
    aps: { alert: { title }, sound: "default", category: `CLOUD_${event.kind.toUpperCase()}` },
    cmux: {
      cloud: {
        kind: event.kind,
        event_id: event.event_id,
        team_id: event.team_id,
        machine_id: event.machine_id,
        session_id: event.session_id,
        deep_link: event.deep_link,
      },
    },
  })
  return Promise.all(targets.map(async (target) => {
    const host = target.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    try {
      const controller = new AbortController()
      const timeout = setTimeout(() => controller.abort(), 10_000)
      const request = new Request(`https://${host}/3/device/${target.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${token}`,
          "apns-topic": target.topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(Math.floor((now + 24 * 3600_000) / 1000)),
          "apns-collapse-id": collapseId,
          "content-type": "application/json",
        },
        body,
      })
      try {
        const response = await fetcher(request, { signal: controller.signal })
        const reason = response.status === 200 ? undefined : ((await response.json().catch(() => ({}))) as { reason?: string }).reason
        if (response.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) forgetProviderToken()
        const apnsId = response.headers.get("apns-id") ?? undefined
        return { token: target.token, outcome: classifyApns(response.status, reason), status: response.status, ...(reason ? { reason } : {}), ...(apnsId ? { apns_id: apnsId } : {}) }
      } finally {
        clearTimeout(timeout)
      }
    } catch (error) {
      return { token: target.token, outcome: "retry_later" as const, status: 0, reason: error instanceof DOMException && error.name === "AbortError" ? "timeout" : "network" }
    }
  }))
}

/** Apple wants one provider token reused for 20 to 60 minutes: one per isolate, renewed after 50 or when refused. */
let cached: { id: string; token: string; at: number } | undefined
const configId = (c: ApnsConfig) => `${c.teamId}:${c.keyId}:${c.keyP8.length}:${c.keyP8.slice(-16)}`
export const forgetProviderToken = () => {
  cached = undefined
}

export const providerToken = async (config: ApnsConfig, now: number): Promise<string> => {
  if (cached && cached.id === configId(config) && now - cached.at < 50 * 60_000) return cached.token
  const key = await importPKCS8(config.keyP8.replace(/\\n/g, "\n"), "ES256")
  const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.keyId }).setIssuer(config.teamId).setIssuedAt(Math.floor(now / 1000)).sign(key)
  cached = { id: configId(config), token, at: now }
  return token
}

/** A permission's acpmux option (PROTOCOL.md "Push notifications"). */
export interface PushOption {
  readonly id: string
  readonly label: string
  readonly kind?: OptionKind
}
export const OPTION_KINDS = ["allow_once", "allow_always", "reject_once", "reject_always"] as const
export type OptionKind = (typeof OPTION_KINDS)[number]

/** One AskUserQuestion-style question. */
export interface PushQuestion {
  readonly question: string
  readonly header?: string
  readonly multiSelect: boolean
  readonly allowsOther: boolean
  readonly options: ReadonlyArray<{ readonly label: string; readonly description?: string }>
}
export const PUSH_STATES = ["waiting", "finished", "failed", "notified"] as const
export type PushState = (typeof PUSH_STATES)[number]

/** What the Mac reports, cleaned. The Worker writes the banner text itself from these fields. */
export interface NotifyEvent {
  readonly eventId: string
  readonly kind: PushKind
  readonly agent?: string
  readonly place?: string
  readonly macId: string
  readonly macName: string
  readonly workspace?: string
  readonly workspaceId?: string
  readonly tabId?: string
  readonly sessionId?: string
  readonly permissionId?: string
  readonly conversationId?: string
  readonly notificationId?: string
  readonly title?: string
  readonly body?: string
  readonly options?: ReadonlyArray<PushOption>
  questions?: ReadonlyArray<PushQuestion>
  readonly tail?: ReadonlyArray<string>
  readonly state?: PushState
  /** Per phone device id: the content sealed to that phone's push key and the Mac's signature (API 0.14.0). */
  readonly sealed?: Readonly<Record<string, SealedBox>>
}

/** One phone's sealed notification (PROTOCOL.md "Sealed pushes and the reply mailbox"). */
export interface SealedBox {
  readonly box: string
  readonly sig: string
}

/** A box is at most 3 KB of base64url, so the whole APNs payload stays under 4096 bytes. */
export const MAX_SEALED_BOX = 3072
const MAX_SEALED_PHONES = 20
const BASE64URL = /^[A-Za-z0-9_-]+$/
const SIGNATURE = /^[0-9a-f]{128}$/
const PHONE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** How long a reply waits in the mailbox for its Mac (PROTOCOL.md). */
export const MAILBOX_TTL_MS = 10 * 60_000
/** The largest sealed reply, in base64url characters (32 of them stay under one WebSocket frame to the Mac). */
export const MAX_MAILBOX_SEALED = 16_384
/** Pending replies one Mac may have. */
export const MAILBOX_PENDING_LIMIT = 32
/** Whether `text` is a sealed blob as clients send it: non-empty base64url of at most `max` characters. */
export const isSealedText = (text: unknown, max: number): text is string => typeof text === "string" && text.length > 0 && text.length <= max && BASE64URL.test(text)

const parseSealed = (v: unknown): Record<string, SealedBox> | string => {
  const bad = "sealed must be {<phone device id>: {box, sig}} (box base64url of at most 3072 characters, sig 64 bytes in hex), at most 20 phones"
  if (!isObject(v)) return bad
  const entries = Object.entries(v)
  if (entries.length === 0 || entries.length > MAX_SEALED_PHONES) return bad
  const out: Record<string, SealedBox> = {}
  for (const [phone, entry] of entries) {
    const id = phone.toLowerCase()
    if (!PHONE_ID.test(id) || !isObject(entry) || !isSealedText(entry.box, MAX_SEALED_BOX)) return bad
    if (typeof entry.sig !== "string" || !SIGNATURE.test(entry.sig)) return bad
    out[id] = { box: entry.box, sig: entry.sig }
  }
  return out
}

/** Combining marks past two on one character are dropped (a Zalgo flood). */
const marks = (text: string): string => text.replace(/(\p{Mn}{2})\p{Mn}+/gu, "$1")

/** `chars` cut to `max` code points; a cut text ends with "…", so a long command's end is never hidden unmarked. */
const cut = (chars: ReadonlyArray<string>, max: number): string =>
  chars.length <= max ? chars.join("") : `${chars.slice(0, Math.max(0, max - 1)).join("")}…`

/** Printable text cut to `max` code points: control and format characters become spaces. */
export const clean = (text: unknown, max: number): string =>
  typeof text !== "string" ? "" : cut(Array.from(marks(text.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/gu, " ").replace(/\s+/g, " ").trim())), max)

const EVENT_ID = /^[A-Za-z0-9._:-]{1,64}$/
const OPAQUE_ID = /^[A-Za-z0-9._:-]{1,128}$/
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const present = (v: unknown) => v !== undefined && v !== null

/**
 * The notify body (PROTOCOL.md `POST /v1/devices/:macId/notify`, 0.13.0 fields), cleaned and cut to the
 * documented limits; a list longer than its limit is cut, a field of the wrong type is refused. The answer is
 * the event without the Mac's own fields, or the reason it was refused.
 */
export const parseNotify = (b: Record<string, unknown>): Omit<NotifyEvent, "macId" | "macName"> | string => {
  if (typeof b.eventId !== "string" || !EVENT_ID.test(b.eventId)) return "eventId must be 1-64 of A-Z a-z 0-9 . _ : -"
  if (!(PUSH_KINDS as ReadonlyArray<unknown>).includes(b.kind)) return `kind must be one of ${PUSH_KINDS.join(", ")}`
  // Everything else is optional: a malformed field is dropped, not the push (a lost ask is worse than a plain one).
  const ids: Record<string, string> = {}
  for (const [k, re] of [
    ["workspaceId", OPAQUE_ID],
    ["tabId", OPAQUE_ID],
    ["sessionId", OPAQUE_ID],
    ["permissionId", OPAQUE_ID],
    ["conversationId", OPAQUE_ID],
    ["notificationId", EVENT_ID]
  ] as const) {
    const v = b[k]
    if (typeof v === "string" && re.test(v)) ids[k] = v
  }
  const texts: Record<string, string> = {}
  for (const [k, max] of [
    ["agent", 40],
    ["place", 60],
    ["workspace", 60],
    ["title", 200],
    ["body", 400]
  ] as const) {
    const c = clean(b[k], max)
    if (c) texts[k] = c
  }
  const state = (PUSH_STATES as ReadonlyArray<unknown>).includes(b.state) ? (b.state as PushState) : undefined
  let options: Array<PushOption> | undefined
  if (Array.isArray(b.options)) {
    options = []
    for (const o of b.options) {
      if (options.length >= 6) break
      if (!isObject(o) || typeof o.id !== "string" || !OPAQUE_ID.test(o.id) || o.id.length > 64 || typeof o.label !== "string") continue
      const kind = (OPTION_KINDS as ReadonlyArray<unknown>).includes(o.kind) ? (o.kind as OptionKind) : undefined
      options.push({ id: o.id, label: clean(o.label, 60), ...(kind ? { kind } : {}) })
    }
  }
  let questions: Array<PushQuestion> | undefined
  if (Array.isArray(b.questions)) {
    questions = []
    for (const q of b.questions) {
      if (questions.length >= 4) break
      if (!isObject(q) || typeof q.question !== "string") continue
      const opts: Array<{ label: string; description?: string }> = []
      for (const o of Array.isArray(q.options) ? q.options : []) {
        if (opts.length >= 6) break
        if (!isObject(o) || typeof o.label !== "string") continue
        const description = clean(o.description, 120)
        opts.push({ label: clean(o.label, 60), ...(description ? { description } : {}) })
      }
      const header = clean(q.header, 30)
      questions.push({ question: clean(q.question, 200), ...(header ? { header } : {}), multiSelect: q.multiSelect === true, allowsOther: q.allowsOther === true, options: opts })
    }
    if (!questions.length) questions = undefined
  }
  let sealed: Record<string, SealedBox> | undefined
  if (present(b.sealed)) {
    const r = parseSealed(b.sealed)
    if (typeof r === "string") return r
    sealed = r
  }
  let tail: Array<string> | undefined
  if (Array.isArray(b.tail)) {
    tail = (b.tail as Array<unknown>)
      .filter((l): l is string => typeof l === "string")
      .slice(-6)
      .map((l) => clean(l, 160))
    if (!tail.length) tail = undefined
  }
  return {
    eventId: b.eventId,
    kind: b.kind as PushKind,
    ...texts,
    ...ids,
    ...(state ? { state } : {}),
    ...(options ? { options } : {}),
    ...(questions ? { questions } : {}),
    ...(tail ? { tail } : {}),
    ...(sealed ? { sealed } : {})
  }
}

/** The rate-limit key of a notify: terminal notifications have their own bucket, so a program that loops
 * OSC 9 never starves a Mac's questions and permission requests (review M3). */
export const notifyLimitKey = (macId: string, kind: PushKind): string => (kind === "terminal" ? `${macId}:terminal` : macId)

const TITLES: Record<PushKind, (agent: string) => string> = {
  question: (a) => `${a} has a question`,
  permission: (a) => `${a} needs permission`,
  completed: (a) => `${a} finished`,
  failed: (a) => `${a} stopped with an error`,
  chief: () => "Chief replied",
  terminal: () => "Terminal"
}

/** Kinds that end a turn: a session's newer one replaces its older one on the phone. */
const TURN_KINDS: ReadonlySet<PushKind> = new Set<PushKind>(["completed", "failed", "chief"])

/** 64-bit FNV-1a of a string, 16 hex digits: a short stable stand-in for a long id. */
const fnv = (text: string): string => {
  let h = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(text)) h = ((h ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return h.toString(16).padStart(16, "0")
}

/**
 * The APNs collapse id (at most 64 bytes): one per session for a finished turn, an error or a Chief reply,
 * so a newer one replaces the older on the lock screen; each ask keeps its own (every one needs an answer);
 * a terminal notification collapses per daemon ledger id.
 */
export const collapseId = (e: Pick<NotifyEvent, "eventId" | "kind" | "sessionId" | "notificationId"> & { readonly macId?: string }): string => {
  // Ledger ids repeat across Macs: scoped by Mac, so one Mac's notification never replaces another's.
  if (e.kind === "terminal" && e.notificationId) {
    const id = `term-${fnv(e.macId ?? "")}-${e.notificationId}`
    return id.length <= 64 ? id : `term-${fnv(`${e.macId ?? ""}:${e.notificationId}`)}`
  }
  if (!e.sessionId || !TURN_KINDS.has(e.kind)) return e.eventId.slice(0, 64)
  const id = `turn-${e.sessionId}`
  return id.length <= 64 ? id : `turn-${fnv(e.sessionId)}`
}

/** The window in which a Mac's session passes one turn-ending push (an error counts apart). Under the Mac's own 30 s. */
export const TURN_PUSH_WINDOW_MS = 15_000

/**
 * The key a turn-ending event is coalesced under (one per Mac, session and finished-or-error), or null for an
 * event that is never coalesced: an ask (each one needs an answer) or one without a session.
 */
export const turnPushKey = (macId: string, e: Pick<NotifyEvent, "kind" | "sessionId">): string | null =>
  e.sessionId && TURN_KINDS.has(e.kind) ? `${macId}:${e.sessionId}:${e.kind === "failed" ? "failed" : "done"}` : null

/** The notification group: the session, else the terminal tab, else the Chief, else the Mac. */
export const threadId = (e: Pick<NotifyEvent, "macId" | "sessionId" | "tabId" | "conversationId"> & Partial<Pick<NotifyEvent, "kind">>): string =>
  e.sessionId ? `${e.macId}:${e.sessionId}` : e.tabId ? `${e.macId}:${e.tabId}` : e.conversationId ? `${e.macId}:chief:${e.conversationId}` : e.macId

/** The phone's category: an ask with one single-choice question of 1 to 4 options gets one button per option. */
export const category = (e: Pick<NotifyEvent, "kind" | "questions">): string => {
  if (e.kind !== "question") return `CMUX_MOBILE_${e.kind.toUpperCase()}`
  const q = e.questions
  const buttons = q?.length === 1 && !q[0]!.multiSelect && q[0]!.options.length >= 1 && q[0]!.options.length <= 4
  return buttons ? "CMUX_MOBILE_QUESTION" : "CMUX_MOBILE_QUESTION_FORM"
}

const rich = (e: NotifyEvent) => !!(e.title || e.body || e.tail?.length || e.questions?.length)

/** The banner: per kind from the content, else the 0.11 fixed text; previews off hides content. */
const alert = (e: NotifyEvent, previews: boolean) => {
  const agent = e.agent || "Your agent"
  const where = e.workspace || e.place
  if (!previews) return { title: TITLES[e.kind](agent), body: e.macName }
  if (!rich(e)) return { title: TITLES[e.kind](agent), body: where ? `${where} · ${e.macName}` : e.macName }
  const last = e.tail?.length ? e.tail[e.tail.length - 1] : undefined
  const [title, body] = (() => {
    switch (e.kind) {
      case "question":
        return [`${agent} asks`, e.questions?.[0]?.question || e.title || ""]
      case "permission":
        // As the Mac's approval prompt for a streaming device (the phone's ApprovalBanner): the Mac in the title.
        return [`${agent} wants to act on ${e.macName}`, e.title || e.body || ""]
      case "completed":
        return [`${agent} finished`, last || e.body || ""]
      case "failed":
        return [`${agent} stopped with an error`, e.body || last || ""]
      case "chief":
        return ["Chief", e.body || last || ""]
      case "terminal":
        // A program chooses its own title: it never stands where an agent's banner would (review M3).
        return [where ? `Terminal · ${where}` : "Terminal", [e.title, e.body].filter(Boolean).join(": ")]
    }
  })()
  if (e.kind === "permission") return where ? { title, subtitle: where, body } : { title, body }
  return { title, subtitle: where ? `${where} · ${e.macName}` : e.macName, body }
}

/** APNs refuses a payload over 4096 bytes. */
export const MAX_PAYLOAD_BYTES = 4096
const size = (v: unknown) => new TextEncoder().encode(JSON.stringify(v)).length
const shorten = (s: string) => {
  const chars = Array.from(s.endsWith("…") ? s.slice(0, -1) : s)
  return cut(chars, Math.max(20, Math.floor(chars.length / 2)))
}

/** The `cmuxMobile` object of a v2 payload: the Mac's name, the routing ids and the content the phone acts on. */
export type MobilePayload = { v: 2; mac: string; macName: string; kind: PushKind; eventId: string; previews: boolean } & Partial<
  Pick<
    NotifyEvent,
    | "agent"
    | "place"
    | "workspace"
    | "workspaceId"
    | "tabId"
    | "sessionId"
    | "permissionId"
    | "conversationId"
    | "notificationId"
    | "title"
    | "body"
    | "options"
    | "questions"
    | "tail"
    | "state"
  >
>

const build = (e: NotifyEvent, previews: boolean): { aps: Record<string, unknown> & { alert: { title: string; subtitle?: string; body: string }; "thread-id": string; category: string }; cmuxMobile: MobilePayload } => {
  const ask = e.kind === "question" || e.kind === "permission"
  const thread = threadId(e)
  const optional = <K extends keyof NotifyEvent>(k: K) => (e[k] !== undefined && e[k] !== "" ? { [k]: e[k] } : {})
  return {
    aps: {
      alert: alert(e, previews),
      sound: "default",
      "mutable-content": 1,
      "thread-id": thread,
      category: category(e),
      "target-content-id": thread,
      ...(ask ? { "interruption-level": "time-sensitive" } : {})
    },
    cmuxMobile: {
      v: 2 as const,
      mac: e.macId,
      macName: e.macName,
      kind: e.kind,
      eventId: e.eventId,
      ...optional("agent"),
      ...optional("place"),
      ...optional("workspace"),
      ...optional("workspaceId"),
      ...optional("tabId"),
      ...optional("sessionId"),
      ...optional("permissionId"),
      ...optional("conversationId"),
      ...optional("notificationId"),
      ...optional("title"),
      ...optional("body"),
      ...optional("options"),
      ...optional("questions"),
      ...optional("tail"),
      ...optional("state"),
      previews
    }
  }
}

/**
 * The APNs JSON body for one phone, at most 4096 bytes: past it the tail goes first (oldest line first), then
 * the title is shortened, then the questions are dropped (the ask becomes a form), then the body is shortened.
 */
export const apnsPayload = (e: NotifyEvent, opts: { previews?: boolean } = {}) => {
  const previews = opts.previews ?? true
  let cur: NotifyEvent = { ...e }
  let p = build(cur, previews)
  const fits = () => size(p) <= MAX_PAYLOAD_BYTES
  const set = (next: NotifyEvent) => {
    cur = next
    p = build(cur, previews)
  }
  // Option descriptions are the least needed to act: they go first.
  if (!fits() && cur.questions?.some((q) => q.options.some((o) => o.description)))
    set({ ...cur, questions: cur.questions.map((q) => ({ ...q, options: q.options.map(({ label }) => ({ label })) })) })
  while (!fits() && cur.tail?.length) {
    const tail = cur.tail.slice(1)
    const next = { ...cur, tail }
    if (!tail.length) delete (next as { tail?: unknown }).tail
    set(next)
  }
  while (!fits() && cur.title && Array.from(cur.title).length > 20) set({ ...cur, title: shorten(cur.title) })
  if (!fits() && cur.questions) {
    const next = { ...cur }
    delete next.questions
    set(next)
  }
  while (!fits() && cur.body && Array.from(cur.body).length > 20) set({ ...cur, body: shorten(cur.body) })
  // Last resort: only what names and routes the push (every text shortened to its floor).
  if (!fits()) {
    const floor = (t: string | undefined, n: number) => (t ? clean(t, n) : undefined)
    const next: NotifyEvent = {
      eventId: cur.eventId,
      kind: cur.kind,
      macId: cur.macId,
      macName: clean(cur.macName, 20),
      ...(cur.agent ? { agent: floor(cur.agent, 20)! } : {}),
      ...(cur.workspace ? { workspace: floor(cur.workspace, 20)! } : {}),
      ...(cur.place ? { place: floor(cur.place, 20)! } : {}),
      ...(cur.title ? { title: floor(cur.title, 20)! } : {}),
      ...(cur.sessionId ? { sessionId: cur.sessionId } : {}),
      ...(cur.workspaceId ? { workspaceId: cur.workspaceId } : {}),
      ...(cur.tabId ? { tabId: cur.tabId } : {}),
      ...(cur.permissionId ? { permissionId: cur.permissionId } : {}),
      ...(cur.conversationId ? { conversationId: cur.conversationId } : {}),
      ...(cur.notificationId ? { notificationId: cur.notificationId } : {}),
      ...(cur.state ? { state: cur.state } : {})
    }
    set(next)
  }
  return p
}

/** The registrations to push `kind` from `macId` to: they want the kind and did not mute the Mac. */
export const pushTargets = (regs: ReadonlyArray<PushRegistration>, macId: string, kind: PushKind): Array<PushRegistration> =>
  regs.filter((r) => r.kinds.includes(kind) && !r.mutedMacs.includes(macId))

/** The kinds some phone that has not muted `macId` wants, in PUSH_KINDS order. */
export const wantedKinds = (regs: ReadonlyArray<PushRegistration>, macId: string): Array<PushKind> => {
  const wanted = new Set(regs.filter((r) => !r.mutedMacs.includes(macId)).flatMap((r) => r.kinds))
  return PUSH_KINDS.filter((k) => wanted.has(k))
}

export const apnsRequest = (target: PushRegistration, e: NotifyEvent, token: string, now: number): Request => {
  const host = target.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
  const ask = e.kind === "question" || e.kind === "permission"
  return new Request(`https://${host}/3/device/${target.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": target.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // An ask matters for a day; a finished turn or a terminal notification for an hour.
      "apns-expiration": String(Math.floor((now + (ask ? 24 * 3600_000 : 3600_000)) / 1000)),
      "apns-collapse-id": collapseId(e),
      "content-type": "application/json"
    },
    body: JSON.stringify(
      sealedFor(e, target) ? sealedPayload(e, sealedFor(e, target)!, { previews: target.previews }) : apnsPayload(e, { previews: target.previews })
    )
  })
}

const sealedFor = (e: NotifyEvent, target: PushRegistration): SealedBox | undefined => e.sealed?.[target.deviceId.toLowerCase()]

/**
 * The APNs body for a phone the Mac sealed this event to (v3): a generic banner, the routing kind and ids, and
 * the box its Notification Service Extension opens. No content field and no readable id leaves here: the
 * thread is a hash, the category the kind's (the extension sets the exact one).
 */
export const sealedPayload = (e: NotifyEvent, sealed: SealedBox, opts: { previews?: boolean } = {}) => {
  const ask = e.kind === "question" || e.kind === "permission"
  const thread = fnv(threadId(e))
  return {
    aps: {
      alert: { title: "cmux", body: `New notification from ${e.macName}` },
      sound: "default",
      "mutable-content": 1 as const,
      "thread-id": thread,
      // No buttons until the extension opened it and set the real category (security review H1).
      category: "CMUX_MOBILE_SEALED",
      ...(ask ? { "interruption-level": "time-sensitive" } : {})
    },
    cmuxMobile: {
      v: 3 as const,
      mac: e.macId,
      macName: clean(e.macName, 40),
      kind: e.kind,
      eventId: e.eventId,
      previews: opts.previews ?? true,
      box: sealed.box,
      sig: sealed.sig
    }
  }
}

export type ApnsOutcome = "sent" | "drop_target" | "failed"

export const classifyApns = (status: number, reason: string | undefined): ApnsOutcome => {
  if (status === 200) return "sent"
  if (status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") return "drop_target"
  return "failed"
}

/** Sends one event to every target; never throws. */
export const sendApns = async (
  config: ApnsConfig,
  targets: ReadonlyArray<PushRegistration>,
  e: NotifyEvent,
  now: number,
  fetcher: typeof fetch = fetch
): Promise<Array<{ token: string; outcome: ApnsOutcome; status: number; reason?: string }>> => {
  if (targets.length === 0) return []
  const token = await providerToken(config, now)
  return Promise.all(
    targets.map(async (t) => {
      try {
        const res = await fetcher(apnsRequest(t, e, token, now))
        const reason = res.status === 200 ? undefined : ((await res.json().catch(() => ({}))) as { reason?: string }).reason
        if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) cached = undefined
        return { token: t.token, outcome: classifyApns(res.status, reason), status: res.status, ...(reason ? { reason } : {}) }
      } catch (err) {
        return { token: t.token, outcome: "failed" as const, status: 0, reason: String(err).slice(0, 120) }
      }
    })
  )
}
