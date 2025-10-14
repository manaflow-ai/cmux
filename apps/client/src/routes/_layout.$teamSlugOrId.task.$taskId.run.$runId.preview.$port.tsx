import { ElectronPreviewBrowser } from "@/components/electron-preview-browser";
import { getTaskRunPreviewPersistKey } from "@/lib/persistent-webview-keys";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useMemo } from "react";
import z from "zod";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
  port: z.string(),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/preview/$port",
)({
  component: PreviewPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
        port: params.port,
      };
    },
  },
});

function PreviewPage() {
  const { taskId, teamSlugOrId, runId, port } = Route.useParams();

  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });

  // Get the specific run
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  // Find the service for the requested port
  const service = useMemo(() => {
    if (!selectedRun?.networking) return null;
    const portNum = parseInt(port, 10);
    return selectedRun.networking.find((s) => s.port === portNum);
  }, [selectedRun, port]);

  // Preview is ready when service exists, has a URL, and status is "running"
  const previewUrl = service?.url ?? null;
  const isPreviewReady = service?.status === "running" && previewUrl !== null;
  const isPreviewStarting = service?.status === "starting";

  const persistKey = useMemo(() => {
    return getTaskRunPreviewPersistKey(runId, port);
  }, [runId, port]);

  const paneBorderRadius = 6;

  return (
    <div className="flex h-full flex-col bg-white dark:bg-neutral-950">
      <div className="flex-1 min-h-0 relative">
        {previewUrl && isPreviewReady ? (
          <ElectronPreviewBrowser
            persistKey={persistKey}
            src={previewUrl}
            borderRadius={paneBorderRadius}
          />
        ) : (
          <div className="flex h-full items-center justify-center">
            <div className="text-center">
              {isPreviewStarting || (service && !isPreviewReady) ? (
                <div className="flex flex-col items-center gap-3">
                  <div className="flex gap-1">
                    <div
                      className="w-2 h-2 bg-blue-500 rounded-full animate-bounce"
                      style={{ animationDelay: "0ms" }}
                    />
                    <div
                      className="w-2 h-2 bg-blue-500 rounded-full animate-bounce"
                      style={{ animationDelay: "150ms" }}
                    />
                    <div
                      className="w-2 h-2 bg-blue-500 rounded-full animate-bounce"
                      style={{ animationDelay: "300ms" }}
                    />
                  </div>
                  <span className="text-sm text-neutral-500 dark:text-neutral-400">
                    Starting dev server on port {port}...
                  </span>
                </div>
              ) : (
                <>
                  <p className="mb-2 text-sm text-neutral-500 dark:text-neutral-400">
                    {selectedRun
                      ? `Port ${port} is not available for this run`
                      : "Loading..."}
                  </p>
                  {selectedRun?.networking && selectedRun.networking.length > 0 && (
                    <div className="mt-4">
                      <p className="mb-2 text-xs text-neutral-400 dark:text-neutral-500">
                        Available ports:
                      </p>
                      <div className="flex justify-center gap-2">
                        {selectedRun.networking
                          .filter((s) => s.status === "running")
                          .map((service) => (
                            <span
                              key={service.port}
                              className="rounded px-2 py-1 text-xs bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-200"
                            >
                              {service.port}
                            </span>
                          ))}
                      </div>
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
