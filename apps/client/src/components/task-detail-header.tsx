import { OpenEditorSplitButton } from "@/components/OpenEditorSplitButton";
import { Dropdown } from "@/components/ui/dropdown";
import { MergeButton, type MergeMethod } from "@/components/ui/merge-button";
import { useSocket } from "@/contexts/socket/use-socket";
import type { Doc } from "@cmux/convex/dataModel";
import { Skeleton } from "@heroui/react";
import { useClipboard } from "@mantine/hooks";
import { useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import {
  Check,
  ChevronDown,
  Copy,
  Crown,
  EllipsisVertical,
  ExternalLink,
  GitBranch,
  GitMerge,
  Trash2,
} from "lucide-react";
import { useCallback, useMemo, useState } from "react";
import { toast } from "sonner";

interface TaskDetailHeaderProps {
  task?: Doc<"tasks"> | null;
  taskRuns?: Doc<"taskRuns">[] | null;
  selectedRun?: Doc<"taskRuns"> | null;
  isCreatingPr: boolean;
  setIsCreatingPr: (v: boolean) => void;
  onMerge: (method: MergeMethod) => Promise<void>;
  totalAdditions?: number;
  totalDeletions?: number;
  hasAnyDiffs?: boolean;
  onExpandAll?: () => void;
  onCollapseAll?: () => void;
  isLoading?: boolean;
}

export function TaskDetailHeader({
  task,
  taskRuns,
  selectedRun,
  isCreatingPr,
  setIsCreatingPr,
  onMerge,
  totalAdditions,
  totalDeletions,
  hasAnyDiffs,
  onExpandAll,
  onCollapseAll,
  isLoading,
}: TaskDetailHeaderProps) {
  const navigate = useNavigate();
  const clipboard = useClipboard({ timeout: 2000 });
  const prIsOpen = selectedRun?.pullRequestState === "open";
  const prIsMerged = selectedRun?.pullRequestState === "merged";
  const { socket } = useSocket();
  const [agentMenuOpen, setAgentMenuOpen] = useState(false);
  const [isOpeningPr, setIsOpeningPr] = useState(false);
  const handleAgentOpenChange = useCallback((open: boolean) => {
    setAgentMenuOpen(open);
  }, []);

  // Determine if there are any diffs to open a PR for
  const hasChanges = useMemo(() => {
    if (typeof hasAnyDiffs === "boolean") return hasAnyDiffs;
    if (
      typeof totalAdditions !== "number" ||
      typeof totalDeletions !== "number"
    ) {
      return false;
    }
    return (totalAdditions || 0) + (totalDeletions || 0) > 0;
  }, [hasAnyDiffs, totalAdditions, totalDeletions]);

  const taskTitle = task?.pullRequestTitle || task?.text;

  const handleCopyBranch = () => {
    if (selectedRun?.newBranch) {
      clipboard.copy(selectedRun.newBranch);
    }
  };

  const [isMerging, setIsMerging] = useState(false);
  const handleMerge = async (method: MergeMethod) => {
    setIsMerging(true);
    try {
      await onMerge(method);
    } finally {
      setIsMerging(false);
    }
  };

  const handleOpenPR = () => {
    if (!socket || !selectedRun?._id) return;
    // Create PR or mark draft ready
    setIsOpeningPr(true);
    const toastId = toast.loading("Opening PR...");
    socket.emit(
      "github-open-pr",
      { taskRunId: selectedRun._id },
      (resp: { success: boolean; url?: string; error?: string }) => {
        setIsOpeningPr(false);
        if (resp.success) {
          toast.success("PR opened", { id: toastId, description: resp.url });
        } else {
          console.error("Failed to open PR:", resp.error);
          toast.error("Failed to open PR", {
            id: toastId,
            description: resp.error,
          });
        }
      }
    );
  };

  const handleViewPR = () => {
    if (!socket || !selectedRun?._id) return;
    if (
      selectedRun.pullRequestUrl &&
      selectedRun.pullRequestUrl !== "pending"
    ) {
      window.open(selectedRun.pullRequestUrl, "_blank");
      return;
    }
    setIsCreatingPr(true);
    socket.emit(
      "github-create-draft-pr",
      { taskRunId: selectedRun._id },
      (resp: { success: boolean; url?: string; error?: string }) => {
        setIsCreatingPr(false);
        if (resp.success && resp.url) {
          window.open(resp.url, "_blank");
        } else if (resp.error) {
          console.error("Failed to create draft PR:", resp.error);
          toast.error("Failed to create draft PR", {
            description: resp.error,
          });
        }
      }
    );
  };

  const worktreePath = useMemo(
    () => selectedRun?.worktreePath || task?.worktreePath || null,
    [selectedRun?.worktreePath, task?.worktreePath]
  );

  return (
    <div className="bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white px-3.5 sticky top-0 z-50 py-2">
      <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 gap-y-1">
        {/* Title row */}
        <div className="col-start-1 row-start-1 flex items-center gap-2 relative min-w-0">
          <h1 className="text-sm font-bold truncate min-w-0" title={taskTitle}>
            {taskTitle || "Loading..."}
          </h1>
          <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
            <span className="text-green-600 dark:text-green-400 font-medium select-none">
              <Skeleton className="rounded min-w-[22px]" isLoaded={!isLoading}>
                +{totalAdditions}
              </Skeleton>
            </span>
            <span className="text-red-600 dark:text-red-400 font-medium select-none">
              <Skeleton className="rounded min-w-[22px]" isLoaded={!isLoading}>
                −{totalDeletions}
              </Skeleton>
            </span>
          </div>
        </div>

        {/* Removed periodic refresh spinner */}

        {/* Actions on right, vertically centered across rows */}
        <div className="col-start-3 row-start-1 row-span-2 self-center flex items-center gap-2 shrink-0">
          {prIsMerged ? (
            <div
              className="flex items-center gap-1.5 px-3 py-1 bg-[#8250df] text-white rounded font-medium text-xs select-none whitespace-nowrap border border-[#6e40cc] dark:bg-[#8250df] dark:border-[#6e40cc]"
              title="Pull request has been merged"
            >
              <GitMerge className="w-3.5 h-3.5" />
              Merged
            </div>
          ) : (
            <MergeButton
              onMerge={
                prIsOpen
                  ? handleMerge
                  : async () => {
                      handleOpenPR();
                    }
              }
              isOpen={prIsOpen}
              disabled={
                isOpeningPr ||
                isCreatingPr ||
                isMerging ||
                (!prIsOpen && !hasChanges)
              }
            />
          )}
          {selectedRun?.pullRequestUrl &&
          selectedRun.pullRequestUrl !== "pending" ? (
            <a
              href={selectedRun.pullRequestUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none whitespace-nowrap"
            >
              <ExternalLink className="w-3.5 h-3.5" />
              {selectedRun.pullRequestIsDraft ? "View draft PR" : "View PR"}
            </a>
          ) : (
            <button
              onClick={handleViewPR}
              className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none disabled:opacity-60 disabled:cursor-not-allowed whitespace-nowrap"
              disabled={isCreatingPr || isOpeningPr || isMerging || !hasChanges}
            >
              <ExternalLink className="w-3.5 h-3.5" />
              {isCreatingPr ? "Creating draft PR..." : "Open draft PR"}
            </button>
          )}

          <OpenEditorSplitButton worktreePath={worktreePath} />

          <button className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none hidden">
            <ExternalLink className="w-3.5 h-3.5" />
          </button>
          <button className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none hidden">
            <Trash2 className="w-3.5 h-3.5" />
          </button>
          <Dropdown.Root>
            <Dropdown.Trigger
              className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
              aria-label="More actions"
            >
              <EllipsisVertical className="w-3.5 h-3.5" />
            </Dropdown.Trigger>
            <Dropdown.Portal>
              <Dropdown.Positioner sideOffset={5}>
                <Dropdown.Popup>
                  <Dropdown.Arrow />
                  <Dropdown.Item onClick={() => onExpandAll?.()}>
                    Expand all
                  </Dropdown.Item>
                  <Dropdown.Item onClick={() => onCollapseAll?.()}>
                    Collapse all
                  </Dropdown.Item>
                </Dropdown.Popup>
              </Dropdown.Positioner>
            </Dropdown.Portal>
          </Dropdown.Root>
        </div>

        {/* Branch row (second line, spans first two columns) */}
        <div className="col-start-1 row-start-2 col-span-2 flex items-center gap-2 text-xs text-neutral-400 min-w-0">
          <button
            onClick={handleCopyBranch}
            className="flex items-center gap-1 hover:text-neutral-700 dark:hover:text-white transition-colors group"
          >
            <div className="relative w-3 h-3">
              <GitBranch
                className={clsx(
                  "w-3 h-3 absolute inset-0 z-0",
                  clipboard.copied ? "hidden" : "block group-hover:hidden"
                )}
                aria-hidden={clipboard.copied}
              />
              <Copy
                className={clsx(
                  "w-3 h-3 absolute inset-0 z-10",
                  clipboard.copied ? "hidden" : "hidden group-hover:block"
                )}
                aria-hidden={clipboard.copied}
              />
              <Check
                className={clsx(
                  "w-3 h-3 text-green-400 absolute inset-0 z-50",
                  clipboard.copied ? "block" : "hidden"
                )}
                aria-hidden={!clipboard.copied}
              />
            </div>
            {selectedRun?.newBranch ? (
              <span className="font-mono text-neutral-600 dark:text-neutral-300 group-hover:text-neutral-900 dark:group-hover:text-white text-[11px] truncate min-w-0 max-w-full select-none">
                {selectedRun.newBranch}
              </span>
            ) : (
              <span className="font-mono text-neutral-500 text-[11px]">
                No branch
              </span>
            )}
          </button>

          <span className="text-neutral-500 dark:text-neutral-600 select-none">
            in
          </span>

          {task?.projectFullName && (
            <span className="font-mono text-neutral-600 dark:text-neutral-300 truncate min-w-0 max-w-[40%] whitespace-nowrap select-none text-[11px]">
              {task.projectFullName}
            </span>
          )}

          {taskRuns && taskRuns.length > 0 && (
            <>
              <span className="text-neutral-500 dark:text-neutral-600 select-none">
                by
              </span>
              <div className="min-w-0 flex-1">
                <Skeleton isLoaded={!!task} className="rounded-md">
                  <Dropdown.Root
                    open={agentMenuOpen}
                    onOpenChange={handleAgentOpenChange}
                  >
                    <Dropdown.Trigger className="flex items-center gap-1 text-neutral-600 dark:text-neutral-300 hover:text-neutral-900 dark:hover:text-white transition-colors text-xs select-none truncate min-w-0 max-w-full">
                      <span className="truncate">{selectedRun?.agentName || "Unknown agent"}</span>
                      <ChevronDown className="w-3 h-3 shrink-0" />
                    </Dropdown.Trigger>

                    <Dropdown.Portal>
                      <Dropdown.Positioner sideOffset={5}>
                        <Dropdown.Popup className="min-w-[200px]">
                          <Dropdown.Arrow />
                          {taskRuns?.map((run) => {
                            const agentName =
                              run.agentName ||
                              run.prompt?.match(/\(([^)]+)\)$/)?.[1] ||
                              "Unknown agent";
                            const isSelected = run._id === selectedRun?._id;
                            return (
                              <Dropdown.CheckboxItem
                                key={run._id}
                                checked={isSelected}
                                onCheckedChange={() => {
                                  if (!task?._id) {
                                    console.error(
                                      "[TaskDetailHeader] No task ID"
                                    );
                                    return;
                                  }
                                  if (!isSelected) {
                                    navigate({
                                      to: "/task/$taskId",
                                      params: { taskId: task?._id },
                                      search: { runId: run._id },
                                    });
                                  }
                                  // Close dropdown after selection
                                  setAgentMenuOpen(false);
                                }}
                                // Also close when selecting the same option
                                onClick={() => setAgentMenuOpen(false)}
                              >
                                <Dropdown.CheckboxItemIndicator>
                                  <Check className="w-3 h-3" />
                                </Dropdown.CheckboxItemIndicator>
                                <span className="col-start-2 flex items-center gap-1.5">
                                  {agentName}
                                  {run.isCrowned && (
                                    <Crown className="w-3 h-3 text-yellow-500 absolute right-4" />
                                  )}
                                </span>
                              </Dropdown.CheckboxItem>
                            );
                          })}
                        </Dropdown.Popup>
                      </Dropdown.Positioner>
                    </Dropdown.Portal>
                  </Dropdown.Root>
                </Skeleton>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
