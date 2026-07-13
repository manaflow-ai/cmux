import { CmuxClient as TransportCmuxClient, type CmuxClientOptions } from "./client.js";
import { defaultSocketPath, envSocketPath, UnixSocketTransport } from "./node-transport.js";
import type { Transport } from "./transport.js";

/** Node.js client configuration, including Unix-socket defaults. */
export interface ClientOptions {
  socketPath?: string;
  session?: string;
  timeoutMs?: number;
  allowProtocolV6Attach?: boolean;
  /** Overrides the default Unix transport. */
  transport?: Transport;
  /** Overrides dedicated transports used for subscribe and attach streams. */
  streamTransportFactory?: () => Transport;
}

/** Node.js cmux client with backward-compatible Unix-socket defaults. */
export class CmuxClient extends TransportCmuxClient {
  readonly socketPath: string;

  constructor(options: ClientOptions = {}) {
    const socketPath = options.socketPath ?? envSocketPath() ?? defaultSocketPath(options.session ?? "main");
    const shared: CmuxClientOptions = {
      transport: options.transport ?? new UnixSocketTransport(socketPath),
      timeoutMs: options.timeoutMs,
      allowProtocolV6Attach: options.allowProtocolV6Attach,
      streamTransportFactory: options.streamTransportFactory
        ?? (options.transport ? undefined : () => new UnixSocketTransport(socketPath)),
    };
    super(shared);
    this.socketPath = socketPath;
  }
}
