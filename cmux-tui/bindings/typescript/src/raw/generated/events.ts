/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR b4e69e774777172ac0198454e7f068e53f7a74501dc787b58f3ead05d17b4af6. */


import type * as T from "./types.js";

/** Protocol v11; emission: emitted; streams: subscribe. */
export type AgentChangedEvent = { event: "agent-changed" } & {
  "session": (string) | null;
  "source": T.AgentSource;
  "state": T.AgentState;
  "surface": T.Id;
  "updated_at_ms": bigint;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type BellEvent = { event: "bell" } & {
  "surface": T.Id;
};

/** Protocol v6; emission: emitted; streams: attach-browser. */
export type BrowserStateEvent = { event: "browser-state" } & {
  "cols": number;
  "error": (string) | null;
  /** The initial browser-state includes the latest frame when one exists; later state updates omit it. */
  "frame"?: (T.BrowserFrame) | null;
  "frames_stalled": boolean;
  "rows": number;
  "status": "starting" | "live" | "failed";
  "surface": T.Id;
  "title": string;
  "url": string;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientAttachedEvent = { event: "client-attached" } & {
  "client": bigint;
  "kind": (string) | null;
  "name": (string) | null;
  "transport": "unix" | "ws";
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientChangedEvent = { event: "client-changed" } & {
  "client": bigint;
  "kind": (string) | null;
  "name": (string) | null;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientDetachedEvent = { event: "client-detached" } & {
  "client": bigint;
};

/** Protocol v9; emission: serialized-never-emitted; streams: subscribe. */
export type ClientListInvalidatedEvent = { event: "client-list-invalidated" } & {
};

/** Protocol v6; emission: emitted; streams: attach-byte. */
export type ColorsChangedEvent = { event: "colors-changed" } & {
  "bg": (T.ColorHex) | null;
  "cursor"?: (T.ColorHex) | null;
  "cursor_blink"?: (boolean) | null;
  "cursor_style"?: (T.CursorStyle) | null;
  "fg": (T.ColorHex) | null;
  "palette"?: Record<string, T.ColorHex>;
  "selection_bg": (T.ColorHex) | null;
  "selection_fg": (T.ColorHex) | null;
  "surface"?: T.Id;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ConfigReloadRequestedEvent = { event: "config-reload-requested" } & {
};

/** Protocol v5; emission: emitted; streams: attach-byte, attach-render, attach-browser. */
export type DetachedEvent = { event: "detached" } & {
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type EmptyEvent = { event: "empty" } & {
};

/** Protocol v6; emission: emitted; streams: attach-browser. */
export type FrameEvent = { event: "frame" } & {
  "data": T.Base64;
  "height": number;
  "seq": bigint;
  "surface": T.Id;
  "width": number;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type FrontendProjectionChangedEvent = { event: "frontend-projection-changed" } & {
  "frontend": string;
  "mutation_id": string;
  "origin": string;
  "projection_revision": bigint;
  "scope": string;
  "subject_key": string;
};

/** Protocol v10; emission: emitted; streams: subscribe. */
export type GraphicsStatusEvent = { event: "graphics-status" } & {
  "attempts"?: number;
  "cell_height"?: number;
  "cell_width"?: number;
  "error"?: string;
  "kind": "kitty-image-budget-worker-start-failed" | "kitty-image-budget-update-failed" | "cell-pixel-update-retries-exhausted";
  "remaining"?: bigint;
  "retry_exhausted"?: boolean;
  "summary"?: string;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type LayoutChangedEvent = { event: "layout-changed" } & {
  "screen": T.Id;
};

/** Protocol v6; emission: emitted; streams: subscribe, attach-byte, attach-browser. */
export type NotificationEvent = { event: "notification" } & {
  "body": string;
  "level": T.NotificationLevel;
  "notification": T.Id;
  "surface": (T.Id) | null;
  "title": string;
};

/** Protocol v5; emission: emitted; streams: attach-byte. */
export type OutputEvent = { event: "output" } & {
  "colors"?: T.TerminalColors;
  "data": T.Base64;
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe, attach-byte, attach-render, attach-browser. */
export type OverflowEvent = { event: "overflow" } & {
  "error": string;
  "scope"?: "surface";
  "surface"?: T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type PairingRequestedEvent = { event: "pairing-requested" } & {
  "code": string;
  "expires_in": bigint;
  "peer": string;
  "request": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type PairingResolvedEvent = { event: "pairing-resolved" } & {
  "request": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type PaneAddedEvent = { event: "pane-added" } & {
  "entity": T.Pane;
  "index": bigint;
  "pane": T.Id;
  "screen": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type PaneClosedEvent = { event: "pane-closed" } & {
  "entity": T.Pane;
  "index": bigint;
  "pane": T.Id;
  "screen": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: attach-render. */
export type RenderDeltaEvent = { event: "render-delta" } & {
  "cursor": T.RenderCursor;
  "default_bg"?: T.ColorHex;
  "default_fg"?: T.ColorHex;
  "full": boolean;
  "graphics"?: T.RenderGraphicsDelta;
  "history_epoch"?: bigint;
  "rows": Array<T.RenderRow>;
  "scrollback_rows"?: number;
  "size"?: T.Size;
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: attach-render. */
export type RenderStateEvent = { event: "render-state" } & {
  "cursor": T.RenderCursor;
  "default_bg": T.ColorHex;
  "default_fg": T.ColorHex;
  "graphics"?: T.RenderGraphics;
  "history_epoch": bigint;
  "rows": Array<T.RenderRow>;
  "scrollback_rows": number;
  "size": T.Size;
  "surface": T.Id;
};

/** Protocol v6; emission: emitted; streams: attach-byte. */
export type ResizedEvent = { event: "resized" } & {
  "colors"?: T.TerminalColors;
  "cols": number;
  /** Protocol 6 compatibility field. */
  "data"?: T.Base64;
  "kitty_graphics_state"?: T.KittyGraphicsState;
  "kitty_image_aliases"?: Array<T.KittyImageAlias>;
  "replay"?: T.Base64;
  "rows": number;
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type ScreenAddedEvent = { event: "screen-added" } & {
  "entity": T.Screen;
  "index": bigint;
  "screen": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type ScreenClosedEvent = { event: "screen-closed" } & {
  "entity": T.Screen;
  "index": bigint;
  "screen": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type ScreenRenamedEvent = { event: "screen-renamed" } & {
  "entity": T.Screen;
  "screen": T.Id;
  "workspace": T.Id;
};

/** Protocol v6; emission: emitted; streams: subscribe, attach-byte, attach-render, attach-browser. */
export type ScrollChangedEvent = { event: "scroll-changed" } & {
  "at_bottom": boolean;
  "offset": bigint;
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type StatusEvent = { event: "status" } & {
  "message": string;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceExitedEvent = { event: "surface-exited" } & {
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceOutputEvent = { event: "surface-output" } & {
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type SurfaceResizeFailedEvent = { event: "surface-resize-failed" } & {
  "cols": number;
  "error": string;
  "reservation_id": (bigint) | null;
  "retry_after_ms": (bigint) | null;
  "rows": number;
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceResizedEvent = { event: "surface-resized" } & {
  "cols": number;
  "reservation_id": (bigint) | null;
  "rows": number;
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type TabAddedEvent = { event: "tab-added" } & {
  "entity": T.Tab;
  "index": bigint;
  "pane": T.Id;
  "screen": T.Id;
  "surface": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type TabClosedEvent = { event: "tab-closed" } & {
  "entity": T.Tab;
  "index": bigint;
  "pane": T.Id;
  "screen": T.Id;
  "surface": T.Id;
  "workspace": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type TabRenamedEvent = { event: "tab-renamed" } & {
  "entity": T.Tab;
  "pane": T.Id;
  "screen": T.Id;
  "surface": T.Id;
  "workspace": T.Id;
};

/** Protocol v9; emission: emitted; streams: subscribe. */
export type TerminalRegistryChangedEvent = { event: "terminal-registry-changed" } & {
  "generation": string;
  "refetch": "terminal-events-or-list-terminals";
  "registry_id": string;
  "terminal_revision": bigint;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type TitleChangedEvent = { event: "title-changed" } & {
  "surface": T.Id;
  "title"?: string;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type TreeChangedEvent = { event: "tree-changed" } & {
};

/** Protocol v5; emission: emitted; streams: attach-byte. */
export type VtStateEvent = { event: "vt-state" } & {
  "colors"?: T.TerminalColors;
  "cols": number;
  "data": T.Base64;
  "kitty_graphics_state"?: T.KittyGraphicsState;
  "kitty_image_aliases"?: Array<T.KittyImageAlias>;
  "rows": number;
  "surface": T.Id;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type WindowTitleRequestedEvent = { event: "window-title-requested" } & {
  "title": string;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type WorkspaceAddedEvent = { event: "workspace-added" } & {
  "entity": T.Workspace;
  "generation": string;
  "index": bigint;
  "mutation_id"?: string;
  "origin"?: string;
  "registry_id": string;
  "workspace": T.Id;
  "workspace_revision": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type WorkspaceClosedEvent = { event: "workspace-closed" } & {
  "entity": T.Workspace;
  "generation": string;
  "index": bigint;
  "mutation_id"?: string;
  "origin"?: string;
  "registry_id": string;
  "workspace": T.Id;
  "workspace_revision": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type WorkspaceMovedEvent = { event: "workspace-moved" } & {
  "entity": T.Workspace;
  "generation": string;
  "index": bigint;
  "mutation_id"?: string;
  "origin"?: string;
  "registry_id": string;
  "workspace": T.Id;
  "workspace_revision": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe-deltas. */
export type WorkspaceRenamedEvent = { event: "workspace-renamed" } & {
  "entity": T.Workspace;
  "generation": string;
  "mutation_id"?: string;
  "origin"?: string;
  "registry_id": string;
  "workspace": T.Id;
  "workspace_revision": bigint;
};

/** A forward-compatible event not known to this SDK version. */
export interface UnknownEvent {
  event: string;
  [key: string]: unknown;
}

/** Every event emitted by protocol v12. */
export type KnownCmuxEvent =
  | AgentChangedEvent
  | BellEvent
  | BrowserStateEvent
  | ClientAttachedEvent
  | ClientChangedEvent
  | ClientDetachedEvent
  | ColorsChangedEvent
  | ConfigReloadRequestedEvent
  | DetachedEvent
  | EmptyEvent
  | FrameEvent
  | FrontendProjectionChangedEvent
  | GraphicsStatusEvent
  | LayoutChangedEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | PairingRequestedEvent
  | PairingResolvedEvent
  | PaneAddedEvent
  | PaneClosedEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ResizedEvent
  | ScreenAddedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | ScrollChangedEvent
  | StatusEvent
  | SurfaceExitedEvent
  | SurfaceOutputEvent
  | SurfaceResizeFailedEvent
  | SurfaceResizedEvent
  | TabAddedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | TerminalRegistryChangedEvent
  | TitleChangedEvent
  | TreeChangedEvent
  | VtStateEvent
  | WindowTitleRequestedEvent
  | WorkspaceAddedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Shapes serialized by runtime code but excluded from active event unions. */
export type SerializedButNotEmittedEvent =
  | ClientListInvalidatedEvent;

/** Known subscribe stream events. */
export type KnownSubscribeEvent =
  | AgentChangedEvent
  | BellEvent
  | ClientAttachedEvent
  | ClientChangedEvent
  | ClientDetachedEvent
  | ConfigReloadRequestedEvent
  | EmptyEvent
  | FrontendProjectionChangedEvent
  | GraphicsStatusEvent
  | LayoutChangedEvent
  | NotificationEvent
  | OverflowEvent
  | PairingRequestedEvent
  | PairingResolvedEvent
  | PaneAddedEvent
  | PaneClosedEvent
  | ScreenAddedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | ScrollChangedEvent
  | StatusEvent
  | SurfaceExitedEvent
  | SurfaceOutputEvent
  | SurfaceResizeFailedEvent
  | SurfaceResizedEvent
  | TabAddedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | TerminalRegistryChangedEvent
  | TitleChangedEvent
  | TreeChangedEvent
  | WindowTitleRequestedEvent
  | WorkspaceAddedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Known delta-subscription events. */
export type TreeDeltaEvent =
  | PaneAddedEvent
  | PaneClosedEvent
  | ScreenAddedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | TabAddedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | WorkspaceAddedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Known events from any attach mode. */
export type KnownAttachEvent =
  | BrowserStateEvent
  | ColorsChangedEvent
  | DetachedEvent
  | FrameEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ResizedEvent
  | ScrollChangedEvent
  | VtStateEvent;

/** Known byte attach events. */
export type KnownByteAttachEvent =
  | ColorsChangedEvent
  | DetachedEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | ResizedEvent
  | ScrollChangedEvent
  | VtStateEvent;

/** Known render attach events. */
export type KnownRenderAttachEvent =
  | DetachedEvent
  | OverflowEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ScrollChangedEvent;

/** Known browser attach events. */
export type KnownBrowserAttachEvent =
  | BrowserStateEvent
  | DetachedEvent
  | FrameEvent
  | NotificationEvent
  | OverflowEvent
  | ScrollChangedEvent;

export type CmuxEvent = KnownCmuxEvent | UnknownEvent;
export type SubscribeEvent = KnownSubscribeEvent | UnknownEvent;
export type AttachEvent = KnownAttachEvent | UnknownEvent;
export type ByteAttachEvent = KnownByteAttachEvent | UnknownEvent;
export type RenderAttachEvent = KnownRenderAttachEvent | UnknownEvent;
export type BrowserAttachEvent = KnownBrowserAttachEvent | UnknownEvent;
