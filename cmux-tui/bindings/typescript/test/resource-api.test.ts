import assert from "node:assert/strict";
import test from "node:test";

import {
  Client,
  CmuxAbortError,
  CmuxConnectionError,
  CmuxProtocolError,
  CmuxTimeoutError,
  ConfirmationRequiredError,
  MutationIndeterminateError,
  MutationTransportUncertainError,
  agentId,
  browserId,
  notificationId,
  pairingRequestId,
  paneId,
  projectionId,
  RendererGrant,
  ResourceError,
  ResourceProtocol,
  sidebarViewId,
  StreamError,
  decimalString,
  exact,
  screenId,
  sessionId,
  shell,
  shellExecutable,
  tabId,
  terminalId,
  workspaceId,
  type Transport,
  type Unsubscribe,
} from "../src/index.js";
import { operations } from "../src/internal/operations.js";
import { CmuxClient } from "../src/raw/index.js";

const HEX_A = "a".repeat(32);
const HEX_B = "b".repeat(32);
const HEX_C = "c".repeat(32);
const SESSION = sessionId(`session_${HEX_A}`);
const WORKSPACE = workspaceId(`ws_${HEX_B}`);
const TERMINAL = terminalId(`term_${HEX_C}`);
const SCREEN = screenId(`screen_${HEX_C}`);
const PANE = paneId(`pane_${HEX_A}`);
const TAB = tabId(`tab_${HEX_B}`);
const BROWSER = browserId(`browser_${HEX_A}`);
const AGENT = agentId(`agent_${HEX_B}`);
const NOTIFICATION = notificationId(`notification_${HEX_A}`);
const PAIRING_REQUEST = pairingRequestId(`pairing_${HEX_B}`);
const PROJECTION = projectionId(`projection_${HEX_C}`);
const SIDEBAR_VIEW = sidebarViewId(`sidebar_view_${HEX_A}`);
const UTF8_128 = "🦀".repeat(32);
const UTF8_129 = `${UTF8_128}a`;
const ILL_FORMED_UNICODE = "\ud800";

type Envelope = Record<string, unknown>;

class FakeTransport implements Transport {
  readonly requests: Envelope[] = [];
  readonly closeRequestCounts: number[] = [];
  private readonly messages = new Set<(json: string) => void>();
  private readonly closes = new Set<() => void>();
  private readonly errors = new Set<(error: Error) => void>();

  constructor(
    private readonly responder: (
      request: Envelope,
      transport: FakeTransport,
    ) => void,
  ) {}

  send(json: string): void {
    const request = JSON.parse(json) as Envelope;
    this.requests.push(request);
    this.responder(request, this);
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
    this.closeRequestCounts.push(this.requests.length);
  }

  emit(envelope: Envelope): void {
    const json = JSON.stringify(envelope);
    for (const handler of this.messages) handler(json);
  }

  error(error: Error): void {
    for (const handler of this.errors) handler(error);
  }

  ok(request: Envelope, result: unknown): void {
    this.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: true,
      result,
    });
    if (
      request.operation === "stream.cancel"
      && result !== null
      && typeof result === "object"
      && !Array.isArray(result)
      && Object.keys(result).length === 0
    ) {
      const stream = (request.params as Envelope | undefined)?.stream;
      if (typeof stream === "string") {
        this.emit({
          protocol: "cmux.protocol/2",
          type: "stream_end",
          stream_id: stream,
          reason: "canceled",
        });
      }
    }
  }
}

class DispatchHandleTransport implements Transport {
  readonly supportsDispatchGuard = true;
  readonly dispatched: string[] = [];
  readonly registrations: string[] = [];
  retained: string | undefined;
  releases = 0;
  private queued: { readonly json: string; readonly dispatch: () => void } | undefined;
  private closed = false;
  private readonly closes = new Set<() => void>();

  constructor(private readonly synchronous: boolean) {}

  send(json: string): void {
    this.dispatched.push(json);
  }

  sendCancellable(
    json: string,
    onDispatched: () => void,
    dispatchGuard?: () => boolean,
  ): Unsubscribe {
    this.registrations.push(json);
    this.retained = json;
    const dispatch = () => {
      if (dispatchGuard?.() === false) return;
      onDispatched();
      this.dispatched.push(json);
    };
    if (this.synchronous) dispatch();
    else this.queued = { json, dispatch };
    return () => {
      this.releases += 1;
      this.retained = undefined;
      if (this.queued?.json === json) this.queued = undefined;
    };
  }

  dispatch(): void {
    const queued = this.queued;
    assert.ok(queued);
    this.queued = undefined;
    queued.dispatch();
  }

  onMessage(): Unsubscribe {
    return () => undefined;
  }

  onClose(handler: () => void): Unsubscribe {
    this.closes.add(handler);
    return () => this.closes.delete(handler);
  }

  onError(): Unsubscribe {
    return () => undefined;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const handler of this.closes) handler();
  }
}

class LegacyDeferredTransport implements Transport {
  readonly sent: string[] = [];
  readonly deferred: string[] = [];
  private readonly closes = new Set<() => void>();

  send(json: string): void {
    this.sent.push(json);
  }

  sendCancellable(json: string, _onDispatched: () => void): Unsubscribe {
    this.deferred.push(json);
    return () => undefined;
  }

  onMessage(): Unsubscribe {
    return () => undefined;
  }

  onClose(handler: () => void): Unsubscribe {
    this.closes.add(handler);
    return () => this.closes.delete(handler);
  }

  onError(): Unsubscribe {
    return () => undefined;
  }

  close(): void {
    for (const handler of this.closes) handler();
  }
}

async function waitForOperation(
  transport: FakeTransport,
  operation: string,
  index = 0,
): Promise<Envelope> {
  const deadline = Date.now() + 1_000;
  for (;;) {
    const request = transport.requests.filter(
      (candidate) => candidate.operation === operation,
    )[index];
    if (request) return request;
    if (Date.now() >= deadline) {
      assert.fail(`timed out waiting for ${operation} request ${index}`);
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 1));
  }
}

test("journal options reject invalid combinations before transport", () => {
  const transport = new FakeTransport(() => {
    assert.fail("invalid journal options reached the transport");
  });
  const client = new Client({ transport });
  const session = client.session(SESSION);

  assert.throws(
    () => void session.journal({
      cursor: { generation: String(SESSION), revision: decimalString("1") },
      start: "tail",
    }),
    /mutually exclusive/,
  );
  assert.throws(
    () => void session.journal({ subjects: [{}] }),
    /require kind or id/,
  );
  assert.throws(
    () => void session.journal({ regex: { pattern: "" } }),
    /1 to 1024 UTF-8 bytes/,
  );
  assert.equal(transport.requests.length, 0);
  client.close();
});

test("journal records must match their envelope cursor", async () => {
  let streamId = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation !== "session.journal.subscribe") return;
    streamId = (request.params as Envelope).stream_id as string;
    current.ok(request, { stream_id: streamId });
  });
  const client = new Client({ transport });
  const stream = await client.session(SESSION).journal();
  const next = stream.next();
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: streamId,
    sequence: "1",
    cursor: { generation: String(SESSION), revision: "1" },
    item: {
      sequence: "2",
      event_id: "event_mismatched_cursor",
      schema_version: 1,
      kind: "agent.turn.completed",
      class: "observation",
      replay: "advisory",
      occurred_at_ms: "1",
      committed_at_ms: "2",
      producer: { kind: "agent_adapter", id: "cmux_agents" },
      authority: null,
      causation_id: null,
      correlation_id: null,
      causation_depth: 0,
      subjects: [],
      sensitivity: "metadata",
      payload: {},
      resource_revision: null,
      previous_resource_revision: null,
    },
  });
  await assert.rejects(
    () => next,
    /journal sequence must match its stream cursor/,
  );
  client.close();
});

test("resource protocol releases cancellation handles at dispatch", async () => {
  for (const synchronous of [true, false]) {
    const transport = new DispatchHandleTransport(synchronous);
    const client = new Client({ transport, timeoutMs: 0 });
    const pending = client.session(SESSION).ping();
    const rejected = assert.rejects(() => pending, CmuxConnectionError);

    if (!synchronous) {
      assert.equal(transport.releases, 0);
      assert.ok(transport.retained?.includes("session.ping"));
      transport.dispatch();
    }
    assert.equal(transport.releases, 1);
    assert.equal(transport.retained, undefined);

    client.close();
    await rejected;
    assert.equal(transport.releases, 1);
  }
});

test("raw router releases the exact cancellation handle at dispatch", async () => {
  for (const synchronous of [true, false]) {
    const transport = new DispatchHandleTransport(synchronous);
    const client = new CmuxClient({ transport, timeoutMs: 1_000 });
    const pending = client.sendRaw({
      id: synchronous ? 1 : 2,
      cmd: "rename-workspace",
      workspace: 7,
      name: "dispatch-once",
    });

    if (!synchronous) {
      assert.equal(transport.releases, 0);
      assert.ok(transport.retained?.includes("rename-workspace"));
      transport.dispatch();
    }
    assert.equal(transport.releases, 1);
    assert.equal(transport.retained, undefined);

    await client.close();
    await assert.rejects(() => pending, /transport closed/);
    assert.equal(transport.releases, 1);
  }
});

test("clients do not trust unadvertised cancellable dispatch guards", async () => {
  {
    const transport = new LegacyDeferredTransport();
    const client = new Client({ transport, timeoutMs: 0 });
    const pending = client.session(SESSION).ping();
    const rejected = assert.rejects(() => pending, CmuxConnectionError);

    assert.equal(transport.sent.length, 1);
    assert.deepEqual(transport.deferred, []);

    client.close();
    await rejected;
  }

  {
    const transport = new LegacyDeferredTransport();
    const client = new CmuxClient({ transport, timeoutMs: 1_000 });
    const pending = client.sendRaw({ id: 3, cmd: "ping" });
    const rejected = assert.rejects(() => pending, /transport closed/);

    assert.equal(transport.sent.length, 1);
    assert.deepEqual(transport.deferred, []);

    await client.close();
    await rejected;
  }
});

test("raw request timeout rejects invalid timer values before registration or dispatch", async () => {
  for (const timeoutMs of [-1, Number.NaN, Number.POSITIVE_INFINITY, 0x8000_0000]) {
    const transport = new DispatchHandleTransport(true);
    const client = new CmuxClient({ transport, timeoutMs: 1_000 });

    await assert.rejects(
      () => client.sendRaw(
        { id: `invalid-${String(timeoutMs)}`, cmd: "ping" },
        { timeoutMs },
      ),
      (error: unknown) => {
        assert.ok(error instanceof TypeError);
        assert.equal(error.message, "timeoutMs must be between 0 and 2147483647");
        return true;
      },
    );
    assert.deepEqual(transport.registrations, []);
    assert.deepEqual(transport.dispatched, []);
    await client.close();
  }
});

test("raw request timeout accepts the inclusive timer boundaries", async () => {
  for (const timeoutMs of [0, 0x7fff_ffff]) {
    const transport = new DispatchHandleTransport(true);
    const client = new CmuxClient({ transport, timeoutMs: 1_000 });
    const pending = client.sendRaw(
      { id: `boundary-${timeoutMs}`, cmd: "ping" },
      { timeoutMs },
    );

    assert.equal(transport.registrations.length, 1);
    assert.equal(transport.dispatched.length, 1);
    await client.close();
    await assert.rejects(() => pending, /session transport closed/);
  }
});

test("resource root, raw boundary, exact commands, and idempotency keys", async () => {
  const randomValues = [HEX_A, HEX_B, HEX_C];
  const transport = new FakeTransport((request, current) => {
    current.ok(request, {
      value: {
        kind: "terminal",
        workspace_id: WORKSPACE,
        screen_id: SCREEN,
        pane_id: PANE,
        tab_id: TAB,
        terminal_id: TERMINAL,
      },
      generation: "generation-a",
      revision: "18446744073709551615",
      replayed: false,
    });
  });
  const client = new Client({
    transport,
    randomHex128: () => randomValues.shift()!,
  });
  const workspace = client.session(SESSION).workspace(WORKSPACE);
  const created = await workspace.run(
    { command: exact(["printf", "%s", "$HOME"]) },
    { correlationKey: "run-1" },
  );
  await workspace.run({ command: shell("printf %s \"$HOME\"") });
  await workspace.run({
    command: shellExecutable("/bin/zsh", "echo $(uname)"),
  });

  assert.equal(typeof Client, "function");
  assert.equal(typeof CmuxClient, "function");
  assert.equal(created.value.terminal.id, TERMINAL);
  assert.equal(created.value.content, created.value.terminal);
  assert.deepEqual(
    Object.keys(created.value).sort(),
    ["content", "kind", "pane", "screen", "tab", "terminal", "workspace"],
  );
  assert.equal(created.revision, "18446744073709551615");
  assert.deepEqual(
    transport.requests.map((request) => request.idempotency_key),
    [`ts-${HEX_A}`, `ts-${HEX_B}`, `ts-${HEX_C}`],
  );
  const common = { machine: "current", session: SESSION, workspace: WORKSPACE };
  assert.deepEqual(transport.requests[0]?.params, {
    ...common,
    argv: ["printf", "%s", "$HOME"],
    correlation_key: "run-1",
  });
  assert.deepEqual(transport.requests[1]?.params, {
    ...common,
    shell: "printf %s \"$HOME\"",
  });
  assert.deepEqual(transport.requests[2]?.params, {
    ...common,
    argv: ["/bin/zsh", "-lc", "echo $(uname)"],
  });
  client.close();
});

test("terminal project returns the new tab on its destination route", async () => {
  const projectedTab = tabId(`tab_${HEX_C}`);
  const transport = new FakeTransport((request, current) => {
    const tab = {
      id: projectedTab,
      pane_id: PANE,
      name: "mirror",
      index: 2,
      focused: false,
      content_kind: "terminal",
      content_id: TERMINAL,
    };
    current.ok(request, request.operation === "terminal.project" ? {
      value: {
        ...tab,
      },
      generation: "generation-a",
      revision: "7",
      replayed: false,
    } : tab);
  });
  const client = new Client({ transport });
  const projected = await client.session(SESSION).terminal(TERMINAL).project(
    {
      workspace: WORKSPACE,
      screen: SCREEN,
      pane: PANE,
      index: 2,
      name: "mirror",
    },
    { idempotencyKey: "project-terminal" },
  );

  assert.equal(projected.value.snapshot?.id, projectedTab);
  assert.equal(projected.value.snapshot?.contentId, TERMINAL);
  await projected.value.refresh();
  assert.deepEqual(transport.requests[0]?.params, {
    machine: "current",
    session: SESSION,
    terminal: TERMINAL,
    destination_workspace: WORKSPACE,
    destination_screen: SCREEN,
    destination_pane: PANE,
    index: 2,
    name: "mirror",
  });
  assert.deepEqual(transport.requests[1]?.params, {
    machine: "current",
    session: SESSION,
    workspace: WORKSPACE,
    screen: SCREEN,
    pane: PANE,
    tab: projectedTab,
  });
  client.close();
});

test("request token bounds count UTF-8 bytes at every public boundary", async () => {
  assert.equal(Buffer.byteLength(UTF8_128, "utf8"), 128);
  assert.equal(Buffer.byteLength(UTF8_129, "utf8"), 129);
  assert.ok(UTF8_129.length < 128);

  const transport = new FakeTransport((request, current) => {
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "fixture.stop",
        message: "boundary accepted",
        details: {},
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });
  const session = client.session(SESSION);
  const workspace = session.workspace(WORKSPACE);
  const screen = workspace.screen(SCREEN);

  const accepted: Array<() => Promise<unknown>> = [
    () => workspace.rename("accepted", { idempotencyKey: UTF8_128 }),
    () => workspace.run(
      { command: exact(["true"]) },
      { correlationKey: UTF8_128 },
    ),
    () => session.creation.resolve(UTF8_128),
    async () => await screen.undoLayout({ confirmationToken: UTF8_128 }),
  ];
  for (const call of accepted) await assert.rejects(call, ResourceError);

  assert.equal(transport.requests[0]?.idempotency_key, UTF8_128);
  assert.equal(
    (transport.requests[1]?.params as Envelope).correlation_key,
    UTF8_128,
  );
  assert.equal(
    (transport.requests[2]?.params as Envelope).correlation_key,
    UTF8_128,
  );
  assert.equal(
    (transport.requests[3]?.params as Envelope).confirmation_token,
    UTF8_128,
  );

  for (const invalid of [UTF8_129, ILL_FORMED_UNICODE]) {
    const rejected: Array<() => Promise<unknown>> = [
      () => workspace.rename("rejected", { idempotencyKey: invalid }),
      () => workspace.run(
        { command: exact(["true"]) },
        { correlationKey: invalid },
      ),
      () => session.creation.resolve(invalid),
      async () => await screen.undoLayout({ confirmationToken: invalid }),
    ];
    for (const call of rejected) await assert.rejects(call, TypeError);
  }
  assert.equal(transport.requests.length, accepted.length);
  client.close();
});

test("idempotency keys require a non-whitespace scalar and reject controls", async () => {
  const transport = new FakeTransport((request, current) => {
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "fixture.stop",
        message: "boundary accepted",
        details: {},
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });
  const workspace = client.session(SESSION).workspace(WORKSPACE);

  await assert.rejects(
    () => workspace.rename("accepted", {
      idempotencyKey: " \u00a0key\u2003 ",
    }),
    ResourceError,
  );
  for (const invalid of ["", " \u00a0\u2003 ", "key\u0000suffix", "key\u007fsuffix"]) {
    await assert.rejects(
      () => workspace.rename("rejected", { idempotencyKey: invalid }),
      TypeError,
    );
  }
  assert.equal(transport.requests.length, 1);
  client.close();
});

test("created paths are strict runtime variants and fixed operations reject mismatches", async () => {
  const transport = new FakeTransport((request, current) => {
    const params = request.params as Envelope;
    if (request.operation === "workspace.create") {
      if (params.initial_content === "empty") {
        assert.equal(params.expected_revision, "16");
      }
      const value = params.initial_content === "empty"
        ? {
          kind: "workspace",
          workspace_id: WORKSPACE,
        }
        : {
          kind: "terminal",
          workspace_id: WORKSPACE,
          screen_id: SCREEN,
          pane_id: PANE,
          tab_id: TAB,
          terminal_id: TERMINAL,
        };
      current.ok(request, {
        value,
        generation: "generation-a",
        revision: "1",
        replayed: false,
      });
      return;
    }
    if (request.operation === "workspace.run") {
      current.ok(request, {
        value: {
          kind: "browser",
          workspace_id: WORKSPACE,
          screen_id: SCREEN,
          pane_id: PANE,
          tab_id: TAB,
          browser_id: BROWSER,
        },
        generation: "generation-a",
        revision: "2",
        replayed: false,
      });
      return;
    }
    current.ok(request, {
      value: {
        kind: "terminal",
        workspace_id: WORKSPACE,
        screen_id: SCREEN,
        pane_id: PANE,
        tab_id: TAB,
        terminal_id: TERMINAL,
      },
      generation: "generation-a",
      revision: "3",
      replayed: false,
    });
  });
  const client = new Client({ transport });
  const session = client.session(SESSION);

  const empty = await session.createWorkspace({
    initialContent: "empty",
  }, {
    expectedRevision: decimalString("16"),
  });
  assert.equal(empty.value.kind, "workspace");
  assert.deepEqual(Object.keys(empty.value), ["kind", "workspace"]);
  assert.ok(Object.isFrozen(empty.value));

  const terminal = await session.createWorkspace();
  assert.equal(terminal.value.kind, "terminal");
  if (terminal.value.kind !== "terminal") {
    assert.fail("expected terminal workspace path");
  }
  assert.equal(terminal.value.terminal.id, TERMINAL);
  assert.equal(terminal.value.content, terminal.value.terminal);

  await assert.rejects(
    () => session.workspace(WORKSPACE).run({
      command: exact(["true"]),
    }),
    /workspace\.run returned a browser created path; expected terminal/,
  );
  await assert.rejects(
    () => session
      .workspace(WORKSPACE)
      .screen(SCREEN)
      .pane(PANE)
      .createBrowserTab({ url: "https://example.com" }),
    /tab\.create_browser returned a terminal created path; expected browser/,
  );
  client.close();
});

test("structured errors preserve fields", async () => {
  const transport = new FakeTransport((request, current) => {
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "selector.not_found",
        message: "session is gone",
        details: { session: SESSION },
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });
  await assert.rejects(
    () => client.session(SESSION).ping(),
    (error: unknown) => {
      assert.ok(error instanceof ResourceError);
      assert.equal(error.code, "selector.not_found");
      assert.equal(error.message, "session is gone");
      assert.deepEqual(error.details, { session: SESSION });
      assert.equal(error.retryable, false);
      return true;
    },
  );
  client.close();
});

test("machine snapshots reject removed provider fields and external origins", async () => {
  for (const machine of [
    {
      id: `machine_${HEX_A}`,
      name: "external",
      origin: "external",
      status: "running",
      connectable: true,
      deleted: false,
      recoverable: true,
    },
    {
      id: `machine_${HEX_A}`,
      name: "local",
      origin: "local",
      status: "running",
      connectable: true,
      provider_scope_id: `provider_scope_${HEX_A}`,
      deleted: false,
      recoverable: true,
    },
  ]) {
    const transport = new FakeTransport((request, current) => {
      current.ok(request, [machine]);
    });
    const client = new Client({ transport });
    await assert.rejects(() => client.listMachines(), CmuxProtocolError);
    client.close();
  }
});

test("optional fields and expected revisions reach the wire", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "notification.list" || request.operation === "agent.list") {
      current.ok(request, []);
      return;
    }
    if (request.operation === "agent.report") {
      current.ok(request, {
        value: {
          id: AGENT,
          session_id: SESSION,
          terminal_id: TERMINAL,
          state: "working",
          source: "socket",
          source_session: "codex-1",
          updated_at_ms: "10",
        },
        generation: "generation-a",
        revision: "9",
        replayed: false,
      });
      return;
    }
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "operation.failed",
        message: "fixture stop",
        details: { operation: request.operation, reason: "fixture" },
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });
  assert.throws(
    () => client.session(SESSION).workspace(WORKSPACE).screen(SCREEN).undoLayout({
      confirmClose: true,
    }),
    /confirmClose requires confirmationToken/,
  );
  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).rename("renamed", {
      expectedRevision: decimalString("7"),
      idempotencyKey: "workspace-rename",
    }),
    ResourceError,
  );
  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).screen(SCREEN).undoLayout({
      confirmClose: true,
      confirmationToken: "undo-preview-token",
      expectedRevision: decimalString("8"),
      idempotencyKey: "screen-undo",
    }),
    ResourceError,
  );
  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).screen(SCREEN).pane(PANE).split(
      {
        direction: "right",
        viewportWidth: 0.5,
      },
    ),
    ResourceError,
  );
  const session = client.session(SESSION);
  assert.deepEqual(await session.listNotifications({ limit: 7 }), []);
  assert.deepEqual(
    await session.listAgents({ terminalId: TERMINAL, state: "working" }),
    [],
  );
  const reported = await session.reportAgent(
    {
      terminalId: TERMINAL,
      state: "working",
      source: "socket",
      sourceSession: "codex-1",
    },
    {
      idempotencyKey: "agent-status",
      expectedRevision: decimalString("9"),
    },
  );
  assert.equal(reported.value.id, AGENT);
  assert.equal(reported.value.snapshot?.state, "working");
  assert.equal("report" in reported.value, false);
  const request = (operation: string): Envelope =>
    transport.requests.find((item) => item.operation === operation)!;
  assert.deepEqual(request("workspace.rename").params, {
    machine: "current",
    session: SESSION,
    workspace: WORKSPACE,
    name: "renamed",
    expected_revision: "7",
  });
  assert.equal(
    (request("screen.layout.undo").params as Envelope).confirm_close,
    true,
  );
  assert.equal(
    (request("screen.layout.undo").params as Envelope).expected_revision,
    "8",
  );
  assert.equal(
    (request("screen.layout.undo").params as Envelope).confirmation_token,
    "undo-preview-token",
  );
  assert.equal(
    (request("pane.split").params as Envelope).viewport_width,
    0.5,
  );
  assert.equal((request("notification.list").params as Envelope).limit, 7);
  assert.equal(
    (request("agent.list").params as Envelope).terminal_id,
    TERMINAL,
  );
  assert.equal((request("agent.list").params as Envelope).state, "working");
  assert.equal(request("agent.report").idempotency_key, "agent-status");
  assert.deepEqual(request("agent.report").params, {
    machine: "current",
    session: SESSION,
    terminal_id: TERMINAL,
    state: "working",
    source: "socket",
    source_session: "codex-1",
    expected_revision: "9",
  });
  assert.equal(
    Object.hasOwn(request("agent.report").params as Envelope, "agent"),
    false,
  );
  client.close();
});

test("indeterminate mutations are typed and never retried", async () => {
  const transport = new FakeTransport((request, current) => {
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "mutation.indeterminate",
        message: "external effect may have completed",
        details: {
          idempotency_key: request.idempotency_key,
          operation: request.operation,
          recovery: "inspect_state_then_retry_with_new_key",
        },
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });
  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).rename("external", {
      idempotencyKey: "external-rename",
    }),
    (error: unknown) => {
      assert.ok(error instanceof MutationIndeterminateError);
      assert.equal(error.code, "mutation.indeterminate");
      assert.equal(error.retryable, false);
      assert.deepEqual(error.details, {
        idempotency_key: "external-rename",
        operation: "workspace.rename",
        recovery: "inspect_state_then_retry_with_new_key",
      });
      return true;
    },
  );
  assert.equal(transport.requests.length, 1);
  client.close();
});

test("confirmation errors expose typed preview details", async () => {
  const transport = new FakeTransport((request, current) => {
    current.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: request.id,
      ok: false,
      error: {
        code: "confirmation.required",
        message: "undo would close panes",
        details: {
          confirmation_token: "undo-preview-token",
          revision: "18446744073709551615",
          closes_panes: [PANE],
        },
        retryable: false,
      },
    });
  });
  const client = new Client({ transport });

  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).screen(SCREEN).undoLayout(),
    (error: unknown) => {
      assert.ok(error instanceof ConfirmationRequiredError);
      assert.equal(error.details.confirmation_token, "undo-preview-token");
      assert.equal(error.details.revision, "18446744073709551615");
      assert.deepEqual(error.details.closes_panes, [PANE]);
      return true;
    },
  );
  client.close();
});

test("structured error token bounds use UTF-8 bytes", async () => {
  const confirmation = async (token: string): Promise<void> => {
    const transport = new FakeTransport((request, current) => {
      current.emit({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: false,
        error: {
          code: "confirmation.required",
          message: "undo would close panes",
          details: {
            confirmation_token: token,
            revision: "1",
            closes_panes: [PANE],
          },
          retryable: false,
        },
      });
    });
    const client = new Client({ transport });
    try {
      await client.session(SESSION).workspace(WORKSPACE).screen(SCREEN).undoLayout();
    } finally {
      client.close();
    }
  };
  await assert.rejects(
    () => confirmation(UTF8_128),
    ConfirmationRequiredError,
  );
  for (const invalid of [UTF8_129, ILL_FORMED_UNICODE]) {
    await assert.rejects(() => confirmation(invalid), CmuxProtocolError);
  }

  const indeterminate = async (idempotencyKey: string): Promise<void> => {
    const transport = new FakeTransport((request, current) => {
      current.emit({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: false,
        error: {
          code: "mutation.indeterminate",
          message: "outcome is unknown",
          details: {
            idempotency_key: idempotencyKey,
            operation: "workspace.rename",
            recovery: "inspect_state_then_retry_with_new_key",
          },
          retryable: false,
        },
      });
    });
    const client = new Client({ transport });
    try {
      await client.session(SESSION).workspace(WORKSPACE).rename("renamed", {
        idempotencyKey: "request-key",
      });
    } finally {
      client.close();
    }
  };
  await assert.rejects(
    () => indeterminate(UTF8_128),
    MutationIndeterminateError,
  );
  for (const invalid of [
    UTF8_129,
    ILL_FORMED_UNICODE,
    " \u00a0\u2003 ",
    "key\u0000suffix",
  ]) {
    await assert.rejects(() => indeterminate(invalid), CmuxProtocolError);
  }
});

test("dropped mutation responses expose supplied and generated idempotency keys", async () => {
  const transport = new FakeTransport(() => {
    // Simulate a request that may have reached the server but lost its response.
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_C,
  });

  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).rename("supplied", {
      idempotencyKey: "supplied-key",
      timeoutMs: 5,
    }),
    (error: unknown) => {
      assert.ok(error instanceof MutationTransportUncertainError);
      assert.equal(error.operation, "workspace.rename");
      assert.equal(error.idempotencyKey, "supplied-key");
      assert.ok(error.cause instanceof CmuxTimeoutError);
      return true;
    },
  );
  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).rename("generated", {
      timeoutMs: 5,
    }),
    (error: unknown) => {
      assert.ok(error instanceof MutationTransportUncertainError);
      assert.equal(error.operation, "workspace.rename");
      assert.equal(error.idempotencyKey, `ts-${HEX_C}`);
      assert.ok(error.cause instanceof CmuxTimeoutError);
      return true;
    },
  );

  assert.equal(transport.requests.length, 2);
  assert.deepEqual(
    transport.requests.map((request) => request.idempotency_key),
    ["supplied-key", `ts-${HEX_C}`],
  );
  client.close();
});

test("a mutation canceled before send is not reported as uncertain", async () => {
  const transport = new FakeTransport(() => {
    assert.fail("pre-aborted mutation reached the transport");
  });
  const client = new Client({ transport });
  const controller = new AbortController();
  controller.abort();

  await assert.rejects(
    () => client.session(SESSION).workspace(WORKSPACE).rename("never-sent", {
      signal: controller.signal,
    }),
    (error: unknown) => {
      assert.ok(error instanceof CmuxAbortError);
      assert.ok(!(error instanceof MutationTransportUncertainError));
      return true;
    },
  );
  assert.equal(transport.requests.length, 0);
  client.close();
});

test("request and stream receive bounds are operation-scoped", async () => {
  let openedStream = "";
  let pingCount = 0;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "session.ping") {
      pingCount += 1;
      if (pingCount === 1) return;
      current.ok(request, {
        alive: true,
        cursor: { generation: "generation-a", revision: "11" },
      });
      return;
    }
    current.ok(request, {});
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_B,
  });
  const session = client.session(SESSION);

  await assert.rejects(
    () => session.ping({ timeoutMs: 5 }),
    CmuxTimeoutError,
  );
  assert.equal((await session.ping({ timeoutMs: 50 })).alive, true);

  const stream = await session.events();
  await assert.rejects(
    () => stream.next({ timeoutMs: 5 }),
    CmuxTimeoutError,
  );
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: { kind: "future", value: 1 },
  });
  assert.equal((await stream.next()).value?.value.kind, "future");

  const abort = new AbortController();
  const pending = stream.next({ signal: abort.signal });
  abort.abort();
  await assert.rejects(() => pending, CmuxAbortError);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "1",
    item: { kind: "future", value: 2 },
  });
  assert.equal((await stream.next()).value?.sequence, "1");
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    0,
  );

  await stream.cancel();
  client.close();
});

test("stream completion detaches its open AbortSignal listener", async () => {
  let openedStream = "";
  const listeners = new Set<EventListenerOrEventListenerObject>();
  const signal = {
    aborted: false,
    addEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject,
    ): void {
      if (type === "abort") listeners.add(listener);
    },
    removeEventListener(
      type: string,
      listener: EventListenerOrEventListenerObject,
    ): void {
      if (type === "abort") listeners.delete(listener);
    },
  } as unknown as AbortSignal;
  const transport = new FakeTransport((request, current) => {
    assert.equal(request.operation, "session.events");
    openedStream = (request.params as Envelope).stream_id as string;
    current.ok(request, { stream_id: openedStream });
  });
  const client = new Client({ transport, randomHex128: () => HEX_B });
  const stream = await client.session(SESSION).events({ signal });
  assert.equal(listeners.size, 1);

  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_end",
    stream_id: openedStream,
    reason: "closed",
  });
  assert.equal(listeners.size, 0);
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
  client.close();
});

test("terminal waits propagate finite server bounds no longer than request deadlines", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "terminal.wait") {
      current.ok(request, { matched: false, text: "" });
      return;
    }
    if (request.operation === "terminal.wait_exit") {
      current.ok(request, {
        state: "pending",
        terminal_id: TERMINAL,
        lifecycle: "running",
        revision: "1",
      });
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const client = new Client({ transport, timeoutMs: 41 });
  const terminal = client.session(SESSION).terminal(TERMINAL);

  await terminal.wait({ pattern: "ready" });
  await terminal.wait(
    { pattern: "ready", timeoutMs: decimalString("99") },
    { timeoutMs: 23 },
  );
  await terminal.wait(
    { pattern: "ready", timeoutMs: decimalString("7") },
    { timeoutMs: 23 },
  );
  await terminal.waitExit(decimalString("99"), { timeoutMs: 17 });
  await terminal.waitExit();
  await terminal.wait({ pattern: "ready" }, { timeoutMs: 0x7fff_ffff });

  assert.deepEqual(
    transport.requests.map((request) => ({
      operation: request.operation,
      timeoutMs: (request.params as Envelope).timeout_ms,
    })),
    [
      { operation: "terminal.wait", timeoutMs: "41" },
      { operation: "terminal.wait", timeoutMs: "23" },
      { operation: "terminal.wait", timeoutMs: "7" },
      { operation: "terminal.wait_exit", timeoutMs: "17" },
      { operation: "terminal.wait_exit", timeoutMs: "41" },
      { operation: "terminal.wait", timeoutMs: "2147483547" },
    ],
  );
  client.close();

  const unboundedTransport = new FakeTransport((request, current) => {
    current.ok(request, { matched: false, text: "" });
  });
  const locallyUnbounded = new Client({
    transport: unboundedTransport,
    timeoutMs: 0,
  });
  await locallyUnbounded.session(SESSION).terminal(TERMINAL).wait({ pattern: "ready" });
  assert.equal(
    (unboundedTransport.requests[0]?.params as Envelope).timeout_ms,
    "10000",
  );
  locallyUnbounded.close();
});

test("timed-out terminal waits cancel once and gate connection reuse", async () => {
  const transport = new FakeTransport(() => {});
  const client = new Client({ transport, timeoutMs: 200 });
  const session = client.session(SESSION);
  const waiting = session.terminal(TERMINAL).wait(
    { pattern: "never" },
    { timeoutMs: 10 },
  );
  const target = await waitForOperation(transport, "terminal.wait");
  const canceled = await waitForOperation(transport, "request.cancel");
  assert.deepEqual(canceled.params, { request_id: target.id });

  let pingSettled = false;
  const ping = session.ping().then((value) => {
    pingSettled = true;
    return value;
  });
  await new Promise<void>((resolve) => setTimeout(resolve, 5));
  assert.equal(pingSettled, false);
  assert.equal(
    transport.requests.filter((request) => request.operation === "session.ping").length,
    0,
  );

  transport.ok(canceled, { canceled: true });
  await assert.rejects(() => waiting, CmuxTimeoutError);
  const pingRequest = await waitForOperation(transport, "session.ping");
  transport.ok(pingRequest, {
    alive: true,
    cursor: { generation: "generation-a", revision: "1" },
  });
  assert.equal((await ping).alive, true);
  assert.equal(
    transport.requests.filter((request) => request.operation === "request.cancel").length,
    1,
  );
  client.close();
});

test("timed-out terminal exit waits use request.cancel", async () => {
  const transport = new FakeTransport(() => {});
  const client = new Client({ transport, timeoutMs: 100 });
  const waiting = client.session(SESSION).terminal(TERMINAL).waitExit(
    undefined,
    { timeoutMs: 10 },
  );
  const target = await waitForOperation(transport, "terminal.wait_exit");
  const canceled = await waitForOperation(transport, "request.cancel");
  assert.deepEqual(canceled.params, { request_id: target.id });
  transport.ok(canceled, { canceled: true });
  await assert.rejects(() => waiting, CmuxTimeoutError);
  client.close();
});

test("terminal wait abort skips pre-dispatch cancellation and cleans up once", async () => {
  const transport = new FakeTransport(() => {});
  const client = new Client({ transport, timeoutMs: 200 });
  const terminal = client.session(SESSION).terminal(TERMINAL);

  const preDispatch = new AbortController();
  preDispatch.abort();
  await assert.rejects(
    () => terminal.wait(
      { pattern: "never" },
      { signal: preDispatch.signal },
    ),
    CmuxAbortError,
  );
  assert.equal(transport.requests.length, 0);

  const abort = new AbortController();
  const waiting = terminal.wait(
    { pattern: "never" },
    { signal: abort.signal, timeoutMs: 20 },
  );
  const target = await waitForOperation(transport, "terminal.wait");
  abort.abort();
  abort.abort();
  const canceled = await waitForOperation(transport, "request.cancel");
  await new Promise<void>((resolve) => setTimeout(resolve, 30));
  assert.equal(
    transport.requests.filter((request) => request.operation === "request.cancel").length,
    1,
  );
  assert.deepEqual(canceled.params, { request_id: target.id });
  transport.ok(canceled, { canceled: true });
  await assert.rejects(() => waiting, CmuxAbortError);
  client.close();
});

test("request.cancel false drains the raced terminal response before reuse", async () => {
  for (const responseFirst of [false, true]) {
    const transport = new FakeTransport(() => {});
    const client = new Client({ transport, timeoutMs: 200 });
    const session = client.session(SESSION);
    const abort = new AbortController();
    const waiting = session.terminal(TERMINAL).wait(
      { pattern: "never" },
      { signal: abort.signal },
    );
    const target = await waitForOperation(transport, "terminal.wait");
    abort.abort();
    const canceled = await waitForOperation(transport, "request.cancel");
    const ping = session.ping();

    if (responseFirst) {
      transport.ok(target, { matched: false, text: "" });
    } else {
      transport.ok(canceled, { canceled: false });
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 5));
    assert.equal(
      transport.requests.filter((request) => request.operation === "session.ping").length,
      0,
    );

    if (responseFirst) {
      transport.ok(canceled, { canceled: false });
    } else {
      transport.ok(target, { matched: false, text: "" });
    }
    await assert.rejects(() => waiting, CmuxAbortError);
    const pingRequest = await waitForOperation(transport, "session.ping");
    transport.ok(pingRequest, {
      alive: true,
      cursor: { generation: "generation-a", revision: "1" },
    });
    assert.equal((await ping).alive, true);
    client.close();
  }
});

test("request.cancel false rejects malformed target results in both orders", async () => {
  for (const responseFirst of [false, true]) {
    const transport = new FakeTransport(() => {});
    const client = new Client({ transport, timeoutMs: 200 });
    const abort = new AbortController();
    const waiting = client.session(SESSION).terminal(TERMINAL).wait(
      { pattern: "never" },
      { signal: abort.signal },
    );
    const target = await waitForOperation(transport, "terminal.wait");
    abort.abort();
    const canceled = await waitForOperation(transport, "request.cancel");

    if (responseFirst) {
      transport.ok(target, { matched: true });
      transport.ok(canceled, { canceled: false });
    } else {
      transport.ok(canceled, { canceled: false });
      transport.ok(target, { matched: true });
    }

    await assert.rejects(() => waiting, CmuxAbortError);
    assert.equal(client.closed, true);
    await assert.rejects(() => client.session(SESSION).ping());
  }
});

test("request.cancel false validates wait_exit identity before reuse", async () => {
  const otherTerminal = terminalId(`term_${"d".repeat(32)}`);
  for (const responseFirst of [false, true]) {
    const transport = new FakeTransport(() => {});
    const client = new Client({ transport, timeoutMs: 200 });
    const session = client.session(SESSION);
    const abort = new AbortController();
    const waiting = session.terminal(TERMINAL).waitExit(undefined, {
      signal: abort.signal,
    });
    const target = await waitForOperation(transport, "terminal.wait_exit");
    abort.abort();
    const canceled = await waitForOperation(transport, "request.cancel");
    const ping = session.ping();
    const pingRejected = assert.rejects(() => ping);

    try {
      const wrongTarget = {
        state: "pending",
        terminal_id: otherTerminal,
        lifecycle: "running",
        revision: "1",
      };
      if (responseFirst) {
        transport.ok(target, wrongTarget);
      } else {
        transport.ok(canceled, { canceled: false });
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 5));
      assert.equal(
        transport.requests.filter(
          (request) => request.operation === "session.ping",
        ).length,
        0,
      );

      if (responseFirst) {
        transport.ok(canceled, { canceled: false });
      } else {
        transport.ok(target, wrongTarget);
      }

      await assert.rejects(() => waiting, CmuxAbortError);
      assert.equal(client.closed, true);
      await pingRejected;
    } finally {
      client.close();
      await Promise.allSettled([waiting, ping, pingRejected]);
    }
  }
});

test("unconfirmed terminal wait cancellation fail-closes without masking abort", async () => {
  for (
    const failure of [
      "malformed-cancel",
      "malformed-target",
      "missing-target",
      "true-after-target",
      "send",
    ] as const
  ) {
    const transport = new FakeTransport((request, current) => {
      if (request.operation !== "request.cancel") return;
      if (failure === "malformed-cancel") {
        current.ok(request, { canceled: true, extra: true });
      } else if (failure === "malformed-target") {
        current.ok(request, { canceled: false });
        const target = current.requests.find(
          (candidate) => candidate.operation === "terminal.wait",
        )!;
        current.emit({
          protocol: "cmux.protocol/2",
          type: "response",
          id: target.id,
          ok: true,
          result: { matched: false, text: "" },
          extra: true,
        });
      } else if (failure === "missing-target") {
        current.ok(request, { canceled: false });
      } else if (failure === "true-after-target") {
        const target = current.requests.find(
          (candidate) => candidate.operation === "terminal.wait",
        )!;
        current.ok(target, { matched: false, text: "" });
        current.ok(request, { canceled: true });
      } else {
        throw new Error("uncertain cancel send");
      }
    });
    const client = new Client({ transport, timeoutMs: 30 });
    const abort = new AbortController();
    const waiting = client.session(SESSION).terminal(TERMINAL).wait(
      { pattern: "never" },
      { signal: abort.signal },
    );
    await waitForOperation(transport, "terminal.wait");
    abort.abort();
    const rejected = assert.rejects(() => waiting, CmuxAbortError);
    await waitForOperation(transport, "request.cancel");
    await rejected;
    assert.equal(client.closed, true);
    await assert.rejects(() => client.session(SESSION).ping());
    assert.equal(
      transport.requests.filter((request) => request.operation === "request.cancel").length,
      1,
    );
  }
});

test("auxiliary resource discriminants select their decoder and preserve extra fields", async () => {
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    current.ok(request, {});
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_C,
  });
  const stream = await client.session(SESSION).events();

  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "1",
    item: {
      kind: "delta",
      cursor: { generation: "generation-a", revision: "2" },
      previous_revision: "1",
      revision: "2",
      changes: [
        {
          kind: "upsert",
          sequence: 0,
          resource: "notification",
          id: NOTIFICATION,
          value: {
            id: NOTIFICATION,
            session_id: SESSION,
            title: "build complete",
            body: "all checks passed",
            level: "info",
            terminal_id: TERMINAL,
            created_at_ms: "1000",
            unread: true,
            extra: { delivery: "native" },
          },
        },
        {
          kind: "upsert",
          sequence: 1,
          resource: "agent",
          id: AGENT,
          value: {
            id: AGENT,
            session_id: SESSION,
            terminal_id: TERMINAL,
            state: "working",
            source: "socket",
            updated_at_ms: "1001",
            source_session: "codex-1",
            extra: { model: "gpt" },
          },
        },
        {
          kind: "upsert",
          sequence: 2,
          resource: "pairing_request",
          id: PAIRING_REQUEST,
          value: {
            id: PAIRING_REQUEST,
            session_id: SESSION,
            peer: "laptop",
            code: "123456",
            expires_in_seconds: "30",
            status: "pending",
            extra: { transport: "websocket" },
          },
        },
        {
          kind: "upsert",
          sequence: 3,
          resource: "frontend_projection",
          id: PROJECTION,
          value: {
            id: PROJECTION,
            session_id: SESSION,
            frontend_id: "swift",
            window_id: "window-a",
            generation: "launch-a",
            projection: { kind: "tree", tabs: 2 },
            projection_revision: "1",
            extra: { source: "sidebar" },
          },
        },
        {
          kind: "upsert",
          sequence: 4,
          resource: "sidebar_view",
          id: SIDEBAR_VIEW,
          value: {
            id: SIDEBAR_VIEW,
            session_id: SESSION,
            cols: 42,
            rows: 18,
            running: true,
            extra: { renderer: "ratatui" },
          },
        },
      ],
    },
  });

  const item = await stream.next();
  const event = item.value?.value;
  if (event?.kind !== "delta") assert.fail("expected a session delta");
  const resources: string[] = [];
  for (const change of event.changes) {
    if ("raw" in change) assert.fail("expected a known resource change");
    if (change.kind !== "upsert") assert.fail("expected an upsert");
    resources.push(change.resource);
    switch (change.resource) {
      case "notification":
        assert.equal(change.value.id, NOTIFICATION);
        assert.equal(change.value.title, "build complete");
        assert.deepEqual(change.value.extra, { delivery: "native" });
        break;
      case "agent":
        assert.equal(change.value.id, AGENT);
        assert.equal(change.value.state, "working");
        assert.deepEqual(change.value.extra, { model: "gpt" });
        break;
      case "pairing_request":
        assert.equal(change.value.id, PAIRING_REQUEST);
        assert.equal(change.value.code.reveal(), "123456");
        assert.deepEqual(change.value.extra, { transport: "websocket" });
        break;
      case "frontend_projection":
        assert.equal(change.value.id, PROJECTION);
        assert.deepEqual(change.value.projection, { kind: "tree", tabs: 2 });
        assert.deepEqual(change.value.extra, { source: "sidebar" });
        break;
      case "sidebar_view":
        assert.equal(change.value.id, SIDEBAR_VIEW);
        assert.equal(change.value.cols, 42);
        assert.deepEqual(change.value.extra, { renderer: "ratatui" });
        break;
      default:
        assert.fail(`unexpected resource ${change.resource}`);
    }
  }
  assert.deepEqual(resources, [
    "notification",
    "agent",
    "pairing_request",
    "frontend_projection",
    "sidebar_view",
  ]);

  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "2",
    item: {
      kind: "delta",
      cursor: { generation: "generation-a", revision: "3" },
      previous_revision: "2",
      revision: "3",
      changes: [{
        kind: "upsert",
        sequence: 5,
        resource: "notification",
        id: NOTIFICATION,
        value: {
          id: NOTIFICATION,
          session_id: SESSION,
          title: "future",
          body: "field",
          level: "info",
          created_at_ms: "1002",
          unread: false,
          undeclared_future_field: true,
        },
      }],
    },
  });
  await assert.rejects(
    () => stream.next(),
    /resource snapshot contains unknown field "undeclared_future_field"/,
  );
  client.close();
});

test("browser frames expose the exact pointer token used by mouse and wheel", async () => {
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "browser.attach") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, {
        stream_id: openedStream,
        attachment_lease: "browser-lease",
      });
      return;
    }
    current.ok(request, {
      value: {},
      generation: "generation-a",
      revision: "12",
      replayed: false,
    });
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_B,
  });
  const browser = client.session(SESSION).browser(BROWSER);
  const stream = await browser.attach();
  const pointerFrameSeq = decimalString("18446744073709551615");

  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "1",
    item: {
      kind: "frame",
      mime_type: "image/png",
      data_base64: "ZnJhbWU=",
      width_px: 1200,
      height_px: 800,
      pointer_frame_seq: pointerFrameSeq,
    },
  });
  const frame = await stream.next();
  assert.equal(frame.value?.value.kind, "frame");
  if (frame.value?.value.kind !== "frame") {
    assert.fail("expected a browser frame");
  }
  assert.equal(frame.value.value.pointerFrameSeq, pointerFrameSeq);

  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "2",
    item: {
      kind: "frame",
      mime_type: "image/jpeg",
      data_base64: "ZnJhbWU=",
      width_px: 1200,
      height_px: 800,
      pointer_frame_seq: null,
    },
  });
  const blockedFrame = await stream.next();
  assert.equal(blockedFrame.value?.value.kind, "frame");
  if (blockedFrame.value?.value.kind !== "frame") {
    assert.fail("expected a browser frame");
  }
  assert.equal(blockedFrame.value.value.pointerFrameSeq, null);

  await browser.mouse({
    kind: "down",
    xPx: 10,
    yPx: 20,
    button: "left",
    clickCount: 1,
    pointerFrameSeq,
  });
  await browser.wheel({
    deltaX: 0,
    deltaY: -120,
    xPx: 10,
    yPx: 20,
    pointerFrameSeq,
  });

  const mouse = transport.requests[1]?.params as Envelope;
  const wheel = transport.requests[2]?.params as Envelope;
  assert.equal(mouse.pointer_frame_seq, pointerFrameSeq);
  assert.equal(wheel.pointer_frame_seq, pointerFrameSeq);
  assert.equal("pointerFrameSeq" in mouse, false);
  assert.equal("pointerFrameSeq" in wheel, false);
  assert.throws(
    () => browser.mouse({
      kind: "move",
      xPx: 0,
      yPx: 0,
      pointerFrameSeq: null as never,
    }),
    /pointerFrameSeq must be a non-null DecimalString/,
  );
  assert.throws(
    () => browser.wheel({
      deltaX: 0,
      deltaY: 1,
      xPx: 0,
      yPx: 0,
      pointerFrameSeq: "01" as never,
    }),
    /pointerFrameSeq must be a non-null DecimalString/,
  );
  client.close();
});

test("browser frames reject a missing or non-string pointer token", async () => {
  const invalidFrames = [
    {
      frame: {
        kind: "frame",
        mime_type: "image/png",
        data_base64: "ZnJhbWU=",
        width_px: 1200,
        height_px: 800,
      },
      message: /pointer_frame_seq is required/,
    },
    {
      frame: {
        kind: "frame",
        mime_type: "image/png",
        data_base64: "ZnJhbWU=",
        width_px: 1200,
        height_px: 800,
        pointer_frame_seq: 7,
      },
      message: /invalid pointer_frame_seq/,
    },
  ] as const;

  for (const invalid of invalidFrames) {
    let openedStream = "";
    const transport = new FakeTransport((request, current) => {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, {
        stream_id: openedStream,
        attachment_lease: "browser-lease",
      });
    });
    const client = new Client({
      transport,
      randomHex128: () => HEX_C,
    });
    const stream = await client.session(SESSION).browser(BROWSER).attach();
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: "1",
      item: invalid.frame,
    });
    await assert.rejects(() => stream.next(), invalid.message);
    client.close();
  }
});

test("mutations update and return the receiver handle", async () => {
  const transport = new FakeTransport((request, current) => {
    current.ok(request, {
      value: {
        id: WORKSPACE,
        name: "renamed",
        session_id: SESSION,
        index: 1,
        focused: true,
      },
      generation: "generation-a",
      revision: "12",
      replayed: false,
    });
  });
  const client = new Client({ transport });
  const workspace = client.session(SESSION).workspace(WORKSPACE);
  const result = await workspace.rename("renamed", {
    idempotencyKey: "workspace-rename",
  });

  assert.equal(result.value, workspace);
  assert.equal(workspace.snapshot?.name, "renamed");
  assert.equal(result.revision, "12");
  client.close();
});

test("terminal snapshots expose lifecycle and durable exit details", async () => {
  let refreshes = 0;
  const transport = new FakeTransport((request, current) => {
    refreshes += 1;
    const base = {
      id: TERMINAL,
      tab_ids: [TAB],
      title: "job",
      cols: 80,
      rows: 24,
    };
    if (refreshes === 1) {
      current.ok(request, {
        ...base,
        running: true,
        lifecycle: "running",
      });
      return;
    }
    current.ok(request, {
      ...base,
      running: refreshes === 3,
      lifecycle: "exited",
      exit: {
        outcome: { kind: "exit", code: 0 },
        exited_at: "20",
        revision: "21",
      },
    });
  });
  const client = new Client({ transport });
  const terminal = client.session(SESSION).terminal(TERMINAL);

  const running = await terminal.refresh();
  assert.equal(running.lifecycle, "running");
  assert.equal(running.exit, undefined);

  const exited = await terminal.refresh();
  assert.equal(exited.lifecycle, "exited");
  assert.deepEqual(exited.exit, {
    outcome: { kind: "exit", code: 0 },
    exitedAt: "20",
    revision: "21",
  });

  await assert.rejects(() => terminal.refresh(), /running must be true exactly/);
  client.close();
});

test("terminal snapshots accept the protocol-one tab_id alias", async () => {
  let refreshes = 0;
  const transport = new FakeTransport((request, current) => {
    const value: Record<string, unknown> = {
      id: TERMINAL,
      title: "legacy",
      cols: 80,
      rows: 24,
      running: true,
      lifecycle: "running",
    };
    if (refreshes === 0) {
      value.tab_id = TAB;
    } else if (refreshes === 1) {
      value.tab_id = null;
    } else if (refreshes === 2) {
      value.tab_id = TAB;
      value.tab_ids = [TAB];
    } else if (refreshes === 4) {
      value.tab_id = TAB;
      value.tab_ids = [];
    }
    refreshes += 1;
    current.ok(request, value);
  });
  const client = new Client({ transport });
  const terminal = client.session(SESSION).terminal(TERMINAL);

  assert.deepEqual((await terminal.refresh()).tabIds, [TAB]);
  assert.deepEqual((await terminal.refresh()).tabIds, []);
  assert.deepEqual((await terminal.refresh()).tabIds, [TAB]);
  await assert.rejects(
    () => terminal.refresh(),
    /requires tab_ids or tab_id/,
  );
  await assert.rejects(
    () => terminal.refresh(),
    /tab_id must be the first tab_ids item/,
  );
  client.close();
});

test("creation resolution and terminal exit reads expose strict typed variants", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.creation.resolve") {
      const correlationKey = (request.params as Envelope).correlation_key;
      if (correlationKey === "pending-create") {
        current.ok(request, {
          correlation_key: correlationKey,
          state: "pending",
          recovery: "wait",
          operation: "workspace.create",
          idempotency_key: "create-key",
        });
        return;
      }
      current.ok(request, {
        correlation_key: correlationKey,
        state: "created",
        recovery: "none",
        operation: "workspace.create",
        idempotency_key: "create-key",
        created_path: {
          kind: "terminal",
          workspace_id: WORKSPACE,
          screen_id: SCREEN,
          pane_id: PANE,
          tab_id: TAB,
          terminal_id: TERMINAL,
        },
        generation: "generation-a",
        revision: "15",
      });
      return;
    }
    current.ok(request, {
      state: "exited",
      terminal_id: TERMINAL,
      lifecycle: "exited",
      outcome: {
        kind: "signal",
        signal: 15,
        core_dumped: false,
      },
      exited_at: "1234",
      revision: "16",
    });
  });
  const client = new Client({ transport });
  const session = client.session(SESSION);

  const pending = await session.creation.resolve("pending-create");
  assert.equal(pending.state, "pending");
  assert.equal(pending.recovery, "wait");

  const created = await session.creation.resolve("created");
  assert.equal(created.state, "created");
  if (created.state !== "created") assert.fail("expected created resolution");
  assert.equal(created.createdPath.kind, "terminal");
  if (created.createdPath.kind !== "terminal") {
    assert.fail("expected terminal created path");
  }
  assert.equal(created.createdPath.terminal.id, TERMINAL);
  assert.equal(created.revision, "15");

  const exited = await session.terminal(TERMINAL).waitExit(decimalString("250"));
  assert.equal(exited.state, "exited");
  if (exited.state !== "exited") assert.fail("expected exited terminal");
  assert.deepEqual(exited.outcome, {
    kind: "signal",
    signal: 15,
    coreDumped: false,
  });

  assert.deepEqual(transport.requests.map((request) => request.operation), [
    "session.creation.resolve",
    "session.creation.resolve",
    "terminal.wait_exit",
  ]);
  assert.equal(
    (transport.requests[2]?.params as Envelope).timeout_ms,
    "250",
  );
  client.close();
});

test("all generation decoders enforce well-formed 128-byte UTF-8 bounds", async () => {
  const cases: ReadonlyArray<{
    readonly name: string;
    readonly call: (generation: string) => Promise<unknown>;
  }> = [
    {
      name: "ping cursor",
      call: async (generation) => {
        const transport = new FakeTransport((request, current) => {
          current.ok(request, {
            alive: true,
            cursor: { generation, revision: "1" },
          });
        });
        const client = new Client({ transport });
        try {
          return await client.session(SESSION).ping();
        } finally {
          client.close();
        }
      },
    },
    {
      name: "stream cursor",
      call: async (generation) => {
        const transport = new FakeTransport((request, current) => {
          current.ok(request, {
            stream_id: (request.params as Envelope).stream_id,
            cursor: { generation, revision: "1" },
          });
        });
        const client = new Client({ transport, randomHex128: () => HEX_A });
        try {
          return await client.session(SESSION).events();
        } finally {
          client.close();
        }
      },
    },
    {
      name: "session snapshot",
      call: async (generation) => {
        const transport = new FakeTransport((request, current) => {
          current.ok(request, {
            id: SESSION,
            machine_id: `machine_${HEX_A}`,
            generation,
            revision: "1",
            connected: true,
          });
        });
        const client = new Client({ transport });
        try {
          return await client.session(SESSION).refresh();
        } finally {
          client.close();
        }
      },
    },
    {
      name: "mutation result",
      call: async (generation) => {
        const transport = new FakeTransport((request, current) => {
          current.ok(request, {
            value: {
              id: WORKSPACE,
              session_id: SESSION,
              name: "renamed",
              index: 0,
              focused: true,
            },
            generation,
            revision: "1",
            replayed: false,
          });
        });
        const client = new Client({ transport });
        try {
          return await client.session(SESSION).workspace(WORKSPACE).rename(
            "renamed",
            { idempotencyKey: "generation-test" },
          );
        } finally {
          client.close();
        }
      },
    },
    {
      name: "creation resolution",
      call: async (generation) => {
        const transport = new FakeTransport((request, current) => {
          current.ok(request, {
            correlation_key: "generation-test",
            state: "created",
            recovery: "none",
            idempotency_key: "creation-key",
            created_path: {
              kind: "workspace",
              workspace_id: WORKSPACE,
            },
            generation,
            revision: "1",
          });
        });
        const client = new Client({ transport });
        try {
          return await client.session(SESSION).creation.resolve("generation-test");
        } finally {
          client.close();
        }
      },
    },
  ];

  for (const current of cases) {
    await assert.doesNotReject(
      () => current.call(UTF8_128),
      `${current.name} rejected an exact 128-byte generation`,
    );
    for (const invalid of [UTF8_129, ILL_FORMED_UNICODE]) {
      await assert.rejects(
        () => current.call(invalid),
        CmuxProtocolError,
        `${current.name} accepted an invalid generation`,
      );
    }
  }
});

test("creation resolution validates UTF-8 correlation and idempotency fields", async () => {
  const resolve = async (
    requestedCorrelation: string,
    responseCorrelation: string,
    responseIdempotency: string,
  ): Promise<unknown> => {
    const transport = new FakeTransport((request, current) => {
      current.ok(request, {
        correlation_key: responseCorrelation,
        state: "created",
        recovery: "none",
        idempotency_key: responseIdempotency,
        created_path: {
          kind: "workspace",
          workspace_id: WORKSPACE,
        },
        generation: UTF8_128,
        revision: "1",
      });
    });
    const client = new Client({ transport });
    try {
      return await client.session(SESSION).creation.resolve(requestedCorrelation);
    } finally {
      client.close();
    }
  };

  await assert.doesNotReject(() => resolve(UTF8_128, UTF8_128, UTF8_128));
  for (const invalid of [UTF8_129, ILL_FORMED_UNICODE]) {
    await assert.rejects(
      () => resolve("request-correlation", invalid, "response-key"),
      /correlation_key must contain 1 to 128 UTF-8 bytes/,
    );
  }
  for (const invalid of [
    UTF8_129,
    ILL_FORMED_UNICODE,
    " \u00a0\u2003 ",
    "key\u0000suffix",
  ]) {
    await assert.rejects(
      () => resolve("request-correlation", "request-correlation", invalid),
      /idempotency_key is not a valid idempotency key/,
    );
  }
});

test("creation and exit discriminators reject malformed catalog variants", async () => {
  const invalidResults = [
    {
      operation: "session.creation.resolve",
      result: {
        correlation_key: "created",
        state: "created",
        recovery: "wait",
        created_path: {
          kind: "workspace",
          workspace_id: WORKSPACE,
        },
        generation: "generation-a",
        revision: "1",
      },
      call: (client: Client) =>
        client.session(SESSION).creation.resolve("created"),
    },
    {
      operation: "terminal.wait_exit",
      result: {
        state: "pending",
        terminal_id: TERMINAL,
        lifecycle: "running",
        revision: "1",
        outcome: { kind: "exit", code: 0 },
      },
      call: (client: Client) => client.session(SESSION).terminal(TERMINAL).waitExit(),
    },
    {
      operation: "terminal.wait_exit",
      result: {
        state: "exited",
        terminal_id: TERMINAL,
        lifecycle: "exited",
        outcome: {
          kind: "signal",
          signal: 0,
          core_dumped: false,
        },
        exited_at: "2",
        revision: "3",
      },
      call: (client: Client) => client.session(SESSION).terminal(TERMINAL).waitExit(),
    },
  ] as const;

  for (const invalid of invalidResults) {
    const transport = new FakeTransport((request, current) => {
      assert.equal(request.operation, invalid.operation);
      current.ok(request, invalid.result);
    });
    const client = new Client({ transport });
    await assert.rejects(() => invalid.call(client));
    client.close();
  }
});

test("stream cancellation uses the opened route and purges buffered items", async () => {
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    current.ok(request, {});
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_B,
  });
  const stream = await client.session(SESSION).events();
  for (let index = 0; index < 2; index += 1) {
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: String(index),
      item: { kind: "future", index },
    });
  }
  const first = await stream.next();
  assert.equal(first.done, false);
  assert.deepEqual(first.value?.value, {
    kind: "future",
    raw: { kind: "future", index: 0 },
  });
  await stream.cancel();
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
  const cancel = transport.requests.find(
    (request) => request.operation === "stream.cancel",
  );
  assert.deepEqual(cancel?.params, {
    machine: "current",
    session: SESSION,
    stream: openedStream,
  });
  client.close();
});

test("public cancel discards stale items and shares one route cleanup", async () => {
  let openedStream = "";
  let cancelRequest: Envelope | undefined;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") {
      cancelRequest = request;
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_C,
  });
  const stream = await client.session(SESSION).events();
  const canceling = stream.cancel();
  assert.ok(cancelRequest);

  for (let index = 0; index <= 256; index += 1) {
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: String(index),
      item: { kind: "changed", data: { index } },
    });
  }
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    1,
  );

  transport.ok(cancelRequest, {});
  await canceling;
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    1,
  );
  client.close();
});

test("stream-open timeout cancels the route and restores stream quota", async () => {
  const openRequests: Envelope[] = [];
  let activeStream: unknown;
  let firstDecoded = 0;
  let secondDecoded = 0;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      if (activeStream !== undefined) {
        current.emit({
          protocol: "cmux.protocol/2",
          type: "response",
          id: request.id,
          ok: false,
          error: {
            code: "stream.quota_exhausted",
            message: "one stream allowed",
            details: {},
            retryable: true,
          },
        });
        return;
      }
      activeStream = (request.params as Envelope).stream_id;
      openRequests.push(request);
      if (openRequests.length === 2) {
        current.ok(request, { stream_id: activeStream });
      }
      return;
    }
    if (request.operation === "stream.cancel") {
      assert.equal((request.params as Envelope).stream, activeStream);
      activeStream = undefined;
      current.ok(request, {});
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const randomValues = [HEX_A, HEX_B];
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => randomValues.shift()!,
  });

  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => {
        firstDecoded += 1;
        return value;
      },
      { timeoutMs: 5 },
    ),
    CmuxTimeoutError,
  );

  const firstOpen = openRequests[0];
  assert.ok(firstOpen);
  const firstStream = (firstOpen.params as Envelope).stream_id;
  const cancel = transport.requests.find(
    (request) => request.operation === "stream.cancel",
  );
  assert.deepEqual(cancel?.params, {
    machine: "current",
    session: SESSION,
    stream: firstStream,
  });

  const second = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => {
      secondDecoded += 1;
      return value;
    },
  );
  const secondOpen = openRequests[1];
  assert.ok(secondOpen);
  const secondStream = (secondOpen.params as Envelope).stream_id;
  assert.notEqual(secondStream, firstStream);

  transport.ok(firstOpen, { stream_id: firstStream });
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: firstStream,
    sequence: "0",
    item: { kind: "late" },
  });
  assert.equal(firstDecoded, 0);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: secondStream,
    sequence: "0",
    item: { kind: "recovered" },
  });
  assert.equal((await second.next()).value?.value.kind, "recovered");
  assert.equal(secondDecoded, 1);
  await second.cancel();
  protocol.close();
});

test("structured stream-open rejection is conclusive and keeps the connection reusable", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.emit({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: false,
        error: {
          code: "stream.quota_exhausted",
          message: "one stream allowed",
          details: { limit: 1 },
          retryable: true,
        },
      });
      return;
    }
    if (request.operation === "session.ping") {
      current.ok(request, { alive: true });
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });

  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    ),
    (error: unknown) => (
      error instanceof ResourceError
      && error.code === "stream.quota_exhausted"
      && error.message === "one stream allowed"
      && error.retryable
    ),
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events"],
  );
  assert.deepEqual(transport.closeRequestCounts, []);
  assert.deepEqual(
    (await protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    )).value,
    { alive: true },
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "session.ping"],
  );
  protocol.close();
});

test("post-dispatch stream-open abort uses an independent cancellation", async () => {
  let openedStream: unknown;
  let decoded = 0;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id;
      return;
    }
    if (request.operation === "stream.cancel") {
      current.ok(request, {});
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_B,
  });
  const controller = new AbortController();
  const opening = protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => {
      decoded += 1;
      return value;
    },
    { signal: controller.signal },
  );
  assert.equal(transport.requests.length, 1);
  controller.abort();
  await assert.rejects(() => opening, CmuxAbortError);

  assert.deepEqual(
    transport.requests.find((request) => request.operation === "stream.cancel")?.params,
    {
      machine: "current",
      session: SESSION,
      stream: openedStream,
    },
  );
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: { kind: "late" },
  });
  assert.equal(decoded, 0);
  protocol.close();
});

test("malformed stream-open ACKs cancel without masking the protocol error", async () => {
  const cases = [
    {
      name: "non-object result",
      result: [] as unknown,
      message: /result must be an object/,
    },
    {
      name: "mismatched stream",
      result: { stream_id: `stream_${HEX_B}` },
      message: /returned stream/,
    },
    {
      name: "malformed cursor",
      result: {
        stream_id: `stream_${HEX_A}`,
        cursor: { generation: "generation-a" },
      },
      message: /cursor/,
    },
  ] as const;

  for (const fixture of cases) {
    let decoded = 0;
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        current.ok(request, fixture.result);
        return;
      }
      if (request.operation === "stream.cancel") {
        current.ok(request, {});
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      randomHex128: () => HEX_A,
    });
    await assert.rejects(
      () => protocol.openStream(
        operations.sessionEvents,
        { machine: "current", session: SESSION },
        (value) => {
          decoded += 1;
          return value;
        },
      ),
      fixture.message,
      fixture.name,
    );
    assert.equal(
      transport.requests.filter((request) => request.operation === "stream.cancel").length,
      1,
      fixture.name,
    );
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: `stream_${HEX_A}`,
      sequence: "0",
      item: { kind: "late" },
    });
    assert.equal(decoded, 0, fixture.name);
    assert.deepEqual(transport.closeRequestCounts, [], fixture.name);
    protocol.close();
  }
});

test("failed-open cleanup failure closes once without masking the open error", async () => {
  const cases = ["send", "dropped", "malformed"] as const;
  for (const failureMode of cases) {
    const cleanupSendError = new Error("stream.cancel transport send failed");
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        current.ok(request, { stream_id: `stream_${HEX_B}` });
        return;
      }
      if (request.operation === "stream.cancel") {
        if (failureMode === "send") throw cleanupSendError;
        if (failureMode === "malformed") {
          current.ok(request, { unexpected: true });
        }
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      randomHex128: () => HEX_A,
    });
    const started = Date.now();
    await assert.rejects(
      () => protocol.openStream(
        operations.sessionEvents,
        { machine: "current", session: SESSION },
        (value) => value,
      ),
      (error: unknown) => (
        error instanceof CmuxProtocolError
        && /returned stream/.test(error.message)
      ),
      failureMode,
    );
    assert.ok(Date.now() - started < 2_000, failureMode);
    assert.deepEqual(
      transport.requests.map((request) => request.operation),
      ["session.events", "stream.cancel"],
      failureMode,
    );
    assert.deepEqual(transport.closeRequestCounts, [2], failureMode);

    const requestCount = transport.requests.length;
    await assert.rejects(
      () => protocol.request(
        operations.sessionPing,
        { machine: "current", session: SESSION },
      ),
      (error: unknown) => (
        error instanceof CmuxConnectionError
        && /failed-open cleanup was not confirmed/.test(error.message)
      ),
      failureMode,
    );
    assert.equal(transport.requests.length, requestCount, failureMode);
    protocol.close();
    transport.error(new Error("late transport error"));
    assert.deepEqual(transport.closeRequestCounts, [2], failureMode);
  }
});

test("connection failure cancels every dispatched open before one close", async () => {
  const failure = new CmuxConnectionError("stream-open response transport failed");
  const openRequests: Envelope[] = [];
  let decoded = 0;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openRequests.push(request);
      return;
    }
    if (request.operation === "stream.cancel") {
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const randomValues = [HEX_A, HEX_B];
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => randomValues.shift()!,
  });
  const openings = [
    protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => {
        decoded += 1;
        return value;
      },
    ),
    protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => {
        decoded += 1;
        return value;
      },
    ),
  ];
  assert.equal(openRequests.length, 2);
  transport.error(failure);
  await Promise.all(
    openings.map(async (opening) => {
      await assert.rejects(
        () => opening,
        (error: unknown) => error === failure,
      );
    }),
  );
  const canceledStreams = transport.requests
    .filter((request) => request.operation === "stream.cancel")
    .map((request) => (request.params as Envelope).stream)
    .sort();
  assert.deepEqual(
    canceledStreams,
    openRequests
      .map((request) => (request.params as Envelope).stream_id)
      .sort(),
  );
  assert.deepEqual(transport.closeRequestCounts, [4]);

  for (const request of openRequests) {
    const id = (request.params as Envelope).stream_id;
    transport.ok(request, { stream_id: id });
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: id,
      sequence: "0",
      item: { kind: "late" },
    });
  }
  assert.equal(decoded, 0);
  protocol.close();
  transport.error(new Error("late transport error"));
  assert.deepEqual(transport.closeRequestCounts, [4]);
});

test("reentrant transport failure waits for dispatch before cleanup and close", async () => {
  const failure = new CmuxConnectionError("reentrant transport failure");
  let openedStream: unknown;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id;
      current.error(failure);
      return;
    }
    if (request.operation === "stream.cancel") return;
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_C,
  });

  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    ),
    (error: unknown) => error === failure,
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.equal(
    (transport.requests[1]?.params as Envelope).stream,
    openedStream,
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
});

test("valid stream-open ACK plus same-turn failure has one cleanup owner", async () => {
  const failure = new CmuxConnectionError("failure after stream-open ACK");
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.ok(request, {
        stream_id: (request.params as Envelope).stream_id,
      });
      current.error(failure);
      return;
    }
    if (request.operation === "stream.cancel") return;
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_C,
  });

  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    ),
    (error: unknown) => error === failure,
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [2]);
});

test("transport send throw after delivery closes without a guessed cancellation", async () => {
  const sendFailure = new Error("stream-open delivered then send threw");
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.ok(request, {
        stream_id: (request.params as Envelope).stream_id,
      });
      throw sendFailure;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  const opening = protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  const immediatePing = protocol.request(
    operations.sessionPing,
    { machine: "current", session: SESSION },
  );
  await assert.rejects(
    () => opening,
    (error: unknown) => error === sendFailure,
  );
  await assert.rejects(() => immediatePing, CmuxConnectionError);
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events"],
  );
  assert.deepEqual(transport.closeRequestCounts, [1]);
  await assert.rejects(
    () => protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    ),
    CmuxConnectionError,
  );
  assert.equal(transport.requests.length, 1);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [1]);
});

test("send throw downgrades queued reentrant cleanup before close", async () => {
  const connectionFailure = new Error("reentrant connection failure");
  const sendFailure = new Error("send failed after reentrant failure");
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.error(connectionFailure);
      throw sendFailure;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    ),
    (error: unknown) => error === sendFailure,
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events"],
  );
  assert.deepEqual(transport.closeRequestCounts, [1]);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [1]);
});

test("partial sibling send closes without appending stream cancellation", async () => {
  const sendFailure = new Error("partial ping transport send failed");
  const transport = new FakeTransport((request) => {
    if (request.operation === "session.events") return;
    if (request.operation === "session.ping") throw sendFailure;
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  const opening = protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  await assert.rejects(
    () => protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    ),
    (error: unknown) => error === sendFailure,
  );
  await assert.rejects(() => opening, CmuxConnectionError);
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "session.ping"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [2]);
});

test("stream-open failures before transport dispatch never emit cancellation", async () => {
  let sends = 0;
  const transport = new FakeTransport((request, current) => {
    sends += 1;
    if (request.operation === "session.ping") {
      current.ok(request, { alive: true });
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    () => protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
      { signal: controller.signal },
    ),
    CmuxAbortError,
  );
  assert.equal(sends, 0);
  assert.deepEqual(transport.closeRequestCounts, []);
  assert.deepEqual(
    (await protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    )).value,
    { alive: true },
  );
  assert.equal(sends, 1);
  protocol.close();
});

test("pre-aborted explicit cancellation can be retried", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.ok(request, {
        stream_id: (request.params as Envelope).stream_id,
      });
      return;
    }
    if (request.operation === "stream.cancel") {
      current.ok(request, {});
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  const stream = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    () => stream.cancel(controller.signal),
    CmuxAbortError,
  );
  assert.equal(
    transport.requests.filter(
      (request) => request.operation === "stream.cancel",
    ).length,
    0,
  );
  await stream.cancel();
  assert.equal(
    transport.requests.filter(
      (request) => request.operation === "stream.cancel",
    ).length,
    1,
  );
  protocol.close();
});

test("explicit cancellation requires response and canceled end in either order", async () => {
  for (const order of ["response-first", "end-first"] as const) {
    let openedStream = "";
    let cancelRequest: Envelope | undefined;
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        openedStream = (request.params as Envelope).stream_id as string;
        current.ok(request, { stream_id: openedStream });
        return;
      }
      if (request.operation === "stream.cancel") {
        cancelRequest = request;
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      timeoutMs: 100,
      randomHex128: () => HEX_A,
    });
    const stream = await protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    );
    let settled = false;
    const canceling = stream.cancel().then(() => {
      settled = true;
    });
    assert.ok(cancelRequest);
    const response = {
      protocol: "cmux.protocol/2",
      type: "response",
      id: cancelRequest.id,
      ok: true,
      result: {},
    };
    const end = {
      protocol: "cmux.protocol/2",
      type: "stream_end",
      stream_id: openedStream,
      reason: "canceled",
      cursor: { generation: "generation-a", revision: "4" },
      recovery: "cancellation confirmed",
    };
    transport.emit(order === "response-first" ? response : end);
    await Promise.resolve();
    assert.equal(settled, false, order);
    transport.emit(order === "response-first" ? end : response);
    await canceling;
    assert.equal(stream.end?.reason, "canceled");
    assert.deepEqual(stream.end?.cursor, {
      generation: "generation-a",
      revision: "4",
    });
    assert.equal(stream.end?.recovery, "cancellation confirmed");
    protocol.close();
  }
});

test("explicit cancellation rejects noncanonical or wrong stream ends and caches failure", async () => {
  const invalidEnds = [
    {
      name: "wrong reason",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "completed",
      }),
    },
    {
      name: "missing reason",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
      }),
    },
    {
      name: "unknown field",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "canceled",
        extra: true,
      }),
    },
    {
      name: "null cursor",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "canceled",
        cursor: null,
      }),
    },
    {
      name: "null recovery",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "canceled",
        recovery: null,
      }),
    },
    {
      name: "error on canceled end",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "canceled",
        error: null,
      }),
    },
    {
      name: "missing required error",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "error",
      }),
    },
    {
      name: "noncanonical embedded error",
      envelope: (stream: string) => ({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: stream,
        reason: "error",
        error: {
          code: "operation.failed",
          message: "failed",
          details: {},
          retryable: false,
          extra: true,
        },
      }),
    },
  ] as const;

  for (const fixture of invalidEnds) {
    let openedStream = "";
    let cancelRequest: Envelope | undefined;
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        openedStream = (request.params as Envelope).stream_id as string;
        current.ok(request, { stream_id: openedStream });
        return;
      }
      if (request.operation === "stream.cancel") {
        cancelRequest = request;
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      timeoutMs: 100,
      randomHex128: () => HEX_A,
    });
    const stream = await protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    );
    const canceling = stream.cancel();
    assert.ok(cancelRequest);
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "response",
      id: cancelRequest.id,
      ok: true,
      result: {},
    });
    transport.emit(fixture.envelope(openedStream));
    let firstError: unknown;
    try {
      await canceling;
      assert.fail(`${fixture.name} unexpectedly confirmed cancellation`);
    } catch (error) {
      firstError = error;
    }
    assert.ok(firstError instanceof CmuxProtocolError, fixture.name);
    await assert.rejects(
      () => stream.cancel(),
      (error: unknown) => error === firstError,
      fixture.name,
    );
    assert.equal(
      transport.requests.filter((request) => request.operation === "stream.cancel").length,
      1,
      fixture.name,
    );
    assert.deepEqual(transport.closeRequestCounts, [2], fixture.name);
    protocol.close();
  }
});

test("explicit cancellation rejects noncanonical responses and caches failure", async () => {
  const invalidResponses = [
    {
      name: "unknown response field",
      envelope: (request: Envelope) => ({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: true,
        result: {},
        extra: true,
      }),
    },
    {
      name: "result and error together",
      envelope: (request: Envelope) => ({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: true,
        result: {},
        error: {
          code: "operation.failed",
          message: "failed",
          details: {},
          retryable: false,
        },
      }),
    },
    {
      name: "nonempty result",
      envelope: (request: Envelope) => ({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: true,
        result: { unexpected: true },
      }),
    },
    {
      name: "noncanonical structured error",
      envelope: (request: Envelope) => ({
        protocol: "cmux.protocol/2",
        type: "response",
        id: request.id,
        ok: false,
        error: {
          code: "operation.failed",
          message: "failed",
          details: {},
          retryable: false,
          extra: true,
        },
      }),
    },
  ] as const;

  for (const fixture of invalidResponses) {
    let cancelRequest: Envelope | undefined;
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        current.ok(request, {
          stream_id: (request.params as Envelope).stream_id,
        });
        return;
      }
      if (request.operation === "stream.cancel") {
        cancelRequest = request;
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      timeoutMs: 100,
      randomHex128: () => HEX_A,
    });
    const stream = await protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    );
    const canceling = stream.cancel();
    assert.ok(cancelRequest);
    transport.emit(fixture.envelope(cancelRequest));
    let firstError: unknown;
    try {
      await canceling;
      assert.fail(`${fixture.name} unexpectedly confirmed cancellation`);
    } catch (error) {
      firstError = error;
    }
    assert.ok(firstError instanceof CmuxProtocolError, fixture.name);
    await assert.rejects(
      () => stream.cancel(),
      (error: unknown) => error === firstError,
      fixture.name,
    );
    assert.equal(
      transport.requests.filter((request) => request.operation === "stream.cancel").length,
      1,
      fixture.name,
    );
    assert.deepEqual(transport.closeRequestCounts, [2], fixture.name);
    protocol.close();
  }
});

test("explicit cancellation deadline covers missing halves and a wrong stream end", async () => {
  for (const caseName of ["missing-end", "missing-response", "wrong-stream"] as const) {
    let openedStream = "";
    let cancelRequest: Envelope | undefined;
    const transport = new FakeTransport((request, current) => {
      if (request.operation === "session.events") {
        openedStream = (request.params as Envelope).stream_id as string;
        current.ok(request, { stream_id: openedStream });
        return;
      }
      if (request.operation === "stream.cancel") {
        cancelRequest = request;
        return;
      }
      assert.fail(`unexpected operation ${String(request.operation)}`);
    });
    const protocol = new ResourceProtocol({
      transport,
      timeoutMs: 20,
      randomHex128: () => HEX_A,
    });
    const stream = await protocol.openStream(
      operations.sessionEvents,
      { machine: "current", session: SESSION },
      (value) => value,
    );
    const canceling = stream.cancel();
    assert.ok(cancelRequest);
    if (caseName !== "missing-response") {
      transport.emit({
        protocol: "cmux.protocol/2",
        type: "response",
        id: cancelRequest.id,
        ok: true,
        result: {},
      });
    }
    if (caseName !== "missing-end") {
      transport.emit({
        protocol: "cmux.protocol/2",
        type: "stream_end",
        stream_id: caseName === "wrong-stream"
          ? `stream_${HEX_B}`
          : openedStream,
        reason: "canceled",
      });
    }
    await assert.rejects(() => canceling, CmuxTimeoutError, caseName);
    assert.deepEqual(transport.closeRequestCounts, [2], caseName);
    protocol.close();
  }
});

test("malformed stale item fails cancellation closed without a second request", async () => {
  let openedStream = "";
  let cancelRequest: Envelope | undefined;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") {
      cancelRequest = request;
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    timeoutMs: 100,
    randomHex128: () => HEX_A,
  });
  const stream = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  const canceling = stream.cancel();
  assert.ok(cancelRequest);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "response",
    id: cancelRequest.id,
    ok: true,
    result: {},
  });
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: { kind: "future" },
    extra: true,
  });
  await assert.rejects(() => canceling, CmuxProtocolError);
  await assert.rejects(() => stream.cancel(), CmuxProtocolError);
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    1,
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  protocol.close();
});

test("public cancellation validates typed stale events after end and before response", async () => {
  let openedStream = "";
  let cancelRequest: Envelope | undefined;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") {
      cancelRequest = request;
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const client = new Client({
    transport,
    timeoutMs: 100,
    randomHex128: () => HEX_A,
  });
  const session = client.session(SESSION);
  const stream = await session.events();
  const canceling = stream.cancel();
  assert.ok(cancelRequest);
  let cancelSettled = false;
  void canceling.then(
    () => {
      cancelSettled = true;
    },
    () => {
      cancelSettled = true;
    },
  );
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_end",
    stream_id: openedStream,
    reason: "canceled",
  });
  await Promise.resolve();
  assert.equal(cancelSettled, false);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: {
      kind: "snapshot",
      cursor: { generation: "generation-a", revision: "0" },
      snapshot: null,
    },
  });
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "response",
    id: cancelRequest.id,
    ok: true,
    result: {},
  });

  let firstError: unknown;
  try {
    await canceling;
    assert.fail("malformed typed stale item unexpectedly confirmed cancellation");
  } catch (error) {
    firstError = error;
  }
  assert.ok(firstError instanceof CmuxProtocolError);
  assert.match(firstError.message, /resource snapshot must be an object/);
  await assert.rejects(
    () => stream.cancel(),
    (error: unknown) => error === firstError,
  );
  await assert.rejects(
    () => session.ping(),
    (error: unknown) => {
      assert.ok(error instanceof CmuxConnectionError);
      assert.match(
        error.message,
        /stream cancellation was not confirmed: CmuxProtocolError: resource snapshot must be an object/,
      );
      return true;
    },
  );
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    1,
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  client.close();
});

test("public cancellation rejects valid typed events after end and before response", async () => {
  let openedStream = "";
  let cancelRequest: Envelope | undefined;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") {
      cancelRequest = request;
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const client = new Client({
    transport,
    timeoutMs: 100,
    randomHex128: () => HEX_A,
  });
  const session = client.session(SESSION);
  const stream = await session.events();
  const canceling = stream.cancel();
  assert.ok(cancelRequest);
  let cancelSettled = false;
  void canceling.then(
    () => {
      cancelSettled = true;
    },
    () => {
      cancelSettled = true;
    },
  );
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_end",
    stream_id: openedStream,
    reason: "canceled",
  });
  await Promise.resolve();
  assert.equal(cancelSettled, false);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: {
      kind: "delta",
      cursor: { generation: "generation-a", revision: "1" },
      previous_revision: "0",
      revision: "1",
      changes: [],
    },
  });
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "response",
    id: cancelRequest.id,
    ok: true,
    result: {},
  });

  let firstError: unknown;
  try {
    await canceling;
    assert.fail("post-end typed item unexpectedly confirmed cancellation");
  } catch (error) {
    firstError = error;
  }
  assert.ok(firstError instanceof CmuxProtocolError);
  assert.match(firstError.message, /stream item received after end envelope/);
  await assert.rejects(
    () => stream.cancel(),
    (error: unknown) => error === firstError,
  );
  await assert.rejects(
    () => session.ping(),
    (error: unknown) => {
      assert.ok(error instanceof CmuxConnectionError);
      assert.match(
        error.message,
        /stream cancellation was not confirmed: CmuxProtocolError: stream item received after end envelope/,
      );
      return true;
    },
  );
  assert.equal(
    transport.requests.filter((request) => request.operation === "stream.cancel").length,
    1,
  );
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  client.close();
});

test("stream item envelopes reject unknown top-level fields and fail closed", async () => {
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    assert.equal(request.operation, "session.events");
    openedStream = (request.params as Envelope).stream_id as string;
    current.ok(request, { stream_id: openedStream });
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  const stream = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  const next = stream.next();
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "stream_item",
    stream_id: openedStream,
    sequence: "0",
    item: { kind: "future" },
    extra: true,
  });
  await assert.rejects(() => next, CmuxProtocolError);
  assert.deepEqual(transport.closeRequestCounts, [1]);
  await assert.rejects(
    () => protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    ),
    CmuxProtocolError,
  );
  protocol.close();
});

test("stale item drip cannot restart the explicit cancellation deadline", async () => {
  let openedStream = "";
  let cancelRequest: Envelope | undefined;
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") {
      cancelRequest = request;
      return;
    }
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    timeoutMs: 50,
    randomHex128: () => HEX_A,
  });
  const stream = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  const started = Date.now();
  const canceling = stream.cancel();
  assert.ok(cancelRequest);
  transport.emit({
    protocol: "cmux.protocol/2",
    type: "response",
    id: cancelRequest.id,
    ok: true,
    result: {},
  });
  let sequence = 0;
  const drip = setInterval(() => {
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: String(sequence),
      item: { kind: "future", sequence },
    });
    sequence += 1;
  }, 5);
  try {
    await assert.rejects(() => canceling, CmuxTimeoutError);
  } finally {
    clearInterval(drip);
  }
  assert.ok(Date.now() - started < 150);
  assert.deepEqual(transport.closeRequestCounts, [2]);
  protocol.close();
});

test("explicit cancel timeout closes the owning connection", async () => {
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      current.ok(request, {
        stream_id: (request.params as Envelope).stream_id,
      });
      return;
    }
    if (request.operation === "stream.cancel") return;
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    timeoutMs: 20,
    randomHex128: () => HEX_A,
  });
  const stream = await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  await assert.rejects(() => stream.cancel(), CmuxTimeoutError);
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  const requestCount = transport.requests.length;
  await assert.rejects(
    () => protocol.request(
      operations.sessionPing,
      { machine: "current", session: SESSION },
    ),
    CmuxConnectionError,
  );
  assert.equal(transport.requests.length, requestCount);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [2]);
});

test("overflow cancel failure closes the owning connection", async () => {
  const cancelFailure = new Error("overflow cancel send failed");
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "stream.cancel") throw cancelFailure;
    assert.fail(`unexpected operation ${String(request.operation)}`);
  });
  const protocol = new ResourceProtocol({
    transport,
    randomHex128: () => HEX_A,
  });
  await protocol.openStream(
    operations.sessionEvents,
    { machine: "current", session: SESSION },
    (value) => value,
  );
  for (let index = 0; index <= 256; index += 1) {
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: String(index),
      item: { kind: "changed", data: { index } },
    });
  }
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(
    transport.requests.map((request) => request.operation),
    ["session.events", "stream.cancel"],
  );
  assert.deepEqual(transport.closeRequestCounts, [2]);
  protocol.close();
  assert.deepEqual(transport.closeRequestCounts, [2]);
});

test("stream overflow is isolated and sends best-effort selector cancellation", async () => {
  let openedStream = "";
  const transport = new FakeTransport((request, current) => {
    if (request.operation === "session.events") {
      openedStream = (request.params as Envelope).stream_id as string;
      current.ok(request, { stream_id: openedStream });
      return;
    }
    if (request.operation === "session.ping") {
      current.ok(request, {
        alive: true,
        cursor: { generation: "generation-a", revision: "9" },
      });
      return;
    }
    current.ok(request, {});
  });
  const client = new Client({
    transport,
    randomHex128: () => HEX_C,
  });
  const session = client.session(SESSION);
  const stream = await session.events();
  for (let index = 0; index <= 256; index += 1) {
    transport.emit({
      protocol: "cmux.protocol/2",
      type: "stream_item",
      stream_id: openedStream,
      sequence: String(index),
      item: { kind: "changed", data: { index } },
    });
  }
  await assert.rejects(() => stream.next(), StreamError);

  const ping = await session.ping();
  assert.deepEqual(ping, {
    alive: true,
    cursor: { generation: "generation-a", revision: "9" },
  });
  const cancel = transport.requests.find(
    (request) => request.operation === "stream.cancel",
  );
  assert.deepEqual(cancel?.params, {
    machine: "current",
    session: SESSION,
    stream: openedStream,
  });
  assert.equal(cancel?.idempotency_key, undefined);
  client.close();
});

test("renderer grants are redacted and one-use", () => {
  const grant = new RendererGrant(
    "renderer-secret",
    "unix:///tmp/renderer.sock",
    TERMINAL,
    ["render"],
    1_000,
  );
  assert.equal(String(grant), "<redacted>");
  assert.equal(grant.take(), "renderer-secret");
  assert.throws(() => grant.take(), /already consumed/);
});
