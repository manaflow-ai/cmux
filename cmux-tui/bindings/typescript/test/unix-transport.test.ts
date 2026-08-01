import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { NewlineFrameBuffer } from "../src/internal/newline-frame-buffer.js";
import { NodeClient, sessionId } from "../src/node.js";
import { UnixSocketTransport } from "../src/node-transport.js";
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
