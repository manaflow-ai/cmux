import { CmuxProtocolError } from "./errors.js";
import { decodeBase64, encodeBase64 } from "./base64.js";
import {
  agentId,
  browserId,
  connectedClientId,
  decimalString,
  encodeSelector,
  machineId,
  notificationId,
  pairingRequestId,
  paneId,
  projectionId,
  screenId,
  selectCurrent,
  selectId,
  sessionId,
  sidebarViewId,
  splitId,
  tabId,
  terminalId,
  workspaceId,
  type AgentId,
  type BrowserId,
  type ConnectedClientId,
  type DecimalString,
  type MachineId,
  type NotificationId,
  type PairingRequestId,
  type PaneId,
  type ProjectionId,
  type ScreenId,
  type Selector,
  type SelectorInput,
  type SessionId,
  type SidebarViewId,
  type SplitId,
  type TabId,
  type TerminalId,
  type WorkspaceId,
} from "./ids.js";
import { operations, type Operation } from "./internal/operations.js";
import {
  hasUtf8ByteLength,
  isValidIdempotencyKey,
} from "./internal/text.js";
import {
  RendererGrant,
  PairingCode,
  type AgentSnapshot,
  type BrowserAttachFrame,
  type BrowserAttachItem,
  type BrowserAttachSnapshot,
  type BrowserAttachState,
  type BrowserSnapshot,
  type BrowserViewerResizeResult,
  type CellPixelsResult,
  type Command,
  type ClientTerminalSize,
  type ClientSnapshot,
  type Cursor,
  type Document,
  type FrontendProjectionSnapshot,
  type LayoutColumn,
  type LayoutDocument,
  type LayoutNode,
  type MachineSnapshot,
  type MutationReceipt,
  type MutationResult,
  type NotificationSnapshot,
  type PairingResolutionResult,
  type PairingRequestSnapshot,
  type PaneSnapshot,
  type PingResult,
  type PixelSize,
  type ProcessInfoResult,
  type ResourceChange,
  type ResourceChangeId,
  type ResourceEntitySnapshot,
  type ResourceKind,
  type ResourceSnapshot,
  type RenderCursor,
  type RenderPatch,
  type RenderRow,
  type RenderRun,
  type RenderScroll,
  type RenderSnapshot,
  type ScreenSnapshot,
  type SessionEvent,
  type SessionJournalRecord,
  type SessionDelta,
  type SessionSnapshotItem,
  type SessionSnapshot,
  type ShutdownResult,
  type SidebarAttachItem,
  type SidebarAttachPatch,
  type SidebarAttachScroll,
  type SidebarAttachSnapshot,
  type SidebarViewSnapshot,
  type Snapshot,
  type Size,
  type TabSnapshot,
  type TerminalCopyResult,
  type TerminalDefaultsSnapshot,
  type TerminalExit,
  type TerminalHistoryResult,
  type TerminalAttachItem,
  type TerminalAttachPatch,
  type TerminalAttachScroll,
  type TerminalAttachSnapshot,
  type TerminalSnapshot,
  type TerminalScreenResult,
  type TerminalStateResult,
  type TerminalWaitResult,
  type TerminalWaitExitResult,
  type TerminalExitOutcome,
  type Unknown,
  type ReloadConfigResult,
  type ViewerResizeResult,
  type ViewerReleaseResult,
  type JsonValue,
  type WorkspaceSnapshot,
} from "./models.js";
import type {
  AgentReportOptions,
  BrowserAttachOptions,
  BrowserMouseOptions,
  BrowserWheelOptions,
  BrowserViewerSizeOptions,
  CreateBrowserOptions,
  CreatePaneOptions,
  CreateScreenOptions,
  CreateTerminalOptions,
  CreateWorkspaceOptions,
  Direction,
  KeyInputOptions,
  LayoutApplyOptions,
  MutationOptions,
  NotificationOptions,
  ProjectionPutOptions,
  RequestOptions,
  RunOptions,
  SessionEventsOptions,
  SessionJournalOptions,
  SidebarEnsureOptions,
  SidebarInputOptions,
  SidebarResizeOptions,
  SplitPaneOptions,
  TerminalAttachOptions,
  TerminalDefaultsOptions,
  TerminalHistoryOptions,
  TerminalMouseOptions,
  TerminalWaitOptions,
  ViewerSizeOptions,
} from "./options.js";
import {
  ResourceProtocol,
  ResourceStream,
  type OperationResponse,
  type ResourceProtocolOptions,
} from "./resource-protocol.js";

type SnapshotDecoder<Value> = (value: unknown) => Value;
type IdFactory<Id extends string> = (value: string) => Id;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) throw new CmuxProtocolError(`${label} must be an object`);
  return value;
}

function jsonValue(value: unknown, label = "JSON value"): JsonValue {
  if (
    value === null
    || typeof value === "string"
    || typeof value === "boolean"
  ) return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new CmuxProtocolError(`${label} contains a non-finite number`);
    }
    return value;
  }
  if (Array.isArray(value)) {
    return Object.freeze(
      value.map((item, index) => jsonValue(item, `${label}[${index}]`)),
    );
  }
  if (isRecord(value)) {
    const result: Record<string, JsonValue> = {};
    for (const [key, item] of Object.entries(value)) {
      result[key] = jsonValue(item, `${label}.${key}`);
    }
    return Object.freeze(result);
  }
  throw new CmuxProtocolError(`${label} is not valid JSON`);
}

function document(value: unknown, label = "JSON object"): Document {
  const decoded = jsonValue(value, label);
  if (decoded === null || Array.isArray(decoded) || typeof decoded !== "object") {
    throw new CmuxProtocolError(`${label} must be an object`);
  }
  return decoded as Document;
}

function unwrap(value: unknown, names: readonly string[]): Record<string, unknown> {
  void names;
  return record(value, "resource result");
}

function optionalId<Id extends string>(
  payload: Record<string, unknown>,
  keys: readonly string[],
  factory: IdFactory<Id>,
): Id | undefined {
  for (const key of keys) {
    if (!Object.hasOwn(payload, key)) continue;
    const value = payload[key];
    if (typeof value !== "string") {
      throw new CmuxProtocolError(`${key} must be a resource ID string`);
    }
    try {
      return factory(value);
    } catch (error) {
      throw new CmuxProtocolError(`invalid ${key}: ${String(error)}`);
    }
  }
  return undefined;
}

function requiredId<Id extends string>(
  payload: Record<string, unknown>,
  keys: readonly string[],
  factory: IdFactory<Id>,
): Id {
  const value = optionalId(payload, keys, factory);
  if (value === undefined) {
    throw new CmuxProtocolError(`resource result omitted ${keys.join("/")} ID`);
  }
  return value;
}

function requiredNullableId<Id extends string>(
  payload: Record<string, unknown>,
  key: string,
  factory: IdFactory<Id>,
): Id | null {
  if (!Object.hasOwn(payload, key)) {
    throw new CmuxProtocolError(`resource result omitted required nullable ${key}`);
  }
  return payload[key] === null ? null : requiredId(payload, [key], factory);
}

function requiredString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== "string") {
    throw new CmuxProtocolError(`resource result omitted required string ${key}`);
  }
  return value;
}

function optionalString(
  payload: Record<string, unknown>,
  key: string,
): string | undefined {
  if (!Object.hasOwn(payload, key)) return undefined;
  const value = payload[key];
  if (typeof value !== "string") {
    throw new CmuxProtocolError(`resource field ${key} must be a string`);
  }
  return value;
}

function requiredNullableString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  if (!Object.hasOwn(payload, key)) {
    throw new CmuxProtocolError(`resource result omitted required field ${key}`);
  }
  const value = payload[key];
  if (value !== null && typeof value !== "string") {
    throw new CmuxProtocolError(`resource field ${key} must be a string or null`);
  }
  return value;
}

function requiredBoolean(payload: Record<string, unknown>, key: string): boolean {
  const value = payload[key];
  if (typeof value !== "boolean") {
    throw new CmuxProtocolError(`resource result omitted required boolean ${key}`);
  }
  return value;
}

function requiredUnsignedInteger(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = payload[key];
  if (
    typeof value !== "number"
    || !Number.isSafeInteger(value)
    || value < 0
    || value > 0xffff_ffff
  ) {
    throw new CmuxProtocolError(
      `resource result omitted required unsigned integer ${key}`,
    );
  }
  return value;
}

function requiredPositiveUint16(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = requiredUnsignedInteger(payload, key);
  if (value < 1 || value > 0xffff) {
    throw new CmuxProtocolError(`${key} must be between 1 and 65535`);
  }
  return value;
}

function requiredUint16(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = requiredUnsignedInteger(payload, key);
  if (value > 0xffff) {
    throw new CmuxProtocolError(`${key} must be a uint16`);
  }
  return value;
}

function requiredPositiveUint32(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = requiredUnsignedInteger(payload, key);
  if (value < 1) {
    throw new CmuxProtocolError(`${key} must be positive`);
  }
  return value;
}

function requiredInt32(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = payload[key];
  if (
    typeof value !== "number"
    || !Number.isSafeInteger(value)
    || value < -0x8000_0000
    || value > 0x7fff_ffff
  ) {
    throw new CmuxProtocolError(`${key} must be an int32`);
  }
  return value;
}

function requiredNumber(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = payload[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new CmuxProtocolError(`${key} must be a finite number`);
  }
  return value;
}

function strictObject(
  payload: Record<string, unknown>,
  allowed: readonly string[],
  label: string,
): void {
  const allowedFields = new Set(allowed);
  const unknown = Object.keys(payload).find((key) => !allowedFields.has(key));
  if (unknown !== undefined) {
    throw new CmuxProtocolError(`${label} contains unknown field ${JSON.stringify(unknown)}`);
  }
}

function requiredEnum<const Values extends readonly string[]>(
  payload: Record<string, unknown>,
  key: string,
  values: Values,
): Values[number] {
  const value = requiredString(payload, key);
  if (!values.includes(value)) {
    throw new CmuxProtocolError(`resource field ${key} has invalid value ${JSON.stringify(value)}`);
  }
  return value;
}

function requiredDecimal(
  payload: Record<string, unknown>,
  key: string,
): DecimalString {
  try {
    return decimalString(requiredString(payload, key));
  } catch (error) {
    throw new CmuxProtocolError(`invalid ${key}: ${String(error)}`);
  }
}

function requiredNullableDecimal(
  payload: Record<string, unknown>,
  key: string,
): DecimalString | null {
  if (!(key in payload)) {
    throw new CmuxProtocolError(`resource field ${key} is required`);
  }
  return payload[key] === null ? null : requiredDecimal(payload, key);
}

function requiredGeneration(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = requiredString(payload, key);
  if (!hasUtf8ByteLength(value, 1, 128)) {
    throw new CmuxProtocolError(
      `resource field ${key} must contain 1 to 128 UTF-8 bytes`,
    );
  }
  return value;
}

function requiredIdempotencyKey(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = requiredString(payload, key);
  if (!isValidIdempotencyKey(value)) {
    throw new CmuxProtocolError(`resource field ${key} is not a valid idempotency key`);
  }
  return value;
}

function snapshotFields<Id extends string>(
  payload: Record<string, unknown>,
  factory: IdFactory<Id>,
  fields: readonly string[],
): Snapshot<Id> {
  strictObject(payload, ["id", ...fields, "extra"], "resource snapshot");
  const declaredExtra = payload.extra === undefined
    ? {}
    : document(payload.extra, "resource extra");
  return Object.freeze({
    id: requiredId(payload, ["id"], factory),
    extra: Object.freeze({ ...declaredExtra }),
  });
}

function machineSnapshot(value: unknown): MachineSnapshot {
  const payload = unwrap(value, ["machine"]);
  return Object.freeze({
    ...snapshotFields(payload, machineId, [
      "name", "origin", "status", "connectable", "deleted", "recoverable",
    ]),
    name: requiredString(payload, "name"),
    origin: requiredEnum(payload, "origin", ["local"] as const),
    status: requiredEnum(
      payload,
      "status",
      ["running", "connecting", "sleeping", "stopped", "unavailable"] as const,
    ),
    connectable: requiredBoolean(payload, "connectable"),
    deleted: requiredBoolean(payload, "deleted"),
    recoverable: requiredBoolean(payload, "recoverable"),
  });
}

function sessionSnapshot(value: unknown): SessionSnapshot {
  const payload = unwrap(value, ["session"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      sessionId,
      ["machine_id", "name", "generation", "revision", "connected"],
    ),
    machineId: requiredId(payload, ["machine_id"], machineId),
    ...optionalProperty("name", optionalString(payload, "name")),
    generation: requiredGeneration(payload, "generation"),
    revision: requiredDecimal(payload, "revision"),
    connected: requiredBoolean(payload, "connected"),
  });
}

function workspaceSnapshot(value: unknown): WorkspaceSnapshot {
  const payload = unwrap(value, ["workspace"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      workspaceId,
      ["session_id", "name", "index", "focused"],
    ),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    name: requiredString(payload, "name"),
    index: requiredUnsignedInteger(payload, "index"),
    focused: requiredBoolean(payload, "focused"),
  });
}

function screenSnapshot(value: unknown): ScreenSnapshot {
  const payload = unwrap(value, ["screen"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      screenId,
      ["workspace_id", "name", "index", "focused", "layout"],
    ),
    workspaceId: requiredId(payload, ["workspace_id"], workspaceId),
    name: requiredNullableString(payload, "name"),
    index: requiredUnsignedInteger(payload, "index"),
    focused: requiredBoolean(payload, "focused"),
    layout: layoutDocument(payload.layout),
  });
}

function paneSnapshot(value: unknown): PaneSnapshot {
  const payload = unwrap(value, ["pane"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      paneId,
      ["screen_id", "name", "focused", "zoomed"],
    ),
    screenId: requiredId(payload, ["screen_id"], screenId),
    name: requiredNullableString(payload, "name"),
    focused: requiredBoolean(payload, "focused"),
    zoomed: requiredBoolean(payload, "zoomed"),
  });
}

function tabSnapshot(value: unknown): TabSnapshot {
  const payload = unwrap(value, ["tab"]);
  const kind = requiredEnum(payload, "content_kind", ["terminal", "browser"] as const);
  const contentId = kind === "terminal"
    ? requiredId(payload, ["content_id"], terminalId)
    : requiredId(payload, ["content_id"], browserId);
  return Object.freeze({
    ...snapshotFields(payload, tabId, [
      "pane_id", "name", "index", "focused", "content_kind", "content_id",
    ]),
    paneId: requiredId(payload, ["pane_id"], paneId),
    name: requiredNullableString(payload, "name"),
    index: requiredUnsignedInteger(payload, "index"),
    focused: requiredBoolean(payload, "focused"),
    contentKind: kind,
    contentId,
  });
}

function terminalSnapshot(value: unknown): TerminalSnapshot {
  const payload = unwrap(value, ["terminal"]);
  const hasLegacyTabId = Object.hasOwn(payload, "tab_id");
  const hasTabIds = Object.hasOwn(payload, "tab_ids");
  if (!hasLegacyTabId && !hasTabIds) {
    throw new CmuxProtocolError("terminal snapshot requires tab_ids or tab_id");
  }
  const legacyTabId = hasLegacyTabId
    ? requiredNullableId(payload, "tab_id", tabId)
    : undefined;
  let decodedTabIds: TabId[];
  if (hasTabIds) {
    const rawTabIds = payload.tab_ids;
    if (!Array.isArray(rawTabIds)) {
      throw new CmuxProtocolError("terminal tab_ids must be an array");
    }
    decodedTabIds = rawTabIds.map(
      (item) => requiredId({ id: item }, ["id"], tabId),
    );
  } else {
    decodedTabIds = legacyTabId === null ? [] : [legacyTabId as TabId];
  }
  const tabIds = Object.freeze(decodedTabIds);
  if (hasLegacyTabId && legacyTabId !== (tabIds[0] ?? null)) {
    throw new CmuxProtocolError("terminal tab_id must be the first tab_ids item");
  }
  const running = requiredBoolean(payload, "running");
  const lifecycle = requiredEnum(
    payload,
    "lifecycle",
    ["launching", "running", "exited"] as const,
  );
  const exit = Object.hasOwn(payload, "exit")
    ? terminalExit(payload.exit)
    : undefined;
  if (running !== (lifecycle === "running")) {
    throw new CmuxProtocolError(
      "terminal running must be true exactly while lifecycle is running",
    );
  }
  if ((exit !== undefined) !== (lifecycle === "exited")) {
    throw new CmuxProtocolError(
      "terminal exit must be present exactly while lifecycle is exited",
    );
  }
  return Object.freeze({
    ...snapshotFields(
      payload,
      terminalId,
      [
        "tab_id", "tab_ids", "title", "cwd", "cols", "rows", "running", "lifecycle",
        "exit",
      ],
    ),
    tabIds,
    title: requiredString(payload, "title"),
    ...optionalProperty("cwd", optionalString(payload, "cwd")),
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
    running,
    lifecycle,
    ...optionalProperty("exit", exit),
  });
}

function browserSnapshot(value: unknown): BrowserSnapshot {
  const payload = unwrap(value, ["browser"]);
  const loading = requiredBoolean(payload, "loading");
  const status = requiredEnum(
    payload,
    "status",
    ["starting", "live", "failed"] as const,
  );
  const error = requiredNullableString(payload, "error");
  if (loading !== (status === "starting")) {
    throw new CmuxProtocolError(
      "browser loading must be true exactly while status is starting",
    );
  }
  if ((error !== null) !== (status === "failed")) {
    throw new CmuxProtocolError(
      "browser error must be non-null exactly while status is failed",
    );
  }
  return Object.freeze({
    ...snapshotFields(payload, browserId, [
      "tab_id", "url", "title", "loading", "source", "status", "error",
      "frames_stalled", "size",
    ]),
    tabId: requiredId(payload, ["tab_id"], tabId),
    url: requiredString(payload, "url"),
    title: requiredString(payload, "title"),
    loading,
    source: requiredEnum(payload, "source", ["external", "launched"] as const),
    status,
    error,
    framesStalled: requiredBoolean(payload, "frames_stalled"),
    size: size(payload.size),
  });
}

function connectedClientSnapshot(value: unknown): ClientSnapshot {
  const payload = unwrap(value, ["client"]);
  if (!Array.isArray(payload.attached_terminal_ids)) {
    throw new CmuxProtocolError("client attached_terminal_ids must be an array");
  }
  if (!Array.isArray(payload.sizes)) {
    throw new CmuxProtocolError("client sizes must be an array");
  }
  return Object.freeze({
    ...snapshotFields(payload, connectedClientId, [
      "session_id", "name", "client_kind", "transport", "connected_seconds",
      "attached_terminal_ids", "sizes", "self",
    ]),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    name: requiredNullableString(payload, "name"),
    clientKind: requiredNullableString(payload, "client_kind"),
    transport: requiredEnum(payload, "transport", ["unix", "websocket"] as const),
    connectedSeconds: requiredDecimal(payload, "connected_seconds"),
    attachedTerminalIds: Object.freeze(
      payload.attached_terminal_ids.map((value) =>
        requiredId({ id: value }, ["id"], terminalId)),
    ),
    sizes: Object.freeze(payload.sizes.map(clientTerminalSize)),
    self: requiredBoolean(payload, "self"),
  });
}

function size(value: unknown): Size {
  const payload = record(value, "size");
  strictObject(payload, ["cols", "rows"], "size");
  return Object.freeze({
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
  });
}

function clientTerminalSize(value: unknown): ClientTerminalSize {
  const payload = record(value, "client terminal size");
  strictObject(
    payload,
    ["terminal_id", "cols", "rows", "participating"],
    "client terminal size",
  );
  if (!Object.hasOwn(payload, "cols") || !Object.hasOwn(payload, "rows")) {
    throw new CmuxProtocolError("client terminal size omitted cols or rows");
  }
  const cols = payload.cols === null ? null : requiredPositiveUint16(payload, "cols");
  const rows = payload.rows === null ? null : requiredPositiveUint16(payload, "rows");
  return Object.freeze({
    terminalId: requiredId(payload, ["terminal_id"], terminalId),
    cols,
    rows,
    participating: requiredBoolean(payload, "participating"),
  });
}

function layoutNode(value: unknown): LayoutNode {
  const payload = record(value, "layout node");
  const kind = requiredString(payload, "kind");
  if (kind === "leaf") {
    strictObject(
      payload,
      ["kind", "pane_id", "tab_ids", "active_tab_id"],
      "layout leaf",
    );
    if (!Array.isArray(payload.tab_ids)) {
      throw new CmuxProtocolError("layout leaf tab_ids must be an array");
    }
    return Object.freeze({
      kind: "leaf",
      paneId: requiredId(payload, ["pane_id"], paneId),
      tabIds: Object.freeze(
        payload.tab_ids.map((item) => requiredId({ id: item }, ["id"], tabId)),
      ),
      ...optionalProperty(
        "activeTabId",
        optionalId(payload, ["active_tab_id"], tabId),
      ),
    });
  }
  if (kind === "split") {
    strictObject(
      payload,
      ["kind", "split_id", "direction", "ratio", "first", "second"],
      "layout split",
    );
    const ratio = requiredNumber(payload, "ratio");
    if (!(ratio > 0 && ratio < 1)) {
      throw new CmuxProtocolError("layout split ratio must be greater than 0 and less than 1");
    }
    return Object.freeze({
      kind: "split",
      splitId: requiredId(payload, ["split_id"], splitId),
      direction: requiredEnum(
        payload,
        "direction",
        ["horizontal", "vertical"] as const,
      ),
      ratio,
      first: layoutNode(payload.first),
      second: layoutNode(payload.second),
    });
  }
  if (kind === "stack") {
    strictObject(
      payload,
      ["kind", "pane_ids", "expanded_pane_id"],
      "layout stack",
    );
    if (!Array.isArray(payload.pane_ids) || payload.pane_ids.length === 0) {
      throw new CmuxProtocolError("layout stack pane_ids must be a non-empty array");
    }
    const paneIds = Object.freeze(
      payload.pane_ids.map((item) => requiredId({ id: item }, ["id"], paneId)),
    );
    const expandedPaneId = requiredId(payload, ["expanded_pane_id"], paneId);
    if (!paneIds.includes(expandedPaneId)) {
      throw new CmuxProtocolError("layout stack expanded_pane_id must be in pane_ids");
    }
    return Object.freeze({
      kind: "stack",
      paneIds,
      expandedPaneId,
    });
  }
  if (kind === "viewport") {
    strictObject(payload, ["kind", "base_width", "columns"], "layout viewport");
    if (!Array.isArray(payload.columns) || payload.columns.length === 0) {
      throw new CmuxProtocolError("layout viewport columns must be a non-empty array");
    }
    const baseWidth = requiredNumber(payload, "base_width");
    if (baseWidth < 0.1 || baseWidth > 1) {
      throw new CmuxProtocolError("layout viewport base_width must be between 0.1 and 1");
    }
    const columns: LayoutColumn[] = payload.columns.map((item) => {
      const column = record(item, "layout column");
      strictObject(column, ["column_id", "width", "root"], "layout column");
      const width = requiredNumber(column, "width");
      if (width < 0.1 || width > 1) {
        throw new CmuxProtocolError("layout column width must be between 0.1 and 1");
      }
      return Object.freeze({
        columnId: requiredId(column, ["column_id"], splitId),
        width,
        root: layoutNode(column.root),
      });
    });
    return Object.freeze({
      kind: "viewport",
      baseWidth,
      columns: Object.freeze(columns),
    });
  }
  throw new CmuxProtocolError(`unknown layout node kind ${JSON.stringify(kind)}`);
}

function layoutDocument(value: unknown): LayoutDocument {
  const payload = record(value, "layout document");
  strictObject(
    payload,
    ["version", "screen_id", "active_pane_id", "zoomed_pane_id", "root", "extra"],
    "layout document",
  );
  if (!Object.hasOwn(payload, "zoomed_pane_id")) {
    throw new CmuxProtocolError("layout document omitted zoomed_pane_id");
  }
  const zoomedPaneId = payload.zoomed_pane_id === null
    ? null
    : requiredId(payload, ["zoomed_pane_id"], paneId);
  const extra = payload.extra === undefined
    ? {}
    : document(payload.extra, "layout document extra");
  return Object.freeze({
    version: requiredUnsignedInteger(payload, "version"),
    screenId: requiredId(payload, ["screen_id"], screenId),
    activePaneId: requiredId(payload, ["active_pane_id"], paneId),
    zoomedPaneId,
    root: layoutNode(payload.root),
    extra: Object.freeze({ ...extra }),
  });
}

function pairingRequestSnapshot(value: unknown): PairingRequestSnapshot {
  const payload = unwrap(value, ["pairing_request"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      pairingRequestId,
      ["session_id", "peer", "code", "expires_in_seconds", "status"],
    ),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    peer: requiredString(payload, "peer"),
    code: new PairingCode(requiredString(payload, "code")),
    expiresInSeconds: requiredDecimal(payload, "expires_in_seconds"),
    status: requiredEnum(
      payload,
      "status",
      ["pending", "accepted", "rejected"] as const,
    ),
  });
}

function frontendProjectionSnapshot(
  value: unknown,
): FrontendProjectionSnapshot {
  const payload = unwrap(value, ["frontend_projection"]);
  const base = snapshotFields(
    payload,
    projectionId,
    [
      "session_id", "frontend_id", "window_id", "generation", "projection",
      "projection_revision",
    ],
  );
  if (!Object.hasOwn(payload, "projection")) {
    throw new CmuxProtocolError("frontend projection omitted projection");
  }
  return Object.freeze({
    ...base,
    sessionId: requiredId(payload, ["session_id"], sessionId),
    frontendId: requiredString(payload, "frontend_id"),
    windowId: requiredString(payload, "window_id"),
    generation: requiredString(payload, "generation"),
    projection: jsonValue(payload.projection, "frontend projection"),
    projectionRevision: requiredDecimal(payload, "projection_revision"),
  });
}

function notificationSnapshot(value: unknown): NotificationSnapshot {
  const payload = unwrap(value, ["notification"]);
  return Object.freeze({
    ...snapshotFields(payload, notificationId, [
      "session_id", "title", "body", "level", "terminal_id", "created_at_ms",
      "unread",
    ]),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    title: requiredString(payload, "title"),
    body: requiredString(payload, "body"),
    level: requiredEnum(
      payload,
      "level",
      ["info", "warning", "error"] as const,
    ),
    ...optionalProperty(
      "terminalId",
      optionalId(payload, ["terminal_id"], terminalId),
    ),
    createdAtMs: requiredDecimal(payload, "created_at_ms"),
    unread: requiredBoolean(payload, "unread"),
  });
}

function agentSnapshot(value: unknown): AgentSnapshot {
  const payload = unwrap(value, ["agent"]);
  return Object.freeze({
    ...snapshotFields(payload, agentId, [
      "session_id", "terminal_id", "state", "source", "updated_at_ms",
      "source_session",
    ]),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    terminalId: requiredId(payload, ["terminal_id"], terminalId),
    state: requiredEnum(
      payload,
      "state",
      ["working", "blocked", "idle", "done", "unknown"] as const,
    ),
    source: requiredEnum(
      payload,
      "source",
      ["hook", "socket", "detected"] as const,
    ),
    updatedAtMs: requiredDecimal(payload, "updated_at_ms"),
    sourceSession: requiredNullableString(payload, "source_session"),
  });
}

function sidebarViewSnapshot(value: unknown): SidebarViewSnapshot {
  const payload = unwrap(value, ["sidebar_view"]);
  return Object.freeze({
    ...snapshotFields(
      payload,
      sidebarViewId,
      ["session_id", "cols", "rows", "running"],
    ),
    sessionId: requiredId(payload, ["session_id"], sessionId),
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
    running: requiredBoolean(payload, "running"),
  });
}

function optionalProperty<Key extends string, Value>(
  key: Key,
  value: Value | undefined,
): { readonly [Property in Key]?: Value } {
  return value === undefined ? {} : { [key]: value } as { [Property in Key]: Value };
}

function listPayload(value: unknown, key: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new CmuxProtocolError(`${key} result must be an array`);
  }
  return value;
}

function commandFields(command: Command): Record<string, unknown> {
  return {
    ...(command.kind === "argv" ? { argv: [...command.argv] } : { shell: command.shell }),
    ...(command.cwd !== undefined ? { cwd: command.cwd } : {}),
  };
}

function layoutNodeFields(node: LayoutNode): Record<string, unknown> {
  switch (node.kind) {
    case "leaf":
      return {
        kind: node.kind,
        pane_id: node.paneId,
        tab_ids: [...node.tabIds],
        ...(node.activeTabId !== undefined
          ? { active_tab_id: node.activeTabId }
          : {}),
      };
    case "split":
      return {
        kind: node.kind,
        split_id: node.splitId,
        direction: node.direction,
        ratio: node.ratio,
        first: layoutNodeFields(node.first),
        second: layoutNodeFields(node.second),
      };
    case "stack":
      return {
        kind: node.kind,
        pane_ids: [...node.paneIds],
        expanded_pane_id: node.expandedPaneId,
      };
    case "viewport":
      return {
        kind: node.kind,
        base_width: node.baseWidth,
        columns: node.columns.map((column) => ({
          column_id: column.columnId,
          width: column.width,
          root: layoutNodeFields(column.root),
        })),
      };
  }
}

function layoutDocumentFields(layout: LayoutDocument): Record<string, unknown> {
  return {
    version: layout.version,
    screen_id: layout.screenId,
    active_pane_id: layout.activePaneId,
    zoomed_pane_id: layout.zoomedPaneId,
    root: layoutNodeFields(layout.root),
    ...(Object.keys(layout.extra).length > 0 ? { extra: layout.extra } : {}),
  };
}

function optionFields(options: object): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(options)) {
    if (
      value === undefined
      || key === "signal"
      || key === "timeoutMs"
      || key === "idempotencyKey"
      || key === "expectedRevision"
    ) continue;
    if (key === "command") {
      Object.assign(result, commandFields(value as Command));
      continue;
    }
    if (key === "layout") {
      result.layout = layoutDocumentFields(value as LayoutDocument);
      continue;
    }
    const wireKey: string = {
      initialContent: "initial_content",
      columns: "cols",
      widthPx: "width_px",
      heightPx: "height_px",
      viewportWidth: "viewport_width",
      readOnly: "read_only",
      deltaRows: "delta_rows",
      deltaX: "delta_x",
      deltaY: "delta_y",
      xPx: "x_px",
      yPx: "y_px",
      clickCount: "click_count",
      pointerFrameSeq: "pointer_frame_seq",
      terminalId: "terminal_id",
      sourceSession: "source_session",
      selectionBackground: "selection_background",
      selectionForeground: "selection_foreground",
      cursorStyle: "cursor_style",
      cursorBlink: "cursor_blink",
      dataBase64: "data_base64",
      pluginId: "plugin_id",
    }[key] ?? key;
    result[wireKey] = value;
  }
  return result;
}

function journalOptionsFields(options: SessionJournalOptions): Record<string, unknown> {
  if (options.cursor !== undefined && options.start !== undefined) {
    throw new TypeError("journal cursor and start are mutually exclusive");
  }
  const fields: Record<string, unknown> = {};
  if (options.cursor !== undefined) fields.cursor = options.cursor;
  if (options.start !== undefined) fields.start = options.start;
  if (options.follow !== undefined) fields.follow = options.follow;
  const filter: Record<string, unknown> = {};
  if (options.kinds !== undefined) filter.kinds = [...options.kinds];
  if (options.classes !== undefined) filter.classes = [...options.classes];
  if (options.subjects !== undefined) {
    if (options.subjects.some((subject) => subject.kind === undefined && subject.id === undefined)) {
      throw new TypeError("journal subject filters require kind or id");
    }
    filter.subjects = options.subjects.map((subject) => ({ ...subject }));
  }
  if (options.maxSensitivity !== undefined) {
    filter.max_sensitivity = options.maxSensitivity;
  }
  if (options.regex !== undefined) {
    if (!hasUtf8ByteLength(options.regex.pattern, 1, 1024)) {
      throw new TypeError("journal regex must contain 1 to 1024 UTF-8 bytes");
    }
    filter.regex = {
      pattern: options.regex.pattern,
      field: options.regex.field ?? "record",
      case_sensitive: options.regex.caseSensitive ?? true,
    };
  }
  if (Object.keys(filter).length > 0) fields.filter = filter;
  return fields;
}

function browserPointerFields(
  input: BrowserMouseOptions | BrowserWheelOptions,
): Record<string, unknown> {
  const fields = optionFields(input);
  try {
    fields.pointer_frame_seq = decimalString(input.pointerFrameSeq);
  } catch (error) {
    throw new TypeError(`pointerFrameSeq must be a non-null DecimalString: ${String(error)}`);
  }
  return fields;
}

function mutationParams(
  _operation: Operation,
  params: Readonly<Record<string, unknown>>,
  options: MutationOptions,
): Readonly<Record<string, unknown>> {
  if (options.expectedRevision === undefined) return params;
  if (typeof options.expectedRevision !== "string") {
    throw new TypeError("expectedRevision must be a decimal string");
  }
  return {
    ...params,
    expected_revision: decimalString(options.expectedRevision),
  };
}

function cursor(value: unknown): Cursor {
  const payload = record(value, "cursor");
  strictObject(payload, ["generation", "revision"], "cursor");
  const generation = requiredGeneration(payload, "generation");
  return Object.freeze({
    generation,
    revision: requiredDecimal(payload, "revision"),
  });
}

function snapshotList<Value>(
  payload: Record<string, unknown>,
  key: string,
  decode: (value: unknown) => Value,
): readonly Value[] {
  const values = payload[key];
  if (!Array.isArray(values)) {
    throw new CmuxProtocolError(`resource snapshot ${key} must be an array`);
  }
  return Object.freeze(values.map(decode));
}

function resourceSnapshot(value: unknown): ResourceSnapshot {
  const payload = record(value, "resource snapshot");
  strictObject(
    payload,
    [
      "machine", "session", "workspaces", "screens", "panes", "tabs",
      "terminals", "browsers", "clients", "notifications", "agents",
      "frontend_projections", "sidebar_views", "cursor", "extra",
    ],
    "resource snapshot",
  );
  const extra = payload.extra === undefined
    ? {}
    : document(payload.extra, "resource snapshot extra");
  return Object.freeze({
    machine: machineSnapshot(payload.machine),
    session: sessionSnapshot(payload.session),
    workspaces: snapshotList(payload, "workspaces", workspaceSnapshot),
    screens: snapshotList(payload, "screens", screenSnapshot),
    panes: snapshotList(payload, "panes", paneSnapshot),
    tabs: snapshotList(payload, "tabs", tabSnapshot),
    terminals: snapshotList(payload, "terminals", terminalSnapshot),
    browsers: snapshotList(payload, "browsers", browserSnapshot),
    clients: snapshotList(payload, "clients", connectedClientSnapshot),
    notifications: snapshotList(
      payload,
      "notifications",
      notificationSnapshot,
    ),
    agents: snapshotList(
      payload,
      "agents",
      agentSnapshot,
    ),
    frontendProjections: snapshotList(
      payload,
      "frontend_projections",
      frontendProjectionSnapshot,
    ),
    sidebarViews: snapshotList(
      payload,
      "sidebar_views",
      sidebarViewSnapshot,
    ),
    cursor: cursor(payload.cursor),
    extra: Object.freeze({ ...extra }),
  });
}

const RESOURCE_KINDS = [
  "machine",
  "session",
  "workspace",
  "screen",
  "pane",
  "tab",
  "terminal",
  "browser",
  "client",
  "notification",
  "agent",
  "pairing_request",
  "frontend_projection",
  "sidebar_view",
] as const satisfies readonly ResourceKind[];

function resourceEntitySnapshot(
  resource: ResourceKind,
  value: unknown,
): ResourceEntitySnapshot {
  switch (resource) {
    case "machine": return machineSnapshot(value);
    case "session": return sessionSnapshot(value);
    case "workspace": return workspaceSnapshot(value);
    case "screen": return screenSnapshot(value);
    case "pane": return paneSnapshot(value);
    case "tab": return tabSnapshot(value);
    case "terminal": return terminalSnapshot(value);
    case "browser": return browserSnapshot(value);
    case "client": return connectedClientSnapshot(value);
    case "notification": return notificationSnapshot(value);
    case "agent": return agentSnapshot(value);
    case "pairing_request": return pairingRequestSnapshot(value);
    case "frontend_projection": return frontendProjectionSnapshot(value);
    case "sidebar_view": return sidebarViewSnapshot(value);
  }
}

function resourceChange(value: unknown): ResourceChange {
  const payload = record(value, "resource change");
  const kind = requiredString(payload, "kind");
  if (kind !== "upsert" && kind !== "delete") {
    return Object.freeze({
      kind,
      raw: document(payload, "unknown resource change"),
    }) satisfies Unknown;
  }
  const resource = requiredEnum(payload, "resource", RESOURCE_KINDS);
  const factories: Readonly<Record<ResourceKind, IdFactory<ResourceChangeId>>> = {
    machine: machineId,
    session: sessionId,
    workspace: workspaceId,
    screen: screenId,
    pane: paneId,
    tab: tabId,
    terminal: terminalId,
    browser: browserId,
    client: connectedClientId,
    notification: notificationId,
    agent: agentId,
    pairing_request: pairingRequestId,
    frontend_projection: projectionId,
    sidebar_view: sidebarViewId,
  };
  const id = requiredId(payload, ["id"], factories[resource]);
  const sequence = requiredUnsignedInteger(payload, "sequence");
  if (kind === "delete") {
    strictObject(payload, ["kind", "sequence", "resource", "id"], "resource delete");
    return Object.freeze({ kind, sequence, resource, id }) as ResourceChange;
  }
  strictObject(
    payload,
    ["kind", "sequence", "resource", "id", "value"],
    "resource upsert",
  );
  const snapshot = resourceEntitySnapshot(resource, payload.value);
  if (snapshot.id !== id) {
    throw new CmuxProtocolError("resource upsert id does not match value.id");
  }
  return Object.freeze({
    kind,
    sequence,
    resource,
    id,
    value: snapshot,
  }) as ResourceChange;
}

function sessionEvent(value: unknown): SessionEvent {
  const payload = record(value, "session event");
  const kind = requiredString(payload, "kind");
  if (kind === "snapshot") {
    strictObject(
      payload,
      ["kind", "cursor", "reset_reason", "snapshot"],
      "session snapshot item",
    );
    const resetReason = Object.hasOwn(payload, "reset_reason")
      ? requiredEnum(
        payload,
        "reset_reason",
        ["initial", "generation_changed", "cursor_expired"] as const,
      )
      : undefined;
    return Object.freeze({
      kind,
      cursor: cursor(payload.cursor),
      ...optionalProperty("resetReason", resetReason),
      snapshot: resourceSnapshot(payload.snapshot),
    }) satisfies SessionSnapshotItem;
  }
  if (kind === "delta") {
    strictObject(
      payload,
      ["kind", "cursor", "previous_revision", "revision", "changes"],
      "session delta",
    );
    if (!Array.isArray(payload.changes)) {
      throw new CmuxProtocolError("session delta changes must be an array");
    }
    return Object.freeze({
      kind,
      cursor: cursor(payload.cursor),
      previousRevision: requiredDecimal(payload, "previous_revision"),
      revision: requiredDecimal(payload, "revision"),
      changes: Object.freeze(payload.changes.map(resourceChange)),
    }) satisfies SessionDelta;
  }
  return Object.freeze({
    kind,
    raw: document(payload, "unknown session event"),
  }) satisfies Unknown;
}

function sessionJournalRecord(value: unknown): SessionJournalRecord {
  const payload = record(value, "session journal record");
  strictObject(payload, [
    "sequence", "event_id", "schema_version", "kind", "class", "replay",
    "occurred_at_ms", "committed_at_ms", "producer", "authority",
    "causation_id", "correlation_id", "causation_depth", "subjects",
    "sensitivity", "payload", "resource_revision", "previous_resource_revision",
  ], "session journal record");
  for (const key of ["authority", "payload"] as const) {
    if (!Object.hasOwn(payload, key)) {
      throw new CmuxProtocolError(`session journal record omitted required field ${key}`);
    }
  }
  const producer = record(payload.producer, "journal producer");
  strictObject(producer, ["kind", "id"], "journal producer");
  const authorityValue = payload.authority;
  const authority = authorityValue === null ? null : (() => {
    const authorityPayload = record(authorityValue, "journal authority");
    strictObject(
      authorityPayload,
      ["principal_id", "lease_id", "generation", "role"],
      "journal authority",
    );
    return Object.freeze({
      principalId: requiredString(authorityPayload, "principal_id"),
      leaseId: requiredString(authorityPayload, "lease_id"),
      generation: requiredString(authorityPayload, "generation"),
      role: requiredString(authorityPayload, "role"),
    });
  })();
  if (!Array.isArray(payload.subjects)) {
    throw new CmuxProtocolError("journal subjects must be an array");
  }
  const subjects = payload.subjects.map((subjectValue, index) => {
    const subjectPayload = record(subjectValue, `journal subject ${index}`);
    strictObject(subjectPayload, ["kind", "id"], "journal subject");
    return Object.freeze({
      kind: requiredString(subjectPayload, "kind"),
      id: requiredString(subjectPayload, "id"),
    });
  });
  return Object.freeze({
    sequence: requiredDecimal(payload, "sequence"),
    eventId: requiredString(payload, "event_id"),
    schemaVersion: requiredPositiveUint32(payload, "schema_version"),
    kind: requiredString(payload, "kind"),
    class: requiredEnum(
      payload,
      "class",
      ["state", "observation", "effect", "checkpoint"] as const,
    ),
    replay: requiredEnum(payload, "replay", ["required", "advisory", "never"] as const),
    occurredAtMs: requiredDecimal(payload, "occurred_at_ms"),
    committedAtMs: requiredDecimal(payload, "committed_at_ms"),
    producer: Object.freeze({
      kind: requiredString(producer, "kind"),
      id: requiredString(producer, "id"),
    }),
    authority,
    causationId: requiredNullableString(payload, "causation_id"),
    correlationId: requiredNullableString(payload, "correlation_id"),
    causationDepth: requiredUint16(payload, "causation_depth"),
    subjects: Object.freeze(subjects),
    sensitivity: requiredEnum(
      payload,
      "sensitivity",
      ["public", "metadata", "sensitive", "secret"] as const,
    ),
    payload: jsonValue(payload.payload, "journal payload"),
    resourceRevision: requiredNullableDecimal(payload, "resource_revision"),
    previousResourceRevision: requiredNullableDecimal(
      payload,
      "previous_resource_revision",
    ),
  }) satisfies SessionJournalRecord;
}

function validateSessionJournalStreamItem(
  record: SessionJournalRecord,
  cursor: Cursor | undefined,
): void {
  if (cursor === undefined || record.sequence !== cursor.revision) {
    throw new CmuxProtocolError("journal sequence must match its stream cursor");
  }
}

function color(payload: Record<string, unknown>, key: string): string {
  const value = requiredString(payload, key);
  if (value.length !== 7) {
    throw new CmuxProtocolError(`${key} must contain 7 characters`);
  }
  return value;
}

function requiredNullableColor(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = requiredNullableString(payload, key);
  if (value !== null && value.length !== 7) {
    throw new CmuxProtocolError(`${key} must contain 7 characters`);
  }
  return value;
}

function renderCursor(value: unknown): RenderCursor {
  const payload = record(value, "render cursor");
  strictObject(
    payload,
    ["x", "y", "style", "blink", "visible", "color"],
    "render cursor",
  );
  return Object.freeze({
    x: requiredUint16(payload, "x"),
    y: requiredUint16(payload, "y"),
    style: requiredEnum(
      payload,
      "style",
      ["block", "underline", "bar"] as const,
    ),
    blink: requiredBoolean(payload, "blink"),
    visible: requiredBoolean(payload, "visible"),
    color: requiredNullableColor(payload, "color"),
  });
}

function renderRun(value: unknown): RenderRun {
  const payload = record(value, "render run");
  strictObject(
    payload,
    ["text", "fg", "bg", "attrs", "underline", "width_hint"],
    "render run",
  );
  return Object.freeze({
    text: requiredString(payload, "text"),
    fg: requiredNullableColor(payload, "fg"),
    bg: requiredNullableColor(payload, "bg"),
    attrs: requiredUnsignedInteger(payload, "attrs"),
    ...optionalProperty(
      "underline",
      Object.hasOwn(payload, "underline")
        ? requiredEnum(
          payload,
          "underline",
          ["single", "double", "curly", "dotted", "dashed"] as const,
        )
        : undefined,
    ),
    ...optionalProperty(
      "widthHint",
      Object.hasOwn(payload, "width_hint")
        ? requiredUint16(payload, "width_hint")
        : undefined,
    ),
  });
}

function renderRow(value: unknown): RenderRow {
  const payload = record(value, "render row");
  strictObject(payload, ["row", "runs"], "render row");
  if (!Array.isArray(payload.runs)) {
    throw new CmuxProtocolError("render row runs must be an array");
  }
  return Object.freeze({
    row: requiredUint16(payload, "row"),
    runs: Object.freeze(payload.runs.map(renderRun)),
  });
}

function renderRows(payload: Record<string, unknown>): readonly RenderRow[] {
  if (!Array.isArray(payload.rows)) {
    throw new CmuxProtocolError("render rows must be an array");
  }
  return Object.freeze(payload.rows.map(renderRow));
}

function renderSnapshot(value: unknown): RenderSnapshot {
  const payload = record(value, "render snapshot");
  strictObject(
    payload,
    [
      "size", "cursor", "default_fg", "default_bg", "scrollback_rows", "rows",
    ],
    "render snapshot",
  );
  const renderSize = size(payload.size);
  const rows = renderRows(payload);
  if (rows.length !== renderSize.rows) {
    throw new CmuxProtocolError("render snapshot rows must match size.rows");
  }
  return Object.freeze({
    size: renderSize,
    cursor: renderCursor(payload.cursor),
    defaultFg: color(payload, "default_fg"),
    defaultBg: color(payload, "default_bg"),
    scrollbackRows: requiredUnsignedInteger(payload, "scrollback_rows"),
    rows,
  });
}

function renderPatch(value: unknown): RenderPatch {
  const payload = record(value, "render patch");
  strictObject(
    payload,
    [
      "cursor", "full_reset", "size", "default_fg", "default_bg",
      "scrollback_rows", "rows",
    ],
    "render patch",
  );
  const fullReset = requiredBoolean(payload, "full_reset");
  const renderSize = Object.hasOwn(payload, "size")
    ? size(payload.size)
    : undefined;
  if (renderSize !== undefined && !fullReset) {
    throw new CmuxProtocolError("render patch resize requires full_reset");
  }
  const rows = renderRows(payload);
  if (renderSize !== undefined && rows.length !== renderSize.rows) {
    throw new CmuxProtocolError("full render patch rows must match size.rows");
  }
  return Object.freeze({
    cursor: renderCursor(payload.cursor),
    fullReset,
    ...optionalProperty("size", renderSize),
    ...optionalProperty(
      "defaultFg",
      Object.hasOwn(payload, "default_fg")
        ? color(payload, "default_fg")
        : undefined,
    ),
    ...optionalProperty(
      "defaultBg",
      Object.hasOwn(payload, "default_bg")
        ? color(payload, "default_bg")
        : undefined,
    ),
    ...optionalProperty(
      "scrollbackRows",
      Object.hasOwn(payload, "scrollback_rows")
        ? requiredUnsignedInteger(payload, "scrollback_rows")
        : undefined,
    ),
    rows,
  });
}

function renderScroll(value: unknown): RenderScroll {
  const payload = record(value, "render scroll");
  strictObject(payload, ["offset", "at_bottom"], "render scroll");
  return Object.freeze({
    offset: requiredDecimal(payload, "offset"),
    atBottom: requiredBoolean(payload, "at_bottom"),
  });
}

function terminalAttachItem(value: unknown): TerminalAttachItem {
  const payload = record(value, "terminal attach item");
  const kind = requiredString(payload, "kind");
  if (kind === "snapshot") {
    strictObject(
      payload,
      ["kind", "terminal_id", "render"],
      "terminal attach snapshot",
    );
    return Object.freeze({
      kind,
      terminalId: requiredId(payload, ["terminal_id"], terminalId),
      render: renderSnapshot(payload.render),
    }) satisfies TerminalAttachSnapshot;
  }
  if (kind === "patch") {
    strictObject(
      payload,
      ["kind", "terminal_id", "render"],
      "terminal attach patch",
    );
    return Object.freeze({
      kind,
      terminalId: requiredId(payload, ["terminal_id"], terminalId),
      render: renderPatch(payload.render),
    }) satisfies TerminalAttachPatch;
  }
  if (kind === "scroll") {
    strictObject(
      payload,
      ["kind", "terminal_id", "scroll"],
      "terminal attach scroll",
    );
    return Object.freeze({
      kind,
      terminalId: requiredId(payload, ["terminal_id"], terminalId),
      scroll: renderScroll(payload.scroll),
    }) satisfies TerminalAttachScroll;
  }
  return Object.freeze({
    kind,
    raw: document(payload, "unknown terminal attach item"),
  }) satisfies Unknown;
}

function pixelSize(value: unknown): PixelSize {
  const payload = record(value, "pixel size");
  strictObject(payload, ["width_px", "height_px"], "pixel size");
  return Object.freeze({
    widthPx: requiredPositiveUint32(payload, "width_px"),
    heightPx: requiredPositiveUint32(payload, "height_px"),
  });
}

function browserAttachItem(value: unknown): BrowserAttachItem {
  const payload = record(value, "browser attach item");
  const kind = requiredString(payload, "kind");
  if (kind === "snapshot") {
    strictObject(
      payload,
      ["kind", "browser", "size"],
      "browser attach snapshot",
    );
    return Object.freeze({
      kind,
      browser: browserSnapshot(payload.browser),
      size: pixelSize(payload.size),
    }) satisfies BrowserAttachSnapshot;
  }
  if (kind === "frame") {
    strictObject(
      payload,
      [
        "kind",
        "mime_type",
        "data_base64",
        "width_px",
        "height_px",
        "pointer_frame_seq",
      ],
      "browser attach frame",
    );
    const dataBase64 = requiredString(payload, "data_base64");
    if (
      dataBase64.length % 4 !== 0
      || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        dataBase64,
      )
    ) {
      throw new CmuxProtocolError("browser frame data_base64 is invalid");
    }
    return Object.freeze({
      kind,
      mimeType: requiredEnum(
        payload,
        "mime_type",
        ["image/png", "image/jpeg"] as const,
      ),
      dataBase64,
      widthPx: requiredPositiveUint32(payload, "width_px"),
      heightPx: requiredPositiveUint32(payload, "height_px"),
      pointerFrameSeq: requiredNullableDecimal(payload, "pointer_frame_seq"),
    }) satisfies BrowserAttachFrame;
  }
  if (kind === "state") {
    strictObject(
      payload,
      ["kind", "url", "title", "loading"],
      "browser attach state",
    );
    return Object.freeze({
      kind,
      url: requiredString(payload, "url"),
      title: requiredString(payload, "title"),
      loading: requiredBoolean(payload, "loading"),
    }) satisfies BrowserAttachState;
  }
  return Object.freeze({
    kind,
    raw: document(payload, "unknown browser attach item"),
  }) satisfies Unknown;
}

function sidebarAttachItem(value: unknown): SidebarAttachItem {
  const payload = record(value, "sidebar attach item");
  const kind = requiredString(payload, "kind");
  if (kind === "snapshot") {
    strictObject(
      payload,
      ["kind", "sidebar_view", "render"],
      "sidebar attach snapshot",
    );
    return Object.freeze({
      kind,
      sidebarView: sidebarViewSnapshot(payload.sidebar_view),
      render: renderSnapshot(payload.render),
    }) satisfies SidebarAttachSnapshot;
  }
  if (kind === "patch") {
    strictObject(
      payload,
      ["kind", "sidebar_view_id", "render"],
      "sidebar attach patch",
    );
    return Object.freeze({
      kind,
      sidebarViewId: requiredId(
        payload,
        ["sidebar_view_id"],
        sidebarViewId,
      ),
      render: renderPatch(payload.render),
    }) satisfies SidebarAttachPatch;
  }
  if (kind === "scroll") {
    strictObject(
      payload,
      ["kind", "sidebar_view_id", "scroll"],
      "sidebar attach scroll",
    );
    return Object.freeze({
      kind,
      sidebarViewId: requiredId(
        payload,
        ["sidebar_view_id"],
        sidebarViewId,
      ),
      scroll: renderScroll(payload.scroll),
    }) satisfies SidebarAttachScroll;
  }
  return Object.freeze({
    kind,
    raw: document(payload, "unknown sidebar attach item"),
  }) satisfies Unknown;
}

function emptyResult(value: unknown): void {
  const payload = record(value, "empty result");
  strictObject(payload, [], "empty result");
}

function pingResult(value: unknown): PingResult {
  const payload = record(value, "ping result");
  strictObject(payload, ["alive", "cursor"], "ping result");
  return Object.freeze({
    alive: requiredBoolean(payload, "alive"),
    cursor: cursor(payload.cursor),
  });
}

function shutdownResult(value: unknown): ShutdownResult {
  const payload = record(value, "shutdown result");
  strictObject(payload, ["accepted"], "shutdown result");
  return Object.freeze({ accepted: requiredBoolean(payload, "accepted") });
}

function reloadConfigResult(value: unknown): ReloadConfigResult {
  const payload = record(value, "reload config result");
  strictObject(payload, ["reloaded", "warnings"], "reload config result");
  if (
    !Array.isArray(payload.warnings)
    || !payload.warnings.every((item) => typeof item === "string")
  ) {
    throw new CmuxProtocolError("reload config warnings must be an array of strings");
  }
  return Object.freeze({
    reloaded: requiredBoolean(payload, "reloaded"),
    warnings: Object.freeze([...payload.warnings]),
  });
}

function optionalNullableStringProperty(
  payload: Record<string, unknown>,
  key: string,
): string | null | undefined {
  return Object.hasOwn(payload, key)
    ? requiredNullableString(payload, key)
    : undefined;
}

function terminalDefaultsSnapshot(value: unknown): TerminalDefaultsSnapshot {
  const payload = record(value, "terminal defaults snapshot");
  strictObject(
    payload,
    [
      "foreground", "background", "cursor", "selection_background",
      "selection_foreground", "cursor_style", "cursor_blink", "palette",
    ],
    "terminal defaults snapshot",
  );
  let palette: Readonly<Record<string, string>> | undefined;
  if (Object.hasOwn(payload, "palette")) {
    const source = record(payload.palette, "terminal defaults palette");
    const decoded: Record<string, string> = {};
    for (const [key, item] of Object.entries(source)) {
      if (typeof item !== "string") {
        throw new CmuxProtocolError(
          `terminal defaults palette ${JSON.stringify(key)} must be a string`,
        );
      }
      decoded[key] = item;
    }
    palette = Object.freeze(decoded);
  }
  let cursorStyle: TerminalDefaultsSnapshot["cursorStyle"];
  if (Object.hasOwn(payload, "cursor_style")) {
    cursorStyle = payload.cursor_style === null
      ? null
      : requiredEnum(
        payload,
        "cursor_style",
        ["block", "bar", "underline"] as const,
      );
  }
  let cursorBlink: boolean | null | undefined;
  if (Object.hasOwn(payload, "cursor_blink")) {
    cursorBlink = payload.cursor_blink === null
      ? null
      : requiredBoolean(payload, "cursor_blink");
  }
  return Object.freeze({
    ...optionalProperty(
      "foreground",
      optionalNullableStringProperty(payload, "foreground"),
    ),
    ...optionalProperty(
      "background",
      optionalNullableStringProperty(payload, "background"),
    ),
    ...optionalProperty("cursor", optionalNullableStringProperty(payload, "cursor")),
    ...optionalProperty(
      "selectionBackground",
      optionalNullableStringProperty(payload, "selection_background"),
    ),
    ...optionalProperty(
      "selectionForeground",
      optionalNullableStringProperty(payload, "selection_foreground"),
    ),
    ...optionalProperty("cursorStyle", cursorStyle),
    ...optionalProperty("cursorBlink", cursorBlink),
    ...optionalProperty("palette", palette),
  });
}

function terminalScreenResult(value: unknown): TerminalScreenResult {
  const payload = record(value, "terminal screen result");
  strictObject(
    payload,
    [
      "text", "cols", "rows", "cursor_row", "cursor_col", "cursor_visible",
      "extra",
    ],
    "terminal screen result",
  );
  return Object.freeze({
    text: requiredString(payload, "text"),
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
    cursorRow: requiredUint16(payload, "cursor_row"),
    cursorCol: requiredUint16(payload, "cursor_col"),
    cursorVisible: requiredBoolean(payload, "cursor_visible"),
    extra: payload.extra === undefined
      ? Object.freeze({})
      : document(payload.extra, "terminal screen extra"),
  });
}

function requiredBase64(
  payload: Record<string, unknown>,
  key: string,
): string {
  const encoded = requiredString(payload, key);
  if (
    encoded.length % 4 !== 0
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
      encoded,
    )
  ) {
    throw new CmuxProtocolError(`${key} must be canonical base64`);
  }
  return encoded;
}

function terminalStateResult(value: unknown): TerminalStateResult {
  const payload = record(value, "terminal state result");
  strictObject(payload, ["state_base64", "cols", "rows"], "terminal state result");
  return Object.freeze({
    state: decodeBase64(requiredBase64(payload, "state_base64")),
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
  });
}

function terminalHistoryResult(value: unknown): TerminalHistoryResult {
  const payload = record(value, "terminal history result");
  strictObject(payload, ["start", "next", "rows"], "terminal history result");
  if (!Array.isArray(payload.rows)) {
    throw new CmuxProtocolError("terminal history rows must be an array");
  }
  let next: DecimalString | null | undefined;
  if (Object.hasOwn(payload, "next")) {
    next = payload.next === null ? null : requiredDecimal(payload, "next");
  }
  return Object.freeze({
    start: requiredDecimal(payload, "start"),
    ...optionalProperty("next", next),
    rows: Object.freeze(payload.rows.map(renderRow)),
  });
}

function terminalWaitResult(value: unknown): TerminalWaitResult {
  const payload = record(value, "terminal wait result");
  strictObject(payload, ["matched", "text"], "terminal wait result");
  return Object.freeze({
    matched: requiredBoolean(payload, "matched"),
    text: requiredString(payload, "text"),
  });
}

function terminalExitOutcome(value: unknown): TerminalExitOutcome {
  const payload = record(value, "terminal exit outcome");
  const kind = requiredEnum(
    payload,
    "kind",
    ["exit", "signal", "unknown"] as const,
  );
  if (kind === "exit") {
    strictObject(payload, ["kind", "code"], "terminal exit outcome");
    return Object.freeze({
      kind,
      code: requiredInt32(payload, "code"),
    });
  }
  if (kind === "signal") {
    strictObject(
      payload,
      ["kind", "signal", "core_dumped"],
      "terminal exit outcome",
    );
    const signal = requiredInt32(payload, "signal");
    if (signal < 1) {
      throw new CmuxProtocolError("terminal exit signal must be positive");
    }
    return Object.freeze({
      kind,
      signal,
      coreDumped: requiredBoolean(payload, "core_dumped"),
    });
  }
  strictObject(payload, ["kind", "reason"], "terminal exit outcome");
  const reason = requiredString(payload, "reason");
  if (reason.length === 0) {
    throw new CmuxProtocolError("terminal exit unknown reason must be non-empty");
  }
  return Object.freeze({ kind, reason });
}

function terminalExit(value: unknown): TerminalExit {
  const payload = record(value, "terminal exit");
  strictObject(
    payload,
    ["outcome", "exited_at", "revision"],
    "terminal exit",
  );
  return Object.freeze({
    outcome: terminalExitOutcome(payload.outcome),
    exitedAt: requiredDecimal(payload, "exited_at"),
    revision: requiredDecimal(payload, "revision"),
  });
}

function terminalWaitExitResult(value: unknown): TerminalWaitExitResult {
  const payload = record(value, "terminal wait exit result");
  const state = requiredEnum(payload, "state", ["pending", "exited"] as const);
  if (state === "pending") {
    strictObject(
      payload,
      ["state", "terminal_id", "lifecycle", "revision"],
      "terminal wait exit pending result",
    );
    return Object.freeze({
      state,
      terminalId: requiredId(payload, ["terminal_id"], terminalId),
      lifecycle: requiredEnum(
        payload,
        "lifecycle",
        ["launching", "running"] as const,
      ),
      revision: requiredDecimal(payload, "revision"),
    });
  }
  strictObject(
    payload,
    [
      "state", "terminal_id", "lifecycle", "outcome", "exited_at",
      "revision",
    ],
    "terminal wait exit exited result",
  );
  return Object.freeze({
    state,
    terminalId: requiredId(payload, ["terminal_id"], terminalId),
    lifecycle: requiredEnum(payload, "lifecycle", ["exited"] as const),
    outcome: terminalExitOutcome(payload.outcome),
    exitedAt: requiredDecimal(payload, "exited_at"),
    revision: requiredDecimal(payload, "revision"),
  });
}

function terminalCopyResult(value: unknown): TerminalCopyResult {
  const payload = record(value, "terminal copy result");
  strictObject(payload, ["mode", "text"], "terminal copy result");
  return Object.freeze({
    mode: requiredEnum(
      payload,
      "mode",
      ["screen", "selection", "scrollback"] as const,
    ),
    text: requiredString(payload, "text"),
  });
}

function processInfoResult(value: unknown): ProcessInfoResult {
  const payload = record(value, "process info result");
  strictObject(
    payload,
    ["pid", "executable", "argv", "cwd", "children"],
    "process info result",
  );
  if (
    !Array.isArray(payload.argv)
    || !payload.argv.every((item) => typeof item === "string")
  ) {
    throw new CmuxProtocolError("process argv must be an array of strings");
  }
  if (!Array.isArray(payload.children)) {
    throw new CmuxProtocolError("process children must be an array");
  }
  return Object.freeze({
    pid: requiredUnsignedInteger(payload, "pid"),
    ...optionalProperty("executable", optionalString(payload, "executable")),
    argv: Object.freeze([...payload.argv]),
    ...optionalProperty("cwd", optionalString(payload, "cwd")),
    children: Object.freeze(
      payload.children.map((item) =>
        requiredUnsignedInteger({ child: item }, "child")),
    ),
  });
}

function rendererGrantResult(value: unknown): RendererGrant {
  const payload = record(value, "renderer grant result");
  strictObject(
    payload,
    ["endpoint", "terminal_id", "token", "rights", "ttl_ms"],
    "renderer grant result",
  );
  const token = requiredString(payload, "token");
  if (token.length === 0) {
    throw new CmuxProtocolError("renderer grant token must be non-empty");
  }
  if (
    !Array.isArray(payload.rights)
    || payload.rights.length === 0
    || !payload.rights.every((right) => typeof right === "string")
  ) {
    throw new CmuxProtocolError(
      "renderer grant rights must be a non-empty array of strings",
    );
  }
  const ttlMs = requiredPositiveUint32(payload, "ttl_ms");
  if (ttlMs > 60_000) {
    throw new CmuxProtocolError("renderer grant ttl_ms must not exceed 60000");
  }
  return new RendererGrant(
    token,
    requiredString(payload, "endpoint"),
    requiredId(payload, ["terminal_id"], terminalId),
    Object.freeze([...payload.rights]),
    ttlMs,
  );
}

function viewerResizeResult(value: unknown): ViewerResizeResult {
  const payload = record(value, "viewer resize result");
  strictObject(payload, ["accepted", "size", "outcome"], "viewer resize result");
  return Object.freeze({
    accepted: requiredBoolean(payload, "accepted"),
    size: size(payload.size),
    outcome: requiredEnum(
      payload,
      "outcome",
      ["applied", "passive", "superseded"] as const,
    ),
  });
}

function browserViewerResizeResult(
  value: unknown,
): BrowserViewerResizeResult {
  const payload = record(value, "browser viewer resize result");
  strictObject(
    payload,
    ["accepted", "size", "outcome"],
    "browser viewer resize result",
  );
  return Object.freeze({
    accepted: requiredBoolean(payload, "accepted"),
    size: pixelSize(payload.size),
    outcome: requiredEnum(
      payload,
      "outcome",
      ["applied", "passive", "superseded"] as const,
    ),
  });
}

function viewerReleaseResult(value: unknown): ViewerReleaseResult {
  const payload = record(value, "viewer release result");
  strictObject(payload, ["outcome"], "viewer release result");
  return Object.freeze({
    outcome: requiredEnum(
      payload,
      "outcome",
      ["applied", "passive", "superseded"] as const,
    ),
  });
}

function cellPixelsResult(value: unknown): CellPixelsResult {
  const payload = record(value, "cell pixels result");
  strictObject(
    payload,
    ["width_px", "height_px", "resized_terminals", "failures"],
    "cell pixels result",
  );
  if (!Array.isArray(payload.resized_terminals)) {
    throw new CmuxProtocolError("resized_terminals must be an array");
  }
  const failuresSource = record(payload.failures, "cell pixel failures");
  const failures: Record<string, string> = {};
  for (const [key, item] of Object.entries(failuresSource)) {
    if (typeof item !== "string") {
      throw new CmuxProtocolError(
        `cell pixel failure ${JSON.stringify(key)} must be a string`,
      );
    }
    failures[key] = item;
  }
  return Object.freeze({
    widthPx: requiredPositiveUint32(payload, "width_px"),
    heightPx: requiredPositiveUint32(payload, "height_px"),
    resizedTerminalIds: Object.freeze(
      payload.resized_terminals.map((item) =>
        requiredId({ id: item }, ["id"], terminalId)),
    ),
    failures: Object.freeze(failures),
  });
}

function pairingResolutionResult(value: unknown): PairingResolutionResult {
  const payload = record(value, "pairing resolution result");
  strictObject(payload, ["pairing_request"], "pairing resolution result");
  return Object.freeze({
    pairingRequest: pairingRequestSnapshot(payload.pairing_request),
  });
}

abstract class Handle<Id extends string, Value extends Snapshot<Id>> {
  protected abstract readonly selectorKey: string;
  protected cached: Value | undefined;

  constructor(
    readonly client: Client,
    readonly selector: SelectorInput<Id>,
    protected readonly scope: Readonly<Record<string, string>> = {},
    snapshot?: Value,
  ) {
    this.cached = snapshot;
  }

  get id(): Id | undefined {
    return typeof this.selector === "string"
      ? this.selector
      : this.selector.kind === "id"
        ? this.selector.id
        : undefined;
  }

  get snapshot(): Value | undefined {
    return this.cached;
  }

  protected params(): Record<string, unknown> {
    return { ...this.scope, [this.selectorKey]: encodeSelector(this.selector) };
  }

  protected acceptSnapshot(snapshot: Value): this {
    const expectedId = this.cached?.id ?? this.id;
    if (expectedId !== undefined && snapshot.id !== expectedId) {
      throw new CmuxProtocolError(
        `${this.selectorKey} mutation returned ${snapshot.id} for ${expectedId}`,
      );
    }
    this.cached = snapshot;
    return this;
  }

  protected async refreshWith(
    operation: Operation,
    decode: SnapshotDecoder<Value>,
    options: RequestOptions = {},
  ): Promise<Value> {
    const result = await this.client[readOperation](operation, this.params(), options);
    const snapshot = decode(result);
    this.cached = snapshot;
    return snapshot;
  }
}

export interface CreatedWorkspacePath {
  readonly kind: "workspace";
  readonly workspace: Workspace;
}

export interface CreatedTerminalPath {
  readonly kind: "terminal";
  readonly workspace: Workspace;
  readonly screen: Screen;
  readonly pane: Pane;
  readonly tab: Tab;
  readonly terminal: Terminal;
  readonly content: Terminal;
}

export interface CreatedBrowserPath {
  readonly kind: "browser";
  readonly workspace: Workspace;
  readonly screen: Screen;
  readonly pane: Pane;
  readonly tab: Tab;
  readonly browser: Browser;
  readonly content: Browser;
}

export type CreatedPath =
  | CreatedWorkspacePath
  | CreatedTerminalPath
  | CreatedBrowserPath;

type CreatedPathByKind = {
  readonly workspace: CreatedWorkspacePath;
  readonly terminal: CreatedTerminalPath;
  readonly browser: CreatedBrowserPath;
};

interface CreationResolutionCommon {
  readonly correlationKey: string;
  readonly operation?: string;
  readonly idempotencyKey?: string;
  readonly createdPath?: CreatedPath;
  readonly generation?: string;
  readonly revision?: DecimalString;
}

export interface CreationResolutionPending extends CreationResolutionCommon {
  readonly state: "pending";
  readonly recovery: "wait";
}

export interface CreationResolutionCreated extends CreationResolutionCommon {
  readonly state: "created";
  readonly recovery: "none";
  readonly createdPath: CreatedPath;
  readonly generation: string;
  readonly revision: DecimalString;
}

export interface CreationResolutionNotApplied extends CreationResolutionCommon {
  readonly state: "not_applied";
  readonly recovery:
    | "retry_same_idempotency_key"
    | "retry_new_idempotency_key";
}

export interface CreationResolutionIndeterminate extends CreationResolutionCommon {
  readonly state: "indeterminate";
  readonly recovery: "do_not_retry";
}

export type CreationResolution =
  | CreationResolutionPending
  | CreationResolutionCreated
  | CreationResolutionNotApplied
  | CreationResolutionIndeterminate;

export interface SessionCreationOperations {
  resolve(
    correlationKey: string,
    options?: RequestOptions,
  ): Promise<CreationResolution>;
}

export interface ClientOptions extends ResourceProtocolOptions {}

const readOperation = Symbol("readOperation");
const controlOperation = Symbol("controlOperation");
const mutateOperation = Symbol("mutateOperation");
const mutateEmptyOperation = Symbol("mutateEmptyOperation");
const createdOperation = Symbol("createdOperation");
const creationResolutionOperation = Symbol("creationResolutionOperation");
const streamOperation = Symbol("streamOperation");

/** Transport-neutral resource API client. */
export class Client {
  protected readonly protocol: ResourceProtocol;

  constructor(options: ClientOptions) {
    this.protocol = new ResourceProtocol(options);
  }

  get closed(): boolean {
    return this.protocol.isClosed;
  }

  close(): void {
    this.protocol.close();
  }

  machine(selector: SelectorInput<MachineId>): Machine {
    return new Machine(this, selector);
  }

  session(
    selector: SelectorInput<SessionId>,
    options: { machine?: SelectorInput<MachineId> } = {},
  ): Session {
    return new Session(
      this,
      selector,
      options.machine === undefined
        ? { machine: "current" }
        : { machine: encodeSelector(options.machine) },
    );
  }

  async listMachines(options: RequestOptions = {}): Promise<Machine[]> {
    const values = listPayload(await this[readOperation](operations.machineList, {}, options), "machines");
    return values.map((value) => {
      const snapshot = machineSnapshot(value);
      return new Machine(this, selectId(snapshot.id), {}, snapshot);
    });
  }

  async findMachinesByName(name: string, options: RequestOptions = {}): Promise<Machine[]> {
    return (await this.listMachines(options)).filter((item) => item.snapshot?.name === name);
  }

  async [readOperation](
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions = {},
    validateAbandonedResult?: (value: unknown) => unknown,
  ): Promise<unknown> {
    if (operation.class !== "read" && operation.class !== "connection_control") {
      throw new TypeError(`${operation.name} is not a read/control operation`);
    }
    return (
      await this.protocol.request(
        operation,
        params,
        options,
        validateAbandonedResult,
      )
    ).value;
  }

  async [controlOperation]<Value>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    decode: (value: unknown) => Value,
    options: RequestOptions = {},
  ): Promise<Value> {
    if (operation.class !== "connection_control") {
      throw new TypeError(`${operation.name} is not connection control`);
    }
    return decode((await this.protocol.request(operation, params, options)).value);
  }

  async [mutateOperation]<Value, Result>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
    decode: (value: unknown) => Value,
    transform: (value: Value) => Result,
  ): Promise<MutationResult<Result>> {
    if (operation.class !== "mutation") throw new TypeError(`${operation.name} is not a mutation`);
    const response = await this.protocol.request(
      operation,
      mutationParams(operation, params, options),
      options,
    );
    return decodeMutation(response, operation.name, (value) => transform(decode(value)));
  }

  async [mutateEmptyOperation](
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    return this[mutateOperation](
      operation,
      params,
      options,
      emptyResult,
      (value) => value,
    );
  }

  async [createdOperation]<Kind extends CreatedPath["kind"]>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
    expectedKind: Kind,
  ): Promise<MutationResult<CreatedPathByKind[Kind]>>;
  async [createdOperation](
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options?: MutationOptions,
  ): Promise<MutationResult<CreatedPath>>;
  async [createdOperation](
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
    expectedKind?: CreatedPath["kind"],
  ): Promise<MutationResult<CreatedPath>> {
    if (
      options.correlationKey !== undefined
      && !hasUtf8ByteLength(options.correlationKey, 1, 128)
    ) {
      throw new TypeError("correlationKey must contain 1 to 128 UTF-8 bytes");
    }
    const requestParams = options.correlationKey === undefined
      ? params
      : { ...params, correlation_key: options.correlationKey };
    const response = await this.protocol.request(
      operation,
      mutationParams(operation, requestParams, options),
      options,
    );
    return decodeMutation(
      response,
      operation.name,
      (value) => {
        const path = this.createdPath(value, requestParams);
        if (expectedKind !== undefined && path.kind !== expectedKind) {
          throw new CmuxProtocolError(
            `${operation.name} returned a ${path.kind} created path; `
            + `expected ${expectedKind}`,
          );
        }
        return path;
      },
    );
  }

  async [creationResolutionOperation](
    params: Readonly<Record<string, unknown>>,
    correlationKey: string,
    options: RequestOptions = {},
  ): Promise<CreationResolution> {
    if (!hasUtf8ByteLength(correlationKey, 1, 128)) {
      throw new TypeError("correlation key must contain 1 to 128 UTF-8 bytes");
    }
    const requestParams = { ...params, correlation_key: correlationKey };
    const value = await this[readOperation](
      operations.sessionCreationResolve,
      requestParams,
      options,
    );
    const result = this.creationResolution(value, requestParams);
    if (result.correlationKey !== correlationKey) {
      throw new CmuxProtocolError(
        `creation resolution returned correlation key ${JSON.stringify(result.correlationKey)} `
        + `for ${JSON.stringify(correlationKey)}`,
      );
    }
    return result;
  }

  async [streamOperation]<Value>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    decode: (value: unknown) => Value,
    options: RequestOptions = {},
    validate?: (value: Value, cursor: Cursor | undefined) => void,
  ): Promise<ResourceStream<Value>> {
    return this.protocol.openStream(operation, params, decode, options, validate);
  }

  private createdPath(
    value: unknown,
    requestParams: Readonly<Record<string, unknown>>,
  ): CreatedPath {
    const payload = record(value, "created path");
    const kind = requiredEnum(
      payload,
      "kind",
      ["workspace", "terminal", "browser"] as const,
    );
    strictObject(
      payload,
      kind === "workspace"
        ? ["kind", "workspace_id"]
        : [
          "kind", "workspace_id", "screen_id", "pane_id", "tab_id",
          kind === "terminal" ? "terminal_id" : "browser_id",
        ],
      "created path",
    );
    if (
      typeof requestParams.machine !== "string"
      || typeof requestParams.session !== "string"
    ) {
      throw new CmuxProtocolError(
        "created path request omitted machine or session selector",
      );
    }
    const workspace = requiredId(payload, ["workspace_id"], workspaceId);
    const sessionScope = {
      machine: requestParams.machine,
      session: requestParams.session,
    };
    const workspaceHandle = new Workspace(this, workspace, sessionScope);
    if (kind === "workspace") {
      return Object.freeze({
        kind,
        workspace: workspaceHandle,
      });
    }
    const screen = requiredId(payload, ["screen_id"], screenId);
    const pane = requiredId(payload, ["pane_id"], paneId);
    const tab = requiredId(payload, ["tab_id"], tabId);
    const workspaceScope = { ...sessionScope, workspace };
    const screenHandle = new Screen(this, screen, workspaceScope);
    const screenScope = { ...workspaceScope, screen };
    const paneHandle = new Pane(this, pane, screenScope);
    const paneScope = { ...screenScope, pane };
    const tabHandle = new Tab(this, tab, paneScope);
    const tabScope = { ...paneScope, tab };
    if (kind === "terminal") {
      const terminal = requiredId(payload, ["terminal_id"], terminalId);
      const terminalHandle = new Terminal(this, terminal, tabScope);
      return Object.freeze({
        kind,
        workspace: workspaceHandle,
        screen: screenHandle,
        pane: paneHandle,
        tab: tabHandle,
        terminal: terminalHandle,
        content: terminalHandle,
      });
    }
    const browser = requiredId(payload, ["browser_id"], browserId);
    const browserHandle = new Browser(this, browser, tabScope);
    return Object.freeze({
      kind,
      workspace: workspaceHandle,
      screen: screenHandle,
      pane: paneHandle,
      tab: tabHandle,
      browser: browserHandle,
      content: browserHandle,
    });
  }

  private creationResolution(
    value: unknown,
    requestParams: Readonly<Record<string, unknown>>,
  ): CreationResolution {
    const payload = record(value, "creation resolution");
    strictObject(
      payload,
      [
        "correlation_key", "state", "recovery", "operation",
        "idempotency_key", "created_path", "generation", "revision",
      ],
      "creation resolution",
    );
    const correlationKey = requiredGeneration(payload, "correlation_key");
    const state = requiredEnum(
      payload,
      "state",
      ["pending", "created", "not_applied", "indeterminate"] as const,
    );
    const recovery = requiredEnum(
      payload,
      "recovery",
      [
        "retry_same_idempotency_key", "retry_new_idempotency_key", "wait",
        "none", "do_not_retry",
      ] as const,
    );
    const operation = optionalString(payload, "operation");
    if (operation !== undefined && operation.length === 0) {
      throw new CmuxProtocolError("creation resolution operation must be non-empty");
    }
    const idempotencyKey = Object.hasOwn(payload, "idempotency_key")
      ? requiredIdempotencyKey(payload, "idempotency_key")
      : undefined;
    const createdPath = Object.hasOwn(payload, "created_path")
      ? this.createdPath(payload.created_path, requestParams)
      : undefined;
    const generation = Object.hasOwn(payload, "generation")
      ? requiredGeneration(payload, "generation")
      : undefined;
    const revision = Object.hasOwn(payload, "revision")
      ? requiredDecimal(payload, "revision")
      : undefined;
    const common = {
      correlationKey,
      ...optionalProperty("operation", operation),
      ...optionalProperty("idempotencyKey", idempotencyKey),
      ...optionalProperty("createdPath", createdPath),
      ...optionalProperty("generation", generation),
      ...optionalProperty("revision", revision),
    };
    if (state === "pending") {
      if (recovery !== "wait") {
        throw new CmuxProtocolError("pending creation resolution requires wait recovery");
      }
      return Object.freeze({ ...common, state, recovery });
    }
    if (state === "created") {
      if (
        recovery !== "none"
        || createdPath === undefined
        || generation === undefined
        || revision === undefined
      ) {
        throw new CmuxProtocolError(
          "created resolution requires none recovery, created path, generation, and revision",
        );
      }
      return Object.freeze({
        ...common,
        state,
        recovery,
        createdPath,
        generation,
        revision,
      });
    }
    if (state === "not_applied") {
      if (
        recovery !== "retry_same_idempotency_key"
        && recovery !== "retry_new_idempotency_key"
      ) {
        throw new CmuxProtocolError(
          "not_applied creation resolution requires a retry recovery",
        );
      }
      return Object.freeze({ ...common, state, recovery });
    }
    if (recovery !== "do_not_retry") {
      throw new CmuxProtocolError(
        "indeterminate creation resolution requires do_not_retry recovery",
      );
    }
    return Object.freeze({ ...common, state, recovery });
  }
}

function decodeMutation<Value>(
  response: OperationResponse,
  operation: string,
  decode: (value: unknown) => Value,
): MutationResult<Value> {
  const payload = record(response.value, "mutation result");
  void response.idempotencyKey;
  void operation;
  strictObject(
    payload,
    ["value", "generation", "revision", "replayed"],
    "mutation result",
  );
  if (!Object.hasOwn(payload, "value")) {
    throw new CmuxProtocolError("mutation result omitted value");
  }
  const generation = requiredGeneration(payload, "generation");
  return Object.freeze({
    value: decode(payload.value),
    generation,
    revision: requiredDecimal(payload, "revision"),
    replayed: requiredBoolean(payload, "replayed"),
  });
}

export class Machine extends Handle<MachineId, MachineSnapshot> {
  protected readonly selectorKey = "machine";
  session(selector: SelectorInput<SessionId>): Session {
    return new Session(this.client, selector, { machine: encodeSelector(this.selector) });
  }

  refresh(options: RequestOptions = {}): Promise<MachineSnapshot> {
    return this.refreshWith(operations.machineGet, machineSnapshot, options);
  }

  async listSessions(options: RequestOptions = {}): Promise<Session[]> {
    const scope = { machine: encodeSelector(this.selector) };
    return listPayload(
      await this.client[readOperation](operations.sessionList, scope, options),
      "sessions",
    ).map((value) => {
      const snapshot = sessionSnapshot(value);
      return new Session(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async findSessionsByName(name: string, options: RequestOptions = {}): Promise<Session[]> {
    return (await this.listSessions(options)).filter((item) => item.snapshot?.name === name);
  }

  openSession(
    selector: SelectorInput<SessionId>,
    options: MutationOptions = {},
  ): Promise<MutationResult<Session>> {
    const scope = { machine: encodeSelector(this.selector) };
    return this.client[mutateOperation](
      operations.sessionOpen,
      { ...scope, session: encodeSelector(selector) },
      options,
      sessionSnapshot,
      (snapshot) => new Session(this.client, selectId(snapshot.id), scope, snapshot),
    );
  }

}

export class Session extends Handle<SessionId, SessionSnapshot> {
  protected readonly selectorKey = "session";
  readonly creation: SessionCreationOperations = Object.freeze({
    resolve: (
      correlationKey: string,
      options: RequestOptions = {},
    ): Promise<CreationResolution> =>
      this.client[creationResolutionOperation](
        this.params(),
        correlationKey,
        options,
      ),
  });

  private nestedScope(): Record<string, string> {
    return { ...this.scope, session: encodeSelector(this.selector) };
  }

  workspace(selector: SelectorInput<WorkspaceId>): Workspace {
    return new Workspace(this.client, selector, this.nestedScope());
  }

  connectedClient(selector: SelectorInput<ConnectedClientId>): ConnectedClient {
    return new ConnectedClient(this.client, selector, this.nestedScope());
  }

  terminal(selector: SelectorInput<TerminalId>): Terminal {
    return new Terminal(this.client, selector, this.nestedScope());
  }

  browser(selector: SelectorInput<BrowserId>): Browser {
    return new Browser(this.client, selector, this.nestedScope());
  }

  sidebarView(selector: SelectorInput<SidebarViewId>): SidebarView {
    return new SidebarView(this.client, selector, this.nestedScope());
  }

  refresh(options: RequestOptions = {}): Promise<SessionSnapshot> {
    return this.refreshWith(operations.sessionGet, sessionSnapshot, options);
  }

  async fullSnapshot(options: RequestOptions = {}): Promise<ResourceSnapshot> {
    return resourceSnapshot(
      await this.client[readOperation](operations.sessionSnapshot, this.params(), options),
    );
  }

  async ping(options: RequestOptions = {}): Promise<PingResult> {
    return pingResult(
      await this.client[readOperation](operations.sessionPing, this.params(), options),
    );
  }

  events(options: SessionEventsOptions = {}): Promise<ResourceStream<SessionEvent>> {
    return this.client[streamOperation](
      operations.sessionEvents,
      { ...this.params(), ...optionFields(options) },
      sessionEvent,
      options,
    );
  }

  journal(options: SessionJournalOptions = {}): Promise<ResourceStream<SessionJournalRecord>> {
    return this.client[streamOperation](
      operations.sessionJournalSubscribe,
      { ...this.params(), ...journalOptionsFields(options) },
      sessionJournalRecord,
      options,
      validateSessionJournalStreamItem,
    );
  }

  shutdown(
    force = false,
    options: MutationOptions = {},
  ): Promise<MutationResult<ShutdownResult>> {
    return this.client[mutateOperation](
      operations.sessionShutdown,
      { ...this.params(), force },
      options,
      shutdownResult,
      (result) => result,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<ShutdownResult>> {
    return this.shutdown(false, options);
  }

  reloadConfig(
    options: MutationOptions = {},
  ): Promise<MutationResult<ReloadConfigResult>> {
    return this.client[mutateOperation](
      operations.sessionReloadConfig,
      this.params(),
      options,
      reloadConfigResult,
      (result) => result,
    );
  }

  updateTerminalDefaults(
    value: TerminalDefaultsOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<TerminalDefaultsSnapshot>> {
    return this.client[mutateOperation](
      operations.sessionTerminalDefaultsUpdate,
      { ...this.params(), ...optionFields(value) },
      options,
      terminalDefaultsSnapshot,
      (snapshot) => snapshot,
    );
  }

  setWindowTitle(title: string, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.sessionWindowTitleSet,
      { ...this.params(), title },
      options,
    );
  }

  clearWindowTitle(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.sessionWindowTitleClear,
      this.params(),
      options,
    );
  }

  async listWorkspaces(options: RequestOptions = {}): Promise<Workspace[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.workspaceList, scope, options),
      "workspaces",
    ).map((value) => {
      const snapshot = workspaceSnapshot(value);
      return new Workspace(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async findWorkspacesByName(
    name: string,
    options: RequestOptions = {},
  ): Promise<Workspace[]> {
    return (await this.listWorkspaces(options)).filter((item) => item.snapshot?.name === name);
  }

  createWorkspace(
    create: CreateWorkspaceOptions = {},
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedPath>> {
    const params = {
      ...this.nestedScope(),
      initial_content: create.initialContent ?? "terminal",
      ...(create.name !== undefined ? { name: create.name } : {}),
    };
    return this.client[createdOperation](operations.workspaceCreate, params, options);
  }

  async listConnectedClients(options: RequestOptions = {}): Promise<ConnectedClient[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.clientList, scope, options),
      "clients",
    ).map((value) => {
      const snapshot = connectedClientSnapshot(value);
      return new ConnectedClient(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listTerminals(options: RequestOptions = {}): Promise<Terminal[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.terminalList, scope, options),
      "terminals",
    ).map((value) => {
      const snapshot = terminalSnapshot(value);
      return new Terminal(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listBrowsers(options: RequestOptions = {}): Promise<Browser[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.browserList, scope, options),
      "browsers",
    ).map((value) => {
      const snapshot = browserSnapshot(value);
      return new Browser(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listPairingRequests(options: RequestOptions = {}): Promise<PairingRequest[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.pairingRequestList, scope, options),
      "pairing_requests",
    ).map((value) => {
      const snapshot = pairingRequestSnapshot(value);
      return new PairingRequest(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async projection(
    selector: SelectorInput<ProjectionId> = selectCurrent<ProjectionId>(),
    options: RequestOptions = {},
  ): Promise<FrontendProjection> {
    const scope = this.nestedScope();
    const snapshot = frontendProjectionSnapshot(
      await this.client[readOperation](
        operations.frontendProjectionGet,
        { ...scope, frontend_projection: encodeSelector(selector) },
        options,
      ),
    );
    return new FrontendProjection(this.client, selectId(snapshot.id), scope, snapshot);
  }

  async listNotifications(
    options: RequestOptions & { readonly limit?: number } = {},
  ): Promise<Notification[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](
        operations.notificationList,
        { ...scope, ...optionFields(options) },
        options,
      ),
      "notifications",
    ).map((value) => {
      const snapshot = notificationSnapshot(value);
      return new Notification(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  createNotification(
    create: NotificationOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Notification>> {
    const scope = this.nestedScope();
    return this.client[mutateOperation](
      operations.notificationCreate,
      { ...scope, ...optionFields(create) },
      options,
      notificationSnapshot,
      (snapshot) => new Notification(this.client, selectId(snapshot.id), scope, snapshot),
    );
  }

  async listAgents(
    options: RequestOptions & {
      readonly terminalId?: TerminalId;
      readonly state?: AgentSnapshot["state"];
    } = {},
  ): Promise<Agent[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](
        operations.agentList,
        { ...scope, ...optionFields(options) },
        options,
      ),
      "agents",
    ).map((value) => {
      const snapshot = agentSnapshot(value);
      return new Agent(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  reportAgent(
    report: AgentReportOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Agent>> {
    const scope = this.nestedScope();
    return this.client[mutateOperation](
      operations.agentReport,
      { ...scope, ...optionFields(report) },
      options,
      agentSnapshot,
      (snapshot) => new Agent(this.client, selectId(snapshot.id), scope, snapshot),
    );
  }
}

export class Workspace extends Handle<WorkspaceId, WorkspaceSnapshot> {
  protected readonly selectorKey = "workspace";
  private nestedScope(): Record<string, string> {
    return { ...this.scope, workspace: encodeSelector(this.selector) };
  }

  screen(selector: SelectorInput<ScreenId>): Screen {
    return new Screen(this.client, selector, this.nestedScope());
  }

  refresh(options: RequestOptions = {}): Promise<WorkspaceSnapshot> {
    return this.refreshWith(operations.workspaceGet, workspaceSnapshot, options);
  }

  async listScreens(options: RequestOptions = {}): Promise<Screen[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.screenList, scope, options),
      "screens",
    ).map((value) => {
      const snapshot = screenSnapshot(value);
      return new Screen(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async findScreensByName(name: string, options: RequestOptions = {}): Promise<Screen[]> {
    return (await this.listScreens(options)).filter((item) => item.snapshot?.name === name);
  }

  createScreen(
    create: CreateScreenOptions = {},
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    const scope = this.nestedScope();
    return this.client[createdOperation](
      operations.screenCreate,
      { ...scope, ...optionFields(create) },
      options,
      "terminal",
    );
  }

  rename(name: string, options: MutationOptions = {}): Promise<MutationResult<Workspace>> {
    return this.client[mutateOperation](
      operations.workspaceRename,
      { ...this.params(), name },
      options,
      workspaceSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  move(
    index: number,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.client[mutateOperation](
      operations.workspaceMove,
      {
        ...this.params(),
        index,
      },
      options,
      workspaceSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Workspace>> {
    return this.client[mutateOperation](
      operations.workspaceFocus,
      this.params(),
      options,
      workspaceSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.workspaceClose, this.params(), options);
  }

  run(
    run: RunOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    return this.client[createdOperation](
      operations.workspaceRun,
      { ...this.params(), ...optionFields(run) },
      options,
      "terminal",
    );
  }

  applyLayout(
    apply: LayoutApplyOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.client[mutateOperation](
      operations.workspaceLayoutApply,
      { ...this.params(), ...optionFields(apply) },
      options,
      workspaceSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class Screen extends Handle<ScreenId, ScreenSnapshot> {
  protected readonly selectorKey = "screen";
  private nestedScope(): Record<string, string> {
    return { ...this.scope, screen: encodeSelector(this.selector) };
  }

  pane(selector: SelectorInput<PaneId>): Pane {
    return new Pane(this.client, selector, this.nestedScope());
  }

  refresh(options: RequestOptions = {}): Promise<ScreenSnapshot> {
    return this.refreshWith(operations.screenGet, screenSnapshot, options);
  }

  async listPanes(options: RequestOptions = {}): Promise<Pane[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.paneList, scope, options),
      "panes",
    ).map((value) => {
      const snapshot = paneSnapshot(value);
      return new Pane(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async findPanesByName(name: string, options: RequestOptions = {}): Promise<Pane[]> {
    return (await this.listPanes(options)).filter((item) => item.snapshot?.name === name);
  }

  createPane(
    create: CreatePaneOptions = {},
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    const scope = this.nestedScope();
    return this.client[createdOperation](
      operations.paneCreate,
      { ...scope, ...optionFields(create) },
      options,
      "terminal",
    );
  }

  rename(name: string | null, options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.client[mutateOperation](
      operations.screenRename,
      { ...this.params(), name },
      options,
      screenSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  clearName(options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.rename(null, options);
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.client[mutateOperation](
      operations.screenFocus,
      this.params(),
      options,
      screenSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.screenClose, this.params(), options);
  }

  async exportLayout(options: RequestOptions = {}): Promise<LayoutDocument> {
    return layoutDocument(
      await this.client[readOperation](operations.screenLayoutExport, this.params(), options),
    );
  }

  undoLayout(
    options: MutationOptions & {
      readonly confirmClose?: boolean;
      readonly confirmationToken?: string;
    } = {},
  ): Promise<MutationResult<Screen>> {
    if (
      options.confirmationToken !== undefined
      && !hasUtf8ByteLength(options.confirmationToken, 1, 128)
    ) {
      throw new TypeError("confirmationToken must contain 1 to 128 UTF-8 bytes");
    }
    if (options.confirmClose && options.confirmationToken === undefined) {
      throw new TypeError("confirmClose requires confirmationToken");
    }
    return this.client[mutateOperation](
      operations.screenLayoutUndo,
      {
        ...this.params(),
        confirm_close: options.confirmClose ?? false,
        ...(options.confirmationToken === undefined
          ? {}
          : { confirmation_token: options.confirmationToken }),
      },
      options,
      screenSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class Pane extends Handle<PaneId, PaneSnapshot> {
  protected readonly selectorKey = "pane";
  private nestedScope(): Record<string, string> {
    return { ...this.scope, pane: encodeSelector(this.selector) };
  }

  tab(selector: SelectorInput<TabId>): Tab {
    return new Tab(this.client, selector, this.nestedScope());
  }

  refresh(options: RequestOptions = {}): Promise<PaneSnapshot> {
    return this.refreshWith(operations.paneGet, paneSnapshot, options);
  }

  async listTabs(options: RequestOptions = {}): Promise<Tab[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client[readOperation](operations.tabList, scope, options),
      "tabs",
    ).map((value) => {
      const snapshot = tabSnapshot(value);
      return new Tab(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async findTabsByName(name: string, options: RequestOptions = {}): Promise<Tab[]> {
    return (await this.listTabs(options)).filter((item) => item.snapshot?.name === name);
  }

  createTerminalTab(
    create: CreateTerminalOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    return this.client[createdOperation](
      operations.tabCreateTerminal,
      { ...this.params(), ...optionFields(create) },
      options,
      "terminal",
    );
  }

  createBrowserTab(
    create: CreateBrowserOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedBrowserPath>> {
    return this.client[createdOperation](
      operations.tabCreateBrowser,
      { ...this.params(), ...optionFields(create) },
      options,
      "browser",
    );
  }

  split(
    create: SplitPaneOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    return this.client[createdOperation](
      operations.paneSplit,
      { ...this.params(), ...optionFields(create) },
      options,
      "terminal",
    );
  }

  rename(name: string | null, options: MutationOptions = {}): Promise<MutationResult<Pane>> {
    return this.paneMutation(operations.paneRename, { name }, options);
  }

  clearName(options: MutationOptions = {}): Promise<MutationResult<Pane>> {
    return this.rename(null, options);
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Pane>> {
    return this.paneMutation(operations.paneFocus, {}, options);
  }

  focusDirection(
    direction: Direction,
    options: MutationOptions = {},
  ): Promise<MutationResult<Pane>> {
    return this.paneMutation(operations.paneFocusDirection, { direction }, options);
  }

  async neighbor(
    direction: Direction,
    options: RequestOptions = {},
  ): Promise<Pane | null> {
    const payload = record(
      await this.client[readOperation](
        operations.paneNeighborGet,
        { ...this.params(), direction },
        options,
      ),
      "pane neighbor result",
    );
    strictObject(payload, ["pane"], "pane neighbor result");
    if (payload.pane === undefined || payload.pane === null) return null;
    const snapshot = paneSnapshot(payload.pane);
    return new Pane(this.client, selectId(snapshot.id), this.scope, snapshot);
  }

  swap(
    other: {
      workspace: SelectorInput<WorkspaceId>;
      screen: SelectorInput<ScreenId>;
      pane: SelectorInput<PaneId>;
    },
    options: MutationOptions = {},
  ): Promise<MutationResult<Pane>> {
    return this.paneMutation(
      operations.paneSwap,
      {
        other_workspace: encodeSelector(other.workspace),
        other_screen: encodeSelector(other.screen),
        other_pane: encodeSelector(other.pane),
      },
      options,
    );
  }

  zoom(enabled?: boolean, options: MutationOptions = {}): Promise<MutationResult<Pane>> {
    return this.paneMutation(
      operations.paneZoom,
      enabled === undefined ? {} : { enabled },
      options,
    );
  }

  setSplitRatio(
    splitId: SplitId,
    ratio: number,
    options: MutationOptions = {},
  ): Promise<MutationResult<Pane>> {
    return this.paneMutation(
      operations.paneSplitRatioSet,
      { split_id: splitId, ratio },
      options,
    );
  }

  setViewportWidth(columns: number, options: MutationOptions = {}): Promise<MutationResult<Pane>> {
    return this.paneMutation(operations.paneViewportWidthSet, { columns }, options);
  }

  run(
    run: RunOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedTerminalPath>> {
    return this.client[createdOperation](
      operations.paneRun,
      { ...this.params(), ...optionFields(run) },
      options,
      "terminal",
    );
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.paneClose, this.params(), options);
  }

  private paneMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Pane>> {
    return this.client[mutateOperation](
      operation,
      { ...this.params(), ...params },
      options,
      paneSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class Tab extends Handle<TabId, TabSnapshot> {
  protected readonly selectorKey = "tab";
  terminal(selector: SelectorInput<TerminalId>): Terminal {
    return new Terminal(this.client, selector, {
      ...this.scope,
      tab: encodeSelector(this.selector),
    });
  }

  browser(selector: SelectorInput<BrowserId>): Browser {
    return new Browser(this.client, selector, {
      ...this.scope,
      tab: encodeSelector(this.selector),
    });
  }

  refresh(options: RequestOptions = {}): Promise<TabSnapshot> {
    return this.refreshWith(operations.tabGet, tabSnapshot, options);
  }

  rename(name: string | null, options: MutationOptions = {}): Promise<MutationResult<Tab>> {
    return this.tabMutation(operations.tabRename, { name }, options);
  }

  clearName(options: MutationOptions = {}): Promise<MutationResult<Tab>> {
    return this.rename(null, options);
  }

  move(
    destination: {
      workspace: SelectorInput<WorkspaceId>;
      screen: SelectorInput<ScreenId>;
      pane: SelectorInput<PaneId>;
      index: number;
    },
    options: MutationOptions = {},
  ): Promise<MutationResult<Tab>> {
    return this.tabMutation(
      operations.tabMove,
      {
        destination_workspace: encodeSelector(destination.workspace),
        destination_screen: encodeSelector(destination.screen),
        destination_pane: encodeSelector(destination.pane),
        index: destination.index,
      },
      options,
    );
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Tab>> {
    return this.tabMutation(operations.tabFocus, {}, options);
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.tabClose, this.params(), options);
  }

  private tabMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Tab>> {
    return this.client[mutateOperation](
      operation,
      { ...this.params(), ...params },
      options,
      tabSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class Terminal extends Handle<TerminalId, TerminalSnapshot> {
  protected readonly selectorKey = "terminal";
  refresh(options: RequestOptions = {}): Promise<TerminalSnapshot> {
    return this.refreshWith(operations.terminalGet, terminalSnapshot, options);
  }

  write(text: string, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.terminalInputWrite,
      { ...this.params(), text },
      options,
    );
  }

  writeBase64(
    bytesBase64: string,
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    requiredBase64({ bytes_base64: bytesBase64 }, "bytes_base64");
    return this.client[mutateEmptyOperation](
      operations.terminalInputWrite,
      { ...this.params(), bytes_base64: bytesBase64 },
      options,
    );
  }

  writeBytes(
    bytes: Uint8Array,
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    return this.writeBase64(encodeBase64(bytes), options);
  }

  keys(input: KeyInputOptions, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.terminalInputKeys,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  mouse(input: TerminalMouseOptions, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.terminalInputMouse,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  setFocused(focused: boolean, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.terminalInputFocus,
      { ...this.params(), focused },
      options,
    );
  }

  async readScreen(options: RequestOptions = {}): Promise<TerminalScreenResult> {
    return terminalScreenResult(
      await this.client[readOperation](
        operations.terminalScreenRead,
        this.params(),
        options,
      ),
    );
  }

  async readState(options: RequestOptions = {}): Promise<TerminalStateResult> {
    return terminalStateResult(
      await this.client[readOperation](
        operations.terminalStateRead,
        this.params(),
        options,
      ),
    );
  }

  async readHistory(
    history: TerminalHistoryOptions = {},
    options: RequestOptions = {},
  ): Promise<TerminalHistoryResult> {
    return terminalHistoryResult(
      await this.client[readOperation](
        operations.terminalHistoryRead,
        { ...this.params(), ...optionFields(history) },
        options,
      ),
    );
  }

  clearHistory(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.terminalHistoryClear, this.params(), options);
  }

  async wait(
    wait: TerminalWaitOptions,
    options: RequestOptions = {},
  ): Promise<TerminalWaitResult> {
    return terminalWaitResult(
      await this.client[readOperation](
        operations.terminalWait,
        {
          ...this.params(),
          pattern: wait.pattern,
          ...(wait.timeoutMs !== undefined
            ? { timeout_ms: wait.timeoutMs }
            : {}),
        },
        {
          ...options,
          ...(options.signal === undefined && wait.signal !== undefined
            ? { signal: wait.signal }
            : {}),
        },
        terminalWaitResult,
      ),
    );
  }

  async waitExit(
    timeoutMs?: DecimalString,
    options: RequestOptions = {},
  ): Promise<TerminalWaitExitResult> {
    const expectedId = this.cached?.id ?? this.id;
    const decodeResult = (value: unknown): TerminalWaitExitResult => {
      const result = terminalWaitExitResult(value);
      if (expectedId !== undefined && result.terminalId !== expectedId) {
        throw new CmuxProtocolError(
          `terminal wait_exit returned ${result.terminalId} for ${expectedId}`,
        );
      }
      return result;
    };
    return decodeResult(
      await this.client[readOperation](
        operations.terminalWaitExit,
        {
          ...this.params(),
          ...(timeoutMs !== undefined ? { timeout_ms: timeoutMs } : {}),
        },
        options,
        decodeResult,
      ),
    );
  }

  async copy(
    mode?: "screen" | "selection" | "scrollback",
    options: RequestOptions = {},
  ): Promise<TerminalCopyResult> {
    return terminalCopyResult(
      await this.client[readOperation](
        operations.terminalCopy,
        { ...this.params(), ...(mode !== undefined ? { mode } : {}) },
        options,
      ),
    );
  }

  async process(options: RequestOptions = {}): Promise<ProcessInfoResult> {
    return processInfoResult(
      await this.client[readOperation](
        operations.terminalProcessGet,
        this.params(),
        options,
      ),
    );
  }

  async createRendererGrant(
    ttlMs?: number,
    options: RequestOptions = {},
  ): Promise<RendererGrant> {
    const result = await this.client[controlOperation](
      operations.terminalRendererGrantCreate,
      {
        ...this.params(),
        ...(ttlMs !== undefined ? { ttl_ms: ttlMs } : {}),
      },
      rendererGrantResult,
      options,
    );
    const expectedId = this.cached?.id ?? this.id;
    if (expectedId !== undefined && result.terminalId !== expectedId) {
      throw new CmuxProtocolError(
        `renderer grant returned ${result.terminalId} for ${expectedId}`,
      );
    }
    return result;
  }

  resizeViewer(
    attachmentLease: string,
    size: ViewerSizeOptions,
    options: RequestOptions = {},
  ): Promise<ViewerResizeResult> {
    return this.client[controlOperation](
      operations.terminalViewerResize,
      { ...this.params(), attachment_lease: attachmentLease, ...optionFields(size) },
      viewerResizeResult,
      options,
    );
  }

  releaseViewer(
    attachmentLease: string,
    options: RequestOptions = {},
  ): Promise<ViewerReleaseResult> {
    return this.client[controlOperation](
      operations.terminalViewerRelease,
      { ...this.params(), attachment_lease: attachmentLease },
      viewerReleaseResult,
      options,
    );
  }

  scrollViewport(deltaRows: number, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.terminalViewportScroll,
      { ...this.params(), delta_rows: deltaRows },
      options,
    );
  }

  move(
    destination: {
      workspace: SelectorInput<WorkspaceId>;
      screen: SelectorInput<ScreenId>;
      pane: SelectorInput<PaneId>;
      index: number;
    },
    options: MutationOptions = {},
  ): Promise<MutationResult<Terminal>> {
    return this.client[mutateOperation](
      operations.terminalMove,
      {
        ...this.params(),
        destination_workspace: encodeSelector(destination.workspace),
        destination_screen: encodeSelector(destination.screen),
        destination_pane: encodeSelector(destination.pane),
        index: destination.index,
      },
      options,
      terminalSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }

  project(
    destination: {
      workspace: SelectorInput<WorkspaceId>;
      screen: SelectorInput<ScreenId>;
      pane: SelectorInput<PaneId>;
      index: number;
      name?: string;
    },
    options: MutationOptions = {},
  ): Promise<MutationResult<Tab>> {
    const encodedWorkspace = encodeSelector(destination.workspace);
    const encodedScreen = encodeSelector(destination.screen);
    const encodedPane = encodeSelector(destination.pane);
    const sessionScope = Object.fromEntries(
      Object.entries(this.scope).filter(
        ([key]) => !["workspace", "screen", "pane", "tab"].includes(key),
      ),
    );
    const tabScope = {
      ...sessionScope,
      workspace: encodedWorkspace,
      screen: encodedScreen,
      pane: encodedPane,
    };
    return this.client[mutateOperation](
      operations.terminalProject,
      {
        ...this.params(),
        destination_workspace: encodedWorkspace,
        destination_screen: encodedScreen,
        destination_pane: encodedPane,
        index: destination.index,
        ...(destination.name === undefined ? {} : { name: destination.name }),
      },
      options,
      tabSnapshot,
      (snapshot) => new Tab(this.client, selectId(snapshot.id), tabScope, snapshot),
    );
  }

  attach(
    options: TerminalAttachOptions = {},
  ): Promise<ResourceStream<TerminalAttachItem>> {
    return this.client[streamOperation](
      operations.terminalAttach,
      { ...this.params(), ...optionFields(options) },
      terminalAttachItem,
      options,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.terminalClose, this.params(), options);
  }
}

export class Browser extends Handle<BrowserId, BrowserSnapshot> {
  protected readonly selectorKey = "browser";
  refresh(options: RequestOptions = {}): Promise<BrowserSnapshot> {
    return this.refreshWith(operations.browserGet, browserSnapshot, options);
  }

  navigate(url: string, options: MutationOptions = {}): Promise<MutationResult<Browser>> {
    return this.browserMutation(operations.browserNavigate, { url }, options);
  }

  back(options: MutationOptions = {}): Promise<MutationResult<Browser>> {
    return this.browserMutation(operations.browserBack, {}, options);
  }

  forward(options: MutationOptions = {}): Promise<MutationResult<Browser>> {
    return this.browserMutation(operations.browserForward, {}, options);
  }

  reload(options: MutationOptions = {}): Promise<MutationResult<Browser>> {
    return this.browserMutation(operations.browserReload, {}, options);
  }

  activate(options: MutationOptions = {}): Promise<MutationResult<Browser>> {
    return this.browserMutation(operations.browserActivate, {}, options);
  }

  key(
    key: string,
    input: {
      kind?: "down" | "up" | "press";
      modifiers?: readonly ("shift" | "control" | "alt" | "meta")[];
    } = {},
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.browserInputKey,
      { ...this.params(), key, ...input },
      options,
    );
  }

  text(text: string, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.browserInputText,
      { ...this.params(), text },
      options,
    );
  }

  mouse(input: BrowserMouseOptions, options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.browserInputMouse,
      { ...this.params(), ...browserPointerFields(input) },
      options,
    );
  }

  wheel(
    input: BrowserWheelOptions,
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.browserInputWheel,
      { ...this.params(), ...browserPointerFields(input) },
      options,
    );
  }

  resizeViewer(
    attachmentLease: string,
    size: BrowserViewerSizeOptions,
    options: RequestOptions = {},
  ): Promise<BrowserViewerResizeResult> {
    return this.client[controlOperation](
      operations.browserViewerResize,
      { ...this.params(), attachment_lease: attachmentLease, ...optionFields(size) },
      browserViewerResizeResult,
      options,
    );
  }

  releaseViewer(
    attachmentLease: string,
    options: RequestOptions = {},
  ): Promise<ViewerReleaseResult> {
    return this.client[controlOperation](
      operations.browserViewerRelease,
      { ...this.params(), attachment_lease: attachmentLease },
      viewerReleaseResult,
      options,
    );
  }

  attach(options: BrowserAttachOptions = {}): Promise<ResourceStream<BrowserAttachItem>> {
    return this.client[streamOperation](
      operations.browserAttach,
      { ...this.params(), ...optionFields(options) },
      browserAttachItem,
      options,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](operations.browserClose, this.params(), options);
  }

  private browserMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Browser>> {
    return this.client[mutateOperation](
      operation,
      { ...this.params(), ...params },
      options,
      browserSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class ConnectedClient extends Handle<ConnectedClientId, ClientSnapshot> {
  protected readonly selectorKey = "client";
  refresh(options: RequestOptions = {}): Promise<ClientSnapshot> {
    return this.refreshWith(operations.clientGet, connectedClientSnapshot, options);
  }

  async updateMetadata(
    metadata: { name?: string | null; kind?: string | null },
    options: RequestOptions = {},
  ): Promise<ClientSnapshot> {
    if (metadata.name === undefined && metadata.kind === undefined) {
      throw new TypeError("client metadata update requires name or kind");
    }
    return this.clientControl(
      operations.clientMetadataUpdate,
      { ...this.params(), ...metadata },
      options,
    );
  }

  clearName(options: RequestOptions = {}): Promise<ClientSnapshot> {
    return this.updateMetadata({ name: null }, options);
  }

  async setSizing(
    terminal: SelectorInput<TerminalId>,
    enabled: boolean,
    sizing: { exclusive?: boolean } = {},
    options: RequestOptions = {},
  ): Promise<ClientSnapshot> {
    return this.clientControl(
      operations.clientSizingSet,
      {
        ...this.params(),
        terminal: encodeSelector(terminal),
        enabled,
        exclusive: sizing.exclusive ?? false,
      },
      options,
    );
  }

  async releaseSizing(
    terminal: SelectorInput<TerminalId>,
    options: RequestOptions = {},
  ): Promise<ClientSnapshot> {
    return this.clientControl(
      operations.clientSizingRelease,
      { ...this.params(), terminal: encodeSelector(terminal) },
      options,
    );
  }

  setCellPixels(
    widthPx: number,
    heightPx: number,
    options: RequestOptions = {},
  ): Promise<CellPixelsResult> {
    return this.client[controlOperation](
      operations.clientCellPixelsSet,
      { ...this.params(), width_px: widthPx, height_px: heightPx },
      cellPixelsResult,
      options,
    );
  }

  detach(options: RequestOptions = {}): Promise<void> {
    return this.client[controlOperation](
      operations.clientDetach,
      this.params(),
      emptyResult,
      options,
    );
  }

  private async clientControl(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions,
  ): Promise<ClientSnapshot> {
    const snapshot = connectedClientSnapshot(
      await this.client[readOperation](operation, params, options),
    );
    this.cached = snapshot;
    return snapshot;
  }
}

export class PairingRequest extends Handle<PairingRequestId, PairingRequestSnapshot> {
  protected readonly selectorKey = "pairing_request";
  resolve(
    decision: "accept" | "reject",
    options: MutationOptions = {},
  ): Promise<MutationResult<PairingRequest>> {
    return this.client[mutateOperation](
      operations.pairingRequestResolve,
      { ...this.params(), decision },
      options,
      pairingResolutionResult,
      (result) => this.acceptSnapshot(result.pairingRequest),
    );
  }
}

export class FrontendProjection extends Handle<ProjectionId, FrontendProjectionSnapshot> {
  protected readonly selectorKey = "frontend_projection";
  put(
    value: ProjectionPutOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<FrontendProjection>> {
    return this.client[mutateOperation](
      operations.frontendProjectionPut,
      {
        ...this.params(),
        frontend_id: value.frontendId,
        window_id: value.windowId,
        generation: value.generation,
        projection: value.projection,
        ...(value.expectedProjectionRevision !== undefined
          ? { expected_projection_revision: value.expectedProjectionRevision }
          : {}),
      },
      options,
      frontendProjectionSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export class Notification extends Handle<NotificationId, NotificationSnapshot> {
  protected readonly selectorKey = "notification";
}

export class Agent extends Handle<AgentId, AgentSnapshot> {
  protected readonly selectorKey = "agent";
}

export class SidebarView extends Handle<SidebarViewId, SidebarViewSnapshot> {
  protected readonly selectorKey = "sidebar_view";
  refresh(options: RequestOptions = {}): Promise<SidebarViewSnapshot> {
    return this.refreshWith(
      operations.sidebarViewGet,
      sidebarViewSnapshot,
      options,
    );
  }

  ensure(
    ensure: SidebarEnsureOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<SidebarView>> {
    return this.client[mutateOperation](
      operations.sidebarViewEnsure,
      { ...this.scope, ...optionFields(ensure) },
      options,
      sidebarViewSnapshot,
      (snapshot) => new SidebarView(
        this.client,
        selectId(snapshot.id),
        this.scope,
        snapshot,
      ),
    );
  }

  attach(options: RequestOptions = {}): Promise<ResourceStream<SidebarAttachItem>> {
    return this.client[streamOperation](
      operations.sidebarViewAttach,
      this.params(),
      sidebarAttachItem,
      options,
    );
  }

  input(
    input: SidebarInputOptions,
    options: MutationOptions = {},
  ): Promise<MutationReceipt> {
    return this.client[mutateEmptyOperation](
      operations.sidebarViewInput,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  resize(
    size: SidebarResizeOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<SidebarView>> {
    return this.sidebarMutation(operations.sidebarViewResize, optionFields(size), options);
  }

  reload(options: MutationOptions = {}): Promise<MutationResult<SidebarView>> {
    return this.sidebarMutation(operations.sidebarViewReload, {}, options);
  }

  private sidebarMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<SidebarView>> {
    return this.client[mutateOperation](
      operation,
      { ...this.params(), ...params },
      options,
      sidebarViewSnapshot,
      (snapshot) => this.acceptSnapshot(snapshot),
    );
  }
}

export { ResourceStream };
