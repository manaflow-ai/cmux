import type {
  DecimalString,
  TerminalId,
} from "./ids.js";
import type {
  Command,
  Cursor,
  LayoutDocument,
  ProviderActionValue,
} from "./models.js";

export type Direction = "left" | "right" | "up" | "down";
export type InitialContent = "terminal" | "empty";

export interface CreateMachineOptions {}

export interface CreateWorkspaceOptions {
  readonly name?: string;
  readonly initialContent?: InitialContent;
}

export interface CreateScreenOptions {
  readonly name?: string;
}

export interface CreatePaneOptions {
  readonly cwd?: string;
  readonly columns?: number;
  readonly rows?: number;
}

export interface SplitPaneOptions extends CreatePaneOptions {
  readonly direction: Direction;
  readonly ratio?: number;
}

export interface CreateTerminalOptions {
  readonly cwd?: string;
  readonly name?: string;
  readonly columns?: number;
  readonly rows?: number;
}

export interface CreateBrowserOptions {
  readonly url: string;
  readonly name?: string;
  readonly widthPx?: number;
  readonly heightPx?: number;
}

export interface RunOptions {
  readonly command: Command;
  readonly name?: string;
  readonly columns?: number;
  readonly rows?: number;
}

export interface SessionEventsOptions {
  readonly cursor?: Cursor;
  readonly signal?: AbortSignal;
}

export interface TerminalHistoryOptions {
  readonly before?: DecimalString;
  readonly limit?: number;
  readonly styled?: boolean;
}

export interface TerminalWaitOptions {
  readonly pattern: string;
  readonly timeoutMs?: number;
  readonly signal?: AbortSignal;
}

export interface TerminalAttachOptions {
  readonly columns?: number;
  readonly rows?: number;
  readonly readOnly?: boolean;
  readonly signal?: AbortSignal;
}

export interface BrowserAttachOptions {
  readonly widthPx?: number;
  readonly heightPx?: number;
  readonly signal?: AbortSignal;
}

export interface LayoutApplyOptions {
  readonly layout: LayoutDocument;
}

export interface KeyInputOptions {
  readonly keys: readonly string[];
}

export interface TerminalMouseOptions {
  readonly kind: string;
  readonly row: number;
  readonly column: number;
  readonly button?: string;
  readonly deltaRows?: number;
  readonly modifiers?: readonly string[];
}

export interface BrowserMouseOptions {
  readonly kind: string;
  readonly xPx: number;
  readonly yPx: number;
  readonly button?: string;
  readonly clickCount?: number;
}

export interface ViewerSizeOptions {
  readonly columns: number;
  readonly rows: number;
}

export interface BrowserViewerSizeOptions {
  readonly widthPx: number;
  readonly heightPx: number;
}

export interface NotificationOptions {
  readonly title: string;
  readonly body: string;
  readonly level?: string;
  readonly terminalId?: TerminalId;
}

export interface AgentReportOptions {
  readonly terminalId: TerminalId;
  readonly state: "working" | "blocked" | "idle" | "done" | "unknown";
  readonly source: "hook" | "socket";
  readonly sourceSession?: string;
}

export interface ProviderActionOptions {
  readonly parameters: Readonly<Record<string, ProviderActionValue>>;
}

export interface SidebarInputOptions {
  readonly dataBase64: string;
}

export interface SidebarResizeOptions {
  readonly columns: number;
  readonly rows: number;
}

export interface SidebarEnsureOptions extends SidebarResizeOptions {
  readonly relaunch?: boolean;
}

export interface RequestOptions {
  readonly signal?: AbortSignal;
}

export interface MutationOptions extends RequestOptions {
  readonly idempotencyKey?: string;
  readonly expectedRevision?: DecimalString;
}
