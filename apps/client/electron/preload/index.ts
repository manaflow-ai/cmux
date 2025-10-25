import { electronAPI } from "@electron-toolkit/preload";
import { contextBridge, ipcRenderer } from "electron";
import type {
  ElectronDevToolsMode,
  ElectronWebContentsEvent,
  ElectronWebContentsSnapshot,
  ElectronWebContentsState,
} from "../../src/types/electron-webcontents";
import type {
  ElectronLogsPayload,
  ElectronMainLogMessage,
} from "../../src/lib/electron-logs/types";

const api = {};

type RectanglePayload = {
  x: number;
  y: number;
  width: number;
  height: number;
};

type LogListener = (entry: ElectronMainLogMessage) => void;
const mainLogListeners = new Set<LogListener>();

// Cmux IPC API for Electron server communication
const cmuxAPI = {
  // Get the current webContents ID
  getCurrentWebContentsId: () => {
    return ipcRenderer.sendSync("cmux:get-current-webcontents-id") as number;
  },

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
    const listener = (
      _event: Electron.IpcRendererEvent,
      ...args: unknown[]
    ) => {
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
    onEvent: (
      socketId: string,
      callback: (eventName: string, ...args: unknown[]) => void
    ) => {
      ipcRenderer.on(
        `socket:event:${socketId}`,
        (_event, eventName, ...args) => {
          callback(eventName, ...args);
        }
      );
    },
  },
  // UI helpers
  ui: {
    focusWebContents: (id: number) => {
      return ipcRenderer.invoke("cmux:ui:focus-webcontents", id) as Promise<{
        ok: boolean;
        queued?: boolean;
      }>;
    },
    restoreLastFocusInWebContents: (id: number) => {
      return ipcRenderer.invoke(
        "cmux:ui:webcontents-restore-last-focus",
        id
      ) as Promise<{ ok: boolean; queued?: boolean }>;
    },
    restoreLastFocusInFrame: (
      contentsId: number,
      frameRoutingId: number,
      frameProcessId: number
    ) => {
      return ipcRenderer.invoke("cmux:ui:frame-restore-last-focus", {
        contentsId,
        frameRoutingId,
        frameProcessId,
      }) as Promise<{ ok: boolean; queued?: boolean }>;
    },
    setCommandPaletteOpen: (open: boolean) => {
      return ipcRenderer.invoke(
        "cmux:ui:set-command-palette-open",
        Boolean(open)
      ) as Promise<{ ok: boolean }>;
    },
    setPreviewReloadVisible: (visible: boolean) => {
      return ipcRenderer.invoke(
        "cmux:ui:set-preview-reload-visible",
        Boolean(visible)
      ) as Promise<{ ok: boolean }>;
    },
    restoreLastFocus: () => {
      return ipcRenderer.invoke("cmux:ui:restore-last-focus") as Promise<{
        ok: boolean;
        queued?: boolean;
      }>;
    },
  },
  logs: {
    onMainLog: (callback: LogListener) => {
      mainLogListeners.add(callback);
      return () => {
        mainLogListeners.delete(callback);
      };
    },
    readAll: () =>
      ipcRenderer.invoke("cmux:logs:read-all") as Promise<ElectronLogsPayload>,
    copyAll: () =>
      ipcRenderer.invoke("cmux:logs:copy-all") as Promise<{ ok: boolean }>,
  },
  autoUpdate: {
    check: () =>
      ipcRenderer.invoke("cmux:auto-update:check") as Promise<{
        ok: boolean;
        reason?: string;
        updateAvailable?: boolean;
        version?: string | null;
      }>,
    setAllowPrerelease: (allow: boolean) =>
      ipcRenderer.invoke("cmux:auto-update:set-allow-prerelease", {
        allowPrerelease: Boolean(allow),
      }) as Promise<{
        ok: boolean;
        allowPrerelease: boolean;
        checkTriggered?: boolean;
      }>,
    install: () =>
      ipcRenderer.invoke("cmux:auto-update:install") as Promise<{
        ok: boolean;
        reason?: string;
      }>,
  },
  webContentsView: {
    create: (options: {
      url: string;
      bounds?: RectanglePayload;
      backgroundColor?: string;
      borderRadius?: number;
      persistKey?: string;
    }) =>
      ipcRenderer.invoke("cmux:webcontents:create", options) as Promise<{
        id: number;
        webContentsId: number;
        restored: boolean;
      }>,
    setBounds: (options: {
      id: number;
      bounds: RectanglePayload;
      visible?: boolean;
    }) =>
      ipcRenderer.invoke("cmux:webcontents:set-bounds", options) as Promise<{
        ok: boolean;
      }>,
    loadURL: (id: number, url: string) =>
      ipcRenderer.invoke("cmux:webcontents:load-url", { id, url }) as Promise<{
        ok: boolean;
      }>,
    release: (options: { id: number; persist?: boolean }) =>
      ipcRenderer.invoke("cmux:webcontents:release", options) as Promise<{
        ok: boolean;
        suspended: boolean;
      }>,
    destroy: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:destroy", id) as Promise<{ ok: boolean }>,
    updateStyle: (options: {
      id: number;
      backgroundColor?: string;
      borderRadius?: number;
    }) =>
      ipcRenderer.invoke("cmux:webcontents:update-style", options) as Promise<{
        ok: boolean;
      }>,
    goBack: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:go-back", id) as Promise<{ ok: boolean }>,
    goForward: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:go-forward", id) as Promise<{ ok: boolean }>,
    reload: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:reload", id) as Promise<{ ok: boolean }>,
    onEvent: (id: number, callback: (event: ElectronWebContentsEvent) => void) => {
      const channel = `cmux:webcontents:event:${id}`;
      const listener = (
        _event: Electron.IpcRendererEvent,
        payload: ElectronWebContentsEvent
      ) => {
        callback(payload);
      };
      ipcRenderer.on(channel, listener);
      return () => {
        ipcRenderer.removeListener(channel, listener);
      };
    },
    getState: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:get-state", id) as Promise<{
        ok: boolean;
        state?: ElectronWebContentsState;
      }>,
    getAllStates: () =>
      ipcRenderer.invoke("cmux:webcontents:get-all-states") as Promise<{
        ok: boolean;
        states?: ElectronWebContentsSnapshot[];
      }>,
    openDevTools: (id: number, options?: { mode?: ElectronDevToolsMode }) =>
      ipcRenderer.invoke("cmux:webcontents:open-devtools", {
        id,
        mode: options?.mode,
      }) as Promise<{ ok: boolean }>,
    closeDevTools: (id: number) =>
      ipcRenderer.invoke("cmux:webcontents:close-devtools", id) as Promise<{ ok: boolean }>,
  },
};

contextBridge.exposeInMainWorld("electron", electronAPI);
contextBridge.exposeInMainWorld("api", api);
contextBridge.exposeInMainWorld("cmux", cmuxAPI);

// Mirror main process logs into the renderer console so they show up in
// DevTools. Avoid exposing tokens or sensitive data in main logs.
ipcRenderer.on(
  "main-log",
  (_event, payload: { level: "log" | "warn" | "error"; message: string }) => {
    const level = (payload?.level ?? "log") as ElectronMainLogMessage["level"];
    const message =
      typeof payload?.message === "string"
        ? payload.message
        : String(payload?.message ?? "");
    const entry: ElectronMainLogMessage = { level, message };

    const fn = console[level] ?? console.log;
    try {
      fn(message);
    } catch {
      // fallback
      console.log(message);
    }

    for (const listener of Array.from(mainLogListeners)) {
      try {
        listener(entry);
      } catch {
        // ignore listener errors to avoid breaking the bridge
      }
    }
  }
);
