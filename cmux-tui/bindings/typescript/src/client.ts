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
  NotificationLevel,
  NotifyResult,
  PaneDirection,
  PaneNeighborResult,
  PingResult,
  ProcessInfoResult,
  ReadScreenResult,
  ReloadConfigResult,
  ReportAgentResult,
  RunResult,
  SidebarPluginResult,
  SplitDirection,
  SubscribeEvent,
  SurfaceResult,
  Tree,
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
  /** Creates dedicated subscribe/attach transports when supplied. */
  streamTransportFactory?: () => Transport;
}

export type NewTabOptions = CmuxRequestParams<"new-tab">;
export type NewBrowserTabOptions = Omit<CmuxRequestParams<"new-browser-tab">, "url">;
export type NewWorkspaceOptions = CmuxRequestParams<"new-workspace">;
export type NewScreenOptions = CmuxRequestParams<"new-screen">;
export type SplitOptions = Omit<CmuxRequestParams<"split">, "pane" | "dir">;
export type SelectOptions = CmuxRequestParams<"select-screen">;
export type SelectTabOptions = CmuxRequestParams<"select-tab">;
export interface SendOptions { text?: string | null; bytes?: string | Uint8Array | null }

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
  private readonly waiters: StreamWaiter<T>[] = [];
  private closed = false;
  private endsAfterDrain = false;

  constructor(
    private readonly timeoutMs: number,
    private readonly cleanup: () => void,
  ) {}

  async next(timeoutMs = this.timeoutMs): Promise<T> {
    if (this.buffered.length > 0) {
      const event = this.buffered.shift()!;
      if (this.endsAfterDrain && this.buffered.length === 0) this.finish();
      return event;
    }
    if (this.closed) throw new CmuxConnectionError("stream is closed");

    const waiter: StreamWaiter<T> = {
      active: true,
      resolve: () => undefined,
      reject: () => undefined,
    };
    const event = await new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter.active = false;
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
    if (!delivered) this.buffered.push(event);
    if (terminal) this.endsAfterDrain = true;
  }

  fail(error: Error): void {
    if (this.closed) return;
    this.finish();
    this.rejectWaiters(error);
  }

  async *[Symbol.asyncIterator](): AsyncIterator<T> {
    while (!this.closed) yield await this.next();
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
  private readonly transport: Transport;
  private readonly router: MessageRouter;
  private readonly streamTransportFactory?: () => Transport;
  private nextRequestId = 1;
  private protocol: number | null = null;

  constructor(options: CmuxClientOptions) {
    this.transport = options.transport;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.allowProtocolV6Attach = options.allowProtocolV6Attach ?? true;
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
    this.protocol = result.protocol;
    return result;
  }

  ping(): Promise<PingResult> { return this.request("ping"); }
  reloadConfig(): Promise<ReloadConfigResult> { return this.request("reload-config"); }
  setWindowTitle(title: string): Promise<EmptyResult> { return this.request("set-window-title", { title }); }
  clearWindowTitle(): Promise<EmptyResult> { return this.request("clear-window-title"); }
  listWorkspaces(): Promise<Tree> { return this.request("list-workspaces"); }
  exportLayout(screen?: Id | null): Promise<ExportLayoutResult> { return this.request("export-layout", { screen }); }
  applyLayout(layout: DeclarativeLayout, options: Omit<CmuxRequestParams<"apply-layout">, "layout"> = {}): Promise<ApplyLayoutResult> {
    return this.request("apply-layout", { ...options, layout });
  }

  async send(surface: Id, options: SendOptions = {}): Promise<EmptyResult> {
    const bytes = options.bytes instanceof Uint8Array ? encodeBase64(options.bytes) : options.bytes;
    return this.request("send", { surface, text: options.text, bytes });
  }

  readScreen(surface: Id): Promise<ReadScreenResult> { return this.request("read-screen", { surface }); }
  sidebarPlugin(cols: number, rows: number, relaunch?: boolean | null): Promise<SidebarPluginResult> {
    return this.request("sidebar-plugin", { cols, rows, relaunch });
  }
  vtState(surface: Id): Promise<VtStateResult> { return this.request("vt-state", { surface }); }
  newTab(options: NewTabOptions = {}): Promise<SurfaceResult> { return this.request("new-tab", options); }
  newBrowserTab(url: string, options: NewBrowserTabOptions = {}): Promise<SurfaceResult> {
    return this.request("new-browser-tab", { url, ...options });
  }
  newWorkspace(options: NewWorkspaceOptions = {}): Promise<SurfaceResult> { return this.request("new-workspace", options); }
  newScreen(options: NewScreenOptions = {}): Promise<SurfaceResult> { return this.request("new-screen", options); }
  split(pane: Id, dir: SplitDirection, options: SplitOptions = {}): Promise<SurfaceResult> {
    return this.request("split", { pane, dir, ...options });
  }
  setRatio(pane: Id, dir: SplitDirection, ratio: number): Promise<EmptyResult> {
    return this.request("set-ratio", { pane, dir, ratio });
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
  closeWorkspace(workspace: Id): Promise<EmptyResult> { return this.request("close-workspace", { workspace }); }
  renamePane(pane: Id, name: string): Promise<EmptyResult> { return this.request("rename-pane", { pane, name }); }
  renameSurface(surface: Id, name: string): Promise<EmptyResult> { return this.request("rename-surface", { surface, name }); }
  renameScreen(screen: Id, name: string): Promise<EmptyResult> { return this.request("rename-screen", { screen, name }); }
  renameWorkspace(workspace: Id, name: string): Promise<EmptyResult> { return this.request("rename-workspace", { workspace, name }); }
  resizeSurface(surface: Id, cols: number, rows: number): Promise<EmptyResult> {
    return this.request("resize-surface", { surface, cols, rows });
  }
  focusPane(pane: Id): Promise<EmptyResult> { return this.request("focus-pane", { pane }); }
  selectTab(options: SelectTabOptions = {}): Promise<EmptyResult> { return this.request("select-tab", options); }
  selectScreen(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-screen", options); }
  selectWorkspace(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-workspace", options); }
  moveTab(surface: Id, pane: Id, index: number): Promise<EmptyResult> { return this.request("move-tab", { surface, pane, index }); }
  moveWorkspace(workspace: Id, index: number): Promise<EmptyResult> { return this.request("move-workspace", { workspace, index }); }
  scrollSurface(surface: Id, delta: number): Promise<EmptyResult> { return this.request("scroll-surface", { surface, delta }); }

  async subscribe(options: CmuxRequestParams<"subscribe"> = {}): Promise<CmuxStream<SubscribeEvent>> {
    return this.openStream(
      { cmd: "subscribe", ...options },
      (event) => event as SubscribeEvent,
      (event, dedicated) => dedicated || !this.attachOnlyEvent(event.event),
    );
  }

  async attachSurface(surface: Id): Promise<CmuxStream<DecodedAttachEvent>> {
    const protocol = this.protocol ?? (await this.identify()).protocol;
    if (protocol > 6 || (protocol > 5 && !this.allowProtocolV6Attach)) {
      throw new CmuxProtocolError(`unsupported attach protocol ${protocol}`);
    }
    return this.openStream(
      { cmd: "attach-surface", surface },
      (event) => this.decodeAttachEvent(event as AttachEvent),
      (event, dedicated) => dedicated || this.matchesAttachEvent(event, surface),
      (event) => event.event === "detached",
    );
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
  ): Promise<CmuxStream<T>> {
    const dedicated = this.streamTransportFactory !== undefined;
    const transport = this.streamTransportFactory?.() ?? this.transport;
    const router = dedicated ? new MessageRouter(transport) : this.router;
    let eventSubscription: Unsubscribe = () => undefined;
    let terminalSubscription: Unsubscribe = () => undefined;
    const stream = new CmuxStream<T>(this.timeoutMs, () => {
      eventSubscription();
      terminalSubscription();
      if (dedicated) transport.close();
    });
    eventSubscription = router.onEvent((event) => {
      if (!accept(event, dedicated)) return;
      try {
        const mapped = map(event);
        stream.push(mapped, terminal(mapped));
      } catch (error) {
        stream.fail(new CmuxProtocolError(`invalid stream event: ${(error as Error).message}`));
      }
    });
    terminalSubscription = router.onTerminal((error) => stream.fail(error));

    const payload = this.dropUndefined({ id: this.nextId(), ...request });
    const response = await router.send(payload, this.timeoutMs).catch((error) => {
      stream.fail(error as Error);
      throw error;
    });
    if (!response.ok) {
      stream.close();
      throw new CmuxCommandError(response.error || "unknown error", response.id, response);
    }
    return stream;
  }

  private decodeAttachEvent(event: AttachEvent): DecodedAttachEvent {
    switch (event.event) {
      case "vt-state": {
        if (typeof event.data !== "string") throw new Error("vt-state data is not base64 text");
        return { ...event, data: decodeBase64(event.data) } as DecodedAttachEvent;
      }
      case "output": {
        if (typeof event.data !== "string") throw new Error("output data is not base64 text");
        return { ...event, data: decodeBase64(event.data) } as DecodedAttachEvent;
      }
      case "resized": {
        const encoded = typeof event.data === "string" ? event.data : event.replay;
        if (typeof encoded !== "string") throw new Error("resized data is not base64 text");
        const data = decodeBase64(encoded);
        return { ...event, data, replay: data } as DecodedAttachEvent;
      }
      default: return event as DecodedAttachEvent;
    }
  }

  private matchesAttachEvent(event: UnknownEvent, surface: Id): boolean {
    if (!("surface" in event) || event.surface !== surface) return false;
    return this.attachOnlyEvent(event.event) || event.event === "scroll-changed";
  }

  private attachOnlyEvent(event: string): boolean {
    return event === "vt-state" || event === "output" || event === "resized" || event === "detached";
  }

  private dropUndefined(value: Record<string, unknown>): JsonObject {
    return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject;
  }

  private nextId(): number {
    return this.nextRequestId++;
  }
}
