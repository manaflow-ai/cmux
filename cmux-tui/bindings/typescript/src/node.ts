import { Client as ResourceClient, type ClientOptions as ResourceClientOptions } from "./resources.js";
import {
  defaultSocketPath,
  defaultSocketPaths,
  envSocketPath,
  validateSocketPath,
  UnixSocketTransport,
  type UnixSocketTransportOptions,
} from "./node-transport.js";

export * from "./index.js";
export {
  defaultSocketPath,
  defaultSocketPaths,
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
    const explicit = options.socketPath ?? envSocketPath();
    const socketPath = explicit ?? defaultSocketPath(options.session ?? "main");
    validateSocketPath(socketPath);
    const fallbackSocketPaths = explicit ? [] : defaultSocketPaths(options.session ?? "main").slice(1);
    super({
      transport: new UnixSocketTransport(socketPath, { ...options, fallbackSocketPaths }),
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
