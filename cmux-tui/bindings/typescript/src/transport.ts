/** Removes a transport event listener. */
export type Unsubscribe = () => void;

/** Called immediately before a deferred transport frame is dispatched. */
export type OnDispatched = () => void;

/** Returns false to discard a deferred frame immediately before its write. */
export type DispatchGuard = () => boolean;

/** Transport-independent delivery of complete JSON messages. */
export interface Transport {
  /** Sends one complete JSON message. */
  send(json: string): void;
  /**
   * Advertises that `sendCancellable` honors its dispatch guard immediately
   * before a deferred write. Omit this marker on legacy two-argument adapters.
   */
  readonly supportsDispatchGuard?: true;
  /**
   * Queues one complete JSON message and returns a function that cancels it if
   * dispatch has not started. Transports that buffer before authentication
   * should implement this so request deadlines cannot leave late frames behind.
   * When `supportsDispatchGuard` is true, the optional guard runs immediately
   * before `onDispatched`; false removes the queued frame without writing it.
   */
  sendCancellable?(
    json: string,
    onDispatched: OnDispatched,
    dispatchGuard?: DispatchGuard,
  ): Unsubscribe;
  /** Observes one complete received JSON message. */
  onMessage(handler: (json: string) => void): Unsubscribe;
  /** Observes transport closure. */
  onClose(handler: () => void): Unsubscribe;
  /** Observes transport failures. */
  onError(handler: (error: Error) => void): Unsubscribe;
  /** Closes the transport and releases its listeners. */
  close(): void;
}
