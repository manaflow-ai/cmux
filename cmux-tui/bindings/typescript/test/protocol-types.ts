import type {
  CmuxClient,
  CmuxEvent,
  CmuxRequest,
  CmuxResponseData,
  CmuxStream,
  DecodedAttachEvent,
  KnownCmuxEvent,
  RenderAttachEvent,
  RenderDeltaEvent,
  RenderStateEvent,
  TreeDeltaEvent,
} from "../src/browser.js";

const requests = [
  { cmd: "identify" },
  { cmd: "ping" },
  { cmd: "set-client-info", name: "browser", kind: "web" },
  { cmd: "list-clients" },
  { cmd: "detach-client", client: 2 },
  { cmd: "reload-config" },
  { cmd: "set-window-title", title: "cmux" },
  { cmd: "clear-window-title" },
  { cmd: "list-workspaces" },
  { cmd: "export-layout", screen: 1 },
  { cmd: "apply-layout", layout: { type: "leaf" } },
  { cmd: "send", surface: 1, text: "ls\r" },
  { cmd: "send", surface: 1, bytes: "AAEC", paste: true },
  { cmd: "read-screen", surface: 1 },
  { cmd: "read-scrollback", surface: 1, start: 0, count: 100 },
  { cmd: "sidebar-plugin", cols: 20, rows: 40, relaunch: true },
  { cmd: "vt-state", surface: 1 },
  { cmd: "new-tab", pane: 1 },
  { cmd: "new-browser-tab", url: "https://example.com" },
  { cmd: "new-workspace", name: "sdk" },
  { cmd: "new-screen", workspace: 1 },
  { cmd: "split", pane: 1, dir: "right" },
  { cmd: "set-ratio", pane: 1, dir: "down", ratio: 0.5 },
  { cmd: "pane-neighbor", pane: 1, dir: "left" },
  { cmd: "focus-direction", dir: "up" },
  { cmd: "swap-pane", pane: 1, target: 2 },
  { cmd: "zoom-pane", mode: "toggle" },
  { cmd: "process-info", surface: 1 },
  { cmd: "set-default-colors", fg: "#ffffff" },
  { cmd: "close-surface", surface: 1 },
  { cmd: "close-pane", pane: 1 },
  { cmd: "close-screen", screen: 1 },
  { cmd: "close-workspace", workspace: 1 },
  { cmd: "rename-pane", pane: 1, name: "pane" },
  { cmd: "rename-surface", surface: 1, name: "tab" },
  { cmd: "rename-screen", screen: 1, name: "screen" },
  { cmd: "rename-workspace", workspace: 1, name: "workspace" },
  { cmd: "resize-surface", surface: 1, cols: 80, rows: 24 },
  { cmd: "focus-pane", pane: 1 },
  { cmd: "select-tab", pane: 1, index: 0 },
  { cmd: "select-screen", delta: 1 },
  { cmd: "select-workspace", index: 0 },
  { cmd: "move-tab", surface: 1, pane: 2, index: 0 },
  { cmd: "move-workspace", workspace: 1, index: 0 },
  { cmd: "scroll-surface", surface: 1, delta: -10 },
  { cmd: "subscribe", tree_events: "deltas" },
  { cmd: "attach-surface", surface: 1 },
  { cmd: "attach-surface", surface: 1, mode: "render" },
  { cmd: "wait-for", surface: "a8f3k2", pattern: "ready", timeout_ms: 5000 },
  { cmd: "run", argv: ["echo", "ok"] },
  { cmd: "send-key", surface: 1, keys: ["ctrl+c"] },
  { cmd: "copy", surface: 1, mode: "screen" },
  { cmd: "ids", kind: "surface" },
  { cmd: "notify", title: "Build", body: "done" },
  { cmd: "list-agents", state: "working" },
  { cmd: "report-agent", surface: 1, state: "working", source: "socket" },
] satisfies CmuxRequest[];

type IdentifyData = CmuxResponseData<(typeof requests)[0]>;
const identify: IdentifyData = { app: "cmux-tui", version: "0.1.2", protocol: 6, session: "main", pid: 1 };
void identify;

function surfaceFromKnownEvent(event: KnownCmuxEvent): number | undefined {
  switch (event.event) {
    case "surface-output":
    case "scroll-changed":
    case "surface-resized":
    case "surface-resize-failed":
    case "surface-exited":
    case "title-changed":
    case "bell":
    case "vt-state":
    case "output":
    case "resized":
    case "detached": return event.surface;
    case "client-attached":
    case "client-changed":
    case "client-detached": return undefined;
    case "colors-changed": return undefined;
    default: return undefined;
  }
}

const colorsChanged: KnownCmuxEvent = {
  event: "colors-changed",
  surface: 1,
  fg: "#d8d9da",
  bg: "#131415",
  cursor: null,
  selection_bg: null,
  selection_fg: null,
  cursor_style: "bar",
  cursor_blink: false,
};

const futureEvent: CmuxEvent = { event: "future-event", extension: true };
const protocolV6Resize: KnownCmuxEvent = {
  event: "resized",
  surface: 1,
  cols: 80,
  rows: 24,
  data: "cmVwbGF5",
};
const protocolV7Resize: KnownCmuxEvent = {
  event: "resized",
  surface: 1,
  cols: 80,
  rows: 24,
  replay: "cmVwbGF5",
};
const clientEvents: KnownCmuxEvent[] = [
  { event: "client-attached", client: 2, transport: "ws", name: "browser", kind: "web" },
  { event: "client-changed", client: 2, name: "tablet", kind: "web" },
  { event: "client-detached", client: 2 },
];
const resizeFailed: KnownCmuxEvent = {
  event: "surface-resize-failed",
  surface: 1,
  cols: 120,
  rows: 40,
  error: "browser is not responding",
  retry_after_ms: 250,
};
void surfaceFromKnownEvent;
void colorsChanged;
void futureEvent;
void protocolV6Resize;
void protocolV7Resize;
void clientEvents;
void resizeFailed;

const renderState: RenderStateEvent = {
  event: "render-state",
  surface: 1,
  size: { cols: 3, rows: 1 },
  cursor: { x: 2, y: 0, style: "block", blink: true, visible: true, color: null },
  default_fg: "#d8d9da",
  default_bg: "#131415",
  scrollback_rows: 42,
  rows: [{
    row: 0,
    runs: [{ text: "$ x", fg: null, bg: null, attrs: 1, underline: "curly", width_hint: 3 }],
  }],
};
const renderDelta: RenderDeltaEvent = {
  event: "render-delta",
  surface: 1,
  cursor: renderState.cursor,
  full: false,
  rows: [],
};
const treeDelta: TreeDeltaEvent = {
  event: "tab-renamed",
  workspace: 1,
  screen: 2,
  pane: 3,
  surface: 4,
  entity: {
    surface: 4,
    kind: "pty",
    browser_source: null,
    name: "shell",
    title: "shell",
    size: { cols: 80, rows: 24 },
    dead: false,
  },
};
void renderState;
void renderDelta;
void treeDelta;

async function typedAttachModes(client: CmuxClient): Promise<void> {
  const bytes: CmuxStream<DecodedAttachEvent> = await client.attachSurface(1);
  const render: CmuxStream<RenderAttachEvent> = await client.attachSurface(1, { mode: "render" });
  bytes.close();
  render.close();
}
void typedAttachModes;

// @ts-expect-error `read-screen` requires a surface id.
const invalidRequest: CmuxRequest = { cmd: "read-screen" };
void invalidRequest;
