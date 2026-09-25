import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { NewlineFrameBuffer } from "../src/internal/newline-frame-buffer.js";
import {
  Client,
  CmuxAbortError,
  CmuxTimeoutError,
  decimalString,
  NodeClient,
  sessionId,
  terminalId,
  type Transport,
  workspaceId,
} from "../src/node.js";
import {
  UnixSocketTransport,
  defaultSocketPath,
  defaultSocketPaths,
  envSocketPath,
  validateSessionName,
  validateUnixSocketPath,
  type UnixSocketTransportOptions,
} from "../src/node-transport.js";
import { CmuxClient } from "../src/raw/node-client.js";
import {
  CmuxAbortError as RawCmuxAbortError,
  CmuxTimeoutError as RawCmuxTimeoutError,
} from "../src/raw/errors.js";

const RESOURCE_SESSION = sessionId(`session_${"a".repeat(32)}`);
const RESOURCE_WORKSPACE = workspaceId(`ws_${"b".repeat(32)}`);
const RESOURCE_TERMINAL = terminalId(`term_${"c".repeat(32)}`);

function withSocketRuntime<T>(run: () => T): T {
  const previousXdg = process.env.XDG_RUNTIME_DIR;
  const previousTmp = process.env.TMPDIR;
  process.env.XDG_RUNTIME_DIR = "/run/user/501";
  delete process.env.TMPDIR;
  try {
    return run();
  } finally {
    if (previousXdg === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = previousXdg;
    if (previousTmp === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previousTmp;
  }
}

async function withSocketRuntimeAsync<T>(run: () => Promise<T>): Promise<T> {
  const previousXdg = process.env.XDG_RUNTIME_DIR;
  const previousTmp = process.env.TMPDIR;
  process.env.XDG_RUNTIME_DIR = "/run/user/501";
  delete process.env.TMPDIR;
  try {
    return await run();
  } finally {
    if (previousXdg === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = previousXdg;
    if (previousTmp === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previousTmp;
  }
}

test("session socket helpers enforce the relaxed safe-name contract", () => {
  for (const session of [
    "",
    ".",
    "..",
    "../escape",
    "nested/session",
    "nested\\session",
    "bad\u0000name",
    "bad\nname",
    "bad\u0085name",
    "bad\u2028name",
    "bad\u2029name",
    "bad\ud800name",
  ]) {
    assert.throws(
      () => validateSessionName(session),
      /session name must be a non-empty path component/,
      `accepted unsafe session ${JSON.stringify(session)}`,
    );
    assert.throws(() => defaultSocketPath(session));
  }

  for (const session of [
    "legacy name",
    "名前",
    "_leading",
    "-leading",
    ".leading",
    "legacy:colon",
  ]) {
    assert.doesNotThrow(() => validateSessionName(session));
    assert.ok(defaultSocketPath(session).endsWith(`/${session}.sock`));
  }
  assert.doesNotThrow(() => validateSessionName(`legacy-${"x".repeat(200)}`));
});

test("preferred runtime socket wins over the raw /tmp compatibility path", () => {
  withSocketRuntime(() => {
    const session = "main";
    assert.equal(
      defaultSocketPath(session),
      join("/run/user/501", `cmux-tui-${process.getuid?.() ?? 0}`, `${session}.sock`),
    );
  });
});

test("long session socket paths use a bindable digest fallback", async () => {
  await withSocketRuntimeAsync(async () => {
    const session = `legacy-${"x".repeat(200)}`;
    const digest = "e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2";
    const socketPath = defaultSocketPath(session);
    assert.equal(
      socketPath,
      join(
        "/run/user/501",
        `cmux-tui-hashed-${process.getuid?.() ?? 0}`,
        `${digest}.sock`,
      ),
    );
    const capacity = process.platform === "darwin" ? 104 : 108;
    assert.ok(Buffer.byteLength(socketPath) < capacity);

    const directory = await mkdtemp(join(tmpdir(), "c-"));
    const leafLength = Buffer.byteLength(socketPath) - Buffer.byteLength(directory) - 1;
    assert.ok(leafLength >= 5);
    const bindPath = join(directory, `${"x".repeat(leafLength - 5)}.sock`);
    assert.equal(Buffer.byteLength(bindPath), Buffer.byteLength(socketPath));
    const server = createServer();
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(bindPath, resolve);
      });
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await rm(directory, { recursive: true, force: true });
    }
  });
});

test("non-ASCII long session paths use the shared UTF-8 SHA-256 digest", () => {
  withSocketRuntime(() => {
    const session = "\u540D\u524D".repeat(100);
    const digest = "0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3";
    const socketPath = defaultSocketPath(session);
    assert.equal(
      socketPath,
      join(
        "/run/user/501",
        `cmux-tui-hashed-${process.getuid?.() ?? 0}`,
        `${digest}.sock`,
      ),
    );
  });
});

test("hashed session paths fall back to /tmp when the runtime base is too long", () => {
  const previousXdg = process.env.XDG_RUNTIME_DIR;
  const previousTmp = process.env.TMPDIR;
  process.env.XDG_RUNTIME_DIR = join("/tmp", "x".repeat(200));
  delete process.env.TMPDIR;
  try {
    const session = `legacy-${"x".repeat(200)}`;
    const socketPath = defaultSocketPath(session);
    assert.ok(
      socketPath.startsWith(
        join("/tmp", `cmux-tui-hashed-${process.getuid?.() ?? 0}`) + "/",
      ),
    );
  } finally {
    if (previousXdg === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = previousXdg;
    if (previousTmp === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previousTmp;
  }
});

test("socket discovery ignores TMP and TEMP outside the contract", () => {
  const previousXdg = process.env.XDG_RUNTIME_DIR;
  const previousTmpdir = process.env.TMPDIR;
  const previousTmp = process.env.TMP;
  const previousTemp = process.env.TEMP;
  delete process.env.XDG_RUNTIME_DIR;
  delete process.env.TMPDIR;
  process.env.TMP = "/tmp/node-tmp-override";
  process.env.TEMP = "/tmp/node-temp-override";
  try {
    assert.equal(
      defaultSocketPath("main"),
      join("/tmp", `cmux-tui-${process.getuid?.() ?? 0}`, "main.sock"),
    );
  } finally {
    if (previousXdg === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = previousXdg;
    if (previousTmpdir === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previousTmpdir;
    if (previousTmp === undefined) delete process.env.TMP;
    else process.env.TMP = previousTmp;
    if (previousTemp === undefined) delete process.env.TEMP;
    else process.env.TEMP = previousTemp;
  }
});

test("socket candidates keep long sessions bindable and short sessions canonical", () => {
  withSocketRuntime(() => {
    const capacity = process.platform === "darwin" ? 104 : 108;
    const longSession = `legacy-${"x".repeat(200)}`;
    const longCandidates = defaultSocketPaths(longSession);
    assert.ok(longCandidates.length > 0);
    assert.ok(longCandidates.every((candidate) => Buffer.byteLength(candidate) < capacity));
    assert.ok(longCandidates.every((candidate) => candidate.includes("-hashed-")));
    assert.ok(longCandidates.every((candidate) => !candidate.endsWith(`/${longSession}.sock`)));

    const shortSession = "main";
    const shortCandidates = defaultSocketPaths(shortSession);
    assert.ok(
      shortCandidates[0].endsWith(
        `/cmux-tui-${process.getuid?.() ?? 0}/${shortSession}.sock`,
      ),
    );
    assert.ok(shortCandidates.every((candidate) => !candidate.includes("-hashed-")));
    assert.equal(defaultSocketPath(shortSession), shortCandidates[0]);
  });
});

test("explicit and environment socket paths remain authoritative", () => {
  const previousTui = process.env.CMUX_TUI_SOCKET;
  const previousMux = process.env.CMUX_MUX_SOCKET;
  try {
    process.env.CMUX_MUX_SOCKET = "/tmp/legacy-authority.sock";
    delete process.env.CMUX_TUI_SOCKET;
    assert.equal(envSocketPath(), "/tmp/legacy-authority.sock");
    process.env.CMUX_TUI_SOCKET = "/tmp/explicit-authority.sock";
    assert.equal(envSocketPath(), "/tmp/explicit-authority.sock");
  } finally {
    if (previousTui === undefined) delete process.env.CMUX_TUI_SOCKET;
    else process.env.CMUX_TUI_SOCKET = previousTui;
    if (previousMux === undefined) delete process.env.CMUX_MUX_SOCKET;
    else process.env.CMUX_MUX_SOCKET = previousMux;
  }
});

test("explicit socket paths are rejected before Node attempts an invalid bind", () => {
  const capacity = process.platform === "darwin" ? 104 : 108;
  assert.doesNotThrow(() => validateUnixSocketPath("/tmp/short.sock"));
  assert.throws(
    () => validateUnixSocketPath(`/tmp/${"x".repeat(capacity)}.sock`),
    /exceeds .*byte platform limit/,
  );
  assert.throws(
    () => new UnixSocketTransport(`/tmp/${"x".repeat(capacity)}.sock`),
    /exceeds .*byte platform limit/,
  );
});

test("Linux abstract socket paths remain supported", () => {
  if (process.platform === "linux") {
    assert.doesNotThrow(() => validateUnixSocketPath("\u0000cmux-tui-test"));
  } else {
    assert.throws(
      () => validateUnixSocketPath("\u0000cmux-tui-test"),
      /only supported on Linux/,
    );
  }
});

test("explicit empty socket paths fail with a typed validation error", () => {
  const message = "socketPath must be a non-empty path";
  assert.throws(() => new NodeClient({ socketPath: "" }), (error: unknown) =>
    error instanceof TypeError && error.message === message,
  );
  assert.throws(() => new CmuxClient({ socketPath: "" }), (error: unknown) =>
    error instanceof TypeError && error.message === message,
  );
});
interface DelayedUnixFixture {
  readonly transport: UnixSocketTransport;
  readonly received: string[];
  ready(): Promise<void>;
  release(): Promise<void>;
  respond(json: string): void;
  close(): Promise<void>;
}

async function delayedUnixFixture(
  options: UnixSocketTransportOptions = {},
): Promise<DelayedUnixFixture> {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-delayed-"));
  const socketPath = join(directory, "session.sock");
  const received: string[] = [];
  let peer: Socket | undefined;
  const server = createServer((socket) => {
    peer = socket;
    socket.setEncoding("utf8");
    let buffered = "";
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      for (;;) {
        const newline = buffered.indexOf("\n");
        if (newline < 0) return;
        received.push(buffered.slice(0, newline));
        buffered = buffered.slice(newline + 1);
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  const transport = new UnixSocketTransport(socketPath, options);
  const socket = (transport as unknown as { readonly socket: Socket }).socket;
  const connectListener = socket.listeners("connect").at(-1) as
    | (() => void)
    | undefined;
  assert.ok(connectListener);
  socket.removeListener("connect", connectListener);
  const physicallyConnected = new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      socket.removeListener("connect", connected);
      socket.removeListener("error", failed);
      socket.removeListener("close", closed);
    };
    const connected = () => {
      cleanup();
      resolve();
    };
    const failed = (error: Error) => {
      cleanup();
      reject(error);
    };
    const closed = () => {
      cleanup();
      reject(new Error("fixture socket closed before connect"));
    };
    socket.once("connect", connected);
    socket.prependOnceListener("error", failed);
    socket.once("close", closed);
  });
  void physicallyConnected.catch(() => undefined);
  let released = false;
  return {
    transport,
    received,
    async ready() {
      await physicallyConnected;
    },
    async release() {
      if (released) return;
      released = true;
      await physicallyConnected;
      connectListener.call(socket);
      await new Promise<void>((resolve) => setTimeout(resolve, 20));
    },
    respond(json: string) {
      assert.ok(peer);
      peer.write(`${json}\n`);
    },
    async close() {
      transport.close();
      peer?.destroy();
      await new Promise<void>((resolve, reject) =>
        server.close((error) => error ? reject(error) : resolve())
      );
      await rm(directory, { recursive: true, force: true });
    },
  };
}

test("delayed Unix fixture rejects when the socket fails before connect", async () => {
  const fixture = await delayedUnixFixture();
  const socket = (
    fixture.transport as unknown as { readonly socket: Socket }
  ).socket;
  const ready = fixture.ready().then(
    () => ({ state: "resolved" as const }),
    (error: unknown) => ({ state: "rejected" as const, error }),
  );

  try {
    socket.emit("error", new Error("fixture connect failed"));
    socket.destroy();
    const outcome = await Promise.race([
      ready,
      new Promise<{ state: "pending" }>((resolve) => {
        setTimeout(() => resolve({ state: "pending" }), 50);
      }),
    ]);
    assert.equal(outcome.state, "rejected");
    if (outcome.state === "rejected") {
      assert.match(String(outcome.error), /fixture connect failed/);
    }
  } finally {
    await fixture.close();
  }
});

function unixResourceOperationCount(
  fixture: DelayedUnixFixture,
  operation: string,
): number {
  return fixture.received.filter((json) =>
    (JSON.parse(json) as { operation?: unknown }).operation === operation
  ).length;
}

function rawMutation(id: number): Record<string, unknown> {
  return {
    id,
    cmd: "rename-workspace",
    workspace: 7,
    name: "never-sent",
  };
}

function abortableRawSend(
  client: CmuxClient,
  request: Record<string, unknown>,
  signal: AbortSignal,
): Promise<unknown> {
  const sendRaw = client.sendRaw.bind(client) as unknown as (
    request: Record<string, unknown>,
    options: { readonly signal: AbortSignal },
  ) => Promise<unknown>;
  return sendRaw(request, { signal });
}

test("Unix resource transport drops a read that expires before connect", async () => {
  const fixture = await delayedUnixFixture();
  const client = new Client({ transport: fixture.transport, timeoutMs: 10 });
  try {
    const ping = client.session(RESOURCE_SESSION).ping();
    await assert.rejects(() => ping, CmuxTimeoutError);
    await fixture.release();
    assert.deepEqual(fixture.received, []);
  } finally {
    client.close();
    await fixture.close();
  }
});

test("Unix transport close suppresses queued connect errors", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-tui-close-"));
  try {
    const transport = new UnixSocketTransport(join(directory, "missing.sock"));
    const errors: Error[] = [];
    transport.onError((error) => errors.push(error));
    const closed = new Promise<void>((resolve) => transport.onClose(resolve));
    transport.close();
    await closed;
    assert.deepEqual(errors, []);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Unix resource transport keeps a queued mutation timeout determinate", async () => {
  const fixture = await delayedUnixFixture();
  const client = new Client({
    transport: fixture.transport,
    randomHex128: () => "c".repeat(32),
  });
  try {
    const renaming = client
      .session(RESOURCE_SESSION)
      .workspace(RESOURCE_WORKSPACE)
      .rename("queued", { timeoutMs: 10 });
    const failure = await renaming.then(
      () => undefined,
      (error: unknown) => error,
    );
    await fixture.release();
    assert.ok(failure instanceof CmuxTimeoutError);
    assert.deepEqual(fixture.received, []);
  } finally {
    client.close();
    await fixture.close();
  }
});

test("Unix resource transport keeps a queued mutation abort determinate", async () => {
  const fixture = await delayedUnixFixture();
  const client = new Client({
    transport: fixture.transport,
    randomHex128: () => "d".repeat(32),
  });
  const controller = new AbortController();
  try {
    const renaming = client
      .session(RESOURCE_SESSION)
      .workspace(RESOURCE_WORKSPACE)
      .rename("queued", { signal: controller.signal });
    controller.abort();
    const failure = await renaming.then(
      () => undefined,
      (error: unknown) => error,
    );
    await fixture.release();
    assert.ok(failure instanceof CmuxAbortError);
    assert.deepEqual(fixture.received, []);
  } finally {
    client.close();
    await fixture.close();
  }
});

test("raw Unix transport cancels a mutation that times out before connect", async () => {
  const fixture = await delayedUnixFixture();
  const client = new CmuxClient({ transport: fixture.transport, timeoutMs: 10 });
  try {
    const request = client.sendRaw(rawMutation(201) as never);
    await assert.rejects(() => request, RawCmuxTimeoutError);
    await fixture.release();
    assert.deepEqual(fixture.received, []);
  } finally {
    await client.close();
    await fixture.close();
  }
});

test("raw Unix transport cancels a mutation aborted before connect", async () => {
  const fixture = await delayedUnixFixture();
  const client = new CmuxClient({ transport: fixture.transport, timeoutMs: 1_000 });
  const controller = new AbortController();
  try {
    const request = abortableRawSend(client, rawMutation(202), controller.signal);
    controller.abort();
    await assert.rejects(() => request, RawCmuxAbortError);
    await fixture.release();
    assert.deepEqual(fixture.received, []);
  } finally {
    await client.close();
    await fixture.close();
  }
});

test("raw Unix transport vetoes a mutation whose timer was synchronously starved", async () => {
  const fixture = await delayedUnixFixture();
  const client = new CmuxClient({ transport: fixture.transport, timeoutMs: 5 });
  try {
    await fixture.ready();
    const request = client.sendRaw(rawMutation(203) as never);
    const outcome = request.then(
      () => undefined,
      (error: unknown) => error,
    );

    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    await fixture.release();
    const failure = await outcome;

    assert.ok(failure instanceof RawCmuxTimeoutError);
    assert.deepEqual(fixture.received, []);
  } finally {
    await client.close();
    await fixture.close();
  }
});

test("raw Unix zero timeout dispatches once before timer settlement", async () => {
  const fixture = await delayedUnixFixture();
  const client = new CmuxClient({
    transport: fixture.transport,
    timeoutMs: 1_000,
    maxPendingResponses: 1,
  });
  try {
    await fixture.release();
    const request = client.sendRaw(
      rawMutation(204) as never,
      { timeoutMs: 0 },
    );
    await assert.rejects(() => request, RawCmuxTimeoutError);
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(
      fixture.received.map((json) => (JSON.parse(json) as { id?: unknown }).id),
      [204],
    );

    const followup = client.sendRaw({ id: 205, cmd: "ping" });
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    fixture.respond('{"id":205,"ok":true,"data":{"alive":true}}');
    assert.equal((await followup).ok, true);
    assert.deepEqual(
      fixture.received.map((json) => (JSON.parse(json) as { id?: unknown }).id),
      [204, 205],
    );
  } finally {
    await client.close();
    await fixture.close();
  }
});

test("Unix resource transport vetoes a mutation whose timer was synchronously starved", async () => {
  const fixture = await delayedUnixFixture();
  const client = new Client({
    transport: fixture.transport,
    randomHex128: () => "f".repeat(32),
  });
  try {
    await fixture.ready();
    const renaming = client
      .session(RESOURCE_SESSION)
      .workspace(RESOURCE_WORKSPACE)
      .rename("expired", { timeoutMs: 5 });
    const outcome = renaming.then(
      () => undefined,
      (error: unknown) => error,
    );

    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    await fixture.release();
    const failure = await outcome;

    assert.ok(failure instanceof CmuxTimeoutError);
    assert.deepEqual(fixture.received, []);
  } finally {
    client.close();
    await fixture.close();
  }
});

test("Unix cancellable connect queue preserves FIFO around removed frames", async () => {
  const fixture = await delayedUnixFixture();
  const dispatched: string[] = [];
  const transport: Transport = fixture.transport;
  try {
    assert.ok(transport.sendCancellable);
    transport.sendCancellable("first", () => dispatched.push("first"));
    const cancelSecond = transport.sendCancellable(
      "second",
      () => dispatched.push("second"),
    );
    transport.sendCancellable("third", () => dispatched.push("third"));
    cancelSecond();

    await fixture.release();
    assert.deepEqual(dispatched, ["first", "third"]);
    assert.deepEqual(fixture.received, ["first", "third"]);
  } finally {
    await fixture.close();
  }
});

test("Unix connect flush keeps reentrant sends behind queued frames", async () => {
  const fixture = await delayedUnixFixture();
  const transport: Transport = fixture.transport;
  try {
    assert.ok(transport.sendCancellable);
    transport.sendCancellable("first", () => transport.send("reentrant"));
    transport.send("second");

    await fixture.release();
    assert.deepEqual(fixture.received, ["first", "second", "reentrant"]);
  } finally {
    await fixture.close();
  }
});

test("Unix connect failure discards queued cancellable frames", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-refused-"));
  const socketPath = join(directory, "missing.sock");
  const transport = new UnixSocketTransport(socketPath);
  const cancellableTransport: Transport = transport;
  let dispatched = false;
  try {
    assert.ok(cancellableTransport.sendCancellable);
    cancellableTransport.sendCancellable("queued", () => {
      dispatched = true;
    });
    const error = new Promise<Error>((resolve) => transport.onError(resolve));
    const closed = new Promise<void>((resolve) => transport.onClose(resolve));
    assert.match((await error).message, /cannot connect to session socket/);
    await closed;
    assert.equal(dispatched, false);
  } finally {
    transport.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("Unix connected sends ignore pre-connect pending byte limits", async () => {
  const fixture = await delayedUnixFixture({
    maxOutboundMessageBytes: 64,
    maxPendingBytes: 4,
    maxPendingMessages: 1,
  });
  try {
    await fixture.release();
    fixture.transport.send("connected-frame");
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(fixture.received, ["connected-frame"]);
  } finally {
    await fixture.close();
  }
});

test("Unix failure fans out throwing observers before destroying the socket", async () => {
  const fixture = await delayedUnixFixture();
  const transport = fixture.transport as unknown as {
    readonly socket: Socket;
    failAndClose(error: Error): void;
  };
  const calls: string[] = [];
  const closed = new Promise<void>((resolve) => fixture.transport.onClose(resolve));
  fixture.transport.onError(() => {
    calls.push("error-one");
    throw new Error("first Unix error observer failed");
  });
  fixture.transport.onError(() => calls.push("error-two"));

  try {
    assert.throws(
      () => transport.failAndClose(new Error("transport failed")),
      /first Unix error observer failed/,
    );
    assert.deepEqual(calls, ["error-one", "error-two"]);
    assert.equal(transport.socket.destroyed, true);
    await closed;
  } finally {
    await fixture.close();
  }
});

test("Unix connect callback contains observer failures during flush failure", async () => {
  const fixture = await delayedUnixFixture();
  const transport = fixture.transport as Transport;
  const calls: string[] = [];
  const closed = new Promise<void>((resolve) => fixture.transport.onClose(resolve));
  fixture.transport.onError(() => {
    calls.push("error-one");
    throw new Error("first Unix error observer failed");
  });
  fixture.transport.onError(() => calls.push("error-two"));
  assert.ok(transport.sendCancellable);
  transport.sendCancellable("queued", () => {
    throw new Error("dispatch callback failed");
  });

  try {
    await assert.doesNotReject(() => fixture.release());
    await closed;
    assert.deepEqual(calls, ["error-one", "error-two"]);
    assert.equal(
      (fixture.transport as unknown as { readonly socket: Socket }).socket.destroyed,
      true,
    );
  } finally {
    await fixture.close();
  }
});

test("Unix finish fans out throwing close observers after lifecycle cleanup", async () => {
  const fixture = await delayedUnixFixture();
  const transport = fixture.transport as unknown as { finish(): void };
  const calls: string[] = [];
  await fixture.release();
  fixture.transport.onClose(() => {
    calls.push("close-one");
    fixture.transport.close();
    throw new Error("first Unix close observer failed");
  });
  fixture.transport.onClose(() => calls.push("close-two"));

  try {
    assert.throws(
      () => transport.finish(),
      /first Unix close observer failed/,
    );
    assert.deepEqual(calls, ["close-one", "close-two"]);
    assert.throws(() => fixture.transport.send("after-close"), /socket closed/);
  } finally {
    await fixture.close();
  }
});

test("Unix wait leases remain reserved until delayed dispatch", async () => {
  const fixture = await delayedUnixFixture();
  const client = new Client({ transport: fixture.transport, timeoutMs: 0 });
  const terminal = client.session(RESOURCE_SESSION).terminal(RESOURCE_TERMINAL);
  const wait = () => terminal.wait({
    pattern: "never",
    timeoutMs: decimalString("1"),
  });
  const pending = Array.from({ length: 8 }, wait);
  let afterDispatch: ReturnType<typeof wait> | undefined;

  try {
    await new Promise<void>((resolve) => setTimeout(resolve, 130));
    const ninth = wait();
    pending.push(ninth);
    await assert.rejects(
      Promise.race([
        ninth,
        new Promise<never>((_resolve, reject) => {
          setTimeout(() => reject(new Error("ninth wait was queued")), 20);
        }),
      ]),
      /terminal wait capacity is 8/,
    );

    await fixture.release();
    assert.equal(unixResourceOperationCount(fixture, "terminal.wait"), 8);

    await new Promise<void>((resolve) => setTimeout(resolve, 130));
    afterDispatch = wait();
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    assert.equal(unixResourceOperationCount(fixture, "terminal.wait"), 9);
  } finally {
    client.close();
    await Promise.allSettled([
      ...pending,
      ...(afterDispatch ? [afterDispatch] : []),
    ]);
    await fixture.close();
  }
});

test("Unix transport preserves JSON-lines request and response framing", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-"));
  const socketPath = join(directory, "session.sock");
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    let buffered = "";
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      for (;;) {
        const newline = buffered.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(buffered.slice(0, newline)) as Record<string, unknown>;
        buffered = buffered.slice(newline + 1);
        if (request.cmd === "identify") {
          assert.deepEqual(request, { id: 1, cmd: "identify" });
          socket.write(`${JSON.stringify({
            id: request.id,
            ok: true,
            data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
          })}\n`);
          continue;
        }
        assert.deepEqual(request, { id: 2, cmd: "ping" });
        socket.write(`${JSON.stringify({
          id: request.id,
          ok: true,
          data: { ok: true, version: "0.1.2", protocol: 6 },
        })}\n`);
      }
    });
  });

  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    const client = new CmuxClient({ socketPath, timeoutMs: 1000 });
    assert.deepEqual(await client.ping(), { ok: true, version: "0.1.2", protocol: 6 });
    await client.close();
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});

test("Unix resource streams outlive their acknowledged open deadline", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-resource-"));
  const socketPath = join(directory, "session.sock");
  let emitEvent: (() => void) | undefined;
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    let buffered = "";
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      for (;;) {
        const newline = buffered.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(buffered.slice(0, newline)) as {
          id: string;
          operation: string;
          params: Record<string, unknown>;
        };
        buffered = buffered.slice(newline + 1);
        if (request.operation === "session.events") {
          const streamId = request.params.stream_id as string;
          socket.write(`${JSON.stringify({
            protocol: "cmux.protocol/2",
            type: "response",
            id: request.id,
            ok: true,
            result: { stream_id: streamId },
          })}\n`);
          emitEvent = () => {
            socket.write(`${JSON.stringify({
              protocol: "cmux.protocol/2",
              type: "stream_item",
              stream_id: streamId,
              sequence: "0",
              item: { kind: "future", transport: "unix" },
            })}\n`);
          };
          continue;
        }
        assert.equal(request.operation, "stream.cancel");
        socket.write(`${JSON.stringify({
          protocol: "cmux.protocol/2",
          type: "response",
          id: request.id,
          ok: true,
          result: {},
        })}\n`);
        socket.write(`${JSON.stringify({
          protocol: "cmux.protocol/2",
          type: "stream_end",
          stream_id: request.params.stream,
          reason: "canceled",
        })}\n`);
      }
    });
  });
  let client: NodeClient | undefined;

  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    client = new NodeClient({
      socketPath,
      timeoutMs: 50,
      randomHex128: () => "b".repeat(32),
    });
    const stream = await client.session(RESOURCE_SESSION).events({
      timeoutMs: 50,
    });

    const next = stream.next({ timeoutMs: 1_000 });
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.ok(emitEvent);
    emitEvent();
    const item = await next;
    assert.equal(item.done, false);
    assert.deepEqual(item.value?.value, {
      kind: "future",
      raw: { kind: "future", transport: "unix" },
    });

    await stream.cancel();
  } finally {
    client?.close();
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())
    );
    await rm(directory, { recursive: true, force: true });
  }
});

test("Unix framing preserves fragmented, coalesced, blank, and CRLF lines", () => {
  const frames: string[] = [];
  const errors: Error[] = [];
  const framing = new NewlineFrameBuffer(
    128,
    (frame) => frames.push(frame),
    (error) => errors.push(error),
  );

  framing.push(Buffer.from("\n \r"));
  framing.push(Buffer.from("\n{\"first\":"));
  framing.push(Buffer.from("1}\r\n{\"second\":2}\n"));

  assert.deepEqual(errors, []);
  assert.deepEqual(frames, [
    "{\"first\":1}\r",
    "{\"second\":2}",
  ]);
});

test("Unix framing concatenates a highly fragmented 16 MiB frame once", () => {
  const maximum = 16 * 1024 * 1024;
  const payload = Buffer.alloc(maximum, 0x61);
  let receivedBytes = 0;
  let scannedBytes = 0;
  let retainedCopiedBytes = 0;
  let concatenationCalls = 0;
  let concatenatedBytes = 0;
  const framing = new NewlineFrameBuffer(
    maximum,
    (frame) => {
      receivedBytes = Buffer.byteLength(frame);
    },
    (error) => assert.fail(error),
    {
      scanned: (bytes) => {
        scannedBytes += bytes;
      },
      retainedCopied: (bytes) => {
        retainedCopiedBytes += bytes;
      },
      concatenated: (bytes) => {
        concatenationCalls += 1;
        concatenatedBytes += bytes;
      },
    },
  );

  const fragmentBytes = 4_093;
  for (let offset = 0; offset < payload.byteLength; offset += fragmentBytes) {
    framing.push(payload.subarray(offset, offset + fragmentBytes));
  }
  framing.push(Buffer.from("\n"));

  assert.equal(receivedBytes, maximum);
  assert.equal(scannedBytes, maximum + 1);
  assert.equal(retainedCopiedBytes, maximum);
  assert.equal(concatenationCalls, 1);
  assert.equal(concatenatedBytes, maximum);
  assert.equal(retainedCopiedBytes + concatenatedBytes, maximum * 2);
});

test("Unix framing detaches a one-byte tail from a large coalesced chunk", () => {
  const frameBytes = 2 * 1024 * 1024;
  const coalesced = Buffer.alloc(frameBytes * 2 + 3);
  coalesced.fill(0x61, 0, frameBytes);
  coalesced[frameBytes] = 0x0a;
  coalesced.fill(0x62, frameBytes + 1, frameBytes * 2 + 1);
  coalesced[frameBytes * 2 + 1] = 0x0a;
  coalesced[frameBytes * 2 + 2] = 0x78;

  const frames: number[] = [];
  let retainedBytes = 0;
  let retainedCapacity = 0;
  let retainedCopiedBytes = 0;
  const framing = new NewlineFrameBuffer(
    frameBytes,
    (frame) => frames.push(Buffer.byteLength(frame)),
    (error) => assert.fail(error),
    {
      retainedCopied: (bytes) => {
        retainedCopiedBytes += bytes;
      },
      retained: (bytes, capacity) => {
        retainedBytes = bytes;
        retainedCapacity = capacity;
      },
    },
  );

  framing.push(coalesced);

  assert.deepEqual(frames, [frameBytes, frameBytes]);
  assert.equal(retainedCopiedBytes, 1);
  assert.equal(retainedBytes, 1);
  assert.equal(retainedCapacity, 1);

  framing.push(Buffer.from("\n"));
  assert.deepEqual(frames, [frameBytes, frameBytes, 1]);
  assert.equal(retainedBytes, 0);
  assert.equal(retainedCapacity, 0);
});

test("Unix framing clears retained chunks before reporting max-plus-one failure", () => {
  const errors: Error[] = [];
  let retainedBytes = 0;
  let retainedCapacity = 0;
  let retainedAtError: [number, number] | undefined;
  const framing = new NewlineFrameBuffer(
    8,
    () => assert.fail("oversized frame must not be delivered"),
    (error) => {
      errors.push(error);
      retainedAtError = [retainedBytes, retainedCapacity];
    },
    {
      retained: (bytes, capacity) => {
        retainedBytes = bytes;
        retainedCapacity = capacity;
      },
    },
  );

  framing.push(Buffer.from("12345678"));
  assert.deepEqual([retainedBytes, retainedCapacity], [8, 8]);
  framing.push(Buffer.from("9"));

  assert.equal(errors.length, 1);
  assert.match(errors[0]!.message, /inbound message exceeds 8 bytes/);
  assert.deepEqual(retainedAtError, [0, 0]);
  assert.deepEqual([retainedBytes, retainedCapacity], [0, 0]);
  framing.push(Buffer.from("\n"));
  assert.equal(errors.length, 1);
});

test("Unix framing stops coalesced delivery after reentrant disposal", () => {
  const frames: string[] = [];
  let framing: NewlineFrameBuffer;
  framing = new NewlineFrameBuffer(
    128,
    (frame) => {
      frames.push(frame);
      framing.dispose();
    },
    (error) => assert.fail(error),
  );

  framing.push(Buffer.from("{\"first\":1}\n{\"second\":2}\n"));

  assert.deepEqual(frames, ["{\"first\":1}"]);
});

test("Unix framing reset discards a partial line without stopping decoding", () => {
  const frames: string[] = [];
  const framing = new NewlineFrameBuffer(
    128,
    (frame) => frames.push(frame),
    (error) => assert.fail(error),
  );

  framing.push(Buffer.from('{"stale":'));
  framing.reset();
  framing.push(Buffer.from('{"fresh":true}\n'));

  assert.deepEqual(frames, ['{"fresh":true}']);
});

test("Unix transport close stops active coalesced frame delivery", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-close-"));
  const socketPath = join(directory, "session.sock");
  let acceptConnection: ((socket: Socket) => void) | undefined;
  const accepted = new Promise<Socket>((resolve) => {
    acceptConnection = resolve;
  });
  const server = createServer((socket) => acceptConnection?.(socket));
  let transport: UnixSocketTransport | undefined;
  let peer: Socket | undefined;

  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    transport = new UnixSocketTransport(socketPath);
    const frames: string[] = [];
    const closed = new Promise<void>((resolve) => transport?.onClose(resolve));
    transport.onMessage((frame) => {
      frames.push(frame);
      transport?.close();
    });
    peer = await accepted;
    peer.write(Buffer.from("{\"first\":1}\n{\"second\":2}\n"));

    await closed;
    assert.deepEqual(frames, ["{\"first\":1}"]);
  } finally {
    transport?.close();
    peer?.destroy();
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())
    );
    await rm(directory, { recursive: true, force: true });
  }
});

test("Unix transport reports and closes on an oversized fragmented frame", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-limit-"));
  const socketPath = join(directory, "session.sock");
  let acceptConnection: ((socket: Socket) => void) | undefined;
  const accepted = new Promise<Socket>((resolve) => {
    acceptConnection = resolve;
  });
  const server = createServer((socket) => acceptConnection?.(socket));
  let transport: UnixSocketTransport | undefined;
  let peer: Socket | undefined;

  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    transport = new UnixSocketTransport(socketPath, {
      maxInboundMessageBytes: 8,
    });
    const error = new Promise<Error>((resolve) => transport?.onError(resolve));
    const closed = new Promise<void>((resolve) => transport?.onClose(resolve));
    peer = await accepted;
    peer.write(Buffer.from("1234"));
    peer.write(Buffer.from("56789"));

    assert.match((await error).message, /inbound message exceeds 8 bytes/);
    await closed;
  } finally {
    transport?.close();
    peer?.destroy();
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())
    );
    await rm(directory, { recursive: true, force: true });
  }
});
