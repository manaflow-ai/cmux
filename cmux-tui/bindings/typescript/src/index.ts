export { CmuxClient, type ClientOptions } from "./node-client.js";
export {
  CmuxStream,
  type AttachSurfaceOptions,
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
  type SubscribeOptions,
} from "./client.js";
export * from "./base64.js";
export * from "./errors.js";
export * from "./node-transport.js";
export * from "./protocol/index.js";
export * from "./transport.js";
export * from "./websocket-transport.js";
