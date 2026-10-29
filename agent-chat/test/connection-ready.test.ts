// HQ #3980: when the chat's WebSocket drops (close, error), the page stops reading ready at
// once, so the "Connection lost. Reconnecting…" notice shows and Start is disabled; the next
// socket's hello makes it ready again.
import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useSession, type SessionState } from "../src/session";

class FakeSocket {
  static OPEN = 1;
  static all: FakeSocket[] = [];
  readyState = 1;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  sent: any[] = [];
  constructor() { FakeSocket.all.push(this); }
  send(payload: string) { this.sent.push(JSON.parse(payload)); }
  close() { this.readyState = 3; }
  receive(payload: object) { this.onmessage?.({ data: JSON.stringify(payload) }); }
}

const prior = new Map<string, PropertyDescriptor | undefined>();
function install(name: string, value: unknown) {
  prior.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
}

async function nextSocket(after: number): Promise<FakeSocket> {
  const deadline = Date.now() + 5_000;
  while (FakeSocket.all.length <= after) {
    if (Date.now() > deadline) throw new Error("no reconnect socket");
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 50)); });
  }
  return FakeSocket.all[after]!;
}

let state: SessionState;
function Probe() { state = useSession(); return null; }
let renderer: ReactTestRenderer | undefined;
try {
  install("IS_REACT_ACT_ENVIRONMENT", true);
  install("WebSocket", FakeSocket);
  install("window", { clearTimeout, setTimeout });
  install("location", { protocol: "http:", host: "localhost", pathname: "/" });
  act(() => { renderer = create(createElement(Probe)); });

  const hello = (socket: FakeSocket) => act(() => {
    socket.onopen?.();
    socket.receive({ kind: "hello", providers: [], defaultCwd: "/default" });
  });
  let socket = FakeSocket.all[0]!;
  hello(socket);
  assert.equal(state.ready, true, "ready after the first hello");

  for (const drop of ["close", "error"] as const) {
    const count = FakeSocket.all.length;
    act(() => { (drop === "close" ? socket.onclose : socket.onerror)?.(); });
    assert.equal(state.ready, false, `still ready after the socket's ${drop}`);
    socket = await nextSocket(count);
    assert.equal(state.ready, false, "a new socket is not ready before its hello");
    hello(socket);
    assert.equal(state.ready, true, `ready again after the hello that follows the ${drop}`);
  }
  console.log("agent-chat ready clears on close and error and returns with the next hello: OK");
} finally {
  if (renderer) act(() => renderer!.unmount());
  for (const [name, descriptor] of prior) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
}
