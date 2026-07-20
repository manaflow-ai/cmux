import type {
  AgentSource,
  AgentState,
  Base64,
  ColorHex,
  Id,
  NotificationLevel,
} from "./common.js";
import type { ClientTransport } from "./commands.js";
import type { RenderDeltaEvent, RenderStateEvent } from "./render.js";
import type { Pane, Screen, Tab, Workspace } from "./tree.js";

export interface TreeChangedEvent { event: "tree-changed" }
export interface LayoutChangedEvent { event: "layout-changed"; screen: Id }
export interface SurfaceOutputEvent { event: "surface-output"; surface: Id }

/** `offset` is the row offset used by the scrollbar geometry. */
export interface ScrollChangedEvent {
  event: "scroll-changed";
  surface: Id;
  offset: number;
  at_bottom: boolean;
}

export interface SurfaceResizedEvent { event: "surface-resized"; surface: Id; cols: number; rows: number; reservation_id?: number | null }
export interface SurfaceResizeFailedEvent {
  event: "surface-resize-failed";
  surface: Id;
  cols: number;
  rows: number;
  error: string;
  retry_after_ms: number | null;
  reservation_id?: number | null;
}
export interface SurfaceExitedEvent { event: "surface-exited"; surface: Id }
export interface TitleChangedEvent { event: "title-changed"; surface: Id; title?: string }
export interface BellEvent { event: "bell"; surface: Id }

export interface NotificationEvent {
  event: "notification";
  notification: Id;
  title: string;
  body: string;
  level: NotificationLevel;
  surface: Id | null;
}

export interface ConfigReloadRequestedEvent { event: "config-reload-requested" }
export interface WindowTitleRequestedEvent { event: "window-title-requested"; title: string }
export interface ClientAttachedEvent {
  event: "client-attached";
  client: Id;
  transport: ClientTransport;
  name: string | null;
  kind: string | null;
}
export interface ClientChangedEvent {
  event: "client-changed";
  client: Id;
  name: string | null;
  kind: string | null;
}
export interface ClientDetachedEvent { event: "client-detached"; client: Id }
export interface EmptyEvent { event: "empty" }

export interface WorkspaceAddedEvent {
  event: "workspace-added";
  workspace: Id;
  index: number;
  /** Absent when the server does not advertise `workspace-registry-v1`. */
  workspace_revision?: number;
  entity: Workspace;
}
export interface WorkspaceClosedEvent {
  event: "workspace-closed";
  workspace: Id;
  index: number;
  /** Absent when the server does not advertise `workspace-registry-v1`. */
  workspace_revision?: number;
  entity: Workspace;
}
export interface WorkspaceRenamedEvent {
  event: "workspace-renamed";
  workspace: Id;
  /** Absent when the server does not advertise `workspace-registry-v1`. */
  workspace_revision?: number;
  entity: Workspace;
}
export interface WorkspaceMovedEvent {
  event: "workspace-moved";
  workspace: Id;
  index: number;
  workspace_revision: number;
  entity: Workspace & { key: string };
}
export interface ScreenAddedEvent {
  event: "screen-added";
  workspace: Id;
  screen: Id;
  index: number;
  entity: Screen;
}
export interface ScreenClosedEvent {
  event: "screen-closed";
  workspace: Id;
  screen: Id;
  index: number;
  entity: Screen;
}
export interface ScreenRenamedEvent {
  event: "screen-renamed";
  workspace: Id;
  screen: Id;
  entity: Screen;
}
export interface PaneAddedEvent {
  event: "pane-added";
  workspace: Id;
  screen: Id;
  pane: Id;
  index: number;
  entity: Pane;
}
export interface PaneClosedEvent {
  event: "pane-closed";
  workspace: Id;
  screen: Id;
  pane: Id;
  index: number;
  entity: Pane;
}
export interface TabAddedEvent {
  event: "tab-added";
  workspace: Id;
  screen: Id;
  pane: Id;
  surface: Id;
  index: number;
  entity: Tab;
}
export interface TabClosedEvent {
  event: "tab-closed";
  workspace: Id;
  screen: Id;
  pane: Id;
  surface: Id;
  index: number;
  entity: Tab;
}
export interface TabRenamedEvent {
  event: "tab-renamed";
  workspace: Id;
  screen: Id;
  pane: Id;
  surface: Id;
  entity: Tab;
}

/** Protocol v7 tree lifecycle deltas. */
export type TreeDeltaEvent =
  | WorkspaceAddedEvent
  | WorkspaceClosedEvent
  | WorkspaceRenamedEvent
  | WorkspaceMovedEvent
  | ScreenAddedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | PaneAddedEvent
  | PaneClosedEvent
  | TabAddedEvent
  | TabClosedEvent
  | TabRenamedEvent;

/** Effective special colors for an attached terminal surface. */
export interface TerminalColors {
  fg: ColorHex | null;
  bg: ColorHex | null;
  cursor: ColorHex | null;
  selection_bg: ColorHex | null;
  selection_fg: ColorHex | null;
  /** Protocol v7 sparse OSC 4 overrides keyed by palette index. Older servers omit this field. */
  palette?: Record<string, ColorHex>;
  /** Protocol v6 additive extension. Older servers omit this field. */
  cursor_style?: "block" | "underline" | "bar" | null;
  /** Protocol v6 additive extension. Older servers omit this field. */
  cursor_blink?: boolean | null;
}

/** Initial base64 VT replay for an attached PTY surface. */
export interface VtStateEvent {
  event: "vt-state";
  surface: Id;
  cols: number;
  rows: number;
  data: Base64;
  /** Protocol v6 additive extension. Older servers omit this field. */
  colors?: TerminalColors;
}

/** Live base64 PTY bytes after the attach snapshot. */
export interface OutputEvent { event: "output"; surface: Id; data: Base64 }

interface ResizedEventBase {
  event: "resized";
  surface: Id;
  cols: number;
  rows: number;
  /** Protocol v7 fresh color snapshot for the replacement replay. Older servers omit it. */
  colors?: TerminalColors;
}

/** A replacement replay using the protocol-v7 field or protocol-v6 compatibility field. */
export type ResizedEvent = ResizedEventBase & (
  | { replay: Base64; data?: Base64 }
  | { data: Base64; replay?: Base64 }
);

export interface DetachedEvent { event: "detached"; surface: Id }

export interface OverflowEvent {
  event: "overflow";
  error: string;
  scope?: "surface";
  surface?: Id;
}

/** Updated effective special colors for this attach stream's surface. */
export interface ColorsChangedEvent extends TerminalColors {
  event: "colors-changed";
  /** Protocol v7 adds the subject id; protocol v6 servers omit it. */
  surface?: Id;
}

export interface BrowserFrame {
  seq: number;
  width: number;
  height: number;
  data: Base64;
}

export interface BrowserStateEvent {
  event: "browser-state";
  surface: Id;
  cols: number;
  rows: number;
  url: string;
  title: string;
  status: string;
  error: string | null;
  frames_stalled: boolean;
  frame?: BrowserFrame | null;
}

export interface BrowserFrameEvent extends BrowserFrame {
  event: "frame";
  surface: Id;
}

/** Proposed event retained for forward-compatible protocol v6 clients. */
export interface AgentStateChangedEvent {
  event: "agent-state-changed";
  surface: Id;
  previous: AgentState | null;
  state: AgentState;
  source: AgentSource;
  session: string | null;
  updated_at_ms: number;
}

/** Proposed notification event shape with its creation timestamp. */
export interface ProposedNotificationEvent extends NotificationEvent {
  created_at_ms: number;
}

/** A forward-compatible event that is not known to this SDK version. */
export interface UnknownEvent {
  event: string;
  [key: string]: unknown;
}

/** All currently implemented subscribe event payloads. */
export type KnownSubscribeEvent =
  | TreeDeltaEvent
  | TreeChangedEvent
  | LayoutChangedEvent
  | SurfaceOutputEvent
  | ScrollChangedEvent
  | SurfaceResizedEvent
  | SurfaceResizeFailedEvent
  | SurfaceExitedEvent
  | TitleChangedEvent
  | BellEvent
  | NotificationEvent
  | ConfigReloadRequestedEvent
  | WindowTitleRequestedEvent
  | ClientAttachedEvent
  | ClientChangedEvent
  | ClientDetachedEvent
  | EmptyEvent
  | OverflowEvent;

/** Subscribe events, including unknown future event names. */
export type SubscribeEvent = KnownSubscribeEvent | UnknownEvent;

/** All currently implemented attach event payloads. */
export type KnownAttachEvent =
  | VtStateEvent
  | OutputEvent
  | ResizedEvent
  | ColorsChangedEvent
  | BrowserStateEvent
  | BrowserFrameEvent
  | RenderStateEvent
  | RenderDeltaEvent
  | ScrollChangedEvent
  | DetachedEvent
  | OverflowEvent;

/** Wire-format attach events, including unknown future event names. */
export type AttachEvent = KnownAttachEvent | UnknownEvent;

/** Every known implemented subscribe or attach event. */
export type KnownCmuxEvent = KnownSubscribeEvent | KnownAttachEvent | AgentStateChangedEvent | ProposedNotificationEvent;

/** Every cmux event, discriminated by `event`, with an unknown-event fallback. */
export type CmuxEvent = KnownCmuxEvent | UnknownEvent;

/** A decoded initial replay yielded by `attachSurface()`. */
export interface DecodedVtStateEvent extends Omit<VtStateEvent, "data"> { data: Uint8Array }

/** Decoded live PTY bytes yielded by `attachSurface()`. */
export interface DecodedOutputEvent extends Omit<OutputEvent, "data"> { data: Uint8Array }

/** A decoded replacement replay yielded by `attachSurface()`. */
export interface DecodedResizedEvent extends Omit<ResizedEvent, "data" | "replay"> {
  data: Uint8Array;
  /** @deprecated Use `data`. Retained for compatibility with early protocol-v6 SDK builds. */
  replay: Uint8Array;
}

/** A special-color update yielded by `attachSurface()`. */
export type DecodedColorsChangedEvent = ColorsChangedEvent;

/** Attach events as yielded by the client after base64 decoding. */
export type DecodedAttachEvent =
  | DecodedVtStateEvent
  | DecodedOutputEvent
  | DecodedResizedEvent
  | DecodedColorsChangedEvent
  | BrowserStateEvent
  | BrowserFrameEvent
  | ScrollChangedEvent
  | DetachedEvent
  | OverflowEvent
  | UnknownEvent;

/** Known events yielded by a protocol v7 render attachment. */
export type KnownRenderAttachEvent =
  | RenderStateEvent
  | RenderDeltaEvent
  | ScrollChangedEvent
  | DetachedEvent
  | OverflowEvent;

/** Render attachment events, including unknown future event names. */
export type RenderAttachEvent = KnownRenderAttachEvent | UnknownEvent;
