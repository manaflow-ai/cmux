import assert from "node:assert/strict";
import test from "node:test";
import {
  Client,
  CmuxConnectionError,
  MAX_STREAM_MESSAGES,
  browserId,
  decimalString,
  paneId,
  screenId,
  tabId,
  workspaceId,
  type BrowserSnapshot,
  type Transport,
  type Unsubscribe,
} from "cmux-sdk/browser";
import {
  BrowserController,
  browserTabsFromSnapshots,
  type BrowserFrameSnapshot,
  type BrowserRecovery,
} from "../src/index.js";

const BROWSER_ID = "browser_" + "1".repeat(32);
const TAB_ID = "tab_" + "2".repeat(32);
const STREAM_ID = "stream_" + "a".repeat(32);
const WORKSPACE_ID = "ws_" + "4".repeat(32);
const SCREEN_ID = "screen_" + "5".repeat(32);
const PANE_ID = "pane_" + "6".repeat(32);
const GENERATION = "fake-generation";

class FakeTransport implements Transport {
  private readonly messages = new Set<(json: string) => void>();
  private readonly closes = new Set<() => void>();
  private readonly errors = new Set<(error: Error) => void>();
  closed = false;

  constructor(
    private readonly receive: (
      transport: FakeTransport,
      request: Record<string, unknown>,
    ) => void,
  ) {}

  send(json: string): void {
    this.receive(this, JSON.parse(json) as Record<string, unknown>);
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.messages.add(handler);
    return () => this.messages.delete(handler);
  }

  onClose(handler: () => void): Unsubscribe {
    this.closes.add(handler);
    return () => this.closes.delete(handler);
  }

  onError(handler: (error: Error) => void): Unsubscribe {
    this.errors.add(handler);
    return () => this.errors.delete(handler);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const handler of this.closes) handler();
  }

  respond(request: Record<string, unknown>, result: unknown): void {
    this.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: true,
      result,
    });
  }

  stream(
    streamId: string,
    sequence: string,
    item: Record<string, unknown>,
  ): void {
    this.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: streamId,
      sequence,
      item,
    });
  }

  end(
    streamId: string,
    reason: "completed" | "canceled" | "gap",
    recovery?: string,
  ): void {
    this.emit({
      protocol: "cmux.protocol/2",
      type: "stream_end",
      stream_id: streamId,
      reason,
      ...(recovery === undefined ? {} : { recovery }),
    });
  }

  fail(error: Error): void {
    for (const handler of this.errors) handler(error);
  }

  private emit(value: unknown): void {
    const json = JSON.stringify(value);
    for (const handler of this.messages) handler(json);
  }
}

class BrowserServer {
  readonly requests: Array<Record<string, unknown>> = [];
  attachAttempts = 0;

  constructor(
    private readonly attachmentMode: "normal" | "hold" | "overflow" = "normal",
  ) {}

  client(): Client {
    return new Client({
      transport: new FakeTransport((transport, request) => {
        this.handle(transport, request);
      }),
      timeoutMs: 100,
      randomHex128: () => "a".repeat(32),
    });
  }

  private handle(
    transport: FakeTransport,
    request: Record<string, unknown>,
  ): void {
    this.requests.push(request);
    const operation = String(request.operation);
    const params = request.params as Record<string, unknown>;
    switch (operation) {
      case "browser.list":
        transport.respond(
          request,
          this.attachmentMode !== "overflow" && this.attachAttempts < 2
            ? [browserSnapshot()]
            : [],
        );
        return;
      case "browser.attach": {
        this.attachAttempts += 1;
        const streamId = String(params.stream_id);
        transport.respond(request, {
          stream_id: streamId,
          attachment_lease: `browser-lease-${this.attachAttempts}`,
        });
        if (this.attachmentMode === "hold") {
          transport.stream(streamId, "1", {
            kind: "snapshot",
            browser: browserSnapshot(),
            size: { width_px: 1200, height_px: 800 },
          });
          return;
        }
        if (this.attachmentMode === "overflow") {
          for (let index = 0; index <= MAX_STREAM_MESSAGES; index += 1) {
            transport.stream(streamId, String(index + 1), {
              kind: "state",
              url: `https://cmux.dev/${index}`,
              title: "overflow",
              loading: false,
            });
          }
          return;
        }
        if (this.attachAttempts === 1) {
          transport.stream(streamId, "1", {
            kind: "snapshot",
            browser: browserSnapshot(),
            size: { width_px: 1200, height_px: 800 },
          });
          transport.stream(streamId, "2", {
            kind: "frame",
            mime_type: "image/png",
            data_base64: "ZnJhbWU=",
            width_px: 1200,
            height_px: 800,
            pointer_frame_seq: "41",
          });
          transport.end(
            streamId,
            "gap",
            "reopen the stream to obtain a fresh snapshot",
          );
        } else {
          transport.stream(streamId, "3", {
            kind: "state",
            url: "https://cmux.dev/updated",
            title: "updated",
            loading: false,
          });
          transport.end(streamId, "completed");
        }
        return;
      }
      case "browser.navigate":
      case "browser.back":
      case "browser.forward":
      case "browser.reload":
      case "browser.activate":
        transport.respond(request, mutation(browserSnapshot()));
        return;
      case "browser.input.text":
      case "browser.input.key":
      case "browser.input.mouse":
      case "browser.input.wheel":
        transport.respond(request, mutation({}));
        return;
      case "tab.create_browser":
        transport.respond(request, mutation(browserCreatedPath()));
        return;
      case "stream.cancel": {
        transport.respond(request, {});
        transport.end(String(params.stream), "canceled");
        return;
      }
      default:
        throw new Error(`unexpected operation ${operation}`);
    }
  }
}

test("maps the typed browser snapshots without legacy surface IDs", () => {
  const snapshot = browserSnapshot();
  const tabs = browserTabsFromSnapshots([
    {
      id: browserId(BROWSER_ID),
      tabId: tabId(TAB_ID),
      url: String(snapshot.url),
      title: String(snapshot.title),
      loading: false,
      source: "launched",
      status: "live",
      error: null,
      framesStalled: false,
      size: { cols: 120, rows: 40 },
      extra: {},
    } satisfies BrowserSnapshot,
  ]);
  assert.equal(tabs[0]?.id, BROWSER_ID);
  assert.equal(tabs[0]?.tabId, TAB_ID);
});

test("drives every browser control through public resource handles", async () => {
  const server = new BrowserServer();
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });
  const id = browserId(BROWSER_ID);
  const pointerFrameSeq = decimalString("41");

  assert.equal((await controller.listBrowserTabs())[0]?.id, id);
  await controller.navigate(id, "https://example.com");
  await controller.reload(id);
  await controller.back(id);
  await controller.forward(id);
  await controller.activate(id);
  await controller.insertText(id, "hello");
  await controller.key(id, {
    kind: "press",
    key: "Enter",
    modifiers: ["shift"],
  });
  await controller.mouse(id, {
    kind: "down",
    xPx: 10,
    yPx: 20,
    button: "left",
    clickCount: 1,
    pointerFrameSeq,
  });
  await controller.wheel(id, {
    xPx: 10,
    yPx: 20,
    deltaX: 0,
    deltaY: -120,
    pointerFrameSeq,
  });

  assert.deepEqual(
    server.requests.map((request) => request.operation),
    [
      "browser.list",
      "browser.navigate",
      "browser.reload",
      "browser.back",
      "browser.forward",
      "browser.activate",
      "browser.input.text",
      "browser.input.key",
      "browser.input.mouse",
      "browser.input.wheel",
    ],
  );
  const key = server.requests[7]?.params as Record<string, unknown>;
  const mouse = server.requests[8]?.params as Record<string, unknown>;
  const wheel = server.requests[9]?.params as Record<string, unknown>;
  assert.deepEqual(key.modifiers, ["shift"]);
  assert.equal(mouse.click_count, 1);
  assert.equal(mouse.pointer_frame_seq, pointerFrameSeq);
  assert.equal(wheel.delta_y, -120);
  assert.equal(wheel.pointer_frame_seq, pointerFrameSeq);
  await controller.close();
});

test("creates a browser tab with explicit correlation and idempotency", async () => {
  const server = new BrowserServer();
  const controller = new BrowserController({
    createClient: () => server.client(),
  });
  const creation = await controller.createBrowserTab({
    location: {
      workspaceId: workspaceId(WORKSPACE_ID),
      screenId: screenId(SCREEN_ID),
      paneId: paneId(PANE_ID),
    },
    url: "https://example.com",
    name: "docs",
    widthPx: 1200,
    heightPx: 800,
    correlationKey: "browser-docs",
    idempotencyKey: "browser-docs-attempt-1",
  });

  assert.equal(creation.recovered, false);
  assert.equal(creation.replayed, false);
  assert.equal(creation.browser.id, BROWSER_ID);
  assert.equal(creation.path.tab.id, TAB_ID);
  const request = server.requests[0];
  assert.equal(request?.operation, "tab.create_browser");
  assert.equal(request?.idempotency_key, "browser-docs-attempt-1");
  const params = request?.params as Record<string, unknown>;
  assert.equal(params.correlation_key, "browser-docs");
  assert.equal(params.workspace, WORKSPACE_ID);
  assert.equal(params.screen, SCREEN_ID);
  assert.equal(params.pane, PANE_ID);
  await controller.close();
});

test("resolves a correlated browser path after losing the create response", async () => {
  const requests: Array<Record<string, unknown>> = [];
  let clients = 0;
  const controller = new BrowserController({
    createClient: () => {
      clients += 1;
      const ordinal = clients;
      return new Client({
        timeoutMs: 100,
        randomHex128: () => `${ordinal}`.repeat(32),
        transport: new FakeTransport((transport, request) => {
          requests.push(request);
          if (ordinal === 1 && request.operation === "tab.create_browser") {
            transport.fail(new CmuxConnectionError("create response lost"));
            return;
          }
          if (
            ordinal === 2
            && request.operation === "session.creation.resolve"
          ) {
            transport.respond(request, {
              correlation_key: "recovered-browser",
              state: "created",
              recovery: "none",
              operation: "tab.create_browser",
              idempotency_key: "recovered-browser-attempt-1",
              created_path: browserCreatedPath(),
              generation: GENERATION,
              revision: "9",
            });
            return;
          }
          throw new Error(`unexpected operation ${String(request.operation)}`);
        }),
      });
    },
  });

  const creation = await controller.createBrowserTab({
    location: {
      workspaceId: workspaceId(WORKSPACE_ID),
      screenId: screenId(SCREEN_ID),
      paneId: paneId(PANE_ID),
    },
    url: "https://cmux.dev",
    correlationKey: "recovered-browser",
    idempotencyKey: "recovered-browser-attempt-1",
  });

  assert.equal(clients, 2);
  assert.equal(creation.recovered, true);
  assert.equal(creation.replayed, undefined);
  assert.equal(creation.browser.id, BROWSER_ID);
  assert.deepEqual(
    requests.map((request) => request.operation),
    ["tab.create_browser", "session.creation.resolve"],
  );
  assert.equal(requests[0]?.idempotency_key, "recovered-browser-attempt-1");
  assert.equal(
    (requests[1]?.params as Record<string, unknown>).correlation_key,
    "recovered-browser",
  );
  await controller.close();
});

test("resyncs after a gap and stops when the browser disappears", async () => {
  const server = new BrowserServer();
  const frames: BrowserFrameSnapshot[] = [];
  const recoveries: BrowserRecovery[] = [];
  const states: string[] = [];
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });

  await controller.followBrowser(browserId(BROWSER_ID), {
    onState: (state) => {
      states.push(state.url);
    },
    onFrame: (frame) => {
      frames.push(frame);
    },
    onRecovery: (recovery) => {
      recoveries.push(recovery);
    },
  }, { maxRecoveries: 2 });

  assert.deepEqual(states, ["https://cmux.dev/updated"]);
  assert.deepEqual(
    frames.map(({ sequence, pointerFrameSeq, mimeType }) => ({
      sequence,
      pointerFrameSeq,
      mimeType,
    })),
    [{
      sequence: "2",
      pointerFrameSeq: "41",
      mimeType: "image/png",
    }],
  );
  assert.deepEqual(
    recoveries.map(({ reason, attempt, browserPresent }) => ({
      reason,
      attempt,
      browserPresent,
    })),
    [
      { reason: "gap", attempt: 1, browserPresent: true },
      { reason: "stream-ended", attempt: 2, browserPresent: false },
    ],
  );
  assert.equal(server.attachAttempts, 2);
  await controller.close();
});

test("replaces a failed command client with a fresh resource client", async () => {
  let clients = 0;
  const controller = new BrowserController({
    createClient: () => {
      clients += 1;
      const ordinal = clients;
      return new Client({
        timeoutMs: 100,
        randomHex128: () => "b".repeat(32),
        transport: new FakeTransport((transport, request) => {
          if (request.operation !== "browser.list") return;
          if (ordinal === 1) {
            transport.fail(new CmuxConnectionError("socket reset"));
          } else {
            transport.respond(request, [browserSnapshot()]);
          }
        }),
      });
    },
    commandReconnectAttempts: 1,
  });

  assert.equal((await controller.listBrowserTabs())[0]?.id, BROWSER_ID);
  assert.equal(clients, 2);
  await controller.close();
});

test("AbortSignal cancels a live browser attachment", async () => {
  const server = new BrowserServer("hold");
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });
  const abort = new AbortController();

  await controller.followBrowser(browserId(BROWSER_ID), {
    onSnapshot: () => abort.abort(),
  }, { signal: abort.signal });

  assert.deepEqual(
    server.requests.map((request) => request.operation),
    ["browser.attach", "stream.cancel"],
  );
  assert.equal(
    (server.requests[1]?.params as Record<string, unknown>).stream,
    STREAM_ID,
  );
  await controller.close();
});

test("bounded SDK stream purges overflow and resyncs from a snapshot", async () => {
  const server = new BrowserServer("overflow");
  const recoveries: BrowserRecovery[] = [];
  let delivered = 0;
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });

  await controller.followBrowser(browserId(BROWSER_ID), {
    onEvent: () => {
      delivered += 1;
    },
    onRecovery: (recovery) => {
      recoveries.push(recovery);
    },
  }, { maxRecoveries: 1 });

  assert.equal(delivered, 0);
  assert.deepEqual(
    recoveries.map(({ reason, browserPresent }) => ({
      reason,
      browserPresent,
    })),
    [{ reason: "gap", browserPresent: false }],
  );
  assert.deepEqual(
    server.requests.map((request) => request.operation),
    ["browser.attach", "stream.cancel", "browser.list"],
  );
  await controller.close();
});

function browserSnapshot(): Record<string, unknown> {
  return {
    id: BROWSER_ID,
    tab_id: TAB_ID,
    url: "https://cmux.dev",
    title: "cmux docs",
    loading: false,
    source: "launched",
    status: "live",
    error: null,
    frames_stalled: false,
    size: { cols: 120, rows: 40 },
  };
}

function browserCreatedPath(): Record<string, unknown> {
  return {
    kind: "browser",
    workspace_id: WORKSPACE_ID,
    screen_id: SCREEN_ID,
    pane_id: PANE_ID,
    tab_id: TAB_ID,
    browser_id: BROWSER_ID,
  };
}

function mutation(value: unknown): Record<string, unknown> {
  return {
    value,
    generation: GENERATION,
    revision: "2",
    replayed: false,
  };
}
