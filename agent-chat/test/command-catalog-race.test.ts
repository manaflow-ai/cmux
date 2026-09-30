import assert from "node:assert/strict";
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
let renderer: ReactTestRenderer | undefined;
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
    return ws.sent.at(-1);
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
  console.log("Command discovery ordering, cwd changes, repeat visits, providers, errors, reconnect, and offline requests: OK");
} finally {
  if (renderer) await act(async () => { renderer!.unmount(); });
  assert.equal(timers.size, 0, "unmount releases every owned timer");
  for (const [key, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete (globalThis as any)[key];
  }
}
