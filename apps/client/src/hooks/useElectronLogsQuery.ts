import { useQuery } from "@tanstack/react-query";

import { fetchElectronLogs, hasElectronLogsBridge } from "@/lib/electron-logs/electron-logs";
import { isElectron } from "@/lib/electron";

export function useElectronLogsQuery() {
  return useQuery({
    queryKey: ["electron-logs", "files"],
    queryFn: fetchElectronLogs,
    enabled: isElectron && hasElectronLogsBridge(),
    staleTime: 5_000,
  });
}
