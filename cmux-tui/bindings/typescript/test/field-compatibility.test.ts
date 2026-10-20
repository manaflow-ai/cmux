import assert from "node:assert/strict";
import test from "node:test";
import { CmuxClient } from "../src/raw/client.js";
import { CmuxProtocolError } from "../src/raw/errors.js";
import type { JsonObject } from "../src/raw/protocol/index.js";
import type { Transport, Unsubscribe } from "../src/transport.js";
import { parseWireJson, stringifyWireJson } from "../src/wire-json.js";

class CompatibilityTransport implements Transport {
  readonly commands: string[] = [];
  private readonly handlers = new Set<(json: string) => void>();

  constructor(
    private readonly protocol: number,
    private readonly capabilities: readonly string[] = [],
  ) {}

  send(json: string): void {
    const request = parseWireJson(json) as JsonObject;
    const command = String(request.cmd);
    this.commands.push(command);
    if (command === "identify") {
      this.emit({
        id: request.id,
        ok: true,
        data: {
          app: "cmux-tui",
          version: "0.1.2",
          protocol: this.protocol,
          session: "main",
          pid: 1,
          ...(this.protocol >= 7
            ? {
              registry_id: "registry",
              generation: "generation",
              workspace_revision: 1n,
            }
            : {}),
          ...(this.protocol >= 9
            ? {
              terminal_revision: 1n,
              daemon_handoff: 1,
            }
            : {}),
          capabilities: [...this.capabilities],
        },
      });
      return;
    }
    this.emit({ id: request.id, ok: true, data: {} });
  }

  onMessage(handler: (json: string) => void): Unsubscribe {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  onClose(): Unsubscribe { return () => undefined; }
  onError(): Unsubscribe { return () => undefined; }
  close(): void {}

  private emit(value: JsonObject): void {
    const json = stringifyWireJson(value);
    for (const handler of this.handlers) handler(json);
  }
}

async function rejectsBeforeCommand(
  protocol: number,
  invoke: (client: CmuxClient) => Promise<unknown>,
  message: RegExp,
  capabilities: readonly string[] = [],
): Promise<void> {
  const transport = new CompatibilityTransport(protocol, capabilities);
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  await assert.rejects(invoke(client), (error: unknown) => {
    assert.ok(error instanceof CmuxProtocolError);
    assert.match(error.message, message);
    return true;
  });
  assert.deepEqual(transport.commands, ["identify"]);
  await client.close();
}

test("typed requests gate fields added after the command's base protocol", async () => {
  await rejectsBeforeCommand(
    6,
    (client) => client.send(7n, { text: "hello", paste: true }),
    /send\.paste requires protocol 7/,
  );
  await rejectsBeforeCommand(
    8,
    (client) => client.run({ command: "echo ready", new_workspace: true, key: "workspace" }),
    /run\.key requires protocol 9/,
  );
  await rejectsBeforeCommand(
    8,
    (client) => client.request("set-default-colors", { cursor: "#ffffff" }),
    /set-default-colors\.cursor requires protocol 9/,
  );
});

test("typed requests gate capability-scoped fields before command writes", async () => {
  await rejectsBeforeCommand(
    10,
    (client) => client.subscribe({ surface: 7n }),
    /subscribe\.surface requires server capability surface-subscribe-filter/,
  );
  await rejectsBeforeCommand(
    10,
    (client) => client.attachSurface(7n, { cols: 80, rows: 24 }),
    /attach-surface\.cols requires server capability attach-initial-size/,
  );
  await rejectsBeforeCommand(
    7,
    (client) => client.request("close-workspace", { key: "workspace-key" }),
    /close-workspace\.key requires server capability workspace-registry-v1/,
  );
});

test("typed field checks treat undefined as absent and explicit null as present", async () => {
  const transport = new CompatibilityTransport(5);
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  await client.send(7n, { text: "hello", paste: undefined });
  assert.deepEqual(transport.commands, ["send"]);
  await client.close();

  await rejectsBeforeCommand(
    8,
    (next) => next.request("set-default-colors", { cursor: null }),
    /set-default-colors\.cursor requires protocol 9/,
  );
});

test("sendRaw deliberately bypasses field version and capability negotiation", async () => {
  const transport = new CompatibilityTransport(5);
  const client = new CmuxClient({ transport, timeoutMs: 100 });
  const response = await client.sendRaw({
    cmd: "send",
    surface: 7n,
    text: "hello",
    paste: true,
  });
  assert.equal(response.ok, true);
  assert.deepEqual(transport.commands, ["send"]);
  await client.close();
});
