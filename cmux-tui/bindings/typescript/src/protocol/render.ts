import type { ColorHex, Id, Size } from "./common.js";

/** Exact underline style for a terminal render run. */
export type RenderUnderline = "single" | "double" | "curly" | "dotted" | "dashed";

/** One maximally coalesced span of styled terminal cells. */
export interface RenderRun {
  text: string;
  fg: ColorHex | null;
  bg: ColorHex | null;
  attrs: number;
  underline?: RenderUnderline;
  width_hint?: number;
}

/** One zero-based row in a viewport or scrollback page. */
export interface RenderRow {
  row: number;
  runs: RenderRun[];
}

/** Authoritative terminal cursor state for a render frame. */
export interface RenderCursor {
  x: number;
  y: number;
  style: "block" | "underline" | "bar";
  blink: boolean;
  visible: boolean;
  color: ColorHex | null;
}

/** Initial complete viewport snapshot for a render attachment. */
export interface RenderStateEvent {
  event: "render-state";
  surface: Id;
  size: Size;
  cursor: RenderCursor;
  default_fg: ColorHex;
  default_bg: ColorHex;
  scrollback_rows: number;
  rows: RenderRow[];
}

/** One render frame containing dirty rows or a full viewport replacement. */
export interface RenderDeltaEvent {
  event: "render-delta";
  surface: Id;
  cursor: RenderCursor;
  full: boolean;
  size?: Size;
  default_fg?: ColorHex;
  default_bg?: ColorHex;
  scrollback_rows?: number;
  rows: RenderRow[];
}
