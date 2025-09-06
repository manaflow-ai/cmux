import type { ClientToServerEvents, ServerToClientEvents } from "@cmux/shared";

// IPC Socket client that mimics Socket.IO API but uses Electron IPC
export class IPCSocketClient {
  private socketId?: string;
  private eventHandlers: Map<string, Set<(...args: any[]) => void>> = new Map();
  private _connected = false;
  
  // Socket.IO compatibility properties
  public id = "";
  public connected = false;
  public disconnected = true;

  constructor(private query: Record<string, string>) {}

  connect() {
    if (this._connected) return this;
    
    // Connect via IPC
    window.cmux.socket.connect(this.query).then(result => {
      this.socketId = result.socketId;
      this._connected = true;
      this.connected = true;
      this.disconnected = false;
      this.id = result.socketId;
      
      // Setup event listener for server events
      window.cmux.socket.onEvent(this.socketId, (eventName: string, ...args: any[]) => {
        // Handle acknowledgment callbacks
        if (eventName.startsWith("ack:")) {
          const callbackId = eventName.slice(4);
          const handler = this.pendingCallbacks.get(callbackId);
          if (handler) {
            handler(args[0]);
            this.pendingCallbacks.delete(callbackId);
          }
          return;
        }
        
        // Handle regular events
        const handlers = this.eventHandlers.get(eventName);
        if (handlers) {
          handlers.forEach(handler => handler(...args));
        }
      });
      
      // Emit connect event
      this.triggerEvent("connect");
    }).catch(error => {
      console.error("[IPCSocket] Connection failed:", error);
      this.triggerEvent("connect_error", error);
    });
    
    return this;
  }

  disconnect() {
    if (!this._connected || !this.socketId) return this;
    
    window.cmux.socket.disconnect(this.socketId);
    this._connected = false;
    this.connected = false;
    this.disconnected = true;
    this.triggerEvent("disconnect");
    
    return this;
  }

  on<E extends keyof ServerToClientEvents>(
    event: E | string,
    handler: ServerToClientEvents[E] | ((...args: any[]) => void)
  ): this {
    if (!this.eventHandlers.has(event as string)) {
      this.eventHandlers.set(event as string, new Set());
    }
    this.eventHandlers.get(event as string)!.add(handler as any);
    
    // Register with server if connected
    if (this._connected && this.socketId) {
      window.cmux.socket.on(this.socketId, event as string);
    }
    
    return this;
  }

  once<E extends keyof ServerToClientEvents>(
    event: E | string,
    handler: ServerToClientEvents[E] | ((...args: any[]) => void)
  ): this {
    const wrappedHandler = (...args: any[]) => {
      (handler as any)(...args);
      this.off(event, wrappedHandler);
    };
    return this.on(event, wrappedHandler);
  }

  off<E extends keyof ServerToClientEvents>(
    event?: E | string,
    handler?: ServerToClientEvents[E] | ((...args: any[]) => void)
  ): this {
    if (!event) {
      this.eventHandlers.clear();
      return this;
    }
    
    if (!handler) {
      this.eventHandlers.delete(event as string);
      return this;
    }
    
    const handlers = this.eventHandlers.get(event as string);
    if (handlers) {
      handlers.delete(handler as any);
    }
    
    return this;
  }

  private pendingCallbacks = new Map<string, (response: any) => void>();

  emit<E extends keyof ClientToServerEvents>(
    event: E | string,
    ...args: any[]
  ): this {
    if (!this._connected || !this.socketId) {
      console.warn("[IPCSocket] Cannot emit - not connected");
      return this;
    }
    
    // Check if last argument is a callback
    const lastArg = args[args.length - 1];
    if (typeof lastArg === "function") {
      // Generate callback ID and store the callback
      const callbackId = `${Date.now()}_callback_${Math.random()}`;
      this.pendingCallbacks.set(callbackId, lastArg);
      
      // Replace callback with callback ID
      const argsWithCallback = [...args.slice(0, -1), callbackId];
      window.cmux.socket.emit(this.socketId, event as string, argsWithCallback);
    } else {
      // No callback, emit normally
      window.cmux.socket.emit(this.socketId, event as string, args);
    }
    
    return this;
  }

  private triggerEvent(event: string, ...args: any[]) {
    const handlers = this.eventHandlers.get(event);
    if (handlers) {
      handlers.forEach(handler => handler(...args));
    }
  }
}