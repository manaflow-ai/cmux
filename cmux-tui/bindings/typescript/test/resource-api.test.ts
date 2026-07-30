import assert from "node:assert/strict";
import test from "node:test";

import {
  Client,
  CmuxAbortError,
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

type Envelope = Record<string, unknown>;

class FakeTransport implements Transport {
  readonly requests: Envelope[] = [];
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

  close(): void {}

  emit(envelope: Envelope): void {
    const json = JSON.stringify(envelope);
    for (const handler of this.messages) handler(json);
  }

  ok(request: Envelope, result: unknown): void {
    this.emit({
      protocol: "cmux.protocol/1",
      type: "response",
      id: request.id,
      ok: true,
      result,
    });
  }
}

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

test("created paths are strict runtime variants and fixed operations reject mismatches", async () => {
  const transport = new FakeTransport((request, current) => {
    const params = request.params as Envelope;
    if (request.operation === "workspace.create") {
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
      protocol: "cmux.protocol/1",
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
      protocol: "cmux.protocol/1",
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
      protocol: "cmux.protocol/1",
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
      protocol: "cmux.protocol/1",
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
    protocol: "cmux.protocol/1",
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
    protocol: "cmux.protocol/1",
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

test("aborted terminal waits retain bounded capacity until response or server deadline", async () => {
  const transport = new FakeTransport((request, current) => {
    if (transport.requests.length === 10) {
      current.ok(request, { matched: false, text: "" });
    }
  });
  const client = new Client({ transport, timeoutMs: 200 });
  const terminal = client.session(SESSION).terminal(TERMINAL);
  const controllers = Array.from({ length: 8 }, () => new AbortController());
  const waits = controllers.map((controller) =>
    terminal.wait(
      { pattern: "never" },
      { signal: controller.signal },
    )
  );
  controllers.forEach((controller) => controller.abort());
  await Promise.all(waits.map((wait) => assert.rejects(() => wait, CmuxAbortError)));

  await assert.rejects(
    () => terminal.wait({ pattern: "blocked" }),
    (error: unknown) => {
      assert.ok(error instanceof CmuxProtocolError);
      assert.match(error.message, /terminal wait capacity is 8/);
      return true;
    },
  );
  assert.equal(transport.requests.length, 8);
  assert.deepEqual(
    transport.requests.map((request) => (request.params as Envelope).timeout_ms),
    Array(8).fill("200"),
  );

  transport.ok(transport.requests[0]!, { matched: false, text: "" });
  const replacementController = new AbortController();
  const replacement = terminal.wait(
    { pattern: "replacement" },
    { signal: replacementController.signal },
  );
  replacementController.abort();
  await assert.rejects(() => replacement, CmuxAbortError);
  assert.equal(transport.requests.length, 9);
  await assert.rejects(
    () => terminal.wait({ pattern: "still-blocked" }),
    /terminal wait capacity is 8/,
  );
  assert.equal(transport.requests.length, 9);

  await new Promise((resolve) => setTimeout(resolve, 225));
  await assert.rejects(
    () => terminal.wait({ pattern: "grace-protected" }),
    /terminal wait capacity is 8/,
  );
  assert.equal(transport.requests.length, 9);

  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal((await terminal.wait({ pattern: "reusable" })).matched, false);
  assert.equal(transport.requests.length, 10);
  client.close();
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
    protocol: "cmux.protocol/1",
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
            projection: { kind: "tree", tabs: 2 },
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
    protocol: "cmux.protocol/1",
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
      current.ok(request, { stream_id: openedStream });
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
    protocol: "cmux.protocol/1",
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
    protocol: "cmux.protocol/1",
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
      current.ok(request, { stream_id: openedStream });
    });
    const client = new Client({
      transport,
      randomHex128: () => HEX_C,
    });
    const stream = await client.session(SESSION).browser(BROWSER).attach();
    transport.emit({
      protocol: "cmux.protocol/1",
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
      tab_id: TAB,
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
      protocol: "cmux.protocol/1",
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
      protocol: "cmux.protocol/1",
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
