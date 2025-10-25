import { waitForConnectedSocket } from "@/contexts/socket/socket-boot";
import { queryOptions } from "@tanstack/react-query";
import type {
  RunBranchStatus,
  RunSyncResponse,
  RunSyncStatusResponse,
} from "@cmux/shared";

export function runSyncStatusQueryOptions({
  taskRunId,
  teamSlugOrId,
  enabled = true,
}: {
  taskRunId: string;
  teamSlugOrId: string;
  enabled?: boolean;
}) {
  return queryOptions<RunBranchStatus>({
    queryKey: ["task-run-sync-status", teamSlugOrId, taskRunId],
    queryFn: async () => {
      const socket = await waitForConnectedSocket();
      return await new Promise<RunBranchStatus>((resolve, reject) => {
        socket.emit(
          "task-run-sync-status",
          { taskRunId },
          (response: RunSyncStatusResponse) => {
            if (response?.ok && response.status) {
              resolve(response.status);
            } else {
              reject(
                new Error(
                  response?.error ?? "Failed to fetch sync status",
                ),
              );
            }
          },
        );
      });
    },
    enabled: enabled && Boolean(taskRunId),
    staleTime: 5_000,
  });
}

export async function performRunSync(taskRunId: string): Promise<RunSyncResponse> {
  const socket = await waitForConnectedSocket();
  return await new Promise<RunSyncResponse>((resolve, reject) => {
    socket.emit(
      "task-run-sync",
      { taskRunId },
      (response: RunSyncResponse | undefined) => {
        if (!response) {
          reject(new Error("Sync response was empty"));
          return;
        }
        resolve(response);
      },
    );
  });
}
