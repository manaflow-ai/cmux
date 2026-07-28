import {
  CmuxClient,
  CmuxConnectionError,
  CmuxTimeoutError,
  type BrowserStateEvent,
  type CmuxRequestParams,
  type DecodedAttachEvent,
  type FrameEvent,
  type Id,
  type Tree,
} from "cmux/browser";

export interface BrowserTab {
  surface: Id;
  workspace: Id;
  workspaceName: string;
  screen: Id;
  screenName: string | null;
  pane: Id;
  paneName: string | null;
  tabIndex: number;
  active: boolean;
  title: string;
  name: string | null;
  status: "starting" | "live" | "failed" | null;
  error: string | null;
  framesStalled: boolean | null;
  source: "external" | "launched" | null;
}

export type BrowserKeyInput = Omit<CmuxRequestParams<"browser-key">, "surface">;
export type BrowserMouseInput = Omit<CmuxRequestParams<"browser-mouse">, "surface">;
export type BrowserWheelInput = Omit<CmuxRequestParams<"browser-wheel">, "surface">;

export interface BrowserFrameSnapshot {
  surface: Id;
  sequence: bigint;
  width: number;
  height: number;
  /** The protocol's base64-encoded browser frame. Its image encoding is not identified by the SDK. */
  data: string;
  source: "initial-state" | "frame-event";
}

export type BrowserRecoveryReason =
  | "overflow"
  | "detached"
  | "connection"
  | "stream-ended";

export interface BrowserRecovery {
  surface: Id;
  reason: BrowserRecoveryReason;
  attempt: number;
  surfacePresent: boolean;
  tabs: readonly BrowserTab[];
  error?: Error;
}

type MaybePromise<T> = T | Promise<T>;

export interface BrowserObserver {
  onState?(state: BrowserStateEvent): MaybePromise<void>;
  onFrame?(frame: BrowserFrameSnapshot): MaybePromise<void>;
  onEvent?(event: DecodedAttachEvent): MaybePromise<void>;
  onRecovery?(recovery: BrowserRecovery): MaybePromise<void>;
}

export interface FollowBrowserOptions {
  signal?: AbortSignal;
  /** Number of successful resyncs that may lead to another attachment. */
  maxRecoveries?: number;
  /** A read timeout is treated as an idle tick, not a failed attachment. */
  idleReadTimeoutMs?: number;
}

export interface BrowserControllerOptions {
  createClient(): CmuxClient;
  /** Number of fresh command connections tried after the first connection fails. */
  commandReconnectAttempts?: number;
  /** Delay between a successful resync and the next attachment. */
  recoveryDelayMs?: number;
  sleep?(milliseconds: number): Promise<void>;
}

const DEFAULT_IDLE_READ_TIMEOUT_MS = 30_000;

/**
 * Portable browser controller built exclusively from the published `cmux/browser` API.
 *
 * The factory must return a fresh client because a closed `CmuxClient` cannot reconnect.
 */
export class BrowserController {
  private readonly createClient: () => CmuxClient;
  private readonly commandReconnectAttempts: number;
  private readonly recoveryDelayMs: number;
  private readonly sleep: (milliseconds: number) => Promise<void>;
  private client: CmuxClient | undefined;
  private pendingClient: Promise<CmuxClient> | undefined;
  private closed = false;

  constructor(options: BrowserControllerOptions) {
    this.createClient = options.createClient;
    this.commandReconnectAttempts = nonNegativeInteger(
      "commandReconnectAttempts",
      options.commandReconnectAttempts ?? 1,
    );
    this.recoveryDelayMs = nonNegativeInteger(
      "recoveryDelayMs",
      options.recoveryDelayMs ?? 250,
    );
    this.sleep = options.sleep ?? ((milliseconds) => new Promise((resolve) => {
      setTimeout(resolve, milliseconds);
    }));
  }

  async connect(): Promise<void> {
    await this.getClient();
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    const pending = this.pendingClient;
    const active = this.client;
    this.client = undefined;
    if (active) await active.close();
    if (pending) {
      const candidate = await pending.catch(() => undefined);
      if (candidate && candidate !== active) await candidate.close();
    }
  }

  async listBrowserTabs(): Promise<BrowserTab[]> {
    const tree = await this.withClient((client) => client.listWorkspaces());
    return browserTabsFromTree(tree);
  }

  async findBrowserTab(surface: Id): Promise<BrowserTab | undefined> {
    return (await this.listBrowserTabs()).find((tab) => tab.surface === surface);
  }

  async navigate(surface: Id, url: string): Promise<void> {
    await this.withClient((client) => client.browserNavigate({ surface, url }));
  }

  async reload(surface: Id): Promise<void> {
    await this.withClient((client) => client.browserReload({ surface }));
  }

  async back(surface: Id): Promise<void> {
    await this.withClient((client) => client.browserBack({ surface }));
  }

  async forward(surface: Id): Promise<void> {
    await this.withClient((client) => client.browserForward({ surface }));
  }

  async activate(surface: Id): Promise<void> {
    await this.withClient((client) => client.browserActivate({ surface }));
  }

  async insertText(surface: Id, text: string): Promise<void> {
    await this.withClient((client) => client.browserInsertText({ surface, text }));
  }

  async key(surface: Id, input: BrowserKeyInput): Promise<void> {
    await this.withClient((client) => client.browserKey({ surface, ...input }));
  }

  async mouse(surface: Id, input: BrowserMouseInput): Promise<void> {
    await this.withClient((client) => client.browserMouse({ surface, ...input }));
  }

  async wheel(surface: Id, input: BrowserWheelInput): Promise<void> {
    await this.withClient((client) => client.browserWheel({ surface, ...input }));
  }

  /**
   * Follows browser state and frames until aborted or the surface disappears.
   *
   * A surface overflow or detach causes a tree resync. If the same browser surface
   * still exists, a fresh attachment is opened. Connection loss follows the same path.
   */
  async followBrowser(
    surface: Id,
    observer: BrowserObserver,
    options: FollowBrowserOptions = {},
  ): Promise<void> {
    const maximum = recoveryLimit(options.maxRecoveries);
    const idleReadTimeoutMs = positiveInteger(
      "idleReadTimeoutMs",
      options.idleReadTimeoutMs ?? DEFAULT_IDLE_READ_TIMEOUT_MS,
    );
    let recoveries = 0;

    while (!options.signal?.aborted) {
      let stream: Awaited<ReturnType<CmuxClient["attachSurface"]>> | undefined;
      let reason: BrowserRecoveryReason | undefined;
      let recoveryError: Error | undefined;
      const abort = () => stream?.close();
      options.signal?.addEventListener("abort", abort, { once: true });

      try {
        stream = await this.withClient((client) => client.attachSurface(surface));
        while (!options.signal?.aborted) {
          let event: DecodedAttachEvent;
          try {
            event = await stream.next(idleReadTimeoutMs);
          } catch (error) {
            if (error instanceof CmuxTimeoutError) continue;
            throw error;
          }

          await observer.onEvent?.(event);
          if (isBrowserStateEvent(event)) {
            await observer.onState?.(event);
            if (event.frame) {
              await observer.onFrame?.({
                surface: event.surface,
                sequence: event.frame.seq,
                width: event.frame.width,
                height: event.frame.height,
                data: event.frame.data,
                source: "initial-state",
              });
            }
          } else if (isFrameEvent(event)) {
            await observer.onFrame?.({
              surface: event.surface,
              sequence: event.seq,
              width: event.width,
              height: event.height,
              data: event.data,
              source: "frame-event",
            });
          }

          if (event.event === "overflow") {
            reason = "overflow";
            break;
          }
          if (event.event === "detached") {
            reason = "detached";
            break;
          }
        }
        if (options.signal?.aborted) return;
        reason ??= "stream-ended";
      } catch (error) {
        if (options.signal?.aborted) return;
        if (!isRecoverable(error)) throw error;
        reason = "connection";
        recoveryError = asError(error);
      } finally {
        options.signal?.removeEventListener("abort", abort);
        stream?.close();
      }

      const tabs = await this.listBrowserTabs();
      const surfacePresent = tabs.some((tab) => tab.surface === surface);
      const attempt = recoveries + 1;
      await observer.onRecovery?.({
        surface,
        reason,
        attempt,
        surfacePresent,
        tabs,
        ...(recoveryError ? { error: recoveryError } : {}),
      });
      if (!surfacePresent) return;
      if (recoveries >= maximum) {
        throw new Error(`browser attachment exceeded ${maximum} recoveries`);
      }
      recoveries += 1;
      if (this.recoveryDelayMs > 0) await this.sleep(this.recoveryDelayMs);
    }
  }

  private async withClient<T>(operation: (client: CmuxClient) => Promise<T>): Promise<T> {
    let lastError: unknown;
    for (let attempt = 0; attempt <= this.commandReconnectAttempts; attempt += 1) {
      let client: CmuxClient | undefined;
      try {
        client = await this.getClient();
        return await operation(client);
      } catch (error) {
        lastError = error;
        if (!isRecoverable(error) || attempt === this.commandReconnectAttempts) throw error;
        if (client) await this.invalidate(client);
      }
    }
    throw lastError;
  }

  private async getClient(): Promise<CmuxClient> {
    if (this.closed) throw new CmuxConnectionError("browser controller is closed");
    if (this.client) return this.client;
    if (this.pendingClient) return this.pendingClient;

    const candidate = this.createClient();
    const pending = (async () => {
      try {
        await candidate.identify();
        if (this.closed) {
          await candidate.close();
          throw new CmuxConnectionError("browser controller is closed");
        }
        this.client = candidate;
        return candidate;
      } catch (error) {
        await candidate.close().catch(() => undefined);
        throw error;
      }
    })();
    this.pendingClient = pending;
    try {
      return await pending;
    } finally {
      if (this.pendingClient === pending) this.pendingClient = undefined;
    }
  }

  private async invalidate(client: CmuxClient): Promise<void> {
    if (this.client === client) this.client = undefined;
    await client.close().catch(() => undefined);
  }
}

export function browserTabsFromTree(tree: Tree): BrowserTab[] {
  const result: BrowserTab[] = [];
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if (!("tabs" in pane)) continue;
        pane.tabs.forEach((tab, tabIndex) => {
          if (tab.kind !== "browser") return;
          result.push({
            surface: tab.surface,
            workspace: workspace.id,
            workspaceName: workspace.name,
            screen: screen.id,
            screenName: screen.name,
            pane: pane.id,
            paneName: pane.name,
            tabIndex,
            active: workspace.active
              && screen.active
              && pane.active_tab === BigInt(tabIndex),
            title: tab.title,
            name: tab.name,
            status: tab.browser_status ?? null,
            error: tab.browser_error ?? null,
            framesStalled: tab.browser_frames_stalled ?? null,
            source: tab.browser_source,
          });
        });
      }
    }
  }
  return result;
}

export function isBrowserStateEvent(event: DecodedAttachEvent): event is BrowserStateEvent {
  if (event.event !== "browser-state") return false;
  const value = event as Record<string, unknown>;
  return typeof value.surface === "bigint"
    && typeof value.url === "string"
    && typeof value.title === "string"
    && typeof value.cols === "number"
    && typeof value.rows === "number"
    && typeof value.frames_stalled === "boolean"
    && (value.status === "starting" || value.status === "live" || value.status === "failed");
}

export function isFrameEvent(event: DecodedAttachEvent): event is FrameEvent {
  if (event.event !== "frame") return false;
  const value = event as Record<string, unknown>;
  return typeof value.surface === "bigint"
    && typeof value.seq === "bigint"
    && typeof value.width === "number"
    && typeof value.height === "number"
    && typeof value.data === "string";
}

function isRecoverable(error: unknown): boolean {
  return error instanceof CmuxConnectionError || error instanceof CmuxTimeoutError;
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function nonNegativeInteger(name: string, value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative safe integer`);
  }
  return value;
}

function positiveInteger(name: string, value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > 2_147_483_647) {
    throw new RangeError(`${name} must be an integer from 1 through 2147483647`);
  }
  return value;
}

function recoveryLimit(value: number | undefined): number {
  if (value === undefined) return Number.POSITIVE_INFINITY;
  return nonNegativeInteger("maxRecoveries", value);
}
