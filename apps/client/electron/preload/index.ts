import { electronAPI } from "@electron-toolkit/preload";
import { contextBridge, ipcRenderer } from "electron";
import type { AutoUpdateEvent, Unsubscribe } from "../../src/types/preload";

const api = {
  updates: {
    onUpdate(cb: (event: AutoUpdateEvent) => void): Unsubscribe {
      const channel = "cmux:auto-update";
      const handler = (_: unknown, payload: AutoUpdateEvent) => cb(payload);
      ipcRenderer.on(channel, handler);
      return () =>
        ipcRenderer.removeListener(
          channel,
          handler as (...args: unknown[]) => void
        );
    },
    install(): void {
      void ipcRenderer.invoke("cmux:install-update");
    },
    checkNow(): void {
      void ipcRenderer.invoke("cmux:check-for-updates");
    },
  },
};

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld("electron", electronAPI);
    contextBridge.exposeInMainWorld("api", api);
  } catch (error) {
    console.error(error);
  }
} else {
  window.electron = electronAPI;
  window.api = api;
}
