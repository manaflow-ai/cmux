import type {
  AgentRecord,
  AgentReportSource,
  AgentState,
  Base64,
  CmuxRequestBase,
  ColorHex,
  EmptyResult,
  Id,
  IdRef,
  NotificationLevel,
  PaneDirection,
  SplitDirection,
} from "./common.js";
import type { DeclarativeLayout, Layout, Tree } from "./tree.js";
import type { RenderRow } from "./render.js";

export interface IdentifyRequest extends CmuxRequestBase { cmd: "identify" }
export interface IdentifyResult {
  app: "cmux-tui";
  version: string;
  build_commit?: string | null;
  ghostty_commit?: string | null;
  protocol: number;
  capabilities?: string[];
  session: string;
  pid: number;
}

export interface PingRequest extends CmuxRequestBase { cmd: "ping" }
export interface PingResult {
  ok: true;
  version: string;
  build_commit?: string | null;
  ghostty_commit?: string | null;
  protocol: number;
}

export interface SetClientInfoRequest extends CmuxRequestBase {
  cmd: "set-client-info";
  name?: string;
  kind?: string;
}

export interface ListClientsRequest extends CmuxRequestBase { cmd: "list-clients" }
export type ClientTransport = "local" | "unix" | "ws";
export interface ClientSize {
  surface: Id;
  cols: number | null;
  rows: number | null;
}
export interface ClientInfo {
  client: Id;
  transport: ClientTransport;
  name: string | null;
  kind: string | null;
  connected_seconds: number;
  attached: Id[];
  sizes: ClientSize[];
  self: boolean;
  size_participating: boolean;
}
export type ListClientsResult = ClientInfo[];

export interface DetachClientRequest extends CmuxRequestBase { cmd: "detach-client"; client: Id }
export interface SetClientSizingRequest extends CmuxRequestBase {
  cmd: "set-client-sizing";
  client?: Id;
  enabled: boolean;
  exclusive?: boolean;
}

export interface ReloadConfigRequest extends CmuxRequestBase { cmd: "reload-config" }
export interface ReloadConfigResult { reloaded: true; path: string | null }

export interface SetWindowTitleRequest extends CmuxRequestBase { cmd: "set-window-title"; title: string }
export interface ClearWindowTitleRequest extends CmuxRequestBase { cmd: "clear-window-title" }

export interface ListWorkspacesRequest extends CmuxRequestBase { cmd: "list-workspaces" }

export interface ExportLayoutRequest extends CmuxRequestBase {
  cmd: "export-layout";
  screen?: Id | null;
}
export interface ExportedPane { pane: Id; surfaces: Id[] }
export interface ExportLayoutResult { layout: Layout; panes: ExportedPane[] }

export interface ApplyLayoutRequest extends CmuxRequestBase {
  cmd: "apply-layout";
  workspace?: Id | null;
  name?: string | null;
  layout: DeclarativeLayout;
}
export interface AppliedPane { pane: Id; surface: Id }
export interface ApplyLayoutResult { screen: Id; panes: AppliedPane[] }

export interface SendRequest extends CmuxRequestBase {
  cmd: "send";
  surface: Id;
  /** When both are supplied, `text` is written before `bytes`. */
  text?: string | null;
  bytes?: Base64 | null;
  /** Protocol v7 bracketed-paste request. */
  paste?: boolean;
}

export interface ReadScreenRequest extends CmuxRequestBase { cmd: "read-screen"; surface: Id }
export interface ReadScreenResult { text: string }

export interface ReadScrollbackRequest extends CmuxRequestBase {
  cmd: "read-scrollback";
  surface: Id;
  start: number;
  count: number;
}
export interface ReadScrollbackResult {
  rows: RenderRow[];
  start: number;
  total: number;
}

export interface SidebarPluginRequest extends CmuxRequestBase {
  cmd: "sidebar-plugin";
  cols: number;
  rows: number;
  relaunch?: boolean | null;
}
export interface SidebarPluginResult {
  surface: Id | null;
  error: string | null;
  retry_after_ms: number | null;
}

export interface VtStateRequest extends CmuxRequestBase { cmd: "vt-state"; surface: Id }
export interface VtStateResult { cols: number; rows: number; data: Base64 }

export interface NewTabRequest extends CmuxRequestBase {
  cmd: "new-tab";
  pane?: Id | null;
  cwd?: string | null;
  /** `cols` is used only when paired with `rows`. */
  cols?: number | null;
  rows?: number | null;
}

export interface NewBrowserTabRequest extends CmuxRequestBase {
  cmd: "new-browser-tab";
  url: string;
  pane?: Id | null;
  cols?: number | null;
  rows?: number | null;
}

export interface NewWorkspaceRequest extends CmuxRequestBase {
  cmd: "new-workspace";
  name?: string | null;
  cols?: number | null;
  rows?: number | null;
}

export interface CreateWorkspaceRequest extends CmuxRequestBase {
  cmd: "create-workspace";
  name?: string | null;
  key?: string | null;
  expected_revision?: number | null;
}

export interface WorkspacePlacement {
  workspace: Id;
  key: string;
  index: number;
  workspace_revision: number;
}

export type WorkspaceSelector =
  | { workspace: Id; key?: string | null }
  | { key: string; workspace?: Id | null };

interface CreateTerminalRequestBase extends CmuxRequestBase {
  cmd: "create-terminal";
  argv?: string[] | null;
  command?: string | null;
  cwd?: string | null;
  name?: string | null;
  cols?: number | null;
  rows?: number | null;
}
export type CreateTerminalRequest = CreateTerminalRequestBase & WorkspaceSelector;

export interface TerminalPlacement {
  surface: Id;
  pane: Id;
  screen: Id;
  workspace: Id;
  key: string;
}

export interface NewScreenRequest extends CmuxRequestBase {
  cmd: "new-screen";
  workspace?: Id | null;
  cols?: number | null;
  rows?: number | null;
}

export interface NewPaneRequest extends CmuxRequestBase {
  cmd: "new-pane";
  pane: Id;
  cols?: number | null;
  rows?: number | null;
}

export interface SplitRequest extends CmuxRequestBase {
  cmd: "split";
  pane: Id;
  dir: SplitDirection;
  cols?: number | null;
  rows?: number | null;
}

export interface SurfaceResult { surface: Id }

export interface SetRatioRequest extends CmuxRequestBase {
  cmd: "set-ratio";
  pane: Id;
  dir: SplitDirection;
  /** The server clamps this value to `0.05..0.95`. */
  ratio: number;
}

export interface SetSplitRatioRequest extends CmuxRequestBase {
  cmd: "set-split-ratio";
  split: Id;
  /** The server clamps this value to `0.05..0.95`. */
  ratio: number;
}

export interface PaneNeighborRequest extends CmuxRequestBase { cmd: "pane-neighbor"; pane: Id; dir: PaneDirection }
export interface PaneNeighborResult { pane: Id | null }

export interface FocusDirectionRequest extends CmuxRequestBase {
  cmd: "focus-direction";
  pane?: Id | null;
  dir: PaneDirection;
}
export interface FocusDirectionResult { pane: Id }

interface SwapPaneRequestBase extends CmuxRequestBase { cmd: "swap-pane"; pane: Id }
export type SwapPaneRequest =
  | (SwapPaneRequestBase & { dir: PaneDirection; target?: null })
  | (SwapPaneRequestBase & { target: Id; dir?: null });

export interface ZoomPaneRequest extends CmuxRequestBase {
  cmd: "zoom-pane";
  pane?: Id | null;
  mode?: "toggle" | "on" | "off" | null;
}
export interface ZoomPaneResult { pane: Id; zoomed: boolean; zoomed_pane: Id | null }

export interface ProcessInfoRequest extends CmuxRequestBase { cmd: "process-info"; surface: Id }
export interface ProcessInfoResult { pid: number | null; command: string | null; cwd: string | null }

export interface SetDefaultColorsRequest extends CmuxRequestBase {
  cmd: "set-default-colors";
  fg?: ColorHex | null;
  bg?: ColorHex | null;
}

export interface CloseSurfaceRequest extends CmuxRequestBase { cmd: "close-surface"; surface: Id }
export interface ClosePaneRequest extends CmuxRequestBase { cmd: "close-pane"; pane: Id }
export interface CloseScreenRequest extends CmuxRequestBase { cmd: "close-screen"; screen: Id }
export interface WorkspaceMutation {
  workspace: Id;
  key: string;
  workspace_revision: number;
}
interface CloseWorkspaceRequestBase extends CmuxRequestBase {
  cmd: "close-workspace";
  expected_revision?: number | null;
}
export type CloseWorkspaceRequest = CloseWorkspaceRequestBase & WorkspaceSelector;

export interface RenamePaneRequest extends CmuxRequestBase { cmd: "rename-pane"; pane: Id; name: string }
export interface RenameSurfaceRequest extends CmuxRequestBase { cmd: "rename-surface"; surface: Id; name: string }
export interface RenameScreenRequest extends CmuxRequestBase { cmd: "rename-screen"; screen: Id; name: string }
interface RenameWorkspaceRequestBase extends CmuxRequestBase {
  cmd: "rename-workspace";
  name: string;
  expected_revision?: number | null;
}
export type RenameWorkspaceRequest = RenameWorkspaceRequestBase & WorkspaceSelector;

export interface ResizeSurfaceRequest extends CmuxRequestBase {
  cmd: "resize-surface";
  surface: Id;
  cols: number;
  rows: number;
}
export interface ResizeSurfaceResult { accepted: boolean; reservation_id?: number | null }
export interface ReleaseSurfaceSizeRequest extends CmuxRequestBase {
  cmd: "release-surface-size";
  surface: Id;
}

export interface FocusPaneRequest extends CmuxRequestBase { cmd: "focus-pane"; pane: Id }

export interface SelectTabRequest extends CmuxRequestBase {
  cmd: "select-tab";
  pane?: Id | null;
  /** If both selectors are present, `index` wins. */
  index?: number | null;
  delta?: number | null;
}

export interface SelectScreenRequest extends CmuxRequestBase {
  cmd: "select-screen";
  /** If both selectors are present, `index` wins. */
  index?: number | null;
  delta?: number | null;
}

export interface SelectWorkspaceRequest extends CmuxRequestBase {
  cmd: "select-workspace";
  /** If both selectors are present, `index` wins. */
  index?: number | null;
  delta?: number | null;
}

export interface MoveTabRequest extends CmuxRequestBase { cmd: "move-tab"; surface: Id; pane: Id; index: number }
interface MoveWorkspaceRequestBase extends CmuxRequestBase {
  cmd: "move-workspace";
  index: number;
  expected_revision?: number | null;
}
export type MoveWorkspaceRequest = MoveWorkspaceRequestBase & WorkspaceSelector;
export interface ScrollSurfaceRequest extends CmuxRequestBase { cmd: "scroll-surface"; surface: Id; delta: number }

export interface SubscribeRequest extends CmuxRequestBase {
  cmd: "subscribe";
  /** Protocol v7 tree lifecycle delivery mode. */
  tree_events?: "coarse" | "deltas";
}

export interface AttachSurfaceRequest extends CmuxRequestBase {
  cmd: "attach-surface";
  surface: Id;
  mode?: "bytes" | "render";
  cols?: number;
  rows?: number;
}

export interface WaitForRequest extends CmuxRequestBase {
  cmd: "wait-for";
  surface: IdRef;
  pattern: string;
  /** `0` performs one immediate check. */
  timeout_ms: number;
}
export interface WaitForResult { matched: true; text: string; elapsed_ms: number }

interface RunRequestBase extends CmuxRequestBase {
  cmd: "run";
  cwd?: string | null;
  pane?: IdRef | null;
  new_workspace?: boolean;
  name?: string | null;
  cols?: number | null;
  rows?: number | null;
}
export type RunRequest =
  | (RunRequestBase & { argv: string[]; command?: null })
  | (RunRequestBase & { command: string; argv?: null });
export interface RunResult { surface: Id; pane: Id; screen: Id; workspace: Id }

export interface SendKeyRequest extends CmuxRequestBase { cmd: "send-key"; surface: IdRef; keys: string[] }

export type CopyMode = "screen" | "selection" | "scrollback";
export interface CopyRequest extends CmuxRequestBase { cmd: "copy"; surface: IdRef; mode: CopyMode }
export interface CopyResult { text: string; mode: CopyMode }

export type IdKind = "workspace" | "screen" | "pane" | "surface";
export interface IdsRequest extends CmuxRequestBase { cmd: "ids"; kind?: IdKind | null }
export interface IdMapping { kind: IdKind; id: Id; short_id: string }
export interface IdsResult { ids: IdMapping[] }

export interface NotifyRequest extends CmuxRequestBase {
  cmd: "notify";
  title: string;
  body: string;
  level?: NotificationLevel | null;
  surface?: IdRef | null;
}
export interface NotifyResult { notification: Id }

export interface ListAgentsRequest extends CmuxRequestBase {
  cmd: "list-agents";
  surface?: IdRef | null;
  state?: AgentState | null;
}
export interface ListAgentsResult { agents: AgentRecord[] }

export interface ReportAgentRequest extends CmuxRequestBase {
  cmd: "report-agent";
  surface: IdRef;
  state: AgentState;
  source: AgentReportSource;
  session?: string | null;
}
export interface ReportAgentResult {
  surface: Id;
  state: AgentState;
  source: AgentReportSource;
  session: string | null;
}

/** Every implemented command request, discriminated by exact wire `cmd`. */
export type CmuxRequest =
  | IdentifyRequest
  | PingRequest
  | SetClientInfoRequest
  | ListClientsRequest
  | DetachClientRequest
  | SetClientSizingRequest
  | ReloadConfigRequest
  | SetWindowTitleRequest
  | ClearWindowTitleRequest
  | ListWorkspacesRequest
  | ExportLayoutRequest
  | ApplyLayoutRequest
  | SendRequest
  | ReadScreenRequest
  | ReadScrollbackRequest
  | SidebarPluginRequest
  | VtStateRequest
  | NewTabRequest
  | NewBrowserTabRequest
  | NewWorkspaceRequest
  | CreateWorkspaceRequest
  | CreateTerminalRequest
  | NewScreenRequest
  | NewPaneRequest
  | SplitRequest
  | SetRatioRequest
  | SetSplitRatioRequest
  | PaneNeighborRequest
  | FocusDirectionRequest
  | SwapPaneRequest
  | ZoomPaneRequest
  | ProcessInfoRequest
  | SetDefaultColorsRequest
  | CloseSurfaceRequest
  | ClosePaneRequest
  | CloseScreenRequest
  | CloseWorkspaceRequest
  | RenamePaneRequest
  | RenameSurfaceRequest
  | RenameScreenRequest
  | RenameWorkspaceRequest
  | ResizeSurfaceRequest
  | ReleaseSurfaceSizeRequest
  | FocusPaneRequest
  | SelectTabRequest
  | SelectScreenRequest
  | SelectWorkspaceRequest
  | MoveTabRequest
  | MoveWorkspaceRequest
  | ScrollSurfaceRequest
  | SubscribeRequest
  | AttachSurfaceRequest
  | WaitForRequest
  | RunRequest
  | SendKeyRequest
  | CopyRequest
  | IdsRequest
  | NotifyRequest
  | ListAgentsRequest
  | ReportAgentRequest;

/** Command name to successful response `data` mapping. */
export interface CmuxResponseDataMap {
  identify: IdentifyResult;
  ping: PingResult;
  "set-client-info": EmptyResult;
  "list-clients": ListClientsResult;
  "detach-client": EmptyResult;
  "set-client-sizing": EmptyResult;
  "reload-config": ReloadConfigResult;
  "set-window-title": EmptyResult;
  "clear-window-title": EmptyResult;
  "list-workspaces": Tree;
  "export-layout": ExportLayoutResult;
  "apply-layout": ApplyLayoutResult;
  send: EmptyResult;
  "read-screen": ReadScreenResult;
  "read-scrollback": ReadScrollbackResult;
  "sidebar-plugin": SidebarPluginResult;
  "vt-state": VtStateResult;
  "new-tab": SurfaceResult;
  "new-browser-tab": SurfaceResult;
  "new-workspace": SurfaceResult;
  "create-workspace": WorkspacePlacement;
  "create-terminal": TerminalPlacement;
  "new-screen": SurfaceResult;
  "new-pane": SurfaceResult;
  split: SurfaceResult;
  "set-ratio": EmptyResult;
  "set-split-ratio": EmptyResult;
  "pane-neighbor": PaneNeighborResult;
  "focus-direction": FocusDirectionResult;
  "swap-pane": EmptyResult;
  "zoom-pane": ZoomPaneResult;
  "process-info": ProcessInfoResult;
  "set-default-colors": EmptyResult;
  "close-surface": EmptyResult;
  "close-pane": EmptyResult;
  "close-screen": EmptyResult;
  "close-workspace": EmptyResult | WorkspaceMutation;
  "rename-pane": EmptyResult;
  "rename-surface": EmptyResult;
  "rename-screen": EmptyResult;
  "rename-workspace": EmptyResult | WorkspaceMutation;
  "resize-surface": ResizeSurfaceResult;
  "release-surface-size": EmptyResult;
  "focus-pane": EmptyResult;
  "select-tab": EmptyResult;
  "select-screen": EmptyResult;
  "select-workspace": EmptyResult;
  "move-tab": EmptyResult;
  "move-workspace": EmptyResult | WorkspaceMutation;
  "scroll-surface": EmptyResult;
  subscribe: EmptyResult;
  "attach-surface": EmptyResult;
  "wait-for": WaitForResult;
  run: RunResult;
  "send-key": EmptyResult;
  copy: CopyResult;
  ids: IdsResult;
  notify: NotifyResult;
  "list-agents": ListAgentsResult;
  "report-agent": ReportAgentResult;
}

export type CmuxCommand = keyof CmuxResponseDataMap;
export type CmuxRequestFor<C extends CmuxCommand> = Extract<CmuxRequest, { cmd: C }>;
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, Extract<keyof T, K>> : never;
export type CmuxRequestParams<C extends CmuxCommand> = DistributiveOmit<CmuxRequestFor<C>, "id" | "cmd">;
export type CmuxResponseDataFor<C extends CmuxCommand> = CmuxResponseDataMap[C];
export type CmuxResponseData<C extends CmuxRequest> = CmuxResponseDataFor<C["cmd"]>;
