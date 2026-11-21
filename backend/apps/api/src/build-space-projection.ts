import type { OutboxRow } from "@cmux/ownership"
import { isDevSpace, parseBuildSpace, spacedName } from "./build-space.ts"
import type { BuildSpace } from "./env.ts"

/**
 * Build spaces in the Postgres projection (build-space.ts, migration 0008_build_space). A dev build's rows go to
 * Postgres with `space` set and every key written as `dev:<slug>|<id>`, the same scheme as its Durable Object names:
 * a dev build's deterministic ids (a DM's conversation id) never meet nightly's row, and no primary key changes (a
 * key change is a contract migration). Nightly and stable rows are untouched.
 *
 * Kinds of account-wide tables (users, teams, memberships, the team audit chain) are never projected from a dev
 * build: their one writer is the base space's object. A kind this list does not know is not projected from a dev
 * build either, so a new projected table stays out of dev spaces until it is classified here.
 *
 * Dev rows never go to the MySQL shadow: its keys are varchar(64) and it has no space column. The projection compares
 * read Postgres's base rows only (db/projection-compare.ts).
 */
export const SPACE_KEYED_KINDS: Readonly<Record<string, ReadonlyArray<string>>> = {
  "install.upsert": ["id"],
  "host.upsert": ["id"],
  "host.delete": ["id"],
  "automation.upsert": ["id"],
  "automation.delete": ["id"],
  "automation_run.upsert": ["id", "automation"],
  "connection.upsert": ["id"],
  "home.conversation.upsert": ["id"],
  "home.participant.upsert": ["conversation_id"],
  "home.invite.upsert": ["id", "conversation_id"],
  "home.message.upsert": ["conversation_id"],
  "home.message.delete": ["conversation_id"],
  "home.message.delete_through": ["conversation_id"]
}

/**
 * The space a row belongs to: its object's, or for a shared object's host rows (TeamDO's `host.*`) the space its
 * payload names. No other kind may name a space: a base row whose payload happens to carry `space` stays a base row.
 */
const rowSpace = (objectSpace: BuildSpace, row: OutboxRow): BuildSpace | null => {
  if (isDevSpace(objectSpace) || !row.kind.startsWith("host.")) return objectSpace
  const named = (row.payload as { space?: unknown } | null)?.space
  return named === undefined ? objectSpace : typeof named === "string" ? parseBuildSpace(named) : null
}

export interface SpacedRows {
  /** Nightly and stable rows, exactly as written. */
  readonly base: ReadonlyArray<OutboxRow>
  /** Dev build rows, keyed by their space (Postgres only). */
  readonly dev: ReadonlyArray<OutboxRow>
  /** Rows a dev build never projects (account-wide or unclassified kinds): done without a write. */
  readonly skipped: ReadonlyArray<number>
}

export const spaceRows = (objectSpace: BuildSpace, rows: ReadonlyArray<OutboxRow>): SpacedRows => {
  const base: Array<OutboxRow> = [], dev: Array<OutboxRow> = [], skipped: Array<number> = []
  for (const row of rows) {
    const space = rowSpace(objectSpace, row)
    if (space === "") {
      base.push(row)
      continue
    }
    const keys = SPACE_KEYED_KINDS[row.kind]
    if (space === null || !keys) {
      skipped.push(row.id)
      continue
    }
    const payload: Record<string, unknown> = { ...(row.payload as Record<string, unknown>), space }
    for (const k of keys) if (typeof payload[k] === "string") payload[k] = spacedName(space, payload[k] as string)
    dev.push({ ...row, payload })
  }
  return { base, dev, skipped }
}
