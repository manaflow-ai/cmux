import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { TeamId, UserId } from "./schemas.ts"

/**
 * Team shared agent keys (Cloud multiplayer, contract C4). An owner or admin stores one key per
 * agent for the whole team; Cloud machines of the team's members use it instead of each member's
 * own key (coderouter route resolution, contract C2). The secret travels only in the
 * `team.agent_key.set` request: TeamDO seals it into a side table (integrations/credentials.ts,
 * KMS when configured, else INTEGRATIONS_KEK) and no op param, event, snapshot, ledger row or read
 * ever holds it. `team.agent_key.status` answers whether a key is set, never the key.
 */
export const TeamAgentKeyAgent = Schema.Literals(["claude", "codex"]).annotate({ identifier: "TeamAgentKeyAgent" })
/** `api_key`: a provider API key. `oauth`: a subscription token (a long-lived setup token, or a sign-in file). */
export const TeamAgentKeyKind = Schema.Literals(["api_key", "oauth"]).annotate({ identifier: "TeamAgentKeyKind" })

/** The longest secret accepted: a sign-in file with its refresh token fits well inside. */
export const TEAM_AGENT_KEY_MAX_BYTES = 16 * 1024

/** One agent's shared key as anyone may see it: whether it is set, by whom and when; `hint` (its last four characters) only for owners and admins. */
export const TeamAgentKeyState = Schema.Struct({
  agent: TeamAgentKeyAgent,
  set: Schema.Boolean,
  kind: Schema.NullOr(TeamAgentKeyKind),
  /** Bumped by every set; a removal keeps it. */
  generation: Schema.Int,
  updated_at: Schema.NullOr(Schema.Int),
  updated_by: Schema.NullOr(UserId),
  hint: Schema.NullOr(Schema.String)
}).annotate({ identifier: "TeamAgentKeyState" })

export const TeamAgentKeySet = def({
  name: "team.agent_key.set",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    agent: TeamAgentKeyAgent,
    kind: TeamAgentKeyKind,
    secret: Schema.String.check(Schema.isMinLength(8), Schema.isMaxLength(TEAM_AGENT_KEY_MAX_BYTES))
  }),
  result: TeamAgentKeyState,
  errors: [...mutationErrors, "team_agent_key.not_configured"],
  docs: "Add or replace the team's shared key for an agent (owners and admins, in a person's session). Cloud machines of the team use it instead of members' own keys. The key is never returned.",
  cli: { path: "team agent-key set", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const TeamAgentKeyRemove = def({
  name: "team.agent_key.remove",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ agent: TeamAgentKeyAgent }),
  result: Schema.Struct({ agent: TeamAgentKeyAgent, removed: Schema.Boolean }),
  errors: mutationErrors,
  docs: "Remove the team's shared key for an agent (owners and admins). Members' Cloud machines go back to their own keys.",
  cli: { path: "team agent-key remove", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const TeamAgentKeyStatus = def({
  name: "team.agent_key.status",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ team: Schema.optionalKey(TeamId) }),
  result: Schema.Struct({ team: TeamId, can_manage: Schema.Boolean, agents: Schema.Array(TeamAgentKeyState) }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Whether the team has a shared key for each agent (members). Never returns a key.",
  cli: { path: "team agent-key status", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const teamAgentKeyOps = [TeamAgentKeySet, TeamAgentKeyRemove, TeamAgentKeyStatus] as const

/** TeamDO's own audit record of a set, replace or removal (never the key). */
export const teamAgentKeyInternalOps: ReadonlyArray<CloudOpDef> = [
  {
    name: "team.agent_key.audit",
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-shared",
    target: "team",
    principals: ["system"],
    params: Schema.Struct({
      action: Schema.Literals(["set", "replaced", "removed"]),
      agent: TeamAgentKeyAgent,
      kind: Schema.optionalKey(TeamAgentKeyKind),
      generation: Schema.Int,
      by: Schema.String
    }),
    result: Schema.Unknown,
    errors: [],
    docs: "Internal: an owner or admin set, replaced or removed a team shared agent key; audit only.",
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  } as CloudOpDef
]
