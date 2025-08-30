import { FloatingPane } from "@/components/floating-pane";
import { GitDiffViewer } from "@/components/git-diff-viewer";
import { TaskDetailHeader } from "@/components/task-detail-header";
import { type MergeMethod } from "@/components/ui/merge-button";
import { useSocket } from "@/contexts/socket/use-socket";
import { api } from "@cmux/convex/api";
import { type Id } from "@cmux/convex/dataModel";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery as useRQ } from "@tanstack/react-query";
import { createFileRoute, useRouter } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import z from "zod";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
});

export const Route = createFileRoute("/_layout/$teamSlugOrId/task/$taskId/")({
  component: TaskDetailPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
      };
    },
  },
  validateSearch: (search: Record<string, unknown>) => {
    const runId = typedZid("taskRuns").optional().parse(search.runId);
    return {
      runId: runId,
    };
  },
  loader: async (opts) => {
    await Promise.all([
      opts.context.queryClient.ensureQueryData(
        convexQuery(api.taskRuns.getByTask, {
          teamSlugOrId: opts.params.teamSlugOrId,
          taskId: opts.params.taskId,
        })
      ),
      opts.context.queryClient.ensureQueryData(
        convexQuery(api.tasks.getById, {
          teamSlugOrId: opts.params.teamSlugOrId,
          id: opts.params.taskId,
        })
      ),
    ]);
  },
});

function TaskDetailPage() {
  const { taskId, teamSlugOrId } = Route.useParams();
  const { runId } = Route.useSearch();

  const [isCreatingPr, setIsCreatingPr] = useState(false);
  // Removed periodic diff refresh; diffs are loaded on demand and on run change
  const [diffControls, setDiffControls] = useState<{
    expandAll: () => void;
    collapseAll: () => void;
    totalAdditions: number;
    totalDeletions: number;
  } | null>(null);
  const { socket } = useSocket();
  const router = useRouter();
  const queryClient = router.options.context?.queryClient;

  const task = useQuery(api.tasks.getById, {
    teamSlugOrId,
    id: taskId,
  });
  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
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

  // Fetch diffs for the selected run via socket (on-demand)
  const diffsQuery = useRQ({
    queryKey: ["run-diffs", selectedRun?._id ?? "none"],
    queryFn: async () =>
      await new Promise<import("@cmux/shared/diff-types").ReplaceDiffEntry[]>(
        (resolve, reject) => {
          if (!selectedRun?._id || !socket) {
            console.error("No selected run or socket");
            resolve([]);
            return;
          }
          socket.emit(
            "get-run-diffs",
            { taskRunId: selectedRun._id },
            (resp) => {
              console.log("get-run-diffs", resp);
              if (resp.ok) resolve(resp.diffs);
              else reject(new Error(resp.error || "Failed to load diffs"));
            }
          );
        }
      ),
    enabled: !!selectedRun?._id && !!socket,
    staleTime: 10_000,
  });

  // On selection, sync PR state with GitHub so UI reflects latest
  useEffect(() => {
    if (!selectedRun?._id || !socket) return;
    socket.emit(
      "github-sync-pr-state",
      { taskRunId: selectedRun._id },
      (_resp: { success: boolean }) => {
        // Convex subscription will update UI automatically
      }
    );
  }, [selectedRun?._id, socket]);

  // Live update diffs when files change for this worktree; mutate TanStack cache directly
  useEffect(() => {
    if (!socket || !selectedRun?._id || !selectedRun?.worktreePath) return;
    const runId = selectedRun._id;
    const workspacePath = selectedRun.worktreePath as string;
    const onChanged = (data: { workspacePath: string; filePath: string }) => {
      if (data.workspacePath !== workspacePath) return;
      socket.emit(
        "get-run-diffs",
        { taskRunId: runId },
        (resp: {
          ok: boolean;
          diffs: import("@cmux/shared/diff-types").ReplaceDiffEntry[];
          error?: string;
        }) => {
          if (resp.ok && queryClient) {
            queryClient.setQueryData(["run-diffs", runId], resp.diffs);
          }
        }
      );
    };
    socket.on("git-file-changed", onChanged);
    return () => {
      socket.off("git-file-changed", onChanged);
    };
  }, [socket, selectedRun?._id, selectedRun?.worktreePath, queryClient]);

  // Check for new changes on mount and periodically
  // Initial load on run change
  useEffect(() => {
    if (!selectedRun?._id) return;
    void diffsQuery.refetch();
  }, [selectedRun?._id, diffsQuery.refetch, diffsQuery]);

  // Stabilize diffs per-run to avoid cross-run flashes
  const [stableDiffsByRun, setStableDiffsByRun] = useState<
    Record<
      Id<"taskRuns">,
      import("@cmux/shared/diff-types").ReplaceDiffEntry[] | undefined
    >
  >({});
  useEffect(() => {
    const diffs = diffsQuery.data;
    if (!diffs || !selectedRun?._id) return;
    const runKey = selectedRun._id;
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
  }, [diffsQuery.data, selectedRun?._id]);

  // When a refresh cycle ends, apply whatever the latest diffs are for this run
  useEffect(() => {
    const diffs = diffsQuery.data;
    if (diffs && selectedRun?._id) {
      setStableDiffsByRun((prev) => ({
        ...prev,
        [selectedRun._id]: diffs,
      }));
    }
  }, [diffsQuery.data, selectedRun?._id]);

  const [, setIsMerging] = useState(false);
  const handleMerge = async (method: MergeMethod): Promise<void> => {
    if (!socket || !selectedRun?._id) return;
    setIsMerging(true);
    const toastId = toast.loading(`Merging PR (${method})...`);
    await new Promise<void>((resolve) => {
      socket.emit(
        "github-merge-pr",
        { taskRunId: selectedRun._id, method },
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
    if (!socket || !selectedRun?._id) return;
    setIsMerging(true);
    const toastId = toast.loading("Merging branch...");
    await new Promise<void>((resolve) => {
      socket.emit(
        "github-merge-branch",
        { taskRunId: selectedRun._id },
        (resp: { success: boolean; commitSha?: string; error?: string }) => {
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
        }
      );
    });
  };

  const hasAnyDiffs = !!(
    (selectedRun?._id ? stableDiffsByRun[selectedRun._id] : diffsQuery.data) ||
    []
  ).length;

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          <TaskDetailHeader
            task={task}
            taskRuns={taskRuns ?? null}
            selectedRun={selectedRun ?? null}
            isCreatingPr={isCreatingPr}
            setIsCreatingPr={setIsCreatingPr}
            onMerge={handleMerge}
            onMergeBranch={handleMergeBranch}
            totalAdditions={diffControls?.totalAdditions}
            totalDeletions={diffControls?.totalDeletions}
            hasAnyDiffs={hasAnyDiffs}
            onExpandAll={diffControls?.expandAll}
            onCollapseAll={diffControls?.collapseAll}
            isLoading={diffsQuery.isPending}
            teamSlugOrId={teamSlugOrId}
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
                  ? stableDiffsByRun[selectedRun._id]
                  : undefined) ||
                diffsQuery.data ||
                []
              }
              isLoading={!diffsQuery.data && !!selectedRun}
              taskRunId={selectedRun?._id}
              key={selectedRun?._id}
              onControlsChange={(c) => setDiffControls(c)}
            />
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
