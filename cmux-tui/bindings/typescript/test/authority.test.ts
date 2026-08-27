import assert from "node:assert/strict";
import test from "node:test";
import { CmuxClient as BrowserClient } from "../src/raw/client.js";
import { CmuxAuthorityError } from "../src/raw/errors.js";
import { CmuxClient as NodeClient } from "../src/raw/node-client.js";
import type { JsonObject } from "../src/raw/protocol/index.js";
import type { Transport, Unsubscribe } from "../src/transport.js";
import { parseWireJson, stringifyWireJson } from "../src/wire-json.js";

class AuthorityTransport implements Transport {
  readonly sent: JsonObject[] = [];
  private readonly handlers = new Set<(json: string) => void>();

  send(json: string): void {
    const request = parseWireJson(json) as JsonObject;
    this.sent.push(request);
    if (request.cmd === "identify") {
      this.emit({
        id: request.id,
        ok: true,
        data: {
          app: "cmux-tui",
          version: "0.1.2",
          protocol: 10,
          session: "main",
          pid: 1,
          registry_id: "registry",
          generation: "generation",
          workspace_revision: 1n,
          terminal_revision: 1n,
          daemon_handoff: 1,
          capabilities: ["provider-managed-workspace-authority-v2"],
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

test("transport-neutral clients deny privileged commands before transport writes", async () => {
  const transport = new AuthorityTransport();
  const client = new BrowserClient({ transport });
  assert.deepEqual(client.authorities, ["control", "frontend"]);

  await assert.rejects(
    () => client.pairingResponse({ request: 1n, approve: false }),
    (error: unknown) => {
      assert.ok(error instanceof CmuxAuthorityError);
      assert.equal(error.command, "pairing-response");
      assert.equal(error.requiredAuthority, "local-admin");
      assert.deepEqual(error.grantedAuthorities, ["control", "frontend"]);
      return true;
    },
  );
  await assert.rejects(
    () => client.markWorkspacesProviderManaged({ authority: "secret" }),
    (error: unknown) => {
      assert.ok(error instanceof CmuxAuthorityError);
      assert.equal(error.command, "mark-workspaces-provider-managed");
      assert.equal(error.requiredAuthority, "provider-authority");
      return true;
    },
  );
  await assert.rejects(
    () => client.sendRaw({
      cmd: "shutdown-daemon",
      pid: 1,
      generation: "generation",
    }),
    CmuxAuthorityError,
  );
  assert.equal(transport.sent.length, 0);
  await client.close();
});

test("frontend denial precedes attach identification", async () => {
  const transport = new AuthorityTransport();
  const client = new BrowserClient({
    transport,
    authorities: ["control"],
  });

  await assert.rejects(
    () => client.attachBrowserSurface(7n),
    (error: unknown) => {
      assert.ok(error instanceof CmuxAuthorityError);
      assert.equal(error.command, "attach-surface");
      assert.equal(error.requiredAuthority, "frontend");
      return true;
    },
  );
  assert.equal(transport.sent.length, 0);
  await client.close();
});

test("provider authority is available only after explicit opt-in", async () => {
  const transport = new AuthorityTransport();
  const client = new BrowserClient({
    transport,
    enableProviderAuthority: true,
  });
  assert.deepEqual(client.authorities, [
    "control",
    "frontend",
    "provider-authority",
  ]);

  await client.markWorkspacesProviderManaged({ authority: "secret" });
  assert.deepEqual(
    transport.sent.map((request) => request.cmd),
    ["identify", "mark-workspaces-provider-managed"],
  );
  await client.close();
});

test("Node clients enable local-admin authority by default", async () => {
  const transport = new AuthorityTransport();
  const client = new NodeClient({ transport });
  assert.deepEqual(client.authorities, [
    "control",
    "frontend",
    "local-admin",
  ]);

  await client.pairingResponse({ request: 1n, approve: false });
  assert.deepEqual(
    transport.sent.map((request) => request.cmd),
    ["identify", "pairing-response"],
  );
  await client.close();
});
