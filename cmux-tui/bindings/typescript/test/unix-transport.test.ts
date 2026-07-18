import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CmuxClient } from "../src/node-client.js";
import { defaultSocketPathFrom, runtimeBaseFromEnv } from "../src/node-transport.js";

test("default socket runtime root prefers XDG and ignores empty values", () => {
  assert.equal(
    runtimeBaseFromEnv({ XDG_RUNTIME_DIR: "/xdg-runtime", TMPDIR: "/tmp-runtime" }),
    "/xdg-runtime",
  );
  assert.equal(
    runtimeBaseFromEnv({ XDG_RUNTIME_DIR: "", TMPDIR: "/tmp-runtime" }),
    "/tmp-runtime",
  );
  assert.equal(runtimeBaseFromEnv({ XDG_RUNTIME_DIR: "", TMPDIR: "" }), "/tmp");
});

test("Darwin default socket path accepts 103 bytes and falls back at 104", () => {
  const base = "/tmp/runtime";
  const uid = 42;
  const emptySession = join(base, `cmux-tui-${uid}`, ".sock");
  const session = "s".repeat(103 - Buffer.byteLength(emptySession));

  const accepted = defaultSocketPathFrom(base, uid, session, true);
  assert.equal(Buffer.byteLength(accepted), 103);
  assert.ok(accepted.startsWith(`${base}/`));

  const fallback = defaultSocketPathFrom(base, uid, `${session}s`, true);
  assert.ok(fallback.startsWith(`/tmp/cmux-tui-${uid}/`));
  assert.notEqual(fallback, join(base, `cmux-tui-${uid}`, `${session}s.sock`));
});

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
