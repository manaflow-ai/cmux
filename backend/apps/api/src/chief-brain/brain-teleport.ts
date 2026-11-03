import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Env } from "../env.ts"

/** Placeholder: the `teleport` tool comes in the next commit. */
const Args = Type.Object({ to: Type.String() })

export const teleportTools = (_env: Env, _who: () => { agent: string | null; owner: string | null }, _effectsAuthorized: () => boolean = () => true): [ToolRegistration<typeof Args>] => [
  { name: "teleport", description: "", parameters: Args, replay: "unsafe", execute: async () => ({ content: [{ type: "text", text: "not implemented" }] }) }
]
