import { CmuxProtocolError } from "./errors.js";
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
  providerActionId,
  providerNoticeId,
  providerScopeId,
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
  type ProviderActionId,
  type ProviderNoticeId,
  type ProviderScopeId,
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
  RendererGrant,
  ExternalMachineSpecifier,
  PairingCode,
  type AgentSnapshot,
  type BrowserAttachFrame,
  type BrowserAttachItem,
  type BrowserAttachSnapshot,
  type BrowserAttachState,
  type BrowserSnapshot,
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
  type MutationResult,
  type NotificationSnapshot,
  type PairingRequestSnapshot,
  type PaneSnapshot,
  type PixelSize,
  type ProviderActionField,
  type ProviderActionSnapshot,
  type ProviderNoticeItem,
  type ProviderNoticeKnown,
  type ProviderNoticeSnapshot,
  type ProviderScopeSnapshot,
  type ResourceChange,
  type ResourceChangeId,
  type ResourceEntitySnapshot,
  type ResourceKind,
  type ResourceSnapshot,
  type ResourceUpsert,
  type RenderCursor,
  type RenderPatch,
  type RenderRow,
  type RenderRun,
  type RenderScroll,
  type RenderSnapshot,
  type ScreenSnapshot,
  type SessionEvent,
  type SessionDelta,
  type SessionSnapshotItem,
  type SessionSnapshot,
  type SidebarAttachItem,
  type SidebarAttachPatch,
  type SidebarAttachScroll,
  type SidebarAttachSnapshot,
  type SidebarViewSnapshot,
  type Snapshot,
  type Size,
  type TabSnapshot,
  type TerminalAttachItem,
  type TerminalAttachPatch,
  type TerminalAttachScroll,
  type TerminalAttachSnapshot,
  type TerminalSnapshot,
  type Unknown,
  type WorkspaceSnapshot,
} from "./models.js";
import type {
  AgentReportOptions,
  BrowserAttachOptions,
  BrowserMouseOptions,
  BrowserViewerSizeOptions,
  CreateBrowserOptions,
  CreateMachineOptions,
  CreatePaneOptions,
  CreateScreenOptions,
  CreateTerminalOptions,
  CreateWorkspaceOptions,
  Direction,
  KeyInputOptions,
  LayoutApplyOptions,
  MutationOptions,
  NotificationOptions,
  ProviderActionOptions,
  RequestOptions,
  RunOptions,
  SessionEventsOptions,
  SidebarEnsureOptions,
  SidebarInputOptions,
  SidebarResizeOptions,
  SplitPaneOptions,
  TerminalAttachOptions,
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

function requiredGeneration(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = requiredString(payload, key);
  if (value.length < 1 || value.length > 128) {
    throw new CmuxProtocolError(
      `resource field ${key} must contain 1 to 128 characters`,
    );
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
    : record(payload.extra, "resource extra");
  return Object.freeze({
    id: requiredId(payload, ["id"], factory),
    extra: Object.freeze({ ...declaredExtra }),
  });
}

function machineSnapshot(value: unknown): MachineSnapshot {
  const payload = unwrap(value, ["machine"]);
  return Object.freeze({
    ...snapshotFields(payload, machineId, [
      "name", "origin", "status", "connectable", "provider_scope_id", "deleted",
      "recoverable",
    ]),
    name: requiredString(payload, "name"),
    origin: requiredEnum(payload, "origin", ["local", "external"] as const),
    status: requiredEnum(
      payload,
      "status",
      ["running", "connecting", "sleeping", "stopped", "unavailable"] as const,
    ),
    connectable: requiredBoolean(payload, "connectable"),
    ...optionalProperty(
      "providerScopeId",
      optionalId(payload, ["provider_scope_id"], providerScopeId),
    ),
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
  return Object.freeze({
    ...snapshotFields(
      payload,
      terminalId,
      ["tab_id", "title", "cwd", "cols", "rows", "running"],
    ),
    tabId: requiredId(payload, ["tab_id"], tabId),
    title: requiredString(payload, "title"),
    ...optionalProperty("cwd", optionalString(payload, "cwd")),
    cols: requiredPositiveUint16(payload, "cols"),
    rows: requiredPositiveUint16(payload, "rows"),
    running: requiredBoolean(payload, "running"),
  });
}

function browserSnapshot(value: unknown): BrowserSnapshot {
  const payload = unwrap(value, ["browser"]);
  return Object.freeze({
    ...snapshotFields(payload, browserId, [
      "tab_id", "url", "title", "loading", "source", "status", "error",
      "frames_stalled", "size",
    ]),
    tabId: requiredId(payload, ["tab_id"], tabId),
    url: requiredString(payload, "url"),
    title: requiredString(payload, "title"),
    loading: requiredBoolean(payload, "loading"),
    source: requiredEnum(payload, "source", ["external", "launched"] as const),
    status: requiredEnum(payload, "status", ["starting", "live", "failed"] as const),
    error: requiredNullableString(payload, "error"),
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
    : record(payload.extra, "layout document extra");
  return Object.freeze({
    version: requiredUnsignedInteger(payload, "version"),
    screenId: requiredId(payload, ["screen_id"], screenId),
    activePaneId: requiredId(payload, ["active_pane_id"], paneId),
    zoomedPaneId,
    root: layoutNode(payload.root),
    extra: Object.freeze({ ...extra }),
  });
}

function auxiliarySnapshot<Id extends string, Value extends Snapshot<Id>>(
  value: unknown,
  name: string,
  factory: IdFactory<Id>,
  _parent?: {
    key: string;
    property: string;
    factory: IdFactory<string>;
  },
): Value {
  const payload = unwrap(value, [name]);
  switch (name) {
    case "pairing_request":
      return Object.freeze({
        ...snapshotFields(
          payload,
          factory,
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
      }) as unknown as Value;
    case "frontend_projection": {
      const base = snapshotFields(
        payload,
        factory,
        ["session_id", "projection"],
      );
      if (!Object.hasOwn(payload, "projection")) {
        throw new CmuxProtocolError("frontend projection omitted projection");
      }
      return Object.freeze({
        ...base,
        sessionId: requiredId(payload, ["session_id"], sessionId),
        projection: payload.projection,
      }) as unknown as Value;
    }
    case "notification":
      return Object.freeze({
        ...snapshotFields(payload, factory, [
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
      }) as unknown as Value;
    case "agent":
      return Object.freeze({
        ...snapshotFields(payload, factory, [
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
      }) as unknown as Value;
    case "sidebar_view":
      return Object.freeze({
        ...snapshotFields(
          payload,
          factory,
          ["session_id", "cols", "rows", "running"],
        ),
        sessionId: requiredId(payload, ["session_id"], sessionId),
        cols: requiredPositiveUint16(payload, "cols"),
        rows: requiredPositiveUint16(payload, "rows"),
        running: requiredBoolean(payload, "running"),
      }) as unknown as Value;
    case "provider_scope":
      return Object.freeze({
        ...snapshotFields(
          payload,
          factory,
          ["name", "kind", "can_admin", "selected"],
        ),
        name: requiredString(payload, "name"),
        kind: requiredEnum(payload, "kind", ["personal", "team"] as const),
        canAdmin: requiredBoolean(payload, "can_admin"),
        selected: requiredBoolean(payload, "selected"),
      }) as unknown as Value;
    case "provider_action": {
      if (!Array.isArray(payload.fields)) {
        throw new CmuxProtocolError("provider action fields must be an array");
      }
      const decodedFields: ProviderActionField[] = payload.fields.map((item) => {
        const field = record(item, "provider action field");
        strictObject(
          field,
          [
            "id", "label", "kind", "required", "max_length", "minimum",
            "maximum", "placeholder",
          ],
          "provider action field",
        );
        const id = requiredString(field, "id");
        if (!id) throw new CmuxProtocolError("provider action field id must be non-empty");
        const kind = requiredEnum(
          field,
          "kind",
          ["text", "email", "integer"] as const,
        );
        const maxLength = Object.hasOwn(field, "max_length")
          ? requiredUnsignedInteger(field, "max_length")
          : undefined;
        if (maxLength === 0) {
          throw new CmuxProtocolError("provider action field max_length must be positive");
        }
        const minimum = Object.hasOwn(field, "minimum")
          ? requiredInt32(field, "minimum")
          : undefined;
        const maximum = Object.hasOwn(field, "maximum")
          ? requiredInt32(field, "maximum")
          : undefined;
        if (minimum !== undefined && maximum !== undefined && minimum > maximum) {
          throw new CmuxProtocolError("provider action field minimum exceeds maximum");
        }
        if (kind === "integer" && (maxLength !== undefined || Object.hasOwn(field, "placeholder"))) {
          throw new CmuxProtocolError("integer provider action fields cannot use text constraints");
        }
        if (kind !== "integer" && (minimum !== undefined || maximum !== undefined)) {
          throw new CmuxProtocolError("text provider action fields cannot use integer constraints");
        }
        return Object.freeze({
          id,
          label: requiredString(field, "label"),
          kind,
          required: requiredBoolean(field, "required"),
          ...optionalProperty("maxLength", maxLength),
          ...optionalProperty("minimum", minimum),
          ...optionalProperty("maximum", maximum),
          ...optionalProperty("placeholder", optionalString(field, "placeholder")),
        });
      });
      return Object.freeze({
        ...snapshotFields(payload, factory, [
          "provider_scope_id", "name", "title", "enabled", "target",
          "destructive", "fields",
        ]),
        providerScopeId: requiredId(
          payload,
          ["provider_scope_id"],
          providerScopeId,
        ),
        name: requiredString(payload, "name"),
        title: requiredString(payload, "title"),
        enabled: requiredBoolean(payload, "enabled"),
        target: requiredEnum(
          payload,
          "target",
          ["scope", "selected_machine", "selected_workspace"] as const,
        ),
        destructive: requiredBoolean(payload, "destructive"),
        fields: Object.freeze(decodedFields),
      }) as unknown as Value;
    }
    case "provider_notice":
      return Object.freeze({
        ...snapshotFields(
          payload,
          factory,
          ["provider_scope_id", "level", "message"],
        ),
        providerScopeId: requiredId(
          payload,
          ["provider_scope_id"],
          providerScopeId,
        ),
        level: requiredEnum(
          payload,
          "level",
          ["info", "warning", "error"] as const,
        ),
        message: requiredString(payload, "message"),
      }) as unknown as Value;
    default:
      throw new CmuxProtocolError(`unknown snapshot type ${JSON.stringify(name)}`);
  }
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

function pairingResolution(value: unknown): PairingRequestSnapshot {
  const payload = record(value, "pairing resolution");
  strictObject(payload, ["pairing_request"], "pairing resolution");
  return auxiliarySnapshot<PairingRequestId, PairingRequestSnapshot>(
    payload.pairing_request,
    "pairing_request",
    pairingRequestId,
  );
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
      timeoutMs: "timeout_ms",
      columns: "cols",
      widthPx: "width_px",
      heightPx: "height_px",
      readOnly: "read_only",
      deltaRows: "delta_rows",
      xPx: "x_px",
      yPx: "y_px",
      clickCount: "click_count",
      terminalId: "terminal_id",
      sourceSession: "source_session",
      dataBase64: "data_base64",
      pluginId: "plugin_id",
    }[key] ?? key;
    result[wireKey] = value;
  }
  return result;
}

function mutationParams(
  operation: Operation,
  params: Readonly<Record<string, unknown>>,
  options: MutationOptions,
): Readonly<Record<string, unknown>> {
  if (options.expectedRevision === undefined) return params;
  if (
    operation.name === "machine.connect_external"
    || operation.name === "machine.create"
    || operation.name === "workspace.create"
  ) {
    throw new TypeError(`${operation.name} does not accept expectedRevision`);
  }
  if (typeof options.expectedRevision !== "string") {
    throw new TypeError("expectedRevision must be a decimal string");
  }
  return {
    ...params,
    expected_revision: decimalString(options.expectedRevision),
  };
}

function document(value: unknown, label = "operation result"): Document {
  return Object.freeze({ ...record(value, label) });
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
    : record(payload.extra, "resource snapshot extra");
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
      (item) => auxiliarySnapshot<NotificationId, NotificationSnapshot>(
        item,
        "notification",
        notificationId,
      ),
    ),
    agents: snapshotList(
      payload,
      "agents",
      (item) => auxiliarySnapshot<AgentId, AgentSnapshot>(
        item,
        "agent",
        agentId,
      ),
    ),
    frontendProjections: snapshotList(
      payload,
      "frontend_projections",
      (item) => auxiliarySnapshot<ProjectionId, FrontendProjectionSnapshot>(
        item,
        "frontend_projection",
        projectionId,
      ),
    ),
    sidebarViews: snapshotList(
      payload,
      "sidebar_views",
      (item) => auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        item,
        "sidebar_view",
        sidebarViewId,
      ),
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
  "provider_scope",
  "provider_action",
  "provider_notice",
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
    case "notification":
      return auxiliarySnapshot<NotificationId, NotificationSnapshot>(
        value,
        "notification",
        notificationId,
      );
    case "agent":
      return auxiliarySnapshot<AgentId, AgentSnapshot>(
        value,
        "agent",
        agentId,
      );
    case "pairing_request":
      return auxiliarySnapshot<PairingRequestId, PairingRequestSnapshot>(
        value,
        "pairing_request",
        pairingRequestId,
      );
    case "frontend_projection":
      return auxiliarySnapshot<ProjectionId, FrontendProjectionSnapshot>(
        value,
        "frontend_projection",
        projectionId,
      );
    case "sidebar_view":
      return auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        value,
        "sidebar_view",
        sidebarViewId,
      );
    case "provider_scope":
      return auxiliarySnapshot<ProviderScopeId, ProviderScopeSnapshot>(
        value,
        "provider_scope",
        providerScopeId,
      );
    case "provider_action":
      return auxiliarySnapshot<ProviderActionId, ProviderActionSnapshot>(
        value,
        "provider_action",
        providerActionId,
      );
    case "provider_notice":
      return auxiliarySnapshot<ProviderNoticeId, ProviderNoticeSnapshot>(
        value,
        "provider_notice",
        providerNoticeId,
      );
  }
}

function resourceChange(value: unknown): ResourceChange {
  const payload = record(value, "resource change");
  const kind = requiredString(payload, "kind");
  if (kind !== "upsert" && kind !== "delete") {
    return Object.freeze({
      kind,
      raw: Object.freeze({ ...payload }),
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
    provider_scope: providerScopeId,
    provider_action: providerActionId,
    provider_notice: providerNoticeId,
  };
  const id = requiredId(payload, ["id"], factories[resource]);
  const sequence = requiredUnsignedInteger(payload, "sequence");
  if (kind === "delete") {
    strictObject(payload, ["kind", "sequence", "resource", "id"], "resource delete");
    return Object.freeze({ kind, sequence, resource, id });
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
  }) satisfies ResourceUpsert;
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
    raw: Object.freeze({ ...payload }),
  }) satisfies Unknown;
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
    raw: Object.freeze({ ...payload }),
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
      ["kind", "mime_type", "data_base64", "width_px", "height_px"],
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
    raw: Object.freeze({ ...payload }),
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
      sidebarView: auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        payload.sidebar_view,
        "sidebar_view",
        sidebarViewId,
      ),
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
    raw: Object.freeze({ ...payload }),
  }) satisfies Unknown;
}

function providerNoticeItem(value: unknown): ProviderNoticeItem {
  const payload = record(value, "provider notice item");
  if (typeof payload.kind !== "string") {
    throw new CmuxProtocolError("provider notice item omitted kind");
  }
  if (payload.kind !== "notice") {
    return Object.freeze({
      kind: payload.kind,
      raw: Object.freeze({ ...payload }),
    }) satisfies Unknown;
  }
  strictObject(
    payload,
    ["kind", "notice", "sequence"],
    "provider notice item",
  );
  return Object.freeze({
    kind: "notice",
    notice: auxiliarySnapshot<ProviderNoticeId, ProviderNoticeSnapshot>(
      payload.notice,
      "provider_notice",
      providerNoticeId,
      {
        key: "provider_scope",
        property: "providerScopeId",
        factory: providerScopeId,
      },
    ),
    sequence: requiredDecimal(payload, "sequence"),
  }) satisfies ProviderNoticeKnown;
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

  protected async refreshWith(
    operation: Operation,
    decode: SnapshotDecoder<Value>,
    options: RequestOptions = {},
  ): Promise<Value> {
    const result = await this.client.read(operation, this.params(), options);
    const snapshot = decode(result);
    this.cached = snapshot;
    return snapshot;
  }
}

export class CreatedPath {
  constructor(
    readonly kind: "workspace" | "terminal" | "browser",
    readonly workspace: Workspace,
    readonly screen?: Screen,
    readonly pane?: Pane,
    readonly tab?: Tab,
    readonly terminal?: Terminal,
    readonly browser?: Browser,
  ) {}

  get content(): Terminal | Browser | undefined {
    return this.terminal ?? this.browser;
  }
}

export interface ClientOptions extends ResourceProtocolOptions {}

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

  providerScope(selector: SelectorInput<ProviderScopeId>): ProviderScope {
    return new ProviderScope(this, selector, { machine: "current" });
  }

  async listMachines(options: RequestOptions = {}): Promise<Machine[]> {
    const values = listPayload(await this.read(operations.machineList, {}, options), "machines");
    return values.map((value) => {
      const snapshot = machineSnapshot(value);
      return new Machine(this, selectId(snapshot.id), {}, snapshot);
    });
  }

  async findMachinesByName(name: string, options: RequestOptions = {}): Promise<Machine[]> {
    return (await this.listMachines(options)).filter((item) => item.snapshot?.name === name);
  }

  async createMachine(
    providerScope: SelectorInput<ProviderScopeId>,
    _create: CreateMachineOptions = {},
    options: MutationOptions = {},
  ): Promise<MutationResult<Machine>> {
    return this.mutate(
      operations.machineCreate,
      { provider_scope: encodeSelector(providerScope) },
      options,
      machineSnapshot,
      (snapshot) => new Machine(this, selectId(snapshot.id), {}, snapshot),
    );
  }

  async listProviderScopes(options: RequestOptions = {}): Promise<ProviderScope[]> {
    const values = listPayload(
      await this.read(
        operations.providerScopeList,
        { machine: "current" },
        options,
      ),
      "provider_scopes",
    );
    return values.map((value) => {
      const snapshot = auxiliarySnapshot<ProviderScopeId, ProviderScopeSnapshot>(
        value,
        "provider_scope",
        providerScopeId,
      );
      return new ProviderScope(
        this,
        selectId(snapshot.id),
        { machine: "current" },
        snapshot,
      );
    });
  }

  async read(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions = {},
  ): Promise<unknown> {
    if (operation.class !== "read" && operation.class !== "connection_control") {
      throw new TypeError(`${operation.name} is not a read/control operation`);
    }
    return (await this.protocol.request(operation, params, options)).value;
  }

  async control(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions = {},
  ): Promise<Document> {
    if (operation.class !== "connection_control") {
      throw new TypeError(`${operation.name} is not connection control`);
    }
    return document((await this.protocol.request(operation, params, options)).value);
  }

  async mutate<Value, Result>(
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

  async mutateDocument(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.mutate(operation, params, options, document, (value) => value);
  }

  async created(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedPath>> {
    const response = await this.protocol.request(
      operation,
      mutationParams(operation, params, options),
      options,
    );
    return decodeMutation(
      response,
      operation.name,
      (value) => this.createdPath(value, params),
    );
  }

  async stream<Value>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    decode: (value: unknown) => Value,
    signal?: AbortSignal,
  ): Promise<ResourceStream<Value>> {
    return this.protocol.openStream(operation, params, decode, signal);
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
      return new CreatedPath(kind, workspaceHandle);
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
      return new CreatedPath(
        kind,
        workspaceHandle,
        screenHandle,
        paneHandle,
        tabHandle,
        new Terminal(this, terminal, tabScope),
      );
    }
    const browser = requiredId(payload, ["browser_id"], browserId);
    return new CreatedPath(
      kind,
      workspaceHandle,
      screenHandle,
      paneHandle,
      tabHandle,
      undefined,
      new Browser(this, browser, tabScope),
    );
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
      await this.client.read(operations.sessionList, scope, options),
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
    return this.client.mutate(
      operations.sessionOpen,
      { ...scope, session: encodeSelector(selector) },
      options,
      sessionSnapshot,
      (snapshot) => new Session(this.client, selectId(snapshot.id), scope, snapshot),
    );
  }

  rename(
    name: string,
    options: MutationOptions & { readonly confirmClose?: boolean } = {},
  ): Promise<MutationResult<Machine>> {
    return this.client.mutate(
      operations.machineRename,
      {
        ...this.params(),
        name,
        confirm_close: options.confirmClose ?? false,
      },
      options,
      machineSnapshot,
      (snapshot) => new Machine(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }

  delete(options: MutationOptions = {}): Promise<MutationResult<Machine>> {
    return this.client.mutate(
      operations.machineDelete,
      this.params(),
      options,
      machineSnapshot,
      (snapshot) => new Machine(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }

  restore(options: MutationOptions = {}): Promise<MutationResult<Machine>> {
    return this.client.mutate(
      operations.machineRestore,
      this.params(),
      options,
      machineSnapshot,
      (snapshot) => new Machine(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }

  purge(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.machinePurge, this.params(), options);
  }

}

export class Session extends Handle<SessionId, SessionSnapshot> {
  protected readonly selectorKey = "session";
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
      await this.client.read(operations.sessionSnapshot, this.params(), options),
    );
  }

  async ping(options: RequestOptions = {}): Promise<Document> {
    return document(await this.client.read(operations.sessionPing, this.params(), options));
  }

  events(options: SessionEventsOptions = {}): Promise<ResourceStream<SessionEvent>> {
    return this.client.stream(
      operations.sessionEvents,
      { ...this.params(), ...optionFields(options) },
      sessionEvent,
      options.signal,
    );
  }

  shutdown(
    force = false,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.sessionShutdown,
      { ...this.params(), force },
      options,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.shutdown(false, options);
  }

  reloadConfig(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.sessionReloadConfig, this.params(), options);
  }

  updateTerminalDefaults(
    value: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.sessionTerminalDefaultsUpdate,
      { ...this.params(), ...value },
      options,
    );
  }

  setWindowTitle(title: string, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.sessionWindowTitleSet,
      { ...this.params(), title },
      options,
    );
  }

  clearWindowTitle(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.sessionWindowTitleClear,
      this.params(),
      options,
    );
  }

  async listWorkspaces(options: RequestOptions = {}): Promise<Workspace[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(operations.workspaceList, scope, options),
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
    return this.client.created(operations.workspaceCreate, params, options);
  }

  async listConnectedClients(options: RequestOptions = {}): Promise<ConnectedClient[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(operations.clientList, scope, options),
      "clients",
    ).map((value) => {
      const snapshot = connectedClientSnapshot(value);
      return new ConnectedClient(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listTerminals(options: RequestOptions = {}): Promise<Terminal[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(operations.terminalList, scope, options),
      "terminals",
    ).map((value) => {
      const snapshot = terminalSnapshot(value);
      return new Terminal(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listBrowsers(options: RequestOptions = {}): Promise<Browser[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(operations.browserList, scope, options),
      "browsers",
    ).map((value) => {
      const snapshot = browserSnapshot(value);
      return new Browser(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async listPairingRequests(options: RequestOptions = {}): Promise<PairingRequest[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(operations.pairingRequestList, scope, options),
      "pairing_requests",
    ).map((value) => {
      const snapshot = auxiliarySnapshot<PairingRequestId, PairingRequestSnapshot>(
        value,
        "pairing_request",
        pairingRequestId,
        { key: "session", property: "sessionId", factory: sessionId },
      );
      return new PairingRequest(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  async projection(
    selector: SelectorInput<ProjectionId> = selectCurrent<ProjectionId>(),
    options: RequestOptions = {},
  ): Promise<FrontendProjection> {
    const scope = this.nestedScope();
    const snapshot = auxiliarySnapshot<ProjectionId, FrontendProjectionSnapshot>(
      await this.client.read(
        operations.frontendProjectionGet,
        { ...scope, frontend_projection: encodeSelector(selector) },
        options,
      ),
      "frontend_projection",
      projectionId,
      { key: "session", property: "sessionId", factory: sessionId },
    );
    return new FrontendProjection(this.client, selectId(snapshot.id), scope, snapshot);
  }

  async listNotifications(
    options: RequestOptions & { readonly limit?: number } = {},
  ): Promise<Notification[]> {
    const scope = this.nestedScope();
    return listPayload(
      await this.client.read(
        operations.notificationList,
        { ...scope, ...optionFields(options) },
        options,
      ),
      "notifications",
    ).map((value) => {
      const snapshot = auxiliarySnapshot<NotificationId, NotificationSnapshot>(
        value,
        "notification",
        notificationId,
        { key: "session", property: "sessionId", factory: sessionId },
      );
      return new Notification(this.client, selectId(snapshot.id), scope, snapshot);
    });
  }

  createNotification(
    create: NotificationOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Notification>> {
    const scope = this.nestedScope();
    return this.client.mutate(
      operations.notificationCreate,
      { ...scope, ...optionFields(create) },
      options,
      (value) => auxiliarySnapshot<NotificationId, NotificationSnapshot>(
        value,
        "notification",
        notificationId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
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
      await this.client.read(
        operations.agentList,
        { ...scope, ...optionFields(options) },
        options,
      ),
      "agents",
    ).map((value) => {
      const snapshot = auxiliarySnapshot<AgentId, AgentSnapshot>(
        value,
        "agent",
        agentId,
        { key: "session", property: "sessionId", factory: sessionId },
      );
      return new Agent(this.client, selectId(snapshot.id), scope, snapshot);
    });
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
      await this.client.read(operations.screenList, scope, options),
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
  ): Promise<MutationResult<CreatedPath>> {
    const scope = this.nestedScope();
    return this.client.created(
      operations.screenCreate,
      { ...scope, ...optionFields(create) },
      options,
    );
  }

  rename(name: string, options: MutationOptions = {}): Promise<MutationResult<Workspace>> {
    return this.client.mutate(
      operations.workspaceRename,
      { ...this.params(), name },
      options,
      workspaceSnapshot,
      (snapshot) => new Workspace(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  move(
    index: number,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.client.mutate(
      operations.workspaceMove,
      {
        ...this.params(),
        index,
      },
      options,
      workspaceSnapshot,
      (snapshot) => new Workspace(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Workspace>> {
    return this.client.mutate(
      operations.workspaceFocus,
      this.params(),
      options,
      workspaceSnapshot,
      (snapshot) => new Workspace(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.workspaceClose, this.params(), options);
  }

  run(run: RunOptions, options: MutationOptions = {}): Promise<MutationResult<CreatedPath>> {
    return this.client.created(
      operations.workspaceRun,
      { ...this.params(), ...optionFields(run) },
      options,
    );
  }

  applyLayout(
    apply: LayoutApplyOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.client.mutate(
      operations.workspaceLayoutApply,
      { ...this.params(), ...optionFields(apply) },
      options,
      workspaceSnapshot,
      (snapshot) => new Workspace(
        this.client,
        selectId(snapshot.id),
        this.scope,
        snapshot,
      ),
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
      await this.client.read(operations.paneList, scope, options),
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
  ): Promise<MutationResult<CreatedPath>> {
    const scope = this.nestedScope();
    return this.client.created(
      operations.paneCreate,
      { ...scope, ...optionFields(create) },
      options,
    );
  }

  rename(name: string | null, options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.client.mutate(
      operations.screenRename,
      { ...this.params(), name },
      options,
      screenSnapshot,
      (snapshot) => new Screen(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  clearName(options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.rename(null, options);
  }

  focus(options: MutationOptions = {}): Promise<MutationResult<Screen>> {
    return this.client.mutate(
      operations.screenFocus,
      this.params(),
      options,
      screenSnapshot,
      (snapshot) => new Screen(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.screenClose, this.params(), options);
  }

  async exportLayout(options: RequestOptions = {}): Promise<LayoutDocument> {
    return layoutDocument(
      await this.client.read(operations.screenLayoutExport, this.params(), options),
    );
  }

  undoLayout(
    options: MutationOptions & { readonly confirmClose?: boolean } = {},
  ): Promise<MutationResult<Screen>> {
    return this.client.mutate(
      operations.screenLayoutUndo,
      { ...this.params(), confirm_close: options.confirmClose ?? false },
      options,
      screenSnapshot,
      (snapshot) => new Screen(
        this.client,
        selectId(snapshot.id),
        this.scope,
        snapshot,
      ),
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
      await this.client.read(operations.tabList, scope, options),
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
  ): Promise<MutationResult<CreatedPath>> {
    return this.client.created(
      operations.tabCreateTerminal,
      { ...this.params(), ...optionFields(create) },
      options,
    );
  }

  createBrowserTab(
    create: CreateBrowserOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedPath>> {
    return this.client.created(
      operations.tabCreateBrowser,
      { ...this.params(), ...optionFields(create) },
      options,
    );
  }

  split(
    create: SplitPaneOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<CreatedPath>> {
    return this.client.created(
      operations.paneSplit,
      { ...this.params(), ...optionFields(create) },
      options,
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
      await this.client.read(
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

  run(run: RunOptions, options: MutationOptions = {}): Promise<MutationResult<CreatedPath>> {
    return this.client.created(
      operations.paneRun,
      { ...this.params(), ...optionFields(run) },
      options,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.paneClose, this.params(), options);
  }

  private paneMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Pane>> {
    return this.client.mutate(
      operation,
      { ...this.params(), ...params },
      options,
      paneSnapshot,
      (snapshot) => new Pane(this.client, selectId(snapshot.id), this.scope, snapshot),
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

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.tabClose, this.params(), options);
  }

  private tabMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Tab>> {
    return this.client.mutate(
      operation,
      { ...this.params(), ...params },
      options,
      tabSnapshot,
      (snapshot) => new Tab(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }
}

export class Terminal extends Handle<TerminalId, TerminalSnapshot> {
  protected readonly selectorKey = "terminal";
  refresh(options: RequestOptions = {}): Promise<TerminalSnapshot> {
    return this.refreshWith(operations.terminalGet, terminalSnapshot, options);
  }

  write(text: string, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.terminalInputWrite,
      { ...this.params(), text },
      options,
    );
  }

  writeBase64(
    bytesBase64: string,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.terminalInputWrite,
      { ...this.params(), bytes_base64: bytesBase64 },
      options,
    );
  }

  keys(input: KeyInputOptions, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.terminalInputKeys,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  mouse(input: TerminalMouseOptions, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.terminalInputMouse,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  setFocused(focused: boolean, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.terminalInputFocus,
      { ...this.params(), focused },
      options,
    );
  }

  async readScreen(options: RequestOptions = {}): Promise<Document> {
    return document(
      await this.client.read(
        operations.terminalScreenRead,
        this.params(),
        options,
      ),
    );
  }

  async readState(options: RequestOptions = {}): Promise<Document> {
    return document(await this.client.read(operations.terminalStateRead, this.params(), options));
  }

  async readHistory(
    history: TerminalHistoryOptions = {},
    options: RequestOptions = {},
  ): Promise<Document> {
    return document(
      await this.client.read(
        operations.terminalHistoryRead,
        { ...this.params(), ...optionFields(history) },
        options,
      ),
    );
  }

  clearHistory(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.terminalHistoryClear, this.params(), options);
  }

  async wait(wait: TerminalWaitOptions): Promise<Document> {
    return document(
      await this.client.read(
        operations.terminalWait,
        { ...this.params(), ...optionFields(wait) },
        wait,
      ),
    );
  }

  async copy(mode?: string, options: RequestOptions = {}): Promise<Document> {
    return document(
      await this.client.read(
        operations.terminalCopy,
        { ...this.params(), ...(mode !== undefined ? { mode } : {}) },
        options,
      ),
    );
  }

  async process(options: RequestOptions = {}): Promise<Document> {
    return document(await this.client.read(operations.terminalProcessGet, this.params(), options));
  }

  async createRendererGrant(
    ttlMs?: number,
    options: RequestOptions = {},
  ): Promise<RendererGrant> {
    const result = await this.client.control(
      operations.terminalRendererGrantCreate,
      {
        ...this.params(),
        ...(ttlMs !== undefined ? { ttl_ms: ttlMs } : {}),
      },
      options,
    );
    if (typeof result.token !== "string") {
      throw new CmuxProtocolError("renderer grant result omitted token");
    }
    if (
      typeof result.endpoint !== "string"
      || typeof result.terminal_id !== "string"
      || !Array.isArray(result.rights)
      || !result.rights.every((right) => typeof right === "string")
      || typeof result.ttl_ms !== "number"
    ) {
      throw new CmuxProtocolError("renderer grant result has invalid metadata");
    }
    return new RendererGrant(
      result.token,
      result.endpoint,
      terminalId(result.terminal_id),
      Object.freeze([...result.rights]),
      result.ttl_ms,
    );
  }

  resizeViewer(size: ViewerSizeOptions, options: RequestOptions = {}): Promise<Document> {
    return this.client.control(
      operations.terminalViewerResize,
      { ...this.params(), ...optionFields(size) },
      options,
    );
  }

  releaseViewer(options: RequestOptions = {}): Promise<Document> {
    return this.client.control(operations.terminalViewerRelease, this.params(), options);
  }

  scrollViewport(deltaRows: number, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
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
    return this.client.mutate(
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
      (snapshot) => new Terminal(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }

  attach(
    options: TerminalAttachOptions = {},
  ): Promise<ResourceStream<TerminalAttachItem>> {
    return this.client.stream(
      operations.terminalAttach,
      { ...this.params(), ...optionFields(options) },
      terminalAttachItem,
      options.signal,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.terminalClose, this.params(), options);
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
    input: { kind?: "down" | "up" | "press"; modifiers?: readonly string[] } = {},
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.browserInputKey,
      { ...this.params(), key, ...input },
      options,
    );
  }

  text(text: string, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.browserInputText,
      { ...this.params(), text },
      options,
    );
  }

  mouse(input: BrowserMouseOptions, options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.browserInputMouse,
      { ...this.params(), ...optionFields(input) },
      options,
    );
  }

  wheel(
    deltaX: number,
    deltaY: number,
    position: { xPx: number; yPx: number },
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.browserInputWheel,
      {
        ...this.params(),
        delta_x: deltaX,
        delta_y: deltaY,
        ...optionFields(position),
      },
      options,
    );
  }

  resizeViewer(size: BrowserViewerSizeOptions, options: RequestOptions = {}): Promise<Document> {
    return this.client.control(
      operations.browserViewerResize,
      { ...this.params(), ...optionFields(size) },
      options,
    );
  }

  releaseViewer(options: RequestOptions = {}): Promise<Document> {
    return this.client.control(operations.browserViewerRelease, this.params(), options);
  }

  attach(options: BrowserAttachOptions = {}): Promise<ResourceStream<BrowserAttachItem>> {
    return this.client.stream(
      operations.browserAttach,
      { ...this.params(), ...optionFields(options) },
      browserAttachItem,
      options.signal,
    );
  }

  close(options: MutationOptions = {}): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(operations.browserClose, this.params(), options);
  }

  private browserMutation(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Browser>> {
    return this.client.mutate(
      operation,
      { ...this.params(), ...params },
      options,
      browserSnapshot,
      (snapshot) => new Browser(this.client, selectId(snapshot.id), this.scope, snapshot),
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

  setCellPixels(widthPx: number, heightPx: number, options: RequestOptions = {}): Promise<Document> {
    return this.client.control(
      operations.clientCellPixelsSet,
      { ...this.params(), width_px: widthPx, height_px: heightPx },
      options,
    );
  }

  detach(options: RequestOptions = {}): Promise<Document> {
    return this.client.control(operations.clientDetach, this.params(), options);
  }

  private async clientControl(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions,
  ): Promise<ClientSnapshot> {
    const snapshot = connectedClientSnapshot(
      await this.client.read(operation, params, options),
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
    return this.client.mutate(
      operations.pairingRequestResolve,
      { ...this.params(), decision },
      options,
      pairingResolution,
      (snapshot) => new PairingRequest(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }
}

export class FrontendProjection extends Handle<ProjectionId, FrontendProjectionSnapshot> {
  protected readonly selectorKey = "frontend_projection";
  put(
    projection: Readonly<Record<string, unknown>>,
    options: MutationOptions = {},
  ): Promise<MutationResult<FrontendProjection>> {
    return this.client.mutate(
      operations.frontendProjectionPut,
      { ...this.params(), projection },
      options,
      (result) => auxiliarySnapshot<ProjectionId, FrontendProjectionSnapshot>(
        result,
        "frontend_projection",
        projectionId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
      (snapshot) =>
        new FrontendProjection(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }
}

export class Notification extends Handle<NotificationId, NotificationSnapshot> {
  protected readonly selectorKey = "notification";
}

export class Agent extends Handle<AgentId, AgentSnapshot> {
  protected readonly selectorKey = "agent";
  report(
    report: AgentReportOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Agent>> {
    return this.client.mutate(
      operations.agentReport,
      { ...this.scope, ...optionFields(report) },
      options,
      (value) => auxiliarySnapshot<AgentId, AgentSnapshot>(
        value,
        "agent",
        agentId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
      (snapshot) => new Agent(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }
}

export class SidebarView extends Handle<SidebarViewId, SidebarViewSnapshot> {
  protected readonly selectorKey = "sidebar_view";
  refresh(options: RequestOptions = {}): Promise<SidebarViewSnapshot> {
    return this.refreshWith(
      operations.sidebarViewGet,
      (value) => auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        value,
        "sidebar_view",
        sidebarViewId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
      options,
    );
  }

  ensure(
    ensure: SidebarEnsureOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<SidebarView>> {
    return this.client.mutate(
      operations.sidebarViewEnsure,
      { ...this.scope, ...optionFields(ensure) },
      options,
      (value) => auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        value,
        "sidebar_view",
        sidebarViewId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
      (snapshot) => new SidebarView(
        this.client,
        selectId(snapshot.id),
        this.scope,
        snapshot,
      ),
    );
  }

  attach(options: { signal?: AbortSignal } = {}): Promise<ResourceStream<SidebarAttachItem>> {
    return this.client.stream(
      operations.sidebarViewAttach,
      this.params(),
      sidebarAttachItem,
      options.signal,
    );
  }

  input(
    input: SidebarInputOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
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
    return this.client.mutate(
      operation,
      { ...this.params(), ...params },
      options,
      (value) => auxiliarySnapshot<SidebarViewId, SidebarViewSnapshot>(
        value,
        "sidebar_view",
        sidebarViewId,
        { key: "session", property: "sessionId", factory: sessionId },
      ),
      (snapshot) => new SidebarView(this.client, selectId(snapshot.id), this.scope, snapshot),
    );
  }
}

export class ProviderScope extends Handle<ProviderScopeId, ProviderScopeSnapshot> {
  protected readonly selectorKey = "provider_scope";

  createMachine(options: MutationOptions = {}): Promise<MutationResult<Machine>> {
    return this.client.mutate(
      operations.machineCreate,
      { provider_scope: encodeSelector(this.selector) },
      options,
      machineSnapshot,
      (snapshot) => new Machine(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }

  connectExternalMachine(
    specifier: ExternalMachineSpecifier,
    options: MutationOptions = {},
  ): Promise<MutationResult<Machine>> {
    return this.client.mutate(
      operations.machineConnectExternal,
      {
        provider_scope: encodeSelector(this.selector),
        specifier: specifier.take(),
      },
      options,
      machineSnapshot,
      (snapshot) => new Machine(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }

  action(selector: SelectorInput<ProviderActionId>): ProviderAction {
    return new ProviderAction(this.client, selector, {
      ...this.scope,
      provider_scope: encodeSelector(this.selector),
    });
  }

  notice(selector: SelectorInput<ProviderNoticeId>): ProviderNotice {
    return new ProviderNotice(this.client, selector, {
      ...this.scope,
      provider_scope: encodeSelector(this.selector),
    });
  }

  invoke(
    action: SelectorInput<ProviderActionId>,
    input: ProviderActionOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<unknown>> {
    return this.action(action).invoke(input, options);
  }

  notices(
    options: { cursor?: Cursor; signal?: AbortSignal } = {},
  ): Promise<ResourceStream<ProviderNoticeItem>> {
    return this.client.stream(
      operations.providerNoticeEvents,
      {
        ...this.scope,
        provider_scope: encodeSelector(this.selector),
        ...(options.cursor !== undefined ? { cursor: options.cursor } : {}),
      },
      providerNoticeItem,
      options.signal,
    );
  }

  markWorkspace(
    workspace: SelectorInput<WorkspaceId>,
    managed: boolean,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.providerWorkspaceMutation(
      operations.providerWorkspaceMark,
      workspace,
      { managed },
      options,
    );
  }

  renameWorkspace(
    workspace: SelectorInput<WorkspaceId>,
    name: string,
    options: MutationOptions = {},
  ): Promise<MutationResult<Workspace>> {
    return this.providerWorkspaceMutation(
      operations.providerWorkspaceRename,
      workspace,
      { name },
      options,
    );
  }

  closeWorkspace(
    workspace: SelectorInput<WorkspaceId>,
    options: MutationOptions = {},
  ): Promise<MutationResult<Document>> {
    return this.client.mutateDocument(
      operations.providerWorkspaceClose,
      {
        ...this.scope,
        provider_scope: encodeSelector(this.selector),
        session: "current",
        workspace: encodeSelector(workspace),
      },
      options,
    );
  }

  private providerWorkspaceMutation(
    operation: Operation,
    workspace: SelectorInput<WorkspaceId>,
    params: Readonly<Record<string, unknown>>,
    options: MutationOptions,
  ): Promise<MutationResult<Workspace>> {
    return this.client.mutate(
      operation,
      {
        ...this.scope,
        provider_scope: encodeSelector(this.selector),
        session: "current",
        workspace: encodeSelector(workspace),
        ...params,
      },
      options,
      workspaceSnapshot,
      (snapshot) => new Workspace(this.client, selectId(snapshot.id), {}, snapshot),
    );
  }
}

export class ProviderAction extends Handle<ProviderActionId, ProviderActionSnapshot> {
  protected readonly selectorKey = "provider_action";
  invoke(
    input: ProviderActionOptions,
    options: MutationOptions = {},
  ): Promise<MutationResult<unknown>> {
    for (const value of Object.values(input.parameters)) {
      if (
        typeof value !== "string"
        && (
          typeof value !== "number"
          || !Number.isInteger(value)
          || value < -0x8000_0000
          || value > 0x7fff_ffff
        )
      ) {
        throw new TypeError(
          "provider action values must be strings or int32 values",
        );
      }
    }
    return this.client.mutate(
      operations.providerActionInvoke,
      { ...this.params(), ...optionFields(input) },
      options,
      (value) => value,
      (value) => value,
    );
  }
}

export class ProviderNotice extends Handle<ProviderNoticeId, ProviderNoticeSnapshot> {
  protected readonly selectorKey = "provider_notice";

  acknowledge(
    sequence: DecimalString,
    options: RequestOptions = {},
  ): Promise<Document> {
    return this.client.control(
      operations.providerNoticeAcknowledge,
      { ...this.params(), sequence },
      options,
    );
  }
}

export { ResourceStream };
