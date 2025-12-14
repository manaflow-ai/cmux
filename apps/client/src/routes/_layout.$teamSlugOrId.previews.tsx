import { TaskTree } from "@/components/TaskTree";
import { TaskTreeSkeleton } from "@/components/TaskTreeSkeleton";
import { FloatingPane } from "@/components/floating-pane";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { formatDistanceToNow } from "date-fns";
import {
  Camera,
  CheckCircle,
  ChevronDown,
  Circle,
  GitPullRequest,
  Loader2,
  XCircle,
} from "lucide-react";
import { useState, type ReactNode } from "react";

export const Route = createFileRoute("/_layout/$teamSlugOrId/previews")({
  component: PreviewsRoute,
  loader: async ({ params }) => {
    const { teamSlugOrId } = params;
    void convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.tasks.getPreviewTasksGroupedByPR, { teamSlugOrId })
    );
  },
});

type PreviewRunStatus = "pending" | "running" | "completed" | "failed" | "skipped";

function getStatusIcon(status: PreviewRunStatus): ReactNode {
  switch (status) {
    case "pending":
      return <Circle className="w-3.5 h-3.5 text-neutral-400" />;
    case "running":
      return <Loader2 className="w-3.5 h-3.5 text-blue-500 animate-spin" />;
    case "completed":
      return <CheckCircle className="w-3.5 h-3.5 text-green-500" />;
    case "failed":
      return <XCircle className="w-3.5 h-3.5 text-red-500" />;
    case "skipped":
      return <Circle className="w-3.5 h-3.5 text-neutral-400" />;
  }
}

function PreviewsRoute() {
  const { teamSlugOrId } = Route.useParams();
  const prGroups = useQuery(api.tasks.getPreviewTasksGroupedByPR, { teamSlugOrId });
  const { expandTaskIds } = useExpandTasks();

  return (
    <FloatingPane>
      <div className="grow h-full flex flex-col">
        <div className="border-b border-neutral-200 px-6 py-4 dark:border-neutral-800">
          <h1 className="text-base font-semibold text-neutral-900 dark:text-neutral-100 select-none">
            Previews
          </h1>
          <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
            Screenshot previews grouped by pull request
          </p>
        </div>
        <div className="overflow-y-auto px-4 pb-6">
          {prGroups === undefined ? (
            <TaskTreeSkeleton count={10} />
          ) : prGroups.length === 0 ? (
            <p className="mt-6 text-sm text-neutral-500 dark:text-neutral-400 select-none">
              No preview runs yet.
            </p>
          ) : (
            <div className="mt-4 space-y-3">
              {prGroups.map((group) => (
                <PRPreviewGroup
                  key={group.prKey}
                  group={group}
                  teamSlugOrId={teamSlugOrId}
                  defaultExpanded={
                    group.latestTask?._id
                      ? expandTaskIds?.includes(group.latestTask._id) ?? false
                      : false
                  }
                />
              ))}
            </div>
          )}
        </div>
      </div>
    </FloatingPane>
  );
}

type PRGroup = {
  prKey: string;
  repoFullName: string;
  prNumber: number;
  prUrl: string;
  totalRuns: number;
  totalScreenshots: number;
  latestTask: {
    _id: string;
    text: string;
    isCompleted: boolean;
  } | null;
  latestRunStatus: PreviewRunStatus;
  hasRunningRun: boolean;
  latestRunAt: number;
};

function PRPreviewGroup({
  group,
  teamSlugOrId,
  defaultExpanded,
}: {
  group: PRGroup;
  teamSlugOrId: string;
  defaultExpanded: boolean;
}) {
  const [isExpanded, setIsExpanded] = useState(defaultExpanded);
  const timeAgo = formatDistanceToNow(new Date(group.latestRunAt), {
    addSuffix: true,
  });

  return (
    <div className="rounded-xl border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950/70 overflow-hidden">
      {/* PR Header - always visible */}
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-neutral-50 dark:hover:bg-neutral-900/50 transition-colors"
      >
        <div className="flex items-center gap-2 flex-shrink-0">
          <ChevronDown
            className={`w-4 h-4 text-neutral-400 transition-transform ${
              isExpanded ? "rotate-180" : ""
            }`}
          />
          <GitPullRequest className="w-4 h-4 text-[#1f883d] dark:text-[#238636]" />
        </div>

        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-sm text-neutral-900 dark:text-neutral-100 truncate">
              {group.repoFullName}
            </span>
            <span className="text-sm text-neutral-500 dark:text-neutral-400 flex-shrink-0">
              #{group.prNumber}
            </span>
          </div>
          <div className="flex items-center gap-2 mt-0.5">
            <span className="text-xs text-neutral-500 dark:text-neutral-500">
              {timeAgo}
            </span>
            <span className="text-neutral-300 dark:text-neutral-700">·</span>
            <span className="text-xs text-neutral-500 dark:text-neutral-500">
              {group.totalRuns} {group.totalRuns === 1 ? "run" : "runs"}
            </span>
            {group.totalScreenshots > 0 && (
              <>
                <span className="text-neutral-300 dark:text-neutral-700">·</span>
                <span className="flex items-center gap-1 text-xs text-neutral-500 dark:text-neutral-500">
                  <Camera className="w-3 h-3" />
                  {group.totalScreenshots}
                </span>
              </>
            )}
          </div>
        </div>

        <div className="flex items-center gap-2 flex-shrink-0">
          {getStatusIcon(group.latestRunStatus)}
          {group.hasRunningRun && (
            <span className="px-1.5 py-0.5 text-[10px] font-medium rounded bg-blue-100 text-blue-700 dark:bg-blue-900/60 dark:text-blue-300">
              Running
            </span>
          )}
        </div>
      </button>

      {/* Expanded content - preview runs for this PR */}
      {isExpanded && group.latestTask && (
        <div className="border-t border-neutral-200 dark:border-neutral-800 px-4 py-3 bg-neutral-50/50 dark:bg-neutral-900/30">
          <TaskTree
            task={group.latestTask as Parameters<typeof TaskTree>[0]["task"]}
            defaultExpanded
            teamSlugOrId={teamSlugOrId}
          />

          {/* Link to view all runs for this PR */}
          {group.totalRuns > 1 && (
            <div className="mt-2 pt-2 border-t border-neutral-200 dark:border-neutral-800">
              <Link
                to="/$teamSlugOrId/prs-only/$owner/$repo/$number"
                params={{
                  teamSlugOrId,
                  owner: group.repoFullName.split("/")[0] ?? "",
                  repo: group.repoFullName.split("/")[1] ?? "",
                  number: String(group.prNumber),
                }}
                className="text-xs text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-300 transition-colors"
              >
                View all {group.totalRuns} runs for this PR →
              </Link>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
