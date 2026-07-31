/** Removes a transport event listener. */
export type Unsubscribe = () => void;

/** Called immediately before a deferred transport frame is dispatched. */
export type OnDispatched = () => void;

/** Transport-independent delivery of complete JSON messages. */
export interface Transport {
  /** Sends one complete JSON message. */
  send(json: string): void;
  /**
   * Queues one complete JSON message and returns a function that cancels it if
   * dispatch has not started. Transports that buffer before authentication
   * should implement this so request deadlines cannot leave late frames behind.
   */
  sendCancellable?(json: string, onDispatched: OnDispatched): Unsubscribe;
  /** Observes one complete received JSON message. */
  onMessage(handler: (json: string) => void): Unsubscribe;
  /** Observes transport closure. */
  onClose(handler: () => void): Unsubscribe;
  /** Observes transport failures. */
  onError(handler: (error: Error) => void): Unsubscribe;
  /** Closes the transport and releases its listeners. */
  close(): void;
}
