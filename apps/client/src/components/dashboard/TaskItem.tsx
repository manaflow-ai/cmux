import { OpenWithDropdown } from "@/components/OpenWithDropdown";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useArchiveTask } from "@/hooks/useArchiveTask";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import type { RunEnvironmentSummary } from "@/types/task";
import { useClipboard } from "@mantine/hooks";
import { useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import { useQuery as useConvexQuery, useMutation } from "convex/react";
// Read team slug from path to avoid route type coupling
import { Archive, ArchiveRestore, Check, Copy, Pin } from "lucide-react";
import { memo, useCallback, useMemo } from "react";

interface TaskItemProps {
  task: Doc<"tasks">;
  teamSlugOrId: string;
}

export const TaskItem = memo(function TaskItem({
  task,
  teamSlugOrId,
}: TaskItemProps) {
  const navigate = useNavigate();
  const clipboard = useClipboard({ timeout: 2000 });
  const { archiveWithUndo, unarchive } = useArchiveTask(teamSlugOrId);

  // Query for task runs to find VSCode instances
  const taskRunsQuery = useConvexQuery(
    api.taskRuns.getByTask,
    isFakeConvexId(task._id) ? "skip" : { teamSlugOrId, taskId: task._id }
  );

  // Query for environment if task has environmentId
  const environmentQuery = useConvexQuery(
    api.environments.get,
    task.environmentId ? { teamSlugOrId, id: task.environmentId } : "skip"
  );

  // Mutation for toggling keep-alive status
  const toggleKeepAlive = useMutation(api.taskRuns.toggleKeepAlive);

  // Find the latest task run with a VSCode instance
  const getLatestVSCodeInstance = useCallback(() => {
    if (!taskRunsQuery || taskRunsQuery.length === 0) return null;

    // Define task run type with nested structure
    interface TaskRunWithChildren extends Doc<"taskRuns"> {
      children?: TaskRunWithChildren[];
      environment?: RunEnvironmentSummary | null;
    }

    // Flatten all task runs (including children)
    const allRuns: TaskRunWithChildren[] = [];
    const flattenRuns = (runs: TaskRunWithChildren[]) => {
      runs.forEach((run) => {
        allRuns.push(run);
        if (run.children) {
          flattenRuns(run.children);
        }
      });
    };
    flattenRuns(taskRunsQuery);

    // Find the most recent run with VSCode instance that's running or starting
    const runWithVSCode = allRuns
      .filter(
        (run) =>
          run.vscode &&
          (run.vscode.status === "running" || run.vscode.status === "starting")
      )
      .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0))[0];

    return runWithVSCode;
  }, [taskRunsQuery]);

  const runWithVSCode = useMemo(
    () => getLatestVSCodeInstance(),
    [getLatestVSCodeInstance]
  );
  const hasActiveVSCode = runWithVSCode?.vscode?.status === "running";

  // Generate the VSCode URL if available
  const vscodeUrl = useMemo(() => {
    if (hasActiveVSCode && runWithVSCode?.vscode?.workspaceUrl) {
      return runWithVSCode.vscode.workspaceUrl;
    }
    return null;
  }, [hasActiveVSCode, runWithVSCode]);

  const handleClick = useCallback(() => {
    navigate({
      to: "/$teamSlugOrId/task/$taskId",
      params: { teamSlugOrId, taskId: task._id },
      search: { runId: undefined },
    });
  }, [navigate, task._id, teamSlugOrId]);

  const handleCopy = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      clipboard.copy(task.text);
    },
    [clipboard, task.text]
  );

  const handleCopyFromMenu = useCallback(() => {
    clipboard.copy(task.text);
  }, [clipboard, task.text]);

  const handleToggleKeepAlive = useCallback(
    async (e: React.MouseEvent) => {
      e.stopPropagation();
      if (runWithVSCode) {
        await toggleKeepAlive({
          teamSlugOrId,
          id: runWithVSCode._id,
          keepAlive: !runWithVSCode.vscode?.keepAlive,
        });
      }
    },
    [runWithVSCode, teamSlugOrId, toggleKeepAlive]
  );

  const handleArchive = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      archiveWithUndo(task);
    },
    [archiveWithUndo, task]
  );

  const handleArchiveFromMenu = useCallback(() => {
    archiveWithUndo(task);
  }, [archiveWithUndo, task]);

  const handleUnarchiveFromMenu = useCallback(() => {
    unarchive(task._id);
  }, [unarchive, task._id]);

  const handleUnarchive = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      unarchive(task._id);
    },
    [unarchive, task._id]
  );

  const isOptimisticUpdate = task._id.includes("-") && task._id.length === 36;

  return (
    <div className="relative group">
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <div
            className={clsx(
              "relative flex items-center gap-2.5 px-3 py-2 border rounded-lg transition-all cursor-default select-none",
              isOptimisticUpdate
                ? "bg-white/50 dark:bg-neutral-700/30 border-neutral-200 dark:border-neutral-500/15 animate-pulse"
                : "bg-white dark:bg-neutral-700/50 border-neutral-200 dark:border-neutral-500/15 hover:border-neutral-300 dark:hover:border-neutral-500/30"
            )}
            onClick={handleClick}
          >
            <div
              className={clsx(
                "w-1.5 h-1.5 rounded-full flex-shrink-0",
                task.isCompleted
                  ? "bg-green-500"
                  : isOptimisticUpdate
                    ? "bg-yellow-500"
                    : "bg-blue-500 animate-pulse"
              )}
            />
            <div className="flex-1 min-w-0 flex items-center gap-2">
              <span className="text-[14px] truncate min-w-0">{task.text}</span>
              {(environmentQuery ||
                task.projectFullName ||
                (task.baseBranch && task.baseBranch !== "main")) && (
                <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto mr-0">
                  {environmentQuery ? (
                    <span>{environmentQuery.name}</span>
                  ) : task.projectFullName ? (
                    <span>{task.projectFullName.split("/")[1]}</span>
                  ) : null}
                  {task.projectFullName &&
                    task.baseBranch &&
                    task.baseBranch !== "main" &&
                    "/"}
                  {task.baseBranch && task.baseBranch !== "main" && (
                    <span>{task.baseBranch}</span>
                  )}
                </span>
              )}
            </div>
            {task.updatedAt && (
              <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto mr-0 tabular-nums">
                {new Date(task.updatedAt).toLocaleTimeString([], {
                  hour: "2-digit",
                  minute: "2-digit",
                })}
              </span>
            )}
          </div>
        </ContextMenu.Trigger>
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
            <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={handleCopyFromMenu}
              >
                <Copy className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                <span>Copy Description</span>
              </ContextMenu.Item>
              {task.isArchived ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleUnarchiveFromMenu}
                >
                  <ArchiveRestore className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Unarchive Task</span>
                </ContextMenu.Item>
              ) : (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleArchiveFromMenu}
                >
                  <Archive className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Archive Task</span>
                </ContextMenu.Item>
              )}
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>
      <div className="right-2 top-0 bottom-0 absolute py-2">
        <div className="flex gap-1">
          {/* Copy button */}
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={handleCopy}
                className={clsx(
                  "p-1 rounded",
                  "bg-neutral-100 dark:bg-neutral-700",
                  "text-neutral-600 dark:text-neutral-400",
                  "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                  "group-hover:opacity-100 opacity-0"
                )}
                title="Copy task description"
              >
                {clipboard.copied ? (
                  <Check className="w-3.5 h-3.5" />
                ) : (
                  <Copy className="w-3.5 h-3.5" />
                )}
              </button>
            </TooltipTrigger>
            <TooltipContent side="top">
              {clipboard.copied ? "Copied!" : "Copy description"}
            </TooltipContent>
          </Tooltip>

          {/* Open with dropdown - always appears on hover */}
          <OpenWithDropdown
            vscodeUrl={vscodeUrl}
            worktreePath={runWithVSCode?.worktreePath || task.worktreePath}
            branch={task.baseBranch}
            className="group-hover:opacity-100 aria-expanded:opacity-100 opacity-0"
          />

          {/* Keep-alive button */}
          {runWithVSCode && hasActiveVSCode && (
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  onClick={handleToggleKeepAlive}
                  className={clsx(
                    "p-1 rounded",
                    "bg-neutral-100 dark:bg-neutral-700",
                    runWithVSCode.vscode?.keepAlive
                      ? "text-blue-600 dark:text-blue-400"
                      : "text-neutral-600 dark:text-neutral-400",
                    "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                    "group-hover:opacity-100 opacity-0",
                    "hidden" // TODO: show this button
                  )}
                >
                  <Pin className="w-3.5 h-3.5" />
                </button>
              </TooltipTrigger>
              <TooltipContent side="top">
                {runWithVSCode.vscode?.keepAlive
                  ? "Container will stay running"
                  : "Keep container running"}
              </TooltipContent>
            </Tooltip>
          )}

          {/* Archive / Unarchive button with tooltip */}
          <Tooltip>
            <TooltipTrigger asChild>
              {task.isArchived ? (
                <button
                  onClick={handleUnarchive}
                  className={clsx(
                    "p-1 rounded",
                    "bg-neutral-100 dark:bg-neutral-700",
                    "text-neutral-600 dark:text-neutral-400",
                    "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                    "group-hover:opacity-100 opacity-0"
                  )}
                  title="Unarchive task"
                >
                  <ArchiveRestore className="w-3.5 h-3.5" />
                </button>
              ) : (
                <button
                  onClick={handleArchive}
                  className={clsx(
                    "p-1 rounded",
                    "bg-neutral-100 dark:bg-neutral-700",
                    "text-neutral-600 dark:text-neutral-400",
                    "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                    "group-hover:opacity-100 opacity-0"
                  )}
                  title="Archive task"
                >
                  <Archive className="w-3.5 h-3.5" />
                </button>
              )}
            </TooltipTrigger>
            <TooltipContent side="top">
              {task.isArchived ? "Unarchive task" : "Archive task"}
            </TooltipContent>
          </Tooltip>
        </div>
      </div>
    </div>
  );
});
