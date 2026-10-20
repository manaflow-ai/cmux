/** A stable tool result for a turn that no owner-authored message authorized. */
export const OWNER_APPROVAL_REQUIRED = "owner approval required: ask the Chief owner to confirm this action in the conversation"

export const effectRefusal = () => ({ content: [{ type: "text" as const, text: OWNER_APPROVAL_REQUIRED }] })

/** Whether every conversation message delivered to a turn came from its owner or the Chief itself. */
export const messagesEffectAuthorized = (
  messages: ReadonlyArray<{ author?: { id?: unknown; kind?: unknown } }>,
  owner: string
): boolean => messages.every((message) => message.author?.kind === "self" || message.author?.id === owner)
