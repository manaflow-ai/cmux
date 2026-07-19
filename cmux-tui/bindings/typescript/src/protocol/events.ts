import type {
  AgentSource,
  AgentState,
  Base64,
  Id,
  NotificationLevel,
} from "./common.js";

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

export interface SurfaceResizedEvent { event: "surface-resized"; surface: Id; cols: number; rows: number }
export interface SurfaceExitedEvent { event: "surface-exited"; surface: Id }
export interface TitleChangedEvent { event: "title-changed"; surface: Id }
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
export interface EmptyEvent { event: "empty" }

/** Initial base64 VT replay for an attached PTY surface. */
export interface VtStateEvent {
  event: "vt-state";
  surface: Id;
  cols: number;
  rows: number;
  data: Base64;
}

/** Live base64 PTY bytes after the attach snapshot. */
export interface OutputEvent { event: "output"; surface: Id; data: Base64 }

/** A protocol v6 replay that replaces the existing terminal mirror. */
export interface ResizedEvent {
  event: "resized";
  surface: Id;
  cols: number;
  rows: number;
  data: Base64;
  /** @deprecated Compatibility with early protocol-v6 drafts. Servers send `data`. */
  replay?: Base64;
}

export interface DetachedEvent { event: "detached"; surface: Id }

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
  | TreeChangedEvent
  | LayoutChangedEvent
  | SurfaceOutputEvent
  | ScrollChangedEvent
  | SurfaceResizedEvent
  | SurfaceExitedEvent
  | TitleChangedEvent
  | BellEvent
  | NotificationEvent
  | ConfigReloadRequestedEvent
  | WindowTitleRequestedEvent
  | EmptyEvent;

/** Subscribe events, including unknown future event names. */
export type SubscribeEvent = KnownSubscribeEvent | UnknownEvent;

/** All currently implemented attach event payloads. */
export type KnownAttachEvent = VtStateEvent | OutputEvent | ResizedEvent | ScrollChangedEvent | DetachedEvent;

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

/** Attach events as yielded by the client after base64 decoding. */
export type DecodedAttachEvent =
  | DecodedVtStateEvent
  | DecodedOutputEvent
  | DecodedResizedEvent
  | ScrollChangedEvent
  | DetachedEvent
  | UnknownEvent;
