/**
 * Shared by the Postgres/MySQL parity test and the copy/verify job (state-placement.md 4.5): the
 * projected tables, their keys, the columns that legitimately differ (defaults set by each server),
 * and one normalization so a row from either database compares equal when it holds the same facts.
 */
import { createHash } from "node:crypto"

export const PROJECTION_TABLES: Record<string, { readonly key: ReadonlyArray<string>; readonly skip: ReadonlyArray<string> }> = {
  users: { key: ["id"], skip: ["created_at", "updated_at"] },
  teams: { key: ["id"], skip: ["created_at", "updated_at"] },
  installs: { key: ["id"], skip: ["updated_at"] },
  memberships: { key: ["team_id", "user_id"], skip: ["updated_at"] },
  hosts: { key: ["id"], skip: ["updated_at", "deleted_at"] },
  automations: { key: ["id"], skip: ["deleted_at"] },
  automation_runs: { key: ["id"], skip: ["updated_at"] },
  connections: { key: ["id"], skip: [] },
  audit_events: { key: ["team_id", "n"], skip: ["created_at"] },
  home_conversations: { key: ["id"], skip: ["updated_at"] },
  home_participants: { key: ["conversation_id", "participant_id"], skip: ["updated_at"] },
  home_invites: { key: ["id"], skip: ["updated_at"] },
  home_message_search: { key: ["conversation_id", "seq"], skip: [] }
}

const sortKeys = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, sortKeys((v as Record<string, unknown>)[k])])) : v

/** One comparable value: times as epoch ms, JSON canonical, integers as numbers, booleans as 0/1. */
export const norm = (v: unknown): unknown => {
  if (v === null || v === undefined) return null
  if (v instanceof Date) return v.getTime()
  if (typeof v === "boolean") return v ? 1 : 0
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}/.test(v)) return Date.parse(v.includes("T") ? v : `${v.replace(" ", "T")}Z`)
  if (typeof v === "string" && /^-?\d+$/.test(v) && v.length < 16) return Number(v)
  if (typeof v === "object") return JSON.stringify(sortKeys(v))
  return v
}

/** A row's comparable shape over the given columns. */
export const shapeRow = (row: Record<string, unknown>, columns: ReadonlyArray<string>): Record<string, unknown> => Object.fromEntries(columns.map((c) => [c, norm(row[c])]))

/** sha256 of the canonical JSON of a shaped row. */
export const rowHash = (shaped: Record<string, unknown>): string => createHash("sha256").update(JSON.stringify(sortKeys(shaped))).digest("hex")

/** A MySQL datetime(3) literal (UTC) from a Date; other values unchanged; objects as JSON text. */
export const toMysqlValue = (v: unknown): unknown => {
  if (v instanceof Date) return v.toISOString().replace("T", " ").replace("Z", "")
  if (v !== null && typeof v === "object") return JSON.stringify(v)
  return v
}
