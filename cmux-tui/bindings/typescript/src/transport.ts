/** Removes a transport event listener. */
export type Unsubscribe = () => void;

/** Transport-independent delivery of complete JSON messages. */
export interface Transport {
  /** Sends one complete JSON message. */
  send(json: string): void;
  /** Observes one complete received JSON message. */
  onMessage(handler: (json: string) => void): Unsubscribe;
  /** Observes transport closure. */
  onClose(handler: () => void): Unsubscribe;
  /** Observes transport failures. */
  onError(handler: (error: Error) => void): Unsubscribe;
  /** Closes the transport and releases its listeners. */
  close(): void;
}
