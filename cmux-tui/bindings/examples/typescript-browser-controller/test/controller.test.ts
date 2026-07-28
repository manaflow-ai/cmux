import assert from "node:assert/strict";
import test from "node:test";
import {
  CmuxClient,
  parseWireJson,
  stringifyWireJson,
  type Tab,
  type Transport,
  type Tree,
  type Unsubscribe,
} from "cmux/browser";
import {
  BrowserController,
  browserTabsFromTree,
  type BrowserFrameSnapshot,
  type BrowserRecovery,
} from "../src/index.js";

class FakeTransport implements Transport {
  private readonly messages = new Set<(json: string) => void>();
  private readonly closes = new Set<() => void>();
  private readonly errors = new Set<(error: Error) => void>();
  closed = false;

  constructor(
    private readonly receive: (transport: FakeTransport, request: Record<string, unknown>) => void,
  ) {}

  send(json: string): void {
    this.receive(this, parseWireJson(json) as Record<string, unknown>);
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

  respond(id: unknown, data: unknown): void {
    this.emit({ id, ok: true, data });
  }

  event(event: Record<string, unknown>): void {
    this.emit(event);
  }

  fail(error: Error): void {
    for (const handler of this.errors) handler(error);
  }

  private emit(value: unknown): void {
    const json = stringifyWireJson(value);
    for (const handler of this.messages) handler(json);
  }
}

class BrowserServer {
  readonly requests: Array<Record<string, unknown>> = [];
  attachAttempts = 0;

  client(): CmuxClient {
    return new CmuxClient({
      transport: new FakeTransport((transport, request) => this.handle(transport, request)),
      streamTransportFactory: () => new FakeTransport(
        (transport, request) => this.handle(transport, request),
      ),
      timeoutMs: 100,
    });
  }

  private handle(transport: FakeTransport, request: Record<string, unknown>): void {
    this.requests.push(request);
    switch (request.cmd) {
      case "identify":
        transport.respond(request.id, identifyResult());
        return;
      case "list-workspaces":
        transport.respond(request.id, workspaceTree(this.attachAttempts < 2));
        return;
      case "attach-surface":
        this.attachAttempts += 1;
        if (this.attachAttempts === 1) {
          transport.event(browserState(1n));
          transport.event(frameEvent(2n));
          transport.event({
            event: "overflow",
            scope: "surface",
            surface: 42n,
            error: "consumer fell behind",
          });
        } else {
          transport.event(browserState(3n));
          transport.event({ event: "detached", surface: 42n });
        }
        transport.respond(request.id, {});
        return;
      case "browser-navigate":
      case "browser-reload":
      case "browser-back":
      case "browser-forward":
      case "browser-activate":
      case "browser-insert-text":
      case "browser-key":
      case "browser-mouse":
      case "browser-wheel":
        transport.respond(request.id, {});
        return;
      default:
        throw new Error(`unexpected command ${String(request.cmd)}`);
    }
  }
}

test("discovers browser tabs without exposing PTY tabs or dead panes", () => {
  const tabs = browserTabsFromTree(workspaceTree(true));
  assert.equal(tabs.length, 1);
  assert.deepEqual(tabs[0], {
    surface: 42n,
    workspace: 1n,
    workspaceName: "sdk examples",
    screen: 2n,
    screenName: "browser",
    pane: 3n,
    paneName: "web",
    tabIndex: 1,
    active: true,
    title: "cmux docs",
    name: "docs",
    status: "live",
    error: null,
    framesStalled: false,
    source: "launched",
  });
});

test("drives every browser control through typed public methods", async () => {
  const server = new BrowserServer();
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });

  assert.equal((await controller.listBrowserTabs())[0]?.surface, 42n);
  await controller.navigate(42n, "https://example.com");
  await controller.reload(42n);
  await controller.back(42n);
  await controller.forward(42n);
  await controller.activate(42n);
  await controller.insertText(42n, "hello");
  await controller.key(42n, {
    kind: "down",
    key: "Enter",
    code: "Enter",
    windows_virtual_key_code: 13,
    modifiers: 0,
    text: "\r",
  });
  await controller.mouse(42n, {
    kind: "down",
    x_px: 10,
    y_px: 20,
    button: "left",
    click_count: 1,
  });
  await controller.wheel(42n, {
    x_px: 10,
    y_px: 20,
    delta_y_px: -120,
  });

  const commands = server.requests.map((request) => request.cmd);
  assert.deepEqual(commands, [
    "identify",
    "list-workspaces",
    "browser-navigate",
    "browser-reload",
    "browser-back",
    "browser-forward",
    "browser-activate",
    "browser-insert-text",
    "browser-key",
    "browser-mouse",
    "browser-wheel",
  ]);
  assert.equal(server.requests[2]?.url, "https://example.com");
  assert.equal(server.requests[7]?.text, "hello");
  assert.equal(server.requests[8]?.windows_virtual_key_code, 13);
  assert.equal(server.requests[9]?.button, "left");
  assert.equal(server.requests[10]?.delta_y_px, -120);
  await controller.close();
});

test("resyncs and reattaches after overflow, then stops when detached surface disappears", async () => {
  const server = new BrowserServer();
  const frames: BrowserFrameSnapshot[] = [];
  const recoveries: BrowserRecovery[] = [];
  const states: bigint[] = [];
  const controller = new BrowserController({
    createClient: () => server.client(),
    recoveryDelayMs: 0,
  });

  await controller.followBrowser(42n, {
    onState: (state) => {
      states.push(state.frame?.seq ?? -1n);
    },
    onFrame: (frame) => {
      frames.push(frame);
    },
    onRecovery: (recovery) => {
      recoveries.push(recovery);
    },
  }, {
    maxRecoveries: 2,
    idleReadTimeoutMs: 50,
  });

  assert.deepEqual(states, [1n, 3n]);
  assert.deepEqual(frames.map(({ sequence, source }) => ({ sequence, source })), [
    { sequence: 1n, source: "initial-state" },
    { sequence: 2n, source: "frame-event" },
    { sequence: 3n, source: "initial-state" },
  ]);
  assert.deepEqual(
    recoveries.map(({ reason, attempt, surfacePresent }) => ({
      reason,
      attempt,
      surfacePresent,
    })),
    [
      { reason: "overflow", attempt: 1, surfacePresent: true },
      { reason: "detached", attempt: 2, surfacePresent: false },
    ],
  );
  assert.equal(server.attachAttempts, 2);
  await controller.close();
});

test("replaces a failed command client with a fresh public client", async () => {
  let clients = 0;
  const controller = new BrowserController({
    createClient: () => {
      clients += 1;
      const ordinal = clients;
      return new CmuxClient({
        timeoutMs: 100,
        transport: new FakeTransport((transport, request) => {
          if (request.cmd === "identify") {
            transport.respond(request.id, identifyResult());
          } else if (request.cmd === "list-workspaces" && ordinal === 1) {
            transport.fail(new Error("socket reset"));
          } else if (request.cmd === "list-workspaces") {
            transport.respond(request.id, workspaceTree(true));
          }
        }),
      });
    },
    commandReconnectAttempts: 1,
  });

  assert.equal((await controller.listBrowserTabs())[0]?.surface, 42n);
  assert.equal(clients, 2);
  await controller.close();
});

function identifyResult(): Record<string, unknown> {
  return {
    app: "cmux-tui",
    version: "0.1.2",
    protocol: 10,
    session: "sdk-test",
    pid: 123,
    daemon_handoff: 1,
    generation: "generation-1",
    registry_id: "registry-1",
    terminal_revision: 1n,
    workspace_revision: 1n,
    capabilities: ["attach-initial-size"],
  };
}

function workspaceTree(browserPresent: boolean): Tree {
  const tabs: Tab[] = [{
    browser_source: null,
    dead: false,
    kind: "pty",
    name: "shell",
    size: { cols: 80, rows: 24 },
    surface: 41n,
    title: "shell",
  }];
  if (browserPresent) {
    tabs.push({
      browser_error: null,
      browser_frames_stalled: false,
      browser_source: "launched",
      browser_status: "live",
      dead: false,
      kind: "browser",
      name: "docs",
      size: { cols: 120, rows: 40 },
      surface: 42n,
      title: "cmux docs",
    });
  }
  return {
    generation: "generation-1",
    pane_revision: 1n,
    registry_id: "registry-1",
    terminal_revision: 1n,
    workspace_revision: 1n,
    workspaces: [{
      active: true,
      id: 1n,
      name: "sdk examples",
      screens: [{
        active: true,
        active_pane: 3n,
        id: 2n,
        layout: { type: "leaf", pane: 3n },
        name: "browser",
        panes: [{
          active_tab: browserPresent ? 1n : 0n,
          id: 3n,
          name: "web",
          tabs,
        }, {
          dead: true,
          id: 99n,
        }],
        zoomed_pane: null,
      }],
    }],
  };
}

function browserState(sequence: bigint): Record<string, unknown> {
  return {
    event: "browser-state",
    surface: 42n,
    cols: 120,
    rows: 40,
    url: "https://cmux.dev",
    title: "cmux docs",
    status: "live",
    error: null,
    frames_stalled: false,
    frame: {
      seq: sequence,
      width: 1200,
      height: 800,
      data: "aW5pdGlhbA==",
    },
  };
}

function frameEvent(sequence: bigint): Record<string, unknown> {
  return {
    event: "frame",
    surface: 42n,
    seq: sequence,
    width: 1200,
    height: 800,
    data: "ZnJhbWU=",
  };
}
