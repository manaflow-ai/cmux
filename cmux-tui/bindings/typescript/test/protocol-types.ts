import type {
  BrowserAttachEvent,
  BrowserStreamEvent,
  CmuxClient,
  CmuxCommand,
  CmuxRequest,
  CmuxRequestParams,
  CmuxResponseDataFor,
  CmuxStream,
  Id,
  KnownCmuxEvent,
  SerializedButNotEmittedEvent,
  Tree,
} from "cmux-sdk/raw";

const surface: Id = 18_446_744_073_709_551_615n;

const read: CmuxRequest = { cmd: "read-screen", surface };
const browserInput: CmuxRequest = {
  cmd: "browser-key",
  surface,
  kind: "down",
  key: "Enter",
  code: "Enter",
  windows_virtual_key_code: 13,
  modifiers: 0,
};
const providerRename: CmuxRequest = {
  cmd: "rename-provider-managed-workspace",
  workspace: 1n,
  key: "workspace-key",
  name: "renamed",
  authority: "opaque-authority",
};
void read;
void browserInput;
void providerRename;

const tree: Tree = {
  registry_id: "registry",
  generation: "generation",
  workspace_revision: 1n,
  terminal_revision: 2n,
  pane_revision: 3n,
  workspaces: [],
};
void tree;

type ReadParams = CmuxRequestParams<"read-screen">;
const readParams: ReadParams = { surface };
void readParams;

type IdentifyData = CmuxResponseDataFor<"identify">;
const identify: IdentifyData = {
  app: "cmux-tui",
  version: "0.1.0",
  protocol: 10,
  session: "main",
  pid: 1,
  registry_id: "registry",
  generation: "generation",
  workspace_revision: 1n,
  terminal_revision: 2n,
  daemon_handoff: 1,
};
void identify;

function eventSurface(event: KnownCmuxEvent): Id | undefined {
  switch (event.event) {
    case "bell":
    case "surface-output":
    case "surface-exited":
    case "surface-resized":
    case "surface-resize-failed":
    case "title-changed":
    case "scroll-changed":
    case "vt-state":
    case "output":
    case "resized":
    case "detached":
    case "render-state":
    case "render-delta":
    case "browser-state":
    case "frame":
      return event.surface;
    default:
      return undefined;
  }
}
void eventSurface;

function browserAttachSubject(event: BrowserAttachEvent): Id | null | undefined {
  switch (event.event) {
    case "browser-state":
      return event.url.length > 0 ? event.surface : undefined;
    case "frame":
    case "detached":
    case "scroll-changed":
      return event.surface;
    case "notification":
      return event.surface;
    case "overflow":
      return event.surface;
    default: {
      const exhaustive: never = event;
      return exhaustive;
    }
  }
}
void browserAttachSubject;

function browserStreamSubject(event: BrowserStreamEvent): Id | null | undefined {
  switch (event.event) {
    case "browser-state":
      return event.url.length > 0 ? event.surface : undefined;
    case "frame":
    case "detached":
    case "scroll-changed":
    case "notification":
    case "overflow":
      return event.surface;
    case "unknown":
      return event.raw.surface as Id | undefined;
    default: {
      const exhaustive: never = event;
      return exhaustive;
    }
  }
}
void browserStreamSubject;

declare const browserClient: CmuxClient;
const browserAttachment: Promise<CmuxStream<BrowserStreamEvent>> =
  browserClient.attachBrowserSurface(surface, {
    idleTimeoutMs: 30_000,
    signal: new AbortController().signal,
  });
void browserAttachment;

// @ts-expect-error Browser attachments never accept render mode.
void browserClient.attachBrowserSurface(surface, { mode: "render" });

const serializedOnly: SerializedButNotEmittedEvent = {
  event: "client-list-invalidated",
};
void serializedOnly;

type ActiveEventName = KnownCmuxEvent["event"];
// @ts-expect-error Serialized-only events must not enter the active union.
const inactiveEvent: ActiveEventName = "client-list-invalidated";
void inactiveEvent;

// @ts-expect-error IDs never accept IEEE-754 numbers.
const unsafeId: Id = 1;
void unsafeId;

// @ts-expect-error read-screen requires a surface.
const missingSurface: CmuxRequest = { cmd: "read-screen" };
void missingSurface;

// @ts-expect-error Canonical wire commands do not accept interactive short IDs.
const shortId: CmuxRequest = { cmd: "read-screen", surface: "a8f3k2" };
void shortId;

declare const command: CmuxCommand;
void command;
