import { ipcMain, webContents } from "electron";
import type { RealtimeServer, RealtimeSocket } from "../realtime.js";
import { serverLogger } from "../utils/fileLogger.js";
import { runWithAuth } from "../utils/requestContext.js";

const PREFIX = "cmux";

export function createIPCTransport(): RealtimeServer {
  const connectionHandlers: Array<(socket: RealtimeSocket) => void> = [];
  const sockets = new Map<number, IPCSocket>();

  // Handle registration (connection establishment)
  ipcMain.handle(`${PREFIX}:register`, (event, meta: { auth?: string; team?: string; auth_json?: string }) => {
    const webContentsId = event.sender.id;
    
    // Create a socket-like wrapper for this webContents
    const socket = new IPCSocket(event.sender, meta);
    sockets.set(webContentsId, socket);
    
    // Run auth and trigger connection handlers
    runWithAuth(meta.auth, meta.auth_json, () => {
      serverLogger.info("IPC client connected:", webContentsId);
      
      // Call all connection handlers
      connectionHandlers.forEach(handler => handler(socket));
    });
    
    return { success: true };
  });

  // Handle RPC calls (emit with ack)
  ipcMain.handle(`${PREFIX}:rpc`, async (event, { event: eventName, args }) => {
    const webContentsId = event.sender.id;
    const socket = sockets.get(webContentsId);
    
    if (!socket) {
      throw new Error("Socket not registered. Call register first.");
    }
    
    // Find the handler and call it with a callback for ack
    const handler = socket.handlers.get(eventName);
    if (!handler) {
      throw new Error(`No handler for event: ${eventName}`);
    }
    
    // Handle different handler signatures
    return new Promise((resolve, reject) => {
      try {
        const callback = (result?: unknown) => resolve(result);
        
        // Call handler with args and callback
        if (args.length === 0) {
          handler(callback);
        } else if (args.length === 1) {
          handler(args[0], callback);
        } else {
          handler(...args, callback);
        }
      } catch (error) {
        reject(error);
      }
    });
  });

  class IPCSocket implements RealtimeSocket {
    id: string;
    handshake: { query: Record<string, string | string[] | undefined> };
    handlers = new Map<string, (...args: unknown[]) => unknown>();
    middlewares: Array<(packet: unknown[], next: () => void) => void> = [];
    
    constructor(private sender: Electron.WebContents, meta: { auth?: string; team?: string; auth_json?: string }) {
      this.id = `ipc-${sender.id}`;
      this.handshake = {
        query: {
          auth: meta.auth,
          team: meta.team,
          auth_json: meta.auth_json,
        }
      };
    }
    
    on(event: string, handler: (...args: unknown[]) => unknown): void {
      this.handlers.set(event, handler);
    }
    
    emit(event: string, ...args: unknown[]): void {
      if (!this.sender.isDestroyed()) {
        this.sender.send(`${PREFIX}:event:${event}`, ...args);
      }
    }
    
    use(middleware: (packet: unknown[], next: () => void) => void): void {
      this.middlewares.push(middleware);
    }
    
    disconnect(): void {
      sockets.delete(this.sender.id);
      serverLogger.info("IPC client disconnected:", this.id);
    }
  }

  // Clean up on webContents destruction
  webContents.getAllWebContents().forEach(wc => {
    wc.on("destroyed", () => {
      const socket = sockets.get(wc.id);
      if (socket) {
        socket.disconnect();
      }
    });
  });

  return {
    onConnection(handler: (socket: RealtimeSocket) => void) {
      connectionHandlers.push(handler);
    },
    emit(event: string, ...args: unknown[]) {
      // Broadcast to all connected sockets
      sockets.forEach(socket => {
        socket.emit(event, ...args);
      });
    },
    async close() {
      // Clean up all sockets
      sockets.forEach(socket => socket.disconnect());
      sockets.clear();
      connectionHandlers.length = 0;
      serverLogger.info("IPC transport closed");
    },
  };
}