import assert from "node:assert/strict";
import test from "node:test";
import { CmuxClient } from "../src/client.js";
import type { Transport, Unsubscribe } from "../src/transport.js";

class ScriptedTransport implements Transport {
  private readonly messageHandlers = new Set<(json: string) => void>();
  private readonly closeHandlers = new Set<() => void>();
  private readonly errorHandlers = new Set<(error: Error) => void>();
  constructor(private readonly script: (request: Record<string, unknown>, transport: ScriptedTransport) => void) {}
  send(json: string): void { this.script(JSON.parse(json) as Record<string, unknown>, this); }
  onMessage(handler: (json: string) => void): Unsubscribe { this.messageHandlers.add(handler); return () => this.messageHandlers.delete(handler); }
  onClose(handler: () => void): Unsubscribe { this.closeHandlers.add(handler); return () => this.closeHandlers.delete(handler); }
  onError(handler: (error: Error) => void): Unsubscribe { this.errorHandlers.add(handler); return () => this.errorHandlers.delete(handler); }
  close(): void { for (const handler of this.closeHandlers) handler(); }
  emit(value: Record<string, unknown>): void {
    const json = JSON.stringify(value);
    for (const handler of this.messageHandlers) handler(json);
  }
}

test("attachSurface decodes VT, output, and resized payloads", async () => {
  const main = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "identify");
    transport.emit({ id: request.id, ok: true, data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 } });
  });
  const attach = new ScriptedTransport((request, transport) => {
    assert.equal(request.cmd, "attach-surface");
    transport.emit({ event: "vt-state", surface: 7, cols: 80, rows: 24, data: "G1s/bA==" });
    transport.emit({ id: request.id, ok: true, data: {} });
    transport.emit({ event: "output", surface: 7, data: "aGk=" });
    transport.emit({ event: "resized", surface: 7, cols: 100, rows: 30, data: "AQID" });
  });
  const client = new CmuxClient({
    transport: main,
    streamTransportFactory: () => attach,
    timeoutMs: 100,
  });

  const stream = await client.attachSurface(7);
  const initial = await stream.next();
  const output = await stream.next();
  const resized = await stream.next();
  assert.equal(initial.event, "vt-state");
  if (initial.event === "vt-state") assert.deepEqual(initial.data, Uint8Array.from([27, 91, 63, 108]));
  assert.equal(output.event, "output");
  if (output.event === "output") assert.deepEqual(output.data, Uint8Array.from([104, 105]));
  assert.equal(resized.event, "resized");
  if (resized.event === "resized") {
    assert.deepEqual(resized.data, Uint8Array.from([1, 2, 3]));
    assert.deepEqual(resized.replay, resized.data);
  }
  stream.close();
  await client.close();
});

test("surface overflow terminates only the matching shared attach stream", async () => {
  const transport = new ScriptedTransport((request, connection) => {
    if (request.cmd === "identify") {
      connection.emit({
        id: request.id,
        ok: true,
        data: { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 },
      });
      return;
    }
    assert.ok(request.cmd === "attach-surface" || request.cmd === "subscribe");
    connection.emit({ id: request.id, ok: true, data: {} });
  });
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const attach = await client.attachSurface(7);
  const subscription = await client.subscribe();

  transport.emit({
    event: "overflow",
    scope: "surface",
    surface: 7,
    error: "surface stream fell behind",
  });
  transport.emit({ event: "overflow", error: "subscriber fell behind" });

  const attachOverflow = await attach.next();
  assert.equal(attachOverflow.event, "overflow");
  await assert.rejects(() => attach.next(), /stream is closed/);
  const subscriptionOverflow = await subscription.next();
  assert.equal(subscriptionOverflow.event, "overflow");
  if (subscriptionOverflow.event === "overflow") {
    assert.equal(subscriptionOverflow.scope, undefined);
  }
  await assert.rejects(() => subscription.next(), /stream is closed/);
  await client.close();
});

test("generic request preserves exact wire command and typed result", async () => {
  let sent: Record<string, unknown> | undefined;
  const transport = new ScriptedTransport((request, connection) => {
    sent = request;
    connection.emit({ id: request.id, ok: true, data: { ok: true, version: "0.1.2", protocol: 6 } });
  });
  const client = new CmuxClient({ transport });
  const result = await client.request({ cmd: "ping" });
  assert.equal(result.protocol, 6);
  assert.deepEqual(sent, { id: 1, cmd: "ping" });
  await client.close();
});
