/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR 55ecd131c02ab3542822be1b9f1292905fa54dee7cea4f22efd4d6ee5d79ba3e. */


/** JSON accepted by the wire codec. bigint is serialized as an exact JSON integer. */
export type JsonValue = null | boolean | number | bigint | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type ActivitySnapshot = {
  "attached_clients": number;
  "last_agent_action_at_ms": (bigint) | null;
  "last_user_input_at_ms": (bigint) | null;
  "live_agents": number;
};

export type ActivitySubscribeResult = {
  "activity": ActivitySnapshot;
};

export type AgentRecord = {
  "session": (string) | null;
  "source": AgentSource;
  "state": AgentState;
  "surface": Id;
  "updated_at_ms": bigint;
};

export type AgentReportSource = "socket" | "hook";

export type AgentSessionSource = {
  /** The agent kind the chat was started with. */
  "harness"?: (string) | null;
  /** install: and the stable install id of the machine whose acpmux runs the session. */
  "host": string;
  /** Display name of the host machine: 1 to 255 bytes, no control characters. */
  "host_name"?: (string) | null;
  /** The acpmux session id; null for a new chat until bind-conversation-tab-session. */
  "session"?: (string) | null;
};

export type AgentSource = "plugin" | "detected" | "socket" | "hook";

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
  "participant"?: string;
  "reservation_id": (bigint) | null;
};

export type Base64 = string;

export type Bookmark = {
  "browser_profile_id": string;
  "created_ms": bigint;
  "favicon_key"?: string;
  /** `bm_` and 32 lowercase hex digits. */
  "id": string;
  /** Dense 0-based position among the node's siblings. */
  "index": bigint;
  /** Known values: url, folder. Other values are future kinds. */
  "kind": string;
  "last_used_ms"?: bigint;
  /** `bar`, `other`, or a folder's id. */
  "parent": string;
  /** Folders only. */
  "source_key"?: string;
  "title": string;
  /** url nodes. */
  "url"?: string;
  [key: string]: unknown;
};

export type BookmarkChangeResult = {
  "bookmark": Bookmark;
  "changed": boolean;
  "replayed": boolean;
  [key: string]: unknown;
};

export type BookmarkImportNode = {
  /** A folder's nodes. */
  "children"?: Array<BookmarkImportNode>;
  /** Defaults to now. */
  "created_ms"?: bigint;
  /** url or folder. */
  "kind": string;
  "title": string;
  /** Required for a url node; refused for a folder. */
  "url"?: string;
};

export type BrowserFrame = {
  "data": Base64;
  "height": number;
  "seq": bigint;
  "width": number;
};

export type BrowserHostProviderResult = {
  "host_pid": number;
  "listener_pid": number;
  "secret": string;
  "socket": string;
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

export type CloseReason = "session_end";

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

export type ColumnPin = {
  "edge": string;
  "mode": string;
};

export type ConversationChange = {
  /** kind conversation. */
  "conversation"?: ConversationSummary;
  /** Known values: message and message-updated (message), read-cursor (participant, seq), conversation (conversation). A change of another kind keeps its fields in the additional properties. */
  "kind": string;
  /** kind message or message-updated. */
  "message"?: ConversationMessage;
  /** kind read-cursor. */
  "participant"?: string;
  /** kind read-cursor. */
  "seq"?: bigint;
  [key: string]: unknown;
};

export type ConversationImportMessage = {
  "author": string;
  "client_msg_id": string;
  "created_at": string;
  "id"?: (string) | null;
  "parts": Array<ConversationPart>;
};

export type ConversationMessage = {
  "author": string;
  "client_msg_id": string;
  "conversation": string;
  "created_at": string;
  "edited_at"?: string;
  "id": string;
  "parts": Array<ConversationPart>;
  "reactions": Array<ConversationReaction>;
  "reply_to"?: ConversationPartRef;
  "retracted_at"?: string;
  "seq": bigint;
};

export type ConversationPart = {
  /** type work. */
  "host"?: string;
  /** type work: the reply preview (a string). type attachment (local-attachments-v1): an image's preview object {hash, mime_type, byte_count}. */
  "preview"?: JsonValue;
  /** type text. */
  "runs"?: Array<ConversationTextRun>;
  /** type work. */
  "session"?: string;
  /** type work. Known values: running, done, failed, waiting. */
  "status"?: string;
  /** type text. */
  "text"?: string;
  /** Known values: text (text, runs), work (session, host, status, preview) and, with local-attachments-v1, attachment (hash, name, mime_type, byte_count, width, height, duration_ms, poster, preview; see spec/commands.md). A part of another type keeps its fields in the additional properties. */
  "type": string;
  [key: string]: unknown;
};

export type ConversationPartRef = {
  "message_id": string;
  "part_index": number;
};

export type ConversationParticipant = {
  "acp_session"?: string;
  /** Known values: mux, agent. Other values are future classes. */
  "agent_class"?: string;
  "display_name": string;
  "id": string;
  /** Known values: human, agent. Other values are future kinds. */
  "kind": string;
};

export type ConversationReaction = {
  "at": string;
  "author": string;
  "kind": ConversationReactionKind;
  "part_index": number;
};

export type ConversationReactionKind = {
  "emoji"?: string;
  /** Known values: love, like, dislike, laugh, emphasize, question. */
  "tapback"?: string;
  [key: string]: unknown;
};

export type ConversationSearchHit = {
  "author": string;
  "conversation": string;
  "created_at": string;
  "message_id": string;
  "seq": bigint;
  "snippet": string;
  "title": string;
};

export type ConversationSummary = {
  "created_at": string;
  "id": string;
  "last_message"?: ConversationMessage;
  "last_seq": bigint;
  "owner": string;
  "participants": Array<ConversationParticipant>;
  "read_cursors": Record<string, bigint>;
  "rev": bigint;
  "title": string;
  "updated_at": string;
};

export type ConversationTabRecord = {
  /** Agent session source (agent-session-tabs-v1); exclusive with the other sources. */
  "agent_session"?: AgentSessionSource;
  /** Conversation source: a conv_ id, with owner. */
  "conversation"?: string;
  /** Conversation source: local or cloud. */
  "owner"?: string;
  /** Page source (page-tabs-v1): the id of one of the app's own pages; exclusive with the other sources. */
  "page"?: string;
};

export type ConversationTextRun = {
  "length": number;
  "link"?: string;
  "mention"?: string;
  "start": number;
};

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

/** Opaque JSON: A uint64 client id or a shared-sizing participant id string. */
export type DetachClientTarget = JsonValue;

export type DetachReason = "network" | "disconnected-by" | "host-shutdown" | "superseded";

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

export type GetSizeStateResult = {
  "self_participant": (string) | null;
  "state": SizeState;
};

export type GuestUrlAcknowledgeResult = {
  "accepted": boolean;
};

export type GuestUrlClaimResult = {
  "claimed": boolean;
};

export type GuestUrlOpenResult = {
  "opened": boolean;
};

export type GuestUrlSubscribeResult = {
  "url_open_ready": boolean;
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
  "launch_snapshot_path"?: (string) | null;
  "lifecycle_ready"?: boolean;
  "machine_name"?: string;
  "pid": number;
  "protocol": number;
  "registry_id": string;
  "session": string;
  "session_id"?: string;
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

export type MachineListeningTcpResult = {
  "stdout": string;
};

export type MachineUsage = {
  "api_equivalent_usd": number;
  "as_of": (string) | null;
  "period_days": number;
  "total_tokens": bigint;
  "vm_id": string;
};

export type MachineUsageResult = {
  "usage": (MachineUsage) | null;
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

export type NewRowResult = {
  "pane": Id;
  "surface": Id;
  "terminal_id"?: (string) | null;
  "terminal_incarnation"?: (string) | null;
  "transaction"?: string;
};

export type NoteSizeActivityResult = {
  "changed": boolean;
  "participant": string;
};

export type NotificationLevel = "info" | "warning" | "error";

export type NotificationMarker = {
  "level": NotificationLevel;
  "notification": Id;
  "source"?: NotificationSource;
  "unread": boolean;
};

export type NotificationSource = "cli" | "terminal" | "agent" | "daemon";

export type NotifyResult = {
  "notification": Id;
};

export type Pane = (LivePane) | (DeadPane);

export type PaneDirection = "left" | "right" | "up" | "down";

export type PaneKind = "pty" | "browser";

export type PaneNeighborResult = {
  "pane": (Id) | null;
};

/** Opaque JSON: A pane named by its numeric id or its public pane_ id. */
export type PaneRef = JsonValue;

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
  /** Executable path or name of the PTY foreground process-group leader, read at request time. Null when the lookup fails; absent from daemons that predate the field. Clients treat absence as null. */
  "foreground_executable"?: (string) | null;
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

export type ReattachViewResult = {
  "participant": string;
  "state": SizeState;
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

export type RowHeight = {
  "height": bigint;
  "row": Id;
};

export type RowMarkerPoint = {
  "col": number;
  "row_marker": bigint;
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

export type SavedTabGroupMember = {
  /** kind terminal. */
  "cwd"?: (string) | null;
  /** kind browser. Known values: webkit, cef. */
  "engine"?: (string) | null;
  /** Known values: terminal (terminal_id, cwd, title) and browser (url, engine, profile_id, title). A member of another kind keeps its fields in the additional properties. */
  "kind": string;
  /** kind browser. */
  "profile_id"?: (string) | null;
  /** kind terminal. */
  "terminal_id"?: (string) | null;
  "title"?: (string) | null;
  /** kind browser. */
  "url"?: string;
  [key: string]: unknown;
};

export type SavedTabGroupRecord = {
  /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
  "color": string;
  "id": string;
  "members": Array<SavedTabGroupMember>;
  "name": string;
  /** The room whose bar shows the saved group (`default` for groups saved by these commands). */
  "room": string;
  "updated_at_ms": bigint;
  [key: string]: unknown;
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

export type ServerStatsConnections = {
  "accepted": bigint;
  "active": bigint;
  "limit": bigint;
  "peak": bigint;
  "refused": bigint;
};

export type ServerStatsHistogram = {
  "count": bigint;
  "max": bigint;
  "mean": bigint;
  "p50": bigint;
  "p90": bigint;
  "p99": bigint;
};

export type ServerStatsJournalWriter = {
  "batch_size": ServerStatsHistogram;
  "batches": bigint;
  "commit_failures": bigint;
  "commit_lock_wait_us": ServerStatsHistogram;
  "commit_us": ServerStatsHistogram;
  "deadline_expiries": bigint;
  "durable_events": bigint;
  "durable_queued": bigint;
  "phase": ServerStatsWriterPhase;
  "phase_for_us": bigint;
  "receipt_wait_us": ServerStatsHistogram;
  "terminal_events": bigint;
  "terminal_queued": bigint;
};

export type ServerStatsLockHolder = {
  "held_for_us": bigint;
  "site": string;
};

export type ServerStatsLockSite = {
  "acquisitions": bigint;
  "hold_max_us": bigint;
  "hold_total_us": bigint;
  "site": string;
};

export type ServerStatsLockStall = {
  "blocker": (string) | null;
  "waited_us": bigint;
  "waiter": string;
};

export type ServerStatsRegistryLock = {
  "contended_acquisitions": bigint;
  "hold_us": ServerStatsHistogram;
  "holder": (ServerStatsLockHolder) | null;
  "last_stall": (ServerStatsLockStall) | null;
  "stalls": bigint;
  "top_sites": Array<ServerStatsLockSite>;
  "wait_us": ServerStatsHistogram;
};

export type ServerStatsResult = {
  "connections": ServerStatsConnections;
  "journal_writer": (ServerStatsJournalWriter) | null;
  "registry_lock": ServerStatsRegistryLock;
  "schema": number;
  "uptime_ms": bigint;
};

export type ServerStatsWriterPhase = "idle" | "waiting_lock" | "committing";

export type SetCellPixelsResult = {
  "failures": Array<CellPixelFailure>;
  "resizes": Array<CellPixelResize>;
};

export type SetSizeCountsResult = {
  "changed"?: boolean;
  "outcome": ViewAttachmentOutcome;
  "participant"?: string;
};

export type SetSizePolicyResult = {
  "state"?: SizeState;
};

export type SetTerminalIdlePolicyResult = {
  "idle_close_seconds": (bigint) | null;
  "terminal_id": string;
};

export type SetTerminalKeepResult = {
  "keep": boolean;
  "terminal_id": string;
};

export type ShutdownDaemonResult = {
  "accepted": true;
  "ended_terminals"?: (bigint) | null;
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

export type SizeDetachActor = {
  "device_name"?: (string) | null;
  "display_name"?: (string) | null;
  "user_id"?: (string) | null;
};

export type SizeDeviceKind = "mac" | "iphone" | "ipad" | "tui" | "browser" | "unknown";

export type SizeMode = "latest" | "smallest" | "largest" | "priority" | "fixed";

export type SizeParticipant = {
  "counts": boolean;
  "counts_override": (boolean) | null;
  "device_id": (string) | null;
  "device_kind": SizeDeviceKind;
  "device_name": (string) | null;
  "display_name": (string) | null;
  "id": string;
  "priority_key": string;
  "user_id": (string) | null;
  "via": (string) | null;
  "viewport": (Size) | null;
};

export type SizePolicy = {
  "fixed"?: (Size) | null;
  "mode"?: SizeMode;
  "priority"?: Array<string>;
};

export type SizeReason = "latest" | "smallest" | "largest" | "priority" | "fixed" | "held" | "priority-fallback";

export type SizeState = {
  "cols": number;
  "generation": bigint;
  "owners": Array<string>;
  "participants": Array<SizeParticipant>;
  "policy": SizePolicy;
  "reason": SizeReason;
  "rows": number;
};

export type SizingIdentity = {
  "device_id"?: (string) | null;
  "device_kind"?: (string) | null;
  "device_name"?: (string) | null;
  "display_name"?: (string) | null;
  "user_id"?: (string) | null;
};

export type SnapshotRequestHave = {
  "generation"?: (bigint) | null;
  "offset"?: (bigint) | null;
  "snapshot_version"?: (number) | null;
};

export type SnapshotRequestResult = {
  "reason"?: (string) | null;
  "request_id"?: (string) | null;
  "retry_after_ms"?: (bigint) | null;
  "status": "accepted" | "collapsed" | "snapshot_throttled";
  "surface": Id;
};

export type SplitDirection = "right" | "down";

export type SplitRespawn = {
  "cwd"?: (string) | null;
  "engine"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "kind": string;
  "profile_id"?: (string) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
  "url"?: (string) | null;
};

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
  "kind": "pty" | "browser" | "conversation";
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

export type TabGroupEndedTerminal = {
  "terminal_id": string;
  "terminal_incarnation": (string) | null;
  [key: string]: unknown;
};

export type TabGroupOutcome = {
  /** Null when the command left no group. */
  "group": (TabGroupRecord) | null;
  "pane": (Id) | null;
  /** Members in strip order. */
  "surfaces": Array<Id>;
  /** The workspace of the group's pane. */
  "workspace": (Id) | null;
  [key: string]: unknown;
};

export type TabGroupRecord = {
  "collapsed": boolean;
  /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
  "color": string;
  "id": string;
  /** May be empty: the group shows only its color. */
  "name": string;
  /** The linked saved group. */
  "saved_id": (string) | null;
  [key: string]: unknown;
};

export type TabGroupRun = {
  "collapsed": boolean;
  /** Known values: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other values are future colors. */
  "color": string;
  "count": bigint;
  "id": string;
  "name": string;
  "pane"?: Id;
  "saved_id": (string) | null;
  /** Strip index of the first member. */
  "start": bigint;
  "surfaces": Array<Id>;
  [key: string]: unknown;
};

/** Opaque JSON: A tab named by its numeric surface id or its public tab_ id. */
export type TabRef = JsonValue;

export type TerminalClipboardHost = {
  "kind": TerminalClipboardHostKind;
  "name"?: string;
};

export type TerminalClipboardHostKind = "local" | "remote" | "cloud";

export type TerminalClipboardLocation = "standard" | "selection" | "primary";

export type TerminalClipboardReplyResult = {
  "accepted": boolean;
  "granted": boolean;
};

export type TerminalClipboardSubscribeResult = {
  "clipboard_read_ready": boolean;
};

export type TerminalColorOverrides = {
  "bg": (ColorHex) | null;
  "cursor": (ColorHex) | null;
  "fg": (ColorHex) | null;
};

export type TerminalColors = {
  "bg": (ColorHex) | null;
  "cursor"?: (ColorHex) | null;
  "cursor_blink"?: (boolean) | null;
  "cursor_style"?: (CursorStyle) | null;
  "fg": (ColorHex) | null;
  "overrides"?: TerminalColorOverrides;
  "palette"?: Record<string, ColorHex>;
  "selection_bg": (ColorHex) | null;
  "selection_fg": (ColorHex) | null;
};

export type TerminalCommandHistoryResult = {
  "enabled": boolean;
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

export type TerminalHistoryPage = {
  "data": string;
  "marker": bigint;
  "rows": number;
};

export type TerminalHistoryPagesResult = {
  "done": boolean;
  "marker_epoch": bigint;
  "next_before"?: (bigint) | null;
  "pages": Array<TerminalHistoryPage>;
  "snapshot_version": number;
  "surface": Id;
};

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

export type TerminalReadRangeResult = {
  "surface": Id;
  "text": string;
  "truncated": boolean;
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

export type TerminalResourceHost = {
  "cpu_ns": bigint;
  "memory_bytes": bigint;
  "pid": number;
};

export type TerminalResourceProcess = {
  "cpu_ns": bigint;
  "memory_bytes": bigint;
  "name": string;
  "pid": number;
  "ppid": number;
};

export type TerminalResources = {
  "host": (TerminalResourceHost) | null;
  "pid": (number) | null;
  "processes": Array<TerminalResourceProcess>;
  "surface": Id;
  "terminal_id": (string) | null;
  "truncated": boolean;
};

export type TerminalResourcesResult = {
  "missing": Array<Id>;
  "sampled_at_ns": bigint;
  "terminals": Array<TerminalResources>;
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
