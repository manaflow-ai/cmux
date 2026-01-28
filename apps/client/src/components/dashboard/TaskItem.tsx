import { OpenWithDropdown } from "@/components/OpenWithDropdown";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useArchiveTask } from "@/hooks/useArchiveTask";
import { useTaskRename } from "@/hooks/useTaskRename";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import type { RunEnvironmentSummary } from "@/types/task";
import { useClipboard } from "@mantine/hooks";
import { Link, useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import { useQuery as useConvexQuery, useMutation } from "convex/react";
// Read team slug from path to avoid route type coupling
import {
  Archive,
  ArchiveRestore,
  Box,
  Check,
  Copy,
  GitMerge,
  Loader2,
  Pencil,
  Pin,
  PinOff,
} from "lucide-react";
import { memo, useCallback, useMemo } from "react";
import { EnvironmentName } from "./EnvironmentName";

interface TaskItemProps {
  task: Doc<"tasks">;
  teamSlugOrId: string;
}

export const TaskItem = memo(function TaskItem({
  task,
  teamSlugOrId,
}: TaskItemProps) {
  const clipboard = useClipboard({ timeout: 2000 });
  const { archiveWithUndo, unarchive, isArchiving } =
    useArchiveTask(teamSlugOrId);
  const taskIsArchiving = isArchiving(task._id);
  const navigate = useNavigate();
  const isOptimisticUpdate = task._id.includes("-") && task._id.length === 36;
  const canRename = !isOptimisticUpdate;

  const {
    isRenaming,
    renameValue,
    renameError,
    isRenamePending,
    renameInputRef,
    handleRenameChange,
    handleRenameKeyDown,
    handleRenameBlur,
    handleRenameFocus,
    handleStartRenaming,
  } = useTaskRename({
    taskId: task._id,
    teamSlugOrId,
    currentText: task.text,
    canRename,
  });

  // Query for task runs to find VSCode instances
  const taskRunsQuery = useConvexQuery(
    api.taskRuns.getByTask,
    isFakeConvexId(task._id) ? "skip" : { teamSlugOrId, taskId: task._id }
  );

  // Check if task has a crown based on crownEvaluationStatus
  const hasCrown = task.crownEvaluationStatus === "succeeded";

  // Mutation for toggling keep-alive status
  const toggleKeepAlive = useMutation(api.taskRuns.toggleKeepAlive);

  // Mutations for pinning/unpinning tasks with optimistic updates
  const pinTask = useMutation(api.tasks.pin).withOptimisticUpdate(
    (localStore, args) => {
      const now = Date.now();

      // Update the task in the main task list
      const tasks = localStore.getQuery(api.tasks.get, { teamSlugOrId: args.teamSlugOrId });
      if (tasks) {
        const updatedTasks = tasks.map(t =>
          t._id === args.id ? { ...t, pinned: true, updatedAt: now, hasUnread: t.hasUnread ?? false } : t
        );
        localStore.setQuery(api.tasks.get, { teamSlugOrId: args.teamSlugOrId }, updatedTasks);
      }

      // Update the pinned items query
      const pinned = localStore.getQuery(api.tasks.getPinned, { teamSlugOrId: args.teamSlugOrId }) || [];
      const taskToPin = tasks?.find(t => t._id === args.id);
      if (taskToPin) {
        // Insert at the beginning since it's the most recently updated
        localStore.setQuery(api.tasks.getPinned, { teamSlugOrId: args.teamSlugOrId },
          [{ ...taskToPin, pinned: true, updatedAt: now, hasUnread: taskToPin.hasUnread ?? false }, ...pinned]
        );
      }
    }
  );

  const unpinTask = useMutation(api.tasks.unpin).withOptimisticUpdate(
    (localStore, args) => {
      const now = Date.now();

      // Update the task in the main task list
      const tasks = localStore.getQuery(api.tasks.get, { teamSlugOrId: args.teamSlugOrId });
      if (tasks) {
        const updatedTasks = tasks.map(t =>
          t._id === args.id ? { ...t, pinned: false, updatedAt: now } : t
        );
        localStore.setQuery(api.tasks.get, { teamSlugOrId: args.teamSlugOrId }, updatedTasks);
      }

      // Update the pinned items query
      const pinned = localStore.getQuery(api.tasks.getPinned, { teamSlugOrId: args.teamSlugOrId }) || [];
      localStore.setQuery(api.tasks.getPinned, { teamSlugOrId: args.teamSlugOrId },
        pinned.filter(t => t._id !== args.id)
      );
    }
  );

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

  // Generate the VSCode URL if available (use base URL, not workspaceUrl)
  const vscodeUrl = useMemo(() => {
    if (hasActiveVSCode && runWithVSCode?.vscode?.url) {
      return runWithVSCode.vscode.url;
    }
    return null;
  }, [hasActiveVSCode, runWithVSCode]);
  const vscodeProvider = runWithVSCode?.vscode?.provider;

  // For local workspaces, find the run with VSCode to navigate to VSCode view directly
  const localWorkspaceRunWithVscode = useMemo(() => {
    if (!task.isLocalWorkspace) {
      return null;
    }
    if (!hasActiveVSCode || !runWithVSCode) {
      return null;
    }
    return runWithVSCode;
  }, [task.isLocalWorkspace, hasActiveVSCode, runWithVSCode]);

  const handleLinkClick = useCallback(
    (event: React.MouseEvent<HTMLAnchorElement>) => {
      // Don't navigate if we're renaming
      if (isRenaming || event.defaultPrevented) {
        event.preventDefault();
        return;
      }
      // Let browser handle modifier key clicks (cmd+click for new tab, etc.)
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
        return;
      }
      // For local workspaces with active VSCode, navigate to VSCode view directly
      if (localWorkspaceRunWithVscode) {
        event.preventDefault();
        void navigate({
          to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
          params: {
            teamSlugOrId,
            taskId: task._id,
            runId: localWorkspaceRunWithVscode._id,
          },
        });
        return;
      }
    },
    [isRenaming, localWorkspaceRunWithVscode, navigate, teamSlugOrId, task._id]
  );

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

  const handlePinFromMenu = useCallback(() => {
    pinTask({
      teamSlugOrId,
      id: task._id,
    });
  }, [pinTask, teamSlugOrId, task._id]);

  const handleUnpinFromMenu = useCallback(() => {
    unpinTask({
      teamSlugOrId,
      id: task._id,
    });
  }, [unpinTask, teamSlugOrId, task._id]);

  return (
    <div className="relative group w-full">
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <Link
            to="/$teamSlugOrId/task/$taskId"
            params={{ teamSlugOrId, taskId: task._id }}
            search={{ runId: undefined }}
            onClick={handleLinkClick}
            className={clsx(
              "relative grid w-full items-center py-2 pr-3 cursor-default select-none group",
              "grid-cols-[24px_36px_1fr_minmax(120px,auto)_58px]",
              isOptimisticUpdate
                ? "bg-white/50 dark:bg-neutral-900/30 animate-pulse"
                : "bg-white dark:bg-neutral-900/50 group-hover:bg-neutral-50/90 dark:group-hover:bg-neutral-600/60",
              isRenaming && "pr-2"
            )}
          >
            <div className="flex items-center justify-center pl-1 -mr-2 relative">
              <input
                type="checkbox"
                className="peer w-3 h-3 cursor-pointer border border-neutral-400 dark:border-neutral-500 rounded bg-white dark:bg-neutral-900 appearance-none checked:bg-neutral-500 checked:border-neutral-500 dark:checked:bg-neutral-400 dark:checked:border-neutral-400 invisible"
                onClick={(e) => e.stopPropagation()}
                onChange={() => {
                  // TODO: Implement checkbox functionality
                }}
              />
              <Check
                className="absolute w-2.5 h-2.5 text-white pointer-events-none transition-opacity peer-checked:opacity-100 opacity-0"
                style={{
                  left: "57%",
                  top: "50%",
                  transform: "translate(-50%, -50%)",
                }}
              />
            </div>
            <div className="flex items-center justify-center">
              {task.mergeStatus === "pr_merged" ? (
                <GitMerge className="w-3.5 h-3.5 text-purple-500 dark:text-purple-400 flex-shrink-0" />
              ) : task.isCloudWorkspace || task.isLocalWorkspace ? (
                <Box className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400 flex-shrink-0" />
              ) : (
                <div
                  className={clsx(
                    "rounded-full flex-shrink-0",
                    hasCrown
                      ? "w-[8px] h-[8px] border border-transparent bg-green-500"
                      : "w-[9.5px] h-[9.5px] border border-neutral-400 dark:border-neutral-500 bg-transparent"
                  )}
                />
              )}
            </div>
            <div className="min-w-0 flex items-center">
              {isRenaming ? (
                <input
                  ref={renameInputRef}
                  type="text"
                  value={renameValue}
                  onChange={handleRenameChange}
                  onKeyDown={handleRenameKeyDown}
                  onBlur={handleRenameBlur}
                  disabled={isRenamePending}
                  autoFocus
                  onFocus={handleRenameFocus}
                  placeholder="Task name"
                  aria-label="Task name"
                  aria-invalid={renameError ? true : undefined}
                  autoComplete="off"
                  spellCheck={false}
                  data-cmux-inline-editing="true"
                  className={clsx(
                    "inline-flex w-full items-center bg-transparent text-[13px] font-medium text-neutral-900 caret-neutral-600 transition-colors duration-200 pr-1",
                    "px-0 py-0 align-middle",
                    "placeholder:text-neutral-400 outline-none border-none focus-visible:outline-none focus-visible:ring-0 appearance-none",
                    "dark:text-neutral-100 dark:caret-neutral-200 dark:placeholder:text-neutral-500",
                    isRenamePending &&
                      "text-neutral-400/70 dark:text-neutral-500/70 cursor-wait"
                  )}
                />
              ) : (
                <span className="text-[13px] font-medium truncate min-w-0 pr-1">
                  {task.text}
                </span>
              )}
            </div>
            <div className="text-[11px] text-neutral-400 dark:text-neutral-500 min-w-0 text-right flex items-center justify-end gap-2">
              {task.environmentId && (
                <EnvironmentName
                  environmentId={task.environmentId}
                  teamSlugOrId={teamSlugOrId}
                />
              )}
              {(task.projectFullName ||
                (task.baseBranch && task.baseBranch !== "main")) && (
                <span>
                  {task.projectFullName && (
                    <span>{task.projectFullName.split("/")[1]}</span>
                  )}
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
            <div className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 tabular-nums text-right">
              {task.updatedAt &&
                (() => {
                  const date = new Date(task.updatedAt);
                  const today = new Date();
                  const isToday =
                    date.getDate() === today.getDate() &&
                    date.getMonth() === today.getMonth() &&
                    date.getFullYear() === today.getFullYear();

                  return (
                    <span>
                      {isToday
                        ? date.toLocaleTimeString([], {
                            hour: "numeric",
                            minute: "2-digit",
                          })
                        : date.toLocaleDateString([], {
                            month: "short",
                            day: "numeric",
                          })}
                    </span>
                  );
                })()}
            </div>
          </Link>
        </ContextMenu.Trigger>
        {renameError && (
          <div className="mt-1 pl-[76px] pr-3 text-[11px] text-red-500 dark:text-red-400">
            {renameError}
          </div>
        )}
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
            <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={handleCopyFromMenu}
              >
                <Copy className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                <span>Copy description</span>
              </ContextMenu.Item>
              {canRename ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleStartRenaming}
                >
                  <Pencil className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Rename</span>
                </ContextMenu.Item>
              ) : null}
              {task.pinned ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleUnpinFromMenu}
                >
                  <PinOff className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Unpin</span>
                </ContextMenu.Item>
              ) : (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handlePinFromMenu}
                >
                  <Pin className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Pin</span>
                </ContextMenu.Item>
              )}
              {task.isArchived ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleUnarchiveFromMenu}
                >
                  <ArchiveRestore className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Unarchive</span>
                </ContextMenu.Item>
              ) : (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleArchiveFromMenu}
                >
                  <Archive className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Archive</span>
                </ContextMenu.Item>
              )}
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>
      <div className="right-2 top-0 bottom-0 absolute py-2 group">
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
            vscodeProvider={vscodeProvider}
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
                  disabled={taskIsArchiving}
                  className={clsx(
                    "p-1 rounded",
                    "bg-neutral-100 dark:bg-neutral-700",
                    "text-neutral-600 dark:text-neutral-400",
                    "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                    taskIsArchiving
                      ? "opacity-100"
                      : "group-hover:opacity-100 opacity-0",
                    taskIsArchiving && "cursor-not-allowed"
                  )}
                  title="Archive task"
                >
                  {taskIsArchiving ? (
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  ) : (
                    <Archive className="w-3.5 h-3.5" />
                  )}
                </button>
              )}
            </TooltipTrigger>
            <TooltipContent side="top">
              {taskIsArchiving
                ? "Archiving..."
                : task.isArchived
                  ? "Unarchive task"
                  : "Archive task"}
            </TooltipContent>
          </Tooltip>
        </div>
      </div>
    </div>
  );
});
