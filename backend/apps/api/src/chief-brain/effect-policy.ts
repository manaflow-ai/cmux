/** A stable tool result for a turn that no owner-authored message authorized. */
export const OWNER_APPROVAL_REQUIRED = "owner approval required: ask the Chief owner to confirm this action in the conversation"

export const effectRefusal = () => ({ content: [{ type: "text" as const, text: OWNER_APPROVAL_REQUIRED }] })
