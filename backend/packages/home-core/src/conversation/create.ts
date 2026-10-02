import { dmConversationId } from "./ids.ts"
import { fail, reject, RejectError, type ConversationReject } from "./reject.ts"
import { validateSettings } from "./settings.ts"
import {
  DEFAULT_SETTINGS,
  MAX_PARTICIPANTS,
  OWNER_CLOUD,
  OWNER_LOCAL,
  type ConversationHead,
  type ConversationKind,
  type ConversationSettings,
  type Message,
  type Participant,
  type PublicInvite,
  type Summary
} from "./types.ts"
import { currentParticipant, validateParticipant, validateTitle } from "./validate.ts"

/** A new conversation. Without `kind` it is a local conversation (the Rust `CreateRequest`). */
export interface CreateRequest {
  /** The owner-assigned conversation id. */
  readonly id: string
  readonly actor: string
  readonly title: string
  readonly participants: ReadonlyArray<Participant>
  /** RFC 3339 UTC with milliseconds. */
  readonly now: string
  // Cloud extensions.
  readonly kind?: ConversationKind
  readonly team?: string
  readonly settings?: Partial<ConversationSettings>
  readonly retention_days?: number
}

export type CreateResult = { readonly ok: true; readonly head: ConversationHead } | ConversationReject

/** Validates a new conversation and returns its head at `rev` 1. */
export const create = (request: CreateRequest): CreateResult => {
  try {
    return { ok: true, head: createOrThrow(request) }
  } catch (error) {
    if (error instanceof RejectError) return reject(error.code)
    throw error
  }
}

const createOrThrow = (request: CreateRequest): ConversationHead => {
  const cloud = request.kind !== undefined
  // Cloud dms and groups may start untitled; clients show participant names.
  if (!(cloud && request.title === "")) validateTitle(request.title)
  const input = request.participants
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_PARTICIPANTS) return fail("invalid_participant")
  const participants: Array<Participant> = []
  for (const raw of input) {
    const participant = validateParticipant(raw, cloud)
    if (participants.some((earlier) => earlier.id === participant.id)) fail("duplicate_participant")
    participants.push(participant)
  }
  const actor = participants.find((participant) => participant.id === request.actor)
  if (!actor) return fail("not_participant")
  const base: ConversationHead = {
    id: request.id,
    title: request.title,
    participants,
    last_seq: 0,
    rev: 1,
    created_at: request.now,
    updated_at: request.now,
    read_cursors: {}
  }
  if (!cloud) return base
  if (actor.kind === "contact") fail("contact_cannot_act")
  validateKindShape(request, participants)
  const settings = request.settings === undefined ? DEFAULT_SETTINGS : validateSettings(DEFAULT_SETTINGS, request.settings, false)
  if (request.retention_days !== undefined && (!Number.isInteger(request.retention_days) || request.retention_days < 30)) fail("invalid_settings")
  return {
    ...base,
    participants: participants.map((participant) => ({
      ...participant,
      role: participant.id === request.actor ? "owner" : "member",
      joined_seq: 0,
      added_by: request.actor
    })),
    kind: request.kind,
    ...(request.team === undefined ? {} : { team: request.team }),
    created_by: request.actor,
    state: "active",
    settings,
    invites: [],
    agent_text_streak: 0,
    ...(request.retention_days === undefined ? {} : { retention_days: request.retention_days })
  }
}

/**
 * dm: exactly two humans (one may be a contact, invited in the next op) with
 * the deterministic id. chief: the owner and one chief. group: humans and
 * agents; contacts join through `invite.create`.
 */
const validateKindShape = (request: CreateRequest, participants: ReadonlyArray<Participant>): void => {
  const kinds = participants.map((participant) => participant.kind)
  switch (request.kind) {
    case "dm": {
      const [a, b] = participants
      if (!a || !b || participants.length !== 2 || kinds.includes("agent") || kinds.every((kind) => kind === "contact")) fail("invalid_participant")
      if (request.id !== dmConversationId(a!.id, b!.id)) fail("invalid_conversation_id")
      return
    }
    case "chief": {
      const chief = participants.find((participant) => participant.kind === "agent")
      const owner = participants.find((participant) => participant.id === request.actor)
      if (participants.length !== 2 || owner?.kind !== "human" || chief?.agent_class !== "mux") fail("invalid_participant")
      return
    }
    case "group":
      if (kinds.includes("contact")) fail("invalid_participant")
      return
    default:
      fail("invalid_participant")
  }
}

const publicInvites = (head: ConversationHead): ReadonlyArray<PublicInvite> | undefined =>
  head.invites?.map(({ token_hash: _hidden, ...rest }) => rest)

/** The wire summary of a conversation. Cloud summaries never carry invite token hashes. */
export const summary = (head: ConversationHead, lastMessage: Message | null | undefined): Summary => {
  const cloud = head.kind !== undefined
  const out: Summary = {
    id: head.id,
    owner: cloud ? OWNER_CLOUD : OWNER_LOCAL,
    title: head.title,
    participants: head.participants,
    last_seq: head.last_seq,
    rev: head.rev,
    created_at: head.created_at,
    updated_at: head.updated_at,
    ...(lastMessage ? { last_message: lastMessage } : {}),
    read_cursors: head.read_cursors
  }
  if (!cloud) return out
  const invites = publicInvites(head)
  return {
    ...out,
    kind: head.kind,
    ...(head.team === undefined ? {} : { team: head.team }),
    ...(head.created_by === undefined ? {} : { created_by: head.created_by }),
    ...(head.state === undefined ? {} : { state: head.state }),
    ...(head.settings === undefined ? {} : { settings: head.settings }),
    ...(invites === undefined ? {} : { invites }),
    ...(head.retention_days === undefined ? {} : { retention_days: head.retention_days })
  }
}

/** A typing indicator is accepted only from a current, non-contact participant. */
export const checkTyping = (head: ConversationHead, actor: string): ConversationReject | null => {
  const participant = currentParticipant(head, actor)
  if (!participant) return reject("not_participant")
  return participant.kind === "contact" ? reject("contact_cannot_act") : null
}
