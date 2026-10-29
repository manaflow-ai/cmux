import { conversation } from "@cmux/home-core"

/** A stable tool result for a turn that no owner-authored message authorized. */
export const OWNER_APPROVAL_REQUIRED = "owner approval required: ask the Chief owner to confirm this action in the conversation"

export const effectRefusal = () => ({ content: [{ type: "text" as const, text: OWNER_APPROVAL_REQUIRED }] })

/** Whether every conversation message delivered to a turn came from its owner or the Chief itself. */
export const messagesEffectAuthorized = (
  messages: ReadonlyArray<{ author?: { id?: unknown; kind?: unknown } }>,
  owner: string
): boolean => messages.every((message) => message.author?.kind === "self" || message.author?.id === owner)

/**
 * Whether one new conversation message leaves this Chief's turn free to run effects (CHIEF-DONE B3:
 * full autonomy for the owner's own requests, the approval rule for anyone else's). The owner's
 * message does. Another member's message does not when it asks this Chief: it would wake this Chief
 * (a mention, a reply to its message, the one-to-one rule, or the group's `all` rule, home-core
 * `wakesFor`), or it replies to a message this view cannot see (counted as asking, to stay safe).
 * Another member's message to someone else (a teammate, another Chief) is context only: before, it
 * took the right away from the owner's own request in the same batch, so in a busy group the owner's
 * Chief refused its owner.
 */
export const messageEffectAuthorized = (
  head: conversation.ConversationHead,
  message: conversation.Message,
  view: ReadonlyArray<conversation.Message>,
  owner: string,
  agent: string
): boolean => {
  if (message.author === owner) return true
  const replyTo = message.reply_to?.message_id
  const target = replyTo === undefined ? undefined : view.find((m) => m.id === replyTo)
  if (replyTo !== undefined && target === undefined) return false
  return !conversation.wakesFor(head, message, target).some((w) => w.agent === agent)
}
