import { OpenWithDropdown } from "@/components/OpenWithDropdown";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { getTaskRunDisplayText } from "@/lib/getTaskRunDisplayText";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { useClipboard } from "@mantine/hooks";
import { useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import { useMutation } from "convex/react";
import { memo, useCallback, useMemo } from "react";
import { Check, Copy, Pin, PinOff } from "lucide-react";

interface PinnedTaskRunItemProps {
  teamSlugOrId: string;
  task: Doc<"tasks">;
  run: Doc<"taskRuns">;
}

export const PinnedTaskRunItem = memo(function PinnedTaskRunItem({
  teamSlugOrId,
  task,
  run,
}: PinnedTaskRunItemProps) {
  const navigate = useNavigate();
  const clipboard = useClipboard({ timeout: 2000 });
  const setPinned = useMutation(api.taskRuns.setPinned);

  const displayText = useMemo(
    () => getTaskRunDisplayText(run),
    [run.agentName, run.summary, run.prompt]
  );
  const copyText = run.summary && run.summary.trim().length > 0 ? run.summary : run.prompt;

  const statusClass =
    run.status === "completed"
      ? "bg-green-500"
      : run.status === "running"
        ? "bg-blue-500 animate-pulse"
        : run.status === "failed"
          ? "bg-red-500"
          : "bg-yellow-500 animate-pulse";

  const updatedAt = run.updatedAt ?? run.createdAt;

  const projectLabel =
    task.projectFullName || (task.baseBranch && task.baseBranch !== "main")
      ? {
          project: task.projectFullName
            ? task.projectFullName.split("/")[1]
            : null,
          branch:
            task.baseBranch && task.baseBranch !== "main"
              ? task.baseBranch
              : null,
        }
      : null;

  const handleNavigate = useCallback(() => {
    navigate({
      to: "/$teamSlugOrId/task/$taskId",
      params: { teamSlugOrId, taskId: task._id },
      search: { runId: run._id },
    });
  }, [navigate, run._id, task._id, teamSlugOrId]);

  const handleCopy = useCallback(
    (event: React.MouseEvent) => {
      event.stopPropagation();
      clipboard.copy(copyText);
    },
    [clipboard, copyText]
  );

  const handleCopyFromMenu = useCallback(() => {
    clipboard.copy(copyText);
  }, [clipboard, copyText]);

  const handleTogglePinned = useCallback(
    (event: React.MouseEvent) => {
      event.stopPropagation();
      void setPinned({
        teamSlugOrId,
        id: run._id,
        isPinned: !run.isPinned,
      });
    },
    [run._id, run.isPinned, setPinned, teamSlugOrId]
  );

  const handleTogglePinnedFromMenu = useCallback(() => {
    void setPinned({
      teamSlugOrId,
      id: run._id,
      isPinned: !run.isPinned,
    });
  }, [run._id, run.isPinned, setPinned, teamSlugOrId]);

  const updatedAtLabel = useMemo(() => {
    if (!updatedAt) return null;
    return new Date(updatedAt).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    });
  }, [updatedAt]);

  return (
    <div className="relative group">
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <div
            className={clsx(
              "relative flex items-center gap-2.5 px-3 py-2 border rounded-lg transition-all cursor-default select-none",
              "bg-white dark:bg-neutral-700/50 border-neutral-200 dark:border-neutral-500/15 hover:border-neutral-300 dark:hover:border-neutral-500/30"
            )}
            onClick={handleNavigate}
          >
            <div
              className={clsx(
                "w-1.5 h-1.5 rounded-full flex-shrink-0",
                statusClass
              )}
            />
            <div className="flex-1 min-w-0 flex flex-col gap-1">
              <div className="flex items-center gap-2 min-w-0">
                <Tooltip delayDuration={0}>
                  <TooltipTrigger asChild>
                    <Pin className="w-3 h-3 text-amber-500 rotate-45 flex-shrink-0" />
                  </TooltipTrigger>
                  <TooltipContent side="top">Pinned run</TooltipContent>
                </Tooltip>
                <span className="text-[14px] truncate min-w-0">
                  {displayText}
                </span>
                {projectLabel ? (
                  <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto">
                    {projectLabel.project && <span>{projectLabel.project}</span>}
                    {projectLabel.project && projectLabel.branch ? "/" : null}
                    {projectLabel.branch && <span>{projectLabel.branch}</span>}
                  </span>
                ) : null}
              </div>
              <span className="text-[11px] text-neutral-500 dark:text-neutral-400 truncate">
                Task: {task.text}
              </span>
            </div>
            {updatedAtLabel ? (
              <span className="text-[11px] text-neutral-400 dark:text-neutral-500 flex-shrink-0 ml-auto tabular-nums">
                {updatedAtLabel}
              </span>
            ) : null}
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
                <span>Copy description</span>
              </ContextMenu.Item>
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={handleTogglePinnedFromMenu}
              >
                {run.isPinned ? (
                  <PinOff className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                ) : (
                  <Pin className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300 rotate-45" />
                )}
                <span>{run.isPinned ? "Unpin run" : "Pin run"}</span>
              </ContextMenu.Item>
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>
      <div className="right-2 top-0 bottom-0 absolute py-2">
        <div className="flex gap-1">
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
                title="Copy run description"
              >
                {clipboard.copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
              </button>
            </TooltipTrigger>
            <TooltipContent side="top">
              {clipboard.copied ? "Copied!" : "Copy description"}
            </TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={handleTogglePinned}
                className={clsx(
                  "p-1 rounded",
                  "bg-neutral-100 dark:bg-neutral-700",
                  "text-neutral-600 dark:text-neutral-400",
                  "hover:bg-neutral-200 dark:hover:bg-neutral-600",
                  "group-hover:opacity-100 opacity-0"
                )}
                title="Unpin run"
              >
                <PinOff className="w-3.5 h-3.5" />
              </button>
            </TooltipTrigger>
            <TooltipContent side="top">Unpin run</TooltipContent>
          </Tooltip>
          <OpenWithDropdown
            vscodeUrl={run.vscode?.workspaceUrl}
            worktreePath={run.worktreePath || task.worktreePath}
            branch={run.newBranch || task.baseBranch}
            networking={run.networking}
            className="group-hover:opacity-100 aria-expanded:opacity-100 opacity-0"
          />
        </div>
      </div>
    </div>
  );
});
