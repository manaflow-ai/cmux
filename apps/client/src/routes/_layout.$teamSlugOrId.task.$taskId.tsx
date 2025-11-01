import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useClipboard } from "@mantine/hooks";
import { useSuspenseQuery } from "@tanstack/react-query";
import {
  createFileRoute,
  Link,
  Outlet,
  useChildMatches,
  useNavigate,
} from "@tanstack/react-router";
import clsx from "clsx";
import { Suspense, useEffect } from "react";

export const Route = createFileRoute("/_layout/$teamSlugOrId/task/$taskId")({
  component: TaskDetailPage,
  parseParams: (params) => ({
    ...params,
    taskId: typedZid("tasks").parse(params.taskId),
  }),
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
});

const WITH_HEADER = false;
const WITH_TABS = false;

// type TaskRunWithChildren = DataModel["taskRuns"] & { children: TaskRunWithChildren[] };
type GetByTaskResultItem = (typeof api.taskRuns.getByTask._returnType)[number];

function TaskDetailPage() {
  const { taskId, teamSlugOrId } = Route.useParams();
  const { data: task } = useSuspenseQuery(
    convexQuery(api.tasks.getById, {
      teamSlugOrId,
      id: taskId,
    })
  );
  const { data: taskRuns } = useSuspenseQuery(
    convexQuery(api.taskRuns.getByTask, {
      teamSlugOrId,
      taskId,
    })
  );
  const clipboard = useClipboard({ timeout: 2000 });

  // Get the deepest matched child to extract runId if present
  const childMatches = useChildMatches();
  const deepestMatch = childMatches[childMatches.length - 1];
  const deepestMatchParams = deepestMatch?.params as
    | { taskRunId: string }
    | undefined;
  const activeRunId = deepestMatchParams?.taskRunId as string | undefined;

  const navigate = useNavigate();

  // Flatten the task runs tree structure for tab display
  const flattenRuns = (
    runs: GetByTaskResultItem[]
  ): Array<GetByTaskResultItem & { depth: number }> => {
    const result: Array<GetByTaskResultItem & { depth: number }> = [];
    const traverse = (run: GetByTaskResultItem, depth: number = 0) => {
      result.push({ ...run, depth });
      if (run.children) {
        run.children.forEach((child: GetByTaskResultItem) =>
          traverse(child, depth + 1)
        );
      }
    };
    runs?.forEach((run) => traverse(run));
    return result;
  };

  const flatRuns = flattenRuns(taskRuns || []);

  const handleCopyTaskText = () => {
    if (task?.text) {
      clipboard.copy(task.text);
    }
  };

  // Keyboard shortcuts for navigating between runs
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Check for Ctrl+1-9 on macOS, Alt+1-9 on Windows/Linux
      const isMac = navigator.platform.toUpperCase().indexOf("MAC") >= 0;
      const modifierPressed = isMac ? e.ctrlKey : e.altKey;

      if (modifierPressed && e.key >= "1" && e.key <= "9") {
        e.preventDefault();
        const keyNum = parseInt(e.key);
        let runIndex: number;

        if (keyNum === 9) {
          // 9 navigates to the last run
          runIndex = flatRuns.length - 1;
        } else {
          // 1-8 navigate to corresponding run (0-based index)
          runIndex = keyNum - 1;
        }

        if (flatRuns[runIndex]) {
          navigate({
            to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
            params: {
              teamSlugOrId,
              taskId,
              runId: flatRuns[runIndex]._id,
            },
          });
        }
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [flatRuns, taskId, navigate, teamSlugOrId]);

  if (!task || !taskRuns) {
    return <div className="p-8">Loading...</div>;
  }

  return (
    <div className="flex flex-col grow min-h-0 min-w-0">
      {WITH_HEADER && (
        <div className="border-b border-neutral-200 dark:border-neutral-700 px-3 py-2">
          <div className="relative group">
            <h1 className="text-sm font-semibold text-neutral-900 dark:text-neutral-100 truncate pr-8">
              {task.text}
            </h1>
            <button
              onClick={handleCopyTaskText}
              className="absolute right-0 top-0 p-1 text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200 transition-all duration-200 opacity-0 group-hover:opacity-100"
              title={clipboard.copied ? "Copied!" : "Copy task text"}
            >
              {clipboard.copied ? (
                <svg
                  className="w-4 h-4 text-green-500"
                  fill="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41L9 16.17z" />
                </svg>
              ) : (
                <svg
                  className="w-4 h-4"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
                  />
                </svg>
              )}
            </button>
          </div>
          {task.description && (
            <p className="text-sm text-neutral-500 dark:text-neutral-400 mt-1">
              {task.description}
            </p>
          )}
        </div>
      )}
      {WITH_TABS && flatRuns.length > 0 && (
        <div className="border-b border-neutral-200 dark:border-neutral-700">
          <div className="flex overflow-x-auto">
            {flatRuns.map((run, index) => (
              <Link
                key={run._id}
                to="/$teamSlugOrId/task/$taskId/run/$runId/vscode"
                params={{
                  teamSlugOrId,
                  taskId,
                  runId: run._id,
                }}
                className={clsx(
                  "px-4 py-2 text-sm font-medium whitespace-nowrap border-b-2 transition-colors select-none",
                  activeRunId === run._id
                    ? "text-blue-600 dark:text-blue-400 border-blue-600 dark:border-blue-400"
                    : "text-neutral-600 dark:text-neutral-400 border-transparent hover:text-neutral-900 dark:hover:text-neutral-100"
                )}
                // No onClick needed; active class controlled by URL
              >
                <span style={{ paddingLeft: `${run.depth * 12}px` }}>
                  {(() => {
                    const name = run.agentName?.trim();
                    if (name && name.length > 0) return name;
                    const summary = run.summary?.trim();
                    if (summary && summary.length > 0) return summary;
                    return `Run ${index + 1}`;
                  })()}
                  {run.status === "running" && " 🟢"}
                  {run.status === "completed" && " ✅"}
                  {run.status === "failed" && " ❌"}
                  {run.isCrowned && " 🏆"}
                </span>
              </Link>
            ))}
          </div>
        </div>
      )}
      <div className="grow flex flex-col min-h-0">
        <Suspense fallback={<div>Loading...</div>}>
          <Outlet />
        </Suspense>
      </div>
    </div>
  );
}
