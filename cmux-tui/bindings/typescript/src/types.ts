/** @deprecated Import protocol and client types from the package root. */
export * from "./protocol/index.js";
export type {
  CmuxClientOptions,
  AttachSurfaceOptions,
  NewBrowserTabOptions,
  NewScreenOptions,
  NewTabOptions,
  NewWorkspaceOptions,
  SelectOptions,
  SelectTabOptions,
  SendOptions,
  SplitOptions,
  SubscribeOptions,
} from "./client.js";
export type { ClientOptions } from "./node-client.js";
