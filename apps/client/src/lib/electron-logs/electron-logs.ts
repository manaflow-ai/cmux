import { isElectron } from "@/lib/electron";

import type {
  ElectronLogsPayload,
  ElectronMainLogMessage,
} from "./types";

type LogsBridge = {
  onMainLog?: (callback: (entry: ElectronMainLogMessage) => void) => () => void;
  readAll?: () => Promise<ElectronLogsPayload>;
  copyAll?: () => Promise<{ ok: boolean }>;
};

function getLogsBridge(): LogsBridge | null {
  if (!isElectron) return null;
  if (typeof window === "undefined") return null;
  const maybe = window as Window & { cmux?: { logs?: LogsBridge } };
  const logs = maybe.cmux?.logs;
  if (!logs) return null;
  if (typeof logs.readAll !== "function") return null;
  if (typeof logs.copyAll !== "function") return null;
  return logs;
}

export function hasElectronLogsBridge(): boolean {
  return Boolean(getLogsBridge());
}

export async function fetchElectronLogs(): Promise<ElectronLogsPayload> {
  const bridge = getLogsBridge();
  if (!bridge?.readAll) {
    throw new Error("Electron logs bridge unavailable");
  }
  const result = await bridge.readAll();
  if (!result || !Array.isArray(result.files) || typeof result.combinedText !== "string") {
    throw new Error("Invalid logs payload received");
  }
  return result;
}

export async function copyAllElectronLogs(): Promise<boolean> {
  const bridge = getLogsBridge();
  if (!bridge?.copyAll) return false;
  try {
    const response = await bridge.copyAll();
    if (response && typeof response.ok === "boolean") {
      return response.ok;
    }
    return true;
  } catch {
    return false;
  }
}

export function subscribeToElectronMainLog(
  callback: (entry: ElectronMainLogMessage) => void
): () => void {
  const bridge = getLogsBridge();
  if (!bridge?.onMainLog) {
    return () => undefined;
  }
  return bridge.onMainLog(callback);
}
