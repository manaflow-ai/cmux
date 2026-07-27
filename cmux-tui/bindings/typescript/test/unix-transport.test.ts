import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CmuxClient } from "../src/node-client.js";

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
