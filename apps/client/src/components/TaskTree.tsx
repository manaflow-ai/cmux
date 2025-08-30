import { OpenWithDropdown } from "@/components/OpenWithDropdown";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useArchiveTask } from "@/hooks/useArchiveTask";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { type Doc, type Id } from "@cmux/convex/dataModel";
import { Link, useLocation } from "@tanstack/react-router";
import clsx from "clsx";
import {
  Archive as ArchiveIcon,
  ArchiveRestore as ArchiveRestoreIcon,
  CheckCircle,
  ChevronRight,
  Circle,
  Copy as CopyIcon,
  Crown,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  Loader2,
  XCircle,
} from "lucide-react";
import { memo, useCallback, useMemo, useState } from "react";

interface TaskRunWithChildren extends Doc<"taskRuns"> {
  children: TaskRunWithChildren[];
}

export interface TaskWithRuns extends Doc<"tasks"> {
  runs: TaskRunWithChildren[];
}

interface TaskTreeProps {
  task: TaskWithRuns;
  level?: number;
  // When true, expand the task node on initial mount
  defaultExpanded?: boolean;
  teamSlugOrId: string;
}

// Extract the display text logic to avoid re-creating it on every render
function getRunDisplayText(run: TaskRunWithChildren): string {
  if (run.summary) {
    return run.summary;
  }

  // Extract agent name from prompt if it exists
  const agentMatch = run.prompt.match(/\(([^)]+)\)$/);
  const agentName = agentMatch ? agentMatch[1] : null;

  if (agentName) {
    return agentName;
  }

  return run.prompt.substring(0, 50) + "...";
}

function TaskTreeInner({
  task,
  level = 0,
  defaultExpanded = false,
  teamSlugOrId,
}: TaskTreeProps) {
  // Get the current route to determine if this task is selected
  const location = useLocation();
  const isTaskSelected = useMemo(
    () => location.pathname.includes(`/task/${task._id}`),
    [location.pathname, task._id]
  );

  // Default to collapsed unless this task is selected or flagged to expand
  const [isExpanded, setIsExpanded] = useState<boolean>(
    isTaskSelected || defaultExpanded
  );
  const hasRuns = task.runs && task.runs.length > 0;

  // Memoize the toggle handler
  const handleToggle = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsExpanded((prev) => !prev);
  }, []);

  const { archiveWithUndo, unarchive } = useArchiveTask(teamSlugOrId);

  const handleCopyDescription = useCallback(() => {
    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(task.text).catch(() => {});
    }
  }, [task.text]);

  const handleArchive = useCallback(() => {
    archiveWithUndo(task);
  }, [archiveWithUndo, task]);

  const handleUnarchive = useCallback(() => {
    unarchive(task._id);
  }, [unarchive, task._id]);

  return (
    <div className="select-none flex flex-col">
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <Link
            to="/$teamSlugOrId/task/$taskId"
            params={{ teamSlugOrId, taskId: task._id }}
            search={{ runId: undefined }}
            className={clsx(
              "flex items-center px-0.5 pt-[2.5px] pb-[3px] text-sm rounded-md hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-default",
              "[&.active]:bg-neutral-100 dark:[&.active]:bg-neutral-800"
            )}
            style={{ paddingLeft: `${4 + level * 16}px` }}
          >
            <button
              onClick={handleToggle}
              className={clsx(
                "size-4.5 mr-1.5 hover:bg-neutral-200 dark:hover:bg-neutral-700 rounded-[5px] grid place-content-center cursor-default",
                !hasRuns && "invisible"
              )}
              style={{ WebkitAppRegion: "no-drag" } as React.CSSProperties}
            >
              <ChevronRight
                className={clsx(
                  "w-3 h-3 transition-transform",
                  isExpanded && "rotate-90"
                )}
              />
            </button>

            <div className="mr-2 flex-shrink-0">
              {(() => {
                // Show merge status icon if PR activity exists
                if (task.mergeStatus && task.mergeStatus !== "none") {
                  switch (task.mergeStatus) {
                    case "pr_draft":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />
                          </TooltipTrigger>
                          <TooltipContent side="right">Draft PR</TooltipContent>
                        </Tooltip>
                      );
                    case "pr_open":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
                          </TooltipTrigger>
                          <TooltipContent side="right">PR Open</TooltipContent>
                        </Tooltip>
                      );
                    case "pr_approved":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
                          </TooltipTrigger>
                          <TooltipContent side="right">
                            PR Approved
                          </TooltipContent>
                        </Tooltip>
                      );
                    case "pr_changes_requested":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitPullRequest className="w-3 h-3 text-yellow-500" />
                          </TooltipTrigger>
                          <TooltipContent side="right">
                            Changes Requested
                          </TooltipContent>
                        </Tooltip>
                      );
                    case "pr_merged":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitMerge className="w-3 h-3 text-purple-500" />
                          </TooltipTrigger>
                          <TooltipContent side="right">Merged</TooltipContent>
                        </Tooltip>
                      );
                    case "pr_closed":
                      return (
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <GitPullRequestClosed className="w-3 h-3 text-red-500" />
                          </TooltipTrigger>
                          <TooltipContent side="right">
                            PR Closed
                          </TooltipContent>
                        </Tooltip>
                      );
                    default:
                      return null;
                  }
                }
                // Fallback to completion status if no merge status
                return task.isCompleted ? (
                  <CheckCircle className="w-3 h-3 text-green-500" />
                ) : (
                  <Circle className="w-3 h-3 text-neutral-400 animate-pulse" />
                );
              })()}
            </div>

            <div className="flex-1 min-w-0">
              <p className="truncate text-neutral-900 dark:text-neutral-100 text-[13px]">
                {task.pullRequestTitle || task.text}
              </p>
            </div>
          </Link>
        </ContextMenu.Trigger>
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="outline-none z-[10000]">
            <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={handleCopyDescription}
              >
                <CopyIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                <span>Copy Description</span>
              </ContextMenu.Item>
              {task.isArchived ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleUnarchive}
                >
                  <ArchiveRestoreIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Unarchive Task</span>
                </ContextMenu.Item>
              ) : (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleArchive}
                >
                  <ArchiveIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Archive Task</span>
                </ContextMenu.Item>
              )}
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>

      {isExpanded && hasRuns && (
        <div className="flex flex-col">
          {task.runs.map((run) => (
            <TaskRunTree
              key={run._id}
              run={run}
              level={level + 1}
              taskId={task._id}
              branch={task.baseBranch}
              teamSlugOrId={teamSlugOrId}
            />
          ))}
        </div>
      )}
    </div>
  );
}

interface TaskRunTreeProps {
  run: TaskRunWithChildren;
  level: number;
  taskId: Id<"tasks">;
  branch?: string;
  teamSlugOrId: string;
}

function TaskRunTreeInner({ run, level, taskId, branch, teamSlugOrId }: TaskRunTreeProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const hasChildren = run.children.length > 0;

  // Memoize the display text to avoid recalculating on every render
  const displayText = useMemo(() => getRunDisplayText(run), [run]);

  // Memoize the toggle handler
  const handleToggle = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsExpanded((prev) => !prev);
  }, []);

  const statusIcon = {
    pending: <Circle className="w-3 h-3 text-neutral-400" />,
    running: <Loader2 className="w-3 h-3 text-blue-500 animate-spin" />,
    completed: <CheckCircle className="w-3 h-3 text-green-500" />,
    failed: <XCircle className="w-3 h-3 text-red-500" />,
  }[run.status];

  // Generate VSCode URL if available
  const hasActiveVSCode = run.vscode?.status === "running";
  const vscodeUrl = useMemo(
    () => (hasActiveVSCode && run.vscode?.url) || null,
    [hasActiveVSCode, run]
  );

  return (
    <div className="mt-px relative group">
      {/* Crown icon shown before status icon, with tooltip */}
      {run.isCrowned && (
        <div className="flex-shrink-0 absolute left-0 pt-[5.5px] pl-[26px]">
          <Tooltip>
            <TooltipTrigger asChild>
              <Crown className="w-3 h-3 text-yellow-500" />
            </TooltipTrigger>
            {run.crownReason && (
              <TooltipContent
                side="right"
                sideOffset={6}
                className="max-w-sm p-3 z-[9999]"
              >
                <div className="space-y-1.5">
                  <p className="font-medium text-sm">Evaluation Reason</p>
                  <p className="text-xs text-muted-foreground">
                    {run.crownReason}
                  </p>
                </div>
              </TooltipContent>
            )}
          </Tooltip>
        </div>
      )}
      <Link
        to="/$teamSlugOrId/task/$taskId/run/$taskRunId"
        params={{ teamSlugOrId, taskId, taskRunId: run._id }}
        className={clsx(
          "group flex items-center px-2 pr-10 py-1 text-xs rounded-md hover:bg-neutral-100 dark:hover:bg-neutral-800 cursor-default",
          "[&.active]:bg-neutral-100 dark:[&.active]:bg-neutral-800"
        )}
        style={{ paddingLeft: `${8 + level * 16}px` }}
      >
        <button
          onClick={handleToggle}
          className={clsx(
            "w-4 h-4 mr-1.5 hover:bg-neutral-200 dark:hover:bg-neutral-700 rounded cursor-default",
            !hasChildren && "invisible"
          )}
          style={{ WebkitAppRegion: "no-drag" } as React.CSSProperties}
        >
          <ChevronRight
            className={clsx(
              "w-3 h-3 transition-transform",
              isExpanded && "rotate-90"
            )}
          />
        </button>

        {run.status === "failed" && run.errorMessage ? (
          <Tooltip>
            <TooltipTrigger asChild>
              <div className="mr-2 flex-shrink-0">{statusIcon}</div>
            </TooltipTrigger>
            <TooltipContent
              side="right"
              className="max-w-xs whitespace-pre-wrap break-words"
            >
              {run.errorMessage}
            </TooltipContent>
          </Tooltip>
        ) : (
          <div className="mr-2 flex-shrink-0">{statusIcon}</div>
        )}

        <div className="flex-1 min-w-0 flex items-center gap-1">
          <span className="truncate text-neutral-700 dark:text-neutral-300">
            {displayText}
          </span>
        </div>
      </Link>

      <div className="absolute right-2 top-1/2 -translate-y-1/2">
        <OpenWithDropdown
          vscodeUrl={vscodeUrl}
          worktreePath={run.worktreePath}
          branch={run.newBranch}
          networking={run.networking}
          className="bg-neutral-100/80 dark:bg-neutral-700/80 hover:bg-neutral-200/80 dark:hover:bg-neutral-600/80 text-neutral-600 dark:text-neutral-400"
          iconClassName="w-2.5 h-2.5"
        />
      </div>

      {isExpanded && hasChildren && (
        <div className="flex flex-col">
          {run.children.map((childRun) => (
            <TaskRunTree
              key={childRun._id}
              run={childRun}
              level={level + 1}
              taskId={taskId}
              branch={branch}
              teamSlugOrId={teamSlugOrId}
            />
          ))}
        </div>
      )}
    </div>
  );
}

// Prevent unnecessary re-renders of large trees during unrelated state changes
export const TaskTree = memo(TaskTreeInner);
const TaskRunTree = memo(TaskRunTreeInner);
