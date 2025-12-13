import { GitHubIcon } from "@/components/icons/github";
import { api } from "@cmux/convex/api";
import { Link, useNavigate } from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import {
  FolderOpen,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
} from "lucide-react";
import { useCallback, useMemo, useState, type MouseEvent } from "react";
import { toast } from "sonner";
import { useSocketSuspense } from "@/contexts/socket/use-socket";
import { SidebarListItem } from "./SidebarListItem";
import { SIDEBAR_PRS_DEFAULT_LIMIT } from "./const";
import type { Doc, Id } from "@cmux/convex/dataModel";

type CreateLocalWorkspaceResponse = {
  success: boolean;
  taskId?: string;
  taskRunId?: string;
  workspaceName?: string;
  workspacePath?: string;
  workspaceUrl?: string;
  pending?: boolean;
  error?: string;
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
      {list.map((pr) => (
        <PullRequestListItem
          key={`${pr.repoFullName}#${pr.number}`}
          pr={pr}
          teamSlugOrId={teamSlugOrId}
          expanded={expanded}
          setExpanded={setExpanded}
        />
      ))}
    </ul>
  );
}

type PullRequestListItemProps = {
  pr: Doc<"pullRequests">;
  teamSlugOrId: string;
  expanded: Record<string, boolean>;
  setExpanded: React.Dispatch<React.SetStateAction<Record<string, boolean>>>;
};

function PullRequestListItem({ pr, teamSlugOrId, expanded, setExpanded }: PullRequestListItemProps) {
  const navigate = useNavigate();
  const { socket } = useSocketSuspense();
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

  const handleOpenLocalWorkspace = useCallback(() => {
    if (!socket) {
      toast.error("Socket not connected");
      return;
    }

    if (!pr.repoFullName) {
      toast.error("No repository information available");
      return;
    }

    if (!pr.headRef) {
      toast.error("No branch information available");
      return;
    }

    const loadingToast = toast.loading("Creating local workspace...");

    socket.emit(
      "create-local-workspace",
      {
        teamSlugOrId,
        projectFullName: pr.repoFullName,
        repoUrl: `https://github.com/${pr.repoFullName}.git`,
        branch: pr.headRef,
      },
      (response: CreateLocalWorkspaceResponse) => {
        if (response.success && response.workspacePath) {
          toast.success("Workspace created successfully!", {
            id: loadingToast,
            description: `Opening workspace at ${response.workspacePath}`,
          });

          // Navigate to the vscode view for this workspace
          if (response.taskRunId && response.taskId) {
            navigate({
              to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
              params: {
                teamSlugOrId,
                taskId: response.taskId as Id<"tasks">,
                runId: response.taskRunId as Id<"taskRuns">,
              },
            });
          }
        } else {
          toast.error(response.error || "Failed to create workspace", {
            id: loadingToast,
          });
        }
      }
    );
  }, [socket, teamSlugOrId, pr.repoFullName, pr.headRef, navigate]);

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
          <button
            onClick={(event) => {
              event.stopPropagation();
              handleOpenLocalWorkspace();
            }}
            className="flex w-full items-center rounded-md pr-2 py-1 text-xs transition-colors hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45"
            style={{ paddingLeft: "32px" }}
            title="Open local workspace from this branch"
          >
            <FolderOpen
              className="mr-2 h-3 w-3 text-neutral-400"
              aria-hidden
            />
            <span className="text-neutral-600 dark:text-neutral-400">
              Open workspace
            </span>
          </button>
          {pr.htmlUrl ? (
            <a
              href={pr.htmlUrl}
              target="_blank"
              rel="noreferrer"
              onClick={(event) => {
                event.stopPropagation();
              }}
              className="flex w-full items-center rounded-md pr-2 py-1 text-xs transition-colors hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45"
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
          ) : null}
        </div>
      ) : null}
    </li>
  );
}

export default SidebarPullRequestList;
