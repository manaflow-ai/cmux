import { useCallback, useEffect, useState } from "react";

import { subscribeToElectronMainLog } from "@/lib/electron-logs/electron-logs";
import type { ElectronMainLogMessage } from "@/lib/electron-logs/types";
import { isElectron } from "@/lib/electron";

export interface ElectronMainLogEntry extends ElectronMainLogMessage {
  receivedAt: number;
}

const DEFAULT_MAX_ENTRIES = 400;

export function useElectronMainLogStream(maxEntries: number = DEFAULT_MAX_ENTRIES) {
  const [entries, setEntries] = useState<ElectronMainLogEntry[]>([]);

  useEffect(() => {
    if (!isElectron) return undefined;
    const unsubscribe = subscribeToElectronMainLog((entry) => {
      setEntries((prev) => {
        const next: ElectronMainLogEntry[] = [
          ...prev,
          { ...entry, receivedAt: Date.now() },
        ];
        if (next.length > maxEntries) {
          next.splice(0, next.length - maxEntries);
        }
        return next;
      });
    });
    return unsubscribe;
  }, [maxEntries]);

  const clear = useCallback(() => {
    setEntries([]);
  }, []);

  return { entries, clear };
}
