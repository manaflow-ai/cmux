import type {
  ElectronLogsPayload,
  ElectronMainLogMessage,
} from "../lib/electron-logs/types";
import type {
  ElectronDevToolsMode,
  ElectronWebContentsEvent,
  ElectronWebContentsSnapshot,
  ElectronWebContentsState,
} from "./electron-webcontents";

interface CmuxSocketAPI {
  connect: (
    query: Record<string, string>
  ) => Promise<{ socketId: string; connected: boolean }>;
  disconnect: (socketId: string) => Promise<{ disconnected: boolean }>;
  emit: (
    socketId: string,
    eventName: string,
    ...args: unknown[]
  ) => Promise<{ success: boolean }>;
  on: (socketId: string, eventName: string) => Promise<{ success: boolean }>;
  onEvent: (
    socketId: string,
    callback: (eventName: string, ...args: unknown[]) => void
  ) => void;
}

interface CmuxLogsAPI {
  onMainLog: (callback: (entry: ElectronMainLogMessage) => void) => () => void;
  readAll: () => Promise<ElectronLogsPayload>;
  copyAll: () => Promise<{ ok: boolean }>;
}

interface CmuxRectangle {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface CmuxWebContentsViewAPI {
  create: (options: {
    url: string;
    bounds?: CmuxRectangle;
    backgroundColor?: string;
    borderRadius?: number;
    persistKey?: string;
  }) => Promise<{ id: number; webContentsId: number; restored: boolean }>;
  setBounds: (options: {
    id: number;
    bounds: CmuxRectangle;
    visible?: boolean;
  }) => Promise<{ ok: boolean }>;
  loadURL: (id: number, url: string) => Promise<{ ok: boolean }>;
  release: (options: {
    id: number;
    persist?: boolean;
  }) => Promise<{ ok: boolean; suspended: boolean }>;
  destroy: (id: number) => Promise<{ ok: boolean }>;
  updateStyle: (options: {
    id: number;
    backgroundColor?: string;
    borderRadius?: number;
  }) => Promise<{ ok: boolean }>;
  goBack: (id: number) => Promise<{ ok: boolean }>;
  goForward: (id: number) => Promise<{ ok: boolean }>;
  reload: (id: number) => Promise<{ ok: boolean }>;
  onEvent: (
    id: number,
    callback: (event: ElectronWebContentsEvent) => void
  ) => () => void;
  getState: (
    id: number
  ) => Promise<{ ok: boolean; state?: ElectronWebContentsState }>;
  getAllStates: () =>
    Promise<{ ok: boolean; states?: ElectronWebContentsSnapshot[] }>;
  openDevTools: (
    id: number,
    options?: { mode?: ElectronDevToolsMode }
  ) => Promise<{ ok: boolean }>;
  closeDevTools: (id: number) => Promise<{ ok: boolean }>;
}

interface CmuxAPI {
  getCurrentWebContentsId?: () => number | undefined;
  register: (meta: {
    auth?: string;
    team?: string;
    auth_json?: string;
  }) => Promise<unknown>;
  rpc: (event: string, ...args: unknown[]) => Promise<unknown>;
  on: (event: string, callback: (...args: unknown[]) => void) => () => void;
  off: (event: string, callback?: (...args: unknown[]) => void) => void;
  ui: {
    focusWebContents: (id: number) => Promise<{ ok: boolean; queued?: boolean }>;
    restoreLastFocusInWebContents: (id: number) => Promise<{ ok: boolean; queued?: boolean }>;
    restoreLastFocusInFrame: (
      contentsId: number,
      frameRoutingId: number,
      frameProcessId: number
    ) => Promise<{ ok: boolean; queued?: boolean }>;
    setCommandPaletteOpen: (open: boolean) => Promise<{ ok: boolean }>;
    showEditContextMenu: (position?: { x?: number; y?: number }) => Promise<{ ok: boolean }>;
    setPreviewReloadVisible?: (visible: boolean) => Promise<{ ok: boolean }>;
    restoreLastFocus: () => Promise<{ ok: boolean; queued?: boolean }>;
  };
  socket: CmuxSocketAPI;
  logs: CmuxLogsAPI;
  webContentsView: CmuxWebContentsViewAPI;
  autoUpdate: {
    check: () =>
      Promise<{
        ok: boolean;
        reason?: string;
        updateAvailable?: boolean;
        version?: string | null;
      }>;
    install: () => Promise<{ ok: boolean; reason?: string }>;
  };
}

declare global {
  interface Window {
    cmux: CmuxAPI;
  }
}

export {};
