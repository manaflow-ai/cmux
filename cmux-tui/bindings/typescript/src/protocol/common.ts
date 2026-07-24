/** A JSON value accepted by the cmux-tui protocol. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/** A JSON object accepted by the cmux-tui protocol. */
export type JsonObject = { [key: string]: Json };

/** An implemented numeric protocol identifier (`uint64` on the wire). */
export type Id = number;

/** A numeric id or proposed stable short id. */
export type IdRef = Id | string;

/** Standard base64 text. */
export type Base64 = string;

/** A `#rrggbb` color string. */
export type ColorHex = `#${string}`;

/** A terminal cell grid. */
export interface Size {
  cols: number;
  rows: number;
}

/** The canonical empty command result. */
export type EmptyResult = Record<string, never>;

/** Fields common to every command request envelope. */
export interface CmuxRequestBase {
  id?: Json;
  cmd: string;
}

/** A successful command response envelope. */
export interface CmuxSuccessResponse<T = Json> {
  id?: Json;
  ok: true;
  data: T;
}

/** A failed command response envelope. */
export interface CmuxFailureResponse {
  id?: Json;
  ok: false;
  error: string;
}

/** The canonical command response envelope. */
export type CmuxResponse<T = Json> = CmuxSuccessResponse<T> | CmuxFailureResponse;

/** Split orientation used by canonical and declarative layouts. */
export type SplitDirection = "right" | "down";

/** Four-way pane navigation direction. */
export type PaneDirection = "left" | "right" | "up" | "down";

/** Notification severity. */
export type NotificationLevel = "info" | "warning" | "error";

/** An agent's reported lifecycle state. */
export type AgentState = "working" | "blocked" | "idle" | "done" | "unknown";

/** The authority that produced an agent record. */
export type AgentSource = "detected" | "socket" | "hook";

/** A source accepted by `report-agent`. */
export type AgentReportSource = "socket" | "hook";

/** One authoritative agent status record. */
export interface AgentRecord {
  surface: Id;
  state: AgentState;
  source: AgentSource;
  session: string | null;
  updated_at_ms: number;
}

/** One posted mux notification. */
export interface Notification {
  notification: Id;
  title: string;
  body: string;
  level: NotificationLevel;
  surface: Id | null;
}
