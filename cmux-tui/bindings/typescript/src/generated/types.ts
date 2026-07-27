/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 10, IR 2006a175f8506aeeca40689c7a61651a6685a7b03b3c9c52c38cd5259c3a9a96. */


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

export type Base64 = string;

export type BrowserFrame = {
  "data": Base64;
  "height": number;
  "seq": bigint;
  "width": number;
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

export type FrontendProjection = {
  "frontend": string;
  "projection": (JsonValue) | null;
  "projection_revision": bigint;
  "replayed"?: boolean;
  "schema_version": number;
  "scope": string;
  "subject_key": string;
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
  "exit": (JsonValue) | null;
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

export type RunResult = {
  "pane": Id;
  "screen": Id;
  "surface": Id;
  "terminal_id": (string) | null;
  "terminal_incarnation": (string) | null;
  "workspace": Id;
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
  "surface": Id;
  "terminal_id"?: (string) | null;
  "terminal_incarnation"?: (string) | null;
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

export type TerminalLifecycle = "launching" | "adopting" | "running" | "exited" | "tombstoned";

export type TerminalPlacement = {
  "generation": string;
  "key": string;
  "lifecycle": ("running") | null;
  "pane": Id;
  "registry_id": string;
  "replayed": boolean;
  "screen": Id;
  "surface": Id;
  "terminal_id": (string) | null;
  "terminal_incarnation": (string) | null;
  "terminal_revision": bigint;
  "workspace": Id;
};

export type TerminalRecord = {
  "exit": (JsonValue) | null;
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

export type VtStateResult = {
  "cols": number;
  "data": Base64;
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
