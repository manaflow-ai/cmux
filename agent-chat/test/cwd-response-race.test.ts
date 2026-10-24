import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useSession, type SessionState } from "../src/session";

// Exercise the real socket handler, rather than only its response predicate.
class CwdSocket {
  static OPEN = 1;
  static latest: CwdSocket;
  readyState = 1;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  sent: any[] = [];
  constructor() { CwdSocket.latest = this; }
  send(payload: string) { this.sent.push(JSON.parse(payload)); }
  close() { this.readyState = 3; }
  receive(payload: object) { this.onmessage?.({ data: JSON.stringify(payload) }); }
}

const prior = new Map<string, PropertyDescriptor | undefined>();
function install(name: string, value: unknown) {
  prior.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
}

let state: SessionState;
function Probe() { state = useSession(); return null; }
let renderer: ReactTestRenderer | undefined;
try {
  install("IS_REACT_ACT_ENVIRONMENT", true);
  install("WebSocket", CwdSocket);
  install("window", { clearTimeout, setTimeout });
  install("location", { protocol: "http:", host: "localhost", pathname: "/" });
  act(() => { renderer = create(createElement(Probe)); });
  const socket = CwdSocket.latest;
  act(() => {
    socket.onopen?.();
    socket.receive({ kind: "hello", providers: [], defaultCwd: "/default" });
  });
  const cwd = "/repo";
  const request = () => socket.sent.filter((message) => message.op === "check-cwd").at(-1);
  act(() => { state.checkCwd(cwd); });
  const old = request();
  act(() => { state.checkCwd(cwd); });
  const current = request();
  assert.notEqual(old.requestId, current.requestId);
  const harness = { id: "current", kind: "workflow", installed: true, label: "Current" };
  act(() => socket.receive({ ...current, kind: "cwd-check", ok: true, repositorySlug: "owner/current", harnesses: [harness] }));
  act(() => socket.receive({ ...old, kind: "cwd-check", ok: false, message: "stale failure", repositorySlug: "owner/stale", harnesses: [] }));
  assert.equal(state.cwdChecks[cwd]?.ok, true, "an old same-path failure must not overwrite final success");
  assert.equal(state.cwdChecks[cwd]?.repositorySlug, "owner/current", "repository links must keep the accepted slug");
  assert.deepEqual(state.harnessSnapshot, { cwd, harnesses: [harness] }, "harness correlation must remain intact");

  act(() => { state.checkCwd("/other"); });
  const other = request();
  act(() => socket.receive({ ...current, kind: "cwd-check", ok: false }));
  assert.equal(state.cwdChecks[cwd]?.ok, true, "a superseded path cannot change validation state");
  act(() => socket.receive({ ...other, kind: "cwd-check", ok: true }));
  assert.equal(state.cwdChecks["/other"]?.ok, true, "a current response without harnesses must still validate");

  act(() => socket.receive({ kind: "hello", providers: [], defaultCwd: "/default" }));
  act(() => { state.checkCwd(cwd); });
  const reconnected = request();
  assert.notEqual(reconnected.connectionEpoch, current.connectionEpoch);
  act(() => socket.receive({ ...reconnected, kind: "cwd-check", ok: true, repositorySlug: "owner/reconnected" }));
  act(() => socket.receive({ ...old, kind: "cwd-check", ok: false, repositorySlug: "owner/old-epoch" }));
  assert.equal(state.cwdChecks[cwd]?.ok, true, "a previous connection's failure must be ignored");
  assert.equal(state.cwdChecks[cwd]?.repositorySlug, "owner/reconnected");
  console.log("cwd socket races: same-path, changed-path, previous-epoch and repository slug: OK");
} finally {
  if (renderer) act(() => renderer!.unmount());
  for (const [name, descriptor] of prior) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
}
