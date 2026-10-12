/**
 * Agent questions in a conversation, equal to the Rust crate's question.rs:
 * the `question` part an agent posts, the `question.answer` op a person
 * commits, and the rules the owner checks for both.
 *
 * Only an agent posts a question; only a human answers one, once. The owner
 * stamps who answered (and from which paired device) from the connection's
 * participant, never from the request. Parsing follows serde: optional fields
 * accept null as absent, defaulted fields are filled in, unknown fields are
 * dropped, and a wrong type is refused.
 */
import { fail } from "./reject.ts"
import type { Participant, Part } from "./types.ts"

/** Most items (questions) in one ask. */
export const MAX_QUESTION_ITEMS = 4
/** Most options in one item. */
export const MAX_QUESTION_OPTIONS = 12
/** Longest prompt, option detail or Other answer, in UTF-8 bytes. */
export const MAX_QUESTION_TEXT_BYTES = 2048
/** Longest header chip or option label, in UTF-8 bytes. */
export const MAX_QUESTION_LABEL_BYTES = 256
/** Longest option preview, in UTF-8 bytes. */
export const MAX_QUESTION_PREVIEW_BYTES = 8192

/** The harness that asked; it decides how the answer reaches the agent. */
export type QuestionHarness = "claude" | "codex" | "acp" | "chief"
const HARNESSES: ReadonlyArray<string> = ["claude", "codex", "acp", "chief"]
export type PreviewFormat = "monospace" | "markdown"

export interface QuestionPreview {
  readonly text: string
  readonly format: PreviewFormat
}

export interface QuestionOption {
  readonly id: string
  readonly label: string
  readonly detail?: string
  readonly preview?: QuestionPreview
}

export interface QuestionItem {
  readonly id: string
  readonly header?: string
  readonly prompt: string
  readonly options: ReadonlyArray<QuestionOption>
  readonly multi_select: boolean
  readonly allows_other: boolean
}

export interface QuestionSelection {
  readonly option_ids: ReadonlyArray<string>
  readonly other?: string
}

/** Who answered, stamped by the owner. */
export interface Respondent {
  /** The person (`user_local`, `user_<id>`); a paired device answers as its person. */
  readonly participant: string
  readonly display_name: string
  /** The paired device's name, for an answer from a paired install. */
  readonly device?: string
  readonly remote: boolean
}

/** What a person chose. In a `question.answer` op only `selections` is read; the owner sets the rest. */
export interface QuestionAnswer {
  /** Keyed by item id; serialized in code point order, as the Rust `BTreeMap`. */
  readonly selections: Readonly<Record<string, QuestionSelection>>
  readonly respondent?: Respondent
  readonly answered_at?: string
}

export type QuestionState = { readonly kind: "pending" } | { readonly kind: "answered"; readonly answer: QuestionAnswer } | { readonly kind: "cancelled" }

export interface QuestionPart {
  readonly type: "question"
  readonly harness: QuestionHarness
  /** The acpmux session that asked. */
  readonly session: string
  /** The acpmux permission the answer settles, when the ask is one. */
  readonly permission?: string
  /** The asking agent's display name. */
  readonly agent?: string
  readonly items: ReadonlyArray<QuestionItem>
  readonly state: QuestionState
}

/** Thrown by the parsers below; each caller maps it to its reject code. */
class Malformed extends Error {}
const malformed = (): never => {
  throw new Malformed()
}

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)
const str = (value: unknown): string => (typeof value === "string" ? value : malformed())
/** serde `Option<String>`: absent or null is None. */
const optStr = (value: unknown): string | undefined => (value === undefined || value === null ? undefined : str(value))
/** serde `#[serde(default)] bool`: absent takes the default, null is refused. */
const bool = (value: unknown, fallback: boolean): boolean => (value === undefined ? fallback : typeof value === "boolean" ? value : malformed())
const list = (value: unknown): ReadonlyArray<unknown> => (value === undefined ? [] : Array.isArray(value) ? value : malformed())
const object = (value: unknown): Record<string, unknown> => (isObject(value) ? value : malformed())

/** UTF-8 length, as Rust `str::len()`. */
const bytes = (text: string): number => Buffer.byteLength(text, "utf8")
/** Rust `str::trim` (the White_Space property; JavaScript's trim also strips U+FEFF and keeps U+0085). */
export const rustTrim = (text: string): string => text.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, "")
/** Rust `short`: not blank and at most `max` bytes. */
const short = (value: string, max: number): boolean => rustTrim(value).length > 0 && bytes(value) <= max

/** Code point order (equal to UTF-8 byte order), as a Rust `BTreeMap<String, _>` serializes. */
const byCodePoint = (a: string, b: string): number => {
  const x = [...a]
  const y = [...b]
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i]!.codePointAt(0)! - y[i]!.codePointAt(0)!
    if (d !== 0) return d
  }
  return x.length - y.length
}

const parseSelection = (value: unknown): QuestionSelection => {
  const raw = object(value)
  const other = optStr(raw.other)
  return { option_ids: list(raw.option_ids).map(str), ...(other === undefined ? {} : { other }) }
}

/** serde `BTreeMap<String, QuestionSelection>`: own keys only, sorted. */
const parseSelections = (value: unknown): Record<string, QuestionSelection> => {
  const raw = object(value)
  return Object.fromEntries(
    Object.keys(raw)
      .sort(byCodePoint)
      .map((key) => [key, parseSelection(raw[key])])
  )
}

const parseAnswer = (value: unknown): QuestionAnswer => {
  const raw = object(value)
  if (raw.selections === undefined) malformed()
  const respondent = raw.respondent === undefined || raw.respondent === null ? undefined : object(raw.respondent)
  const answeredAt = optStr(raw.answered_at)
  let stamped: Respondent | undefined
  if (respondent) {
    const device = optStr(respondent.device)
    stamped = { participant: str(respondent.participant), display_name: str(respondent.display_name), ...(device === undefined ? {} : { device }), remote: bool(respondent.remote, false) }
  }
  return { selections: parseSelections(raw.selections), ...(stamped ? { respondent: stamped } : {}), ...(answeredAt === undefined ? {} : { answered_at: answeredAt }) }
}

const parseState = (value: unknown): QuestionState => {
  if (value === undefined) return { kind: "pending" }
  const raw = object(value)
  if (raw.kind === "pending" || raw.kind === "cancelled") return { kind: raw.kind }
  if (raw.kind === "answered") return { kind: "answered", answer: parseAnswer(raw.answer) }
  return malformed()
}

const parseOption = (value: unknown): QuestionOption => {
  const raw = object(value)
  const detail = optStr(raw.detail)
  let preview: QuestionPreview | undefined
  if (raw.preview !== undefined && raw.preview !== null) {
    const p = object(raw.preview)
    const format = p.format === undefined ? "monospace" : p.format === "monospace" || p.format === "markdown" ? p.format : malformed()
    preview = { text: str(p.text), format }
  }
  return { id: str(raw.id), label: str(raw.label), ...(detail === undefined ? {} : { detail }), ...(preview ? { preview } : {}) }
}

const parseItem = (value: unknown): QuestionItem => {
  const raw = object(value)
  const header = optStr(raw.header)
  return {
    id: str(raw.id),
    ...(header === undefined ? {} : { header }),
    prompt: str(raw.prompt),
    options: list(raw.options).map(parseOption),
    multi_select: bool(raw.multi_select, false),
    allows_other: bool(raw.allows_other, true)
  }
}

/** The serde round trip of a question part: Rust field order, defaults filled, unknown fields dropped. */
const parseQuestion = (value: Record<string, unknown>): QuestionPart => {
  const harness = str(value.harness)
  if (!HARNESSES.includes(harness)) malformed()
  if (!Array.isArray(value.items)) malformed()
  const permission = optStr(value.permission)
  const agent = optStr(value.agent)
  return {
    type: "question",
    harness: harness as QuestionHarness,
    session: str(value.session),
    ...(permission === undefined ? {} : { permission }),
    ...(agent === undefined ? {} : { agent }),
    items: (value.items as Array<unknown>).map(parseItem),
    state: parseState(value.state)
  }
}

/**
 * Parses and checks a question part's shape: sizes and unique ids (Rust
 * `question::validate`). A send also requires `pending` (apply); an edit may
 * only cancel (`checkQuestionEdit`).
 */
export const validateQuestion = (value: Record<string, unknown>): QuestionPart => {
  let question: QuestionPart
  try {
    question = parseQuestion(value)
  } catch (error) {
    if (error instanceof Malformed) return fail("invalid_parts")
    throw error
  }
  const items = question.items
  const itemsOk = items.length > 0 && items.length <= MAX_QUESTION_ITEMS
  const idsOk = new Set(items.map((item) => item.id)).size === items.length
  const refsOk =
    short(question.session, MAX_QUESTION_LABEL_BYTES) &&
    (question.permission === undefined || short(question.permission, MAX_QUESTION_LABEL_BYTES)) &&
    (question.agent === undefined || short(question.agent, MAX_QUESTION_LABEL_BYTES))
  if (!itemsOk || !idsOk || !refsOk) fail("invalid_parts")
  for (const item of items) {
    const valid =
      short(item.id, MAX_QUESTION_LABEL_BYTES) &&
      short(item.prompt, MAX_QUESTION_TEXT_BYTES) &&
      (item.header === undefined || short(item.header, MAX_QUESTION_LABEL_BYTES)) &&
      item.options.length <= MAX_QUESTION_OPTIONS &&
      new Set(item.options.map((option) => option.id)).size === item.options.length &&
      (item.options.length > 0 || item.allows_other) &&
      item.options.every(
        (option) =>
          short(option.id, MAX_QUESTION_LABEL_BYTES) &&
          short(option.label, MAX_QUESTION_LABEL_BYTES) &&
          (option.detail === undefined || bytes(option.detail) <= MAX_QUESTION_TEXT_BYTES) &&
          (option.preview === undefined || bytes(option.preview.text) <= MAX_QUESTION_PREVIEW_BYTES)
      )
    if (!valid) fail("invalid_parts")
  }
  return question
}

const isQuestion = (part: Part): part is QuestionPart => part.type === "question"

/** Stored parts come from the host (a database row); compare them in the same normal form. */
const normal = (part: QuestionPart): QuestionPart => {
  try {
    return parseQuestion(part as unknown as Record<string, unknown>)
  } catch (error) {
    if (error instanceof Malformed) return fail("invalid_parts")
    throw error
  }
}
const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)

/**
 * A message edit may not touch a question except to cancel a pending one:
 * the question parts must sit at the same indexes with the same content
 * (Rust `question::check_edit`). `after` is already validated.
 */
export const checkQuestionEdit = (before: ReadonlyArray<Part>, after: ReadonlyArray<Part>): void => {
  const questions = (parts: ReadonlyArray<Part>) => parts.flatMap((part, index) => (isQuestion(part) ? [{ index, question: part }] : []))
  const old = questions(before)
  const next = questions(after)
  if (old.length !== next.length) fail("invalid_parts")
  old.forEach((entry, position) => {
    const was = normal(entry.question)
    const now = next[position]!
    const sameContent = same({ ...was, state: { kind: "pending" } }, { ...now.question, state: { kind: "pending" } })
    const stateOk = same(was.state, now.question.state) || (was.state.kind === "pending" && now.question.state.kind === "cancelled")
    if (entry.index !== now.index || !sameContent || !stateOk) fail("invalid_parts")
  })
}

/**
 * Commits a person's answer into `part`: it must be pending and the answer
 * complete and valid; the owner stamps the respondent from `actor` (Rust
 * `question::answer`). Returns the answered part.
 */
export const answerQuestion = (part: QuestionPart, answer: unknown, actor: Participant, now: string): QuestionPart => {
  if (actor.kind !== "human") return fail("human_only")
  const question = normal(part)
  if (question.state.kind !== "pending") return fail("question_closed")
  let requested: Record<string, QuestionSelection>
  try {
    requested = parseSelections(object(answer).selections)
  } catch (error) {
    if (error instanceof Malformed) return fail("invalid_answer")
    throw error
  }
  const known = new Set(question.items.map((item) => item.id))
  if (Object.keys(requested).some((key) => !known.has(key))) fail("invalid_answer")
  const selections: Record<string, QuestionSelection> = {}
  for (const item of question.items) {
    const selection = Object.hasOwn(requested, item.id) ? requested[item.id]! : { option_ids: [] }
    const trimmed = selection.other === undefined ? undefined : rustTrim(selection.other)
    const other = trimmed === undefined || trimmed.length === 0 ? undefined : trimmed
    const chosen = new Set(selection.option_ids)
    const valid =
      (chosen.size > 0 || other !== undefined) &&
      chosen.size === selection.option_ids.length &&
      [...chosen].every((id) => item.options.some((option) => option.id === id)) &&
      (other === undefined || (item.allows_other && bytes(other) <= MAX_QUESTION_TEXT_BYTES)) &&
      (item.multi_select || chosen.size + (other === undefined ? 0 : 1) === 1)
    if (!valid) fail("invalid_answer")
    // Option order follows the item, not the request.
    const optionIds = item.options.filter((option) => chosen.has(option.id)).map((option) => option.id)
    selections[item.id] = { option_ids: optionIds, ...(other === undefined ? {} : { other }) }
  }
  const respondent: Respondent =
    actor.person !== undefined
      ? { participant: actor.person, display_name: actor.display_name, device: actor.display_name, remote: true }
      : { participant: actor.id, display_name: actor.display_name, remote: false }
  const sorted = Object.fromEntries(Object.keys(selections).sort(byCodePoint).map((key) => [key, selections[key]!]))
  return { ...question, state: { kind: "answered", answer: { selections: sorted, respondent, answered_at: now } } }
}

/** Search text of a question: its first item's prompt (Rust `message_text`). */
export const questionText = (part: QuestionPart): string | undefined => part.items[0]?.prompt
