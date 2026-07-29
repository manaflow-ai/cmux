import type {
  AgentId,
  BrowserId,
  ConnectedClientId,
  DecimalString,
  MachineId,
  NotificationId,
  PairingRequestId,
  PaneId,
  ProjectionId,
  ProviderActionId,
  ProviderNoticeId,
  ProviderScopeId,
  ScreenId,
  SessionId,
  SidebarViewId,
  SplitId,
  StreamId,
  TabId,
  TerminalId,
  WorkspaceId,
} from "./ids.js";

export type Document = Readonly<Record<string, unknown>>;
export type ProviderActionValue = string | number;

class Secret {
  #value: string;
  #used = false;

  constructor(value: string, private readonly label: string) {
    if (!value) throw new TypeError(`${label} must be a non-empty string`);
    this.#value = value;
  }

  take(): string {
    if (this.#used) throw new Error(`${this.label} was already consumed`);
    this.#used = true;
    return this.#value;
  }

  toString(): string {
    return "<redacted>";
  }

  toJSON(): string {
    return "<redacted>";
  }
}

/** One-use renderer credential whose value is never publicly enumerable. */
export class RendererGrant extends Secret {
  constructor(
    value: string,
    readonly endpoint: string,
    readonly terminalId: TerminalId,
    readonly rights: readonly string[],
    readonly ttlMs: number,
  ) {
    super(value, "renderer grant");
  }
}

/** Provider credential whose value is never publicly enumerable. */
export class ProviderCredential extends Secret {
  constructor(readonly name: string, value: string) {
    if (!name) throw new TypeError("provider credential name must be non-empty");
    super(value, "provider credential");
  }

  toWire(): Readonly<{ name: string; value: string }> {
    return Object.freeze({ name: this.name, value: this.take() });
  }
}

/** One-use provider-owned machine specifier with redacted display. */
export class ExternalMachineSpecifier extends Secret {
  constructor(value: string) {
    super(value, "external machine specifier");
  }
}

export interface Snapshot<Id extends string> {
  readonly id: Id;
  readonly extra: Document;
}

export interface MachineSnapshot extends Snapshot<MachineId> {
  readonly name: string;
  readonly origin: "local" | "external";
  readonly status: "running" | "connecting" | "sleeping" | "stopped" | "unavailable";
  readonly connectable: boolean;
  readonly providerScopeId?: ProviderScopeId;
  readonly deleted: boolean;
  readonly recoverable: boolean;
}
export interface SessionSnapshot extends Snapshot<SessionId> {
  readonly machineId: MachineId;
  readonly name?: string;
  readonly generation: string;
  readonly revision: DecimalString;
  readonly connected: boolean;
}
export interface WorkspaceSnapshot extends Snapshot<WorkspaceId> {
  readonly name: string;
  readonly sessionId: SessionId;
  readonly index: number;
  readonly focused: boolean;
}
export interface ScreenSnapshot extends Snapshot<ScreenId> {
  readonly name: string | null;
  readonly workspaceId: WorkspaceId;
  readonly index: number;
  readonly focused: boolean;
  readonly layout: LayoutDocument;
}
export interface PaneSnapshot extends Snapshot<PaneId> {
  readonly name: string | null;
  readonly screenId: ScreenId;
  readonly focused: boolean;
  readonly zoomed: boolean;
}
export interface TabSnapshot extends Snapshot<TabId> {
  readonly name: string | null;
  readonly paneId: PaneId;
  readonly index: number;
  readonly focused: boolean;
  readonly contentKind: "terminal" | "browser";
  readonly contentId: TerminalId | BrowserId;
}
export interface TerminalSnapshot extends Snapshot<TerminalId> {
  readonly tabId: TabId;
  readonly title: string;
  readonly cwd?: string;
  readonly cols: number;
  readonly rows: number;
  readonly running: boolean;
}
export interface BrowserSnapshot extends Snapshot<BrowserId> {
  readonly tabId: TabId;
  readonly url: string;
  readonly title: string;
  readonly loading: boolean;
  readonly source: "external" | "launched";
  readonly status: "starting" | "live" | "failed";
  readonly error: string | null;
  readonly framesStalled: boolean;
  readonly size: Size;
}
export interface ClientSnapshot extends Snapshot<ConnectedClientId> {
  readonly name: string | null;
  readonly sessionId: SessionId;
  readonly clientKind: string | null;
  readonly transport: "unix" | "websocket";
  readonly connectedSeconds: DecimalString;
  readonly attachedTerminalIds: readonly TerminalId[];
  readonly sizes: readonly ClientTerminalSize[];
  readonly self: boolean;
}
export interface NotificationSnapshot extends Snapshot<NotificationId> {
  readonly sessionId: SessionId;
  readonly title: string;
  readonly body: string;
  readonly level: "info" | "warning" | "error";
  readonly terminalId?: TerminalId;
  readonly createdAtMs: DecimalString;
  readonly unread: boolean;
}
export interface AgentSnapshot extends Snapshot<AgentId> {
  readonly sessionId: SessionId;
  readonly terminalId: TerminalId;
  readonly state: "working" | "blocked" | "idle" | "done" | "unknown";
  readonly source: "hook" | "socket" | "detected";
  readonly updatedAtMs: DecimalString;
  readonly sourceSession: string | null;
}

export class PairingCode {
  #value: string;

  constructor(value: string) {
    if (!value) throw new TypeError("pairing code must be a non-empty string");
    this.#value = value;
  }

  reveal(): string {
    return this.#value;
  }

  toString(): string {
    return "<redacted>";
  }

  toJSON(): string {
    return "<redacted>";
  }
}

export interface PairingRequestSnapshot extends Snapshot<PairingRequestId> {
  readonly sessionId: SessionId;
  readonly peer: string;
  readonly code: PairingCode;
  readonly expiresInSeconds: DecimalString;
  readonly status: "pending" | "accepted" | "rejected";
}
export interface FrontendProjectionSnapshot extends Snapshot<ProjectionId> {
  readonly sessionId: SessionId;
  readonly projection: unknown;
}
export interface SidebarViewSnapshot extends Snapshot<SidebarViewId> {
  readonly sessionId: SessionId;
  readonly cols: number;
  readonly rows: number;
  readonly running: boolean;
}
export interface ProviderScopeSnapshot extends Snapshot<ProviderScopeId> {
  readonly name: string;
  readonly kind: "personal" | "team";
  readonly canAdmin: boolean;
  readonly selected: boolean;
}
export interface ProviderActionField {
  readonly id: string;
  readonly label: string;
  readonly kind: "text" | "email" | "integer";
  readonly required: boolean;
  readonly maxLength?: number;
  readonly minimum?: number;
  readonly maximum?: number;
  readonly placeholder?: string;
}
export interface ProviderActionSnapshot extends Snapshot<ProviderActionId> {
  readonly name: string;
  readonly providerScopeId: ProviderScopeId;
  readonly title: string;
  readonly enabled: boolean;
  readonly target: "scope" | "selected_machine" | "selected_workspace";
  readonly destructive: boolean;
  readonly fields: readonly ProviderActionField[];
}
export interface ProviderNoticeSnapshot extends Snapshot<ProviderNoticeId> {
  readonly providerScopeId: ProviderScopeId;
  readonly level: "info" | "warning" | "error";
  readonly message: string;
}

export interface Cursor {
  readonly generation: string;
  readonly revision: DecimalString;
}

export interface MutationResult<Value> {
  readonly value: Value;
  readonly generation: string;
  readonly revision: DecimalString;
  readonly replayed: boolean;
}

export interface ExactCommand {
  readonly kind: "argv";
  readonly argv: readonly string[];
  readonly cwd?: string;
}

export interface ShellCommand {
  readonly kind: "shell";
  readonly shell: string;
  readonly cwd?: string;
}

export type Command = ExactCommand | ShellCommand;

export function exact(
  argv: readonly string[],
  options: {
    cwd?: string;
  } = {},
): ExactCommand {
  if (argv.length === 0 || argv[0] === "") {
    throw new TypeError("argv must contain a non-empty executable");
  }
  if (!argv.every((item) => typeof item === "string")) {
    throw new TypeError("every argv item must be a string");
  }
  return Object.freeze({
    kind: "argv",
    argv: Object.freeze([...argv]),
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
  });
}

/** Explicitly asks the target session to expand a script in its own shell. */
export function shell(
  script: string,
  options: {
    cwd?: string;
  } = {},
): ShellCommand {
  if (typeof script !== "string") throw new TypeError("shell script must be a string");
  if (!script) throw new TypeError("shell script must be non-empty");
  return Object.freeze({
    kind: "shell",
    shell: script,
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
  });
}

/** Chooses one shell executable without inspecting or expanding the script. */
export function shellExecutable(
  executable: string,
  script: string,
  options: { cwd?: string } = {},
): ExactCommand {
  return exact([executable, "-lc", script], options);
}

export interface KeyInput {
  readonly key: string;
  readonly action?: string;
  readonly modifiers?: readonly string[];
  readonly text?: string;
}

export interface MouseInput {
  readonly kind: string;
  readonly x?: number;
  readonly y?: number;
  readonly button?: string;
  readonly modifiers?: readonly string[];
}

export interface Size {
  readonly cols: number;
  readonly rows: number;
}

export interface LayoutLeaf {
  readonly kind: "leaf";
  readonly paneId: PaneId;
  readonly tabIds: readonly TabId[];
  readonly activeTabId?: TabId;
}

export interface LayoutSplit {
  readonly kind: "split";
  readonly splitId: SplitId;
  readonly direction: "horizontal" | "vertical";
  readonly ratio: number;
  readonly first: LayoutNode;
  readonly second: LayoutNode;
}

export interface LayoutStack {
  readonly kind: "stack";
  readonly paneIds: readonly PaneId[];
  readonly expandedPaneId: PaneId;
}

export interface LayoutColumn {
  readonly columnId: SplitId;
  readonly width: number;
  readonly root: LayoutNode;
}

export interface LayoutViewport {
  readonly kind: "viewport";
  readonly baseWidth: number;
  readonly columns: readonly LayoutColumn[];
}

export type LayoutNode = LayoutLeaf | LayoutSplit | LayoutStack | LayoutViewport;

export interface LayoutDocument {
  readonly version: number;
  readonly screenId: ScreenId;
  readonly activePaneId: PaneId;
  readonly zoomedPaneId: PaneId | null;
  readonly root: LayoutNode;
  readonly extra: Document;
}

export interface PixelSize {
  readonly widthPx: number;
  readonly heightPx: number;
}

export interface ClientTerminalSize {
  readonly terminalId: TerminalId;
  readonly cols: number | null;
  readonly rows: number | null;
  readonly participating: boolean;
}

export interface StreamItem<Value> {
  readonly streamId: StreamId;
  readonly sequence: DecimalString;
  readonly cursor?: Cursor;
  readonly value: Value;
}

export interface StreamEnd {
  readonly streamId: StreamId;
  readonly reason: "completed" | "canceled" | "closed" | "gap" | "error";
  readonly cursor?: Cursor;
  readonly error?: Error;
  readonly recovery?: string;
}

export interface ResourceSnapshot {
  readonly machine: MachineSnapshot;
  readonly session: SessionSnapshot;
  readonly workspaces: readonly WorkspaceSnapshot[];
  readonly screens: readonly ScreenSnapshot[];
  readonly panes: readonly PaneSnapshot[];
  readonly tabs: readonly TabSnapshot[];
  readonly terminals: readonly TerminalSnapshot[];
  readonly browsers: readonly BrowserSnapshot[];
  readonly clients: readonly ClientSnapshot[];
  readonly notifications: readonly NotificationSnapshot[];
  readonly agents: readonly AgentSnapshot[];
  readonly frontendProjections: readonly FrontendProjectionSnapshot[];
  readonly sidebarViews: readonly SidebarViewSnapshot[];
  readonly cursor: Cursor;
  readonly extra: Document;
}

export type ResourceKind =
  | "machine"
  | "session"
  | "workspace"
  | "screen"
  | "pane"
  | "tab"
  | "terminal"
  | "browser"
  | "client"
  | "notification"
  | "agent"
  | "pairing_request"
  | "frontend_projection"
  | "sidebar_view"
  | "provider_scope"
  | "provider_action"
  | "provider_notice";

export type ResourceChangeId =
  | MachineId
  | SessionId
  | WorkspaceId
  | ScreenId
  | PaneId
  | TabId
  | TerminalId
  | BrowserId
  | ConnectedClientId
  | NotificationId
  | AgentId
  | PairingRequestId
  | ProjectionId
  | SidebarViewId
  | ProviderScopeId
  | ProviderActionId
  | ProviderNoticeId;

export type ResourceEntitySnapshot =
  | MachineSnapshot
  | SessionSnapshot
  | WorkspaceSnapshot
  | ScreenSnapshot
  | PaneSnapshot
  | TabSnapshot
  | TerminalSnapshot
  | BrowserSnapshot
  | ClientSnapshot
  | NotificationSnapshot
  | AgentSnapshot
  | PairingRequestSnapshot
  | FrontendProjectionSnapshot
  | SidebarViewSnapshot
  | ProviderScopeSnapshot
  | ProviderActionSnapshot
  | ProviderNoticeSnapshot;

export interface ResourceUpsert {
  readonly kind: "upsert";
  readonly sequence: number;
  readonly resource: ResourceKind;
  readonly id: ResourceChangeId;
  readonly value: ResourceEntitySnapshot;
}

export interface ResourceDelete {
  readonly kind: "delete";
  readonly sequence: number;
  readonly resource: ResourceKind;
  readonly id: ResourceChangeId;
}

export interface Unknown {
  readonly kind: string;
  readonly raw: Document;
}

export type ResourceChange = ResourceUpsert | ResourceDelete | Unknown;

export interface SessionSnapshotItem {
  readonly kind: "snapshot";
  readonly cursor: Cursor;
  readonly resetReason?: "initial" | "generation_changed" | "cursor_expired";
  readonly snapshot: ResourceSnapshot;
}

export interface SessionDelta {
  readonly kind: "delta";
  readonly cursor: Cursor;
  readonly previousRevision: DecimalString;
  readonly revision: DecimalString;
  readonly changes: readonly ResourceChange[];
}

export type SessionEvent = SessionSnapshotItem | SessionDelta | Unknown;

export interface RenderCursor {
  readonly x: number;
  readonly y: number;
  readonly style: "block" | "underline" | "bar";
  readonly blink: boolean;
  readonly visible: boolean;
  readonly color: string | null;
}

export interface RenderRun {
  readonly text: string;
  readonly fg: string | null;
  readonly bg: string | null;
  readonly attrs: number;
  readonly underline?: "single" | "double" | "curly" | "dotted" | "dashed";
  readonly widthHint?: number;
}

export interface RenderRow {
  readonly row: number;
  readonly runs: readonly RenderRun[];
}

export interface RenderSnapshot {
  readonly size: Size;
  readonly cursor: RenderCursor;
  readonly defaultFg: string;
  readonly defaultBg: string;
  readonly scrollbackRows: number;
  readonly rows: readonly RenderRow[];
}

export interface RenderPatch {
  readonly cursor: RenderCursor;
  readonly fullReset: boolean;
  readonly size?: Size;
  readonly defaultFg?: string;
  readonly defaultBg?: string;
  readonly scrollbackRows?: number;
  readonly rows: readonly RenderRow[];
}

export interface RenderScroll {
  readonly offset: DecimalString;
  readonly atBottom: boolean;
}

export interface TerminalAttachSnapshot {
  readonly kind: "snapshot";
  readonly terminalId: TerminalId;
  readonly render: RenderSnapshot;
}

export interface TerminalAttachPatch {
  readonly kind: "patch";
  readonly terminalId: TerminalId;
  readonly render: RenderPatch;
}

export interface TerminalAttachScroll {
  readonly kind: "scroll";
  readonly terminalId: TerminalId;
  readonly scroll: RenderScroll;
}

export type TerminalAttachItem =
  | TerminalAttachSnapshot
  | TerminalAttachPatch
  | TerminalAttachScroll
  | Unknown;

export interface BrowserAttachSnapshot {
  readonly kind: "snapshot";
  readonly browser: BrowserSnapshot;
  readonly size: PixelSize;
}

export interface BrowserAttachFrame {
  readonly kind: "frame";
  readonly mimeType: "image/png" | "image/jpeg";
  readonly dataBase64: string;
  readonly widthPx: number;
  readonly heightPx: number;
}

export interface BrowserAttachState {
  readonly kind: "state";
  readonly url: string;
  readonly title: string;
  readonly loading: boolean;
}

export type BrowserAttachItem =
  | BrowserAttachSnapshot
  | BrowserAttachFrame
  | BrowserAttachState
  | Unknown;

export interface SidebarAttachSnapshot {
  readonly kind: "snapshot";
  readonly sidebarView: SidebarViewSnapshot;
  readonly render: RenderSnapshot;
}

export interface SidebarAttachPatch {
  readonly kind: "patch";
  readonly sidebarViewId: SidebarViewId;
  readonly render: RenderPatch;
}

export interface SidebarAttachScroll {
  readonly kind: "scroll";
  readonly sidebarViewId: SidebarViewId;
  readonly scroll: RenderScroll;
}

export type SidebarAttachItem =
  | SidebarAttachSnapshot
  | SidebarAttachPatch
  | SidebarAttachScroll
  | Unknown;

export interface ProviderNoticeKnown {
  readonly kind: "notice";
  readonly notice: ProviderNoticeSnapshot;
  readonly sequence: DecimalString;
}

export type ProviderNoticeItem =
  | ProviderNoticeKnown
  | Unknown;
