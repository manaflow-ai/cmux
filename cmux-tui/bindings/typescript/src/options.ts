import type {
  DecimalString,
  TerminalId,
} from "./ids.js";
import type {
  Command,
  Cursor,
  JournalClass,
  JsonValue,
  LayoutDocument,
} from "./models.js";

export type Direction = "left" | "right" | "up" | "down";
export type InitialContent = "terminal" | "empty";

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
  readonly viewportWidth?: number;
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

export interface RequestOptions {
  readonly signal?: AbortSignal;
  /** Overrides this call's client deadline. Zero disables only the local deadline. */
  readonly timeoutMs?: number;
}

export interface SessionEventsOptions extends RequestOptions {
  readonly cursor?: Cursor;
}

export interface JournalSubjectFilter {
  readonly kind?: string;
  readonly id?: string;
}

export interface JournalRegexFilter {
  readonly pattern: string;
  readonly field?: "kind" | "subjects" | "payload" | "record" | "terminal_output";
  readonly caseSensitive?: boolean;
}

export interface SessionJournalOptions extends RequestOptions {
  readonly cursor?: Cursor;
  readonly start?: "tail" | "beginning";
  readonly follow?: boolean;
  readonly kinds?: readonly string[];
  readonly classes?: readonly JournalClass[];
  readonly subjects?: readonly JournalSubjectFilter[];
  readonly maxSensitivity?: "public" | "metadata" | "sensitive";
  readonly regex?: JournalRegexFilter;
}

export interface TerminalHistoryOptions {
  readonly before?: DecimalString;
  readonly limit?: number;
  readonly styled?: boolean;
}

export interface TerminalWaitOptions {
  readonly pattern: string;
  /** Server-side bound, clamped to the request or 10-second safety bound. */
  readonly timeoutMs?: DecimalString;
  /** @deprecated Pass the signal in the second `wait` argument. */
  readonly signal?: AbortSignal;
}

export interface TerminalAttachOptions extends RequestOptions {
  readonly columns?: number;
  readonly rows?: number;
  readonly readOnly?: boolean;
}

export interface BrowserAttachOptions extends RequestOptions {
  readonly widthPx?: number;
  readonly heightPx?: number;
}

export interface LayoutApplyOptions {
  readonly layout: LayoutDocument;
}

export interface KeyInputOptions {
  readonly keys: readonly string[];
}

export interface TerminalMouseOptions {
  readonly kind: "down" | "up" | "move" | "wheel";
  readonly row: number;
  readonly column: number;
  readonly button?: "left" | "middle" | "right";
  readonly deltaRows?: number;
  readonly modifiers?: readonly ("shift" | "control" | "alt" | "meta")[];
}

export interface BrowserMouseOptions {
  readonly kind: "down" | "up" | "move";
  readonly xPx: number;
  readonly yPx: number;
  /** Non-null token from the exact BrowserAttachFrame being presented. */
  readonly pointerFrameSeq: DecimalString;
  readonly button?: "left" | "middle" | "right" | "back" | "forward";
  readonly clickCount?: number;
}

export interface BrowserWheelOptions {
  readonly deltaX: number;
  readonly deltaY: number;
  readonly xPx: number;
  readonly yPx: number;
  /** Non-null token from the exact BrowserAttachFrame being presented. */
  readonly pointerFrameSeq: DecimalString;
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
  readonly level?: "info" | "warning" | "error";
  readonly terminalId?: TerminalId;
}

export interface AgentReportOptions {
  readonly terminalId: TerminalId;
  readonly state: "working" | "blocked" | "idle" | "done" | "unknown";
  readonly source: "hook" | "socket";
  readonly sourceSession?: string;
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

export interface TerminalDefaultsOptions {
  readonly foreground?: string | null;
  readonly background?: string | null;
  readonly cursor?: string | null;
  readonly selectionBackground?: string | null;
  readonly selectionForeground?: string | null;
  readonly cursorStyle?: "block" | "bar" | "underline" | null;
  readonly cursorBlink?: boolean | null;
  readonly palette?: Readonly<Record<string, string>> | null;
  readonly complete?: boolean;
}

export interface MutationOptions extends RequestOptions {
  readonly idempotencyKey?: string;
  readonly expectedRevision?: DecimalString;
  /** Correlates one of the eight creation operations with creation.resolve. */
  readonly correlationKey?: string;
}

export interface ProjectionPutOptions {
  readonly frontendId: string;
  readonly windowId: string;
  readonly generation: string;
  readonly projection: JsonValue;
  readonly expectedProjectionRevision?: DecimalString;
}

export type ProjectionValue = JsonValue;
