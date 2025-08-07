import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { OpenWithDropdown } from "@/components/OpenWithDropdown";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import { useClipboard } from "@mantine/hooks";
import { useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import { useQuery as useConvexQuery, useMutation } from "convex/react";
import {
  Archive,
  Check,
  Copy,
  Crown,
  Pin,
} from "lucide-react";
import { memo, useCallback, useMemo } from "react";

interface TaskItemProps {
  task: Doc<"tasks">;
}

export const TaskItem = memo(function TaskItem({ task }: TaskItemProps) {
  const navigate = useNavigate();
  const archiveTask = useMutation(api.tasks.archive);
  const clipboard = useClipboard({ timeout: 2000 });

  // Query for task runs to find VSCode instances
  const taskRunsQuery = useConvexQuery(
    api.taskRuns.getByTask, 
    isFakeConvexId(task._id) ? "skip" : { taskId: task._id }
  );

  // Mutation for toggling keep-alive status
  const toggleKeepAlive = useMutation(api.taskRuns.toggleKeepAlive);
  
  // Derive crowned run from taskRuns
  const crownedRun = useMemo(() => {
    if (!taskRunsQuery) return null;
    
    // Define task run type with nested structure
    interface TaskRunWithChildren extends Doc<"taskRuns"> {
      children?: TaskRunWithChildren[];
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
    
    // Find the crowned run
    return allRuns.find(run => run.isCrowned === true) || null;
  }, [taskRunsQuery]);

  // Find the latest task run with a VSCode instance
  const getLatestVSCodeInstance = useCallback(() => {
    if (!taskRunsQuery || taskRunsQuery.length === 0) return null;

    // Define task run type with nested structure
    interface TaskRunWithChildren extends Doc<"taskRuns"> {
      children?: TaskRunWithChildren[];
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

  const runWithVSCode = useMemo(() => getLatestVSCodeInstance(), [getLatestVSCodeInstance]);
  const hasActiveVSCode = runWithVSCode?.vscode?.status === "running";

  // Generate the VSCode URL if available
  const vscodeUrl = useMemo(() =>
    hasActiveVSCode &&
    runWithVSCode?.vscode?.containerName &&
    runWithVSCode?.vscode?.ports?.vscode
      ? `http://${runWithVSCode._id.substring(0, 12)}.39378.localhost:9776/`
      : null,
    [hasActiveVSCode, runWithVSCode]
  );

  const handleClick = useCallback(() => {
    navigate({
      to: "/task/$taskId",
      params: { taskId: task._id },
    });
  }, [navigate, task._id]);

  const handleCopy = useCallback((e: React.MouseEvent) => {
    e.stopPropagation();
    clipboard.copy(task.text);
  }, [clipboard, task.text]);

  const handleToggleKeepAlive = useCallback(async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (runWithVSCode) {
      await toggleKeepAlive({
        id: runWithVSCode._id,
        keepAlive: !runWithVSCode.vscode?.keepAlive,
      });
    }
  }, [runWithVSCode, toggleKeepAlive]);

  const handleArchive = useCallback((e: React.MouseEvent) => {
    e.stopPropagation();
    archiveTask({ id: task._id });
  }, [archiveTask, task._id]);

  const isOptimisticUpdate = task._id.includes("-") && task._id.length === 36;

  return (
    <div
      className={clsx(
        "relative group flex items-center gap-2.5 px-3 py-2 border rounded-lg transition-all cursor-default select-none",
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
        <span className="text-[14px] truncate">
          {task.text}
        </span>
        {crownedRun && (
          <Crown className="w-3.5 h-3.5 text-yellow-500 flex-shrink-0" />
        )}
        {(task.projectFullName || (task.branch && task.branch !== "main")) && (
          <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto mr-0">
            {task.projectFullName && (
              <span>{task.projectFullName.split("/")[1]}</span>
            )}
            {task.projectFullName &&
              task.branch &&
              task.branch !== "main" &&
              "/"}
            {task.branch && task.branch !== "main" && (
              <span>{task.branch}</span>
            )}
          </span>
        )}
      </div>
      {task.updatedAt && (
        <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto mr-0">
          {new Date(task.updatedAt).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          })}
        </span>
      )}

      <div className="right-2 absolute flex gap-1 group-hover:opacity-100 opacity-0">
        {/* Copy button */}
        <TooltipProvider>
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={handleCopy}
                className={clsx(
                  "p-1 rounded",
                  "bg-neutral-100 dark:bg-neutral-700",
                  "text-neutral-600 dark:text-neutral-400",
                  "hover:bg-neutral-200 dark:hover:bg-neutral-600"
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
        </TooltipProvider>

        {/* Open with dropdown - always appears on hover */}
        <OpenWithDropdown 
          vscodeUrl={vscodeUrl}
          worktreePath={runWithVSCode?.worktreePath || task.worktreePath}
        />

        {/* Keep-alive button */}
        {runWithVSCode && hasActiveVSCode && (
          <TooltipProvider>
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
                    "hover:bg-neutral-200 dark:hover:bg-neutral-600"
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
          </TooltipProvider>
        )}

        {/* Archive button */}
        <button
          onClick={handleArchive}
          className={clsx(
            "p-1 rounded",
            "bg-neutral-100 dark:bg-neutral-700",
            "text-neutral-600 dark:text-neutral-400",
            "hover:bg-neutral-200 dark:hover:bg-neutral-600"
          )}
          title="Archive task"
        >
          <Archive className="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
  );
});