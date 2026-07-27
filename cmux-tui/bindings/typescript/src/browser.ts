export {
  CmuxClient,
  CmuxStream,
  TERMINAL_KEY_TEXT_MAX_BYTES,
  type CmuxClientOptions,
  type CmuxClientOptions as ClientOptions,
  type AttachSurfaceOptions,
  type NewBrowserTabOptions,
  type NewScreenOptions,
  type NewTabOptions,
  type NewWorkspaceOptions,
  type SelectOptions,
  type SelectTabOptions,
  type SendOptions,
  type SplitOptions,
  type SubscribeOptions,
} from "./client.js";
export * from "./base64.js";
export * from "./errors.js";
export * from "./protocol/index.js";
export * from "./transport.js";
export * from "./websocket-transport.js";
