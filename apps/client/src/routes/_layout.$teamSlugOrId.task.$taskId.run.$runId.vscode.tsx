import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { useCallback } from "react";
import z from "zod";
import { PersistentWebView } from "@/components/persistent-webview";
import { getTaskRunPersistKey } from "@/lib/persistent-webview-keys";
import { preloadTaskRunIframes } from "../lib/preloadTaskRunIframes";


const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/vscode"
)({
  component: VSCodeComponent,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: async (opts) => {
    const result = await opts.context.queryClient.ensureQueryData(
      convexQuery(api.taskRuns.get, {
        teamSlugOrId: opts.params.teamSlugOrId,
        id: opts.params.runId,
      })
    );
    if (result) {
      void preloadTaskRunIframes([
        {
          url: result.vscode?.workspaceUrl || "",
          taskRunId: opts.params.runId,
        },
      ]);
    }
  },
});

function VSCodeComponent() {
  const { runId: taskRunId, teamSlugOrId } = Route.useParams();
  const taskRun = useSuspenseQuery(
    convexQuery(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    })
  );

  const workspaceUrl = taskRun?.data?.vscode?.workspaceUrl ?? null;
  const persistKey = getTaskRunPersistKey(taskRunId);
  const hasWorkspace = workspaceUrl !== null;

  const onLoad = useCallback(() => {
    console.log(`Workspace view loaded for task run ${taskRunId}`);
  }, [taskRunId]);

  const onError = useCallback(
    (error: Error) => {
      console.error(`Failed to load workspace view for task run ${taskRunId}:`, error);
    },
    [taskRunId]
  );

  return (
    <div className="pl-1 flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        <div className="flex flex-row grow min-h-0 relative">
          {workspaceUrl ? (
            <PersistentWebView
              persistKey={persistKey}
              src={workspaceUrl}
              className="grow flex relative"
              iframeClassName="select-none"
              allow="clipboard-read; clipboard-write; usb; serial; hid; cross-origin-isolated; autoplay; camera; microphone; geolocation; payment; fullscreen"
              sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts allow-top-navigation"
              retainOnUnmount
              suspended={!hasWorkspace}
              onLoad={onLoad}
              onError={onError}
            />
          ) : (
            <div className="grow" />
          )}
          <div
            className={clsx(
              "absolute inset-0 flex items-center justify-center transition pointer-events-none",
              {
                "opacity-100": !hasWorkspace,
                "opacity-0": hasWorkspace,
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
