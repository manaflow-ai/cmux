export type ElectronDevToolsMode = "right" | "bottom" | "undocked" | "detach";

export interface ElectronWebContentsState {
  id: number;
  webContentsId: number;
  url: string;
  title: string;
  canGoBack: boolean;
  canGoForward: boolean;
  isLoading: boolean;
  isDevToolsOpened: boolean;
}

export interface ElectronWebContentsStateEvent {
  type: "state";
  state: ElectronWebContentsState;
  reason?: string;
}

export interface ElectronWebContentsLoadFailedEvent {
  type: "load-failed";
  id: number;
  errorCode: number;
  errorDescription: string;
  validatedURL: string;
  isMainFrame: boolean;
}

export type ElectronWebContentsEvent =
  | ElectronWebContentsStateEvent
  | ElectronWebContentsLoadFailedEvent;
