import { homeConversationOps } from "./ops-home-conversation.ts"
import { homeInboxOps, homeInternalOps } from "./ops-home-inbox.ts"

/**
 * Home messaging ops (plans/cmux-next/home-messaging.md section 4). Schemas: ops-home-schemas.ts.
 * `homeOps` are public (catalog, HTTP, MCP per op); `homeInternalOps` are system ops a Durable
 * Object or the Worker builds itself, never exported to the catalog.
 */
export const homeOps = [...homeConversationOps, ...homeInboxOps] as const
export { homeInternalOps }
