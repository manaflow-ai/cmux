import type {
  CmuxEvent,
  CmuxRequest,
  CmuxResponseData,
  KnownCmuxEvent,
} from "../src/browser.js";

const requests = [
  { cmd: "identify" },
  { cmd: "ping" },
  { cmd: "reload-config" },
  { cmd: "set-window-title", title: "cmux" },
  { cmd: "clear-window-title" },
  { cmd: "list-workspaces" },
  { cmd: "export-layout", screen: 1 },
  { cmd: "apply-layout", layout: { type: "leaf" } },
  { cmd: "send", surface: 1, text: "ls\r" },
  { cmd: "read-screen", surface: 1 },
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
  { cmd: "subscribe", events: ["bell"] },
  { cmd: "attach-surface", surface: 1 },
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
    case "surface-exited":
    case "title-changed":
    case "bell":
    case "vt-state":
    case "output":
    case "resized":
    case "detached": return event.surface;
    default: return undefined;
  }
}

const futureEvent: CmuxEvent = { event: "future-event", extension: true };
void surfaceFromKnownEvent;
void futureEvent;

// @ts-expect-error `read-screen` requires a surface id.
const invalidRequest: CmuxRequest = { cmd: "read-screen" };
void invalidRequest;
