import { GitHubIcon } from "@/components/icons/github";
import { api } from "@cmux/convex/api";
import { Link } from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import clsx from "clsx";
import {
  Eye,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  Loader2,
} from "lucide-react";
import { useMemo, useState, type MouseEvent } from "react";
import { SidebarListItem } from "./SidebarListItem";
import { SIDEBAR_PRS_DEFAULT_LIMIT } from "./const";
import type { Doc, Id } from "@cmux/convex/dataModel";

type PreviewRunInfo = {
  _id: string;
  status: string;
  createdAt: number;
  completedAt?: number;
  headRef?: string;
  screenshotSetId?: string;
  taskId?: string;
};

type Props = {
  teamSlugOrId: string;
  limit?: number;
};

export function SidebarPullRequestList({
  teamSlugOrId,
  limit = SIDEBAR_PRS_DEFAULT_LIMIT,
}: Props) {
  const prs = useConvexQuery(api.github_prs.listPullRequests, {
    teamSlugOrId,
    state: "open",
    limit,
  });

  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  const list = useMemo(() => prs ?? [], [prs]);

  // Build the list of PRs to query for preview runs
  const prsToQuery = useMemo(
    () =>
      list.map((pr) => ({
        repoFullName: pr.repoFullName,
        prNumber: pr.number,
      })),
    [list]
  );

  // Fetch preview runs for all visible PRs
  const previewRuns = useConvexQuery(
    api.previewRuns.getMostRecentForPrs,
    list.length > 0 ? { teamSlugOrId, prs: prsToQuery } : "skip"
  );

  if (prs === undefined) {
    return (
      <ul className="flex flex-col gap-px" aria-label="Loading pull requests">
        {Array.from({ length: limit }).map((_, index) => (
          <li key={index} className="px-2 py-1.5">
            <div className="h-3 rounded bg-neutral-200 dark:bg-neutral-800 animate-pulse" />
          </li>
        ))}
      </ul>
    );
  }

  if (list.length === 0) {
    return (
      <p className="mt-1 pl-2 pr-3 py-2 text-xs text-neutral-500 dark:text-neutral-400 select-none">
        No pull requests
      </p>
    );
  }

  return (
    <ul className="flex flex-col gap-px">
      {list.map((pr) => {
        const key = `${pr.repoFullName}#${pr.number}`;
        const previewRun = previewRuns?.[key];
        return (
          <PullRequestListItem
            key={key}
            pr={pr}
            teamSlugOrId={teamSlugOrId}
            expanded={expanded}
            setExpanded={setExpanded}
            previewRun={previewRun}
          />
        );
      })}
    </ul>
  );
}

type PullRequestListItemProps = {
  pr: Doc<"pullRequests">;
  teamSlugOrId: string;
  expanded: Record<string, boolean>;
  setExpanded: React.Dispatch<React.SetStateAction<Record<string, boolean>>>;
  previewRun?: PreviewRunInfo;
};

function PullRequestListItem({ pr, teamSlugOrId, expanded, setExpanded, previewRun }: PullRequestListItemProps) {
  const [owner = "", repo = ""] = pr.repoFullName?.split("/", 2) ?? ["", ""];
  const key = `${pr.repoFullName}#${pr.number}`;
  const isExpanded = expanded[key] ?? false;
  const branchLabel = pr.headRef;

  const secondaryParts = [
    branchLabel,
    `${pr.repoFullName}#${pr.number}`,
    pr.authorLogin,
  ]
    .filter(Boolean)
    .map(String);
  const secondary = secondaryParts.join(" • ");
  const leadingIcon = pr.merged ? (
    <GitMerge className="w-3 h-3 text-purple-500" />
  ) : pr.state === "closed" ? (
    <GitPullRequestClosed className="w-3 h-3 text-red-500" />
  ) : pr.draft ? (
    <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />
  ) : (
    <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
  );

  const handleToggle = (
    _event?: MouseEvent<HTMLButtonElement | HTMLAnchorElement>
  ) => {
    setExpanded((prev) => ({
      ...prev,
      [key]: !isExpanded,
    }));
  };

  // Format preview status for display
  const getPreviewStatusInfo = (run: PreviewRunInfo) => {
    const isInProgress = run.status === "pending" || run.status === "running";
    const isCompleted = run.status === "completed" || run.status === "skipped";
    const isFailed = run.status === "failed";

    const statusLabel = isInProgress
      ? "Running"
      : isCompleted
        ? "Complete"
        : isFailed
          ? "Failed"
          : run.status;

    return { isInProgress, isCompleted, isFailed, statusLabel };
  };

  // Format time ago for preview run
  const formatTimeAgo = (timestamp: number) => {
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);

    if (minutes < 1) return "just now";
    if (minutes < 60) return `${minutes}m ago`;
    if (hours < 24) return `${hours}h ago`;
    return `${days}d ago`;
  };

  return (
    <li key={key} className="rounded-md select-none">
      <Link
        to="/$teamSlugOrId/prs-only/$owner/$repo/$number"
        params={{
          teamSlugOrId,
          owner,
          repo,
          number: String(pr.number),
        }}
        className="group block"
        onClick={(event) => {
          if (
            event.defaultPrevented ||
            event.metaKey ||
            event.ctrlKey ||
            event.shiftKey ||
            event.altKey
          ) {
            return;
          }
          handleToggle(event);
        }}
      >
        <SidebarListItem
          paddingLeft={10}
          toggle={{
            expanded: isExpanded,
            onToggle: handleToggle,
            visible: true,
          }}
          title={pr.title}
          titleClassName="text-[13px] text-neutral-950 dark:text-neutral-100"
          secondary={secondary || undefined}
          meta={leadingIcon}
        />
      </Link>
      {isExpanded ? (
        <div className="mt-px flex flex-col" role="group">
          {/* Preview run info */}
          {previewRun && (
            <PreviewRunLink
              previewRun={previewRun}
              teamSlugOrId={teamSlugOrId}
              getStatusInfo={getPreviewStatusInfo}
              formatTimeAgo={formatTimeAgo}
            />
          )}
          {/* GitHub link */}
          {pr.htmlUrl && (
            <a
              href={pr.htmlUrl}
              target="_blank"
              rel="noreferrer"
              onClick={(event) => {
                event.stopPropagation();
              }}
              className="mt-px flex w-full items-center rounded-md pr-2 py-1 text-xs transition-colors hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45"
              style={{ paddingLeft: "32px" }}
            >
              <GitHubIcon
                className="mr-2 h-3 w-3 text-neutral-400 grayscale opacity-60"
                aria-hidden
              />
              <span className="text-neutral-600 dark:text-neutral-400">
                GitHub
              </span>
            </a>
          )}
        </div>
      ) : null}
    </li>
  );
}

// Component to render the preview run link under a PR
function PreviewRunLink({
  previewRun,
  teamSlugOrId,
  getStatusInfo,
  formatTimeAgo,
}: {
  previewRun: PreviewRunInfo;
  teamSlugOrId: string;
  getStatusInfo: (run: PreviewRunInfo) => {
    isInProgress: boolean;
    isCompleted: boolean;
    isFailed: boolean;
    statusLabel: string;
  };
  formatTimeAgo: (timestamp: number) => string;
}) {
  const { isInProgress, isCompleted, isFailed, statusLabel } = getStatusInfo(previewRun);
  const timestamp = previewRun.completedAt || previewRun.createdAt;

  // Status indicator dot/spinner
  const StatusIndicator = () => {
    if (isInProgress) {
      return (
        <Loader2
          className="mr-2 h-3 w-3 text-blue-500 animate-spin"
          aria-hidden
        />
      );
    }
    return (
      <div
        className={clsx(
          "mr-2 h-2 w-2 rounded-full flex-shrink-0",
          isCompleted && "bg-green-500",
          isFailed && "bg-red-500",
          !isCompleted && !isFailed && "bg-neutral-400"
        )}
        aria-hidden
      />
    );
  };

  // If there's a taskId, make it a link to the task
  if (previewRun.taskId) {
    return (
      <Link
        to="/$teamSlugOrId/task/$taskId"
        params={{
          teamSlugOrId,
          taskId: previewRun.taskId as Id<"tasks">,
        }}
        search={{ runId: undefined }}
        onClick={(event) => {
          event.stopPropagation();
        }}
        className="mt-px flex w-full items-center rounded-md pr-2 py-1 text-xs transition-colors hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45"
        style={{ paddingLeft: "32px" }}
      >
        <StatusIndicator />
        <Eye className="mr-1.5 h-3 w-3 text-neutral-400 dark:text-neutral-500" aria-hidden />
        <span className="text-neutral-600 dark:text-neutral-400 flex-1 min-w-0 truncate">
          Preview
        </span>
        <span className="ml-1 text-neutral-400 dark:text-neutral-500 text-[10px]">
          {statusLabel} {formatTimeAgo(timestamp)}
        </span>
      </Link>
    );
  }

  // Without taskId, just show status (no link)
  return (
    <div
      className="mt-px flex w-full items-center rounded-md pr-2 py-1 text-xs"
      style={{ paddingLeft: "32px" }}
    >
      <StatusIndicator />
      <Eye className="mr-1.5 h-3 w-3 text-neutral-400 dark:text-neutral-500" aria-hidden />
      <span className="text-neutral-500 dark:text-neutral-500 flex-1 min-w-0 truncate">
        Preview
      </span>
      <span className="ml-1 text-neutral-400 dark:text-neutral-500 text-[10px]">
        {statusLabel} {formatTimeAgo(timestamp)}
      </span>
    </div>
  );
}

export default SidebarPullRequestList;
