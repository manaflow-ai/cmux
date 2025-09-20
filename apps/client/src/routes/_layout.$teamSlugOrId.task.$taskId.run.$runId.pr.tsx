import { FloatingPane } from "@/components/floating-pane";
import { PersistentWebView } from "@/components/persistent-webview";
import { getTaskRunPullRequestPersistKey } from "@/lib/persistent-webview-keys";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useMemo } from "react";
import z from "zod";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute("/_layout/$teamSlugOrId/task/$taskId/run/$runId/pr")(
  {
    component: RunPullRequestPage,
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
      await Promise.all([
        opts.context.queryClient.ensureQueryData(
          convexQuery(api.taskRuns.getByTask, {
            teamSlugOrId: opts.params.teamSlugOrId,
            taskId: opts.params.taskId,
          })
        ),
        opts.context.queryClient.ensureQueryData(
          convexQuery(api.tasks.getById, {
            teamSlugOrId: opts.params.teamSlugOrId,
            id: opts.params.taskId,
          })
        ),
      ]);
    },
  }
);

function RunPullRequestPage() {
  const { taskId, teamSlugOrId, runId } = Route.useParams();

  const task = useQuery(api.tasks.getById, {
    teamSlugOrId,
    id: taskId,
  });

  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });

  // Get the specific run from the URL parameter
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  const pullRequestUrl = selectedRun?.pullRequestUrl;
  const isPending = pullRequestUrl === "pending";
  const hasUrl = pullRequestUrl && pullRequestUrl !== "pending";
  const persistKey = useMemo(() => {
    return getTaskRunPullRequestPersistKey(runId);
  }, [runId]);
  const paneBorderRadius = 6;

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          {/* Header */}
          <div className="border-b border-neutral-200 dark:border-neutral-800 px-4 py-3 flex items-center justify-between shrink-0">
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Pull Request
              </h2>
              {selectedRun?.pullRequestState && (
                <span className="text-xs px-2 py-0.5 rounded-full bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400">
                  {selectedRun.pullRequestState}
                </span>
              )}
            </div>
            {hasUrl && (
              <a
                href={pullRequestUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-blue-600 dark:text-blue-400 hover:underline flex items-center gap-1"
              >
                Open in GitHub
                <svg
                  className="w-3 h-3"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                  />
                </svg>
              </a>
            )}
          </div>

          {/* Task description */}
          {task?.text && (
            <div className="px-4 py-2 border-b border-neutral-200 dark:border-neutral-800">
              <div className="text-xs text-neutral-600 dark:text-neutral-300">
                <span className="text-neutral-500 dark:text-neutral-400 select-none">
                  Task:{" "}
                </span>
                <span className="font-medium">{task.text}</span>
              </div>
            </div>
          )}

          {/* Main content */}
          <div className="flex-1 bg-white dark:bg-neutral-950">
            {isPending ? (
              <div className="flex flex-col items-center justify-center h-full text-neutral-500 dark:text-neutral-400">
                <div className="w-8 h-8 border-2 border-neutral-300 dark:border-neutral-600 border-t-blue-500 rounded-full animate-spin mb-4" />
                <p className="text-sm">Pull request is being created...</p>
              </div>
            ) : hasUrl ? (
              <PersistentWebView
                persistKey={persistKey}
                src={pullRequestUrl}
                className="w-full h-full border-0"
                borderRadius={paneBorderRadius}
              />
            ) : (
              <div className="flex flex-col items-center justify-center h-full text-neutral-500 dark:text-neutral-400">
                <svg
                  className="w-16 h-16 mb-4 text-neutral-300 dark:text-neutral-700"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
                  />
                </svg>
                <p className="text-sm font-medium mb-1">No pull request</p>
                <p className="text-xs">This run doesn't have an associated pull request</p>
              </div>
            )}
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
