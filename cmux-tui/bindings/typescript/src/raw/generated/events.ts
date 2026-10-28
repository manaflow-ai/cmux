/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR d60b4d9a4e2b29ec10b92b01dff8f04e076911755afc8c218f2d85410be831e3. */


import type * as T from "./types.js";

/** Protocol v12; emission: emitted; streams: control. */
export type ActivityChangedEvent = { event: "activity-changed" } & {
  "activity": T.ActivitySnapshot;
};

/** Protocol v11; emission: emitted; streams: subscribe. */
export type AgentChangedEvent = { event: "agent-changed" } & {
  /** Adapter identity when the producer knows it; absent from protocol-11 event senders and null when no adapter was identified. */
  "agent"?: (string) | null;
  /** The harness's own session id that the agent's hooks reported (`claude`, `codex` session ids), checked to `[A-Za-z0-9._:-]` and at most 256 bytes; null when no hook reported one or it isn't portable (a session-less adapter's local token). Hook reports keep `session` for a human label, so clients find a terminal's agent session by this. */
  "agent_session_id"?: (string) | null;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  /** The terminal agent's last prompt (at most 200 characters), kept in daemon memory only: never journaled or persisted; null when none since the agent started or the daemon restarted. */
  "last_prompt"?: (string) | null;
  "session": (string) | null;
  /** When the agent entered `state` (Unix ms). A report that keeps the state keeps it; after a daemon restart it is the last report's time. Absent from older senders: use `updated_at_ms`. */
  "since_ms"?: bigint;
  "source": T.AgentSource;
  "state": T.AgentState;
  "surface": T.Id;
  "updated_at_ms": bigint;
};

/** Protocol v12; emission: emitted; streams: control. */
export type AgentInventoryChangedEvent = { event: "agent-inventory-changed" } & {
  "machine": string;
  "revision": bigint;
  "watch_id": string;
};

/** Protocol v12; emission: emitted; streams: control. */
export type AgentInventoryWatchEndedEvent = { event: "agent-inventory-watch-ended" } & {
  "machine": string;
  "reason": string;
  "watch_id": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type AgentPresenceChangedEvent = { event: "agent-presence-changed" } & {
  /** What the agent is doing now; null clears the surface's presence and every other field is then null. */
  "activity": (T.AgentPresenceActivity) | null;
  /** Adapter identity (claude, codex, ...). */
  "agent": (string) | null;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  /** The 1-based line the tool call targets, when the tool input names one. */
  "line": (bigint) | null;
  /** The file the tool call targets, when the tool input names one. */
  "path": (string) | null;
  /** The agent's portable session id, a stable identity for colour. */
  "session": (string) | null;
  "surface": T.Id;
  /** The native tool name of the current or last tool call. */
  "tool": (string) | null;
  /** When the hook observed the event; null on clear. */
  "updated_at_ms": (bigint) | null;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type BellEvent = { event: "bell" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "surface": T.Id;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type BookmarksChangedEvent = { event: "bookmarks-changed" } & {
  "bookmarks_revision": bigint;
  "browser_profile_id": string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ChiefChangedEvent = { event: "chief-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "change": "created" | "updated" | "deleted";
  "chief": string;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientAttachedEvent = { event: "client-attached" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "client": bigint;
  "kind": (string) | null;
  "name": (string) | null;
  "transport": "unix" | "ws";
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientChangedEvent = { event: "client-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "client": bigint;
  "kind": (string) | null;
  "name": (string) | null;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ClientDetachedEvent = { event: "client-detached" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "client": bigint;
};

/** Protocol v9; emission: serialized-never-emitted; streams: subscribe. */
export type ClientListInvalidatedEvent = { event: "client-list-invalidated" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudConversationChangedEvent = { event: "cloud-conversation-changed" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "change": (T.JsonValue) | null;
  "conversation": string;
  "rev": bigint;
  "seq": bigint;
  "transaction": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudConversationLiveEvent = { event: "cloud-conversation-live" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "frame": (T.JsonValue) | null;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudConversationResyncedEvent = { event: "cloud-conversation-resynced" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "messages": (T.JsonValue) | null;
  "rev": bigint;
  "seq": bigint;
  "summary": (T.JsonValue) | null;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudConversationRunChangedEvent = { event: "cloud-conversation-run-changed" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "run": (T.JsonValue) | null;
  "steps": Array<T.JsonValue>;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudConversationTypingEvent = { event: "cloud-conversation-typing" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "on": boolean;
  "participant": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudHostReplicaNeededEvent = { event: "cloud-host-replica-needed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "expires_at"?: (bigint) | null;
  "reason": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudInboxChangedEvent = { event: "cloud-inbox-changed" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "entries": (T.JsonValue) | null;
  "seq": bigint;
  "transaction": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudInboxResetEvent = { event: "cloud-inbox-reset" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "seq": bigint;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudMuxResyncedEvent = { event: "cloud-mux-resynced" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "pending": (T.JsonValue) | null;
  "seq": bigint;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudMuxWakeEvent = { event: "cloud-mux-wake" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "seq": bigint;
  "wakes": (T.JsonValue) | null;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudSessionNeededEvent = { event: "cloud-session-needed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "expires_at"?: (bigint) | null;
  "reason": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type CloudSubscriptionStateEvent = { event: "cloud-subscription-state" } & {
  "account"?: string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation"?: (string) | null;
  "reason"?: (string) | null;
  "scope": string;
  "state": string;
};

/** Protocol v6; emission: emitted; streams: attach-byte. */
export type ColorsChangedEvent = { event: "colors-changed" } & {
  "bg": (T.ColorHex) | null;
  "cursor"?: (T.ColorHex) | null;
  "cursor_blink"?: (boolean) | null;
  "cursor_style"?: (T.CursorStyle) | null;
  "fg": (T.ColorHex) | null;
  "overrides"?: T.TerminalColorOverrides;
  "palette"?: Record<string, T.ColorHex>;
  "selection_bg": (T.ColorHex) | null;
  "selection_fg": (T.ColorHex) | null;
  "surface"?: T.Id;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type ConfigReloadRequestedEvent = { event: "config-reload-requested" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationChangedEvent = { event: "conversation-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "change": (T.JsonValue) | null;
  "conversation": string;
  "rev": bigint;
  "transaction": (string) | null;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationDraftEvent = { event: "conversation-draft" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "item": T.JsonValue;
  "participant": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationInboxChangedEvent = { event: "conversation-inbox-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "marked_unread": boolean;
  "participant": string;
  "pin_position"?: bigint;
  "pinned": boolean;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationLiveEvent = { event: "conversation-live" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "frame": (T.JsonValue) | null;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationRunChangedEvent = { event: "conversation-run-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "run": (T.JsonValue) | null;
  "steps": Array<T.JsonValue>;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ConversationTypingEvent = { event: "conversation-typing" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "conversation": string;
  "on": boolean;
  "participant": string;
};

/** Protocol v12; emission: emitted; streams: control. */
export type DaemonShutdownEvent = { event: "daemon-shutdown" } & {
};

/** Protocol v5; emission: emitted; streams: attach-byte, attach-render, attach-browser. */
export type DetachedEvent = { event: "detached" } & {
  "by"?: T.SizeDetachActor;
  "reason"?: T.DetachReason;
  "scope"?: string;
  "surface": T.Id;
  "view"?: string;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type EmptyEvent = { event: "empty" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "cell_height"?: number;
  "cell_width"?: number;
  "error"?: string;
  "kind": "kitty-image-budget-worker-start-failed" | "kitty-image-budget-update-failed" | "cell-pixel-update-retries-exhausted";
  "remaining"?: bigint;
  "retry_exhausted"?: boolean;
  "summary"?: string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type HistoryChangedEvent = { event: "history-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "kinds": Array<string>;
  "revision": bigint;
};

/** Protocol v12; emission: emitted; streams: attach-byte. */
export type InputFailedEvent = { event: "input-failed" } & {
  "bytes": bigint;
  "reason": "terminal_ended" | "not_a_terminal" | "write_failed" | "daemon_handoff" | "overflow" | "attach_failed";
  /** The attach stream the INPUT frame named; the stream's tag, as on every item of an attach stream. */
  "stream": number;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type KeybindingsChangedEvent = { event: "keybindings-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "origin": "user" | "cli" | "mcp" | "script" | "remote" | "app" | "file";
  "revision": bigint;
};

/** Protocol v6; emission: emitted; streams: subscribe. */
export type LayoutChangedEvent = { event: "layout-changed" } & {
  "active_pane"?: T.Id;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "layout"?: T.Layout;
  "screen": T.Id;
  "transaction"?: string;
  "workspace"?: T.Id;
  "zoomed_pane"?: (T.Id) | null;
};

/** Protocol v12; emission: emitted; streams: control. */
export type LoopbackClosedEvent = { event: "loopback-closed" } & {
  "error"?: string;
  "stream": bigint;
};

/** Protocol v12; emission: emitted; streams: control. */
export type LoopbackCreditEvent = { event: "loopback-credit" } & {
  "bytes": bigint;
  "stream": bigint;
};

/** Protocol v12; emission: emitted; streams: control. */
export type LoopbackDataEvent = { event: "loopback-data" } & {
  "data": string;
  "stream": bigint;
};

/** Protocol v12; emission: emitted; streams: control. */
export type LoopbackEofEvent = { event: "loopback-eof" } & {
  "stream": bigint;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type MachineUsageChangedEvent = { event: "machine-usage-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "usage": (T.MachineUsage) | null;
};

/** Protocol v6; emission: emitted; streams: subscribe, attach-byte, attach-browser. */
export type NotificationEvent = { event: "notification" } & {
  "body": string;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "desktop"?: boolean;
  "level": T.NotificationLevel;
  "notification": T.Id;
  "reply"?: boolean;
  "source"?: T.NotificationSource;
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
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "code": string;
  "expires_in": bigint;
  "peer": string;
  "request": bigint;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type PairingResolvedEvent = { event: "pairing-resolved" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ParticipantAvatarChangedEvent = { event: "participant-avatar-changed" } & {
  "avatar": (T.JsonValue) | null;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "participant": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type PersonalChangedEvent = { event: "personal-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "personal_revision": bigint;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ProgramStatusChangedEvent = { event: "program-status-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "program_status": (T.ShownProgramStatus) | null;
  "surface": T.Id;
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

/** Protocol v12; emission: emitted; streams: subscribe-deltas. */
export type ScreenChangedEvent = { event: "screen-changed" } & {
  "entity": T.Screen;
  "index"?: (bigint) | null;
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

/** Protocol v12; emission: emitted; streams: control. */
export type ScriptLogEvent = { event: "script-log" } & {
  /** The console method that wrote the line (log, info, warn, error, debug). */
  "level": string;
  /** The line, its arguments joined as the console prints them. */
  "message": string;
  /** The id of the script-run that wrote the line; absent for a REPL session's line. */
  "request"?: T.JsonValue;
  /** The REPL session (script-repl-open) whose cell wrote the line; absent for a script-run's line. */
  "session"?: string;
};

/** Protocol v6; emission: emitted; streams: subscribe, attach-byte, attach-render, attach-browser. */
export type ScrollChangedEvent = { event: "scroll-changed" } & {
  "at_bottom": boolean;
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "offset": bigint;
  "surface": T.Id;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type ServerDiagnosticSiteEvent = { event: "server-diagnostic-site" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  /** Blocking and inversion: the crate of the call site without its version, or other. Never a path. */
  "crate"?: string;
  /** blocking: a blocking call where blocking is disallowed (or a work item's wait for other work); inversion: a wait on work of lower QoS; hang: a request method that ran past the 250 ms watchdog threshold, or a holder-link frame or a journal commit past its hang tier. */
  "family": "blocking" | "inversion" | "hang";
  /** Blocking and inversion: 16 hex digits, FNV-1a of the file's path from the crate folder on. Never a path. */
  "file_hash"?: string;
  /** The blocking kind (cmux_threads BlockingKind names: fs, sleep, recv, priority-inversion, ...), or for a hang its scope: request, holder-link or journal-writer. */
  "kind": string;
  /** Blocking: a work item's wait for other work. */
  "lane_sync"?: boolean;
  /** Blocking and inversion: the call site's line. */
  "line"?: number;
  /** Hang: what ran: the request's command or v2 operation name (a colon written as a dot), the holder frame kind (data, exit, ...) or commit-batch. */
  "method"?: string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type SettingsChangedEvent = { event: "settings-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "keys": Array<string>;
  "origin": "user" | "cli" | "mcp" | "script" | "remote" | "app" | "file";
  "revision": bigint;
};

/** Protocol v12; emission: emitted; streams: subscribe, attach-byte, attach-render. */
export type SizeStateEvent = { event: "size-state" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "self_participant"?: string;
  "state": T.SizeState;
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type StatusEvent = { event: "status" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "message": string;
};

/** Protocol v12; emission: emitted; streams: attach-byte, attach-render, attach-browser. */
export type StreamEndEvent = { event: "stream-end" } & {
  "reason": "canceled" | "detached" | "overflow" | "attach_failed";
  "stream": number;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceExitedEvent = { event: "surface-exited" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceOutputEvent = { event: "surface-output" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "surface": T.Id;
};

/** Protocol v7; emission: emitted; streams: subscribe. */
export type SurfaceResizeFailedEvent = { event: "surface-resize-failed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "cols": number;
  "error": string;
  "reservation_id": (bigint) | null;
  "retry_after_ms": (bigint) | null;
  "rows": number;
  "surface": T.Id;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type SurfaceResizedEvent = { event: "surface-resized" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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

/** Protocol v12; emission: emitted; streams: subscribe-deltas. */
export type TabChangedEvent = { event: "tab-changed" } & {
  "entity": T.Tab;
  "index"?: (bigint) | null;
  "pane": T.Id;
  "screen": T.Id;
  "surface": T.Id;
  "transaction"?: (string) | null;
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

/** Protocol v12; emission: emitted; streams: control. */
export type TerminalClipboardReadEvent = { event: "terminal-clipboard-read" } & {
  "host": T.TerminalClipboardHost;
  "location": T.TerminalClipboardLocation;
  "request_id": string;
  "terminal_id": string;
};

/** Protocol v12; emission: emitted; streams: control. */
export type TerminalClipboardReadCancelledEvent = { event: "terminal-clipboard-read-cancelled" } & {
  "request_id": string;
};

/** Protocol v12; emission: emitted; streams: control. */
export type TerminalInputUnclaimedEvent = { event: "terminal-input-unclaimed" } & {
  "bytes_base64": T.Base64;
  "reason": string;
  "terminal_id": string;
};

/** Protocol v12; emission: emitted; streams: subscribe. */
export type TerminalReapedEvent = { event: "terminal-reaped" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "grace_ms": bigint;
  "terminal": (string) | null;
  "terminal_id": string;
};

/** Protocol v9; emission: emitted; streams: subscribe. */
export type TerminalRegistryChangedEvent = { event: "terminal-registry-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "generation": string;
  "refetch": "terminal-events-or-list-terminals";
  "registry_id": string;
  "terminal_revision": bigint;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type TitleChangedEvent = { event: "title-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
  "surface": T.Id;
  "title"?: string;
};

/** Protocol v5; emission: emitted; streams: subscribe. */
export type TreeChangedEvent = { event: "tree-changed" } & {
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
};

/** Protocol v12; emission: emitted; streams: control. */
export type UrlOpenEvent = { event: "url-open" } & {
  "request_id": string;
  "terminal_id": string;
  "url": string;
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
  /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
  "cause"?: T.EventCause;
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

/** Protocol v12; emission: emitted; streams: subscribe-deltas. */
export type WorkspaceChangedEvent = { event: "workspace-changed" } & {
  "entity": T.Workspace;
  "generation": string;
  "index"?: (bigint) | null;
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
  | ActivityChangedEvent
  | AgentChangedEvent
  | AgentInventoryChangedEvent
  | AgentInventoryWatchEndedEvent
  | AgentPresenceChangedEvent
  | BellEvent
  | BookmarksChangedEvent
  | BrowserStateEvent
  | ChiefChangedEvent
  | ClientAttachedEvent
  | ClientChangedEvent
  | ClientDetachedEvent
  | CloudConversationChangedEvent
  | CloudConversationLiveEvent
  | CloudConversationResyncedEvent
  | CloudConversationRunChangedEvent
  | CloudConversationTypingEvent
  | CloudHostReplicaNeededEvent
  | CloudInboxChangedEvent
  | CloudInboxResetEvent
  | CloudMuxResyncedEvent
  | CloudMuxWakeEvent
  | CloudSessionNeededEvent
  | CloudSubscriptionStateEvent
  | ColorsChangedEvent
  | ConfigReloadRequestedEvent
  | ConversationChangedEvent
  | ConversationDraftEvent
  | ConversationInboxChangedEvent
  | ConversationLiveEvent
  | ConversationRunChangedEvent
  | ConversationTypingEvent
  | DaemonShutdownEvent
  | DetachedEvent
  | EmptyEvent
  | FrameEvent
  | FrontendProjectionChangedEvent
  | GraphicsStatusEvent
  | HistoryChangedEvent
  | InputFailedEvent
  | KeybindingsChangedEvent
  | LayoutChangedEvent
  | LoopbackClosedEvent
  | LoopbackCreditEvent
  | LoopbackDataEvent
  | LoopbackEofEvent
  | MachineUsageChangedEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | PairingRequestedEvent
  | PairingResolvedEvent
  | PaneAddedEvent
  | PaneClosedEvent
  | ParticipantAvatarChangedEvent
  | PersonalChangedEvent
  | ProgramStatusChangedEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ResizedEvent
  | ScreenAddedEvent
  | ScreenChangedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | ScriptLogEvent
  | ScrollChangedEvent
  | ServerDiagnosticSiteEvent
  | SettingsChangedEvent
  | SizeStateEvent
  | StatusEvent
  | StreamEndEvent
  | SurfaceExitedEvent
  | SurfaceOutputEvent
  | SurfaceResizeFailedEvent
  | SurfaceResizedEvent
  | TabAddedEvent
  | TabChangedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | TerminalClipboardReadEvent
  | TerminalClipboardReadCancelledEvent
  | TerminalInputUnclaimedEvent
  | TerminalReapedEvent
  | TerminalRegistryChangedEvent
  | TitleChangedEvent
  | TreeChangedEvent
  | UrlOpenEvent
  | VtStateEvent
  | WindowTitleRequestedEvent
  | WorkspaceAddedEvent
  | WorkspaceChangedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Shapes serialized by runtime code but excluded from active event unions. */
export type SerializedButNotEmittedEvent =
  | ClientListInvalidatedEvent;

/** Known subscribe stream events. */
export type KnownSubscribeEvent =
  | AgentChangedEvent
  | AgentPresenceChangedEvent
  | BellEvent
  | BookmarksChangedEvent
  | ChiefChangedEvent
  | ClientAttachedEvent
  | ClientChangedEvent
  | ClientDetachedEvent
  | CloudConversationChangedEvent
  | CloudConversationLiveEvent
  | CloudConversationResyncedEvent
  | CloudConversationRunChangedEvent
  | CloudConversationTypingEvent
  | CloudHostReplicaNeededEvent
  | CloudInboxChangedEvent
  | CloudInboxResetEvent
  | CloudMuxResyncedEvent
  | CloudMuxWakeEvent
  | CloudSessionNeededEvent
  | CloudSubscriptionStateEvent
  | ConfigReloadRequestedEvent
  | ConversationChangedEvent
  | ConversationDraftEvent
  | ConversationInboxChangedEvent
  | ConversationLiveEvent
  | ConversationRunChangedEvent
  | ConversationTypingEvent
  | EmptyEvent
  | FrontendProjectionChangedEvent
  | GraphicsStatusEvent
  | HistoryChangedEvent
  | KeybindingsChangedEvent
  | LayoutChangedEvent
  | MachineUsageChangedEvent
  | NotificationEvent
  | OverflowEvent
  | PairingRequestedEvent
  | PairingResolvedEvent
  | PaneAddedEvent
  | PaneClosedEvent
  | ParticipantAvatarChangedEvent
  | PersonalChangedEvent
  | ProgramStatusChangedEvent
  | ScreenAddedEvent
  | ScreenChangedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | ScrollChangedEvent
  | ServerDiagnosticSiteEvent
  | SettingsChangedEvent
  | SizeStateEvent
  | StatusEvent
  | SurfaceExitedEvent
  | SurfaceOutputEvent
  | SurfaceResizeFailedEvent
  | SurfaceResizedEvent
  | TabAddedEvent
  | TabChangedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | TerminalReapedEvent
  | TerminalRegistryChangedEvent
  | TitleChangedEvent
  | TreeChangedEvent
  | WindowTitleRequestedEvent
  | WorkspaceAddedEvent
  | WorkspaceChangedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Known delta-subscription events. */
export type TreeDeltaEvent =
  | PaneAddedEvent
  | PaneClosedEvent
  | ScreenAddedEvent
  | ScreenChangedEvent
  | ScreenClosedEvent
  | ScreenRenamedEvent
  | TabAddedEvent
  | TabChangedEvent
  | TabClosedEvent
  | TabRenamedEvent
  | WorkspaceAddedEvent
  | WorkspaceChangedEvent
  | WorkspaceClosedEvent
  | WorkspaceMovedEvent
  | WorkspaceRenamedEvent;

/** Known events from any attach mode. */
export type KnownAttachEvent =
  | BrowserStateEvent
  | ColorsChangedEvent
  | DetachedEvent
  | FrameEvent
  | InputFailedEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ResizedEvent
  | ScrollChangedEvent
  | SizeStateEvent
  | StreamEndEvent
  | VtStateEvent;

/** Known byte attach events. */
export type KnownByteAttachEvent =
  | ColorsChangedEvent
  | DetachedEvent
  | InputFailedEvent
  | NotificationEvent
  | OutputEvent
  | OverflowEvent
  | ResizedEvent
  | ScrollChangedEvent
  | SizeStateEvent
  | StreamEndEvent
  | VtStateEvent;

/** Known render attach events. */
export type KnownRenderAttachEvent =
  | DetachedEvent
  | OverflowEvent
  | RenderDeltaEvent
  | RenderStateEvent
  | ScrollChangedEvent
  | SizeStateEvent
  | StreamEndEvent;

/** Known browser attach events. */
export type KnownBrowserAttachEvent =
  | BrowserStateEvent
  | DetachedEvent
  | FrameEvent
  | NotificationEvent
  | OverflowEvent
  | ScrollChangedEvent
  | StreamEndEvent;

export type CmuxEvent = KnownCmuxEvent | UnknownEvent;
export type SubscribeEvent = KnownSubscribeEvent | UnknownEvent;
export type AttachEvent = KnownAttachEvent | UnknownEvent;
export type ByteAttachEvent = KnownByteAttachEvent | UnknownEvent;
export type RenderAttachEvent = KnownRenderAttachEvent | UnknownEvent;
export type BrowserAttachEvent = KnownBrowserAttachEvent | UnknownEvent;
