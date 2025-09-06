import { contextBridge, ipcRenderer } from "electron";
import { electronAPI } from "@electron-toolkit/preload";

const api = {};

// Cmux IPC API for Electron server communication
const cmuxAPI = {
  // Register with the server (like socket connection)
  register: (meta: { auth?: string; team?: string; auth_json?: string }) => {
    return ipcRenderer.invoke("cmux:register", meta);
  },
  
  // RPC call (like socket.emit with acknowledgment)
  rpc: (event: string, ...args: unknown[]) => {
    return ipcRenderer.invoke("cmux:rpc", { event, args });
  },
  
  // Subscribe to server events
  on: (event: string, callback: (...args: unknown[]) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, ...args: unknown[]) => {
      callback(...args);
    };
    ipcRenderer.on(`cmux:event:${event}`, listener);
    return () => {
      ipcRenderer.removeListener(`cmux:event:${event}`, listener);
    };
  },
  
  // Unsubscribe from server events
  off: (event: string, callback?: (...args: unknown[]) => void) => {
    if (callback) {
      ipcRenderer.removeListener(`cmux:event:${event}`, callback);
    } else {
      ipcRenderer.removeAllListeners(`cmux:event:${event}`);
    }
  },
  
  // Socket IPC methods for IPC-based socket communication
  socket: {
    connect: (query: Record<string, string>) => {
      return ipcRenderer.invoke("socket:connect", query);
    },
    disconnect: (socketId: string) => {
      return ipcRenderer.invoke("socket:disconnect", socketId);
    },
    emit: (socketId: string, eventName: string, ...args: unknown[]) => {
      // Pass args as an array to avoid serialization issues
      return ipcRenderer.invoke("socket:emit", socketId, eventName, args);
    },
    on: (socketId: string, eventName: string) => {
      return ipcRenderer.invoke("socket:on", socketId, eventName);
    },
    onEvent: (socketId: string, callback: (eventName: string, ...args: unknown[]) => void) => {
      ipcRenderer.on(`socket:event:${socketId}`, (_event, eventName, ...args) => {
        callback(eventName, ...args);
      });
    },
  }
};

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld("electron", electronAPI);
    contextBridge.exposeInMainWorld("api", api);
    contextBridge.exposeInMainWorld("cmux", cmuxAPI);
    // Mirror main process logs into the renderer console so they show up in
    // DevTools. Avoid exposing tokens or sensitive data in main logs.
    ipcRenderer.on(
      "main-log",
      (
        _event,
        payload: { level: "log" | "warn" | "error"; message: string }
      ) => {
        const level = payload?.level ?? "log";
        const msg = payload?.message ?? "";
        const fn = console[level] ?? console.log;
        try {
          fn(msg);
        } catch {
          // fallback
          console.log(msg);
        }
      }
    );

    // No socket port bridge required; renderer uses HTTP socket
  } catch (error) {
    console.error(error);
  }
} else {
  // @ts-expect-error - window augmentation for non-isolated context
  window.electron = electronAPI;
  // @ts-expect-error - window augmentation for non-isolated context
  window.api = api;
  // @ts-expect-error - window augmentation for non-isolated context
  window.cmux = cmuxAPI;
  ipcRenderer.on(
    "main-log",
    (_event, payload: { level: "log" | "warn" | "error"; message: string }) => {
      const level = payload?.level ?? "log";
      const msg = payload?.message ?? "";
      const fn = console[level] ?? console.log;
      try {
        fn(msg);
      } catch {
        console.log(msg);
      }
    }
  );

  // No socket port bridge required in non-isolated context
}
