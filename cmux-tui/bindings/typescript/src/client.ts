import { decodeBase64, encodeBase64 } from "./base64.js";
import {
  CmuxCommandError,
  CmuxConnectionError,
  CmuxError,
  CmuxProtocolError,
  CmuxTimeoutError,
} from "./errors.js";
import type {
  ApplyLayoutResult,
  AttachEvent,
  CmuxCommand,
  CmuxRequest,
  CmuxRequestParams,
  CmuxResponse,
  CmuxResponseData,
  CmuxResponseDataFor,
  ColorHex,
  CopyMode,
  CopyResult,
  DecodedAttachEvent,
  EmptyResult,
  ExportLayoutResult,
  Id,
  IdKind,
  IdRef,
  IdsResult,
  IdentifyResult,
  Json,
  JsonObject,
  ListAgentsResult,
  ListClientsResult,
  NotificationLevel,
  NotifyResult,
  PaneDirection,
  PaneNeighborResult,
  PingResult,
  ProcessInfoResult,
  ReadScrollbackResult,
  ReadScreenResult,
  ReloadConfigResult,
  ResizeSurfaceResult,
  ReportAgentResult,
  RunResult,
  RenderAttachEvent,
  SidebarPluginResult,
  SplitDirection,
  SubscribeEvent,
  SurfaceResult,
  TerminalPlacement,
  Tree,
  WorkspacePlacement,
  WorkspaceMutation,
  UnknownEvent,
  VtStateResult,
  WaitForResult,
  ZoomPaneResult,
  AgentReportSource,
  AgentState,
  DeclarativeLayout,
  FocusDirectionResult,
} from "./protocol/index.js";
import type { Transport, Unsubscribe } from "./transport.js";

export interface CmuxClientOptions {
  transport: Transport;
  timeoutMs?: number;
  allowProtocolV6Attach?: boolean;
  /** Maximum events retained for a stream whose consumer falls behind. */
  maxBufferedEvents?: number;
  /** Maximum encoded characters per attach payload and retained bytes across buffered attach events. */
  maxAttachEncodedChars?: number;
  /** Creates dedicated subscribe/attach transports when supplied. */
  streamTransportFactory?: () => Transport;
}

export const DEFAULT_MAX_BUFFERED_EVENTS = 256;
export const DEFAULT_MAX_ATTACH_ENCODED_CHARS = 16 * 1024 * 1024;

function workspaceMutationResult(result: EmptyResult | WorkspaceMutation): WorkspaceMutation {
  if ("workspace" in result
    && "key" in result
    && "workspace_revision" in result
    && typeof result.workspace === "number"
    && typeof result.key === "string"
    && typeof result.workspace_revision === "number") {
    return {
      workspace: result.workspace,
      key: result.key,
      workspace_revision: result.workspace_revision,
    };
  }
  throw new CmuxProtocolError("server returned an invalid workspace registry mutation");
}

export type NewTabOptions = CmuxRequestParams<"new-tab">;
export type NewBrowserTabOptions = Omit<CmuxRequestParams<"new-browser-tab">, "url">;
export type NewWorkspaceOptions = CmuxRequestParams<"new-workspace">;
export type CreateWorkspaceOptions = CmuxRequestParams<"create-workspace">;
export type CreateTerminalOptions = CmuxRequestParams<"create-terminal">;
export type CloseWorkspaceOptions = CmuxRequestParams<"close-workspace">;
export type RenameWorkspaceOptions = CmuxRequestParams<"rename-workspace">;
export type MoveWorkspaceOptions = CmuxRequestParams<"move-workspace">;
export type NewScreenOptions = CmuxRequestParams<"new-screen">;
export type NewPaneOptions = Omit<CmuxRequestParams<"new-pane">, "pane">;
export type SplitOptions = Omit<CmuxRequestParams<"split">, "pane" | "dir">;
export type SelectOptions = CmuxRequestParams<"select-screen">;
export type SelectTabOptions = CmuxRequestParams<"select-tab">;
export interface SendOptions {
  text?: string | null;
  /** Standard base64-encoded raw bytes sent in the wire `bytes` field. */
  base64?: string | null;
  /** @deprecated Use `base64`, or pass text for UTF-8 input. */
  bytes?: string | Uint8Array | null;
  /** Request bracketed-paste wrapping when terminal mode 2004 is enabled. */
  paste?: boolean;
}
export interface SubscribeOptions { treeEvents?: "coarse" | "deltas" }
export type AttachSurfaceOptions = { mode?: "bytes" | "render" } & (
  | { cols: number; rows: number }
  | { cols?: never; rows?: never }
);

interface PendingResponse {
  resolve: (response: CmuxResponse<unknown>) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

class MessageRouter {
  private readonly pending = new Map<string, PendingResponse>();
  private readonly eventHandlers = new Set<(event: UnknownEvent) => void>();
  private readonly terminalHandlers = new Set<(error: Error) => void>();
  private terminalError: Error | null = null;

  constructor(readonly transport: Transport) {
    transport.onMessage((json) => this.receive(json));
    transport.onError((error) => this.terminate(this.connectionError(error)));
    transport.onClose(() => this.terminate(new CmuxConnectionError("session transport closed")));
  }

  send(request: JsonObject, timeoutMs: number): Promise<CmuxResponse<unknown>> {
    const key = this.idKey(request.id);
    if (this.terminalError) return Promise.reject(this.terminalError);
    if (this.pending.has(key)) return Promise.reject(new CmuxProtocolError(`duplicate request id ${key}`));

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new CmuxTimeoutError("session did not respond"));
      }, timeoutMs);
      this.pending.set(key, { resolve, reject, timer });
      try {
        this.transport.send(JSON.stringify(request));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(key);
        reject(this.connectionError(error));
      }
    });
  }

  onEvent(handler: (event: UnknownEvent) => void): Unsubscribe {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onTerminal(handler: (error: Error) => void): Unsubscribe {
    this.terminalHandlers.add(handler);
    if (this.terminalError) queueMicrotask(() => handler(this.terminalError!));
    return () => this.terminalHandlers.delete(handler);
  }

  private receive(json: string): void {
    let value: unknown;
    try {
      value = JSON.parse(json);
    } catch (error) {
      this.terminate(new CmuxProtocolError(`bad JSON from server: ${(error as Error).message}`));
      return;
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      this.terminate(new CmuxProtocolError("server sent non-object JSON message"));
      return;
    }

    const object = value as Record<string, unknown>;
    if (typeof object.event === "string") {
      for (const handler of this.eventHandlers) handler(object as UnknownEvent);
      return;
    }

    const key = object.id === undefined ? this.pending.keys().next().value : this.idKey(object.id as Json);
    if (key === undefined) return;
    const pending = this.pending.get(key);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(key);
    pending.resolve(object as unknown as CmuxResponse<unknown>);
  }

  private terminate(error: Error): void {
    if (this.terminalError) return;
    this.terminalError = error;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    for (const handler of this.terminalHandlers) handler(error);
  }

  private idKey(id: Json | undefined): string {
    return id === undefined ? "undefined" : JSON.stringify(id);
  }

  private connectionError(error: unknown): Error {
    if (error instanceof CmuxError) return error;
    return new CmuxConnectionError(error instanceof Error ? error.message : String(error));
  }
}

interface StreamWaiter<T> {
  active: boolean;
  resolve: (event: T) => void;
  reject: (error: Error) => void;
}

/** A closeable async event stream with optional per-read timeouts. */
export class CmuxStream<T extends { event: string }> implements AsyncIterable<T> {
  private readonly buffered: T[] = [];
  private bufferedBytes = 0;
  private readonly waiters: StreamWaiter<T>[] = [];
  private closed = false;
  private endsAfterDrain = false;
  private terminalError: Error | null = null;

  constructor(
    private readonly timeoutMs: number,
    private readonly cleanup: () => void,
    private readonly maxBufferedEvents = DEFAULT_MAX_BUFFERED_EVENTS,
    private readonly maxBufferedBytes = Number.POSITIVE_INFINITY,
    private readonly retainedBytes: (event: T) => number = () => 0,
  ) {}

  async next(timeoutMs = this.timeoutMs): Promise<T> {
    if (this.buffered.length > 0) {
      const event = this.buffered.shift()!;
      this.bufferedBytes = Math.max(0, this.bufferedBytes - this.retainedBytes(event));
      if (this.endsAfterDrain && this.buffered.length === 0) this.finish();
      return event;
    }
    if (this.terminalError) throw this.terminalError;
    if (this.closed) throw new CmuxConnectionError("stream is closed");

    const waiter: StreamWaiter<T> = {
      active: true,
      resolve: () => undefined,
      reject: () => undefined,
    };
    const event = await new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter.active = false;
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new CmuxTimeoutError("stream did not produce an event"));
      }, timeoutMs);
      waiter.resolve = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
      waiter.reject = (error) => {
        clearTimeout(timer);
        reject(error);
      };
      this.waiters.push(waiter);
    });
    if (this.endsAfterDrain && this.buffered.length === 0) this.finish();
    return event;
  }

  close(): void {
    if (this.closed) return;
    this.buffered.length = 0;
    this.bufferedBytes = 0;
    this.finish();
    this.rejectWaiters(new CmuxConnectionError("stream is closed"));
  }

  push(event: T, terminal = false): void {
    if (this.closed) return;
    let delivered = false;
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      if (!waiter.active) continue;
      waiter.resolve(event);
      delivered = true;
      break;
    }
    if (!delivered) {
      if (this.buffered.length >= this.maxBufferedEvents) {
        this.fail(new CmuxProtocolError("stream event buffer overflow"));
        return;
      }
      const retainedBytes = this.retainedBytes(event);
      if (retainedBytes > this.maxBufferedBytes - this.bufferedBytes) {
        this.fail(
          new CmuxProtocolError(
            `stream buffered data exceeds ${this.maxBufferedBytes} bytes`,
          ),
        );
        return;
      }
      this.buffered.push(event);
      this.bufferedBytes += retainedBytes;
    }
    if (terminal) this.endsAfterDrain = true;
  }

  fail(error: Error): void {
    if (this.closed) return;
    this.terminalError = error;
    this.buffered.length = 0;
    this.bufferedBytes = 0;
    this.finish();
    this.rejectWaiters(error);
  }

  get error(): Error | null {
    return this.terminalError;
  }

  async *[Symbol.asyncIterator](): AsyncIterator<T> {
    try {
      while (true) {
        if (this.terminalError) throw this.terminalError;
        if (this.closed) return;
        yield await this.next();
      }
    } finally {
      this.close();
    }
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    this.cleanup();
  }

  private rejectWaiters(error: Error): void {
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      if (waiter.active) waiter.reject(error);
    }
  }
}

/** Promise-based typed client for any cmux JSON transport. */
export class CmuxClient {
  readonly timeoutMs: number;
  readonly allowProtocolV6Attach: boolean;
  readonly maxBufferedEvents: number;
  readonly maxAttachEncodedChars: number;
  private readonly transport: Transport;
  private readonly router: MessageRouter;
  private readonly streamTransportFactory?: () => Transport;
  private nextRequestId = 1;
  private identifiedProtocol: number | null = null;
  private identifiedCapabilities = new Set<string>();
  private sharedSubscriptionActive = false;

  constructor(options: CmuxClientOptions) {
    this.transport = options.transport;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.allowProtocolV6Attach = options.allowProtocolV6Attach ?? true;
    this.maxBufferedEvents = this.securityLimit(
      "maxBufferedEvents",
      options.maxBufferedEvents,
      DEFAULT_MAX_BUFFERED_EVENTS,
    );
    this.maxAttachEncodedChars = this.securityLimit(
      "maxAttachEncodedChars",
      options.maxAttachEncodedChars,
      DEFAULT_MAX_ATTACH_ENCODED_CHARS,
    );
    this.streamTransportFactory = options.streamTransportFactory;
    this.router = new MessageRouter(this.transport);
  }

  async close(): Promise<void> {
    this.transport.close();
  }

  async sendRaw(obj: JsonObject): Promise<CmuxResponse<unknown>> {
    const payload = this.dropUndefined({ ...obj });
    if (!("id" in payload)) payload.id = this.nextId();
    return this.router.send(payload, this.timeoutMs);
  }

  request<C extends CmuxRequest>(request: C): Promise<CmuxResponseData<C>>;
  // params is only optional when the command genuinely has no required params;
  // otherwise `client.request("send")` would compile and fail server-side.
  request<C extends CmuxCommand>(
    cmd: C,
    ...args: Record<string, never> extends CmuxRequestParams<C>
      ? [params?: CmuxRequestParams<C>]
      : [params: CmuxRequestParams<C>]
  ): Promise<CmuxResponseDataFor<C>>;
  async request<C extends CmuxCommand>(
    requestOrCommand: CmuxRequest | C,
    params?: CmuxRequestParams<C>,
  ): Promise<CmuxResponseDataFor<C>> {
    const request = typeof requestOrCommand === "string"
      ? { cmd: requestOrCommand, ...(params ?? {}) }
      : requestOrCommand;
    const response = await this.sendRaw(request as unknown as JsonObject);
    if (response.ok) return response.data as CmuxResponseDataFor<C>;
    throw new CmuxCommandError(response.error || "unknown error", response.id, response);
  }

  async identify(): Promise<IdentifyResult> {
    const result = await this.request("identify");
    this.identifiedProtocol = result.protocol;
    this.identifiedCapabilities = new Set(result.capabilities ?? []);
    return result;
  }

  /** The protocol reported by the latest `identify()`, or null before identification. */
  get protocol(): number | null { return this.identifiedProtocol; }

  ping(): Promise<PingResult> { return this.request("ping"); }
  setClientInfo(name?: string, kind?: string): Promise<EmptyResult> {
    return this.request("set-client-info", { name, kind });
  }
  listClients(): Promise<ListClientsResult> { return this.request("list-clients"); }
  detachClient(client: Id): Promise<EmptyResult> { return this.request("detach-client", { client }); }
  setClientSizing(client: Id, enabled: boolean): Promise<EmptyResult> {
    return this.request("set-client-sizing", { client, enabled });
  }
  useOnlyClientSizing(client: Id): Promise<EmptyResult> {
    return this.request("set-client-sizing", { client, enabled: true, exclusive: true });
  }
  useAllClientSizing(): Promise<EmptyResult> {
    return this.request("set-client-sizing", { enabled: true });
  }
  reloadConfig(): Promise<ReloadConfigResult> { return this.request("reload-config"); }
  setWindowTitle(title: string): Promise<EmptyResult> { return this.request("set-window-title", { title }); }
  clearWindowTitle(): Promise<EmptyResult> { return this.request("clear-window-title"); }
  listWorkspaces(): Promise<Tree> { return this.request("list-workspaces"); }
  exportLayout(screen?: Id | null): Promise<ExportLayoutResult> { return this.request("export-layout", { screen }); }
  applyLayout(layout: DeclarativeLayout, options: Omit<CmuxRequestParams<"apply-layout">, "layout"> = {}): Promise<ApplyLayoutResult> {
    return this.request("apply-layout", { ...options, layout });
  }

  async send(surface: Id, options: SendOptions = {}): Promise<EmptyResult> {
    const legacyBytes = options.bytes instanceof Uint8Array ? encodeBase64(options.bytes) : options.bytes;
    const bytes = "base64" in options ? options.base64 : legacyBytes;
    return this.request("send", { surface, text: options.text, bytes, paste: options.paste });
  }

  readScreen(surface: Id): Promise<ReadScreenResult> { return this.request("read-screen", { surface }); }
  readScrollback(surface: Id, start: number, count: number): Promise<ReadScrollbackResult> {
    return this.request("read-scrollback", { surface, start, count });
  }
  sidebarPlugin(cols: number, rows: number, relaunch?: boolean | null): Promise<SidebarPluginResult> {
    return this.request("sidebar-plugin", { cols, rows, relaunch });
  }
  vtState(surface: Id): Promise<VtStateResult> { return this.request("vt-state", { surface }); }
  newTab(options: NewTabOptions = {}): Promise<SurfaceResult> { return this.request("new-tab", options); }
  newBrowserTab(url: string, options: NewBrowserTabOptions = {}): Promise<SurfaceResult> {
    return this.request("new-browser-tab", { url, ...options });
  }
  newWorkspace(options: NewWorkspaceOptions = {}): Promise<SurfaceResult> { return this.request("new-workspace", options); }
  async createWorkspace(options: CreateWorkspaceOptions = {}): Promise<WorkspacePlacement> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return this.request("create-workspace", options);
  }
  async createTerminal(options: CreateTerminalOptions): Promise<TerminalPlacement> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return this.request("create-terminal", options);
  }
  newScreen(options: NewScreenOptions = {}): Promise<SurfaceResult> { return this.request("new-screen", options); }
  async newPane(pane: Id, options: NewPaneOptions = {}): Promise<SurfaceResult> {
    await this.requireProtocol(9, "new-pane");
    return this.request("new-pane", { pane, ...options });
  }
  split(pane: Id, dir: SplitDirection, options: SplitOptions = {}): Promise<SurfaceResult> {
    return this.request("split", { pane, dir, ...options });
  }
  setRatio(pane: Id, dir: SplitDirection, ratio: number): Promise<EmptyResult> {
    return this.request("set-ratio", { pane, dir, ratio });
  }
  async setSplitRatio(split: Id, ratio: number): Promise<EmptyResult> {
    await this.requireProtocol(8, "set-split-ratio");
    return this.request("set-split-ratio", { split, ratio });
  }
  paneNeighbor(pane: Id, dir: PaneDirection): Promise<PaneNeighborResult> {
    return this.request("pane-neighbor", { pane, dir });
  }
  focusDirection(dir: PaneDirection, pane?: Id | null): Promise<FocusDirectionResult> {
    return this.request("focus-direction", { pane, dir });
  }
  swapPane(params: CmuxRequestParams<"swap-pane">): Promise<EmptyResult> { return this.request("swap-pane", params); }
  zoomPane(params: CmuxRequestParams<"zoom-pane"> = {}): Promise<ZoomPaneResult> { return this.request("zoom-pane", params); }
  processInfo(surface: Id): Promise<ProcessInfoResult> { return this.request("process-info", { surface }); }
  setDefaultColors(fg?: ColorHex | null, bg?: ColorHex | null): Promise<EmptyResult> {
    return this.request("set-default-colors", { fg, bg });
  }
  closeSurface(surface: Id): Promise<EmptyResult> { return this.request("close-surface", { surface }); }
  closePane(pane: Id): Promise<EmptyResult> { return this.request("close-pane", { pane }); }
  closeScreen(screen: Id): Promise<EmptyResult> { return this.request("close-screen", { screen }); }
  async closeWorkspace(workspace: Id): Promise<EmptyResult> {
    await this.request("close-workspace", { workspace });
    return {};
  }
  async closeWorkspaceRegistry(options: CloseWorkspaceOptions): Promise<WorkspaceMutation> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return workspaceMutationResult(await this.request("close-workspace", options));
  }
  renamePane(pane: Id, name: string): Promise<EmptyResult> { return this.request("rename-pane", { pane, name }); }
  renameSurface(surface: Id, name: string): Promise<EmptyResult> { return this.request("rename-surface", { surface, name }); }
  renameScreen(screen: Id, name: string): Promise<EmptyResult> { return this.request("rename-screen", { screen, name }); }
  async renameWorkspace(workspace: Id, name: string): Promise<EmptyResult> {
    await this.request("rename-workspace", { workspace, name });
    return {};
  }
  async renameWorkspaceRegistry(options: RenameWorkspaceOptions): Promise<WorkspaceMutation> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return workspaceMutationResult(await this.request("rename-workspace", options));
  }
  async resizeSurface(surface: Id, cols: number, rows: number): Promise<ResizeSurfaceResult> {
    const result = await this.request("resize-surface", { surface, cols, rows });
    return { ...result, accepted: result.accepted ?? true };
  }
  releaseSurfaceSize(surface: Id): Promise<EmptyResult> {
    return this.request("release-surface-size", { surface });
  }
  focusPane(pane: Id): Promise<EmptyResult> { return this.request("focus-pane", { pane }); }
  selectTab(options: SelectTabOptions = {}): Promise<EmptyResult> { return this.request("select-tab", options); }
  selectScreen(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-screen", options); }
  selectWorkspace(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-workspace", options); }
  moveTab(surface: Id, pane: Id, index: number): Promise<EmptyResult> { return this.request("move-tab", { surface, pane, index }); }
  async moveWorkspace(workspace: Id, index: number): Promise<EmptyResult> {
    await this.request("move-workspace", { workspace, index });
    return {};
  }
  async moveWorkspaceRegistry(options: MoveWorkspaceOptions): Promise<WorkspaceMutation> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return workspaceMutationResult(await this.request("move-workspace", options));
  }
  scrollSurface(surface: Id, delta: number): Promise<EmptyResult> { return this.request("scroll-surface", { surface, delta }); }

  async subscribe(options: SubscribeOptions = {}): Promise<CmuxStream<SubscribeEvent>> {
    return this.openStream(
      { cmd: "subscribe", tree_events: options.treeEvents },
      (event) => event as SubscribeEvent,
      (event, dedicated) => dedicated
        || (!this.attachOnlyEvent(event.event) && !this.isSurfaceOverflow(event)),
      (event) => event.event === "overflow" && !this.isSurfaceOverflow(event),
      true,
    );
  }

  attachSurface(surface: Id, options?: AttachSurfaceOptions & { mode?: "bytes" }): Promise<CmuxStream<DecodedAttachEvent>>;
  attachSurface(surface: Id, options: AttachSurfaceOptions & { mode: "render" }): Promise<CmuxStream<RenderAttachEvent>>;
  attachSurface(
    surface: Id,
    options: AttachSurfaceOptions,
  ): Promise<CmuxStream<DecodedAttachEvent> | CmuxStream<RenderAttachEvent>>;
  async attachSurface(
    surface: Id,
    options: AttachSurfaceOptions = {},
  ): Promise<CmuxStream<DecodedAttachEvent> | CmuxStream<RenderAttachEvent>> {
    if ((options.cols === undefined) !== (options.rows === undefined)) {
      throw new CmuxProtocolError("attach-surface cols and rows must be supplied together");
    }
    const mode = options.mode ?? "bytes";
    const protocol = this.identifiedProtocol ?? (await this.identify()).protocol;
    if (mode === "render" && protocol < 7) {
      throw new CmuxProtocolError(
        `render attach requires protocol 7 or newer; server reported protocol ${protocol}`,
      );
    }
    if (mode === "bytes" && protocol > 5 && !this.allowProtocolV6Attach) {
      throw new CmuxProtocolError(`byte attach for protocol ${protocol} is disabled`);
    }
    if ((options.cols !== undefined || options.rows !== undefined)
      && !this.identifiedCapabilities.has("attach-initial-size")) {
      throw new CmuxProtocolError("initial attach sizing is not supported by this server");
    }
    const request: CmuxRequest = {
      cmd: "attach-surface",
      surface,
      ...(options.mode === undefined ? {} : { mode }),
      ...(options.cols === undefined ? {} : { cols: options.cols }),
      ...(options.rows === undefined ? {} : { rows: options.rows }),
    };
    if (mode === "render") {
      return this.openStream(
        request,
        (event) => event as RenderAttachEvent,
        (event, dedicated) => dedicated || this.matchesAttachEvent(event, surface, mode),
        (event) => event.event === "detached" || this.isSurfaceOverflow(event, surface),
      );
    }
    return this.openStream(
      request,
      (event) => this.decodeAttachEvent(event as AttachEvent),
      (event, dedicated) => dedicated || this.matchesAttachEvent(event, surface, mode),
      (event) => event.event === "detached" || this.isSurfaceOverflow(event, surface),
      false,
      {
        maxBytes: this.maxAttachEncodedChars,
        retainedBytes: (event) => this.attachEventRetainedBytes(event),
      },
    );
  }

  private async requireCapability(capability: string, feature: string): Promise<void> {
    if (this.identifiedProtocol === null) {
      await this.identify();
    }
    if (!this.identifiedCapabilities.has(capability)) {
      throw new CmuxProtocolError(`${feature} is not supported by this server`);
    }
  }

  private async requireProtocol(minimum: number, feature: string): Promise<void> {
    const protocol = this.protocol ?? (await this.identify()).protocol;
    if (protocol < minimum) {
      throw new CmuxProtocolError(
        `${feature} requires protocol ${minimum}; server uses protocol ${protocol}`,
      );
    }
  }

  waitFor(surface: IdRef, pattern: string, timeoutMs: number): Promise<WaitForResult> {
    return this.request("wait-for", { surface, pattern, timeout_ms: timeoutMs });
  }
  run(options: CmuxRequestParams<"run">): Promise<RunResult> { return this.request("run", options); }
  sendKey(surface: IdRef, keys: string[]): Promise<EmptyResult> { return this.request("send-key", { surface, keys }); }
  copy(surface: IdRef, mode: CopyMode): Promise<CopyResult> { return this.request("copy", { surface, mode }); }
  ids(kind?: IdKind | null): Promise<IdsResult> { return this.request("ids", { kind }); }
  notify(
    title: string,
    body: string,
    options: { level?: NotificationLevel | null; surface?: IdRef | null } = {},
  ): Promise<NotifyResult> {
    return this.request("notify", { title, body, ...options });
  }
  listAgents(options: CmuxRequestParams<"list-agents"> = {}): Promise<ListAgentsResult> {
    return this.request("list-agents", options);
  }
  reportAgent(
    surface: IdRef,
    state: AgentState,
    source: AgentReportSource,
    session?: string | null,
  ): Promise<ReportAgentResult> {
    return this.request("report-agent", { surface, state, source, session });
  }

  private async openStream<T extends { event: string }>(
    request: CmuxRequest,
    map: (event: UnknownEvent) => T,
    accept: (event: UnknownEvent, dedicated: boolean) => boolean,
    terminal: (event: T) => boolean = () => false,
    exclusiveSharedSubscription = false,
    buffering?: { maxBytes: number; retainedBytes: (event: T) => number },
  ): Promise<CmuxStream<T>> {
    const dedicated = this.streamTransportFactory !== undefined;
    if (exclusiveSharedSubscription && !dedicated) {
      if (this.sharedSubscriptionActive) {
        throw new CmuxProtocolError(
          "concurrent subscriptions require streamTransportFactory",
        );
      }
      this.sharedSubscriptionActive = true;
    }
    const transport = this.streamTransportFactory?.() ?? this.transport;
    const router = dedicated ? new MessageRouter(transport) : this.router;
    let eventSubscription: Unsubscribe = () => undefined;
    let terminalSubscription: Unsubscribe = () => undefined;
    let streamError: Error | null = null;
    const stream = new CmuxStream<T>(this.timeoutMs, () => {
      eventSubscription();
      terminalSubscription();
      if (exclusiveSharedSubscription && !dedicated) {
        this.sharedSubscriptionActive = false;
      }
      if (dedicated) transport.close();
    }, this.maxBufferedEvents, buffering?.maxBytes, buffering?.retainedBytes);
    eventSubscription = router.onEvent((event) => {
      if (!accept(event, dedicated)) return;
      try {
        const mapped = map(event);
        stream.push(mapped, terminal(mapped));
        streamError ??= stream.error;
      } catch (error) {
        streamError = error instanceof CmuxProtocolError
          ? error
          : new CmuxProtocolError(`invalid stream event: ${(error as Error).message}`);
        stream.fail(streamError);
      }
    });
    terminalSubscription = router.onTerminal((error) => stream.fail(error));

    const payload = this.dropUndefined({ id: this.nextId(), ...request });
    const response = await router.send(payload, this.timeoutMs).catch((error) => {
      stream.fail(error as Error);
      throw streamError ?? error;
    });
    if (!response.ok) {
      stream.close();
      throw new CmuxCommandError(response.error || "unknown error", response.id, response);
    }
    const terminalError = streamError ?? stream.error;
    if (terminalError) throw terminalError;
    return stream;
  }

  private decodeAttachEvent(event: AttachEvent): DecodedAttachEvent {
    switch (event.event) {
      case "vt-state": {
        return { ...event, data: this.decodeAttachData(event.data, "vt-state") } as DecodedAttachEvent;
      }
      case "output": {
        return { ...event, data: this.decodeAttachData(event.data, "output") } as DecodedAttachEvent;
      }
      case "resized": {
        const encoded = typeof event.data === "string" ? event.data : event.replay;
        const data = this.decodeAttachData(encoded, "resized");
        return { ...event, data, replay: data } as DecodedAttachEvent;
      }
      case "frame": {
        this.validateAttachEncodedData(event.data, "frame");
        return event as DecodedAttachEvent;
      }
      case "browser-state": {
        const frame = event.frame;
        if (frame !== undefined && frame !== null) {
          if (typeof frame !== "object" || Array.isArray(frame)) {
            throw new CmuxProtocolError("browser-state frame is not an object");
          }
          this.validateAttachEncodedData(
            (frame as { data?: unknown }).data,
            "browser-state frame",
          );
        }
        return event as DecodedAttachEvent;
      }
      default: return event as DecodedAttachEvent;
    }
  }

  private decodeAttachData(value: unknown, eventName: string): Uint8Array {
    return decodeBase64(this.validateAttachEncodedData(value, eventName));
  }

  private validateAttachEncodedData(value: unknown, eventName: string): string {
    if (typeof value !== "string") {
      throw new CmuxProtocolError(`${eventName} data is not base64 text`);
    }
    if (value.length > this.maxAttachEncodedChars) {
      throw new CmuxProtocolError(
        `${eventName} data exceeds ${this.maxAttachEncodedChars} encoded characters`,
      );
    }
    return value;
  }

  private attachEventRetainedBytes(event: DecodedAttachEvent): number {
    switch (event.event) {
      case "vt-state":
      case "output":
      case "resized":
        return event.data instanceof Uint8Array ? event.data.byteLength : 0;
      case "frame":
        return typeof event.data === "string" ? event.data.length : 0;
      case "browser-state":
        return new TextEncoder().encode(JSON.stringify(event)).byteLength;
      default:
        return 0;
    }
  }

  private matchesAttachEvent(event: UnknownEvent, surface: Id, mode: "bytes" | "render"): boolean {
    // colors-changed is scoped by its attach connection and intentionally has
    // no surface field in protocol v6. Protocol v7 includes the surface id.
    if (event.event === "colors-changed") {
      return mode === "bytes" && (!("surface" in event) || event.surface === surface);
    }
    if (!("surface" in event) || event.surface !== surface) return false;
    if (event.event === "detached" || event.event === "scroll-changed"
      || this.isSurfaceOverflow(event, surface)) return true;
    return mode === "render"
      ? event.event === "render-state" || event.event === "render-delta"
      : event.event === "vt-state" || event.event === "output" || event.event === "resized"
        || event.event === "frame" || event.event === "browser-state";
  }

  private isSurfaceOverflow(
    event: { event: string; scope?: unknown; surface?: unknown },
    surface?: Id,
  ): boolean {
    return event.event === "overflow"
      && event.scope === "surface"
      && "surface" in event
      && (surface === undefined || event.surface === surface);
  }

  private attachOnlyEvent(event: string): boolean {
    return event === "vt-state"
      || event === "output"
      || event === "resized"
      || event === "frame"
      || event === "browser-state"
      || event === "colors-changed"
      || event === "render-state"
      || event === "render-delta"
      || event === "detached";
  }

  private dropUndefined(value: Record<string, unknown>): JsonObject {
    return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject;
  }

  private securityLimit(name: string, value: number | undefined, maximum: number): number {
    const limit = value ?? maximum;
    if (!Number.isSafeInteger(limit) || limit <= 0 || limit > maximum) {
      throw new RangeError(`${name} must be an integer from 1 through ${maximum}`);
    }
    return limit;
  }

  private nextId(): number {
    return this.nextRequestId++;
  }
}
