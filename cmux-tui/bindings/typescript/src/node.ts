import { Client as ResourceClient, type ClientOptions as ResourceClientOptions } from "./resources.js";
import {
  defaultSocketPath,
  envSocketPath,
  validateSocketPath,
  UnixSocketTransport,
  type UnixSocketTransportOptions,
} from "./node-transport.js";

export * from "./index.js";
export {
  defaultSocketPath,
  envSocketPath,
  UnixSocketTransport,
  type UnixSocketTransportOptions,
} from "./node-transport.js";

export interface NodeClientOptions
extends Omit<ResourceClientOptions, "transport">, UnixSocketTransportOptions {
  readonly socketPath?: string;
  readonly session?: string;
}

/** Resource client with Node's Unix-socket transport configured by default. */
export class NodeClient extends ResourceClient {
  readonly socketPath: string;

  constructor(options: NodeClientOptions = {}) {
    const socketPath =
      options.socketPath
      ?? envSocketPath()
      ?? defaultSocketPath(options.session ?? "main");
    validateSocketPath(socketPath);
    super({
      transport: new UnixSocketTransport(socketPath, options),
      ...(options.timeoutMs !== undefined ? { timeoutMs: options.timeoutMs } : {}),
      ...(options.localExecutor !== undefined
        ? { localExecutor: options.localExecutor }
        : {}),
      ...(options.randomHex128 !== undefined
        ? { randomHex128: options.randomHex128 }
        : {}),
    });
    this.socketPath = socketPath;
  }
}
