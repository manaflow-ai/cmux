import type { Base64, ColorHex, Id, Size } from "./common.js";

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

/** Decoded pixel format carried by a Kitty graphics image. */
export type RenderGraphicFormat = "rgb" | "rgba";

/** One authoritative Kitty image payload. */
export interface RenderGraphicImage {
  id: number;
  generation: number;
  width: number;
  height: number;
  format: RenderGraphicFormat;
  data: Base64;
}

/** One non-virtual Kitty placement resolved against the terminal viewport. */
export interface RenderGraphicPlacement {
  image_id: number;
  placement_id: number;
  ordinal: number;
  x_offset: number;
  y_offset: number;
  source_x: number;
  source_y: number;
  source_width: number;
  source_height: number;
  columns: number;
  rows: number;
  grid_cols: number;
  grid_rows: number;
  pixel_width: number;
  pixel_height: number;
  viewport_col: number;
  viewport_row: number;
  viewport_visible: boolean;
  z: number;
}

/**
 * Authoritative Kitty placements and optionally refreshed image pixels.
 *
 * `placements` always replaces the previous placement set. An omitted
 * `images` field preserves the previous image set.
 */
export interface RenderGraphics {
  generation: number;
  images?: RenderGraphicImage[];
  placements: RenderGraphicPlacement[];
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
  /** Omitted by servers predating render-mode Kitty graphics. */
  graphics?: RenderGraphics;
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
  /** Omitted by servers predating render-mode Kitty graphics. */
  graphics?: RenderGraphics;
}
