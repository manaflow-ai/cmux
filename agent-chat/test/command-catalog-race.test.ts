import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

const globalKeys = ["window", "document", "location", "history", "sessionStorage", "WebSocket", "setTimeout", "clearTimeout", "IS_REACT_ACT_ENVIRONMENT"];
const descriptors = new Map(globalKeys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const timers = new Map<number, { run: () => void; delay: number }>();
let nextTimer = 1;
const location = { pathname: "/", protocol: "http:", host: "fixture", search: "" };
const sockets: FakeSocket[] = [];
class FakeSocket {
  static OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  sent: any[] = [];
  constructor(_url: string) { sockets.push(this); }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  open() { this.readyState = FakeSocket.OPEN; this.onopen?.(); }
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent); }
  close() { this.readyState = 3; this.onclose?.(); }
}
const setTimer = (run: () => void, delay: number) => { const id = nextTimer++; timers.set(id, { run, delay }); return id; };
const clearTimer = (id: number) => { timers.delete(id); };
for (const [key, value] of Object.entries({
  window: { setTimeout: setTimer, clearTimeout: clearTimer },
  setTimeout: setTimer, clearTimeout: clearTimer,
  document: { title: "cmux agent" }, location,
  history: { replaceState(_state: unknown, _unused: string, path: string) { location.pathname = path; } },
  sessionStorage: { setItem() {} }, WebSocket: FakeSocket, IS_REACT_ACT_ENVIRONMENT: true,
})) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });

const groups = (name: string) => [{ trigger: "/" as const, commands: [{ name, description: name }] }];
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
let renderer: ReactTestRenderer | undefined;
let fixtureRoot: string | undefined;
let restoreDiscovery: (() => void) | undefined;
try {
  const { useSession } = await import("../src/session");
  let state: ReturnType<typeof useSession>;
  function Harness() { state = useSession(); return null; }
  const update = async (callback: () => void) => { await act(async () => { callback(); }); };
  await act(async () => { renderer = create(createElement(Harness)); });
  const ws = sockets.at(-1)!;
  await update(() => ws.open());
  const request = async (provider: string, cwd: string) => {
    await update(() => state.requestProviderCommands(provider, cwd));
    return sockets.at(-1)!.sent.at(-1);
  };
  const reply = async (request: any, name: string, extra: Record<string, unknown> = {}) => update(() => ws.receive({
    kind: "commands-list", provider: request.provider, cwd: request.cwd,
    requestId: request.requestId, groups: groups(name), ...extra,
  }));

  const oldProject = await request("codex", "/repo/old");
  const newProject = await request("codex", "/repo/new");
  await reply(newProject, "new-project-command");
  await reply(oldProject, "old-project-command");
  assert.deepEqual(state.providerCommands.codex, groups("new-project-command"), "an older project response must not replace the current command menu");
  assert.ok(oldProject.requestId && newProject.requestId && oldProject.requestId !== newProject.requestId);
  await reply(newProject, "duplicate");
  assert.deepEqual(state.providerCommands.codex, groups("new-project-command"));

  const backToOld = await request("codex", "/repo/old");
  assert.deepEqual(state.providerCommands.codex, [], "switching cwd hides commands from the previous project while discovery runs");
  await reply(oldProject, "first-visit");
  await reply(backToOld, "wrong-path", { cwd: "/repo/elsewhere" });
  await reply(backToOld, "wrong-provider", { provider: "claude" });
  await reply(backToOld, "uncorrelated", { requestId: undefined });
  assert.deepEqual(state.providerCommands.codex, []);
  await reply(backToOld, "returned-project-command");
  assert.deepEqual(state.providerCommands.codex, groups("returned-project-command"));

  const refresh = await request("codex", "/repo/old");
  assert.deepEqual(state.providerCommands.codex, groups("returned-project-command"), "refreshing the same project can retain its valid commands");
  const otherProvider = await request("pi", "/repo/old");
  await reply(otherProvider, "pi-command");
  await reply(refresh, "refreshed-codex-command");
  assert.deepEqual(state.providerCommands.pi, groups("pi-command"));
  assert.deepEqual(state.providerCommands.codex, groups("refreshed-codex-command"));

  const failed = await request("codex", "/repo/failure");
  await update(() => ws.receive({ kind: "error", op: "list-commands", requestId: failed.requestId, cwd: failed.cwd, message: "discovery failed" }));
  await reply(failed, "late-after-error");
  assert.deepEqual(state.providerCommands.codex, []);
  const retryFailure = await request("codex", "/repo/failure");
  await update(() => ws.receive({ kind: "error", op: "list-commands", requestId: failed.requestId, cwd: failed.cwd }));
  await reply(retryFailure, "retry-command");
  assert.deepEqual(state.providerCommands.codex, groups("retry-command"), "an old failure must not settle a newer retry");
  const empty = await request("claude", "/repo/empty");
  await reply(empty, "unused", { groups: [] });
  assert.deepEqual(state.providerCommands.claude, [], "a successful empty catalog clears the command menu");

  const beforeDisconnect = await request("codex", "/repo/reconnect");
  await update(() => ws.close());
  // Even direct delivery through the new socket must reject the old request.
  const [retryId, retry] = [...timers].find(([, timer]) => timer.delay === 800)!;
  timers.delete(retryId);
  await update(retry.run);
  const replacement = sockets.at(-1)!;
  await update(() => replacement.open());
  await update(() => replacement.receive({ kind: "commands-list", ...beforeDisconnect, requestId: beforeDisconnect.requestId, groups: groups("previous-connection") }));
  assert.deepEqual(state.providerCommands.codex, []);
  await update(() => state.requestProviderCommands("codex", "/repo/reconnect"));
  const reconnectRequest = replacement.sent.at(-1);
  await update(() => replacement.receive({ kind: "commands-list", ...reconnectRequest, groups: groups("recovered-command") }));
  assert.deepEqual(state.providerCommands.codex, groups("recovered-command"));

  replacement.readyState = 3;
  await update(() => state.requestProviderCommands("codex", "/repo/offline"));
  assert.deepEqual(state.providerCommands.codex, [], "changing cwd while offline must not show the old project's commands");
  assert.equal(replacement.sent.at(-1), reconnectRequest);

  // Bridge the production server response path into the mounted client. The
  // isolated provider fixture completes discoveries in reverse order while
  // the server's real cwd cache and response/error encoding run normally.
  const { sendCommandCatalogResponse } = await import("../server");
  const { piAdapter } = await import("../adapters/pi");
  const originalDiscovery = piAdapter.listCommands;
  restoreDiscovery = () => { piAdapter.listCommands = originalDiscovery; };
  const scratch = join(import.meta.dir, "../scratch");
  await mkdir(scratch, { recursive: true });
  fixtureRoot = await mkdtemp(join(scratch, "command-catalog-"));
  const oldCwd = join(fixtureRoot, "old");
  const newCwd = join(fixtureRoot, "new");
  const failedCwd = join(fixtureRoot, "failed");
  const rejectedCwd = join(fixtureRoot, "rejected");
  await Promise.all([oldCwd, newCwd, failedCwd, rejectedCwd].map((path) => mkdir(path)));
  const oldDiscovery = deferred<ReturnType<typeof groups>>();
  const newDiscovery = deferred<ReturnType<typeof groups>>();
  let discoveries = 0;
  piAdapter.listCommands = (cwd) => {
    discoveries++;
    if (cwd === oldCwd) return oldDiscovery.promise;
    if (cwd === newCwd) return newDiscovery.promise;
    if (cwd === rejectedCwd) return Promise.reject(new Error("async discovery failure"));
    throw new Error("provider discovery failed with private details");
  };
  const encoded: any[] = [];
  const bridge = { send(data: string | Buffer) {
    const message = JSON.parse(String(data)); encoded.push(message); replacement.receive(message); return 0;
  } };
  replacement.readyState = FakeSocket.OPEN;
  const serverOld = await request("pi", oldCwd);
  const serverNew = await request("pi", newCwd);
  const oldFlight = sendCommandCatalogResponse(bridge, serverOld);
  const newFlight = sendCommandCatalogResponse(bridge, serverNew);
  await act(async () => { newDiscovery.resolve(groups("server-new")); await newFlight; });
  await act(async () => { oldDiscovery.resolve(groups("server-old")); await oldFlight; });
  assert.deepEqual(state.providerCommands.pi, groups("server-new"));
  assert.equal(encoded[0].requestId, serverNew.requestId);
  assert.equal(encoded[0].cwd, newCwd);
  assert.equal(encoded[1].requestId, serverOld.requestId);
  assert.equal(encoded[1].cwd, oldCwd);
  const cached = await request("pi", newCwd);
  await act(async () => { await sendCommandCatalogResponse(bridge, cached); });
  assert.equal(discoveries, 2, "the server keeps cwd cache entries while correlating each reply");
  assert.deepEqual(state.providerCommands.pi, groups("server-new"));

  const serverFailure = await request("pi", failedCwd);
  await act(async () => { await sendCommandCatalogResponse(bridge, serverFailure); });
  assert.equal(encoded.at(-1).kind, "error");
  assert.equal(encoded.at(-1).requestId, serverFailure.requestId);
  assert.equal(encoded.at(-1).cwd, failedCwd);
  assert.ok(!encoded.at(-1).message.includes("private details"));
  await update(() => replacement.receive({ kind: "commands-list", ...serverFailure, groups: groups("late-server-success") }));
  assert.deepEqual(state.providerCommands.pi, []);
  const rejected = await request("pi", rejectedCwd);
  await act(async () => { await sendCommandCatalogResponse(bridge, rejected); });
  assert.equal(encoded.at(-1).kind, "error");
  assert.equal(encoded.at(-1).requestId, rejected.requestId);
  assert.equal(encoded.at(-1).cwd, rejectedCwd);

  const unknownProvider = await request("missing-provider", newCwd);
  await act(async () => { await sendCommandCatalogResponse(bridge, unknownProvider); });
  assert.equal(encoded.at(-1).kind, "error");
  assert.equal(encoded.at(-1).requestId, unknownProvider.requestId);
  assert.equal(encoded.at(-1).cwd, newCwd);
  const legacy: any[] = [];
  await sendCommandCatalogResponse({ send(data) { legacy.push(JSON.parse(String(data))); return 0; } }, { provider: "pi", cwd: newCwd });
  assert.deepEqual(legacy[0].groups, groups("server-new"), "legacy clients can still discover commands without request IDs");
  console.log("Command discovery ordering, cwd changes, repeat visits, providers, errors, reconnect, and offline requests: OK");
} finally {
  restoreDiscovery?.();
  if (renderer) await act(async () => { renderer!.unmount(); });
  if (fixtureRoot) await rm(fixtureRoot, { recursive: true, force: true });
  assert.equal(timers.size, 0, "unmount releases every owned timer");
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
