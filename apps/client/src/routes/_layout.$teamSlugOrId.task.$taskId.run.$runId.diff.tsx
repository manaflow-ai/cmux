import { FloatingPane } from "@/components/floating-pane";
import { type GitDiffViewerProps } from "@/components/git-diff-viewer";
import { RunDiffSection } from "@/components/RunDiffSection";
import { TaskDetailHeader } from "@/components/task-detail-header";
import { useTheme } from "@/components/theme/use-theme";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { useSocket } from "@/contexts/socket/use-socket";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import { cn } from "@/lib/utils";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { performRunSync, runSyncStatusQueryOptions } from "@/queries/run-sync";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type {
  TaskAcknowledged,
  TaskStarted,
  TaskError,
  RunBranchStatus,
} from "@cmux/shared";
import { AGENT_CONFIGS } from "@cmux/shared/agentConfig";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { Switch } from "@heroui/react";
import { useQuery as useRQ, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery } from "convex/react";
import { Command } from "lucide-react";
import {
  Suspense,
  memo,
  useCallback,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";
import { toast } from "sonner";
import { attachTaskLifecycleListeners } from "@/lib/socket/taskLifecycleListeners";
import z from "zod";
import type { EditorApi } from "@/components/dashboard/DashboardInput";
import LexicalEditor from "@/components/lexical/LexicalEditor";
import { useCombinedWorkflowData, WorkflowRunsSection } from "@/components/WorkflowRunsSection";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

const gitDiffViewerClassNames: GitDiffViewerProps["classNames"] = {
  fileDiffRow: {
    button: "top-[96px] md:top-[56px]",
  },
};

type DiffControls = Parameters<
  NonNullable<GitDiffViewerProps["onControlsChange"]>
>[0];

type RunEnvironmentSummary = Pick<
  Doc<"environments">,
  "_id" | "name" | "selectedRepos"
>;

type TaskRunWithChildren = Doc<"taskRuns"> & {
  children: TaskRunWithChildren[];
  environment: RunEnvironmentSummary | null;
};

const AVAILABLE_AGENT_NAMES = new Set(AGENT_CONFIGS.map((agent) => agent.name));

type AutoSyncReason = "merge-in-progress" | "pull-error" | "pull-exception";

function buildAutoSyncPrompt({
  task,
  run,
  status,
  reason,
}: {
  task: Doc<"tasks">;
  run: TaskRunWithChildren;
  status?: RunBranchStatus;
  reason: AutoSyncReason;
}): string {
  const baseBranch = task.baseBranch || "main";
  const branchName = run.newBranch || "(unknown branch)";
  const lines: string[] = [];

  if (reason === "merge-in-progress") {
    lines.push(
      "A previous sync attempt left the repository mid-merge. Finish syncing the branch with the latest base.",
    );
  } else {
    lines.push(
      `Sync the branch ${branchName} with the latest commits on origin/${baseBranch}.`,
    );
  }

  if (status?.behind) {
    lines.push(
      `The branch is currently ${status.behind} commit${status.behind === 1 ? "" : "s"} behind origin/${baseBranch}.`,
    );
  }

  if (status?.mergeInProgress) {
    lines.push(
      "A merge conflict is already in progress; resolve every conflicting file, stage the results, and complete the merge.",
    );
  } else {
    lines.push(
      `Pull from origin/${baseBranch}, resolve any conflicts, and ensure the project still builds and tests successfully.`,
    );
  }

  lines.push(
    "Leave a brief summary of what changed so reviewers understand the resolution steps.",
  );

  return lines.join(" ");
}

interface RestartTaskFormProps {
  task: Doc<"tasks"> | null | undefined;
  teamSlugOrId: string;
  restartAgents: string[];
  restartIsCloudMode: boolean;
  persistenceKey: string;
}

const RestartTaskForm = memo(function RestartTaskForm({
  task,
  teamSlugOrId,
  restartAgents,
  restartIsCloudMode,
  persistenceKey,
}: RestartTaskFormProps) {
  const { socket } = useSocket();
  const { theme } = useTheme();
  const { addTaskToExpand } = useExpandTasks();
  const createTask = useMutation(api.tasks.create);
  const editorApiRef = useRef<EditorApi | null>(null);
  const [followUpText, setFollowUpText] = useState("");
  const [isRestartingTask, setIsRestartingTask] = useState(false);
  const [overridePrompt, setOverridePrompt] = useState(false);

  const handleRestartTask = useCallback(async () => {
    if (!task) {
      toast.error("Task data is still loading. Try again in a moment.");
      return;
    }
    if (!socket) {
      toast.error("Socket not connected. Refresh or try again later.");
      return;
    }

    const editorContent = editorApiRef.current?.getContent();
    const followUp = (editorContent?.text ?? followUpText).trim();

    if (!followUp && overridePrompt) {
      toast.error("Add new instructions when overriding the prompt.");
      return;
    }
    if (!followUp && !task.text) {
      toast.error("Add follow-up context before restarting.");
      return;
    }

    if (restartAgents.length === 0) {
      toast.error(
        "No previous agents found for this task. Start a new run from the dashboard.",
      );
      return;
    }

    const originalPrompt = task.text ?? "";
    const combinedPrompt = overridePrompt
      ? followUp
      : originalPrompt
        ? followUp
          ? `${originalPrompt}\n\n${followUp}`
          : originalPrompt
        : followUp;

    const projectFullNameForSocket =
      task.projectFullName ??
      (task.environmentId ? `env:${task.environmentId}` : undefined);

    if (!projectFullNameForSocket) {
      toast.error("Missing repository or environment for this task.");
      return;
    }

    setIsRestartingTask(true);

    try {
      const existingImages =
        task.images && task.images.length > 0
          ? task.images.map((image) => ({
            storageId: image.storageId,
            fileName: image.fileName,
            altText: image.altText,
          }))
          : [];

      const newImages = (editorContent?.images && editorContent.images.length > 0
        ? editorContent.images.filter((img) => "storageId" in img)
        : []) as {
          storageId: Id<"_storage">;
          fileName: string | undefined;
          altText: string;
        }[];

      const imagesPayload =
        [...existingImages, ...newImages].length > 0
          ? [...existingImages, ...newImages]
          : undefined;

      const newTaskId = await createTask({
        teamSlugOrId,
        text: combinedPrompt,
        projectFullName: task.projectFullName ?? undefined,
        baseBranch: task.baseBranch ?? undefined,
        images: imagesPayload,
        environmentId: task.environmentId ?? undefined,
      });

      addTaskToExpand(newTaskId);

      const isEnvTask = projectFullNameForSocket.startsWith("env:");
      const repoUrl = !isEnvTask
        ? `https://github.com/${projectFullNameForSocket}.git`
        : undefined;

      const handleRestartAck = (response: TaskAcknowledged | TaskStarted | TaskError) => {
        if ("error" in response) {
          toast.error(`Task restart error: ${response.error}`);
          return;
        }

        attachTaskLifecycleListeners(socket, response.taskId, {
          onFailed: (payload) => {
            toast.error(`Follow-up task failed to start: ${payload.error}`);
          },
        });

        editorApiRef.current?.clear();
        setFollowUpText("");
      };

      socket.emit(
        "start-task",
        {
          ...(repoUrl ? { repoUrl } : {}),
          ...(task.baseBranch ? { branch: task.baseBranch } : {}),
          taskDescription: combinedPrompt,
          projectFullName: projectFullNameForSocket,
          taskId: newTaskId,
          selectedAgents: [...restartAgents],
          isCloudMode: restartIsCloudMode,
          ...(task.environmentId ? { environmentId: task.environmentId } : {}),
          theme,
        },
        handleRestartAck,
      );

      toast.success("Started follow-up task");
    } catch (error) {
      console.error("Failed to restart task", error);
      toast.error("Failed to start follow-up task");
    } finally {
      setIsRestartingTask(false);
    }
  }, [
    addTaskToExpand,
    createTask,
    followUpText,
    overridePrompt,
    restartAgents,
    restartIsCloudMode,
    socket,
    task,
    teamSlugOrId,
    theme,
  ]);

  const handleFormSubmit = useCallback(
    (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      void handleRestartTask();
    },
    [handleRestartTask],
  );

  const trimmedFollowUp = followUpText.trim();
  const isRestartDisabled =
    isRestartingTask ||
    (overridePrompt ? !trimmedFollowUp : !trimmedFollowUp && !task?.text) ||
    !socket ||
    !task;
  const isMac =
    typeof navigator !== "undefined" &&
    navigator.userAgent.toUpperCase().includes("MAC");
  const restartDisabledReason = useMemo(() => {
    if (isRestartingTask) {
      return "Starting follow-up...";
    }
    if (!task) {
      return "Task data loading...";
    }
    if (!socket) {
      return "Socket not connected";
    }
    if (overridePrompt && !trimmedFollowUp) {
      return "Add new instructions";
    }
    if (!trimmedFollowUp && !task?.text) {
      return "Add follow-up context";
    }
    return undefined;
  }, [isRestartingTask, overridePrompt, socket, task, trimmedFollowUp]);

  return (
    <div className="sticky bottom-0 z-[var(--z-popover)] border-t border-transparent px-3.5 pb-3.5 pt-2">
      <form
        onSubmit={handleFormSubmit}
        className="mx-auto w-full max-w-2xl overflow-hidden rounded-2xl border border-neutral-500/15 bg-white dark:border-neutral-500/15 dark:bg-neutral-950"
      >
        <div className="px-3.5 pt-3.5">
          <LexicalEditor
            key={persistenceKey}
            placeholder={
              overridePrompt
                ? "Edit original task instructions..."
                : "Add updated instructions or context..."
            }
            onChange={setFollowUpText}
            onSubmit={() => void handleRestartTask()}
            repoUrl={
              task?.projectFullName
                ? `https://github.com/${task.projectFullName}.git`
                : undefined
            }
            branch={task?.baseBranch ?? undefined}
            environmentId={task?.environmentId ?? undefined}
            persistenceKey={persistenceKey}
            maxHeight="300px"
            minHeight="30px"
            onEditorReady={(api) => {
              editorApiRef.current = api;
            }}
            contentEditableClassName="text-[15px] text-neutral-900 dark:text-neutral-100 focus:outline-none"
            padding={{
              paddingLeft: "0px",
              paddingRight: "0px",
              paddingTop: "0px",
            }}
          />
        </div>
        <div className="flex items-center justify-between gap-2 px-3.5 pb-3 pt-2">
          <div className="flex items-center gap-2.5">
            <Switch
              isSelected={overridePrompt}
              onValueChange={(value) => {
                setOverridePrompt(value);
                if (value) {
                  if (!task?.text) {
                    return;
                  }
                  const promptText = task.text;
                  const currentContent = editorApiRef.current?.getContent();
                  const currentText = currentContent?.text ?? "";
                  if (!currentText) {
                    editorApiRef.current?.insertText?.(promptText);
                  } else if (!currentText.includes(promptText)) {
                    editorApiRef.current?.insertText?.(promptText);
                  }
                } else {
                  editorApiRef.current?.clear();
                }
              }}
              size="sm"
              aria-label="Override prompt"
              classNames={{
                wrapper: cn(
                  "group-data-[selected=true]:bg-neutral-600",
                  "group-data-[selected=true]:border-neutral-600",
                  "dark:group-data-[selected=true]:bg-neutral-500",
                  "dark:group-data-[selected=true]:border-neutral-500",
                ),
              }}
            />
            <span className="text-xs leading-tight text-neutral-500 dark:text-neutral-400">
              {overridePrompt
                ? "Override initial prompt"
                : task?.text
                  ? "Original prompt included"
                  : "New task prompt"}
            </span>
          </div>
          <Tooltip>
            <TooltipTrigger asChild>
              <span tabIndex={0} className="inline-flex">
                <Button
                  type="submit"
                  size="sm"
                  variant="default"
                  className="!h-7"
                  disabled={isRestartDisabled}
                >
                  {isRestartingTask ? "Starting..." : "Restart task"}
                </Button>
              </span>
            </TooltipTrigger>
            <TooltipContent
              side="bottom"
              className="flex items-center gap-1 border-black bg-black text-white [&>*:last-child]:bg-black [&>*:last-child]:fill-black"
            >
              {restartDisabledReason ? (
                <span className="text-xs">{restartDisabledReason}</span>
              ) : (
                <>
                  {isMac ? (
                    <>
                      <Command className="size-3.5 opacity-80" />
                      <span className="text-xs leading-tight">+ Enter</span>
                    </>
                  ) : (
                    <span className="text-xs leading-tight">Ctrl + Enter</span>
                  )}
                </>
              )}
            </TooltipContent>
          </Tooltip>
        </div>
      </form>
    </div>
  );
});

interface RunSyncBannerProps {
  status?: RunBranchStatus;
  isLoading: boolean;
  onSync: () => void;
  isSyncing: boolean;
  isDeployingAgent: boolean;
  baseBranchLabel: string;
}

function RunSyncBanner({
  status,
  isLoading,
  onSync,
  isSyncing,
  isDeployingAgent,
  baseBranchLabel,
}: RunSyncBannerProps) {
  const branchLabel = baseBranchLabel || "main";

  let primaryText = `Checking sync status for origin/${branchLabel}…`;
  let secondaryText: string | null = null;
  let toneClass = "text-neutral-600 dark:text-neutral-300";
  let actionLabel = "Sync";
  let showAction = false;

  if (!isLoading && status) {
    if (status.status === "up_to_date" && !status.mergeInProgress) {
      primaryText = `Branch is up to date with origin/${branchLabel}.`;
      toneClass = "text-green-600 dark:text-green-400";
    } else if (status.mergeInProgress) {
      primaryText = `Merge conflicts detected while syncing with origin/${branchLabel}.`;
      secondaryText =
        "Handing off to an agent will finish the merge and resolve conflicts.";
      toneClass = "text-amber-600 dark:text-amber-400";
      actionLabel = "Deploy Agent";
      showAction = true;
    } else if (status.status === "behind") {
      primaryText = `Branch is ${status.behind} commit${status.behind === 1 ? "" : "s"} behind origin/${branchLabel}.`;
      secondaryText = "Sync now to pull the latest changes.";
      toneClass = "text-amber-600 dark:text-amber-400";
      showAction = true;
    } else {
      primaryText = `Unable to confirm if branch is current with origin/${branchLabel}.`;
      secondaryText = "You can still attempt to sync or deploy an agent.";
      showAction = true;
    }
  } else if (!isLoading) {
    primaryText = `Unable to load sync status for origin/${branchLabel}.`;
    secondaryText = "You can attempt to sync anyway.";
    showAction = true;
  }

  const warnings = status?.warnings?.filter((warning, index, arr) =>
    arr.indexOf(warning) === index,
  );

  const isBusy = isSyncing || isDeployingAgent;
  if (isBusy) {
    actionLabel = isDeployingAgent ? "Deploying…" : "Syncing…";
  }

  return (
    <div className="border-b border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900 px-3 py-3 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
      <div className="flex flex-col gap-1">
        <span className={cn("text-sm font-medium", toneClass)}>{primaryText}</span>
        {secondaryText ? (
          <span className="text-xs text-neutral-600 dark:text-neutral-400">
            {secondaryText}
          </span>
        ) : null}
        {warnings && warnings.length > 0 ? (
          <ul className="text-xs text-neutral-500 dark:text-neutral-400 list-disc pl-4 space-y-0.5">
            {warnings.map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
        ) : null}
      </div>
      {showAction ? (
        <Button
          size="sm"
          onClick={onSync}
          disabled={isBusy}
          className="self-start md:self-auto"
        >
          {actionLabel}
        </Button>
      ) : null}
    </div>
  );
}

RestartTaskForm.displayName = "RestartTaskForm";

function collectAgentNamesFromRuns(
  runs: TaskRunWithChildren[] | undefined,
): string[] {
  if (!runs) return [];

  // Top-level runs mirror the user's original agent selection, including duplicates.
  const rootAgents = runs
    .map((run) => run.agentName?.trim())
    .filter((name): name is string => {
      if (!name) {
        return false;
      }
      return AVAILABLE_AGENT_NAMES.has(name);
    });

  if (rootAgents.length > 0) {
    return rootAgents;
  }

  const ordered: string[] = [];
  const traverse = (items: TaskRunWithChildren[]) => {
    for (const run of items) {
      const trimmed = run.agentName?.trim();
      if (trimmed && AVAILABLE_AGENT_NAMES.has(trimmed)) {
        ordered.push(trimmed);
      }
      if (run.children.length > 0) {
        traverse(run.children);
      }
    }
  };

  traverse(runs);
  return ordered;
}

function WorkflowRunsWrapper({
  teamSlugOrId,
  repoFullName,
  prNumber,
  headSha,
  checksExpandedByRepo,
  setChecksExpandedByRepo,
}: {
  teamSlugOrId: string;
  repoFullName: string;
  prNumber: number;
  headSha?: string;
  checksExpandedByRepo: Record<string, boolean | null>;
  setChecksExpandedByRepo: React.Dispatch<React.SetStateAction<Record<string, boolean | null>>>;
}) {
  const workflowData = useCombinedWorkflowData({
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
  });

  // Auto-expand if there are failures (only on initial load)
  const hasAnyFailure = useMemo(() => {
    return workflowData.allRuns.some(
      (run) =>
        run.conclusion === "failure" ||
        run.conclusion === "timed_out" ||
        run.conclusion === "action_required"
    );
  }, [workflowData.allRuns]);

  const isExpanded = checksExpandedByRepo[repoFullName] ?? hasAnyFailure;

  return (
    <WorkflowRunsSection
      allRuns={workflowData.allRuns}
      isLoading={workflowData.isLoading}
      isExpanded={isExpanded}
      onToggle={() => {
        setChecksExpandedByRepo((prev) => ({
          ...prev,
          [repoFullName]: !isExpanded,
        }));
      }}
    />
  );
}

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/diff",
)({
  component: RunDiffPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: (opts) => {
    const { runId } = opts.params;

    void opts.context.queryClient
      .ensureQueryData(
        convexQuery(api.taskRuns.getRunDiffContext, {
          teamSlugOrId: opts.params.teamSlugOrId,
          taskId: opts.params.taskId,
          runId,
        }),
      )
      .then(async (context) => {
        if (!context) {
          return;
        }

        const { task, taskRuns, branchMetadataByRepo } = context;

        if (task) {
          opts.context.queryClient.setQueryData(
            convexQuery(api.tasks.getById, {
              teamSlugOrId: opts.params.teamSlugOrId,
              id: opts.params.taskId,
            }).queryKey,
            task,
          );
        }

        if (taskRuns) {
          opts.context.queryClient.setQueryData(
            convexQuery(api.taskRuns.getByTask, {
              teamSlugOrId: opts.params.teamSlugOrId,
              taskId: opts.params.taskId,
            }).queryKey,
            taskRuns,
          );
        }

        const selectedTaskRun = taskRuns.find((run) => run._id === runId);
        if (!task || !selectedTaskRun?.newBranch) {
          return;
        }

        const trimmedProjectFullName = task.projectFullName?.trim();
        const targetRepos = new Set<string>();
        for (const repo of selectedTaskRun.environment?.selectedRepos ?? []) {
          const trimmed = repo?.trim();
          if (trimmed) {
            targetRepos.add(trimmed);
          }
        }
        if (trimmedProjectFullName) {
          targetRepos.add(trimmedProjectFullName);
        }

        if (targetRepos.size === 0) {
          return;
        }

        const baseRefForDiff = normalizeGitRef(task.baseBranch || "main");
        const headRefForDiff = normalizeGitRef(selectedTaskRun.newBranch);
        if (!headRefForDiff || !baseRefForDiff) {
          return;
        }

        const metadataForPrimaryRepo = trimmedProjectFullName
          ? branchMetadataByRepo?.[trimmedProjectFullName]
          : undefined;
        const baseBranchMeta = metadataForPrimaryRepo?.find(
          (branch) => branch.name === task.baseBranch,
        );

        const prefetches = Array.from(targetRepos).map(async (repoFullName) => {
          const metadata =
            trimmedProjectFullName && repoFullName === trimmedProjectFullName
              ? baseBranchMeta
              : undefined;

          return opts.context.queryClient
            .ensureQueryData(
              gitDiffQueryOptions({
                baseRef: baseRefForDiff,
                headRef: headRefForDiff,
                repoFullName,
                lastKnownBaseSha: metadata?.lastKnownBaseSha,
                lastKnownMergeCommitSha: metadata?.lastKnownMergeCommitSha,
              }),
            )
            .catch(() => undefined);
        });

        await Promise.all(prefetches);
      })
      .catch(() => undefined);

    return undefined;
  },
});

function RunDiffPage() {
  const { taskId, teamSlugOrId, runId } = Route.useParams();
  const [diffControls, setDiffControls] = useState<DiffControls | null>(null);
  const [isSyncing, setIsSyncing] = useState(false);
  const [isDeployingAgent, setIsDeployingAgent] = useState(false);
  const queryClient = useQueryClient();
  const { theme } = useTheme();
  const { addTaskToExpand: addTaskToExpandGlobal } = useExpandTasks();
  const task = useQuery(api.tasks.getById, {
    teamSlugOrId,
    id: taskId,
  });
  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  const syncStatusQueryOptions = useMemo(
    () =>
      runSyncStatusQueryOptions({
        taskRunId: selectedRun?._id ?? "",
        teamSlugOrId,
        enabled: Boolean(selectedRun?._id),
      }),
    [selectedRun?._id, teamSlugOrId],
  );

  const runSyncStatusQuery = useRQ(syncStatusQueryOptions);
  const syncStatus = runSyncStatusQuery.data;
  const isSyncStatusLoading =
    runSyncStatusQuery.isPending || runSyncStatusQuery.isFetching;

  // Get PR information from the selected run
  const pullRequests = useMemo(() => {
    return selectedRun?.pullRequests?.filter(
      (pr) => pr.number !== undefined && pr.number !== null
    ) as Array<{ repoFullName: string; number: number; url?: string }> | undefined;
  }, [selectedRun]);

  // Track expanded state for each PR's checks
  const [checksExpandedByRepo, setChecksExpandedByRepo] = useState<Record<string, boolean | null>>({});

  const expandAllChecks = useCallback(() => {
    if (!pullRequests) return;
    const newState: Record<string, boolean | null> = {};
    for (const pr of pullRequests) {
      newState[pr.repoFullName] = true;
    }
    setChecksExpandedByRepo(newState);
  }, [pullRequests]);

  const collapseAllChecks = useCallback(() => {
    if (!pullRequests) return;
    const newState: Record<string, boolean | null> = {};
    for (const pr of pullRequests) {
      newState[pr.repoFullName] = false;
    }
    setChecksExpandedByRepo(newState);
  }, [pullRequests]);
  const restartProvider = selectedRun?.vscode?.provider;
  const restartRunEnvironmentId = selectedRun?.environmentId;
  const taskEnvironmentId = task?.environmentId;
  const restartIsCloudMode = useMemo(() => {
    if (restartProvider === "docker") {
      return false;
    }
    if (restartProvider) {
      return true;
    }
    if (restartRunEnvironmentId || taskEnvironmentId) {
      return true;
    }
    return false;
  }, [restartProvider, restartRunEnvironmentId, taskEnvironmentId]);
  const environmentRepos = useMemo(() => {
    const repos = selectedRun?.environment?.selectedRepos ?? [];
    const trimmed = repos
      .map((repo) => repo?.trim())
      .filter((repo): repo is string => Boolean(repo));
    return Array.from(new Set(trimmed));
  }, [selectedRun]);

  const repoFullNames = useMemo(() => {
    if (task?.projectFullName) {
      return [task.projectFullName];
    }
    return environmentRepos;
  }, [task?.projectFullName, environmentRepos]);

  const [primaryRepo, ...additionalRepos] = repoFullNames;

  const branchMetadataQuery = useRQ({
    ...convexQuery(api.github.getBranchesByRepo, {
      teamSlugOrId,
      repo: primaryRepo ?? "",
    }),
    enabled: Boolean(primaryRepo),
  });

  const branchMetadata = branchMetadataQuery.data as
    | Doc<"branches">[]
    | undefined;

  const baseBranchMetadata = useMemo(() => {
    if (!task?.baseBranch) {
      return undefined;
    }
    return branchMetadata?.find((branch) => branch.name === task.baseBranch);
  }, [branchMetadata, task?.baseBranch]);

  const metadataByRepo = useMemo(() => {
    if (!primaryRepo) return undefined;
    if (!baseBranchMetadata) return undefined;
    const { lastKnownBaseSha, lastKnownMergeCommitSha } = baseBranchMetadata;
    if (!lastKnownBaseSha && !lastKnownMergeCommitSha) {
      return undefined;
    }
    return {
      [primaryRepo]: {
        lastKnownBaseSha: lastKnownBaseSha ?? undefined,
        lastKnownMergeCommitSha: lastKnownMergeCommitSha ?? undefined,
      },
    };
  }, [primaryRepo, baseBranchMetadata]);

  const restartAgents = useMemo(() => {
    const previousAgents = collectAgentNamesFromRuns(taskRuns);
    if (previousAgents.length > 0) {
      return previousAgents;
    }
    const fallback = selectedRun?.agentName?.trim();
    if (fallback && AVAILABLE_AGENT_NAMES.has(fallback)) {
      return [fallback];
    }
    return [];
  }, [selectedRun?.agentName, taskRuns]);

  const createFollowUpTask = useMutation(api.tasks.create);

  const deployAgentForSync = useCallback(
    async (reason: AutoSyncReason, status?: RunBranchStatus) => {
      if (isDeployingAgent) {
        return;
      }
      if (!task) {
        toast.error("Task data is still loading. Try again in a moment.");
        return;
      }
      if (!selectedRun) {
        toast.error("Run data is unavailable. Refresh and try again.");
        return;
      }
      if (!socket) {
        toast.error("Socket not connected. Refresh or try again later.");
        return;
      }
      if (restartAgents.length === 0) {
        toast.error(
          "No previous agents found for this task. Start a new run from the dashboard.",
        );
        return;
      }

      const projectFullNameForSocket =
        task.projectFullName ??
        (task.environmentId ? `env:${task.environmentId}` : undefined);

      if (!projectFullNameForSocket) {
        toast.error("Missing repository or environment to deploy the agent.");
        return;
      }

      setIsDeployingAgent(true);
      const prompt = buildAutoSyncPrompt({
        task,
        run: selectedRun,
        status,
        reason,
      });

      const imagesPayload =
        task.images && task.images.length > 0
          ? task.images.map((image) => ({
              storageId: image.storageId,
              fileName: image.fileName,
              altText: image.altText,
            }))
          : undefined;

      try {
        const newTaskId = await createFollowUpTask({
          teamSlugOrId,
          text: prompt,
          projectFullName: task.projectFullName ?? undefined,
          baseBranch: task.baseBranch ?? undefined,
          images: imagesPayload,
          environmentId: task.environmentId ?? undefined,
        });

        addTaskToExpandGlobal(newTaskId);

        const repoUrl = projectFullNameForSocket.startsWith("env:")
          ? undefined
          : `https://github.com/${projectFullNameForSocket}.git`;

        const handleRestartAck = (
          response: TaskAcknowledged | TaskStarted | TaskError,
        ) => {
          if ("error" in response) {
            toast.error(`Failed to deploy agent: ${response.error}`);
            return;
          }

          attachTaskLifecycleListeners(socket, response.taskId, {
            onFailed: (payload) => {
              toast.error(
                `Auto-sync agent failed to start: ${payload.error}`,
              );
            },
          });
        };

        socket.emit(
          "start-task",
          {
            ...(repoUrl ? { repoUrl } : {}),
            ...(task.baseBranch ? { branch: task.baseBranch } : {}),
            taskDescription: prompt,
            projectFullName: projectFullNameForSocket,
            taskId: newTaskId,
            selectedAgents: [...restartAgents],
            isCloudMode: restartIsCloudMode,
            ...(task.environmentId ? { environmentId: task.environmentId } : {}),
            theme,
          },
          handleRestartAck,
        );

        toast.info("Deploying an agent to resolve sync issues…");

        void queryClient.invalidateQueries({
          queryKey: syncStatusQueryOptions.queryKey,
        });
      } catch (error) {
        const message =
          error instanceof Error ? error.message : String(error ?? "");
        toast.error("Failed to deploy agent", { description: message });
      } finally {
        setIsDeployingAgent(false);
      }
    },
    [
      addTaskToExpandGlobal,
      createFollowUpTask,
      isDeployingAgent,
      queryClient,
      restartAgents,
      restartIsCloudMode,
      selectedRun,
      socket,
      syncStatusQueryOptions.queryKey,
      task,
      teamSlugOrId,
      theme,
    ],
  );

  const invalidateDiffQueries = useCallback(async () => {
    if (!selectedRun) {
      return;
    }
    const baseRefForDiff = normalizeGitRef(task?.baseBranch || "main");
    const headRefForDiff = normalizeGitRef(selectedRun.newBranch);
    if (!baseRefForDiff || !headRefForDiff || !primaryRepo) {
      return;
    }

    const repos = [primaryRepo, ...additionalRepos];
    await Promise.all(
      repos.map((repo) => {
        const options = gitDiffQueryOptions({
          repoFullName: repo,
          baseRef: baseRefForDiff,
          headRef: headRefForDiff,
          lastKnownBaseSha: metadataByRepo?.[repo]?.lastKnownBaseSha,
          lastKnownMergeCommitSha: metadataByRepo?.[repo]?.lastKnownMergeCommitSha,
        });
        return queryClient.invalidateQueries({ queryKey: options.queryKey });
      }),
    );
  }, [
    additionalRepos,
    metadataByRepo,
    primaryRepo,
    queryClient,
    selectedRun,
    task?.baseBranch,
  ]);

  const handleSync = useCallback(async () => {
    if (isSyncing || isDeployingAgent) {
      return;
    }
    if (!selectedRun) {
      toast.error("Run data is unavailable. Refresh and try again.");
      return;
    }
    if (!task) {
      toast.error("Task data is still loading. Try again in a moment.");
      return;
    }

    if (syncStatus?.mergeInProgress) {
      await deployAgentForSync("merge-in-progress", syncStatus);
      return;
    }

    setIsSyncing(true);
    try {
      const response = await performRunSync(selectedRun._id);

      if (response.ok) {
        const branchLabel = task.baseBranch || "main";
        toast.success(`Synced with origin/${branchLabel}.`);
        if (response.status) {
          queryClient.setQueryData(
            syncStatusQueryOptions.queryKey,
            response.status,
          );
        } else {
          void runSyncStatusQuery.refetch();
        }
        await invalidateDiffQueries();
        return;
      }

      if (response.status) {
        queryClient.setQueryData(
          syncStatusQueryOptions.queryKey,
          response.status,
        );
      }
      toast.error("Sync failed", {
        description: response.error,
      });
      await deployAgentForSync("pull-error", response.status);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error ?? "");
      toast.error("Sync failed", { description: message });
      await deployAgentForSync("pull-exception", syncStatus);
    } finally {
      setIsSyncing(false);
    }
  }, [
    deployAgentForSync,
    invalidateDiffQueries,
    isDeployingAgent,
    isSyncing,
    queryClient,
    runSyncStatusQuery,
    selectedRun,
    syncStatus,
    syncStatusQueryOptions.queryKey,
    task,
  ]);

  const taskRunId = selectedRun?._id ?? runId;
  const restartTaskPersistenceKey = `restart-task-${taskId}-${runId}`;

  // 404 if selected run is missing
  if (!selectedRun) {
    return (
      <div className="p-6 text-sm text-neutral-600 dark:text-neutral-300">
        404 – Run not found
      </div>
    );
  }

  const baseRef = normalizeGitRef(task?.baseBranch || "main");
  const headRef = normalizeGitRef(selectedRun.newBranch);
  const hasDiffSources =
    Boolean(primaryRepo) && Boolean(baseRef) && Boolean(headRef);
  const shouldPrefixDiffs = repoFullNames.length > 1;

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          <TaskDetailHeader
            task={task}
            taskRuns={taskRuns ?? null}
            selectedRun={selectedRun ?? null}
            taskRunId={taskRunId}
            onExpandAll={diffControls?.expandAll}
            onCollapseAll={diffControls?.collapseAll}
            onExpandAllChecks={expandAllChecks}
            onCollapseAllChecks={collapseAllChecks}
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
          <div className="bg-white dark:bg-neutral-900 grow flex flex-col">
            {pullRequests && pullRequests.length > 0 && (
              <Suspense fallback={null}>
                {pullRequests.map((pr) => (
                  <WorkflowRunsWrapper
                    key={pr.repoFullName}
                    teamSlugOrId={teamSlugOrId}
                    repoFullName={pr.repoFullName}
                    prNumber={pr.number}
                    headSha={undefined}
                    checksExpandedByRepo={checksExpandedByRepo}
                    setChecksExpandedByRepo={setChecksExpandedByRepo}
                  />
                ))}
              </Suspense>
            )}
            {hasDiffSources ? (
              <>
                <RunSyncBanner
                  status={syncStatus}
                  isLoading={isSyncStatusLoading}
                  onSync={handleSync}
                  isSyncing={isSyncing}
                  isDeployingAgent={isDeployingAgent}
                  baseBranchLabel={task?.baseBranch || "main"}
                />
                <Suspense
                  fallback={
                    <div className="flex items-center justify-center h-full">
                      <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none">
                        Loading diffs...
                      </div>
                    </div>
                  }
                >
                  <RunDiffSection
                    repoFullName={primaryRepo as string}
                    additionalRepoFullNames={additionalRepos}
                    withRepoPrefix={shouldPrefixDiffs}
                    ref1={baseRef}
                    ref2={headRef}
                    onControlsChange={setDiffControls}
                    classNames={gitDiffViewerClassNames}
                    metadataByRepo={metadataByRepo}
                  />
                </Suspense>
              </>
            ) : (
              <div className="p-6 text-sm text-neutral-600 dark:text-neutral-300">
                Missing repo or branches to show diff.
              </div>
            )}
            <RestartTaskForm
              key={restartTaskPersistenceKey}
              task={task}
              teamSlugOrId={teamSlugOrId}
              restartAgents={restartAgents}
              restartIsCloudMode={restartIsCloudMode}
              persistenceKey={restartTaskPersistenceKey}
            />
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
