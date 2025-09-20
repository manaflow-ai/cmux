export type ElectronLogLevel = "log" | "warn" | "error";

export interface ElectronMainLogMessage {
  level: ElectronLogLevel;
  message: string;
}

export interface ElectronLogFile {
  name: string;
  path: string;
  size: number;
  modifiedMs: number | null;
  content: string;
}

export interface ElectronLogsPayload {
  files: ElectronLogFile[];
  combinedText: string;
}
