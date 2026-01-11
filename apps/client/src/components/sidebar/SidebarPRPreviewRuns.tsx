import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { Link } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { formatDistanceToNow } from "date-fns";
import {
  Camera,
  CheckCircle,
  Circle,
  Loader2,
  XCircle,
} from "lucide-react";
import { useMemo } from "react";

type Props = {
  teamSlugOrId: string;
  repoFullName: string;
  prNumber: number;
};

type PreviewRunStatus = "pending" | "running" | "completed" | "failed" | "skipped";

function getStatusIcon(status: PreviewRunStatus) {
  switch (status) {
    case "pending":
      return <Circle className="w-3 h-3 text-neutral-400" />;
    case "running":
      return <Loader2 className="w-3 h-3 text-blue-500 animate-spin" />;
    case "completed":
      return <CheckCircle className="w-3 h-3 text-green-500" />;
    case "failed":
      return <XCircle className="w-3 h-3 text-red-500" />;
    case "skipped":
      return <Circle className="w-3 h-3 text-neutral-400" />;
  }
}

export function SidebarPRPreviewRuns({ teamSlugOrId, repoFullName, prNumber }: Props) {
  const previewRuns = useQuery(api.previewRuns.listByPullRequest, {
    teamSlugOrId,
    repoFullName,
    prNumber,
    limit: 5,
  });

  const latestRun = useMemo(() => {
    if (!previewRuns || previewRuns.length === 0) return null;
    return previewRuns[0];
  }, [previewRuns]);

  const olderRuns = useMemo(() => {
    if (!previewRuns || previewRuns.length <= 1) return [];
    return previewRuns.slice(1);
  }, [previewRuns]);

  if (previewRuns === undefined) {
    return (
      <div className="mt-px flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400 py-1.5" style={{ paddingLeft: "32px" }}>
        <Loader2 className="w-3 h-3 animate-spin" />
        <span>Loading previews...</span>
      </div>
    );
  }

  if (!latestRun) {
    return null;
  }

  return (
    <div className="flex flex-col" role="group">
      {/* Most recent preview run - always shown */}
      <PreviewRunItem
        run={latestRun}
        teamSlugOrId={teamSlugOrId}
        isLatest
      />

      {/* Older runs - shown in a subtle collapsed style */}
      {olderRuns.length > 0 && (
        <details className="group/older">
          <summary className="mt-px flex w-full items-center rounded-md pr-2 py-1 text-xs cursor-pointer hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 list-none" style={{ paddingLeft: "32px" }}>
            <span className="text-[10px] text-neutral-500 dark:text-neutral-500">
              {olderRuns.length} older {olderRuns.length === 1 ? "run" : "runs"}
            </span>
          </summary>
          <div className="flex flex-col">
            {olderRuns.map((run) => (
              <PreviewRunItem
                key={run._id}
                run={run}
                teamSlugOrId={teamSlugOrId}
                isLatest={false}
              />
            ))}
          </div>
        </details>
      )}
    </div>
  );
}

type PreviewRunItemProps = {
  run: {
    _id: string;
    status: PreviewRunStatus;
    taskId?: Id<"tasks">;
    screenshotCount: number;
    createdAt: number;
    headSha: string;
  };
  teamSlugOrId: string;
  isLatest: boolean;
};

function PreviewRunItem({ run, teamSlugOrId, isLatest }: PreviewRunItemProps) {
  const timeAgo = formatDistanceToNow(new Date(run.createdAt), { addSuffix: true });
  const shortSha = run.headSha?.slice(0, 7);

  // If we have a linked task, we can navigate to it
  const hasTask = Boolean(run.taskId);

  const content = (
    <div
      className={`mt-px flex w-full items-center gap-2 rounded-md pr-2 py-1 text-xs transition-colors ${
        hasTask ? "hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 cursor-default" : ""
      }`}
      style={{ paddingLeft: "32px" }}
    >
      <span className="flex items-center justify-center w-4 h-4 flex-shrink-0">
        {getStatusIcon(run.status)}
      </span>
      <span className="flex-1 min-w-0 flex items-center gap-1.5 text-neutral-600 dark:text-neutral-400">
        {isLatest && (
          <span className="px-1 py-0.5 text-[9px] font-medium rounded bg-emerald-100/80 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-300">
            Latest
          </span>
        )}
        <span className="truncate">{timeAgo}</span>
        {shortSha && (
          <span className="font-mono text-[10px] text-neutral-500 dark:text-neutral-500 flex-shrink-0">
            {shortSha}
          </span>
        )}
      </span>
      {run.screenshotCount > 0 && (
        <span className="flex items-center gap-0.5 text-[10px] text-neutral-500 dark:text-neutral-500 flex-shrink-0">
          <Camera className="w-3 h-3" />
          {run.screenshotCount}
        </span>
      )}
    </div>
  );

  if (hasTask && run.taskId) {
    return (
      <Link
        to="/$teamSlugOrId/task/$taskId"
        params={{ teamSlugOrId, taskId: run.taskId }}
        search={{ runId: undefined }}
      >
        {content}
      </Link>
    );
  }

  return content;
}

export default SidebarPRPreviewRuns;
