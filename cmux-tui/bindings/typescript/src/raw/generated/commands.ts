/* This file is generated. Do not edit by hand. */
/* cmux-tui mux protocol 12, IR 3abe68cfbb73abb8aab5265d34cdafd7207a111cbe9e1923c8637f5376abb929. */


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
  "mode"?: ("bytes" | "render") | null;
  "rows"?: (number) | null;
  "surface": T.Id;
}
export type AttachSurfaceResult = T.EmptyResult;

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
  "screen": T.Id;
}
export type CloseScreenResult = T.EmptyResult;

/** Protocol v5; authority: control. */
export interface CloseSurfaceRequest extends CmuxRequestBase {
  cmd: "close-surface";
  "surface": T.Id;
}
export type CloseSurfaceResult = T.EmptyResult;

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
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "origin"?: (string) | null;
  "workspace"?: (T.Id) | null;
}
export type CloseWorkspaceResult = T.WorkspaceMutationResult;

/** Protocol v6; authority: control. */
export interface CopyRequest extends CmuxRequestBase {
  cmd: "copy";
  "mode": "screen" | "selection" | "scrollback";
  "surface": T.Id;
}

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

/** Protocol v7; authority: control. */
export interface CreateTerminalRequest extends CmuxRequestBase {
  cmd: "create-terminal";
  "argv"?: (Array<string>) | null;
  "cols"?: (number) | null;
  "command"?: (string) | null;
  "cwd"?: (string) | null;
  "expected_generation"?: (string) | null;
  "expected_revision"?: (bigint) | null;
  "key"?: (string) | null;
  "mutation_id"?: (string) | null;
  "name"?: (string) | null;
  "origin"?: (string) | null;
  "rows"?: (number) | null;
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

/** Protocol v10; authority: frontend. */
export interface DetachAttachedViewRequest extends CmuxRequestBase {
  cmd: "detach-attached-view";
  "lease": string;
  "surface": T.Id;
}
export type DetachAttachedViewResult = T.AttachedViewOutcomeResult;

/** Protocol v6; authority: control. */
export interface DetachClientRequest extends CmuxRequestBase {
  cmd: "detach-client";
  "client": bigint;
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

/** Protocol v10; authority: local-admin. */
export interface GetBrowserProviderRequest extends CmuxRequestBase {
  cmd: "get-browser-provider";
}
export type GetBrowserProviderResult = T.BrowserProviderSnapshot;

/** Protocol v6; authority: frontend. */
export interface GetCellPixelsRequest extends CmuxRequestBase {
  cmd: "get-cell-pixels";
}

/** Protocol v7; authority: control. */
export interface GetFrontendProjectionRequest extends CmuxRequestBase {
  cmd: "get-frontend-projection";
  "frontend": string;
  "scope": string;
  "subject_key": string;
}
export type GetFrontendProjectionResult = T.FrontendProjection;

/** Protocol v5; authority: control. */
export interface IdentifyRequest extends CmuxRequestBase {
  cmd: "identify";
}

/** Protocol v6; authority: control. */
export interface IdsRequest extends CmuxRequestBase {
  cmd: "ids";
  "kind"?: ("workspace" | "screen" | "pane" | "surface") | null;
}

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

/** Protocol v6; authority: control. */
export interface ListClientsRequest extends CmuxRequestBase {
  cmd: "list-clients";
}
export type ListClientsResult = Array<T.ClientInfo>;

/** Protocol v9; authority: control. */
export interface ListTerminalsRequest extends CmuxRequestBase {
  cmd: "list-terminals";
}

/** Protocol v5; authority: control. */
export interface ListWorkspacesRequest extends CmuxRequestBase {
  cmd: "list-workspaces";
}
export type ListWorkspacesResult = T.Tree;

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

/** Protocol v5; authority: control. */
export interface MoveTabRequest extends CmuxRequestBase {
  cmd: "move-tab";
  "index": bigint;
  "pane": T.Id;
  "surface": T.Id;
}
export type MoveTabResult = T.EmptyResult;

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

/** Protocol v5; authority: control. */
export interface NewBrowserTabRequest extends CmuxRequestBase {
  cmd: "new-browser-tab";
  "cols"?: (number) | null;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
  "url": string;
}
export type NewBrowserTabResult = T.SurfaceResult;

/** Protocol v9; authority: control. */
export interface NewPaneRequest extends CmuxRequestBase {
  cmd: "new-pane";
  "cols"?: (number) | null;
  "pane": T.Id;
  "rows"?: (number) | null;
}
export type NewPaneResult = T.SurfaceResult;

/** Protocol v9; authority: control. */
export interface NewPaneRightRequest extends CmuxRequestBase {
  cmd: "new-pane-right";
  "cols"?: (number) | null;
  "pane": T.Id;
  "rows"?: (number) | null;
  "width"?: (number) | null;
}
export type NewPaneRightResult = T.SurfaceResult;

/** Protocol v5; authority: control. */
export interface NewScreenRequest extends CmuxRequestBase {
  cmd: "new-screen";
  "cols"?: (number) | null;
  "rows"?: (number) | null;
  "workspace"?: (T.Id) | null;
}
export type NewScreenResult = T.SurfaceResult;

/** Protocol v5; authority: control. */
export interface NewTabRequest extends CmuxRequestBase {
  cmd: "new-tab";
  "cols"?: (number) | null;
  "cwd"?: (string) | null;
  "pane"?: (T.Id) | null;
  "rows"?: (number) | null;
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

/** Protocol v6; authority: control. */
export interface NotifyRequest extends CmuxRequestBase {
  cmd: "notify";
  "body": string;
  "level"?: (T.NotificationLevel) | null;
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
  "lease": string;
  "surface": T.Id;
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
  "lease": string;
  "rows": number;
  "surface": T.Id;
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
  "kind"?: (string) | null;
  "name"?: (string) | null;
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

/** Protocol v5; authority: control. */
export interface SetRatioRequest extends CmuxRequestBase {
  cmd: "set-ratio";
  "dir": T.SplitDirection;
  "pane": T.Id;
  "ratio": number;
}
export type SetRatioResult = T.EmptyResult;

/** Protocol v8; authority: control. */
export interface SetSplitRatioRequest extends CmuxRequestBase {
  cmd: "set-split-ratio";
  "ratio": number;
  "split": T.Id;
  "transaction"?: (bigint) | null;
}
export type SetSplitRatioResult = T.EmptyResult;

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

/** Protocol v9; authority: local-admin. */
export interface ShutdownDaemonRequest extends CmuxRequestBase {
  cmd: "shutdown-daemon";
  "force"?: boolean;
  "generation": string;
  "pid": number;
}

/** Protocol v6; authority: frontend. */
export interface SidebarPluginRequest extends CmuxRequestBase {
  cmd: "sidebar-plugin";
  "cols": number;
  "relaunch"?: boolean;
  "rows": number;
}

/** Protocol v5; authority: control. */
export interface SplitRequest extends CmuxRequestBase {
  cmd: "split";
  "cols"?: (number) | null;
  "dir": T.SplitDirection;
  "pane": T.Id;
  "rows"?: (number) | null;
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

/** Protocol v9; authority: control. */
export interface UndoLayoutRequest extends CmuxRequestBase {
  cmd: "undo-layout";
  "confirm_close"?: boolean;
  "pane": T.Id;
  "revision"?: (bigint) | null;
}
export type UndoLayoutResult = T.LayoutUndoResult;

/** Protocol v10; authority: local-admin. */
export interface UnregisterBrowserProviderRequest extends CmuxRequestBase {
  cmd: "unregister-browser-provider";
}
export type UnregisterBrowserProviderResult = T.BrowserProviderUnregisterResult;

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
  | ApplyLayoutRequest
  | AttachSurfaceRequest
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
  | CloseSurfaceRequest
  | CloseTerminalRequest
  | CloseWorkspaceRequest
  | CopyRequest
  | CreateSurfaceWithReceiptRequest
  | CreateTerminalRequest
  | CreateWorkspaceRequest
  | DetachAttachedViewRequest
  | DetachClientRequest
  | ExportLayoutRequest
  | FocusDirectionRequest
  | FocusPaneRequest
  | GetBrowserProviderRequest
  | GetCellPixelsRequest
  | GetFrontendProjectionRequest
  | IdentifyRequest
  | IdsRequest
  | JournalFrontendEventRequest
  | ListAgentsRequest
  | ListClientsRequest
  | ListTerminalsRequest
  | ListWorkspacesRequest
  | MachineUsageRequest
  | MarkWorkspacesProviderManagedRequest
  | MintTerminalRendererRequest
  | MintTerminalRendererByTerminalRequest
  | MoveTabRequest
  | MoveTerminalRequest
  | MoveWorkspaceRequest
  | NewBrowserTabRequest
  | NewPaneRequest
  | NewPaneRightRequest
  | NewScreenRequest
  | NewTabRequest
  | NewWorkspaceRequest
  | NotifyRequest
  | PairingResponseRequest
  | PaneNeighborRequest
  | PingRequest
  | ProcessInfoRequest
  | PutFrontendProjectionRequest
  | ReadScreenRequest
  | ReadScrollbackRequest
  | RegisterBrowserProviderRequest
  | ReleaseAttachedViewSizeRequest
  | ReleaseSurfaceSizeRequest
  | ReloadConfigRequest
  | RenamePaneRequest
  | RenameProviderManagedWorkspaceRequest
  | RenameScreenRequest
  | RenameSurfaceRequest
  | RenameWorkspaceRequest
  | ReportAgentRequest
  | ReportFocusRequest
  | ResizeAttachedViewRequest
  | ResizeSurfaceRequest
  | ResolveTerminalRequest
  | RunRequest
  | ScrollSurfaceRequest
  | SelectScreenRequest
  | SelectTabRequest
  | SelectWorkspaceRequest
  | SendRequest
  | SendKeyRequest
  | SetCellPixelsRequest
  | SetClientInfoRequest
  | SetClientSizingRequest
  | SetDefaultColorsRequest
  | SetRatioRequest
  | SetSplitRatioRequest
  | SetViewportPaneWidthRequest
  | SetWindowTitleRequest
  | ShutdownDaemonRequest
  | SidebarPluginRequest
  | SplitRequest
  | SubscribeRequest
  | SwapPaneRequest
  | TerminalEventsRequest
  | UndoLayoutRequest
  | UnregisterBrowserProviderRequest
  | VtStateRequest
  | WaitForRequest
  | ZoomPaneRequest;

/** Command name to request, result, authority, and version mapping. */
export interface CmuxCommandDefinitionMap {
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
  "close-surface": {
    request: CloseSurfaceRequest;
    result: CloseSurfaceResult;
    authority: "control";
    since: 5;
    capability: null;
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
  "copy": {
    request: CopyRequest;
    result: T.CopyResult;
    authority: "control";
    since: 6;
    capability: null;
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
  "get-frontend-projection": {
    request: GetFrontendProjectionRequest;
    result: GetFrontendProjectionResult;
    authority: "control";
    since: 7;
    capability: null;
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
  "list-clients": {
    request: ListClientsRequest;
    result: ListClientsResult;
    authority: "control";
    since: 6;
    capability: null;
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
  "list-workspaces": {
    request: ListWorkspacesRequest;
    result: ListWorkspacesResult;
    authority: "control";
    since: 5;
    capability: null;
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
  "move-tab": {
    request: MoveTabRequest;
    result: MoveTabResult;
    authority: "control";
    since: 5;
    capability: null;
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
  "new-browser-tab": {
    request: NewBrowserTabRequest;
    result: NewBrowserTabResult;
    authority: "control";
    since: 5;
    capability: null;
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
  "set-default-colors": {
    request: SetDefaultColorsRequest;
    result: SetDefaultColorsResult;
    authority: "control";
    since: 5;
    capability: null;
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
  "set-split-ratio": {
    request: SetSplitRatioRequest;
    result: SetSplitRatioResult;
    authority: "control";
    since: 8;
    capability: null;
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
  "undo-layout": {
    request: UndoLayoutRequest;
    result: UndoLayoutResult;
    authority: "control";
    since: 9;
    capability: "layout-undo-v1";
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
