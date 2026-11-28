import {
  Client,
  CmuxConnectionError,
  CmuxProtocolError,
  CmuxTimeoutError,
  MutationTransportUncertainError,
  StreamError,
  selectCurrent,
  type Browser,
  type BrowserAttachFrame,
  type BrowserAttachItem,
  type BrowserAttachSnapshot,
  type BrowserAttachState,
  type BrowserId,
  type BrowserMouseOptions,
  type BrowserSnapshot,
  type BrowserWheelOptions,
  type CreatedBrowserPath,
  type CreationResolution,
  type DecimalString,
  type PaneId,
  type ScreenId,
  type SelectorInput,
  type SessionId,
  type WorkspaceId,
} from "cmux-sdk/browser";

export type BrowserTab = BrowserSnapshot;

export interface BrowserKeyInput {
  readonly key: string;
  readonly kind?: "down" | "up" | "press";
  readonly modifiers?: readonly ("shift" | "control" | "alt" | "meta")[];
}

export type BrowserWheelInput = BrowserWheelOptions;

export interface BrowserFrameSnapshot {
  readonly browserId: BrowserId;
  readonly sequence: DecimalString;
  readonly pointerFrameSeq: DecimalString | null;
  readonly mimeType: BrowserAttachFrame["mimeType"];
  readonly widthPx: number;
  readonly heightPx: number;
  readonly dataBase64: string;
}

export type BrowserRecoveryReason = "gap" | "connection" | "stream-ended";

export interface BrowserRecovery {
  readonly browserId: BrowserId;
  readonly reason: BrowserRecoveryReason;
  readonly attempt: number;
  readonly browserPresent: boolean;
  readonly tabs: readonly BrowserTab[];
  readonly error?: Error;
}

type MaybePromise<T> = T | Promise<T>;

export interface BrowserObserver {
  onSnapshot?(snapshot: BrowserAttachSnapshot): MaybePromise<void>;
  onState?(state: BrowserAttachState): MaybePromise<void>;
  onFrame?(frame: BrowserFrameSnapshot): MaybePromise<void>;
  onEvent?(event: BrowserAttachItem): MaybePromise<void>;
  onRecovery?(recovery: BrowserRecovery): MaybePromise<void>;
}

export interface FollowBrowserOptions {
  readonly signal?: AbortSignal;
  /** Number of successful resyncs that may lead to another attachment. */
  readonly maxRecoveries?: number;
}

export interface BrowserControllerOptions {
  readonly createClient: () => Client;
  readonly session?: SelectorInput<SessionId>;
  /** Number of fresh clients tried after a command connection fails. */
  readonly commandReconnectAttempts?: number;
  /** Delay between a successful resync and the next attachment. */
  readonly recoveryDelayMs?: number;
  readonly sleep?: (milliseconds: number) => Promise<void>;
}

export interface BrowserLocation {
  readonly workspaceId: WorkspaceId;
  readonly screenId: ScreenId;
  readonly paneId: PaneId;
}

export interface CreateBrowserTabInput {
  readonly location: BrowserLocation;
  readonly url: string;
  readonly name?: string;
  readonly widthPx?: number;
  readonly heightPx?: number;
  readonly correlationKey: string;
  readonly idempotencyKey: string;
}

export interface BrowserCreation {
  readonly path: CreatedBrowserPath;
  readonly browser: Browser;
  readonly generation: string;
  readonly revision: DecimalString;
  /** Undefined when recovered from creation.resolve, which has no replay flag. */
  readonly replayed: boolean | undefined;
  readonly recovered: boolean;
}

export class BrowserCreationRecoveryError extends Error {
  constructor(readonly resolution: CreationResolution) {
    super(
      `browser creation is ${resolution.state}; recovery is ${resolution.recovery}`,
    );
    this.name = "BrowserCreationRecoveryError";
  }
}

/** Browser automation composed only from public cmux resource handles. */
export class BrowserController {
  private readonly createClient: () => Client;
  private readonly sessionSelector: SelectorInput<SessionId>;
  private readonly commandReconnectAttempts: number;
  private readonly recoveryDelayMs: number;
  private readonly sleep: (milliseconds: number) => Promise<void>;
  private client: Client | undefined;
  private closed = false;

  constructor(options: BrowserControllerOptions) {
    this.createClient = options.createClient;
    this.sessionSelector = options.session ?? selectCurrent();
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
    await this.withClient(async () => undefined);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.client?.close();
    this.client = undefined;
  }

  async listBrowserTabs(): Promise<BrowserTab[]> {
    return this.withClient(async (client) => {
      const browsers = await client.session(this.sessionSelector).listBrowsers();
      return browsers.flatMap((browser) => (
        browser.snapshot === undefined ? [] : [browser.snapshot]
      ));
    });
  }

  async findBrowserTab(browserId: BrowserId): Promise<BrowserTab | undefined> {
    return (await this.listBrowserTabs()).find((tab) => tab.id === browserId);
  }

  /**
   * Creates one browser tab and resolves its exact path after an uncertain
   * transport result. Callers own both stable keys.
   */
  async createBrowserTab(
    input: CreateBrowserTabInput,
  ): Promise<BrowserCreation> {
    try {
      const result = await this.withClient((client) => {
        const session = client.session(this.sessionSelector);
        const pane = session
          .workspace(input.location.workspaceId)
          .screen(input.location.screenId)
          .pane(input.location.paneId);
        return pane.createBrowserTab({
          url: input.url,
          ...(input.name === undefined ? {} : { name: input.name }),
          ...(input.widthPx === undefined ? {} : { widthPx: input.widthPx }),
          ...(input.heightPx === undefined ? {} : { heightPx: input.heightPx }),
        }, {
          correlationKey: input.correlationKey,
          idempotencyKey: input.idempotencyKey,
        });
      });
      return browserCreation(
        result.value,
        result.generation,
        result.revision,
        result.replayed,
        false,
      );
    } catch (error) {
      if (!(error instanceof MutationTransportUncertainError)) throw error;
      if (
        error.operation !== "tab.create_browser"
        || error.idempotencyKey !== input.idempotencyKey
      ) {
        throw error;
      }
      const resolution = await this.withClient((client) => (
        client
          .session(this.sessionSelector)
          .creation
          .resolve(input.correlationKey)
      ));
      if (resolution.state !== "created") {
        throw new BrowserCreationRecoveryError(resolution);
      }
      if (
        resolution.operation !== undefined
        && resolution.operation !== "tab.create_browser"
      ) {
        throw new CmuxProtocolError(
          `browser correlation resolved to ${resolution.operation}`,
        );
      }
      if (resolution.createdPath.kind !== "browser") {
        throw new CmuxProtocolError(
          `tab.create_browser recovery returned a ${resolution.createdPath.kind} created path`,
        );
      }
      return browserCreation(
        resolution.createdPath,
        resolution.generation,
        resolution.revision,
        undefined,
        true,
      );
    }
  }

  async navigate(browserId: BrowserId, url: string): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.navigate(url));
  }

  async reload(browserId: BrowserId): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.reload());
  }

  async back(browserId: BrowserId): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.back());
  }

  async forward(browserId: BrowserId): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.forward());
  }

  async activate(browserId: BrowserId): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.activate());
  }

  async insertText(browserId: BrowserId, text: string): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.text(text));
  }

  async key(browserId: BrowserId, input: BrowserKeyInput): Promise<void> {
    await this.withBrowser(
      browserId,
      (browser) => browser.key(input.key, {
        ...(input.kind === undefined ? {} : { kind: input.kind }),
        ...(input.modifiers === undefined ? {} : { modifiers: input.modifiers }),
      }),
    );
  }

  async mouse(browserId: BrowserId, input: BrowserMouseOptions): Promise<void> {
    await this.withBrowser(browserId, (browser) => browser.mouse(input));
  }

  async wheel(browserId: BrowserId, input: BrowserWheelInput): Promise<void> {
    await this.withBrowser(
      browserId,
      (browser) => browser.wheel(input),
    );
  }

  /**
   * Follow typed browser snapshots, state, and frames until aborted or removed.
   *
   * A stream gap or connection loss causes a browser-list resync. The same
   * browser is reattached only when its typed ID remains present.
   */
  async followBrowser(
    browserId: BrowserId,
    observer: BrowserObserver,
    options: FollowBrowserOptions = {},
  ): Promise<void> {
    const maximum = recoveryLimit(options.maxRecoveries);
    let recoveries = 0;

    while (!options.signal?.aborted) {
      let reason: BrowserRecoveryReason = "stream-ended";
      let recoveryError: Error | undefined;
      try {
        const stream = await this.withClient((client) => (
          client
            .session(this.sessionSelector)
            .browser(browserId)
            .attach({ signal: options.signal })
        ));
        for await (const item of stream) {
          const event = item.value;
          await observer.onEvent?.(event);
          if (isAttachSnapshot(event)) {
            await observer.onSnapshot?.(event);
          } else if (isAttachState(event)) {
            await observer.onState?.(event);
          } else if (isAttachFrame(event)) {
            await observer.onFrame?.({
              browserId,
              sequence: item.sequence,
              pointerFrameSeq: event.pointerFrameSeq,
              mimeType: event.mimeType,
              widthPx: event.widthPx,
              heightPx: event.heightPx,
              dataBase64: event.dataBase64,
            });
          }
        }
        if (options.signal?.aborted) return;
        reason = stream.end?.reason === "gap" ? "gap" : "stream-ended";
      } catch (error) {
        if (options.signal?.aborted) return;
        if (!isRecoverable(error) && !(error instanceof StreamError)) throw error;
        reason = error instanceof StreamError && error.reason === "gap"
          ? "gap"
          : "connection";
        recoveryError = asError(error);
        if (this.client?.closed) this.client = undefined;
      }

      const tabs = await this.listBrowserTabs();
      const browserPresent = tabs.some((tab) => tab.id === browserId);
      const attempt = recoveries + 1;
      await observer.onRecovery?.({
        browserId,
        reason,
        attempt,
        browserPresent,
        tabs,
        ...(recoveryError === undefined ? {} : { error: recoveryError }),
      });
      if (!browserPresent) return;
      if (recoveries >= maximum) {
        throw new Error(`browser attachment exceeded ${maximum} recoveries`);
      }
      recoveries += 1;
      if (this.recoveryDelayMs > 0) await this.sleep(this.recoveryDelayMs);
    }
  }

  private async withBrowser(
    browserId: BrowserId,
    operation: (browser: Browser) => Promise<unknown>,
  ): Promise<void> {
    await this.withClient(async (client) => {
      await operation(client.session(this.sessionSelector).browser(browserId));
    });
  }

  private async withClient<T>(
    operation: (client: Client) => Promise<T>,
  ): Promise<T> {
    let lastError: unknown;
    for (
      let attempt = 0;
      attempt <= this.commandReconnectAttempts;
      attempt += 1
    ) {
      const client = this.getClient();
      try {
        return await operation(client);
      } catch (error) {
        lastError = error;
        if (!isRecoverable(error) || attempt === this.commandReconnectAttempts) {
          throw error;
        }
        this.invalidate(client);
      }
    }
    throw lastError;
  }

  private getClient(): Client {
    if (this.closed) {
      throw new CmuxConnectionError("browser controller is closed");
    }
    if (this.client?.closed) this.client = undefined;
    this.client ??= this.createClient();
    return this.client;
  }

  private invalidate(client: Client): void {
    if (this.client === client) this.client = undefined;
    client.close();
  }
}

function browserCreation(
  path: CreatedBrowserPath,
  generation: string,
  revision: DecimalString,
  replayed: boolean | undefined,
  recovered: boolean,
): BrowserCreation {
  return Object.freeze({
    path,
    browser: path.browser,
    generation,
    revision,
    replayed,
    recovered,
  });
}

export function browserTabsFromSnapshots(
  snapshots: readonly BrowserSnapshot[],
): BrowserTab[] {
  return [...snapshots];
}

function isAttachSnapshot(
  event: BrowserAttachItem,
): event is BrowserAttachSnapshot {
  return event.kind === "snapshot" && "browser" in event;
}

function isAttachState(event: BrowserAttachItem): event is BrowserAttachState {
  return event.kind === "state" && "url" in event;
}

function isAttachFrame(event: BrowserAttachItem): event is BrowserAttachFrame {
  return event.kind === "frame" && "dataBase64" in event;
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

function recoveryLimit(value: number | undefined): number {
  if (value === undefined) return Number.POSITIVE_INFINITY;
  return nonNegativeInteger("maxRecoveries", value);
}
