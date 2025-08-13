import { FloatingPane } from "@/components/floating-pane";
import { GitDiffViewer } from "@/components/git-diff-viewer";
import { TaskDetailHeader } from "@/components/task-detail-header";
import { type MergeMethod } from "@/components/ui/merge-button";
import { useSocket } from "@/contexts/socket/use-socket";
import { api } from "@cmux/convex/api";
import { type Id } from "@cmux/convex/dataModel";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";

export const Route = createFileRoute("/_layout/task/$taskId/")({
  component: TaskDetailPage,
  validateSearch: (search: Record<string, unknown>) => {
    return {
      runId: search.runId as string | undefined,
    };
  },
  loader: async (opts) => {
    await Promise.all([
      opts.context.queryClient.ensureQueryData(
        convexQuery(api.taskRuns.getByTask, {
          taskId: opts.params.taskId as Id<"tasks">,
        })
      ),
      opts.context.queryClient.ensureQueryData(
        convexQuery(api.tasks.getById, {
          id: opts.params.taskId as Id<"tasks">,
        })
      ),
    ]);
  },
});

function TaskDetailPage() {
  const { taskId } = Route.useParams();
  const { runId } = Route.useSearch();

  const [isCreatingPr, setIsCreatingPr] = useState(false);
  const [isCheckingDiffs, setIsCheckingDiffs] = useState(false);
  const [diffControls, setDiffControls] = useState<{
    expandAll: () => void;
    collapseAll: () => void;
    totalAdditions: number;
    totalDeletions: number;
  } | null>(null);
  const { socket } = useSocket();

  const task = useQuery(api.tasks.getById, {
    id: taskId as Id<"tasks">,
  });
  const taskRuns = useQuery(api.taskRuns.getByTask, {
    taskId: taskId as Id<"tasks">,
  });

  // Find the crowned run (if any)
  const crownedRun = taskRuns?.find((run) => run.isCrowned);

  // Select the run to display (either from query param, crowned, or first available)
  const selectedRun = useMemo(() => {
    if (runId) {
      return taskRuns?.find((run) => run._id === runId);
    }
    // Default to crowned run if available, otherwise first completed run
    return (
      crownedRun ||
      taskRuns?.find((run) => run.status === "completed") ||
      taskRuns?.[0]
    );
  }, [runId, taskRuns, crownedRun]);

  // Fetch diffs for the selected run
  const diffs = useQuery(
    api.gitDiffs.getByTaskRun,
    selectedRun ? { taskRunId: selectedRun._id } : "skip"
  );

  // Check for new changes on mount and periodically
  useEffect(() => {
    if (!selectedRun) return;

    const checkForChanges = async () => {
      setIsCheckingDiffs(true);

      try {
        // Use Socket.IO to request diff refresh from the server
        if (!socket) {
          console.warn("Socket not available");
          setIsCheckingDiffs(false);
          return;
        }

        socket.emit(
          "refresh-diffs",
          { taskRunId: selectedRun._id },
          (response: { success: boolean; message?: string }) => {
            if (response.success) {
              console.log("Diff refresh:", response.message);
              // The diffs will be updated reactively via the useQuery hook
            } else {
              console.log("Could not refresh diffs:", response.message);
            }
            setIsCheckingDiffs(false);
          }
        );
      } catch (error) {
        console.error("Error refreshing diffs:", error);
        setIsCheckingDiffs(false);
      }
    };

    // Check on mount
    checkForChanges();

    // Check periodically (every 30 seconds)
    const interval = setInterval(checkForChanges, 30000);

    return () => clearInterval(interval);
  }, [selectedRun?._id]);

  // Check PR status on mount and periodically
  useEffect(() => {
    if (!selectedRun || !socket) return;

    const checkPRStatus = () => {
      socket.emit(
        "check-pr-status",
        { taskRunId: selectedRun._id },
        (response: { success: boolean; haspr?: boolean; url?: string; merged?: boolean; error?: string }) => {
          if (response.success) {
            console.log("PR status:", response);
            // The PR status will be updated in the database and reflected via useQuery
          }
        }
      );
    };

    // Check on mount
    checkPRStatus();

    // Check periodically (every 15 seconds)
    const interval = setInterval(checkPRStatus, 15000);

    return () => clearInterval(interval);
  }, [selectedRun?._id, socket]);

  // Stabilize diffs per-run to avoid cross-run flashes
  const [stableDiffsByRun, setStableDiffsByRun] = useState<
    Record<string, typeof diffs>
  >({});
  useEffect(() => {
    if (!diffs || isCheckingDiffs || !selectedRun?._id) return;
    const runKey = selectedRun._id as string;
    setStableDiffsByRun((prev) => {
      const prevForRun = prev[runKey];
      if (!prevForRun) return { ...prev, [runKey]: diffs };
      const prevByPath = new Map(prevForRun.map((d) => [d.filePath, d]));
      const next: typeof diffs = diffs.map((d) => {
        const p = prevByPath.get(d.filePath);
        if (!p) return d;
        const same =
          p.status === d.status &&
          p.additions === d.additions &&
          p.deletions === d.deletions &&
          p.isBinary === d.isBinary &&
          (p.patch || "") === (d.patch || "") &&
          (p.oldContent || "") === (d.oldContent || "") &&
          (p.newContent || "") === (d.newContent || "") &&
          (p.contentOmitted || false) === (d.contentOmitted || false);
        return same ? p : d;
      });
      return { ...prev, [runKey]: next };
    });
  }, [diffs, isCheckingDiffs, selectedRun?._id]);

  // When a refresh cycle ends, apply whatever the latest diffs are for this run
  useEffect(() => {
    if (!isCheckingDiffs && diffs && selectedRun?._id) {
      setStableDiffsByRun((prev) => ({
        ...prev,
        [selectedRun._id as string]: diffs,
      }));
    }
  }, [isCheckingDiffs, diffs, selectedRun?._id]);

  const [isMerging, setIsMerging] = useState(false);
  
  const handleMerge = useCallback(
    (method: MergeMethod) => {
      if (!socket || !selectedRun?._id) {
        toast.error("Unable to merge", {
          description: "Socket connection not available",
        });
        return;
      }

      // Check if already merged
      if (selectedRun.pullRequestMerged) {
        toast.info("Already merged", {
          description: "This pull request has already been merged",
        });
        return;
      }

      // Check if PR exists
      if (!selectedRun.pullRequestUrl || selectedRun.pullRequestUrl === "pending") {
        toast.error("No pull request", {
          description: "Please create a pull request first by clicking 'Open PR'",
        });
        return;
      }

      setIsMerging(true);
      socket.emit(
        "github-merge-pr",
        { taskRunId: selectedRun._id, mergeMethod: method },
        (response: { success: boolean; message?: string; error?: string }) => {
          setIsMerging(false);
          if (response.success) {
            toast.success("Pull request merged!", {
              description: response.message,
            });
          } else {
            toast.error("Failed to merge", {
              description: response.error || "Unknown error occurred",
            });
          }
        }
      );
    },
    [socket, selectedRun]
  );

  const hasAnyDiffs = !!(
    (selectedRun?._id ? stableDiffsByRun[selectedRun._id as string] : diffs) ||
    []
  ).length;
  console.log({ hasAnyDiffs });

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          <TaskDetailHeader
            task={task ?? null}
            taskRuns={taskRuns ?? null}
            selectedRun={selectedRun ?? null}
            isCheckingDiffs={isCheckingDiffs}
            isCreatingPr={isCreatingPr}
            setIsCreatingPr={setIsCreatingPr}
            onMerge={handleMerge}
            isMerging={isMerging}
            totalAdditions={diffControls?.totalAdditions}
            totalDeletions={diffControls?.totalDeletions}
            hasAnyDiffs={hasAnyDiffs}
            onExpandAll={diffControls?.expandAll}
            onCollapseAll={diffControls?.collapseAll}
          />
          {task?.text && (
            <div className="mb-2 px-3.5">
              <div className="text-xs text-neutral-600 dark:text-neutral-300">
                <span className="text-neutral-500 dark:text-neutral-400 select-none">
                  Prompt:{" "}
                </span>
                <span className="font-medium">{task.text}</span>
              </div>
            </div>
          )}
          <div className="bg-white dark:bg-neutral-950 grow flex flex-col">
            <GitDiffViewer
              diffs={
                (selectedRun?._id
                  ? stableDiffsByRun[selectedRun._id as string]
                  : undefined) ||
                diffs ||
                []
              }
              isLoading={!diffs && !!selectedRun}
              taskRunId={selectedRun?._id}
              isMerged={selectedRun?.pullRequestMerged}
              key={selectedRun?._id}
              onControlsChange={(c) => setDiffControls(c)}
            />
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
