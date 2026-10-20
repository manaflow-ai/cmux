/** @deprecated Import protocol and client types from the package root. */
export * from "./protocol/index.js";
export type {
  CmuxClientOptions,
  AttachSurfaceOptions,
  BrowserAttachEvent,
  BrowserStreamEvent,
  BrowserAttachSurfaceOptions,
  NewBrowserTabOptions,
  NewScreenOptions,
  NewTabOptions,
  NewPaneOptions,
  NewWorkspaceOptions,
  SelectOptions,
  SelectTabOptions,
  SendOptions,
  SplitOptions,
  StreamNextOptions,
  StreamOpenOptions,
  SubscribeOptions,
  UnknownBrowserAttachEvent,
} from "./client.js";
export type { ClientOptions } from "./node-client.js";
