/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR 65aa592727bc414fe3e66ac125c9b8541a1926bbe9eaa572acc66b4681bf6589. */


/** JSON accepted by the wire codec. bigint is serialized as an exact JSON integer. */
export type JsonValue = null | boolean | number | bigint | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type AgentRecord = {
  "session": (string) | null;
  "source": AgentSource;
  "state": AgentState;
  "surface": Id;
  "updated_at_ms": bigint;
};

export type AgentReportSource = "socket" | "hook";

export type AgentSource = "detected" | "socket" | "hook";

export type AgentState = "working" | "blocked" | "idle" | "done" | "unknown";

export type AppliedPane = {
  "pane": Id;
  "surface": Id;
};

export type ApplyLayoutResult = {
  "panes": Array<AppliedPane>;
  "screen": Id;
};

export type AttachedViewOutcomeResult = {
  "outcome": ViewAttachmentOutcome;
};

export type AttachedViewResizeResult = {
  "accepted": boolean;
  "outcome": ViewAttachmentOutcome;
  "reservation_id": (bigint) | null;
};

export type Base64 = string;

export type BrowserFrame = {
  "data": Base64;
  "height": number;
  "seq": bigint;
  "width": number;
};

export type BrowserProviderAuthentication = "none" | "bearer";

export type BrowserProviderSnapshot = {
  "authentication"?: BrowserProviderAuthentication;
  "available": boolean;
  "clients"?: bigint;
  "endpoint"?: string;
  "provider_id"?: string;
  "revision": bigint;
  "targets": Array<BrowserProviderTarget>;
};

export type BrowserProviderTarget = {
  "tab_id": string;
  "target_id": string;
};

export type BrowserProviderUnregisterResult = {
  "removed": boolean;
};

export type CellPixelFailure = {
  "error": string;
  "surface": Id;
};

export type CellPixelResize = {
  "cols": number;
  "reservation_id": bigint;
  "rows": number;
  "surface": Id;
};

export type CellPixelSurface = {
  "height_px": number;
  "surface": Id;
  "width_px": number;
};

export type ClientInfo = {
  "attached": Array<Id>;
  "client": bigint;
  "connected_seconds": bigint;
  "kind": (string) | null;
  "name": (string) | null;
  "self": boolean;
  "sizes": Array<ClientSize>;
  "transport": ClientTransport;
};

export type ClientSize = {
  "cols": (number) | null;
  "rows": (number) | null;
  "size_participating": boolean;
  "surface": Id;
};

export type ClientTransport = "local" | "unix" | "ws";

export type CloseTerminalResult = {
  "already_closed": boolean;
  "closed": true;
  "generation": string;
  "registry_id": string;
  "surface": (Id) | null;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
};

export type ColorHex = string;

export type CopyResult = {
  "mode": "screen" | "selection" | "scrollback";
  "text": string;
};

export type CursorStyle = "block" | "underline" | "bar";

export type DeadPane = {
  "dead": true;
  "id": Id;
};

export type DeclarativeLayout = ({ "type": "leaf" } & {
  "command"?: (Array<string>) | null;
  "cwd"?: (string) | null;
  "type": "leaf";
}) | ({ "type": "split" } & {
  "a": DeclarativeLayout;
  "b": DeclarativeLayout;
  "dir": SplitDirection;
  "ratio": number;
  "type": "split";
}) | ({ "type": "stack" } & {
  "expanded": Id;
  "panes": Array<Id>;
  "type": "stack";
});

export type EmptyResult = {
};

export type ExportLayoutResult = {
  "layout": Layout;
  "panes": Array<ExportedPane>;
};

export type ExportedPane = {
  "pane": Id;
  "surfaces": Array<Id>;
};

export type FocusDirectionResult = {
  "pane": Id;
};

export type FrontendFocusTarget = "pane" | "machine_rail" | "workspace_rail" | "tabs_rail" | "projection_rail";

export type FrontendJournalEvent = ({ "kind": "focus" } & {
  "content_id"?: (string) | null;
  "event_id": string;
  "frontend_projection_id": string;
  "generation": string;
  "kind": "focus";
  "pane_id"?: (string) | null;
  "screen_id"?: (string) | null;
  "tab_id"?: (string) | null;
  "target": FrontendFocusTarget;
  "workspace_id"?: (string) | null;
}) | ({ "kind": "resize" } & {
  "cell_height": number;
  "cell_width": number;
  "cols": number;
  "event_id": string;
  "frontend_projection_id": string;
  "generation": string;
  "kind": "resize";
  "rows": number;
}) | ({ "kind": "viewport" } & {
  "event_id": string;
  "frontend_projection_id": string;
  "generation": string;
  "kind": "viewport";
  "offset": bigint;
  "screen_id"?: (string) | null;
  "settled": boolean;
  "target": bigint;
});

export type FrontendProjection = {
  "frontend": string;
  "projection": (JsonValue) | null;
  "projection_revision": bigint;
  "replayed"?: boolean;
  "schema_version": number;
  "scope": string;
  "subject_key": string;
};

export type GetCellPixelsResult = {
  "height_px": number;
  "surfaces": Array<CellPixelSurface>;
  "width_px": number;
};

export type Id = bigint;

export type IdMapping = {
  "id": Id;
  "kind": "workspace" | "screen" | "pane" | "surface";
  "short_id": string;
};

export type IdentifyResult = {
  "app": "cmux-tui";
  "build_commit"?: (string) | null;
  "capabilities"?: Array<string>;
  "daemon_handoff": 1;
  "generation": string;
  "ghostty_commit"?: (string) | null;
  "lifecycle_ready"?: boolean;
  "pid": number;
  "protocol": number;
  "registry_id": string;
  "session": string;
  "terminal_revision": bigint;
  "version": string;
  "workspace_revision": bigint;
};

export type IdsResult = {
  "ids": Array<IdMapping>;
};

export type KittyGraphicsState = {
  "alternate_next_image_id": number;
  "alternate_replay_next_image_id": number;
  "image_bytes": bigint;
  "images": bigint;
  "inflight_bytes": bigint;
  "placements": bigint;
  "primary_next_image_id": number;
  "primary_replay_next_image_id": number;
  "replay_cursor_offset": number;
};

export type KittyImageAlias = {
  "image_id": number;
  "image_number": number;
};

export type Layout = ({ "type": "leaf" } & {
  "pane": Id;
  "type": "leaf";
}) | ({ "type": "split" } & {
  "a": Layout;
  "b": Layout;
  "dir": SplitDirection;
  "ratio": number;
  /** Stable for the lifetime of this split node. */
  "split"?: Id;
  "type": "split";
}) | ({ "type": "stack" } & {
  "expanded": Id;
  "panes": Array<Id>;
  "type": "stack";
});

export type LayoutUndoConfirmationRequired = {
  "closes_panes": Array<Id>;
  "confirmation_required": true;
  "revision": bigint;
  "screen": Id;
  "undone": false;
};

export type LayoutUndoResult = (LayoutUndoUndone) | (LayoutUndoConfirmationRequired);

export type LayoutUndoUndone = {
  "confirmation_required"?: false;
  "revision": bigint;
  "screen": Id;
  "undone": true;
};

export type ListAgentsResult = {
  "agents": Array<AgentRecord>;
};

export type ListTerminalsResult = {
  "generation": string;
  "registry_id": string;
  "terminal_revision": bigint;
  "terminals": Array<TerminalRecord>;
};

export type LivePane = {
  "active_tab": bigint;
  "focused_at"?: bigint;
  "id": Id;
  "name": (string) | null;
  "short_id"?: string;
  "tabs": Array<Tab>;
};

export type MintTerminalRendererResult = {
  "endpoint": string;
  "incarnation": string;
  "protocol_version": number;
  "rights": number;
  "terminal_id": string;
  "token": string;
  "ttl_ms": bigint;
};

export type MoveTerminalResult = {
  "changed": boolean;
  "generation": string;
  "lifecycle": TerminalLifecycle;
  "pane": (Id) | null;
  "registry_id": string;
  "replayed": boolean;
  "screen": (Id) | null;
  "surface": (Id) | null;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
  "workspace": (Id) | null;
  "workspace_key": string;
};

export type NotificationLevel = "info" | "warning" | "error";

export type NotificationMarker = {
  "level": NotificationLevel;
  "notification": Id;
  "unread": boolean;
};

export type NotifyResult = {
  "notification": Id;
};

export type Pane = (LivePane) | (DeadPane);

export type PaneDirection = "left" | "right" | "up" | "down";

export type PaneNeighborResult = {
  "pane": (Id) | null;
};

export type PingResult = {
  "build_commit"?: (string) | null;
  "ghostty_commit"?: (string) | null;
  "ok": true;
  "protocol": number;
  "version": string;
};

export type ProcessInfoResult = {
  "command": (string) | null;
  "cwd": (string) | null;
  /** Working directory of the process group that owns the PTY, read at request time. Null when the lookup fails; absent from daemons that predate the field. Clients treat absence as null. */
  "foreground_cwd"?: (string) | null;
  "pid": (number) | null;
};

export type ProviderWorkspaceMutationResult = {
  "key": string;
  "workspace": Id;
  "workspace_revision": bigint;
};

export type ReadScreenResult = {
  "text": string;
};

export type ReadScrollbackResult = {
  "epoch": bigint;
  "rows": Array<RenderRow>;
  "start": number;
  "total": number;
};

export type RenderCursor = {
  "blink": boolean;
  "color": (ColorHex) | null;
  "style": CursorStyle;
  "visible": boolean;
  "x": number;
  "y": number;
};

export type RenderGraphicFormat = "rgb" | "rgba";

export type RenderGraphicImage = {
  "data": Base64;
  "format": RenderGraphicFormat;
  "generation": bigint;
  "height": number;
  "id": number;
  "width": number;
};

export type RenderGraphicPlacement = {
  "anchor_col"?: number;
  "anchor_row"?: number;
  "columns": number;
  "grid_cols": number;
  "grid_rows": number;
  "image_id": number;
  "ordinal": number;
  "pixel_height": number;
  "pixel_width": number;
  "placement_id": number;
  "rows": number;
  "source_height": number;
  "source_width": number;
  "source_x": number;
  "source_y": number;
  "viewport_col": number;
  "viewport_row": number;
  "viewport_visible": boolean;
  "x_offset": number;
  "y_offset": number;
  "z": number;
};

export type RenderGraphics = {
  "generation": bigint;
  "images"?: Array<RenderGraphicImage>;
  "placements": Array<RenderGraphicPlacement>;
  "removed_image_ids"?: Array<number>;
};

export type RenderGraphicsDelta = {
  "generation": bigint;
  "images"?: Array<RenderGraphicImage>;
  "placements"?: Array<RenderGraphicPlacement>;
  "removed_image_ids"?: Array<number>;
};

export type RenderRow = {
  "row": number;
  "runs": Array<RenderRun>;
};

export type RenderRun = {
  "attrs": number;
  "bg": (ColorHex) | null;
  "fg": (ColorHex) | null;
  "text": string;
  "underline"?: RenderUnderline;
  "width_hint"?: number;
};

export type RenderUnderline = "single" | "double" | "curly" | "dotted" | "dashed";

export type ReportAgentResult = {
  "session": (string) | null;
  "source": AgentReportSource;
  "state": AgentState;
  "surface": Id;
};

export type ResizeSurfaceResult = {
  "accepted": boolean;
  "reservation_id": (bigint) | null;
};

export type ResolveTerminalResult = {
  "exit": (TerminalExit) | null;
  "generation": string;
  "launch_spec": JsonValue;
  "lifecycle": TerminalLifecycle;
  "registry_id": string;
  "surface": (Id) | null;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
  "workspace_key": string;
};

export type ResourceSelectors = {
  "agent"?: (string) | null;
  "browser"?: (string) | null;
  "client"?: (string) | null;
  "frontend_projection"?: (string) | null;
  "machine"?: (string) | null;
  "notification"?: (string) | null;
  "pairing_request"?: (string) | null;
  "pane"?: (string) | null;
  "screen"?: (string) | null;
  "session"?: (string) | null;
  "sidebar_view"?: (string) | null;
  "split"?: (string) | null;
  "stream"?: (string) | null;
  "tab"?: (string) | null;
  "terminal"?: (string) | null;
  "workspace"?: (string) | null;
};

export type RunResult = {
  "already_exited": boolean;
  "exit": (TerminalExit) | null;
  "lifecycle": TerminalLifecycle;
  "pane": (Id) | null;
  "screen": (Id) | null;
  "surface": (Id) | null;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
  "workspace": (Id) | null;
};

export type Screen = {
  "active": boolean;
  "active_pane": Id;
  "id": Id;
  "layout": Layout;
  "name": (string) | null;
  "panes": Array<Pane>;
  "short_id"?: string;
  "zoomed_pane": (Id) | null;
};

export type SetCellPixelsResult = {
  "failures": Array<CellPixelFailure>;
  "resizes": Array<CellPixelResize>;
};

export type ShutdownDaemonResult = {
  "accepted": true;
  "generation": string;
  "pid": number;
};

export type SidebarPluginResult = {
  "error": (string) | null;
  "retry_after_ms": (bigint) | null;
  "surface": (Id) | null;
};

export type Size = {
  "cols": number;
  "rows": number;
};

export type SplitDirection = "right" | "down";

export type SurfaceResult = {
  "surface": Id;
  "terminal_id"?: (string) | null;
  "terminal_incarnation"?: (string) | null;
};

export type Tab = {
  "browser_error"?: (string) | null;
  "browser_frames_stalled"?: (boolean) | null;
  "browser_source": ("external" | "launched") | null;
  "browser_status"?: ("starting" | "live" | "failed") | null;
  "dead": boolean;
  "kind": "pty" | "browser";
  "name": (string) | null;
  "notification"?: (NotificationMarker) | null;
  "short_id"?: string;
  "size": (Size) | null;
  "supports_clear_history_key_fallback"?: boolean;
  "surface": Id;
  "terminal_id"?: (string) | null;
  "terminal_incarnation"?: (string) | null;
  "terminal_resource_id"?: (string) | null;
  "title": string;
};

export type TerminalColors = {
  "bg": (ColorHex) | null;
  "cursor"?: (ColorHex) | null;
  "cursor_blink"?: (boolean) | null;
  "cursor_style"?: (CursorStyle) | null;
  "fg": (ColorHex) | null;
  "palette"?: Record<string, ColorHex>;
  "selection_bg": (ColorHex) | null;
  "selection_fg": (ColorHex) | null;
};

export type TerminalEventsResult = {
  "events": Array<TerminalRegistryEvent>;
  "generation": string;
  "registry_id": string;
  "terminal_revision": bigint;
};

export type TerminalExit = {
  "exited_at_ms": bigint;
  "outcome": TerminalExitOutcome;
};

export type TerminalExitOutcome = ({ "kind": "exit" } & {
  "code": number;
  "kind": "exit";
}) | ({ "kind": "signal" } & {
  "core_dumped": boolean;
  "kind": "signal";
  "signal": number;
}) | ({ "kind": "unknown" } & {
  "kind": "unknown";
  "reason": string;
});

export type TerminalKey = "unidentified" | "backquote" | "backslash" | "bracket-left" | "bracket-right" | "comma" | "digit0" | "digit1" | "digit2" | "digit3" | "digit4" | "digit5" | "digit6" | "digit7" | "digit8" | "digit9" | "equal" | "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" | "minus" | "period" | "quote" | "semicolon" | "slash" | "backspace" | "enter" | "space" | "tab" | "delete" | "end" | "home" | "insert" | "page-down" | "page-up" | "arrow-down" | "arrow-left" | "arrow-right" | "arrow-up" | "numpad0" | "numpad1" | "numpad2" | "numpad3" | "numpad4" | "numpad5" | "numpad6" | "numpad7" | "numpad8" | "numpad9" | "numpad-add" | "numpad-backspace" | "numpad-comma" | "numpad-decimal" | "numpad-divide" | "numpad-enter" | "numpad-equal" | "numpad-multiply" | "numpad-subtract" | "numpad-up" | "numpad-down" | "numpad-right" | "numpad-left" | "numpad-begin" | "numpad-home" | "numpad-end" | "numpad-insert" | "numpad-delete" | "numpad-page-up" | "numpad-page-down" | "escape" | "f1" | "f2" | "f3" | "f4" | "f5" | "f6" | "f7" | "f8" | "f9" | "f10" | "f11" | "f12" | "f13" | "f14" | "f15" | "f16" | "f17" | "f18" | "f19" | "f20";

export type TerminalKeyAction = "press" | "release" | "repeat";

export type TerminalKeyInput = {
  "action"?: (TerminalKeyAction) | null;
  "base_layout_codepoint"?: (string) | null;
  "composing"?: boolean;
  "consumed_mods": TerminalModifiers;
  "key": TerminalKey;
  "macos_option_as_alt": boolean;
  "mods": TerminalModifiers;
  "shifted_codepoint"?: (string) | null;
  "unshifted_codepoint"?: (string) | null;
  "utf8": string;
};

export type TerminalLifecycle = "launching" | "adopting" | "running" | "exited" | "tombstoned";

export type TerminalModifiers = {
  "alt": boolean;
  "caps_lock": boolean;
  "control": boolean;
  "num_lock": boolean;
  "shift": boolean;
  "super": boolean;
};

export type TerminalPlacement = {
  "already_exited": boolean;
  "exit": (TerminalExit) | null;
  "generation": string;
  "key": string;
  "lifecycle": TerminalLifecycle;
  "pane": (Id) | null;
  "registry_id": string;
  "replayed": boolean;
  "screen": (Id) | null;
  "surface": (Id) | null;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
  "workspace": (Id) | null;
};

export type TerminalRecord = {
  "exit": (TerminalExit) | null;
  "launch_spec": JsonValue;
  "lifecycle": TerminalLifecycle;
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  "workspace_key": string;
};

export type TerminalRegistryEvent = {
  "kind": string;
  "mutation_id": string;
  "origin": string;
  "result": JsonValue;
  "terminal_id": string;
  "terminal_revision": bigint;
  "workspace_key": string;
};

export type Tree = {
  "generation"?: string;
  "pane_revision"?: bigint;
  "registry_id"?: string;
  "terminal_revision"?: bigint;
  "workspace_revision"?: bigint;
  "workspaces": Array<Workspace>;
};

export type ViewAttachmentOutcome = "applied" | "passive" | "superseded";

export type VtStateResult = {
  "cols": number;
  "data": Base64;
  "kitty_graphics_state"?: KittyGraphicsState;
  "kitty_image_aliases"?: Array<KittyImageAlias>;
  "rows": number;
};

export type WaitForResult = {
  "elapsed_ms": bigint;
  "matched": true;
  "text": string;
};

export type Workspace = {
  "active": boolean;
  "id": Id;
  "key"?: string;
  "name": string;
  "screens": Array<Screen>;
  "short_id"?: string;
};

export type WorkspaceMutationResult = {
  "changed"?: boolean;
  "generation": string;
  "index": bigint;
  "key": string;
  "registry_id": string;
  "replayed": boolean;
  "workspace": Id;
  "workspace_revision": bigint;
};

export type ZoomPaneResult = {
  "pane": Id;
  "zoomed": boolean;
  "zoomed_pane": (Id) | null;
};
