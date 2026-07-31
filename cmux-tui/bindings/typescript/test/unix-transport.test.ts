import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { NodeClient, sessionId } from "../src/node.js";
import { CmuxClient } from "../src/raw/node-client.js";

const RESOURCE_SESSION = sessionId(`session_${"a".repeat(32)}`);

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
            protocol: "cmux.protocol/1",
            type: "response",
            id: request.id,
            ok: true,
            result: { stream_id: streamId },
          })}\n`);
          emitEvent = () => {
            socket.write(`${JSON.stringify({
              protocol: "cmux.protocol/1",
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
          protocol: "cmux.protocol/1",
          type: "response",
          id: request.id,
          ok: true,
          result: {},
        })}\n`);
        socket.write(`${JSON.stringify({
          protocol: "cmux.protocol/1",
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
