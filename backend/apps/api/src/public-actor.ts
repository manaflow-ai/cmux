import type { Principal } from "@cmux/ownership"

/** Subscribers see public ids and the display name; never email, Stack ids or grants. */
export const publicActor = (p: Principal): Principal => ({
  identity: p.agent ? `agent:${p.agent}` : p.user ? `user:${p.user}` : p.identity,
  ...(p.kind ? { kind: p.kind } : {}),
  ...(p.user ? { user: p.user } : {}),
  ...(p.agent ? { agent: p.agent } : {}),
  ...(p.display_name ? { display_name: p.display_name } : {})
})
