import { OpenEditorSplitButton } from "@/components/OpenEditorSplitButton";
import { Dropdown } from "@/components/ui/dropdown";
import { MergeButton, type MergeMethod } from "@/components/ui/merge-button";
import { useSocketSuspense } from "@/contexts/socket/use-socket";
import { isElectron } from "@/lib/electron";
import { diffSmartQueryOptions } from "@/queries/diff-smart";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { Skeleton } from "@heroui/react";
import { useClipboard } from "@mantine/hooks";
import { useQuery as useRQ } from "@tanstack/react-query";
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
import {
  Suspense,
  useCallback,
  useMemo,
  useState,
  type CSSProperties,
} from "react";
import { toast } from "sonner";

interface TaskDetailHeaderProps {
  task?: Doc<"tasks"> | null;
  taskRuns?: Doc<"taskRuns">[] | null;
  selectedRun?: Doc<"taskRuns"> | null;
  isCreatingPr: boolean;
  setIsCreatingPr: (v: boolean) => void;
  totalAdditions?: number;
  totalDeletions?: number;
  taskRunId: Id<"taskRuns">;
  onExpandAll?: () => void;
  onCollapseAll?: () => void;
  teamSlugOrId: string;
  // Smart diff view (no toggle)
}

const ENABLE_MERGE_BUTTON = false;

function AdditionsAndDeletions({
  repoFullName,
  ref1,
  ref2,
}: {
  repoFullName: string;
  ref1: string;
  ref2: string;
}) {
  const diffsQuery = useRQ(
    repoFullName && ref1 && ref2
      ? diffSmartQueryOptions({ repoFullName, baseRef: ref1, headRef: ref2 })
      : { queryKey: ["diff-smart-disabled"], queryFn: async () => [] }
  );

  if (diffsQuery.error) {
    return (
      <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
        <span className="text-neutral-500 dark:text-neutral-400 font-medium select-none">
          Error loading diffs
        </span>
      </div>
    );
  }

  const totals = diffsQuery.data
    ? diffsQuery.data.reduce(
        (acc, d) => {
          acc.add += d.additions || 0;
          acc.del += d.deletions || 0;
          return acc;
        },
        { add: 0, del: 0 }
      )
    : undefined;

  return (
    <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
      <Skeleton
        className="rounded min-w-[20px] h-[14px]"
        isLoaded={!diffsQuery.isPending}
      >
        {totals && (
          <span className="text-green-600 dark:text-green-400 font-medium select-none">
            +{totals.add}
          </span>
        )}
      </Skeleton>
      <Skeleton
        className="rounded min-w-[20px] h-[14px]"
        isLoaded={!diffsQuery.isPending}
      >
        {totals && (
          <span className="text-red-600 dark:text-red-400 font-medium select-none">
            -{totals.del}
          </span>
        )}
      </Skeleton>
    </div>
  );
}

export function TaskDetailHeader({
  task,
  taskRuns,
  selectedRun,
  isCreatingPr,
  setIsCreatingPr,
  taskRunId,
  onExpandAll,
  onCollapseAll,
  teamSlugOrId,
}: TaskDetailHeaderProps) {
  const navigate = useNavigate();
  const clipboard = useClipboard({ timeout: 2000 });
  const prIsOpen = selectedRun?.pullRequestState === "open";
  const prIsMerged = selectedRun?.pullRequestState === "merged";
  const [agentMenuOpen, setAgentMenuOpen] = useState(false);
  const [isOpeningPr, setIsOpeningPr] = useState(false);
  const handleAgentOpenChange = useCallback((open: boolean) => {
    setAgentMenuOpen(open);
  }, []);
  const taskTitle = task?.pullRequestTitle || task?.text;
  const handleCopyBranch = () => {
    if (selectedRun?.newBranch) {
      clipboard.copy(selectedRun.newBranch);
    }
  };
  const [isMerging, setIsMerging] = useState(false);
  const worktreePath = useMemo(
    () => selectedRun?.worktreePath || task?.worktreePath || null,
    [selectedRun?.worktreePath, task?.worktreePath]
  );

  const dragStyle = isElectron
    ? ({ WebkitAppRegion: "drag" } as CSSProperties)
    : undefined;

  return (
    <div
      className="bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white px-3.5 sticky top-0 z-[var(--z-sticky)] py-2"
      style={dragStyle}
    >
      <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 gap-y-1">
        {/* Title row */}
        <div className="col-start-1 row-start-1 flex items-center gap-2 relative min-w-0">
          <h1 className="text-sm font-bold truncate min-w-0" title={taskTitle}>
            {taskTitle || "Loading..."}
          </h1>
          <Suspense
            fallback={
              <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
                <Skeleton className="rounded min-w-[20px] h-[14px] fade-out" />
                <Skeleton className="rounded min-w-[20px] h-[14px] fade-out" />
              </div>
            }
          >
            <AdditionsAndDeletions
              repoFullName={task?.projectFullName || ""}
              ref1={task?.baseBranch || ""}
              ref2={selectedRun?.newBranch || ""}
            />
          </Suspense>
        </div>

        <div
          className="col-start-3 row-start-1 row-span-2 self-center flex items-center gap-2 shrink-0"
          style={
            isElectron
              ? ({ WebkitAppRegion: "no-drag" } as CSSProperties)
              : undefined
          }
        >
          {/* Removed Latest/Landed toggle; using smart diff */}
          <Suspense
            fallback={
              <div className="flex items-center gap-2">
                <button
                  className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-200 dark:text-neutral-800 border border-neutral-300 dark:border-neutral-700 rounded font-medium text-xs select-none whitespace-nowrap cursor-wait"
                  disabled
                >
                  <GitMerge className="w-3.5 h-3.5" />
                  Merge
                </button>
                <button
                  className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-200 dark:text-neutral-800 border border-neutral-300 dark:border-neutral-700 rounded font-medium text-xs select-none whitespace-nowrap cursor-wait"
                  disabled
                >
                  <ExternalLink className="w-3.5 h-3.5" />
                  Open draft PR
                </button>
              </div>
            }
          >
            <SocketActions
              selectedRun={selectedRun ?? null}
              taskRunId={taskRunId}
              prIsOpen={prIsOpen}
              prIsMerged={prIsMerged}
              isCreatingPr={isCreatingPr}
              setIsCreatingPr={setIsCreatingPr}
              isOpeningPr={isOpeningPr}
              setIsOpeningPr={setIsOpeningPr}
              isMerging={isMerging}
              setIsMerging={setIsMerging}
              repoFullName={task?.projectFullName || ""}
              ref1={task?.baseBranch || ""}
              ref2={selectedRun?.newBranch || ""}
            />
          </Suspense>

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
        <div
          className="col-start-1 row-start-2 col-span-2 flex items-center gap-2 text-xs text-neutral-400 min-w-0"
          style={
            isElectron
              ? ({ WebkitAppRegion: "no-drag" } as CSSProperties)
              : undefined
          }
        >
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
                  "w-3 h-3 absolute inset-0 z-[var(--z-low)]",
                  clipboard.copied ? "hidden" : "hidden group-hover:block"
                )}
                aria-hidden={clipboard.copied}
              />
              <Check
                className={clsx(
                  "w-3 h-3 text-green-400 absolute inset-0 z-[var(--z-sticky)]",
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
                      <span className="truncate">
                        {selectedRun?.agentName || "Unknown agent"}
                      </span>
                      <ChevronDown className="w-3 h-3 shrink-0" />
                    </Dropdown.Trigger>

                    <Dropdown.Portal>
                      <Dropdown.Positioner sideOffset={5}>
                        <Dropdown.Popup className="min-w-[200px]">
                          <Dropdown.Arrow />
                          {taskRuns?.map((run) => {
                            const trimmedAgentName = run.agentName?.trim();
                            const summary = run.summary?.trim();
                            const agentName =
                              trimmedAgentName && trimmedAgentName.length > 0
                                ? trimmedAgentName
                                : summary && summary.length > 0
                                  ? summary
                                  : "unknown agent";
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
                                      to: "/$teamSlugOrId/task/$taskId",
                                      params: {
                                        teamSlugOrId,
                                        taskId: task?._id,
                                      },
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

function SocketActions({
  selectedRun,
  taskRunId,
  prIsOpen,
  prIsMerged,
  isCreatingPr,
  setIsCreatingPr,
  isOpeningPr,
  setIsOpeningPr,
  isMerging,
  setIsMerging,
  repoFullName,
  ref1,
  ref2,
}: {
  selectedRun: Doc<"taskRuns"> | null;
  taskRunId: Id<"taskRuns">;
  prIsOpen: boolean;
  prIsMerged: boolean;
  isCreatingPr: boolean;
  setIsCreatingPr: (v: boolean) => void;
  isOpeningPr: boolean;
  setIsOpeningPr: (v: boolean) => void;
  isMerging: boolean;
  setIsMerging: (v: boolean) => void;
  repoFullName: string;
  ref1: string;
  ref2: string;
}) {
  const { socket } = useSocketSuspense();

  // For environments, get repos from selectedRun.environment.selectedRepos
  const environmentRepos = useMemo(() => {
    const repos = selectedRun?.environment?.selectedRepos ?? [];
    const trimmed = repos
      .map((repo) => repo?.trim())
      .filter((repo): repo is string => Boolean(repo));
    return Array.from(new Set(trimmed));
  }, [selectedRun?.environment?.selectedRepos]);

  const primaryRepo = repoFullName || environmentRepos[0] || "";

  const diffsQuery = useRQ(
    primaryRepo ? diffSmartQueryOptions({ repoFullName: primaryRepo, baseRef: ref1, headRef: ref2 }) : { queryKey: ["diff-smart-disabled"], queryFn: async () => [] }
  );
  const hasChanges = (diffsQuery.data || []).length > 0;

  const handleMerge = async (method: MergeMethod) => {
    if (!socket || !taskRunId) return;
    setIsMerging(true);
    const toastId = toast.loading(`Merging PR (${method})...`);
    await new Promise<void>((resolve) => {
      socket.emit(
        "github-merge-pr",
        { taskRunId, method },
        (resp: {
          success: boolean;
          merged?: boolean;
          state?: string;
          url?: string;
          error?: string;
        }) => {
          setIsMerging(false);
          if (resp.success) {
            toast.success("PR merged", { id: toastId, description: resp.url });
          } else {
            toast.error("Failed to merge PR", {
              id: toastId,
              description: resp.error,
            });
          }
          resolve();
        }
      );
    });
  };

  const handleMergeBranch = async (): Promise<void> => {
    if (!socket || !taskRunId) return;
    setIsMerging(true);
    const toastId = toast.loading("Merging branch...");
    await new Promise<void>((resolve) => {
      socket.emit("github-merge-branch", { taskRunId }, (resp) => {
        setIsMerging(false);
        if (resp.success) {
          toast.success("Branch merged", {
            id: toastId,
            description: resp.commitSha,
          });
        } else {
          toast.error("Failed to merge branch", {
            id: toastId,
            description: resp.error,
          });
        }
        resolve();
      });
    });
  };

  const handleOpenPR = () => {
    if (!socket || !taskRunId) return;
    // Create PR or mark draft ready
    setIsOpeningPr(true);
    const toastId = toast.loading("Opening PR...");
    socket.emit("github-open-pr", { taskRunId }, (resp) => {
      setIsOpeningPr(false);
      if (resp.success) {
        toast.success("PR opened", {
          id: toastId,
          description: resp.url,
          ...(resp.url
            ? {
                action: {
                  label: "View PR",
                  onClick: () =>
                    window.open(resp.url, "_blank", "noopener,noreferrer"),
                },
              }
            : {}),
        });
      } else {
        console.error("Failed to open PR:", resp.error);
        toast.error("Failed to open PR", {
          id: toastId,
          description: resp.error,
        });
      }
    });
  };

  const handleViewPR = () => {
    if (!socket || !taskRunId) return;
    const prUrl = selectedRun?.pullRequestUrl;
    if (prUrl && prUrl !== "pending") {
      window.open(prUrl, "_blank");
      return;
    }
    setIsCreatingPr(true);
    socket.emit(
      "github-create-draft-pr",
      { taskRunId },
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

  return (
    <>
      {prIsMerged ? (
        <div
          className="flex items-center gap-1.5 px-3 py-1 bg-[#8250df] text-white rounded font-medium text-xs select-none whitespace-nowrap border border-[#6e40cc] dark:bg-[#8250df] dark:border-[#6e40cc] cursor-not-allowed"
          title="Pull request has been merged"
        >
          <GitMerge className="w-3.5 h-3.5" />
          Merged
        </div>
      ) : (
        <MergeButton
          onMerge={prIsOpen ? handleMerge : async () => handleOpenPR()}
          isOpen={prIsOpen}
          disabled={
            isOpeningPr ||
            isCreatingPr ||
            isMerging ||
            (!prIsOpen && !hasChanges)
          }
        />
      )}
      {!prIsOpen && !prIsMerged && ENABLE_MERGE_BUTTON && (
        <button
          onClick={handleMergeBranch}
          className="flex items-center gap-1.5 px-3 py-1 bg-[#8250df] text-white rounded hover:bg-[#8250df]/90 dark:bg-[#8250df] dark:hover:bg-[#8250df]/90 border border-[#6e40cc] dark:border-[#6e40cc] font-medium text-xs select-none disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap"
          disabled={isOpeningPr || isCreatingPr || isMerging || !hasChanges}
        >
          <GitMerge className="w-3.5 h-3.5" />
          Merge
        </button>
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
    </>
  );
}
