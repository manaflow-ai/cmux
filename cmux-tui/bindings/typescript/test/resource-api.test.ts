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
  browserId,
  paneId,
  RendererGrant,
  ResourceError,
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
