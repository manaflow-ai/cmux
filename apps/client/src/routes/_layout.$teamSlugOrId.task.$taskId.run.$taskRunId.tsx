import { api } from "@cmux/convex/api";
import { getShortId } from "@cmux/shared";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { usePersistentIframe } from "../hooks/usePersistentIframe";
import { preloadTaskRunIframes } from "../lib/preloadTaskRunIframes";

// Configuration: Set to true to use the proxy URL, false to use direct localhost URL
const USE_PROXY_URL = false;

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$taskRunId"
)({
  component: TaskRunComponent,
  parseParams: (params) => ({
    ...params,
    taskRunId: typedZid("taskRuns").parse(params.taskRunId),
  }),
  loader: async (opts) => {
    const result = await opts.context.queryClient.ensureQueryData(
      convexQuery(api.taskRuns.get, {
        teamSlugOrId: opts.params.teamSlugOrId,
        id: opts.params.taskRunId,
      })
    );
    if (result) {
      void preloadTaskRunIframes([
        {
          url: result.vscode?.workspaceUrl || "",
          key: `task-run-${opts.params.taskRunId}`,
        },
      ]);
    }
  },
});

function TaskRunComponent() {
  const { taskRunId, teamSlugOrId } = Route.useParams();
  const taskRun = useSuspenseQuery(
    convexQuery(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    })
  );

  const shortId = getShortId(taskRunId);

  const iframeUrl = USE_PROXY_URL
    ? `http://${shortId}.39378.localhost:9776/?folder=/root/workspace`
    : taskRun?.data?.vscode?.workspaceUrl || "about:blank";

  const { containerRef } = usePersistentIframe({
    key: `task-run-${taskRunId}`,
    url: iframeUrl,
    className: "select-none",
    allow:
      "clipboard-read; clipboard-write; usb; serial; hid; cross-origin-isolated; autoplay; camera; microphone; geolocation; payment; fullscreen",
    sandbox:
      "allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts allow-top-navigation",
    onLoad: () => {
      console.log(`Iframe loaded for task run ${taskRunId}`);
    },
    onError: (error) => {
      console.error(`Failed to load iframe for task run ${taskRunId}:`, error);
    },
  });

  return (
    <div className="pl-1 flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        <div className="flex flex-row grow min-h-0 relative">
          <div
            ref={containerRef}
            className={clsx("grow flex relative", {
              invisible: !taskRun?.data?.vscode?.workspaceUrl,
            })}
          />
          <div
            className={clsx(
              "absolute inset-0 flex items-center justify-center transition",
              {
                "opacity-100 pointer-events-none":
                  !taskRun?.data?.vscode?.workspaceUrl,
                "opacity-0 pointer-events-auto":
                  taskRun?.data?.vscode?.workspaceUrl,
              }
            )}
          >
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
              <span className="text-sm text-neutral-500">
                Starting VS Code...
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
