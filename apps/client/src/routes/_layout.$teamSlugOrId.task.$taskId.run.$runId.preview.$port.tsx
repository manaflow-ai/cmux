import { ElectronPreviewBrowser } from "@/components/electron-preview-browser";
import { TaskRunTerminalSurface } from "@/components/TaskRunTerminalSurface";
import { Button } from "@/components/ui/button";
import { getTaskRunPreviewPersistKey } from "@/lib/persistent-webview-keys";
import { toProxyWorkspaceUrl } from "@/lib/toProxyWorkspaceUrl";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { X } from "lucide-react";
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
  const [showTerminal, setShowTerminal] = useState(false);

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
      (s) => s.port === portNum && s.status === "running",
    );
    return service?.url;
  }, [selectedRun, port]);

  const persistKey = useMemo(() => {
    return getTaskRunPreviewPersistKey(runId, port);
  }, [runId, port]);

  const workspaceUrl = useMemo(() => {
    const rawUrl = selectedRun?.vscode?.workspaceUrl;
    return rawUrl ? toProxyWorkspaceUrl(rawUrl) : null;
  }, [selectedRun]);

  const paneBorderRadius = 6;

  return (
    <div className="flex h-full flex-col bg-white dark:bg-neutral-950">
      <div className="relative flex-1 min-h-0 flex">
        {previewUrl ? (
          <>
            <div className={`flex-1 transition-all duration-300 ${showTerminal ? "mr-0" : "mr-0"}`}>
              <ElectronPreviewBrowser
                persistKey={persistKey}
                src={previewUrl}
                borderRadius={paneBorderRadius}
                showTerminal={showTerminal}
                onToggleTerminal={() => setShowTerminal((prev) => !prev)}
                onErrorStateChange={(isError) => {
                  if (isError) {
                    setShowTerminal(true);
                  }
                }}
              />
            </div>

            <div
              className={`transition-all duration-300 ease-out ${showTerminal ? "w-[500px]" : "w-0"} overflow-hidden border-l border-neutral-200 dark:border-neutral-800`}
            >
              <div className="w-[500px] h-full flex flex-col bg-neutral-950">
                {workspaceUrl ? (
                  <TaskRunTerminalSurface
                    workspaceUrl={workspaceUrl}
                    title="Dev script terminal"
                    subtitle="Streaming tmux window"
                    headerActions={
                      <Button
                        type="button"
                        size="icon"
                        variant="ghost"
                        onClick={() => setShowTerminal(false)}
                        className="text-neutral-600 hover:text-neutral-900 dark:text-neutral-300 dark:hover:text-white"
                        aria-label="Hide terminal"
                      >
                        <X className="size-4" />
                      </Button>
                    }
                    className="flex-1 bg-neutral-950 text-neutral-100"
                  />
                ) : (
                  <div className="flex h-full items-center justify-center text-neutral-500">
                    <p>Workspace not available</p>
                  </div>
                )}
              </div>
            </div>
          </>
        ) : (
          <div className="flex h-full items-center justify-center flex-1">
            <div className="text-center">
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
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
