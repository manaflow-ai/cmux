import { summary } from "./create.ts"
import type { OutboxItem } from "./engine-types.ts"
import { fanOut, type FanOut, type UnreadCounts } from "./fanout.ts"
import type { Commit, OpRequest } from "./request.ts"
import type { ConversationHead, Invite, Participant } from "./types.ts"

/**
 * Outbox items of one ConversationDO commit (home-messaging.md sections 5
 * and 7): DO-to-DO items carry a `target` (drained by RPC, at least once,
 * idempotent at the target by `entity`), projection rows have none. No
 * projection carries a raw address, a secret or a token hash.
 */

export const conversationProjection = (head: ConversationHead, lastAt: string) => ({
  id: head.id,
  kind: head.kind ?? "group",
  team_id: head.team ?? null,
  title: head.title,
  created_by: head.created_by ?? null,
  created_at: head.created_at,
  last_seq: head.last_seq,
  last_at: lastAt,
  participant_count: head.participants.filter((participant) => participant.left_at === undefined).length,
  state: head.state ?? "active"
})

const participantProjection = (head: ConversationHead, participant: Participant, now: string, added: boolean) => ({
  conversation_id: head.id,
  participant_id: participant.id,
  kind: participant.kind,
  visible_from_seq: head.settings?.history_visible === "since_join" ? (participant.joined_seq ?? 0) : 0,
  // Only a new or rejoined record carries `joined_at`; the drain keeps the stored one otherwise.
  ...(added ? { joined_at: now } : {}),
  left_at: participant.left_at ?? null
})

export const inviteProjection = (conversation: string, invite: Invite) => ({
  id: invite.id,
  conversation_id: conversation,
  invited_by: invite.invited_by,
  address_id: invite.address,
  channel: invite.channel,
  status: invite.status,
  delivery_state: invite.delivery.state,
  copy_variant: invite.copy_variant,
  created_at: invite.created_at,
  expires_at: invite.expires_at,
  accepted_by: invite.accepted_by ?? null,
  accepted_at: invite.accepted_at ?? null
})

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

/** DO-to-DO items from a fan-out intent. */
export const fanOutItems = (fan: FanOut, inviterName: string | undefined, kind: ConversationHead["kind"]): Array<OutboxItem> => {
  const items: Array<OutboxItem> = []
  for (const bump of fan.bumps) {
    const user = bump.user
    items.push({
      kind: "inbox.bump",
      entity: `bump:${bump.conversation}:${bump.rev}`,
      // `user` binds the UserDO inbox to its owner on the first bump (inbox/domain.ts).
      payload: bump,
      target: { class: "UserDO", name: user, coalesce: `bump:${bump.conversation}` }
    })
  }
  for (const wake of fan.wakes) {
    items.push({
      kind: "mux.wake",
      entity: `wake:${wake.conversation}:${wake.seq}`,
      payload: { conversation: wake.conversation, seq: wake.seq, reason: wake.reason },
      target: { class: "MuxDO", name: wake.agent }
    })
  }
  for (const delivery of fan.deliveries) {
    items.push({
      kind: "address.deliver",
      entity: `deliver:${delivery.invite}`,
      // No secret here: the link secret reaches AddressDO another way (see the lane report).
      payload: { ...delivery, conversation_kind: kind ?? "group", ...(inviterName ? { inviter_name: inviterName } : {}) },
      target: { class: "AddressDO", name: delivery.address }
    })
  }
  return items
}

/** Postgres projection rows for the changes between `before` and the committed head. */
export const projectionItems = (before: ConversationHead | null, commit: Commit, fan: FanOut, now: string, lastAt: string): Array<OutboxItem> => {
  const head = commit.head
  const items: Array<OutboxItem> = []
  const metaChanged =
    !before ||
    before.last_seq !== head.last_seq ||
    before.title !== head.title ||
    before.state !== head.state ||
    !same(before.participants, head.participants)
  if (metaChanged) items.push({ kind: "home.conversation.upsert", entity: head.id, payload: conversationProjection(head, lastAt) })
  const visibilityChanged = before?.settings?.history_visible !== head.settings?.history_visible
  for (const participant of head.participants) {
    const old = before?.participants.find((candidate) => candidate.id === participant.id)
    if (old && same(old, participant) && !visibilityChanged) continue
    const added = !old || (old.left_at !== undefined && participant.left_at === undefined) || old.kind !== participant.kind
    items.push({
      kind: "home.participant.upsert",
      entity: `${head.id}:${participant.id}`,
      payload: participantProjection(head, participant, now, added)
    })
  }
  // A address dropped from the head (outside a dm) leaves in the projection.
  for (const old of before?.participants ?? []) {
    if (head.participants.some((participant) => participant.id === old.id)) continue
    items.push({
      kind: "home.participant.upsert",
      entity: `${head.id}:${old.id}`,
      payload: { ...participantProjection(head, old, now, false), left_at: old.left_at ?? now }
    })
  }
  for (const invite of head.invites ?? []) {
    const old = before?.invites?.find((candidate) => candidate.id === invite.id)
    if (old && same(old, invite)) continue
    items.push({ kind: "home.invite.upsert", entity: invite.id, payload: inviteProjection(head.id, invite) })
  }
  for (const intent of fan.search) {
    if (intent.op === "upsert") items.push({ kind: "home.message.upsert", entity: `${intent.row.conversation_id}:${intent.row.seq}`, payload: intent.row })
    else items.push({ kind: "home.message.delete", entity: `${intent.conversation_id}:${intent.seq}`, payload: { conversation_id: intent.conversation_id, seq: intent.seq } })
  }
  return items
}

/** Every outbox item of one commit: fan-out first, then projections. */
export const commitOutbox = (before: ConversationHead, request: OpRequest, commit: Commit, counts?: Readonly<Record<string, UnreadCounts>>): Array<OutboxItem> => {
  const fan = fanOut({ before, request, commit, ...(counts ? { counts } : {}) })
  const lastAt = fan.bumps[0]?.last_at ?? lastAtOf(commit, request)
  const inviter = commit.head.participants.find((participant) => participant.id === request.actor)?.display_name
  return [...fanOutItems(fan, inviter, commit.head.kind), ...projectionItems(before, commit, fan, request.now, lastAt)]
}

/** Outbox of a new conversation: a bump for every human and the projection rows. */
export const createOutbox = (head: ConversationHead): Array<OutboxItem> => {
  const fan: FanOut = {
    bumps: head.participants
      .filter((participant) => participant.kind === "human")
      .map((participant) => ({
        user: participant.id,
        conversation: head.id,
        rev: head.rev,
        kind: head.kind ?? "group",
        title: head.title,
        last_seq: 0,
        last_at: head.created_at,
        preview: "",
        unread: 0,
        mentions: 0,
        ...(head.kind === "dm" ? { dm_peer: head.participants.find((other) => other.id !== participant.id)?.id ?? participant.id } : {})
      })),
    wakes: [],
    search: [],
    deliveries: []
  }
  const commit: Commit = { head, change: { kind: "conversation", conversation: summary(head, null) } }
  return [...fanOutItems(fan, undefined, head.kind), ...projectionItems(null, commit, fan, head.created_at, head.created_at)]
}

const lastAtOf = (commit: Commit, request: OpRequest): string => {
  const head = commit.head
  if (commit.message && commit.message.seq === head.last_seq) return commit.message.created_at
  if (request.last_message && request.last_message.seq === head.last_seq) return request.last_message.created_at
  return head.created_at
}
