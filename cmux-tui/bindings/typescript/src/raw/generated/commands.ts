/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR c46f726ee9b8a780eb8c16644b79d6aac31855f718c671d1ee0304ad4bb34dfe. */


import type * as T from "./types.js";

export interface CmuxRequestBase {
  id?: T.JsonValue;
  cmd: string;
}

export interface CmuxSuccessResponse<D = T.JsonValue> {
  id?: T.JsonValue;
  ok: true;
  data: D;
}
export interface CmuxFailureResponse {
  id?: T.JsonValue;
  ok: false;
  error: string;
}
export type CmuxResponse<D = T.JsonValue> =
  | CmuxSuccessResponse<D>
  | CmuxFailureResponse;

/** Protocol v12; authority: control. */
export interface AckTabNotificationsRequest extends CmuxRequestBase {
  cmd: "ack-tab-notifications";
  "surface": T.Id;
}
export type AckTabNotificationsResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface AddScreensToScreenGroupRequest extends CmuxRequestBase {
  cmd: "add-screens-to-screen-group";
  "group": string;
  "index"?: (bigint) | null;
  "screens": Array<T.Id>;
}
export type AddScreensToScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface AddTabsToTabGroupRequest extends CmuxRequestBase {
  cmd: "add-tabs-to-tab-group";
  "group": string;
  "surfaces": Array<T.TabRef>;
  "transaction"?: (string) | null;
}
export type AddTabsToTabGroupResult = T.JsonValue;

/** Protocol v6; authority: control. */
export interface ApplyLayoutRequest extends CmuxRequestBase {
  cmd: "apply-layout";
  "cols"?: (number) | null;
  "layout": T.DeclarativeLayout;
  "name"?: (string) | null;
  "rows"?: (number) | null;
  "workspace"?: (T.Id) | null;
}

/** Protocol v5; authority: frontend. */
export interface AttachSurfaceRequest extends CmuxRequestBase {
  cmd: "attach-surface";
  "cols"?: (number) | null;
  "expected_generation"?: (string) | null;
  "expected_terminal_id"?: (string) | null;
  "mode"?: ("bytes" | "render") | null;
  "rows"?: (number) | null;
  "snapshot"?: (string) | null;
  "snapshot_local_history"?: boolean;
  "snapshot_version"?: (number) | null;
  "surface"?: (T.Id) | null;
  "viewer_backlog_bytes"?: (bigint) | null;
}
export type AttachSurfaceResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface BindConversationTabSessionRequest extends CmuxRequestBase {
  cmd: "bind-conversation-tab-session";
  /** The tab's current session, or null for a tab without one; the bind applies only when it matches. */
  "expected_session": (string) | null;
  "session": string;
  "surface": T.Id;
}
export type BindConversationTabSessionResult = {
  "conversation": T.ConversationTabRecord;
  "replayed": boolean;
  "surface": T.Id;
};

/** Protocol v6; authority: frontend. */
export interface BrowserActivateRequest extends CmuxRequestBase {
  cmd: "browser-activate";
  "surface": T.Id;
}
export type BrowserActivateResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserBackRequest extends CmuxRequestBase {
  cmd: "browser-back";
  "surface": T.Id;
}
export type BrowserBackResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserForwardRequest extends CmuxRequestBase {
  cmd: "browser-forward";
  "surface": T.Id;
}
export type BrowserForwardResult = T.EmptyResult;

/** Protocol v10; authority: frontend. */
export interface BrowserFramePresentedRequest extends CmuxRequestBase {
  cmd: "browser-frame-presented";
  "frame_seq": bigint;
  "surface": T.Id;
}
export type BrowserFramePresentedResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserInsertTextRequest extends CmuxRequestBase {
  cmd: "browser-insert-text";
  "surface": T.Id;
  "text": string;
}
export type BrowserInsertTextResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserKeyRequest extends CmuxRequestBase {
  cmd: "browser-key";
  "code": string;
  "key": string;
  "kind": "down" | "up";
  "modifiers": number;
  "surface": T.Id;
  "text"?: (string) | null;
  "windows_virtual_key_code": number;
}
export type BrowserKeyResult = T.EmptyResult;

/** Protocol v10; authority: frontend. */
export interface BrowserKeyPressRequest extends CmuxRequestBase {
  cmd: "browser-key-press";
  "code": string;
  "key": string;
  "modifiers": number;
  "surface": T.Id;
  "text"?: (string) | null;
  "windows_virtual_key_code": number;
}
export type BrowserKeyPressResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserMouseRequest extends CmuxRequestBase {
  cmd: "browser-mouse";
  "button"?: (string) | null;
  "click_count"?: (number) | null;
  "frame_seq"?: (bigint) | null;
  "kind": "down" | "up" | "move";
  "surface": T.Id;
  "x_px": number;
  "y_px": number;
}
export type BrowserMouseResult = T.EmptyResult;

/** Protocol v10; authority: frontend. */
export interface BrowserMouseGuardedRequest extends CmuxRequestBase {
  cmd: "browser-mouse-guarded";
  "button"?: (string) | null;
  "click_count"?: (number) | null;
  "frame_seq": bigint;
  "kind": "down" | "up" | "move";
  "surface": T.Id;
  "x_px": number;
  "y_px": number;
}
export type BrowserMouseGuardedResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserNavigateRequest extends CmuxRequestBase {
  cmd: "browser-navigate";
  "surface": T.Id;
  "url": string;
}
export type BrowserNavigateResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserReloadRequest extends CmuxRequestBase {
  cmd: "browser-reload";
  "surface": T.Id;
}
export type BrowserReloadResult = T.EmptyResult;

/** Protocol v6; authority: frontend. */
export interface BrowserWheelRequest extends CmuxRequestBase {
  cmd: "browser-wheel";
  "delta_y_px": number;
  "frame_seq"?: (bigint) | null;
  "surface": T.Id;
  "x_px": number;
  "y_px": number;
}
export type BrowserWheelResult = T.EmptyResult;

/** Protocol v10; authority: frontend. */
export interface BrowserWheelGuardedRequest extends CmuxRequestBase {
  cmd: "browser-wheel-guarded";
  "delta_y_px": number;
  "frame_seq": bigint;
  "surface": T.Id;
  "x_px": number;
  "y_px": number;
}
export type BrowserWheelGuardedResult = T.EmptyResult;

/** Protocol v9; authority: control. */
export interface ClearHistoryRequest extends CmuxRequestBase {
  cmd: "clear-history";
  "fallback_key"?: (T.TerminalKeyInput) | null;
  "surface": T.Id;
}
export type ClearHistoryResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface ClearWindowTitleRequest extends CmuxRequestBase {
  cmd: "clear-window-title";
}
export type ClearWindowTitleResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface ClientFocusRequest extends CmuxRequestBase {
  cmd: "client-focus";
  "client_id": string;
}
export type ClientFocusResult = {
  "pane": (T.Id) | null;
  "tab": (bigint) | null;
};

/** Protocol v5; authority: control. */
export interface ClosePaneRequest extends CmuxRequestBase {
  cmd: "close-pane";
  "end_terminals"?: boolean;
  "pane": T.Id;
}
export type ClosePaneResult = T.EmptyResult;

/** Protocol v9; authority: provider-authority. */
export interface CloseProviderManagedWorkspaceRequest extends CmuxRequestBase {
  cmd: "close-provider-managed-workspace";
  "authority": string;
  "key": string;
  "workspace": T.Id;
}
export type CloseProviderManagedWorkspaceResult = T.ProviderWorkspaceMutationResult;

/** Protocol v5; authority: control. */
export interface CloseScreenRequest extends CmuxRequestBase {
  cmd: "close-screen";
  "end_terminals"?: boolean;
  "screen": T.Id;
}
export type CloseScreenResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface CloseScreenGroupRequest extends CmuxRequestBase {
  cmd: "close-screen-group";
  "end_terminals"?: boolean;
  "group": string;
}
export type CloseScreenGroupResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface CloseSurfaceRequest extends CmuxRequestBase {
  cmd: "close-surface";
  "surface": T.Id;
}
export type CloseSurfaceResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface CloseTabGroupRequest extends CmuxRequestBase {
  cmd: "close-tab-group";
  "end_terminals"?: boolean;
  "group": string;
}
export type CloseTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CloseTabsRequest extends CmuxRequestBase {
  cmd: "close-tabs";
  "end_terminals"?: boolean;
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "surfaces": Array<T.TabRef>;
  "transaction"?: (string) | null;
}
export type CloseTabsResult = T.JsonValue;

/** Protocol v9; authority: control. */
export interface CloseTerminalRequest extends CmuxRequestBase {
  cmd: "close-terminal";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "terminal_id": string;
  "terminal_incarnation"?: (string) | null;
}

/** Protocol v5; authority: control. */
export interface CloseWorkspaceRequest extends CmuxRequestBase {
  cmd: "close-workspace";
  "end_terminals"?: boolean;
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type CloseWorkspaceResult = T.WorkspaceMutationResult;

/** Protocol v12; authority: local-admin. */
export interface ConversationAgentTokenRequest extends CmuxRequestBase {
  cmd: "conversation-agent-token";
  "participant": string;
}
export type ConversationAgentTokenResult = {
  "participant": string;
  "token": string;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationBindRequest extends CmuxRequestBase {
  cmd: "conversation-bind";
  "participant": string;
  "token": string;
}
export type ConversationBindResult = {
  "participant": string;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationCreateRequest extends CmuxRequestBase {
  cmd: "conversation-create";
  "actor"?: (string) | null;
  "idempotency_key": string;
  "participants": (T.JsonValue) | null;
  "title": string;
}
export type ConversationCreateResult = {
  "conversation": T.ConversationSummary;
  "replayed": boolean;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationHistoryRequest extends CmuxRequestBase {
  cmd: "conversation-history";
  "before_seq": bigint;
  "conversation": string;
  "limit": number;
}
export type ConversationHistoryResult = {
  "messages": Array<T.ConversationMessage>;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationListRequest extends CmuxRequestBase {
  cmd: "conversation-list";
}
export type ConversationListResult = {
  "conversations": Array<T.ConversationSummary>;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationOpRequest extends CmuxRequestBase {
  cmd: "conversation-op";
  "actor"?: (string) | null;
  "conversation": string;
  "idempotency_key": string;
  "op": (T.JsonValue) | null;
  "transaction"?: (string) | null;
}
export type ConversationOpResult = {
  "change": T.ConversationChange;
  "replayed": boolean;
  "rev": bigint;
  "seq"?: bigint;
  "transaction"?: string;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationSearchRequest extends CmuxRequestBase {
  cmd: "conversation-search";
  "limit": number;
  "query": string;
}
export type ConversationSearchResult = {
  "hits": Array<T.ConversationSearchHit>;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationSnapshotRequest extends CmuxRequestBase {
  cmd: "conversation-snapshot";
  "conversation": string;
  "tail": number;
}
export type ConversationSnapshotResult = {
  "conversation": T.ConversationSummary;
  "messages": Array<T.ConversationMessage>;
};

/** Protocol v12; authority: local-admin. */
export interface ConversationTypingRequest extends CmuxRequestBase {
  cmd: "conversation-typing";
  "actor"?: (string) | null;
  "conversation": string;
  "on": boolean;
}
export type ConversationTypingResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface CopyRequest extends CmuxRequestBase {
  cmd: "copy";
  "mode": "screen" | "selection" | "scrollback";
  "surface": T.Id;
}

/** Protocol v12; authority: control. */
export interface CreateBookmarkRequest extends CmuxRequestBase {
  cmd: "create-bookmark";
  "bookmark"?: (string) | null;
  "browser_profile_id": string;
  "created_ms"?: (bigint) | null;
  "favicon_key"?: (string) | null;
  "index"?: (bigint) | null;
  "kind": string;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "parent": string;
  "source_key"?: (string) | null;
  "title": string;
  "url"?: (string) | null;
}
export type CreateBookmarkResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CreateBrowserProfileRequest extends CmuxRequestBase {
  cmd: "create-browser-profile";
  "browser_profile"?: (string) | null;
  "color"?: (string) | null;
  "icon"?: (string) | null;
  "index"?: (bigint) | null;
  "name": string;
  "source"?: (T.JsonValue) | null;
}
export type CreateBrowserProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CreatePersonalGroupRequest extends CmuxRequestBase {
  cmd: "create-personal-group";
  "collapsed"?: boolean;
  "color"?: (string) | null;
  "group"?: (string) | null;
  "index"?: (bigint) | null;
  "name": string;
  "profile"?: (string) | null;
}
export type CreatePersonalGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CreateProfileRequest extends CmuxRequestBase {
  cmd: "create-profile";
  "browser_profile_id"?: (string) | null;
  "color"?: (string) | null;
  "default_session_id"?: (string) | null;
  "defaults"?: (T.JsonValue) | null;
  "follows"?: (Array<string>) | null;
  "icon"?: (string) | null;
  "index"?: (bigint) | null;
  "name": string;
  "profile"?: (string) | null;
  "theme"?: (string) | null;
}
export type CreateProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CreateScreenGroupRequest extends CmuxRequestBase {
  cmd: "create-screen-group";
  "color"?: (string) | null;
  "name"?: (string) | null;
  "screens": Array<T.Id>;
}
export type CreateScreenGroupResult = T.JsonValue;

/** Protocol v10; authority: control. */
export interface CreateSurfaceWithReceiptRequest extends CmuxRequestBase {
  cmd: "create-surface-with-receipt";
  "argv"?: (Array<string>) | null;
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "idempotency_key"?: (string) | null;
  "operation": string;
  "origin": string;
  "pane"?: (T.Id) | null;
  "receipt": string;
  "rows"?: (number) | null;
  "selector_fallbacks"?: Array<T.ResourceSelectors>;
  "selectors"?: (T.ResourceSelectors) | null;
  "url"?: (string) | null;
  "width"?: (number) | null;
  "workspace"?: (T.Id) | null;
}
export type CreateSurfaceWithReceiptResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface CreateTabGroupRequest extends CmuxRequestBase {
  cmd: "create-tab-group";
  "color"?: (string) | null;
  "group"?: (string) | null;
  "name"?: (string) | null;
  "surfaces": Array<T.TabRef>;
  "transaction"?: (string) | null;
}
export type CreateTabGroupResult = T.JsonValue;

/** Protocol v7; authority: control. */
export interface CreateTerminalRequest extends CmuxRequestBase {
  cmd: "create-terminal";
  "argv"?: (Array<string>) | null;
  "cols"?: (number) | null;
  "command"?: (string) | null;
  "cwd"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "keep"?: boolean;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "name"?: (string) | null;
  "origin"?: (string) | null;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type CreateTerminalResult = T.TerminalPlacement;

/** Protocol v7; authority: control. */
export interface CreateWorkspaceRequest extends CmuxRequestBase {
  cmd: "create-workspace";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "name"?: (string) | null;
  "origin"?: (string) | null;
}
export type CreateWorkspaceResult = T.WorkspaceMutationResult;

/** Protocol v12; authority: control. */
export interface CreateWorkspaceGroupRequest extends CmuxRequestBase {
  cmd: "create-workspace-group";
  "collapsed"?: boolean;
  "color"?: (string) | null;
  "group"?: (string) | null;
  "index"?: (bigint) | null;
  "name": string;
}
export type CreateWorkspaceGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteBookmarkRequest extends CmuxRequestBase {
  cmd: "delete-bookmark";
  "bookmark": string;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
}
export type DeleteBookmarkResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteBrowserProfileRequest extends CmuxRequestBase {
  cmd: "delete-browser-profile";
  "browser_profile": string;
}
export type DeleteBrowserProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeletePersonalGroupRequest extends CmuxRequestBase {
  cmd: "delete-personal-group";
  "group": string;
}
export type DeletePersonalGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteProfileRequest extends CmuxRequestBase {
  cmd: "delete-profile";
  "move_to"?: (string) | null;
  "profile": string;
}
export type DeleteProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteSavedScreenGroupRequest extends CmuxRequestBase {
  cmd: "delete-saved-screen-group";
  "saved": string;
}
export type DeleteSavedScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteSavedTabGroupRequest extends CmuxRequestBase {
  cmd: "delete-saved-tab-group";
  "saved": string;
}
export type DeleteSavedTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface DeleteWorkspaceGroupRequest extends CmuxRequestBase {
  cmd: "delete-workspace-group";
  "group": string;
}
export type DeleteWorkspaceGroupResult = T.JsonValue;

/** Protocol v10; authority: frontend. */
export interface DetachAttachedViewRequest extends CmuxRequestBase {
  cmd: "detach-attached-view";
  "lease"?: (string) | null;
  "surface": T.Id;
  "view"?: (string) | null;
}
export type DetachAttachedViewResult = T.AttachedViewOutcomeResult;

/** Protocol v6; authority: control. */
export interface DetachClientRequest extends CmuxRequestBase {
  cmd: "detach-client";
  "by"?: (T.SizeDetachActor) | null;
  "client": T.DetachClientTarget;
  "surface"?: (T.Id) | null;
}
export type DetachClientResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface ExportLayoutRequest extends CmuxRequestBase {
  cmd: "export-layout";
  "screen"?: (T.Id) | null;
}

/** Protocol v6; authority: control. */
export interface FocusDirectionRequest extends CmuxRequestBase {
  cmd: "focus-direction";
  "dir": T.PaneDirection;
  "pane"?: (T.Id) | null;
}

/** Protocol v5; authority: control. */
export interface FocusPaneRequest extends CmuxRequestBase {
  cmd: "focus-pane";
  "pane": T.Id;
}
export type FocusPaneResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface ForgetSessionRequest extends CmuxRequestBase {
  cmd: "forget-session";
  "force"?: boolean;
  "session_id": string;
}
export type ForgetSessionResult = T.JsonValue;

/** Protocol v10; authority: local-admin. */
export interface GetBrowserProviderRequest extends CmuxRequestBase {
  cmd: "get-browser-provider";
}
export type GetBrowserProviderResult = T.BrowserProviderSnapshot;

/** Protocol v6; authority: frontend. */
export interface GetCellPixelsRequest extends CmuxRequestBase {
  cmd: "get-cell-pixels";
}

/** Protocol v12; authority: control. */
export interface GetFrontendBrowserHistoryRequest extends CmuxRequestBase {
  cmd: "get-frontend-browser-history";
  "surface": T.Id;
}
export type GetFrontendBrowserHistoryResult = T.JsonValue;

/** Protocol v7; authority: control. */
export interface GetFrontendProjectionRequest extends CmuxRequestBase {
  cmd: "get-frontend-projection";
  "frontend": string;
  "scope": string;
  "subject_key": string;
}
export type GetFrontendProjectionResult = T.FrontendProjection;

/** Protocol v12; authority: control. */
export interface GetSizeStateRequest extends CmuxRequestBase {
  cmd: "get-size-state";
  "surface": T.Id;
}

/** Protocol v5; authority: control. */
export interface IdentifyRequest extends CmuxRequestBase {
  cmd: "identify";
}

/** Protocol v6; authority: control. */
export interface IdsRequest extends CmuxRequestBase {
  cmd: "ids";
  "kind"?: ("workspace" | "screen" | "pane" | "surface") | null;
}

/** Protocol v12; authority: control. */
export interface ImportBookmarksRequest extends CmuxRequestBase {
  cmd: "import-bookmarks";
  "browser_profile_id": string;
  "index"?: (bigint) | null;
  "mutation_id"?: (string) | null;
  "nodes": Array<T.JsonValue>;
  "origin"?: (string) | null;
  "parent": string;
  "replace"?: boolean;
  "source_key"?: (string) | null;
}
export type ImportBookmarksResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ImportSessionOrganizationRequest extends CmuxRequestBase {
  cmd: "import-session-organization";
  "groups"?: Array<T.JsonValue>;
  "session_id": string;
  "workspaces"?: Array<T.JsonValue>;
}
export type ImportSessionOrganizationResult = T.JsonValue;

/** Protocol v10; authority: control. */
export interface JournalFrontendEventRequest extends CmuxRequestBase {
  cmd: "journal-frontend-event";
  "event": T.FrontendJournalEvent;
}
export type JournalFrontendEventResult = {
  "committed": true;
};

/** Protocol v6; authority: control. */
export interface ListAgentsRequest extends CmuxRequestBase {
  cmd: "list-agents";
  "state"?: (T.AgentState) | null;
  "surface"?: (T.Id) | null;
}

/** Protocol v12; authority: control. */
export interface ListBookmarksRequest extends CmuxRequestBase {
  cmd: "list-bookmarks";
  "browser_profile_id": string;
}
export type ListBookmarksResult = T.JsonValue;

/** Protocol v6; authority: control. */
export interface ListClientsRequest extends CmuxRequestBase {
  cmd: "list-clients";
}
export type ListClientsResult = Array<T.ClientInfo>;

/** Protocol v12; authority: control. */
export interface ListNotificationsRequest extends CmuxRequestBase {
  cmd: "list-notifications";
  "limit"?: (bigint) | null;
}
export type ListNotificationsResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ListPersonalRequest extends CmuxRequestBase {
  cmd: "list-personal";
}
export type ListPersonalResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ListSavedScreenGroupsRequest extends CmuxRequestBase {
  cmd: "list-saved-screen-groups";
}
export type ListSavedScreenGroupsResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ListSavedTabGroupsRequest extends CmuxRequestBase {
  cmd: "list-saved-tab-groups";
}
export type ListSavedTabGroupsResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ListTabGroupsRequest extends CmuxRequestBase {
  cmd: "list-tab-groups";
}
export type ListTabGroupsResult = T.JsonValue;

/** Protocol v9; authority: control. */
export interface ListTerminalsRequest extends CmuxRequestBase {
  cmd: "list-terminals";
}

/** Protocol v12; authority: control. */
export interface ListWorkspaceGroupsRequest extends CmuxRequestBase {
  cmd: "list-workspace-groups";
}
export type ListWorkspaceGroupsResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface ListWorkspacesRequest extends CmuxRequestBase {
  cmd: "list-workspaces";
}
export type ListWorkspacesResult = T.Tree;

/** Protocol v12; authority: control. */
export interface MachineListeningTcpRequest extends CmuxRequestBase {
  cmd: "machine-listening-tcp";
}

/** Protocol v12; authority: control. */
export interface MachineUsageRequest extends CmuxRequestBase {
  cmd: "machine-usage";
}

/** Protocol v9; authority: provider-authority. */
export interface MarkWorkspacesProviderManagedRequest extends CmuxRequestBase {
  cmd: "mark-workspaces-provider-managed";
  "authority": string;
}
export type MarkWorkspacesProviderManagedResult = T.EmptyResult;

/** Protocol v9; authority: frontend. */
export interface MintTerminalRendererRequest extends CmuxRequestBase {
  cmd: "mint-terminal-renderer";
  "surface": T.Id;
  "ttl_ms"?: bigint;
}

/** Protocol v11; authority: frontend. */
export interface MintTerminalRendererByTerminalRequest extends CmuxRequestBase {
  cmd: "mint-terminal-renderer-by-terminal";
  "terminal": string;
  "ttl_ms"?: bigint;
}
export type MintTerminalRendererByTerminalResult = T.MintTerminalRendererResult;

/** Protocol v12; authority: control. */
export interface MoveBookmarkRequest extends CmuxRequestBase {
  cmd: "move-bookmark";
  "bookmark": string;
  "index": bigint;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "parent": string;
}
export type MoveBookmarkResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveBrowserProfileRequest extends CmuxRequestBase {
  cmd: "move-browser-profile";
  "browser_profile": string;
  "index": bigint;
}
export type MoveBrowserProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MovePersonalGroupRequest extends CmuxRequestBase {
  cmd: "move-personal-group";
  "group": string;
  "index": bigint;
}
export type MovePersonalGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveProfileRequest extends CmuxRequestBase {
  cmd: "move-profile";
  "index": bigint;
  "profile": string;
}
export type MoveProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveScreenRequest extends CmuxRequestBase {
  cmd: "move-screen";
  "index"?: (bigint) | null;
  "new_workspace"?: boolean;
  "screen": T.Id;
  "workspace"?: (T.Id) | null;
}
export type MoveScreenResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveScreenGroupRequest extends CmuxRequestBase {
  cmd: "move-screen-group";
  "group": string;
  "index"?: (bigint) | null;
  "new_workspace"?: boolean;
  "workspace"?: (T.Id) | null;
}
export type MoveScreenGroupResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface MoveTabRequest extends CmuxRequestBase {
  cmd: "move-tab";
  "index": bigint;
  "pane": T.Id;
  "surface": T.Id;
  "transaction"?: (string) | null;
}
export type MoveTabResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface MoveTabGroupRequest extends CmuxRequestBase {
  cmd: "move-tab-group";
  "group": string;
  "index"?: (bigint) | null;
  "pane"?: (T.PaneRef) | null;
  "transaction"?: (string) | null;
}
export type MoveTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabGroupToColumnRequest extends CmuxRequestBase {
  cmd: "move-tab-group-to-column";
  "after_column"?: (T.Id) | null;
  "group": string;
  "pane"?: (T.PaneRef) | null;
  "screen"?: (T.Id) | null;
  "transaction"?: (string) | null;
  "width"?: (number) | null;
}
export type MoveTabGroupToColumnResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabGroupToNewWorkspaceRequest extends CmuxRequestBase {
  cmd: "move-tab-group-to-new-workspace";
  "group": string;
  "index"?: (bigint) | null;
  "transaction"?: (string) | null;
  "workspace_group"?: (string) | null;
}
export type MoveTabGroupToNewWorkspaceResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabGroupToSplitRequest extends CmuxRequestBase {
  cmd: "move-tab-group-to-split";
  "edge": string;
  "group": string;
  "pane": T.PaneRef;
  "ratio"?: (number) | null;
  "transaction"?: (string) | null;
}
export type MoveTabGroupToSplitResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabToColumnRequest extends CmuxRequestBase {
  cmd: "move-tab-to-column";
  "after_column"?: (T.Id) | null;
  "dock"?: (T.ColumnPin) | null;
  "pane"?: (T.Id) | null;
  "respawn"?: (T.SplitRespawn) | null;
  "screen"?: (T.Id) | null;
  "surface": T.Id;
  "transaction"?: (string) | null;
  "width"?: (number) | null;
}
export type MoveTabToColumnResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabToNewWorkspaceRequest extends CmuxRequestBase {
  cmd: "move-tab-to-new-workspace";
  "group"?: (string) | null;
  "index"?: (bigint) | null;
  "name"?: (string) | null;
  "surface": T.Id;
  "transaction"?: (string) | null;
}
export type MoveTabToNewWorkspaceResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabToSplitRequest extends CmuxRequestBase {
  cmd: "move-tab-to-split";
  "edge": string;
  "pane": T.Id;
  "ratio"?: (number) | null;
  "respawn"?: (T.SplitRespawn) | null;
  "surface": T.Id;
  "transaction"?: (string) | null;
}
export type MoveTabToSplitResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveTabToWorkspaceRequest extends CmuxRequestBase {
  cmd: "move-tab-to-workspace";
  "surface": T.Id;
  "transaction"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type MoveTabToWorkspaceResult = T.EmptyResult;

/** Protocol v9; authority: control. */
export interface MoveTerminalRequest extends CmuxRequestBase {
  cmd: "move-terminal";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "terminal_id": string;
  "terminal_incarnation"?: (string) | null;
  "workspace_key": string;
}

/** Protocol v5; authority: control. */
export interface MoveWorkspaceRequest extends CmuxRequestBase {
  cmd: "move-workspace";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "index": bigint;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type MoveWorkspaceResult = T.WorkspaceMutationResult;

/** Protocol v12; authority: control. */
export interface MoveWorkspaceGroupRequest extends CmuxRequestBase {
  cmd: "move-workspace-group";
  "group": string;
  "index": bigint;
}
export type MoveWorkspaceGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface MoveWorkspaceToGroupRequest extends CmuxRequestBase {
  cmd: "move-workspace-to-group";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "group"?: (string) | null;
  "index"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type MoveWorkspaceToGroupResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface NewBrowserTabRequest extends CmuxRequestBase {
  cmd: "new-browser-tab";
  "cols"?: (number) | null;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
  "url": string;
}
export type NewBrowserTabResult = T.SurfaceResult;

/** Protocol v12; authority: control. */
export interface NewConversationTabRequest extends CmuxRequestBase {
  cmd: "new-conversation-tab";
  "agent_session"?: (T.AgentSessionSource) | null;
  "cols"?: (number) | null;
  "conversation"?: (string) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "owner"?: (string) | null;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
  "workspace"?: (T.Id) | null;
}
export type NewConversationTabResult = {
  "content_resource_id": (string) | null;
  "conversation": T.ConversationTabRecord;
  "replayed": boolean;
  "surface": T.Id;
  "tab_resource_id": (string) | null;
};

/** Protocol v12; authority: control. */
export interface NewFrontendBrowserTabRequest extends CmuxRequestBase {
  cmd: "new-frontend-browser-tab";
  "cols"?: (number) | null;
  "engine": string;
  "favicon_url"?: (string) | null;
  "idempotency_key"?: (string) | null;
  "owner"?: (string) | null;
  "pane"?: (T.Id) | null;
  "profile_id"?: (string) | null;
  "rows"?: (number) | null;
  "title"?: (string) | null;
  "url": string;
}
export type NewFrontendBrowserTabResult = T.JsonValue;

/** Protocol v9; authority: control. */
export interface NewPaneRequest extends CmuxRequestBase {
  cmd: "new-pane";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "keep"?: boolean;
  "pane": T.Id;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
}
export type NewPaneResult = T.SurfaceResult;

/** Protocol v9; authority: control. */
export interface NewPaneRightRequest extends CmuxRequestBase {
  cmd: "new-pane-right";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "keep"?: boolean;
  "kind"?: (T.PaneKind) | null;
  "pane": T.Id;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
  "url"?: (string) | null;
  "width"?: (number) | null;
}
export type NewPaneRightResult = T.SurfaceResult;

/** Protocol v12; authority: control. */
export interface NewRowRequest extends CmuxRequestBase {
  cmd: "new-row";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "height_permille": bigint;
  "keep"?: boolean;
  "pane": T.Id;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
  "transaction"?: (string) | null;
}

/** Protocol v5; authority: control. */
export interface NewScreenRequest extends CmuxRequestBase {
  cmd: "new-screen";
  "color"?: (string) | null;
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "group"?: (string) | null;
  "icon"?: (string) | null;
  "index"?: (bigint) | null;
  "pinned"?: (boolean) | null;
  "rows"?: (number) | null;
  "screen_name"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type NewScreenResult = T.SurfaceResult;

/** Protocol v5; authority: control. */
export interface NewTabRequest extends CmuxRequestBase {
  cmd: "new-tab";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "env"?: (Record<string, string>) | null;
  "keep"?: boolean;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
}
export type NewTabResult = T.SurfaceResult;

/** Protocol v5; authority: control. */
export interface NewWorkspaceRequest extends CmuxRequestBase {
  cmd: "new-workspace";
  "cols"?: (number) | null;
  "name"?: (string) | null;
  "rows"?: (number) | null;
}
export type NewWorkspaceResult = T.SurfaceResult;

/** Protocol v12; authority: control. */
export interface NoteSizeActivityRequest extends CmuxRequestBase {
  cmd: "note-size-activity";
  "surface": T.Id;
  "view"?: (string) | null;
}

/** Protocol v6; authority: control. */
export interface NotifyRequest extends CmuxRequestBase {
  cmd: "notify";
  "body": string;
  "level"?: (T.NotificationLevel) | null;
  "source"?: (T.NotificationSource) | null;
  "surface"?: (T.Id) | null;
  "title": string;
}

/** Protocol v7; authority: local-admin. */
export interface PairingResponseRequest extends CmuxRequestBase {
  cmd: "pairing-response";
  "approve": boolean;
  "request": bigint;
}
export type PairingResponseResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface PaneNeighborRequest extends CmuxRequestBase {
  cmd: "pane-neighbor";
  "dir": T.PaneDirection;
  "pane": T.Id;
}

/** Protocol v12; authority: control. */
export interface PasteImageRequest extends CmuxRequestBase {
  cmd: "paste-image";
  "data"?: (string) | null;
  "lease": string;
  "mime"?: (string) | null;
  "offset"?: (bigint) | null;
  "op": string;
  "size"?: (bigint) | null;
  "surface": T.Id;
  "terminal_id": string;
  "upload_id": string;
}
export type PasteImageResult = {
  "accepted": boolean;
};

/** Protocol v12; authority: control. */
export interface PinWorkspaceRequest extends CmuxRequestBase {
  cmd: "pin-workspace";
  "profile": string;
  "session_id": string;
  "workspace_key": string;
}
export type PinWorkspaceResult = T.JsonValue;

/** Protocol v6; authority: control. */
export interface PingRequest extends CmuxRequestBase {
  cmd: "ping";
}

/** Protocol v6; authority: control. */
export interface ProcessInfoRequest extends CmuxRequestBase {
  cmd: "process-info";
  "surface": T.Id;
}

/** Protocol v7; authority: control. */
export interface PutFrontendProjectionRequest extends CmuxRequestBase {
  cmd: "put-frontend-projection";
  /** Accepted by the current decoder but ignored for projection writes. */
  "expected_generation"?: (string) | null;
  "expected_projection_revision"?: (bigint) | null;
  /** Accepted by the current decoder but ignored for projection writes. */
  "expected_revision"?: (bigint) | null;
  "frontend": string;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "projection": (T.JsonValue) | null;
  "schema_version": number;
  "scope": string;
  "subject_key": string;
}
export type PutFrontendProjectionResult = T.FrontendProjection;

/** Protocol v12; authority: control. */
export interface PutSessionRequest extends CmuxRequestBase {
  cmd: "put-session";
  "capabilities"?: (T.JsonValue) | null;
  "follow_with"?: (string) | null;
  "machine_name"?: (string) | null;
  "session_id": string;
  "session_name"?: (string) | null;
  "transport": (T.JsonValue) | null;
}
export type PutSessionResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface ReadScreenRequest extends CmuxRequestBase {
  cmd: "read-screen";
  "surface": T.Id;
}

/** Protocol v7; authority: control. */
export interface ReadScrollbackRequest extends CmuxRequestBase {
  cmd: "read-scrollback";
  "count": number;
  "start": number;
  "surface": T.Id;
}

/** Protocol v12; authority: control. */
export interface ReattachViewRequest extends CmuxRequestBase {
  cmd: "reattach-view";
  "counts"?: (boolean) | null;
  "surface": T.Id;
}

/** Protocol v10; authority: local-admin. */
export interface RegisterBrowserProviderRequest extends CmuxRequestBase {
  cmd: "register-browser-provider";
  "authentication": T.BrowserProviderAuthentication;
  "bearer_token"?: (string) | null;
  "endpoint": string;
  "provider_id": string;
  "targets": Array<T.BrowserProviderTarget>;
}
export type RegisterBrowserProviderResult = T.BrowserProviderSnapshot;

/** Protocol v10; authority: frontend. */
export interface ReleaseAttachedViewSizeRequest extends CmuxRequestBase {
  cmd: "release-attached-view-size";
  "lease"?: (string) | null;
  "surface": T.Id;
  "view"?: (string) | null;
}
export type ReleaseAttachedViewSizeResult = T.AttachedViewOutcomeResult;

/** Protocol v7; authority: control. */
export interface ReleaseSurfaceSizeRequest extends CmuxRequestBase {
  cmd: "release-surface-size";
  "surface": T.Id;
}
export type ReleaseSurfaceSizeResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface ReloadConfigRequest extends CmuxRequestBase {
  cmd: "reload-config";
}
export type ReloadConfigResult = {
  "path": (string) | null;
  "reloaded": true;
};

/** Protocol v12; authority: control. */
export interface RemoveScreensFromScreenGroupRequest extends CmuxRequestBase {
  cmd: "remove-screens-from-screen-group";
  "screens": Array<T.Id>;
}
export type RemoveScreensFromScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface RemoveTabsFromTabGroupRequest extends CmuxRequestBase {
  cmd: "remove-tabs-from-tab-group";
  "surfaces": Array<T.TabRef>;
  "transaction"?: (string) | null;
}
export type RemoveTabsFromTabGroupResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface RenamePaneRequest extends CmuxRequestBase {
  cmd: "rename-pane";
  "name": string;
  "pane": T.Id;
}
export type RenamePaneResult = T.EmptyResult;

/** Protocol v9; authority: provider-authority. */
export interface RenameProviderManagedWorkspaceRequest extends CmuxRequestBase {
  cmd: "rename-provider-managed-workspace";
  "authority": string;
  "key": string;
  "name": string;
  "workspace": T.Id;
}
export type RenameProviderManagedWorkspaceResult = T.ProviderWorkspaceMutationResult;

/** Protocol v5; authority: control. */
export interface RenameScreenRequest extends CmuxRequestBase {
  cmd: "rename-screen";
  "name": string;
  "screen": T.Id;
}
export type RenameScreenResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface RenameSurfaceRequest extends CmuxRequestBase {
  cmd: "rename-surface";
  "name": string;
  "surface": T.Id;
}
export type RenameSurfaceResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface RenameWorkspaceRequest extends CmuxRequestBase {
  cmd: "rename-workspace";
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "name": string;
  "origin"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type RenameWorkspaceResult = T.WorkspaceMutationResult;

/** Protocol v12; authority: control. */
export interface ReopenSavedScreenGroupRequest extends CmuxRequestBase {
  cmd: "reopen-saved-screen-group";
  "saved": string;
  "workspace"?: (T.Id) | null;
}
export type ReopenSavedScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface ReopenSavedTabGroupRequest extends CmuxRequestBase {
  cmd: "reopen-saved-tab-group";
  "pane": T.PaneRef;
  "saved": string;
  "transaction"?: (string) | null;
}
export type ReopenSavedTabGroupResult = T.JsonValue;

/** Protocol v6; authority: control. */
export interface ReportAgentRequest extends CmuxRequestBase {
  cmd: "report-agent";
  "session"?: (string) | null;
  "source": T.AgentReportSource;
  "state": T.AgentState;
  "surface": T.Id;
}

/** Protocol v12; authority: control. */
export interface ReportFocusRequest extends CmuxRequestBase {
  cmd: "report-focus";
  "client_id": string;
  "pane": T.Id;
  "tab"?: (bigint) | null;
}
export type ReportFocusResult = T.EmptyResult;

/** Protocol v10; authority: frontend. */
export interface ResizeAttachedViewRequest extends CmuxRequestBase {
  cmd: "resize-attached-view";
  "cols": number;
  "identity"?: (T.SizingIdentity) | null;
  "lease"?: (string) | null;
  "rows": number;
  "surface": T.Id;
  "view"?: (string) | null;
}
export type ResizeAttachedViewResult = T.AttachedViewResizeResult;

/** Protocol v5; authority: control. */
export interface ResizeSurfaceRequest extends CmuxRequestBase {
  cmd: "resize-surface";
  "cols": number;
  "rows": number;
  "surface": T.Id;
}

/** Protocol v9; authority: control. */
export interface ResolveTerminalRequest extends CmuxRequestBase {
  cmd: "resolve-terminal";
  "terminal_id": string;
}

/** Protocol v6; authority: control. */
export interface RunRequest extends CmuxRequestBase {
  cmd: "run";
  "argv"?: (Array<string>) | null;
  "cols"?: (number) | null;
  "command"?: (string) | null;
  "cwd"?: (string) | null;
  "key"?: (string) | null;
  "name"?: (string) | null;
  "new_workspace"?: boolean;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
}

/** Protocol v12; authority: control. */
export interface SaveScreenGroupRequest extends CmuxRequestBase {
  cmd: "save-screen-group";
  "group": string;
}
export type SaveScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SaveTabGroupRequest extends CmuxRequestBase {
  cmd: "save-tab-group";
  "group": string;
}
export type SaveTabGroupResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface ScrollSurfaceRequest extends CmuxRequestBase {
  cmd: "scroll-surface";
  "delta": bigint;
  "surface": T.Id;
}
export type ScrollSurfaceResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface SelectScreenRequest extends CmuxRequestBase {
  cmd: "select-screen";
  "delta"?: (bigint) | null;
  "index"?: (bigint) | null;
}
export type SelectScreenResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface SelectTabRequest extends CmuxRequestBase {
  cmd: "select-tab";
  "delta"?: (bigint) | null;
  "index"?: (bigint) | null;
  "pane"?: (T.Id) | null;
}
export type SelectTabResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface SelectWorkspaceRequest extends CmuxRequestBase {
  cmd: "select-workspace";
  "delta"?: (bigint) | null;
  "index"?: (bigint) | null;
}
export type SelectWorkspaceResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface SendRequest extends CmuxRequestBase {
  cmd: "send";
  "bytes"?: (T.Base64) | null;
  "paste"?: boolean;
  "surface": T.Id;
  "text"?: (string) | null;
}
export type SendResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface SendKeyRequest extends CmuxRequestBase {
  cmd: "send-key";
  "keys": Array<string>;
  "surface": T.Id;
}
export type SendKeyResult = T.EmptyResult;

/** Protocol v12; authority: local-admin. */
export interface ServerStatsRequest extends CmuxRequestBase {
  cmd: "server-stats";
}

/** Protocol v6; authority: frontend. */
export interface SetCellPixelsRequest extends CmuxRequestBase {
  cmd: "set-cell-pixels";
  "height_px": number;
  "width_px": number;
}

/** Protocol v6; authority: control. */
export interface SetClientInfoRequest extends CmuxRequestBase {
  cmd: "set-client-info";
  "capabilities"?: (Array<string>) | null;
  "device_id"?: (string) | null;
  "device_kind"?: (string) | null;
  "device_name"?: (string) | null;
  "display_name"?: (string) | null;
  "kind"?: (string) | null;
  "name"?: (string) | null;
  "user_id"?: (string) | null;
}
export type SetClientInfoResult = T.EmptyResult;

/** Protocol v10; authority: control. */
export interface SetClientSizingRequest extends CmuxRequestBase {
  cmd: "set-client-sizing";
  "client"?: (bigint) | null;
  "enabled": boolean;
  "exclusive"?: boolean;
  "surface": T.Id;
}
export type SetClientSizingResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface SetColumnDockRequest extends CmuxRequestBase {
  cmd: "set-column-dock";
  "dock": boolean;
  "edge"?: (string) | null;
  "mode"?: (string) | null;
  "pane": T.Id;
  "transaction"?: (bigint) | null;
}
export type SetColumnDockResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface SetDefaultColorsRequest extends CmuxRequestBase {
  cmd: "set-default-colors";
  "bg"?: (T.ColorHex) | null;
  "complete"?: boolean;
  "cursor"?: (T.ColorHex) | null;
  "cursor_blink"?: (boolean) | null;
  "cursor_style"?: (T.CursorStyle) | null;
  "fg"?: (T.ColorHex) | null;
  "palette"?: (Record<string, T.ColorHex>) | null;
  "selection_bg"?: (T.ColorHex) | null;
  "selection_fg"?: (T.ColorHex) | null;
}
export type SetDefaultColorsResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface SetFrontendBrowserHistoryRequest extends CmuxRequestBase {
  cmd: "set-frontend-browser-history";
  "history": (T.JsonValue) | null;
  "surface": T.Id;
}
export type SetFrontendBrowserHistoryResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetPersonalTerminalRequest extends CmuxRequestBase {
  cmd: "set-personal-terminal";
  "session_id": string;
  "terminal_key": string;
  "theme"?: (string) | null;
}
export type SetPersonalTerminalResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetPersonalWorkspaceRequest extends CmuxRequestBase {
  cmd: "set-personal-workspace";
  "browser_profile_id"?: (string) | null;
  "group"?: (string) | null;
  "index"?: (bigint) | null;
  "session_id": string;
  "theme"?: (string) | null;
  "workspace_key": string;
}
export type SetPersonalWorkspaceResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetProfileFollowsRequest extends CmuxRequestBase {
  cmd: "set-profile-follows";
  "profile": string;
  "session_ids": Array<string>;
}
export type SetProfileFollowsResult = T.JsonValue;

/** Protocol v5; authority: control. */
export interface SetRatioRequest extends CmuxRequestBase {
  cmd: "set-ratio";
  "dir": T.SplitDirection;
  "pane": T.Id;
  "ratio": number;
}
export type SetRatioResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface SetRowHeightsRequest extends CmuxRequestBase {
  cmd: "set-row-heights";
  "column": T.Id;
  "fit"?: boolean;
  "heights": Array<T.RowHeight>;
  "transaction"?: (bigint) | null;
}
export type SetRowHeightsResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetScreenMetadataRequest extends CmuxRequestBase {
  cmd: "set-screen-metadata";
  "color"?: (string) | null;
  "icon"?: (string) | null;
  "screen": T.Id;
}
export type SetScreenMetadataResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetScreenPinnedRequest extends CmuxRequestBase {
  cmd: "set-screen-pinned";
  "pinned": boolean;
  "screen": T.Id;
}
export type SetScreenPinnedResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface SetSizeCountsRequest extends CmuxRequestBase {
  cmd: "set-size-counts";
  "client"?: (bigint) | null;
  "counts"?: (boolean) | null;
  "lease"?: (string) | null;
  "participant"?: (string) | null;
  "surface": T.Id;
  "view"?: (string) | null;
}

/** Protocol v12; authority: control. */
export interface SetSizePolicyRequest extends CmuxRequestBase {
  cmd: "set-size-policy";
  "policy"?: (T.SizePolicy) | null;
  "surface"?: (T.Id) | null;
  "workspace"?: (T.Id) | null;
}

/** Protocol v8; authority: control. */
export interface SetSplitRatioRequest extends CmuxRequestBase {
  cmd: "set-split-ratio";
  "ratio": number;
  "split": T.Id;
  "transaction"?: (bigint) | null;
}
export type SetSplitRatioResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface SetTabPinnedRequest extends CmuxRequestBase {
  cmd: "set-tab-pinned";
  "pinned": boolean;
  "surface": T.Id;
}
export type SetTabPinnedResult = T.JsonValue;

/** Protocol v12; authority: local-admin. */
export interface SetTerminalCommandHistoryRequest extends CmuxRequestBase {
  cmd: "set-terminal-command-history";
  "enabled": boolean;
}
export type SetTerminalCommandHistoryResult = T.TerminalCommandHistoryResult;

/** Protocol v12; authority: control. */
export interface SetTerminalIdlePolicyRequest extends CmuxRequestBase {
  cmd: "set-terminal-idle-policy";
  "idle_close_seconds"?: (bigint) | null;
  "surface"?: (T.Id) | null;
  "terminal_id"?: (string) | null;
}

/** Protocol v12; authority: control. */
export interface SetTerminalKeepRequest extends CmuxRequestBase {
  cmd: "set-terminal-keep";
  "keep": boolean;
  "surface"?: (T.Id) | null;
  "terminal_id"?: (string) | null;
}

/** Protocol v9; authority: control. */
export interface SetViewportPaneWidthRequest extends CmuxRequestBase {
  cmd: "set-viewport-pane-width";
  "pane": T.Id;
  "transaction"?: (bigint) | null;
  "width": number;
}
export type SetViewportPaneWidthResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface SetWindowTitleRequest extends CmuxRequestBase {
  cmd: "set-window-title";
  "title": string;
}
export type SetWindowTitleResult = T.EmptyResult;

/** Protocol v12; authority: control. */
export interface SetWorkspaceMetadataRequest extends CmuxRequestBase {
  cmd: "set-workspace-metadata";
  "color"?: (string) | null;
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "icon"?: (string) | null;
  "key"?: (string) | null;
  "marked_unread"?: (boolean) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "pinned"?: (boolean) | null;
  "title"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type SetWorkspaceMetadataResult = T.JsonValue;

/** Protocol v9; authority: local-admin. */
export interface ShutdownDaemonRequest extends CmuxRequestBase {
  cmd: "shutdown-daemon";
  "end_terminals"?: boolean;
  "force"?: boolean;
  "generation": string;
  "keep_layout"?: boolean;
  "pid": number;
}

/** Protocol v6; authority: frontend. */
export interface SidebarPluginRequest extends CmuxRequestBase {
  cmd: "sidebar-plugin";
  "cols": number;
  "relaunch"?: boolean;
  "rows": number;
}

/** Protocol v12; authority: frontend. */
export interface SnapshotRequestRequest extends CmuxRequestBase {
  cmd: "snapshot-request";
  "have"?: (T.SnapshotRequestHave) | null;
  "reason"?: (string) | null;
  "request_id"?: (string) | null;
  "surface": T.Id;
}

/** Protocol v5; authority: control. */
export interface SplitRequest extends CmuxRequestBase {
  cmd: "split";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "dir": T.SplitDirection;
  "env"?: (Record<string, string>) | null;
  "keep"?: boolean;
  "kind"?: (T.PaneKind) | null;
  "pane": T.Id;
  "rows"?: (number) | null;
  "shell_args"?: (Array<string>) | null;
  "terminal_id"?: (string) | null;
  "url"?: (string) | null;
}
export type SplitResult = T.SurfaceResult;

/** Protocol v5; authority: frontend. */
export interface SubscribeRequest extends CmuxRequestBase {
  cmd: "subscribe";
  "surface"?: (T.Id) | null;
  "tree_events"?: ("coarse" | "deltas") | null;
}
export type SubscribeResult = T.EmptyResult;

/** Protocol v6; authority: control. */
export interface SwapPaneRequest extends CmuxRequestBase {
  cmd: "swap-pane";
  "dir"?: (T.PaneDirection) | null;
  "pane": T.Id;
  "target"?: (T.Id) | null;
}
export type SwapPaneResult = T.EmptyResult;

/** Protocol v9; authority: control. */
export interface TerminalEventsRequest extends CmuxRequestBase {
  cmd: "terminal-events";
  "after_revision"?: bigint;
}

/** Protocol v12; authority: control. */
export interface TerminalHistoryRequest extends CmuxRequestBase {
  cmd: "terminal-history";
  "before"?: (bigint) | null;
  "marker_epoch": bigint;
  "max_bytes"?: (bigint) | null;
  "surface": T.Id;
}
export type TerminalHistoryResult = T.TerminalHistoryPagesResult;

/** Protocol v12; authority: control. */
export interface TerminalReadRangeRequest extends CmuxRequestBase {
  cmd: "terminal-read-range";
  "format"?: (string) | null;
  "from": T.RowMarkerPoint;
  "marker_epoch": bigint;
  "max_bytes"?: (bigint) | null;
  "surface": T.Id;
  "to": T.RowMarkerPoint;
}

/** Protocol v12; authority: control. */
export interface TerminalResourcesRequest extends CmuxRequestBase {
  cmd: "terminal-resources";
  "surfaces"?: (Array<T.Id>) | null;
}

/** Protocol v9; authority: control. */
export interface UndoLayoutRequest extends CmuxRequestBase {
  cmd: "undo-layout";
  "confirm_close"?: boolean;
  "pane": T.Id;
  "revision"?: (bigint) | null;
}
export type UndoLayoutResult = T.LayoutUndoResult;

/** Protocol v12; authority: control. */
export interface UngroupScreenGroupRequest extends CmuxRequestBase {
  cmd: "ungroup-screen-group";
  "group": string;
}
export type UngroupScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UngroupTabGroupRequest extends CmuxRequestBase {
  cmd: "ungroup-tab-group";
  "group": string;
}
export type UngroupTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UnpinWorkspaceRequest extends CmuxRequestBase {
  cmd: "unpin-workspace";
  "session_id": string;
  "workspace_key": string;
}
export type UnpinWorkspaceResult = T.JsonValue;

/** Protocol v10; authority: local-admin. */
export interface UnregisterBrowserProviderRequest extends CmuxRequestBase {
  cmd: "unregister-browser-provider";
}
export type UnregisterBrowserProviderResult = T.BrowserProviderUnregisterResult;

/** Protocol v12; authority: control. */
export interface UnsaveScreenGroupRequest extends CmuxRequestBase {
  cmd: "unsave-screen-group";
  "group": string;
}
export type UnsaveScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UnsaveTabGroupRequest extends CmuxRequestBase {
  cmd: "unsave-tab-group";
  "group": string;
}
export type UnsaveTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateBookmarkRequest extends CmuxRequestBase {
  cmd: "update-bookmark";
  "bookmark": string;
  "favicon_key"?: (string) | null;
  "last_used_ms"?: (bigint) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "title"?: (string) | null;
  "url"?: (string) | null;
}
export type UpdateBookmarkResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateBrowserProfileRequest extends CmuxRequestBase {
  cmd: "update-browser-profile";
  "browser_profile": string;
  "color"?: (string) | null;
  "icon"?: (string) | null;
  "name"?: (string) | null;
}
export type UpdateBrowserProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateFrontendBrowserTabRequest extends CmuxRequestBase {
  cmd: "update-frontend-browser-tab";
  "favicon_url"?: (string) | null;
  "owner"?: (string) | null;
  "surface": T.Id;
  "title"?: (string) | null;
  "url"?: (string) | null;
}
export type UpdateFrontendBrowserTabResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdatePersonalGroupRequest extends CmuxRequestBase {
  cmd: "update-personal-group";
  "collapsed"?: (boolean) | null;
  "color"?: (string) | null;
  "group": string;
  "name"?: (string) | null;
  "profile"?: (string) | null;
}
export type UpdatePersonalGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateProfileRequest extends CmuxRequestBase {
  cmd: "update-profile";
  "browser_profile_id"?: (string) | null;
  "color"?: (string) | null;
  "default_session_id"?: (string) | null;
  "defaults"?: (T.JsonValue) | null;
  "icon"?: (string) | null;
  "name"?: (string) | null;
  "profile": string;
  "theme"?: (string) | null;
}
export type UpdateProfileResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateScreenGroupRequest extends CmuxRequestBase {
  cmd: "update-screen-group";
  "collapsed"?: (boolean) | null;
  "color"?: (string) | null;
  "group": string;
  "name"?: (string) | null;
}
export type UpdateScreenGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateTabGroupRequest extends CmuxRequestBase {
  cmd: "update-tab-group";
  "collapsed"?: (boolean) | null;
  "color"?: (string) | null;
  "group": string;
  "name"?: (string) | null;
}
export type UpdateTabGroupResult = T.JsonValue;

/** Protocol v12; authority: control. */
export interface UpdateWorkspaceGroupRequest extends CmuxRequestBase {
  cmd: "update-workspace-group";
  "collapsed"?: (boolean) | null;
  "color"?: (string) | null;
  "group": string;
  "name"?: (string) | null;
}
export type UpdateWorkspaceGroupResult = T.JsonValue;

/** Protocol v12; authority: local-admin. */
export interface UrlOpenRequest extends CmuxRequestBase {
  cmd: "url-open";
  "terminal_id": string;
  "url": string;
}
export type UrlOpenResult = T.GuestUrlOpenResult;

/** Protocol v12; authority: frontend. */
export interface UrlOpenClaimRequest extends CmuxRequestBase {
  cmd: "url-open-claim";
  "request_id": string;
}
export type UrlOpenClaimResult = T.GuestUrlClaimResult;

/** Protocol v12; authority: frontend. */
export interface UrlOpenResultRequest extends CmuxRequestBase {
  cmd: "url-open-result";
  "opened": boolean;
  "request_id": string;
}
export type UrlOpenResultResult = T.GuestUrlAcknowledgeResult;

/** Protocol v12; authority: frontend. */
export interface UrlOpenSubscribeRequest extends CmuxRequestBase {
  cmd: "url-open-subscribe";
  "terminal_ids": Array<string>;
}
export type UrlOpenSubscribeResult = T.GuestUrlSubscribeResult;

/** Protocol v5; authority: control. */
export interface VtStateRequest extends CmuxRequestBase {
  cmd: "vt-state";
  "surface": T.Id;
}

/** Protocol v6; authority: control. */
export interface WaitForRequest extends CmuxRequestBase {
  cmd: "wait-for";
  "pattern": string;
  "surface": T.Id;
  /** Zero performs one immediate check. */
  "timeout_ms": bigint;
}

/** Protocol v6; authority: control. */
export interface ZoomPaneRequest extends CmuxRequestBase {
  cmd: "zoom-pane";
  "mode"?: ("toggle" | "on" | "off") | null;
  "pane"?: (T.Id) | null;
}

/** Every implemented protocol command request. */
export type CmuxRequest =
  | AckTabNotificationsRequest
  | AddScreensToScreenGroupRequest
  | AddTabsToTabGroupRequest
  | ApplyLayoutRequest
  | AttachSurfaceRequest
  | BindConversationTabSessionRequest
  | BrowserActivateRequest
  | BrowserBackRequest
  | BrowserForwardRequest
  | BrowserFramePresentedRequest
  | BrowserInsertTextRequest
  | BrowserKeyRequest
  | BrowserKeyPressRequest
  | BrowserMouseRequest
  | BrowserMouseGuardedRequest
  | BrowserNavigateRequest
  | BrowserReloadRequest
  | BrowserWheelRequest
  | BrowserWheelGuardedRequest
  | ClearHistoryRequest
  | ClearWindowTitleRequest
  | ClientFocusRequest
  | ClosePaneRequest
  | CloseProviderManagedWorkspaceRequest
  | CloseScreenRequest
  | CloseScreenGroupRequest
  | CloseSurfaceRequest
  | CloseTabGroupRequest
  | CloseTabsRequest
  | CloseTerminalRequest
  | CloseWorkspaceRequest
  | ConversationAgentTokenRequest
  | ConversationBindRequest
  | ConversationCreateRequest
  | ConversationHistoryRequest
  | ConversationListRequest
  | ConversationOpRequest
  | ConversationSearchRequest
  | ConversationSnapshotRequest
  | ConversationTypingRequest
  | CopyRequest
  | CreateBookmarkRequest
  | CreateBrowserProfileRequest
  | CreatePersonalGroupRequest
  | CreateProfileRequest
  | CreateScreenGroupRequest
  | CreateSurfaceWithReceiptRequest
  | CreateTabGroupRequest
  | CreateTerminalRequest
  | CreateWorkspaceRequest
  | CreateWorkspaceGroupRequest
  | DeleteBookmarkRequest
  | DeleteBrowserProfileRequest
  | DeletePersonalGroupRequest
  | DeleteProfileRequest
  | DeleteSavedScreenGroupRequest
  | DeleteSavedTabGroupRequest
  | DeleteWorkspaceGroupRequest
  | DetachAttachedViewRequest
  | DetachClientRequest
  | ExportLayoutRequest
  | FocusDirectionRequest
  | FocusPaneRequest
  | ForgetSessionRequest
  | GetBrowserProviderRequest
  | GetCellPixelsRequest
  | GetFrontendBrowserHistoryRequest
  | GetFrontendProjectionRequest
  | GetSizeStateRequest
  | IdentifyRequest
  | IdsRequest
  | ImportBookmarksRequest
  | ImportSessionOrganizationRequest
  | JournalFrontendEventRequest
  | ListAgentsRequest
  | ListBookmarksRequest
  | ListClientsRequest
  | ListNotificationsRequest
  | ListPersonalRequest
  | ListSavedScreenGroupsRequest
  | ListSavedTabGroupsRequest
  | ListTabGroupsRequest
  | ListTerminalsRequest
  | ListWorkspaceGroupsRequest
  | ListWorkspacesRequest
  | MachineListeningTcpRequest
  | MachineUsageRequest
  | MarkWorkspacesProviderManagedRequest
  | MintTerminalRendererRequest
  | MintTerminalRendererByTerminalRequest
  | MoveBookmarkRequest
  | MoveBrowserProfileRequest
  | MovePersonalGroupRequest
  | MoveProfileRequest
  | MoveScreenRequest
  | MoveScreenGroupRequest
  | MoveTabRequest
  | MoveTabGroupRequest
  | MoveTabGroupToColumnRequest
  | MoveTabGroupToNewWorkspaceRequest
  | MoveTabGroupToSplitRequest
  | MoveTabToColumnRequest
  | MoveTabToNewWorkspaceRequest
  | MoveTabToSplitRequest
  | MoveTabToWorkspaceRequest
  | MoveTerminalRequest
  | MoveWorkspaceRequest
  | MoveWorkspaceGroupRequest
  | MoveWorkspaceToGroupRequest
  | NewBrowserTabRequest
  | NewConversationTabRequest
  | NewFrontendBrowserTabRequest
  | NewPaneRequest
  | NewPaneRightRequest
  | NewRowRequest
  | NewScreenRequest
  | NewTabRequest
  | NewWorkspaceRequest
  | NoteSizeActivityRequest
  | NotifyRequest
  | PairingResponseRequest
  | PaneNeighborRequest
  | PasteImageRequest
  | PinWorkspaceRequest
  | PingRequest
  | ProcessInfoRequest
  | PutFrontendProjectionRequest
  | PutSessionRequest
  | ReadScreenRequest
  | ReadScrollbackRequest
  | ReattachViewRequest
  | RegisterBrowserProviderRequest
  | ReleaseAttachedViewSizeRequest
  | ReleaseSurfaceSizeRequest
  | ReloadConfigRequest
  | RemoveScreensFromScreenGroupRequest
  | RemoveTabsFromTabGroupRequest
  | RenamePaneRequest
  | RenameProviderManagedWorkspaceRequest
  | RenameScreenRequest
  | RenameSurfaceRequest
  | RenameWorkspaceRequest
  | ReopenSavedScreenGroupRequest
  | ReopenSavedTabGroupRequest
  | ReportAgentRequest
  | ReportFocusRequest
  | ResizeAttachedViewRequest
  | ResizeSurfaceRequest
  | ResolveTerminalRequest
  | RunRequest
  | SaveScreenGroupRequest
  | SaveTabGroupRequest
  | ScrollSurfaceRequest
  | SelectScreenRequest
  | SelectTabRequest
  | SelectWorkspaceRequest
  | SendRequest
  | SendKeyRequest
  | ServerStatsRequest
  | SetCellPixelsRequest
  | SetClientInfoRequest
  | SetClientSizingRequest
  | SetColumnDockRequest
  | SetDefaultColorsRequest
  | SetFrontendBrowserHistoryRequest
  | SetPersonalTerminalRequest
  | SetPersonalWorkspaceRequest
  | SetProfileFollowsRequest
  | SetRatioRequest
  | SetRowHeightsRequest
  | SetScreenMetadataRequest
  | SetScreenPinnedRequest
  | SetSizeCountsRequest
  | SetSizePolicyRequest
  | SetSplitRatioRequest
  | SetTabPinnedRequest
  | SetTerminalCommandHistoryRequest
  | SetTerminalIdlePolicyRequest
  | SetTerminalKeepRequest
  | SetViewportPaneWidthRequest
  | SetWindowTitleRequest
  | SetWorkspaceMetadataRequest
  | ShutdownDaemonRequest
  | SidebarPluginRequest
  | SnapshotRequestRequest
  | SplitRequest
  | SubscribeRequest
  | SwapPaneRequest
  | TerminalEventsRequest
  | TerminalHistoryRequest
  | TerminalReadRangeRequest
  | TerminalResourcesRequest
  | UndoLayoutRequest
  | UngroupScreenGroupRequest
  | UngroupTabGroupRequest
  | UnpinWorkspaceRequest
  | UnregisterBrowserProviderRequest
  | UnsaveScreenGroupRequest
  | UnsaveTabGroupRequest
  | UpdateBookmarkRequest
  | UpdateBrowserProfileRequest
  | UpdateFrontendBrowserTabRequest
  | UpdatePersonalGroupRequest
  | UpdateProfileRequest
  | UpdateScreenGroupRequest
  | UpdateTabGroupRequest
  | UpdateWorkspaceGroupRequest
  | UrlOpenRequest
  | UrlOpenClaimRequest
  | UrlOpenResultRequest
  | UrlOpenSubscribeRequest
  | VtStateRequest
  | WaitForRequest
  | ZoomPaneRequest;

/** Command name to request, result, authority, and version mapping. */
export interface CmuxCommandDefinitionMap {
  "ack-tab-notifications": {
    request: AckTabNotificationsRequest;
    result: AckTabNotificationsResult;
    authority: "control";
    since: 12;
    capability: "notification-ack-v1";
    stream: null;
  };
  "add-screens-to-screen-group": {
    request: AddScreensToScreenGroupRequest;
    result: AddScreensToScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "add-tabs-to-tab-group": {
    request: AddTabsToTabGroupRequest;
    result: AddTabsToTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "apply-layout": {
    request: ApplyLayoutRequest;
    result: T.ApplyLayoutResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "attach-surface": {
    request: AttachSurfaceRequest;
    result: AttachSurfaceResult;
    authority: "frontend";
    since: 5;
    capability: null;
    stream: "attach";
  };
  "bind-conversation-tab-session": {
    request: BindConversationTabSessionRequest;
    result: BindConversationTabSessionResult;
    authority: "control";
    since: 12;
    capability: "agent-session-tabs-v1";
    stream: null;
  };
  "browser-activate": {
    request: BrowserActivateRequest;
    result: BrowserActivateResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-back": {
    request: BrowserBackRequest;
    result: BrowserBackResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-forward": {
    request: BrowserForwardRequest;
    result: BrowserForwardResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-frame-presented": {
    request: BrowserFramePresentedRequest;
    result: BrowserFramePresentedResult;
    authority: "frontend";
    since: 10;
    capability: "browser-pointer-frame-guard-v1";
    stream: null;
  };
  "browser-insert-text": {
    request: BrowserInsertTextRequest;
    result: BrowserInsertTextResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-key": {
    request: BrowserKeyRequest;
    result: BrowserKeyResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-key-press": {
    request: BrowserKeyPressRequest;
    result: BrowserKeyPressResult;
    authority: "frontend";
    since: 10;
    capability: null;
    stream: null;
  };
  "browser-mouse": {
    request: BrowserMouseRequest;
    result: BrowserMouseResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-mouse-guarded": {
    request: BrowserMouseGuardedRequest;
    result: BrowserMouseGuardedResult;
    authority: "frontend";
    since: 10;
    capability: "browser-pointer-frame-guard-v1";
    stream: null;
  };
  "browser-navigate": {
    request: BrowserNavigateRequest;
    result: BrowserNavigateResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-reload": {
    request: BrowserReloadRequest;
    result: BrowserReloadResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-wheel": {
    request: BrowserWheelRequest;
    result: BrowserWheelResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "browser-wheel-guarded": {
    request: BrowserWheelGuardedRequest;
    result: BrowserWheelGuardedResult;
    authority: "frontend";
    since: 10;
    capability: "browser-pointer-frame-guard-v1";
    stream: null;
  };
  "clear-history": {
    request: ClearHistoryRequest;
    result: ClearHistoryResult;
    authority: "control";
    since: 9;
    capability: "clear-history-v1";
    stream: null;
  };
  "clear-window-title": {
    request: ClearWindowTitleRequest;
    result: ClearWindowTitleResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "client-focus": {
    request: ClientFocusRequest;
    result: ClientFocusResult;
    authority: "control";
    since: 12;
    capability: "client-focus-v1";
    stream: null;
  };
  "close-pane": {
    request: ClosePaneRequest;
    result: ClosePaneResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "close-provider-managed-workspace": {
    request: CloseProviderManagedWorkspaceRequest;
    result: CloseProviderManagedWorkspaceResult;
    authority: "provider-authority";
    since: 9;
    capability: "provider-managed-workspace-authority-v2";
    stream: null;
  };
  "close-screen": {
    request: CloseScreenRequest;
    result: CloseScreenResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "close-screen-group": {
    request: CloseScreenGroupRequest;
    result: CloseScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "close-surface": {
    request: CloseSurfaceRequest;
    result: CloseSurfaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "close-tab-group": {
    request: CloseTabGroupRequest;
    result: CloseTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "close-tabs": {
    request: CloseTabsRequest;
    result: CloseTabsResult;
    authority: "control";
    since: 12;
    capability: "batch-close-v1";
    stream: null;
  };
  "close-terminal": {
    request: CloseTerminalRequest;
    result: T.CloseTerminalResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "close-workspace": {
    request: CloseWorkspaceRequest;
    result: CloseWorkspaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "conversation-agent-token": {
    request: ConversationAgentTokenRequest;
    result: ConversationAgentTokenResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-bind": {
    request: ConversationBindRequest;
    result: ConversationBindResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-create": {
    request: ConversationCreateRequest;
    result: ConversationCreateResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-history": {
    request: ConversationHistoryRequest;
    result: ConversationHistoryResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-list": {
    request: ConversationListRequest;
    result: ConversationListResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-op": {
    request: ConversationOpRequest;
    result: ConversationOpResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-search": {
    request: ConversationSearchRequest;
    result: ConversationSearchResult;
    authority: "local-admin";
    since: 12;
    capability: "conversation-search-v1";
    stream: null;
  };
  "conversation-snapshot": {
    request: ConversationSnapshotRequest;
    result: ConversationSnapshotResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "conversation-typing": {
    request: ConversationTypingRequest;
    result: ConversationTypingResult;
    authority: "local-admin";
    since: 12;
    capability: "local-conversations-v1";
    stream: null;
  };
  "copy": {
    request: CopyRequest;
    result: T.CopyResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "create-bookmark": {
    request: CreateBookmarkRequest;
    result: CreateBookmarkResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "create-browser-profile": {
    request: CreateBrowserProfileRequest;
    result: CreateBrowserProfileResult;
    authority: "control";
    since: 12;
    capability: "browser-profiles-v1";
    stream: null;
  };
  "create-personal-group": {
    request: CreatePersonalGroupRequest;
    result: CreatePersonalGroupResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "create-profile": {
    request: CreateProfileRequest;
    result: CreateProfileResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "create-screen-group": {
    request: CreateScreenGroupRequest;
    result: CreateScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "create-surface-with-receipt": {
    request: CreateSurfaceWithReceiptRequest;
    result: CreateSurfaceWithReceiptResult;
    authority: "control";
    since: 10;
    capability: "creation-receipts-v1";
    stream: null;
  };
  "create-tab-group": {
    request: CreateTabGroupRequest;
    result: CreateTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "create-terminal": {
    request: CreateTerminalRequest;
    result: CreateTerminalResult;
    authority: "control";
    since: 7;
    capability: "workspace-registry-v1";
    stream: null;
  };
  "create-workspace": {
    request: CreateWorkspaceRequest;
    result: CreateWorkspaceResult;
    authority: "control";
    since: 7;
    capability: "workspace-registry-v1";
    stream: null;
  };
  "create-workspace-group": {
    request: CreateWorkspaceGroupRequest;
    result: CreateWorkspaceGroupResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "delete-bookmark": {
    request: DeleteBookmarkRequest;
    result: DeleteBookmarkResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "delete-browser-profile": {
    request: DeleteBrowserProfileRequest;
    result: DeleteBrowserProfileResult;
    authority: "control";
    since: 12;
    capability: "browser-profiles-v1";
    stream: null;
  };
  "delete-personal-group": {
    request: DeletePersonalGroupRequest;
    result: DeletePersonalGroupResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "delete-profile": {
    request: DeleteProfileRequest;
    result: DeleteProfileResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "delete-saved-screen-group": {
    request: DeleteSavedScreenGroupRequest;
    result: DeleteSavedScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "delete-saved-tab-group": {
    request: DeleteSavedTabGroupRequest;
    result: DeleteSavedTabGroupResult;
    authority: "control";
    since: 12;
    capability: "saved-tab-groups-v1";
    stream: null;
  };
  "delete-workspace-group": {
    request: DeleteWorkspaceGroupRequest;
    result: DeleteWorkspaceGroupResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "detach-attached-view": {
    request: DetachAttachedViewRequest;
    result: DetachAttachedViewResult;
    authority: "frontend";
    since: 10;
    capability: "view-attachment-detach-v1";
    stream: null;
  };
  "detach-client": {
    request: DetachClientRequest;
    result: DetachClientResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "export-layout": {
    request: ExportLayoutRequest;
    result: T.ExportLayoutResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "focus-direction": {
    request: FocusDirectionRequest;
    result: T.FocusDirectionResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "focus-pane": {
    request: FocusPaneRequest;
    result: FocusPaneResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "forget-session": {
    request: ForgetSessionRequest;
    result: ForgetSessionResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "get-browser-provider": {
    request: GetBrowserProviderRequest;
    result: GetBrowserProviderResult;
    authority: "local-admin";
    since: 10;
    capability: "browser-provider-v1";
    stream: null;
  };
  "get-cell-pixels": {
    request: GetCellPixelsRequest;
    result: T.GetCellPixelsResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "get-frontend-browser-history": {
    request: GetFrontendBrowserHistoryRequest;
    result: GetFrontendBrowserHistoryResult;
    authority: "control";
    since: 12;
    capability: "frontend-browser-history-v1";
    stream: null;
  };
  "get-frontend-projection": {
    request: GetFrontendProjectionRequest;
    result: GetFrontendProjectionResult;
    authority: "control";
    since: 7;
    capability: null;
    stream: null;
  };
  "get-size-state": {
    request: GetSizeStateRequest;
    result: T.GetSizeStateResult;
    authority: "control";
    since: 12;
    capability: "shared-sizing-v1";
    stream: null;
  };
  "identify": {
    request: IdentifyRequest;
    result: T.IdentifyResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "ids": {
    request: IdsRequest;
    result: T.IdsResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "import-bookmarks": {
    request: ImportBookmarksRequest;
    result: ImportBookmarksResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "import-session-organization": {
    request: ImportSessionOrganizationRequest;
    result: ImportSessionOrganizationResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "journal-frontend-event": {
    request: JournalFrontendEventRequest;
    result: JournalFrontendEventResult;
    authority: "control";
    since: 10;
    capability: "frontend-journal-v1";
    stream: null;
  };
  "list-agents": {
    request: ListAgentsRequest;
    result: T.ListAgentsResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "list-bookmarks": {
    request: ListBookmarksRequest;
    result: ListBookmarksResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "list-clients": {
    request: ListClientsRequest;
    result: ListClientsResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "list-notifications": {
    request: ListNotificationsRequest;
    result: ListNotificationsResult;
    authority: "control";
    since: 12;
    capability: "notification-ack-v1";
    stream: null;
  };
  "list-personal": {
    request: ListPersonalRequest;
    result: ListPersonalResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "list-saved-screen-groups": {
    request: ListSavedScreenGroupsRequest;
    result: ListSavedScreenGroupsResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "list-saved-tab-groups": {
    request: ListSavedTabGroupsRequest;
    result: ListSavedTabGroupsResult;
    authority: "control";
    since: 12;
    capability: "saved-tab-groups-v1";
    stream: null;
  };
  "list-tab-groups": {
    request: ListTabGroupsRequest;
    result: ListTabGroupsResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "list-terminals": {
    request: ListTerminalsRequest;
    result: T.ListTerminalsResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "list-workspace-groups": {
    request: ListWorkspaceGroupsRequest;
    result: ListWorkspaceGroupsResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "list-workspaces": {
    request: ListWorkspacesRequest;
    result: ListWorkspacesResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "machine-listening-tcp": {
    request: MachineListeningTcpRequest;
    result: T.MachineListeningTcpResult;
    authority: "control";
    since: 12;
    capability: "machine-listening-tcp-v1";
    stream: null;
  };
  "machine-usage": {
    request: MachineUsageRequest;
    result: T.MachineUsageResult;
    authority: "control";
    since: 12;
    capability: "machine-usage-v1";
    stream: null;
  };
  "mark-workspaces-provider-managed": {
    request: MarkWorkspacesProviderManagedRequest;
    result: MarkWorkspacesProviderManagedResult;
    authority: "provider-authority";
    since: 9;
    capability: "provider-managed-workspace-authority-v2";
    stream: null;
  };
  "mint-terminal-renderer": {
    request: MintTerminalRendererRequest;
    result: T.MintTerminalRendererResult;
    authority: "frontend";
    since: 9;
    capability: null;
    stream: null;
  };
  "mint-terminal-renderer-by-terminal": {
    request: MintTerminalRendererByTerminalRequest;
    result: MintTerminalRendererByTerminalResult;
    authority: "frontend";
    since: 11;
    capability: null;
    stream: null;
  };
  "move-bookmark": {
    request: MoveBookmarkRequest;
    result: MoveBookmarkResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "move-browser-profile": {
    request: MoveBrowserProfileRequest;
    result: MoveBrowserProfileResult;
    authority: "control";
    since: 12;
    capability: "browser-profiles-v1";
    stream: null;
  };
  "move-personal-group": {
    request: MovePersonalGroupRequest;
    result: MovePersonalGroupResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "move-profile": {
    request: MoveProfileRequest;
    result: MoveProfileResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "move-screen": {
    request: MoveScreenRequest;
    result: MoveScreenResult;
    authority: "control";
    since: 12;
    capability: "screen-metadata-v1";
    stream: null;
  };
  "move-screen-group": {
    request: MoveScreenGroupRequest;
    result: MoveScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "move-tab": {
    request: MoveTabRequest;
    result: MoveTabResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "move-tab-group": {
    request: MoveTabGroupRequest;
    result: MoveTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "move-tab-group-to-column": {
    request: MoveTabGroupToColumnRequest;
    result: MoveTabGroupToColumnResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "move-tab-group-to-new-workspace": {
    request: MoveTabGroupToNewWorkspaceRequest;
    result: MoveTabGroupToNewWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "move-tab-group-to-split": {
    request: MoveTabGroupToSplitRequest;
    result: MoveTabGroupToSplitResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "move-tab-to-column": {
    request: MoveTabToColumnRequest;
    result: MoveTabToColumnResult;
    authority: "control";
    since: 12;
    capability: "tab-drag-v1";
    stream: null;
  };
  "move-tab-to-new-workspace": {
    request: MoveTabToNewWorkspaceRequest;
    result: MoveTabToNewWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "tab-drag-v1";
    stream: null;
  };
  "move-tab-to-split": {
    request: MoveTabToSplitRequest;
    result: MoveTabToSplitResult;
    authority: "control";
    since: 12;
    capability: "tab-drag-v1";
    stream: null;
  };
  "move-tab-to-workspace": {
    request: MoveTabToWorkspaceRequest;
    result: MoveTabToWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "tab-workspace-move-v1";
    stream: null;
  };
  "move-terminal": {
    request: MoveTerminalRequest;
    result: T.MoveTerminalResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "move-workspace": {
    request: MoveWorkspaceRequest;
    result: MoveWorkspaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "move-workspace-group": {
    request: MoveWorkspaceGroupRequest;
    result: MoveWorkspaceGroupResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "move-workspace-to-group": {
    request: MoveWorkspaceToGroupRequest;
    result: MoveWorkspaceToGroupResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "new-browser-tab": {
    request: NewBrowserTabRequest;
    result: NewBrowserTabResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "new-conversation-tab": {
    request: NewConversationTabRequest;
    result: NewConversationTabResult;
    authority: "control";
    since: 12;
    capability: "conversation-tabs-v1";
    stream: null;
  };
  "new-frontend-browser-tab": {
    request: NewFrontendBrowserTabRequest;
    result: NewFrontendBrowserTabResult;
    authority: "control";
    since: 12;
    capability: "frontend-browser-tabs-v1";
    stream: null;
  };
  "new-pane": {
    request: NewPaneRequest;
    result: NewPaneResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "new-pane-right": {
    request: NewPaneRightRequest;
    result: NewPaneRightResult;
    authority: "control";
    since: 9;
    capability: "viewport-splits-v1";
    stream: null;
  };
  "new-row": {
    request: NewRowRequest;
    result: T.NewRowResult;
    authority: "control";
    since: 12;
    capability: "rows-v1";
    stream: null;
  };
  "new-screen": {
    request: NewScreenRequest;
    result: NewScreenResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "new-tab": {
    request: NewTabRequest;
    result: NewTabResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "new-workspace": {
    request: NewWorkspaceRequest;
    result: NewWorkspaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "note-size-activity": {
    request: NoteSizeActivityRequest;
    result: T.NoteSizeActivityResult;
    authority: "control";
    since: 12;
    capability: "shared-sizing-v1";
    stream: null;
  };
  "notify": {
    request: NotifyRequest;
    result: T.NotifyResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "pairing-response": {
    request: PairingResponseRequest;
    result: PairingResponseResult;
    authority: "local-admin";
    since: 7;
    capability: null;
    stream: null;
  };
  "pane-neighbor": {
    request: PaneNeighborRequest;
    result: T.PaneNeighborResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "paste-image": {
    request: PasteImageRequest;
    result: PasteImageResult;
    authority: "control";
    since: 12;
    capability: "terminal-image-paste-v1";
    stream: null;
  };
  "pin-workspace": {
    request: PinWorkspaceRequest;
    result: PinWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "ping": {
    request: PingRequest;
    result: T.PingResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "process-info": {
    request: ProcessInfoRequest;
    result: T.ProcessInfoResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "put-frontend-projection": {
    request: PutFrontendProjectionRequest;
    result: PutFrontendProjectionResult;
    authority: "control";
    since: 7;
    capability: null;
    stream: null;
  };
  "put-session": {
    request: PutSessionRequest;
    result: PutSessionResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "read-screen": {
    request: ReadScreenRequest;
    result: T.ReadScreenResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "read-scrollback": {
    request: ReadScrollbackRequest;
    result: T.ReadScrollbackResult;
    authority: "control";
    since: 7;
    capability: null;
    stream: null;
  };
  "reattach-view": {
    request: ReattachViewRequest;
    result: T.ReattachViewResult;
    authority: "control";
    since: 12;
    capability: "sizing-view-detach-v1";
    stream: null;
  };
  "register-browser-provider": {
    request: RegisterBrowserProviderRequest;
    result: RegisterBrowserProviderResult;
    authority: "local-admin";
    since: 10;
    capability: "browser-provider-v1";
    stream: null;
  };
  "release-attached-view-size": {
    request: ReleaseAttachedViewSizeRequest;
    result: ReleaseAttachedViewSizeResult;
    authority: "frontend";
    since: 10;
    capability: "view-attachment-lease-v1";
    stream: null;
  };
  "release-surface-size": {
    request: ReleaseSurfaceSizeRequest;
    result: ReleaseSurfaceSizeResult;
    authority: "control";
    since: 7;
    capability: null;
    stream: null;
  };
  "reload-config": {
    request: ReloadConfigRequest;
    result: ReloadConfigResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "remove-screens-from-screen-group": {
    request: RemoveScreensFromScreenGroupRequest;
    result: RemoveScreensFromScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "remove-tabs-from-tab-group": {
    request: RemoveTabsFromTabGroupRequest;
    result: RemoveTabsFromTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "rename-pane": {
    request: RenamePaneRequest;
    result: RenamePaneResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "rename-provider-managed-workspace": {
    request: RenameProviderManagedWorkspaceRequest;
    result: RenameProviderManagedWorkspaceResult;
    authority: "provider-authority";
    since: 9;
    capability: "provider-managed-workspace-authority-v2";
    stream: null;
  };
  "rename-screen": {
    request: RenameScreenRequest;
    result: RenameScreenResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "rename-surface": {
    request: RenameSurfaceRequest;
    result: RenameSurfaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "rename-workspace": {
    request: RenameWorkspaceRequest;
    result: RenameWorkspaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "reopen-saved-screen-group": {
    request: ReopenSavedScreenGroupRequest;
    result: ReopenSavedScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "reopen-saved-tab-group": {
    request: ReopenSavedTabGroupRequest;
    result: ReopenSavedTabGroupResult;
    authority: "control";
    since: 12;
    capability: "saved-tab-groups-v1";
    stream: null;
  };
  "report-agent": {
    request: ReportAgentRequest;
    result: T.ReportAgentResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "report-focus": {
    request: ReportFocusRequest;
    result: ReportFocusResult;
    authority: "control";
    since: 12;
    capability: "client-focus-v1";
    stream: null;
  };
  "resize-attached-view": {
    request: ResizeAttachedViewRequest;
    result: ResizeAttachedViewResult;
    authority: "frontend";
    since: 10;
    capability: "view-attachment-lease-v1";
    stream: null;
  };
  "resize-surface": {
    request: ResizeSurfaceRequest;
    result: T.ResizeSurfaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "resolve-terminal": {
    request: ResolveTerminalRequest;
    result: T.ResolveTerminalResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "run": {
    request: RunRequest;
    result: T.RunResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "save-screen-group": {
    request: SaveScreenGroupRequest;
    result: SaveScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "save-tab-group": {
    request: SaveTabGroupRequest;
    result: SaveTabGroupResult;
    authority: "control";
    since: 12;
    capability: "saved-tab-groups-v1";
    stream: null;
  };
  "scroll-surface": {
    request: ScrollSurfaceRequest;
    result: ScrollSurfaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "select-screen": {
    request: SelectScreenRequest;
    result: SelectScreenResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "select-tab": {
    request: SelectTabRequest;
    result: SelectTabResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "select-workspace": {
    request: SelectWorkspaceRequest;
    result: SelectWorkspaceResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "send": {
    request: SendRequest;
    result: SendResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "send-key": {
    request: SendKeyRequest;
    result: SendKeyResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "server-stats": {
    request: ServerStatsRequest;
    result: T.ServerStatsResult;
    authority: "local-admin";
    since: 12;
    capability: "server-stats-v1";
    stream: null;
  };
  "set-cell-pixels": {
    request: SetCellPixelsRequest;
    result: T.SetCellPixelsResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "set-client-info": {
    request: SetClientInfoRequest;
    result: SetClientInfoResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "set-client-sizing": {
    request: SetClientSizingRequest;
    result: SetClientSizingResult;
    authority: "control";
    since: 10;
    capability: null;
    stream: null;
  };
  "set-column-dock": {
    request: SetColumnDockRequest;
    result: SetColumnDockResult;
    authority: "control";
    since: 12;
    capability: "dock-columns-v1";
    stream: null;
  };
  "set-default-colors": {
    request: SetDefaultColorsRequest;
    result: SetDefaultColorsResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "set-frontend-browser-history": {
    request: SetFrontendBrowserHistoryRequest;
    result: SetFrontendBrowserHistoryResult;
    authority: "control";
    since: 12;
    capability: "frontend-browser-history-v1";
    stream: null;
  };
  "set-personal-terminal": {
    request: SetPersonalTerminalRequest;
    result: SetPersonalTerminalResult;
    authority: "control";
    since: 12;
    capability: "personal-terminals-v1";
    stream: null;
  };
  "set-personal-workspace": {
    request: SetPersonalWorkspaceRequest;
    result: SetPersonalWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "set-profile-follows": {
    request: SetProfileFollowsRequest;
    result: SetProfileFollowsResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "set-ratio": {
    request: SetRatioRequest;
    result: SetRatioResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "set-row-heights": {
    request: SetRowHeightsRequest;
    result: SetRowHeightsResult;
    authority: "control";
    since: 12;
    capability: "rows-v1";
    stream: null;
  };
  "set-screen-metadata": {
    request: SetScreenMetadataRequest;
    result: SetScreenMetadataResult;
    authority: "control";
    since: 12;
    capability: "screen-metadata-v1";
    stream: null;
  };
  "set-screen-pinned": {
    request: SetScreenPinnedRequest;
    result: SetScreenPinnedResult;
    authority: "control";
    since: 12;
    capability: "screen-metadata-v1";
    stream: null;
  };
  "set-size-counts": {
    request: SetSizeCountsRequest;
    result: T.SetSizeCountsResult;
    authority: "control";
    since: 12;
    capability: "shared-sizing-v1";
    stream: null;
  };
  "set-size-policy": {
    request: SetSizePolicyRequest;
    result: T.SetSizePolicyResult;
    authority: "control";
    since: 12;
    capability: "shared-sizing-v1";
    stream: null;
  };
  "set-split-ratio": {
    request: SetSplitRatioRequest;
    result: SetSplitRatioResult;
    authority: "control";
    since: 8;
    capability: null;
    stream: null;
  };
  "set-tab-pinned": {
    request: SetTabPinnedRequest;
    result: SetTabPinnedResult;
    authority: "control";
    since: 12;
    capability: "tab-metadata-v1";
    stream: null;
  };
  "set-terminal-command-history": {
    request: SetTerminalCommandHistoryRequest;
    result: SetTerminalCommandHistoryResult;
    authority: "local-admin";
    since: 12;
    capability: "terminal-command-journal-v1";
    stream: null;
  };
  "set-terminal-idle-policy": {
    request: SetTerminalIdlePolicyRequest;
    result: T.SetTerminalIdlePolicyResult;
    authority: "control";
    since: 12;
    capability: "terminal-idle-close-v1";
    stream: null;
  };
  "set-terminal-keep": {
    request: SetTerminalKeepRequest;
    result: T.SetTerminalKeepResult;
    authority: "control";
    since: 12;
    capability: "terminal-reap-v1";
    stream: null;
  };
  "set-viewport-pane-width": {
    request: SetViewportPaneWidthRequest;
    result: SetViewportPaneWidthResult;
    authority: "control";
    since: 9;
    capability: "viewport-column-resize-v1";
    stream: null;
  };
  "set-window-title": {
    request: SetWindowTitleRequest;
    result: SetWindowTitleResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "set-workspace-metadata": {
    request: SetWorkspaceMetadataRequest;
    result: SetWorkspaceMetadataResult;
    authority: "control";
    since: 12;
    capability: "workspace-metadata-v1";
    stream: null;
  };
  "shutdown-daemon": {
    request: ShutdownDaemonRequest;
    result: T.ShutdownDaemonResult;
    authority: "local-admin";
    since: 9;
    capability: null;
    stream: null;
  };
  "sidebar-plugin": {
    request: SidebarPluginRequest;
    result: T.SidebarPluginResult;
    authority: "frontend";
    since: 6;
    capability: null;
    stream: null;
  };
  "snapshot-request": {
    request: SnapshotRequestRequest;
    result: T.SnapshotRequestResult;
    authority: "frontend";
    since: 12;
    capability: "terminal-snapshot-v1";
    stream: null;
  };
  "split": {
    request: SplitRequest;
    result: SplitResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "subscribe": {
    request: SubscribeRequest;
    result: SubscribeResult;
    authority: "frontend";
    since: 5;
    capability: null;
    stream: "subscribe";
  };
  "swap-pane": {
    request: SwapPaneRequest;
    result: SwapPaneResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "terminal-events": {
    request: TerminalEventsRequest;
    result: T.TerminalEventsResult;
    authority: "control";
    since: 9;
    capability: null;
    stream: null;
  };
  "terminal-history": {
    request: TerminalHistoryRequest;
    result: TerminalHistoryResult;
    authority: "control";
    since: 12;
    capability: "terminal-snapshot-v1";
    stream: null;
  };
  "terminal-read-range": {
    request: TerminalReadRangeRequest;
    result: T.TerminalReadRangeResult;
    authority: "control";
    since: 12;
    capability: "terminal-snapshot-v1";
    stream: null;
  };
  "terminal-resources": {
    request: TerminalResourcesRequest;
    result: T.TerminalResourcesResult;
    authority: "control";
    since: 12;
    capability: "terminal-resources-v1";
    stream: null;
  };
  "undo-layout": {
    request: UndoLayoutRequest;
    result: UndoLayoutResult;
    authority: "control";
    since: 9;
    capability: "layout-undo-v1";
    stream: null;
  };
  "ungroup-screen-group": {
    request: UngroupScreenGroupRequest;
    result: UngroupScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "ungroup-tab-group": {
    request: UngroupTabGroupRequest;
    result: UngroupTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "unpin-workspace": {
    request: UnpinWorkspaceRequest;
    result: UnpinWorkspaceResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "unregister-browser-provider": {
    request: UnregisterBrowserProviderRequest;
    result: UnregisterBrowserProviderResult;
    authority: "local-admin";
    since: 10;
    capability: "browser-provider-v1";
    stream: null;
  };
  "unsave-screen-group": {
    request: UnsaveScreenGroupRequest;
    result: UnsaveScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "unsave-tab-group": {
    request: UnsaveTabGroupRequest;
    result: UnsaveTabGroupResult;
    authority: "control";
    since: 12;
    capability: "saved-tab-groups-v1";
    stream: null;
  };
  "update-bookmark": {
    request: UpdateBookmarkRequest;
    result: UpdateBookmarkResult;
    authority: "control";
    since: 12;
    capability: "bookmarks-v1";
    stream: null;
  };
  "update-browser-profile": {
    request: UpdateBrowserProfileRequest;
    result: UpdateBrowserProfileResult;
    authority: "control";
    since: 12;
    capability: "browser-profiles-v1";
    stream: null;
  };
  "update-frontend-browser-tab": {
    request: UpdateFrontendBrowserTabRequest;
    result: UpdateFrontendBrowserTabResult;
    authority: "control";
    since: 12;
    capability: "frontend-browser-tabs-v1";
    stream: null;
  };
  "update-personal-group": {
    request: UpdatePersonalGroupRequest;
    result: UpdatePersonalGroupResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "update-profile": {
    request: UpdateProfileRequest;
    result: UpdateProfileResult;
    authority: "control";
    since: 12;
    capability: "profiles-v1";
    stream: null;
  };
  "update-screen-group": {
    request: UpdateScreenGroupRequest;
    result: UpdateScreenGroupResult;
    authority: "control";
    since: 12;
    capability: "screen-groups-v1";
    stream: null;
  };
  "update-tab-group": {
    request: UpdateTabGroupRequest;
    result: UpdateTabGroupResult;
    authority: "control";
    since: 12;
    capability: "tab-groups-v1";
    stream: null;
  };
  "update-workspace-group": {
    request: UpdateWorkspaceGroupRequest;
    result: UpdateWorkspaceGroupResult;
    authority: "control";
    since: 12;
    capability: "workspace-groups-v1";
    stream: null;
  };
  "url-open": {
    request: UrlOpenRequest;
    result: UrlOpenResult;
    authority: "local-admin";
    since: 12;
    capability: null;
    stream: null;
  };
  "url-open-claim": {
    request: UrlOpenClaimRequest;
    result: UrlOpenClaimResult;
    authority: "frontend";
    since: 12;
    capability: null;
    stream: null;
  };
  "url-open-result": {
    request: UrlOpenResultRequest;
    result: UrlOpenResultResult;
    authority: "frontend";
    since: 12;
    capability: null;
    stream: null;
  };
  "url-open-subscribe": {
    request: UrlOpenSubscribeRequest;
    result: UrlOpenSubscribeResult;
    authority: "frontend";
    since: 12;
    capability: null;
    stream: "subscribe";
  };
  "vt-state": {
    request: VtStateRequest;
    result: T.VtStateResult;
    authority: "control";
    since: 5;
    capability: null;
    stream: null;
  };
  "wait-for": {
    request: WaitForRequest;
    result: T.WaitForResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
  "zoom-pane": {
    request: ZoomPaneRequest;
    result: T.ZoomPaneResult;
    authority: "control";
    since: 6;
    capability: null;
    stream: null;
  };
}

export type CmuxCommand = keyof CmuxCommandDefinitionMap;
export type CmuxRequestFor<C extends CmuxCommand> =
  CmuxCommandDefinitionMap[C]["request"];
type DistributiveOmit<V, K extends PropertyKey> =
  V extends unknown ? Omit<V, Extract<keyof V, K>> : never;
export type CmuxRequestParams<C extends CmuxCommand> =
  DistributiveOmit<CmuxRequestFor<C>, "id" | "cmd">;
export type CmuxResponseDataFor<C extends CmuxCommand> =
  CmuxCommandDefinitionMap[C]["result"];
export type CmuxResponseData<R extends CmuxRequest> =
  CmuxResponseDataFor<R["cmd"]>;
export type CmuxAuthorityFor<C extends CmuxCommand> =
  CmuxCommandDefinitionMap[C]["authority"];
export type CmuxSinceFor<C extends CmuxCommand> =
  CmuxCommandDefinitionMap[C]["since"];

/** Canonical typed call surface. Convenience methods are handwritten. */
export interface CmuxCommandCaller {
  request<R extends CmuxRequest>(request: R): Promise<CmuxResponseData<R>>;
  request<C extends CmuxCommand>(
    command: C,
    ...args: Record<string, never> extends CmuxRequestParams<C>
      ? [params?: CmuxRequestParams<C>]
      : [params: CmuxRequestParams<C>]
  ): Promise<CmuxResponseDataFor<C>>;
}
