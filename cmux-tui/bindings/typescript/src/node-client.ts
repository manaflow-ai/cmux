import {
  CmuxClient as TransportCmuxClient,
  type CmuxClientOptions,
} from "./client.js";
import type { CmuxAuthority } from "./generated/metadata.js";
import { defaultSocketPath, envSocketPath, UnixSocketTransport } from "./node-transport.js";
import type { Transport } from "./transport.js";

/** Node.js client configuration, including Unix-socket defaults. */
export interface ClientOptions {
  socketPath?: string;
  session?: string;
  /** Command acknowledgement timeout. */
  timeoutMs?: number;
  /**
   * Command authorities enabled for this client.
   * Node Unix clients default to control, frontend, and local-admin.
   */
  authorities?: readonly CmuxAuthority[];
  /** Explicitly enables provider-owned workspace mutation commands. */
  enableProviderAuthority?: boolean;
  /** Optional idle timeout for stream reads. The default waits indefinitely. */
  streamIdleTimeoutMs?: number;
  allowProtocolV6Attach?: boolean;
  maxBufferedEvents?: number;
  maxAttachEncodedChars?: number;
  maxPendingResponses?: number;
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
      authorities: options.authorities ?? ["control", "frontend", "local-admin"],
      enableProviderAuthority: options.enableProviderAuthority,
      timeoutMs: options.timeoutMs,
      streamIdleTimeoutMs: options.streamIdleTimeoutMs,
      allowProtocolV6Attach: options.allowProtocolV6Attach,
      maxBufferedEvents: options.maxBufferedEvents,
      maxAttachEncodedChars: options.maxAttachEncodedChars,
      maxPendingResponses: options.maxPendingResponses,
      streamTransportFactory: options.streamTransportFactory
        ?? (options.transport ? undefined : () => new UnixSocketTransport(socketPath)),
    };
    super(shared);
    this.socketPath = socketPath;
  }
}
