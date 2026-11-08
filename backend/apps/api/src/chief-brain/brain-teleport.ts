import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Env } from "../env.ts"
import { effectRefusal } from "./effect-policy.ts"
import { TELEPORT_DESCRIPTION } from "./prompts.ts"
import { destinationError } from "../teleport-destination.ts"

/**
 * A Cloud Chief's move request (Chief teleport). The Cloud Chief cannot reach the person's Mac, so it leaves
 * the request in its settings object's config (`teleport`, GET /v1/chiefs/<agent>/brain value.config.teleport);
 * a watcher on the person's Mac reads it and runs `optchat-chief move` after the turn. The owner sets or clears
 * it with PUT /v1/chiefs/<agent>/brain {teleport}; the Chief sets it with its `teleport` tool.
 *
 * - to: "home" (the Mac the Chief came from), "ssh:<host>[:<dir>]" or "local:<absolute dir>"; at most 256
 *   characters, no control characters. The host starts with a letter or digit (never an ssh option).
 * - id: 1 to 64 of A-Z a-z 0-9 _ - (the Mac acts on each id once).
 * - at: when it was asked, an ISO 8601 time.
 */
export interface Teleport {
  readonly to: string
  readonly id: string
  readonly at: string
}

/** The cb_config row of the settings object that holds the request (JSON), absent when there is none. */
export const TELEPORT_KEY = "teleport"

/** The grammar is shared with automation teleport (teleport-destination.ts). */
export { destinationError } from "../teleport-destination.ts"

/** The first problem of a `teleport` patch value (a request or null), or null. */
export const teleportError = (v: unknown): string | null => {
  if (v === null) return null
  if (typeof v !== "object" || Array.isArray(v)) return "teleport must be {to, id, at} or null"
  const t = v as Record<string, unknown>
  if (Object.keys(t).some((k) => k !== "to" && k !== "id" && k !== "at")) return "teleport has only to, id and at"
  const bad = destinationError(t.to)
  if (bad) return `teleport.${bad}`
  if (typeof t.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(t.id)) return "teleport.id must be 1 to 64 of A-Z a-z 0-9 _ -"
  if (typeof t.at !== "string" || t.at.length > 64 || !/^\d{4}-\d{2}-\d{2}T/.test(t.at) || Number.isNaN(Date.parse(t.at))) return "teleport.at must be an ISO 8601 time"
  return null
}

/** The stored request, or null (none, or a row this code cannot read). */
export const readTeleport = (sql: SqlStorage): Teleport | null => {
  const raw = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, TELEPORT_KEY).toArray()[0]?.value
  if (raw === undefined) return null
  try {
    const t = JSON.parse(raw) as unknown
    return teleportError(t) === null && t !== null ? (t as Teleport) : null
  } catch {
    return null
  }
}

/** Stores a checked request (teleportError is null), or deletes it for null. */
export const writeTeleport = (sql: SqlStorage, t: Teleport | null): void => {
  if (t === null) return void sql.exec(`DELETE FROM cb_config WHERE name = ?`, TELEPORT_KEY)
  sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, TELEPORT_KEY, JSON.stringify({ to: t.to, id: t.id, at: t.at }))
}

const Args = Type.Object({ to: Type.String({ description: 'home, or ssh:HOST (a Mac mini the person names).' }) })

type Settings = { configure(agent: string, owner: string, patch: Record<string, unknown>): Promise<{ ok: true } | { ok: false; code: string; message: string }> }

/** The `teleport` tool, for a brain whose `who()` names its chief and owner (null: not bound yet). */
export const teleportTools = (env: Env, who: () => { agent: string | null; owner: string | null }, effectsAuthorized: () => boolean = () => true): [ToolRegistration<typeof Args>] => [
  {
    name: "teleport",
    description: TELEPORT_DESCRIPTION,
    parameters: Args,
    replay: "unsafe",
    execute: async ({ to }) => {
      if (!effectsAuthorized()) return effectRefusal()
      const text = await (async () => {
        const { agent, owner } = who()
        if (!agent || !owner) return "teleport: this brain has no chief yet"
        const bad = destinationError(typeof to === "string" ? to.trim() : to)
        if (bad) return `teleport: ${bad}`
        const request: Teleport = { to: to.trim(), id: `tp_${crypto.randomUUID().replaceAll("-", "")}`, at: new Date().toISOString() }
        // The same mutation path as the owner's PUT (configure), on the Chief's settings object (name = agent).
        const settings = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as Settings
        const r = await settings.configure(agent, owner, { teleport: request })
        if (!r.ok) return `teleport: not saved (${r.code}): ${r.message}`
        return `Move requested (${request.to}). The person's Mac will move you after this turn ends; your memory and this conversation go with you. Say goodbye now, in one short line.`
      })().catch((e: unknown) => `teleport: ${e instanceof Error ? e.message : String(e)}`)
      return { content: [{ type: "text", text }] }
    }
  }
]
