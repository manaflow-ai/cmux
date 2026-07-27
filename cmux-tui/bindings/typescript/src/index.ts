export { CmuxClient, type ClientOptions } from "./node-client.js";
export {
  CmuxStream,
  type AttachSurfaceOptions,
  type BrowserAttachEvent,
  type BrowserStreamEvent,
  type BrowserAttachSurfaceOptions,
  type CmuxClientOptions,
  type NewBrowserTabOptions,
  type NewScreenOptions,
  type NewTabOptions,
  type NewWorkspaceOptions,
  type CreateTerminalOptions,
  type CreateWorkspaceOptions,
  type CloseWorkspaceOptions,
  type MoveWorkspaceOptions,
  type RenameWorkspaceOptions,
  type SelectOptions,
  type SelectTabOptions,
  type SendOptions,
  type SplitOptions,
  type StreamNextOptions,
  type StreamOpenOptions,
  type SubscribeOptions,
  type UnknownBrowserAttachEvent,
} from "./client.js";
export * from "./base64.js";
export * from "./errors.js";
export * from "./node-transport.js";
export * from "./protocol/index.js";
export * from "./transport.js";
export * from "./transport-limits.js";
export * from "./websocket-transport.js";
export * from "./wire-json.js";
