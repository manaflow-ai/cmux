import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Memory } from "./memory.ts"
import { DATE_DESCRIPTION, ZOOM_DESCRIPTION } from "./prompts.ts"

/** The OptChat memory tools of a Chief turn (spec 7): zoom into a view line, and the date of a message. */
const ZoomArgs = Type.Object({
  id: Type.Integer({ description: "First message id of the line (the number before +)." }),
  n: Type.Integer({ description: "How many messages the line covers (the number after +); a power of 2." })
})
const DateArgs = Type.Object({ id: Type.Integer({ description: "A message id." }) })

export { handsTools } from "./brain-hands.ts"

export const memoryTools = (memory: () => Memory): [ToolRegistration<typeof ZoomArgs>, ToolRegistration<typeof DateArgs>] => [
  { name: "zoom", description: ZOOM_DESCRIPTION, parameters: ZoomArgs, replay: "safe", execute: async ({ id, n }) => ({ content: [{ type: "text", text: memory().zoom(id, n) }] }) },
  { name: "date", description: DATE_DESCRIPTION, parameters: DateArgs, replay: "safe", execute: async ({ id }) => ({ content: [{ type: "text", text: memory().date(id, "UTC") }] }) }
]
