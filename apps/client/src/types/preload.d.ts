export type UpdateStatus =
  | "checking"
  | "available"
  | "not-available"
  | "download-progress"
  | "downloaded"
  | "error";

export interface AutoUpdateEvent {
  status: UpdateStatus;
  message?: string;
  info?: { version?: string | null; releaseNotes?: string | null };
  progress?: {
    percent: number;
    transferred: number;
    total: number;
    bytesPerSecond: number;
  };
}

export type Unsubscribe = () => void;

declare global {
  interface Window {
    electron: unknown;
    api: {
      updates: {
        onUpdate: (cb: (event: AutoUpdateEvent) => void) => Unsubscribe;
        install: () => void;
        checkNow: () => void;
      };
    };
  }
}

export {};
