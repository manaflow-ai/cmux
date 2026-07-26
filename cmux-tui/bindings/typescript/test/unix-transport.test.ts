import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CmuxClient } from "../src/node-client.js";
import {
  UNIX_SOCKET_MESSAGE_MAX_BYTES,
  UnixSocketTransport,
} from "../src/node-transport.js";

test("Unix transport preserves JSON-lines request and response framing", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-"));
  const socketPath = join(directory, "session.sock");
  const server = createServer((socket) => {
    socket.setEncoding("utf8");
    let buffered = "";
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      const newline = buffered.indexOf("\n");
      if (newline < 0) return;
      const request = JSON.parse(buffered.slice(0, newline)) as Record<string, unknown>;
      assert.deepEqual(request, { id: 1, cmd: "ping" });
      socket.write(`${JSON.stringify({
        id: request.id,
        ok: true,
        data: { ok: true, version: "0.1.2", protocol: 6 },
      })}\n`);
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

test("Unix transport rejects an oversized unterminated message", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-typescript-"));
  const socketPath = join(directory, "session.sock");
  const server = createServer((socket) => {
    socket.on("error", () => {});
    socket.write(Buffer.alloc(UNIX_SOCKET_MESSAGE_MAX_BYTES + 1, 0x61));
  });
  let transport: UnixSocketTransport | undefined;

  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socketPath, resolve);
    });
    transport = new UnixSocketTransport(socketPath);
    const error = await new Promise<Error>((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("transport accepted an oversized message")),
        10_000,
      );
      transport!.onError((value) => {
        clearTimeout(timeout);
        resolve(value);
      });
    });
    assert.match(error.message, /exceeds 33554432 bytes/);
  } finally {
    transport?.close();
    await new Promise<void>((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve())
    );
    await rm(directory, { recursive: true, force: true });
  }
});
