import { ElectronPreviewBrowser } from "@/components/electron-preview-browser";
import { PersistentWebView } from "@/components/persistent-webview";
import { isElectron } from "@/lib/electron";
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
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/preview/$port"
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

  // Find the service URL for the requested port
  const previewUrl = useMemo(() => {
    if (!selectedRun?.networking) return null;
    const portNum = parseInt(port, 10);
    const service = selectedRun.networking.find(
      (s) => s.port === portNum && s.status === "running"
    );
    return service?.url;
  }, [selectedRun, port]);

  const persistKey = useMemo(() => {
    return getTaskRunPreviewPersistKey(runId, port);
  }, [runId, port]);

  const paneBorderRadius = 6;

  return (
    <>
      {previewUrl ? (
        isElectron ? (
          <ElectronPreviewBrowser
            persistKey={persistKey}
            src={previewUrl}
            borderRadius={paneBorderRadius}
          />
        ) : (
          <PersistentWebView
            persistKey={persistKey}
            src={previewUrl}
            className="w-full h-full border-0"
            borderRadius={paneBorderRadius}
            sandbox="allow-same-origin allow-scripts allow-popups allow-forms allow-modals allow-downloads"
          />
        )
      ) : (
        <div className="flex items-center justify-center h-full bg-white dark:bg-neutral-950">
          <div className="text-center">
            <p className="text-sm text-neutral-500 dark:text-neutral-400 mb-2">
              {selectedRun
                ? `Port ${port} is not available for this run`
                : "Loading..."}
            </p>
            {selectedRun?.networking && selectedRun.networking.length > 0 && (
              <div className="mt-4">
                <p className="text-xs text-neutral-400 dark:text-neutral-500 mb-2">
                  Available ports:
                </p>
                <div className="flex gap-2 justify-center">
                  {selectedRun.networking
                    .filter((s) => s.status === "running")
                    .map((service) => (
                      <span
                        key={service.port}
                        className="px-2 py-1 text-xs bg-neutral-100 dark:bg-neutral-800 rounded"
                      >
                        {service.port}
                      </span>
                    ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </>
  );
}
