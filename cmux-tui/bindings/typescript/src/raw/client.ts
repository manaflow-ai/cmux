import { decodeBase64, encodeBase64 } from "../base64.js";
import {
  CmuxAbortError,
  CmuxAuthorityError,
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
  KnownBrowserAttachEvent,
  ListAgentsResult,
  ListClientsResult,
  ListTerminalsResult,
  MoveTerminalResult,
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
  ResolveTerminalResult,
  RunResult,
  RenderAttachEvent,
  SidebarPluginResult,
  SplitDirection,
  SubscribeEvent,
  SurfaceResult,
  TerminalPlacement,
  TerminalEventsResult,
  Tree,
  WorkspacePlacement,
  WorkspaceMutation,
  UnknownEvent,
  VtStateResult,
  WaitForResult,
  ZoomPaneResult,
  AgentReportSource,
  AgentState,
  CloseTerminalResult,
  DeclarativeLayout,
  FocusDirectionResult,
} from "./protocol/index.js";
import {
  commandResultNeedsDecodeContext,
  commandStreamNeedsDecodeContext,
  decodeCommandResult,
  decodeProtocolEvent,
  encodeCommandParams,
  type ProtocolDecodeContext,
} from "./protocol-codec.js";
import {
  COMMAND_METADATA,
  EVENT_METADATA,
  PROFILES,
  type CmuxAuthority,
} from "./generated/metadata.js";
import type { Transport, Unsubscribe } from "../transport.js";
import { validateRequestTimeout } from "../internal/request-timeout.js";
import {
  RENDER_ATTACH_MAX_ENCODED_CHARS,
  RENDER_GRAPHIC_MAX_ENCODED_CHARS,
  RENDER_GRAPHIC_MAX_IMAGES,
  RENDER_GRAPHIC_MAX_PLACEMENTS,
  utf8ByteLength,
} from "../transport-limits.js";
import { parseWireJson, stringifyWireJson } from "../wire-json.js";

export interface CmuxClientOptions {
  transport: Transport;
  /**
   * Command authorities enabled for this client. Profiles inherit the
   * authorities declared by generated `PROFILES` metadata.
   *
   * Transport-neutral clients default to control and frontend.
   */
  authorities?: readonly CmuxAuthority[];
  /** Explicitly enables provider-owned workspace mutation commands. */
  enableProviderAuthority?: boolean;
  /**
   * Command acknowledgement timeout from 0 through 2147483647 milliseconds.
   * Zero permits dispatch only when it starts synchronously.
   * It does not limit idle event streams.
   */
  timeoutMs?: number;
  /** Maximum time to establish an attach stream. */
  attachHandshakeTimeoutMs?: number;
  /** Optional default timeout for an idle stream read. The default waits indefinitely. */
  streamIdleTimeoutMs?: number;
  allowProtocolV6Attach?: boolean;
  /** Maximum events retained for a stream whose consumer falls behind. */
  maxBufferedEvents?: number;
  /** Maximum command responses waiting concurrently on one transport. */
  maxPendingResponses?: number;
  /** Maximum encoded characters per attach payload and retained bytes across buffered attach events. */
  maxAttachEncodedChars?: number;
  /** Creates dedicated subscribe/attach transports when supplied. */
  streamTransportFactory?: () => Transport;
}

export interface SendRawOptions {
  /**
   * Overrides the client command acknowledgement timeout with a finite value
   * from 0 through 2147483647 milliseconds. Zero permits dispatch only when
   * it starts synchronously.
   */
  timeoutMs?: number;
  /** Cancels the request and any transport frame that has not started dispatch. */
  signal?: AbortSignal;
}

export const DEFAULT_MAX_BUFFERED_EVENTS = 256;
export const DEFAULT_MAX_ATTACH_ENCODED_CHARS = RENDER_ATTACH_MAX_ENCODED_CHARS;
export const DEFAULT_MAX_PENDING_RESPONSES = 256;
export const MIN_ATTACH_HANDSHAKE_BYTES_PER_SECOND = 64 * 1024;
export const MAX_ATTACH_HANDSHAKE_TIMEOUT_MS = 15 * 60 * 1_000;
const DEFAULT_CLIENT_AUTHORITIES =
  Object.freeze(["control", "frontend"] as const satisfies readonly CmuxAuthority[]);

export function defaultAttachHandshakeTimeoutMs(
  requestTimeoutMs: number,
  maxAttachEncodedChars: number,
): number {
  const transferMs = Math.ceil(
    maxAttachEncodedChars * 1_000 / MIN_ATTACH_HANDSHAKE_BYTES_PER_SECOND,
  );
  return Math.max(
    requestTimeoutMs,
    Math.min(MAX_ATTACH_HANDSHAKE_TIMEOUT_MS, requestTimeoutMs + transferMs),
  );
}

function workspaceMutationResult(result: WorkspaceMutation): WorkspaceMutation {
  return result;
}

function normalizeClientSizing(clients: ListClientsResult): ListClientsResult {
  return clients;
}

export type NewTabOptions = CmuxRequestParams<"new-tab">;
export type NewBrowserTabOptions = Omit<CmuxRequestParams<"new-browser-tab">, "url">;
export type NewWorkspaceOptions = CmuxRequestParams<"new-workspace">;
export type CreateWorkspaceOptions = CmuxRequestParams<"create-workspace">;
export type CreateTerminalOptions = CmuxRequestParams<"create-terminal">;
export type CloseTerminalOptions = Omit<
  CmuxRequestParams<"close-terminal">,
  "terminal_id" | "terminal_incarnation"
>;
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
export interface StreamOpenOptions {
  /** Cancels an in-flight stream open and the resulting stream lifetime. */
  signal?: AbortSignal;
  /** Overrides the client's idle timeout for this stream. Omit to wait indefinitely by default. */
  idleTimeoutMs?: number;
}
export interface StreamNextOptions {
  /** Overrides the stream's idle timeout for this read. Omit to use the stream default. */
  timeoutMs?: number;
  /** Cancels only this pending read without closing the stream. */
  signal?: AbortSignal;
}
export interface SubscribeOptions extends StreamOpenOptions {
  treeEvents?: "coarse" | "deltas";
  /** Restricts server-side events to one surface when the capability is available. */
  surface?: Id | null;
}
type AttachDimensions =
  | { cols: number; rows: number }
  | { cols?: never; rows?: never };
export type AttachSurfaceOptions = StreamOpenOptions
  & { mode?: "bytes" | "render" }
  & AttachDimensions;
export type BrowserAttachSurfaceOptions = StreamOpenOptions & AttachDimensions;
/** The six browser attachment events known to this SDK version. */
export type BrowserAttachEvent = KnownBrowserAttachEvent;

/** A forward-compatible browser attachment event unknown to this SDK version. */
export interface UnknownBrowserAttachEvent {
  event: "unknown";
  /** The event discriminant received on the wire. */
  wireEvent: string;
  /** The complete decoded wire object, with large integers preserved as bigint. */
  raw: JsonObject;
}

/** Events yielded by `attachBrowserSurface()`. */
export type BrowserStreamEvent = BrowserAttachEvent | UnknownBrowserAttachEvent;

interface PendingResponse {
  resolve: (response: CmuxResponse<unknown>) => void;
  reject: (error: Error) => void;
  readonly dispatchDeadline: number;
  timer?: ReturnType<typeof setTimeout>;
  signal?: AbortSignal;
  abort?: () => void;
  cancelUndispatched?: Unsubscribe;
}

class MessageRouter {
  private readonly pending = new Map<string, PendingResponse>();
  private readonly eventHandlers =
    new Set<(event: UnknownEvent, receivedBytes: number) => void>();
  private readonly terminalHandlers = new Set<(error: Error) => void>();
  private terminalError: Error | null = null;
  private decodeContext: ProtocolDecodeContext | undefined;

  constructor(
    readonly transport: Transport,
    private readonly maxPendingResponses = DEFAULT_MAX_PENDING_RESPONSES,
    decodeContext?: ProtocolDecodeContext,
  ) {
    this.decodeContext = decodeContext;
    transport.onMessage((json) => this.receive(json));
    transport.onError((error) => this.terminate(this.connectionError(error)));
    transport.onClose(() => this.terminate(new CmuxConnectionError("session transport closed")));
  }

  send(
    request: JsonObject,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<CmuxResponse<unknown>> {
    const key = this.idKey(request.id);
    if (this.terminalError) return Promise.reject(this.terminalError);
    if (signal?.aborted) return Promise.reject(new CmuxAbortError("operation aborted"));
    validateRequestTimeout(timeoutMs);
    if (this.pending.has(key)) return Promise.reject(new CmuxProtocolError(`duplicate request id ${key}`));
    if (this.pending.size >= this.maxPendingResponses) {
      return Promise.reject(new CmuxProtocolError("pending response buffer is full"));
    }

    return new Promise((resolve, reject) => {
      const pending: PendingResponse = {
        resolve,
        reject,
        dispatchDeadline: performance.now() + timeoutMs,
      };
      const expire = () => {
        if (!this.takePending(key, pending)) return;
        reject(new CmuxTimeoutError("session did not respond"));
      };
      pending.timer = setTimeout(expire, timeoutMs);
      if (signal) {
        pending.signal = signal;
        pending.abort = () => {
          if (!this.takePending(key, pending)) return;
          reject(new CmuxAbortError("operation aborted"));
        };
      }
      this.pending.set(key, pending);
      if (signal) {
        signal.addEventListener("abort", pending.abort!, { once: true });
        if (signal.aborted) {
          pending.abort!();
          return;
        }
      }
      try {
        const json = stringifyWireJson(request);
        if (
          this.transport.supportsDispatchGuard === true
          && this.transport.sendCancellable
        ) {
          let dispatchStarted = false;
          let synchronousDispatchWindow = true;
          const cancelUndispatched = this.transport.sendCancellable(
            json,
            () => {
              if (dispatchStarted) return;
              dispatchStarted = true;
              const release = pending.cancelUndispatched;
              pending.cancelUndispatched = undefined;
              release?.();
            },
            () => {
              if (this.pending.get(key) !== pending) return false;
              if (timeoutMs === 0 && synchronousDispatchWindow) return true;
              if (performance.now() < pending.dispatchDeadline) return true;
              expire();
              return false;
            },
          );
          synchronousDispatchWindow = false;
          if (!dispatchStarted && this.pending.get(key) === pending) {
            pending.cancelUndispatched = cancelUndispatched;
          } else {
            cancelUndispatched();
          }
        } else {
          this.transport.send(json);
        }
      } catch (error) {
        if (this.takePending(key, pending)) reject(this.connectionError(error));
      }
    });
  }

  onEvent(handler: (event: UnknownEvent, receivedBytes: number) => void): Unsubscribe {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onTerminal(handler: (error: Error) => void): Unsubscribe {
    this.terminalHandlers.add(handler);
    if (this.terminalError) queueMicrotask(() => handler(this.terminalError!));
    return () => this.terminalHandlers.delete(handler);
  }

  setDecodeContext(context: ProtocolDecodeContext): void {
    this.decodeContext = context;
  }

  private receive(json: string): void {
    let value: unknown;
    try {
      value = parseWireJson(json);
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
      let event: UnknownEvent;
      try {
        event = decodeProtocolEvent(object, this.decodeContext);
      } catch (error) {
        this.terminate(
          error instanceof Error
            ? error
            : new CmuxProtocolError("server sent an invalid event"),
        );
        return;
      }
      const receivedBytes = utf8ByteLength(json);
      for (const handler of this.eventHandlers) handler(event, receivedBytes);
      return;
    }

    const key = object.id === undefined ? this.pending.keys().next().value : this.idKey(object.id as Json);
    if (key === undefined) return;
    const pending = this.pending.get(key);
    if (!pending) return;
    if (!this.takePending(key, pending)) return;
    pending.resolve(object as unknown as CmuxResponse<unknown>);
  }

  private terminate(error: Error): void {
    if (this.terminalError) return;
    this.terminalError = error;
    for (const [key, pending] of this.pending) {
      if (this.takePending(key, pending)) pending.reject(error);
    }
    for (const handler of this.terminalHandlers) handler(error);
  }

  private takePending(key: string, pending: PendingResponse): boolean {
    if (this.pending.get(key) !== pending) return false;
    this.pending.delete(key);
    if (pending.timer !== undefined) clearTimeout(pending.timer);
    if (pending.signal && pending.abort) {
      pending.signal.removeEventListener("abort", pending.abort);
    }
    const cancelUndispatched = pending.cancelUndispatched;
    pending.cancelUndispatched = undefined;
    cancelUndispatched?.();
    return true;
  }

  private idKey(id: Json | undefined): string {
    return id === undefined ? "undefined" : stringifyWireJson(id);
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

interface BufferedStreamEvent<T> {
  event: T;
  retainedBytes: number;
}

/** A closeable async event stream that waits indefinitely unless an idle timeout is configured. */
export class CmuxStream<T extends { event: string }> implements AsyncIterable<T> {
  private readonly buffered: BufferedStreamEvent<T>[] = [];
  private bufferedBytes = 0;
  private readonly waiters: StreamWaiter<T>[] = [];
  private closed = false;
  private endsAfterDrain = false;
  private terminalError: Error | null = null;

  constructor(
    readonly idleTimeoutMs: number | undefined,
    private readonly cleanup: () => void,
    private readonly maxBufferedEvents = DEFAULT_MAX_BUFFERED_EVENTS,
    private readonly maxBufferedBytes = Number.POSITIVE_INFINITY,
    private readonly retainedBytes: (event: T) => number = () => 0,
  ) {
    if (idleTimeoutMs !== undefined) this.validateIdleTimeout(idleTimeoutMs);
  }

  next(timeoutMs?: number): Promise<T>;
  next(options: StreamNextOptions): Promise<T>;
  async next(input?: number | StreamNextOptions): Promise<T> {
    const options = typeof input === "number" ? { timeoutMs: input } : (input ?? {});
    const timeoutMs = options.timeoutMs ?? this.idleTimeoutMs;
    if (timeoutMs !== undefined) this.validateIdleTimeout(timeoutMs);
    if (options.signal?.aborted) throw new CmuxAbortError("stream read aborted");
    if (this.buffered.length > 0) {
      const buffered = this.buffered.shift()!;
      this.bufferedBytes = Math.max(0, this.bufferedBytes - buffered.retainedBytes);
      if (this.endsAfterDrain && this.buffered.length === 0) this.finish();
      return buffered.event;
    }
    if (this.terminalError) throw this.terminalError;
    if (this.closed) throw new CmuxConnectionError("stream is closed");

    const waiter: StreamWaiter<T> = {
      active: true,
      resolve: () => undefined,
      reject: () => undefined,
    };
    const event = await new Promise<T>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const remove = () => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
      };
      const cleanup = () => {
        if (timer !== undefined) clearTimeout(timer);
        options.signal?.removeEventListener("abort", abort);
      };
      waiter.resolve = (value) => {
        if (!waiter.active) return;
        waiter.active = false;
        cleanup();
        resolve(value);
      };
      waiter.reject = (error) => {
        if (!waiter.active) return;
        waiter.active = false;
        cleanup();
        reject(error);
      };
      this.waiters.push(waiter);
      const abort = () => {
        if (!waiter.active) return;
        remove();
        waiter.reject(new CmuxAbortError("stream read aborted"));
      };
      if (timeoutMs !== undefined) {
        timer = setTimeout(() => {
          if (!waiter.active) return;
          remove();
          waiter.reject(new CmuxTimeoutError("stream did not produce an event"));
        }, timeoutMs);
      }
      if (options.signal) {
        options.signal.addEventListener("abort", abort, { once: true });
        if (options.signal.aborted) abort();
      }
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

  push(event: T, terminal = false, retainedBytesOverride?: number): void {
    if (this.closed) return;
    const retainedBytes = retainedBytesOverride ?? this.retainedBytes(event);
    if (retainedBytes > this.maxBufferedBytes) {
      this.fail(
        new CmuxProtocolError(
          `stream event data exceeds ${this.maxBufferedBytes} bytes`,
        ),
      );
      return;
    }
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
      if (retainedBytes > this.maxBufferedBytes - this.bufferedBytes) {
        this.fail(
          new CmuxProtocolError(
            `stream buffered data exceeds ${this.maxBufferedBytes} bytes`,
          ),
        );
        return;
      }
      this.buffered.push({ event, retainedBytes });
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

  private validateIdleTimeout(value: number): void {
    if (!Number.isSafeInteger(value) || value <= 0 || value > 2_147_483_647) {
      throw new RangeError("stream idle timeout must be an integer from 1 through 2147483647");
    }
  }
}

/** Promise-based typed client for any cmux JSON transport. */
export class CmuxClient {
  readonly timeoutMs: number;
  readonly attachHandshakeTimeoutMs: number;
  readonly streamIdleTimeoutMs: number | undefined;
  readonly allowProtocolV6Attach: boolean;
  readonly maxBufferedEvents: number;
  readonly maxPendingResponses: number;
  readonly maxAttachEncodedChars: number;
  /** Expanded, immutable command authorities enabled for this client. */
  readonly authorities: readonly CmuxAuthority[];
  private readonly transport: Transport;
  private readonly router: MessageRouter;
  private readonly streamTransportFactory?: () => Transport;
  private readonly authoritySet: ReadonlySet<CmuxAuthority>;
  private nextRequestId = 1;
  private identifiedProtocol: number | null = null;
  private identifiedCapabilities = new Set<string>();
  private sharedSubscriptionActive = false;

  constructor(options: CmuxClientOptions) {
    const timeoutMs = validateRequestTimeout(options.timeoutMs ?? 10_000);
    this.transport = options.transport;
    this.authoritySet = this.resolveAuthorities(
      options.authorities ?? DEFAULT_CLIENT_AUTHORITIES,
      options.enableProviderAuthority ?? false,
    );
    this.authorities = Object.freeze([...this.authoritySet]);
    this.timeoutMs = timeoutMs;
    this.streamIdleTimeoutMs = options.streamIdleTimeoutMs;
    if (this.streamIdleTimeoutMs !== undefined) {
      this.streamIdleTimeout(
        "streamIdleTimeoutMs",
        this.streamIdleTimeoutMs,
      );
    }
    this.allowProtocolV6Attach = options.allowProtocolV6Attach ?? true;
    this.maxBufferedEvents = this.securityLimit(
      "maxBufferedEvents",
      options.maxBufferedEvents,
      DEFAULT_MAX_BUFFERED_EVENTS,
    );
    this.maxPendingResponses = this.securityLimit(
      "maxPendingResponses",
      options.maxPendingResponses,
      DEFAULT_MAX_PENDING_RESPONSES,
    );
    this.maxAttachEncodedChars = this.securityLimit(
      "maxAttachEncodedChars",
      options.maxAttachEncodedChars,
      DEFAULT_MAX_ATTACH_ENCODED_CHARS,
    );
    const defaultAttachTimeout = defaultAttachHandshakeTimeoutMs(
      this.timeoutMs,
      this.maxAttachEncodedChars,
    );
    this.attachHandshakeTimeoutMs = options.attachHandshakeTimeoutMs === undefined
      ? defaultAttachTimeout
      : Math.max(
        this.timeoutMs,
        this.securityLimit(
          "attachHandshakeTimeoutMs",
          options.attachHandshakeTimeoutMs,
          MAX_ATTACH_HANDSHAKE_TIMEOUT_MS,
        ),
      );
    this.streamTransportFactory = options.streamTransportFactory;
    this.router = new MessageRouter(this.transport, this.maxPendingResponses);
  }

  async close(): Promise<void> {
    this.transport.close();
  }

  async sendRaw(
    obj: JsonObject,
    options: SendRawOptions = {},
  ): Promise<CmuxResponse<unknown>> {
    const payload = this.dropUndefined({ ...obj });
    if (
      typeof payload.cmd === "string"
      && Object.hasOwn(COMMAND_METADATA, payload.cmd)
    ) {
      this.assertCommandAuthority(payload.cmd as CmuxCommand);
    }
    if (!("id" in payload)) payload.id = this.nextId();
    return this.router.send(
      payload,
      options.timeoutMs ?? this.timeoutMs,
      options.signal,
    );
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
    const source = (typeof requestOrCommand === "string"
      ? { cmd: requestOrCommand, ...(params ?? {}) }
      : requestOrCommand) as {
        cmd: C;
        id?: Json;
        [key: string]: unknown;
      };
    const { cmd, id, ...rawParams } = source;
    await this.ensureCommandAvailable(cmd as C, rawParams);
    const encoded = encodeCommandParams(
      cmd as C,
      rawParams as CmuxRequestParams<C>,
    );
    const request = {
      cmd,
      ...encoded,
      ...(id === undefined ? {} : { id }),
    };
    const response = await this.sendRaw(request as unknown as JsonObject);
    if (response.ok) {
      return decodeCommandResult(
        cmd as C,
        response.data,
        this.protocolDecodeContext(),
      );
    }
    throw new CmuxCommandError(response.error || "unknown error", response.id, response);
  }

  async identify(): Promise<IdentifyResult> {
    const result = await this.request("identify");
    this.rememberIdentity(result);
    return result;
  }

  /** The protocol reported by the latest `identify()`, or null before identification. */
  get protocol(): number | null { return this.identifiedProtocol; }

  ping(): Promise<PingResult> { return this.request("ping"); }
  setClientInfo(name?: string, kind?: string): Promise<EmptyResult> {
    return this.request("set-client-info", { name, kind });
  }
  async listClients(): Promise<ListClientsResult> {
    return normalizeClientSizing(await this.request("list-clients"));
  }
  detachClient(client: Id): Promise<EmptyResult> { return this.request("detach-client", { client }); }
  async setClientSizing(surface: Id, client: Id, enabled: boolean): Promise<EmptyResult> {
    await this.requireProtocol(10, "set-client-sizing");
    return this.request("set-client-sizing", { surface, client, enabled });
  }
  async useOnlyClientSizing(surface: Id, client: Id): Promise<EmptyResult> {
    await this.requireProtocol(10, "set-client-sizing");
    return this.request("set-client-sizing", { surface, client, enabled: true, exclusive: true });
  }
  async useAllClientSizing(surface: Id): Promise<EmptyResult> {
    await this.requireProtocol(10, "set-client-sizing");
    return this.request("set-client-sizing", { surface, enabled: true });
  }
  reloadConfig(): Promise<ReloadConfigResult> { return this.request("reload-config"); }
  setWindowTitle(title: string): Promise<EmptyResult> { return this.request("set-window-title", { title }); }
  clearWindowTitle(): Promise<EmptyResult> { return this.request("clear-window-title"); }
  listWorkspaces(): Promise<Tree> { return this.request("list-workspaces"); }
  getFrontendProjection(
    params: CmuxRequestParams<"get-frontend-projection">,
  ): Promise<CmuxResponseDataFor<"get-frontend-projection">> {
    return this.request("get-frontend-projection", params);
  }
  putFrontendProjection(
    params: CmuxRequestParams<"put-frontend-projection">,
  ): Promise<CmuxResponseDataFor<"put-frontend-projection">> {
    return this.request("put-frontend-projection", params);
  }
  listTerminals(): Promise<ListTerminalsResult> { return this.request("list-terminals"); }
  terminalEvents(afterRevision = 0n): Promise<TerminalEventsResult> {
    return this.request("terminal-events", { after_revision: afterRevision });
  }
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
  sidebarPlugin(cols: number, rows: number, relaunch?: boolean): Promise<SidebarPluginResult> {
    return this.request("sidebar-plugin", { cols, rows, relaunch });
  }
  mintTerminalRenderer(
    params: CmuxRequestParams<"mint-terminal-renderer">,
  ): Promise<CmuxResponseDataFor<"mint-terminal-renderer">> {
    return this.request("mint-terminal-renderer", params);
  }
  setCellPixels(
    params: CmuxRequestParams<"set-cell-pixels">,
  ): Promise<CmuxResponseDataFor<"set-cell-pixels">> {
    return this.request("set-cell-pixels", params);
  }
  async vtState(surface: Id): Promise<VtStateResult> {
    await this.ensureCommandAvailable("vt-state", { surface });
    const params = encodeCommandParams("vt-state", { surface });
    const response = await this.sendRaw(
      { cmd: "vt-state", ...params },
      { timeoutMs: this.attachHandshakeTimeoutMs },
    );
    if (response.ok) {
      return decodeCommandResult(
        "vt-state",
        response.data,
        this.protocolDecodeContext(),
      ) as VtStateResult;
    }
    throw new CmuxCommandError(response.error || "unknown error", response.id, response);
  }
  resolveTerminal(terminalId: string): Promise<ResolveTerminalResult> {
    return this.request("resolve-terminal", { terminal_id: terminalId });
  }
  closeTerminal(
    terminalId: string,
    terminalIncarnation?: string | null,
    options: CloseTerminalOptions = {},
  ): Promise<CloseTerminalResult> {
    return this.request("close-terminal", {
      ...options,
      terminal_id: terminalId,
      terminal_incarnation: terminalIncarnation,
    });
  }
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
  moveTerminal(
    terminalId: string,
    workspaceKey: string,
    options: Omit<
      CmuxRequestParams<"move-terminal">,
      "terminal_id" | "workspace_key"
    > = {},
  ): Promise<MoveTerminalResult> {
    return this.request("move-terminal", {
      ...options,
      terminal_id: terminalId,
      workspace_key: workspaceKey,
    });
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
    return this.request("resize-surface", { surface, cols, rows });
  }
  releaseSurfaceSize(surface: Id): Promise<EmptyResult> {
    return this.request("release-surface-size", { surface });
  }
  focusPane(pane: Id): Promise<EmptyResult> { return this.request("focus-pane", { pane }); }
  selectTab(options: SelectTabOptions = {}): Promise<EmptyResult> { return this.request("select-tab", options); }
  selectScreen(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-screen", options); }
  selectWorkspace(options: SelectOptions = {}): Promise<EmptyResult> { return this.request("select-workspace", options); }
  moveTab(surface: Id, pane: Id, index: number | bigint): Promise<EmptyResult> {
    return this.request("move-tab", { surface, pane, index: this.uint64(index, "index") });
  }
  async moveWorkspace(workspace: Id, index: number | bigint): Promise<EmptyResult> {
    await this.request("move-workspace", {
      workspace,
      index: this.uint64(index, "index"),
    });
    return {};
  }
  async moveWorkspaceRegistry(options: MoveWorkspaceOptions): Promise<WorkspaceMutation> {
    await this.requireCapability("workspace-registry-v1", "workspace registry");
    return workspaceMutationResult(await this.request("move-workspace", options));
  }
  scrollSurface(surface: Id, delta: number | bigint): Promise<EmptyResult> {
    return this.request("scroll-surface", {
      surface,
      delta: this.int64(delta, "delta"),
    });
  }
  browserMouse(
    params: CmuxRequestParams<"browser-mouse">,
  ): Promise<CmuxResponseDataFor<"browser-mouse">> {
    return this.request("browser-mouse", params);
  }
  browserWheel(
    params: CmuxRequestParams<"browser-wheel">,
  ): Promise<CmuxResponseDataFor<"browser-wheel">> {
    return this.request("browser-wheel", params);
  }
  browserKey(
    params: CmuxRequestParams<"browser-key">,
  ): Promise<CmuxResponseDataFor<"browser-key">> {
    return this.request("browser-key", params);
  }
  browserInsertText(
    params: CmuxRequestParams<"browser-insert-text">,
  ): Promise<CmuxResponseDataFor<"browser-insert-text">> {
    return this.request("browser-insert-text", params);
  }
  browserNavigate(
    params: CmuxRequestParams<"browser-navigate">,
  ): Promise<CmuxResponseDataFor<"browser-navigate">> {
    return this.request("browser-navigate", params);
  }
  browserBack(
    params: CmuxRequestParams<"browser-back">,
  ): Promise<CmuxResponseDataFor<"browser-back">> {
    return this.request("browser-back", params);
  }
  browserForward(
    params: CmuxRequestParams<"browser-forward">,
  ): Promise<CmuxResponseDataFor<"browser-forward">> {
    return this.request("browser-forward", params);
  }
  browserReload(
    params: CmuxRequestParams<"browser-reload">,
  ): Promise<CmuxResponseDataFor<"browser-reload">> {
    return this.request("browser-reload", params);
  }
  browserActivate(
    params: CmuxRequestParams<"browser-activate">,
  ): Promise<CmuxResponseDataFor<"browser-activate">> {
    return this.request("browser-activate", params);
  }
  shutdownDaemon(
    params: CmuxRequestParams<"shutdown-daemon">,
  ): Promise<CmuxResponseDataFor<"shutdown-daemon">> {
    return this.request("shutdown-daemon", params);
  }
  pairingResponse(
    params: CmuxRequestParams<"pairing-response">,
  ): Promise<CmuxResponseDataFor<"pairing-response">> {
    return this.request("pairing-response", params);
  }
  markWorkspacesProviderManaged(
    params: CmuxRequestParams<"mark-workspaces-provider-managed">,
  ): Promise<CmuxResponseDataFor<"mark-workspaces-provider-managed">> {
    return this.request("mark-workspaces-provider-managed", params);
  }
  closeProviderManagedWorkspace(
    params: CmuxRequestParams<"close-provider-managed-workspace">,
  ): Promise<CmuxResponseDataFor<"close-provider-managed-workspace">> {
    return this.request("close-provider-managed-workspace", params);
  }
  renameProviderManagedWorkspace(
    params: CmuxRequestParams<"rename-provider-managed-workspace">,
  ): Promise<CmuxResponseDataFor<"rename-provider-managed-workspace">> {
    return this.request("rename-provider-managed-workspace", params);
  }

  async subscribe(options: SubscribeOptions = {}): Promise<CmuxStream<SubscribeEvent>> {
    return this.openStream(
      { cmd: "subscribe", tree_events: options.treeEvents, surface: options.surface },
      (event) => event as SubscribeEvent,
      (event, dedicated) => dedicated
        || (!this.attachOnlyEvent(event.event) && !this.isSurfaceOverflow(event)),
      (event) => event.event === "overflow" && !this.isSurfaceOverflow(event),
      true,
      undefined,
      options,
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
    this.assertCommandAuthority("attach-surface");
    if ((options.cols === undefined) !== (options.rows === undefined)) {
      throw new CmuxProtocolError("attach-surface cols and rows must be supplied together");
    }
    const mode = options.mode ?? "bytes";
    const protocol = this.identifiedProtocol
      ?? (await this.identifyForStream(options.signal)).protocol;
    if (mode === "render" && protocol < 7) {
      throw new CmuxProtocolError(
        `render attach requires protocol 7 or newer; server reported protocol ${protocol}`,
      );
    }
    if (mode === "bytes" && protocol > 5 && !this.allowProtocolV6Attach) {
      throw new CmuxProtocolError(`byte attach for protocol ${protocol} is disabled`);
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
        (event) => this.validateRenderAttachEvent(event),
        (event, dedicated) => dedicated || this.matchesAttachEvent(event, surface, mode),
        (event) => event.event === "detached" || this.isSurfaceOverflow(event, surface),
        false,
        {
          maxBytes: this.maxAttachEncodedChars,
          retainedBytes: (_event, receivedBytes) => receivedBytes,
        },
        options,
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
      options,
    );
  }

  /**
   * Attaches to a browser surface with a fully discriminated browser event union.
   *
   * Future events use the distinct `unknown` discriminant and retain their
   * original event name and complete decoded wire payload.
   */
  async attachBrowserSurface(
    surface: Id,
    options: BrowserAttachSurfaceOptions = {},
  ): Promise<CmuxStream<BrowserStreamEvent>> {
    this.assertCommandAuthority("attach-surface");
    if ((options.cols === undefined) !== (options.rows === undefined)) {
      throw new CmuxProtocolError("attach-surface cols and rows must be supplied together");
    }
    const protocol = this.identifiedProtocol
      ?? (await this.identifyForStream(options.signal)).protocol;
    if (protocol < 6) {
      throw new CmuxProtocolError(
        `browser attach requires protocol 6 or newer; server reported protocol ${protocol}`,
      );
    }
    const request: CmuxRequest = {
      cmd: "attach-surface",
      surface,
      ...(options.cols === undefined ? {} : { cols: options.cols }),
      ...(options.rows === undefined ? {} : { rows: options.rows }),
    };
    return this.openStream(
      request,
      (event) => this.browserAttachEvent(event),
      (event, dedicated) => dedicated || this.matchesBrowserAttachEvent(event, surface),
      (event) => event.event === "detached" || this.isSurfaceOverflow(event, surface),
      false,
      {
        maxBytes: this.maxAttachEncodedChars,
        retainedBytes: (event) => this.browserAttachEventRetainedBytes(event),
      },
      options,
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

  private async identifyForStream(signal?: AbortSignal): Promise<IdentifyResult> {
    if (!signal) return this.identify();
    const request = {
      id: this.nextId(),
      cmd: "identify",
    } as JsonObject;
    const response = await this.router.send(request, this.timeoutMs, signal);
    if (!response.ok) {
      throw new CmuxCommandError(
        response.error || "unknown error",
        response.id,
        response,
      );
    }
    const result = decodeCommandResult("identify", response.data);
    this.rememberIdentity(result);
    return result;
  }

  private rememberIdentity(result: IdentifyResult): void {
    this.identifiedProtocol = result.protocol;
    this.identifiedCapabilities = new Set(result.capabilities ?? []);
    this.router.setDecodeContext({
      protocol: result.protocol,
      capabilities: this.identifiedCapabilities,
    });
  }

  private protocolDecodeContext(): ProtocolDecodeContext | undefined {
    if (this.identifiedProtocol === null) return undefined;
    return {
      protocol: this.identifiedProtocol,
      capabilities: this.identifiedCapabilities,
    };
  }

  private async ensureCommandAvailable(
    command: CmuxCommand,
    params: Readonly<Record<string, unknown>> = {},
  ): Promise<void> {
    const metadata = COMMAND_METADATA[command];
    if (!metadata) throw new CmuxProtocolError(`unknown command ${String(command)}`);
    this.assertCommandAuthority(command);
    const fieldRequirements = Object.entries(metadata.fields).filter(
      ([field]) => Object.prototype.hasOwnProperty.call(params, field)
        && params[field] !== undefined,
    );
    const fieldNeedsNegotiation = fieldRequirements.some(([, requirement]) =>
      (requirement.since !== null && requirement.since > 5)
      || requirement.capability !== null,
    );
    if (
      command !== "identify"
      && this.identifiedProtocol === null
      && (
        metadata.since > 5
        || metadata.capability !== null
        || fieldNeedsNegotiation
        || commandResultNeedsDecodeContext(command)
      )
    ) {
      await this.identify();
    }
    if (this.identifiedProtocol !== null && this.identifiedProtocol < metadata.since) {
      throw new CmuxProtocolError(
        `${command} requires protocol ${metadata.since}; server uses protocol ${this.identifiedProtocol}`,
      );
    }
    if (
      metadata.capability !== null
      && this.identifiedProtocol !== null
      && !this.identifiedCapabilities.has(metadata.capability)
    ) {
      throw new CmuxProtocolError(
        `${command} requires server capability ${metadata.capability}`,
      );
    }
    for (const [field, requirement] of fieldRequirements) {
      if (
        requirement.since !== null
        && this.identifiedProtocol !== null
        && this.identifiedProtocol < requirement.since
      ) {
        throw new CmuxProtocolError(
          `${command}.${field} requires protocol ${requirement.since}; server uses protocol ${this.identifiedProtocol}`,
        );
      }
      if (
        requirement.capability !== null
        && this.identifiedProtocol !== null
        && !this.identifiedCapabilities.has(requirement.capability)
      ) {
        throw new CmuxProtocolError(
          `${command}.${field} requires server capability ${requirement.capability}`,
        );
      }
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

  waitFor(surface: IdRef, pattern: string, timeoutMs: number | bigint): Promise<WaitForResult> {
    return this.request("wait-for", {
      surface,
      pattern,
      timeout_ms: this.uint64(timeoutMs, "timeoutMs"),
    });
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
    buffering?: {
      maxBytes: number;
      retainedBytes: (event: T, receivedBytes: number) => number;
    },
    streamOptions: StreamOpenOptions = {},
  ): Promise<CmuxStream<T>> {
    if (streamOptions.signal?.aborted) {
      throw new CmuxAbortError("stream open aborted");
    }
    const idleTimeoutMs = streamOptions.idleTimeoutMs ?? this.streamIdleTimeoutMs;
    if (idleTimeoutMs !== undefined) {
      this.streamIdleTimeout("idleTimeoutMs", idleTimeoutMs);
    }
    const { cmd, id: requestId, ...rawParams } = request;
    await this.ensureCommandAvailable(cmd, rawParams);
    if (
      this.identifiedProtocol === null
      && commandStreamNeedsDecodeContext(cmd)
    ) {
      await this.identifyForStream(streamOptions.signal);
    }
    if (streamOptions.signal?.aborted) {
      throw new CmuxAbortError("stream open aborted");
    }
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
    const router = dedicated
      ? new MessageRouter(
        transport,
        this.maxPendingResponses,
        this.protocolDecodeContext(),
      )
      : this.router;
    let eventSubscription: Unsubscribe = () => undefined;
    let terminalSubscription: Unsubscribe = () => undefined;
    let abortSubscription: Unsubscribe = () => undefined;
    let streamError: Error | null = null;
    const stream = new CmuxStream<T>(idleTimeoutMs, () => {
      eventSubscription();
      terminalSubscription();
      abortSubscription();
      if (exclusiveSharedSubscription && !dedicated) {
        this.sharedSubscriptionActive = false;
      }
      if (dedicated) transport.close();
    }, this.maxBufferedEvents, buffering?.maxBytes);
    eventSubscription = router.onEvent((event, receivedBytes) => {
      if (!accept(event, dedicated)) return;
      try {
        const mapped = map(event);
        stream.push(
          mapped,
          terminal(mapped),
          buffering?.retainedBytes(mapped, receivedBytes),
        );
        streamError ??= stream.error;
      } catch (error) {
        streamError = error instanceof CmuxProtocolError
          ? error
          : new CmuxProtocolError(`invalid stream event: ${(error as Error).message}`);
        stream.fail(streamError);
      }
    });
    terminalSubscription = router.onTerminal((error) => stream.fail(error));

    const encoded = encodeCommandParams(cmd, rawParams);
    const payload = this.dropUndefined({
      id: requestId ?? this.nextId(),
      cmd,
      ...encoded,
    });
    const response = await router.send(
      payload,
      buffering === undefined ? this.timeoutMs : this.attachHandshakeTimeoutMs,
      streamOptions.signal,
    ).catch((error) => {
      stream.fail(error as Error);
      throw streamError ?? error;
    });
    if (!response.ok) {
      stream.close();
      throw new CmuxCommandError(response.error || "unknown error", response.id, response);
    }
    const terminalError = streamError ?? stream.error;
    if (terminalError) throw terminalError;
    if (streamOptions.signal) {
      const signal = streamOptions.signal;
      const abort = () => stream.fail(new CmuxAbortError("stream aborted"));
      signal.addEventListener("abort", abort, { once: true });
      abortSubscription = () => signal.removeEventListener("abort", abort);
      if (signal.aborted) abort();
    }
    const abortError = stream.error;
    if (abortError) throw abortError;
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

  private browserAttachEvent(event: UnknownEvent): BrowserStreamEvent {
    switch (event.event) {
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
        return event as BrowserAttachEvent;
      }
      case "frame":
        this.validateAttachEncodedData(event.data, "frame");
        return event as BrowserAttachEvent;
      case "detached":
      case "notification":
      case "overflow":
      case "scroll-changed":
        return event as BrowserAttachEvent;
      default:
        if (!Object.hasOwn(EVENT_METADATA, event.event)) {
          return {
            event: "unknown",
            wireEvent: event.event,
            raw: event as unknown as JsonObject,
          };
        }
        throw new CmuxProtocolError(
          `unexpected browser attach event ${event.event}`,
        );
    }
  }

  private validateRenderAttachEvent(event: UnknownEvent): RenderAttachEvent {
    if (event.event !== "render-state" && event.event !== "render-delta") {
      return event as RenderAttachEvent;
    }
    const graphics = event.graphics;
    if (graphics === undefined) return event as RenderAttachEvent;
    if (graphics === null || typeof graphics !== "object" || Array.isArray(graphics)) {
      throw new CmuxProtocolError(`${event.event} graphics is not an object`);
    }
    const placements = (graphics as { placements?: unknown }).placements;
    if (placements === undefined && event.event === "render-state") {
      throw new CmuxProtocolError(`${event.event} graphics placements is not an array`);
    }
    if (placements !== undefined && !Array.isArray(placements)) {
      throw new CmuxProtocolError(`${event.event} graphics placements is not an array`);
    }
    if (Array.isArray(placements) && placements.length > RENDER_GRAPHIC_MAX_PLACEMENTS) {
      throw new CmuxProtocolError(
        `${event.event} graphics exceeds ${RENDER_GRAPHIC_MAX_PLACEMENTS} placements`,
      );
    }
    const removedImageIds =
      (graphics as { removed_image_ids?: unknown }).removed_image_ids;
    if (removedImageIds !== undefined) {
      if (!Array.isArray(removedImageIds)) {
        throw new CmuxProtocolError(
          `${event.event} graphics removed_image_ids is not an array`,
        );
      }
      if (removedImageIds.length > RENDER_GRAPHIC_MAX_IMAGES) {
        throw new CmuxProtocolError(
          `${event.event} graphics exceeds ${RENDER_GRAPHIC_MAX_IMAGES} removed image IDs`,
        );
      }
      if (removedImageIds.some((id) =>
        !Number.isSafeInteger(id) || id <= 0 || id > 0xffff_ffff
      )) {
        throw new CmuxProtocolError(
          `${event.event} graphics removed_image_ids contains an invalid image ID`,
        );
      }
    }
    const images = (graphics as { images?: unknown }).images;
    if (images === undefined) return event as RenderAttachEvent;
    if (!Array.isArray(images)) {
      throw new CmuxProtocolError(`${event.event} graphics images is not an array`);
    }
    if (images.length > RENDER_GRAPHIC_MAX_IMAGES) {
      throw new CmuxProtocolError(
        `${event.event} graphics exceeds ${RENDER_GRAPHIC_MAX_IMAGES} images`,
      );
    }
    for (const image of images) {
      if (image === null || typeof image !== "object" || Array.isArray(image)) {
        throw new CmuxProtocolError(`${event.event} graphics image is not an object`);
      }
      this.validateAttachEncodedData(
        (image as { data?: unknown }).data,
        `${event.event} graphics image`,
        Math.min(this.maxAttachEncodedChars, RENDER_GRAPHIC_MAX_ENCODED_CHARS),
      );
    }
    return event as RenderAttachEvent;
  }

  private decodeAttachData(value: unknown, eventName: string): Uint8Array {
    return decodeBase64(this.validateAttachEncodedData(value, eventName));
  }

  private validateAttachEncodedData(
    value: unknown,
    eventName: string,
    maxEncodedChars = this.maxAttachEncodedChars,
  ): string {
    if (typeof value !== "string") {
      throw new CmuxProtocolError(`${eventName} data is not base64 text`);
    }
    if (value.length > maxEncodedChars) {
      throw new CmuxProtocolError(
        `${eventName} data exceeds ${maxEncodedChars} encoded characters`,
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
        return new TextEncoder().encode(stringifyWireJson(event)).byteLength;
      default:
        return 0;
    }
  }

  private browserAttachEventRetainedBytes(event: BrowserStreamEvent): number {
    switch (event.event) {
      case "frame":
        return event.data.length;
      case "browser-state":
        return new TextEncoder().encode(stringifyWireJson(event)).byteLength;
      case "unknown":
        return new TextEncoder().encode(stringifyWireJson(event.raw)).byteLength;
      default:
        return 0;
    }
  }

  private matchesBrowserAttachEvent(event: UnknownEvent, surface: Id): boolean {
    if (!Object.hasOwn(EVENT_METADATA, event.event)) {
      return "surface" in event && this.matchesWireId(event.surface, surface);
    }
    if (event.event === "notification") {
      return event.surface === surface;
    }
    if (!("surface" in event) || event.surface !== surface) return false;
    return event.event === "browser-state"
      || event.event === "frame"
      || event.event === "detached"
      || event.event === "scroll-changed"
      || this.isSurfaceOverflow(event, surface);
  }

  private matchesWireId(value: unknown, expected: Id): boolean {
    return value === expected
      || (typeof value === "number"
        && Number.isSafeInteger(value)
        && value >= 0
        && BigInt(value) === expected);
  }

  private assertCommandAuthority(command: CmuxCommand): void {
    const required = COMMAND_METADATA[command].authority;
    if (!this.authoritySet.has(required)) {
      throw new CmuxAuthorityError(command, required, this.authorities);
    }
  }

  private resolveAuthorities(
    requested: readonly CmuxAuthority[],
    enableProviderAuthority: boolean,
  ): ReadonlySet<CmuxAuthority> {
    const resolved = new Set<CmuxAuthority>();
    const visit = (authority: CmuxAuthority): void => {
      if (!Object.hasOwn(PROFILES, authority)) {
        throw new RangeError(`unknown cmux authority ${String(authority)}`);
      }
      if (resolved.has(authority)) return;
      resolved.add(authority);
      for (const inherited of PROFILES[authority].inherits) visit(inherited);
    };
    for (const authority of requested) visit(authority);
    if (enableProviderAuthority) visit("provider-authority");
    return resolved;
  }

  private matchesAttachEvent(event: UnknownEvent, surface: Id, mode: "bytes" | "render"): boolean {
    // colors-changed is scoped by its attach connection and intentionally has
    // no surface field in protocol v6. Protocol v7 includes the surface id.
    if (event.event === "colors-changed") {
      return mode === "bytes" && (!("surface" in event) || event.surface === surface);
    }
    if (event.event === "notification") {
      return mode === "bytes" && event.surface === surface;
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

  private streamIdleTimeout(name: string, value: number): number {
    if (!Number.isSafeInteger(value) || value <= 0 || value > 2_147_483_647) {
      throw new RangeError(`${name} must be an integer from 1 through 2147483647`);
    }
    return value;
  }

  private uint64(value: number | bigint, name: string): bigint {
    if (typeof value === "bigint") {
      if (value < 0n || value > ((1n << 64n) - 1n)) {
        throw new RangeError(`${name} must fit uint64`);
      }
      return value;
    }
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new RangeError(`${name} must be a non-negative safe integer or bigint`);
    }
    return BigInt(value);
  }

  private int64(value: number | bigint, name: string): bigint {
    const exact = typeof value === "bigint"
      ? value
      : Number.isSafeInteger(value)
        ? BigInt(value)
        : null;
    if (exact === null || exact < -(1n << 63n) || exact > ((1n << 63n) - 1n)) {
      throw new RangeError(`${name} must be a safe integer or bigint in int64 range`);
    }
    return exact;
  }

  private nextId(): number {
    return this.nextRequestId++;
  }
}
