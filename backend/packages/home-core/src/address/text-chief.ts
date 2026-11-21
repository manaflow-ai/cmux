/**
 * Texting Chief over one shared line (home-messaging.md section 19; Lawrence 2026-11-02: "we only
 * have a single imessage number", "you just talk to primary chief, and you can designate which one
 * is primary chief"). Pure: the AddressDO adapter passes the sender's chiefs, the text and the
 * configuration.
 *
 * - A text goes to the person's primary Chief (the chief record with `is_default`).
 * - `/primary <name>` makes another Chief primary (the same `chief.update {is_default: true}` the
 *   app's settings use); `/primary` or `/chiefs` alone lists the Chiefs.
 * - `@<name> <text>` sends that one text to another Chief; the primary stays.
 * - A reply starts with its Chief's name when more than one Chief is in play in the thread.
 */

/** One of the person's Chiefs, as `chief.list` returns it. */
export interface TextChief {
  readonly id: string
  readonly display_name: string
  readonly is_default: boolean
  readonly main_conversation: string | null
}

export type TextCommand =
  | { readonly kind: "send"; readonly chief: TextChief; readonly text: string; readonly one_off: boolean }
  | { readonly kind: "primary"; readonly chief: TextChief }
  | { readonly kind: "list" }
  | { readonly kind: "help" }
  | { readonly kind: "unknown_chief"; readonly name: string }
  | { readonly kind: "no_chief" }

const key = (s: string) => s.trim().toLowerCase().replace(/\s+/g, " ")

/** A Chief by id, exact name, or a unique name prefix (case and spacing do not matter). */
export const findChief = (chiefs: ReadonlyArray<TextChief>, name: string): TextChief | null => {
  const k = key(name)
  if (!k) return null
  const byId = chiefs.find((c) => c.id === name.trim())
  if (byId) return byId
  const exact = chiefs.filter((c) => key(c.display_name) === k)
  if (exact.length === 1) return exact[0]!
  const squashed = k.replace(/ /g, "")
  const prefix = chiefs.filter((c) => key(c.display_name).replace(/ /g, "").startsWith(squashed))
  return prefix.length === 1 ? prefix[0]! : null
}

/** The primary Chief: the default one, else the first (a list always has one default when it has any). */
export const primaryChief = (chiefs: ReadonlyArray<TextChief>): TextChief | null => chiefs.find((c) => c.is_default) ?? chiefs[0] ?? null

/**
 * What a text asks for. `fixed` is the Chief a dedicated line always talks to (TEXT_CHIEF_LINES),
 * which turns off `/primary` and `@name` on that line.
 */
export const parseTextCommand = (content: string, chiefs: ReadonlyArray<TextChief>, fixed: TextChief | null = null): TextCommand => {
  const text = content.trim()
  if (fixed) return { kind: "send", chief: fixed, text, one_off: false }
  const slash = /^\/(primary|chief|chiefs|help)\b\s*(.*)$/is.exec(text)
  if (slash) {
    const verb = slash[1]!.toLowerCase()
    const arg = slash[2]!.trim()
    if (verb === "help") return { kind: "help" }
    if (verb === "chiefs" || !arg) return { kind: "list" }
    const chief = findChief(chiefs, arg)
    return chief ? { kind: "primary", chief } : { kind: "unknown_chief", name: arg }
  }
  // `@name text`: the longest Chief name that the text starts with (names may have spaces).
  if (text.startsWith("@")) {
    const rest = text.slice(1)
    const byLength = [...chiefs].sort((a, b) => b.display_name.length - a.display_name.length)
    for (const c of byLength) {
      const n = c.display_name.trim()
      if (n && rest.toLowerCase().startsWith(n.toLowerCase()) && (rest.length === n.length || /[\s,:]/.test(rest[n.length]!))) {
        return { kind: "send", chief: c, text: rest.slice(n.length).replace(/^[\s,:]+/, "").trim(), one_off: !c.is_default }
      }
    }
    const word = /^(\S+)\s*(.*)$/s.exec(rest)
    const chief = word ? findChief(chiefs, word[1]!.replace(/[,:]$/, "")) : null
    if (chief) return { kind: "send", chief, text: word![2]!.trim(), one_off: !chief.is_default }
    // An unknown @word is ordinary text for the primary (people write "@" for other reasons).
  }
  const primary = primaryChief(chiefs)
  return primary ? { kind: "send", chief: primary, text, one_off: false } : { kind: "no_chief" }
}

/** The list reply: every Chief, the primary marked. */
export const chiefListText = (chiefs: ReadonlyArray<TextChief>): string => {
  if (chiefs.length === 0) return "You have no Chiefs yet. Open cmux to make one."
  const lines = chiefs.map((c) => `${c.is_default ? "• " : "  "}${c.display_name}${c.is_default ? " (primary)" : ""}`)
  return [`Your Chiefs:`, ...lines, ``, `Text "/primary <name>" to change who answers, or start a text with "@<name>" to ask another Chief once.`].join("\n")
}

export const TEXT_HELP =
  'You are texting your primary Chief. "/chiefs" lists your Chiefs, "/primary <name>" changes who answers, and "@<name> <text>" asks another Chief once. Reply STOP to stop texts.'

export const UNKNOWN_SENDER_TEXT = "Hi! This is the cmux line for texting Chief. This number is not linked to a cmux account, so nobody will read or answer texts here."

/**
 * A Chief's reply as a text: its name first when more than one Chief is in play (the thread has
 * heard from more than one Chief lately, or the reply is not from the primary).
 */
export const replyText = (body: string, chiefName: string, prefix: boolean, max = TEXT_MAX): string => {
  const head = prefix ? `${chiefName}: ` : ""
  const room = max - head.length
  const trimmed = body.trim()
  return head + (trimmed.length > room ? `${trimmed.slice(0, room - 20).trimEnd()}… (more in cmux)` : trimmed)
}

/** iMessage takes up to ~19k characters; a text that long is unreadable, so replies stop well before. */
export const TEXT_MAX = 6_000

/** The words of a message's parts as a text (attachments and other parts as one short line each). */
export const partsText = (parts: ReadonlyArray<{ readonly type: string; readonly text?: unknown; readonly name?: unknown; readonly prompt?: unknown }>): string =>
  parts
    .map((p) => {
      if (p.type === "text" && typeof p.text === "string") return p.text
      if (p.type === "question" && typeof p.prompt === "string") return p.prompt
      if (p.type === "attachment") return `[${typeof p.name === "string" ? p.name : "attachment"} in cmux]`
      return ""
    })
    .filter((s) => s.trim().length > 0)
    .join("\n")

/** One line of TEXT_CHIEF_LINES: who a line belongs to (absent = shared, routed by sender) and an optional fixed Chief. */
export interface TextLine {
  readonly number: string
  readonly owner: string | null
  readonly chief: string | null
}

const E164 = /^\+[1-9][0-9]{7,14}$/

/**
 * The lines texts may arrive on: TEXT_CHIEF_LINES (JSON `{"+1555…": {"owner": "user_…|email", "chief":
 * "agent_…"}}`, every field optional) or else the one shared SendBlue number. A bad entry is dropped.
 */
export const parseTextLines = (raw: string | undefined, shared: string | undefined): ReadonlyArray<TextLine> => {
  const out: Array<TextLine> = []
  if (raw) {
    try {
      const obj = JSON.parse(raw) as Record<string, unknown>
      for (const [number, v] of Object.entries(obj ?? {})) {
        if (!E164.test(number)) continue
        const o = (v && typeof v === "object" ? v : {}) as { owner?: unknown; chief?: unknown }
        out.push({ number, owner: typeof o.owner === "string" ? o.owner : null, chief: typeof o.chief === "string" ? o.chief : null })
      }
    } catch {
      // A malformed map is no map: only the shared line remains.
    }
  }
  if (shared && E164.test(shared) && !out.some((l) => l.number === shared)) out.push({ number: shared, owner: null, chief: null })
  return out
}

/**
 * TEXT_CHIEF_PEOPLE (a secret: phone numbers are personal data): JSON `{"+1555…": "user_…" | "email"}`,
 * the senders allowed to text Chief before the in-app link exists for them. Returns the account or
 * email for `phone`, or null.
 */
export const textPersonOf = (raw: string | undefined, phone: string): string | null => {
  if (!raw) return null
  try {
    const v = (JSON.parse(raw) as Record<string, unknown>)[phone]
    return typeof v === "string" && v.length > 0 ? v : null
  } catch {
    return null
  }
}
