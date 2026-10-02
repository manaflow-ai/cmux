import { validContactId, validParticipantId } from "./ids.ts"
import { fail } from "./reject.ts"
import {
  MAX_DISPLAY_NAME_CHARS,
  MAX_EMOJI_BYTES,
  MAX_PARTS,
  MAX_PREVIEW_BYTES,
  MAX_TEXT_BYTES,
  MAX_TEXT_RUNS,
  MAX_TITLE_CHARS,
  TAPBACKS,
  type AgentClass,
  type ConversationHead,
  type Part,
  type Participant,
  type ReactionKind,
  type Tapback,
  type TextRun,
  type WorkStatus
} from "./types.ts"

/** Rust `char::is_control` (general category Cc). */
const CONTROL = /\p{Cc}/u
/** Rust `char::is_whitespace` (the White_Space property). */
const WHITESPACE = /\p{White_Space}/u

/** Unicode scalar values, as Rust `chars().count()`. */
export const charCount = (text: string): number => [...text].length
/** UTF-8 length, as Rust `str::len()`. */
export const utf8Bytes = (text: string): number => Buffer.byteLength(text, "utf8")

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)
const isString = (value: unknown): value is string => typeof value === "string"
const isU32 = (value: unknown): value is number => Number.isInteger(value) && (value as number) >= 0 && (value as number) <= 0xffff_ffff

export const validateTitle = (title: unknown): void => {
  if (!isString(title)) return fail("invalid_title")
  const count = charCount(title)
  if (count === 0 || count > MAX_TITLE_CHARS || CONTROL.test(title)) fail("invalid_title")
}

const validDisplayName = (name: unknown): boolean => {
  if (!isString(name)) return false
  const count = charCount(name)
  return count > 0 && count <= MAX_DISPLAY_NAME_CHARS && !CONTROL.test(name)
}

const validAscii = (value: unknown, max: number): boolean => {
  if (!isString(value) || value.length === 0 || value.length > max) return false
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (code < 0x21 || code > 0x7e) return false
  }
  return true
}

/**
 * The Rust participant rule. `cloud` also admits contacts (`contact_<26>`, no
 * agent fields) and checks the cloud-only fields' types.
 */
export const validateParticipant = (participant: unknown, cloud: boolean): Participant => {
  if (!isObject(participant) || !isString(participant.id)) return fail("invalid_participant")
  const { id, kind, agent_class, acp_session } = participant
  let prefixMatches: boolean
  if (kind === "human") prefixMatches = id.startsWith("user_") && agent_class === undefined && validParticipantId(id)
  else if (kind === "agent") prefixMatches = id.startsWith("agent_") && validParticipantId(id)
  else if (kind === "contact" && cloud) prefixMatches = validContactId(id) && agent_class === undefined && acp_session === undefined
  else prefixMatches = false
  const classOk = agent_class === undefined || agent_class === "mux" || agent_class === "agent"
  const sessionOk = acp_session === undefined || validAscii(acp_session, 256)
  // A local head has no `owner_user`: Rust's serde drops it, so it is dropped here too.
  const ownerOk =
    participant.owner_user === undefined || !cloud || (kind === "agent" && isString(participant.owner_user) && validParticipantId(participant.owner_user))
  if (!prefixMatches || !classOk || !sessionOk || !ownerOk || !validDisplayName(participant.display_name)) fail("invalid_participant")
  return {
    id,
    kind: kind as Participant["kind"],
    display_name: participant.display_name as string,
    ...(agent_class === undefined ? {} : { agent_class: agent_class as AgentClass }),
    ...(acp_session === undefined ? {} : { acp_session: acp_session as string }),
    ...(participant.owner_user === undefined || !cloud ? {} : { owner_user: participant.owner_user as string })
  }
}

/** Validates a reaction kind and returns it without other fields. */
export const validateReaction = (reaction: unknown): ReactionKind => {
  if (!isObject(reaction)) return fail("invalid_reaction")
  const keys = Object.keys(reaction)
  if (keys.length !== 1) return fail("invalid_reaction")
  if ("tapback" in reaction) {
    if (!TAPBACKS.includes(reaction.tapback as never)) fail("invalid_reaction")
  } else if ("emoji" in reaction) {
    const emoji = reaction.emoji
    if (!isString(emoji) || emoji.length === 0 || utf8Bytes(emoji) > MAX_EMOJI_BYTES || CONTROL.test(emoji) || WHITESPACE.test(emoji)) {
      fail("invalid_reaction")
    }
  } else {
    fail("invalid_reaction")
  }
  return "tapback" in reaction ? { tapback: reaction.tapback as Tapback } : { emoji: reaction.emoji as string }
}

/** Equality of reaction kinds; a malformed `b` equals nothing. */
export const reactionEquals = (a: ReactionKind, b: unknown): boolean => {
  if (!isObject(b)) return false
  return "tapback" in a ? b.tapback === a.tapback && !("emoji" in b) : b.emoji === a.emoji && !("tapback" in b)
}

const validShortText = (value: unknown, maxBytes: number): boolean =>
  isString(value) && value.length > 0 && utf8Bytes(value) <= maxBytes && !CONTROL.test(value)

/**
 * Validates parts and returns them with only the known fields, as a serde
 * round trip in the Rust crate would.
 */
export const validateParts = (parts: unknown): ReadonlyArray<Part> => {
  if (!Array.isArray(parts) || parts.length === 0 || parts.length > MAX_PARTS) return fail("invalid_parts")
  let textBytes = 0
  const out: Array<Part> = []
  for (const part of parts as Array<unknown>) {
    if (!isObject(part)) return fail("invalid_parts")
    if (part.type === "text") {
      const { text, runs } = part
      if (!isString(text) || text.length === 0) return fail("invalid_parts")
      textBytes += utf8Bytes(text)
      if (textBytes > MAX_TEXT_BYTES) fail("invalid_parts")
      if (runs === undefined) {
        out.push({ type: "text", text })
        continue
      }
      if (!Array.isArray(runs) || runs.length > MAX_TEXT_RUNS) return fail("invalid_parts")
      const cleanRuns: Array<TextRun> = []
      for (const run of runs as Array<unknown>) {
        if (!isObject(run) || !isU32(run.start) || !isU32(run.length)) return fail("invalid_parts")
        const mentionOk = run.mention === undefined || (isString(run.mention) && validParticipantId(run.mention))
        const linkOk = run.link === undefined || validShortText(run.link, 2048)
        if (run.length === 0 || run.start + run.length > text.length || !mentionOk || !linkOk) fail("invalid_parts")
        cleanRuns.push({
          start: run.start,
          length: run.length,
          ...(run.mention === undefined ? {} : { mention: run.mention as string }),
          ...(run.link === undefined ? {} : { link: run.link as string })
        })
      }
      out.push({ type: "text", text, runs: cleanRuns })
    } else if (part.type === "work") {
      const statusOk = part.status === "running" || part.status === "done" || part.status === "failed" || part.status === "waiting"
      const valid =
        statusOk &&
        validShortText(part.session, 256) &&
        (part.host === undefined || validShortText(part.host, 256)) &&
        (part.preview === undefined || (isString(part.preview) && utf8Bytes(part.preview) <= MAX_PREVIEW_BYTES))
      if (!valid) fail("invalid_parts")
      out.push({
        type: "work",
        session: part.session as string,
        ...(part.host === undefined ? {} : { host: part.host as string }),
        status: part.status as WorkStatus,
        ...(part.preview === undefined ? {} : { preview: part.preview as string })
      })
    } else {
      fail("invalid_parts")
    }
  }
  return out
}

/** Any participant record with this id, current or departed. */
export const findParticipant = (head: ConversationHead, id: string): Participant | undefined =>
  head.participants.find((participant) => participant.id === id)

/** A participant who has not left. */
export const currentParticipant = (head: ConversationHead, id: string): Participant | undefined => {
  const participant = findParticipant(head, id)
  return participant && participant.left_at === undefined ? participant : undefined
}

export const currentParticipants = (head: ConversationHead): ReadonlyArray<Participant> =>
  head.participants.filter((participant) => participant.left_at === undefined)

export const hasText = (parts: ReadonlyArray<Part>): boolean => parts.some((part) => part.type === "text")
