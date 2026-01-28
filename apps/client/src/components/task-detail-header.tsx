import { OpenEditorSplitButton } from "@/components/OpenEditorSplitButton";
import { Dropdown } from "@/components/ui/dropdown";
import { MergeButton, type MergeMethod } from "@/components/ui/merge-button";
import { useSocketSuspense } from "@/contexts/socket/use-socket";
import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type { TaskRunWithChildren } from "@/types/task";
import { Skeleton } from "@heroui/react";
import { useClipboard } from "@mantine/hooks";
import {
  useMutation,
  useQueries,
  type DefaultError,
} from "@tanstack/react-query";
import {
  postApiIntegrationsGithubPrsMergeMutation,
  postApiIntegrationsGithubPrsOpenMutation,
} from "@cmux/www-openapi-client/react-query";
import type {
  Options,
  PostApiIntegrationsGithubPrsMergeData,
  PostApiIntegrationsGithubPrsMergeResponse,
  PostApiIntegrationsGithubPrsOpenData,
  PostApiIntegrationsGithubPrsOpenResponse,
} from "@cmux/www-openapi-client";
import { useNavigate, useLocation } from "@tanstack/react-router";
import clsx from "clsx";
import {
  Check,
  ChevronDown,
  Copy,
  Crown,
  ExternalLink,
  FolderOpen,
  GitBranch,
  GitMerge,
  RefreshCw,
  Settings,
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
import {
  SocketMutationError,
  type MergeBranchResponse,
  type PullRequestActionResponse,
  type ToastFeedbackContext,
  getErrorDescription,
} from "./task-detail-header.mutations";
import type {
  SocketMutationErrorInstance,
} from "./task-detail-header.mutations";

interface TaskDetailHeaderProps {
  task?: Doc<"tasks"> | null;
  taskRuns?: TaskRunWithChildren[] | null;
  selectedRun?: TaskRunWithChildren | null;
  totalAdditions?: number;
  totalDeletions?: number;
  taskRunId: Id<"taskRuns">;
  onExpandAll?: () => void;
  onCollapseAll?: () => void;
  onExpandAllChecks?: () => void;
  onCollapseAllChecks?: () => void;
  onPanelSettings?: () => void;
  onOpenLocalWorkspace?: () => void;
  onToggleAutoSync?: () => void;
  autoSyncEnabled?: boolean;
  teamSlugOrId: string;
}

const ENABLE_MERGE_BUTTON = false;

type RepoDiffTarget = {
  repoFullName: string;
  baseRef?: string;
  headRef?: string;
};

function AdditionsAndDeletions({
  repos,
  defaultBaseRef,
  defaultHeadRef,
}: {
  repos: RepoDiffTarget[];
  defaultBaseRef?: string;
  defaultHeadRef?: string;
}) {
  const repoConfigs = useMemo(() => {
    const normalizedDefaults = {
      base: normalizeGitRef(defaultBaseRef),
      head: normalizeGitRef(defaultHeadRef),
    };

    const map = new Map<
      string,
      { repoFullName: string; baseRef?: string; headRef?: string }
    >();
    for (const repo of repos) {
      const repoFullName = repo.repoFullName?.trim();
      if (!repoFullName) {
        continue;
      }
      const normalizedBaseRef =
        normalizeGitRef(repo.baseRef) || normalizedDefaults.base;
      const normalizedHeadRef =
        normalizeGitRef(repo.headRef) || normalizedDefaults.head;
      map.set(repoFullName, {
        repoFullName,
        baseRef: normalizedBaseRef || undefined,
        headRef: normalizedHeadRef || undefined,
      });
    }

    return Array.from(map.values());
  }, [repos, defaultBaseRef, defaultHeadRef]);

  const queries = useQueries({
    queries: repoConfigs.map((config) => {
      const headRef = config.headRef ?? "";
      const options = gitDiffQueryOptions({
        repoFullName: config.repoFullName,
        baseRef: config.baseRef,
        headRef,
      });
      return {
        ...options,
        enabled: options.enabled,
      };
    }),
  });

  const hasMissingHeadRef = repoConfigs.some((config) => !config.headRef);

  const isLoading =
    repoConfigs.length === 0 ||
    hasMissingHeadRef ||
    queries.some((query) => query.isPending || query.isFetching);

  const firstError = queries.find((query, index) => {
    if (!repoConfigs[index]?.headRef) {
      return false;
    }
    return Boolean(query.error);
  });

  if (!isLoading && firstError?.error) {
    return (
      <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
        <span className="text-neutral-500 dark:text-neutral-400 font-medium select-none">
          Error loading diffs
        </span>
      </div>
    );
  }

  const totals =
    !isLoading && queries.length > 0
      ? queries.reduce(
        (acc, query, index) => {
          if (!repoConfigs[index]?.headRef) {
            return acc;
          }
          for (const diff of query.data ?? []) {
            acc.add += diff.additions ?? 0;
            acc.del += diff.deletions ?? 0;
          }
          return acc;
        },
        { add: 0, del: 0 },
      )
      : undefined;

  return (
    <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
      <Skeleton className="rounded min-w-[20px] h-[14px]" isLoaded={!isLoading}>
        {totals && (
          <span className="text-green-600 dark:text-green-400 font-medium select-none">
            +{totals.add}
          </span>
        )}
      </Skeleton>
      <Skeleton className="rounded min-w-[20px] h-[14px]" isLoaded={!isLoading}>
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
  taskRunId,
  onExpandAll,
  onCollapseAll,
  onExpandAllChecks,
  onCollapseAllChecks,
  onPanelSettings,
  onOpenLocalWorkspace,
  onToggleAutoSync,
  autoSyncEnabled = true,
  teamSlugOrId,
}: TaskDetailHeaderProps) {
  const navigate = useNavigate();
  const location = useLocation();
  const clipboard = useClipboard({ timeout: 2000 });
  const prIsOpen = selectedRun?.pullRequestState === "open";
  const prIsMerged = selectedRun?.pullRequestState === "merged";
  const [agentMenuOpen, setAgentMenuOpen] = useState(false);
  const handleAgentOpenChange = useCallback((open: boolean) => {
    setAgentMenuOpen(open);
  }, []);
  const taskTitle = task?.pullRequestTitle || task?.text;
  const handleCopyBranch = () => {
    if (selectedRun?.newBranch) {
      clipboard.copy(selectedRun.newBranch);
    }
  };
  const worktreePath = useMemo(
    () => selectedRun?.worktreePath || task?.worktreePath || null,
    [selectedRun?.worktreePath, task?.worktreePath],
  );

  const normalizedBaseBranch = useMemo(() => {
    const candidate = task?.baseBranch;
    if (candidate && candidate.trim()) {
      return normalizeGitRef(candidate);
    }
    return normalizeGitRef("main");
  }, [task?.baseBranch]);
  const normalizedHeadBranch = useMemo(
    () => normalizeGitRef(selectedRun?.newBranch),
    [selectedRun?.newBranch],
  );

  const environmentRepos = useMemo<string[]>(() => {
    const repos = selectedRun?.environment?.selectedRepos ?? [];
    const trimmed = repos
      .map((repo: string | undefined) => repo?.trim())
      .filter((repo): repo is string => Boolean(repo));
    return Array.from(new Set(trimmed));
  }, [selectedRun]);

  const repoFullNames = useMemo(() => {
    const names = new Set<string>();
    if (task?.projectFullName?.trim()) {
      names.add(task.projectFullName.trim());
    }
    for (const repo of environmentRepos) {
      names.add(repo);
    }
    return Array.from(names);
  }, [task?.projectFullName, environmentRepos]);

  const repoDiffTargets = useMemo<RepoDiffTarget[]>(() => {
    const baseRef = normalizedBaseBranch || undefined;
    const headRef = normalizedHeadBranch || undefined;
    return repoFullNames.map((repoFullName) => ({
      repoFullName,
      baseRef,
      headRef,
    }));
  }, [repoFullNames, normalizedBaseBranch, normalizedHeadBranch]);

  const dragStyle = isElectron
    ? ({ WebkitAppRegion: "drag" } as CSSProperties)
    : undefined;

  const hasExpandActions = Boolean(onExpandAll || onExpandAllChecks);
  const hasCollapseActions = Boolean(onCollapseAll || onCollapseAllChecks);
  const showActionsDropdown = hasExpandActions || hasCollapseActions;

  const handleExpandAllClick = useCallback(() => {
    onExpandAll?.();
    onExpandAllChecks?.();
  }, [onExpandAll, onExpandAllChecks]);

  const handleCollapseAllClick = useCallback(() => {
    onCollapseAll?.();
    onCollapseAllChecks?.();
  }, [onCollapseAll, onCollapseAllChecks]);

  return (
    <div
      className="bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white px-3.5 sticky top-0 z-[var(--z-sticky)] py-2 border-b border-neutral-200/80 dark:border-neutral-800/70"
      style={dragStyle}
    >
      <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 gap-y-1">
        {/* Title row */}
        <div className="col-start-1 row-start-1 flex items-center gap-2 relative min-w-0">
          <h1 className="text-sm font-bold truncate min-w-0" title={taskTitle}>
            {taskTitle || "Loading..."}
          </h1>
          {/* Hide git diff stats for cloud/local workspaces */}
          {!task?.isCloudWorkspace && !task?.isLocalWorkspace && (
            <Suspense
              fallback={
                <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
                  <Skeleton className="rounded min-w-[20px] h-[14px] fade-out" />
                  <Skeleton className="rounded min-w-[20px] h-[14px] fade-out" />
                </div>
              }
            >
              <AdditionsAndDeletions
                repos={repoDiffTargets}
                defaultBaseRef={normalizedBaseBranch || undefined}
                defaultHeadRef={normalizedHeadBranch || undefined}
              />
            </Suspense>
          )}
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
              repoDiffTargets={repoDiffTargets}
              teamSlugOrId={teamSlugOrId}
            />
          </Suspense>

          <OpenEditorSplitButton worktreePath={worktreePath} />

          {onOpenLocalWorkspace && (
            <button
              onClick={onOpenLocalWorkspace}
              className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
              aria-label="Open local workspace"
              title="Open local workspace from this branch"
            >
              <FolderOpen className="w-3.5 h-3.5" />
            </button>
          )}

          {onToggleAutoSync && (
            <button
              onClick={onToggleAutoSync}
              className={clsx(
                "p-1 select-none transition-colors",
                autoSyncEnabled
                  ? "text-green-500 hover:text-green-600 dark:text-green-400 dark:hover:text-green-300"
                  : "text-neutral-400 hover:text-neutral-700 dark:hover:text-white"
              )}
              aria-label={autoSyncEnabled ? "Auto-sync enabled (click to disable)" : "Auto-sync disabled (click to enable)"}
              title={autoSyncEnabled ? "Auto-sync ON - Click to disable" : "Auto-sync OFF - Click to enable"}
            >
              <RefreshCw className="w-3.5 h-3.5" />
            </button>
          )}

          {onPanelSettings && (
            <button
              onClick={onPanelSettings}
              className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
              aria-label="Panel settings"
              title="Configure panel layout"
            >
              <Settings className="w-3.5 h-3.5" />
            </button>
          )}

          {showActionsDropdown && (
            <Dropdown.Root>
              <Dropdown.Trigger
                className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
                aria-label="More actions"
              >
                <span aria-hidden>⋯</span>
              </Dropdown.Trigger>
              <Dropdown.Portal>
                <Dropdown.Positioner sideOffset={5}>
                  <Dropdown.Popup>
                    <Dropdown.Arrow />
                    {hasExpandActions && (
                      <Dropdown.Item onClick={handleExpandAllClick}>
                        Expand all
                      </Dropdown.Item>
                    )}
                    {hasCollapseActions && (
                      <Dropdown.Item onClick={handleCollapseAllClick}>
                        Collapse all
                      </Dropdown.Item>
                    )}
                  </Dropdown.Popup>
                </Dropdown.Positioner>
              </Dropdown.Portal>
            </Dropdown.Root>
          )}

          <button className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none hidden">
            <ExternalLink className="w-3.5 h-3.5" />
          </button>
          <button className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none hidden">
            <Trash2 className="w-3.5 h-3.5" />
          </button>
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
                  clipboard.copied ? "hidden" : "block group-hover:hidden",
                )}
                aria-hidden={clipboard.copied}
              />
              <Copy
                className={clsx(
                  "w-3 h-3 absolute inset-0 z-[var(--z-low)]",
                  clipboard.copied ? "hidden" : "hidden group-hover:block",
                )}
                aria-hidden={clipboard.copied}
              />
              <Check
                className={clsx(
                  "w-3 h-3 text-green-400 absolute inset-0 z-[var(--z-sticky)]",
                  clipboard.copied ? "block" : "hidden",
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

          {taskRuns && taskRuns.length > 0 && selectedRun && (
            <>
              <span className="text-neutral-500 dark:text-neutral-600 select-none">
                by
              </span>
              <Dropdown.Root
                open={agentMenuOpen}
                onOpenChange={handleAgentOpenChange}
              >
                <Dropdown.Trigger className="flex items-center gap-1 text-neutral-600 dark:text-neutral-300 hover:text-neutral-900 dark:hover:text-white transition-colors text-[11px] select-none">
                  <span className="truncate">
                    {selectedRun.agentName || "Unknown agent"}
                  </span>
                  <ChevronDown className="w-3 h-3 shrink-0" />
                </Dropdown.Trigger>

                <Dropdown.Portal>
                  <Dropdown.Positioner
                    sideOffset={5}
                    className="!z-[var(--z-global-blocking)]"
                  >
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
                        const isSelected = run._id === selectedRun._id;
                        return (
                          <Dropdown.CheckboxItem
                            key={run._id}
                            checked={isSelected}
                            onCheckedChange={() => {
                              if (!task?._id) {
                                console.error(
                                  "[TaskDetailHeader] No task ID",
                                );
                                return;
                              }
                              if (!isSelected) {
                                // Check if we're currently on the git diff viewer
                                const isOnDiffPage = location.pathname.endsWith("/diff");

                                if (isOnDiffPage) {
                                  // Navigate to the selected agent's git diff viewer
                                  navigate({
                                    to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
                                    params: {
                                      teamSlugOrId,
                                      taskId: task._id,
                                      runId: run._id,
                                    },
                                  });
                                } else {
                                  // Navigate to the task index page with the runId search param
                                  navigate({
                                    to: "/$teamSlugOrId/task/$taskId",
                                    params: {
                                      teamSlugOrId,
                                      taskId: task._id,
                                    },
                                    search: { runId: run._id },
                                  });
                                }
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
  repoDiffTargets,
  teamSlugOrId,
}: {
  selectedRun: TaskRunWithChildren | null;
  taskRunId: Id<"taskRuns">;
  prIsOpen: boolean;
  prIsMerged: boolean;
  repoDiffTargets: RepoDiffTarget[];
  teamSlugOrId: string;
}) {
  const { socket } = useSocketSuspense();
  const navigate = useNavigate();
  const pullRequests = useMemo(
    () => selectedRun?.pullRequests ?? [],
    [selectedRun?.pullRequests],
  );

  const repoFullNames = useMemo(() => {
    const names = new Set<string>();
    for (const target of repoDiffTargets) {
      const trimmed = target.repoFullName?.trim();
      if (trimmed) {
        names.add(trimmed);
      }
    }
    for (const pr of pullRequests) {
      const trimmed = pr.repoFullName?.trim();
      if (trimmed) {
        names.add(trimmed);
      }
    }
    return Array.from(names).sort((a, b) => a.localeCompare(b));
  }, [repoDiffTargets, pullRequests]);

  const pullRequestMap = useMemo(
    () => new Map(pullRequests.map((pr) => [pr.repoFullName, pr] as const)),
    [pullRequests],
  );

  const diffQueries = useQueries({
    queries: repoDiffTargets.map((target) => ({
      ...gitDiffQueryOptions({
        repoFullName: target.repoFullName,
        baseRef: target.baseRef,
        headRef: target.headRef ?? "",
      }),
      enabled:
        Boolean(target.repoFullName?.trim()) && Boolean(target.headRef?.trim()),
    })),
  });

  const hasChanges =
    repoDiffTargets.length === 0
      ? false
      : diffQueries.some((query, index) => {
        if (!repoDiffTargets[index]?.headRef) {
          return false;
        }
        return (query.data ?? []).length > 0;
      });

  const navigateToPrs = (
    prs: Array<{
      url?: string | null;
      repoFullName?: string;
      number?: number;
    }>,
  ) => {
    prs.forEach((pr) => {
      // Open GitHub URL directly in new tab if available
      if (pr.url) {
        window.open(pr.url, '_blank', 'noopener,noreferrer');
      } else if (pr.repoFullName && pr.number) {
        // Fallback to internal viewer if URL not available
        const [owner = "", repo = ""] = pr.repoFullName.split("/", 2);
        navigate({
          to: "/$teamSlugOrId/prs-only/$owner/$repo/$number",
          params: {
            teamSlugOrId,
            owner,
            repo,
            number: String(pr.number),
          },
        });
      }
    });
  };

  const summarizeResults = (
    results: Array<{ repoFullName: string; error?: string | undefined }>,
  ) => {
    const total = results.length;
    const successCount = results.filter((result) => !result.error).length;
    if (total === 0) {
      return "No repositories updated";
    }
    if (successCount === total) {
      return `${total} ${total === 1 ? "repository" : "repositories"} updated`;
    }
    return `${successCount}/${total} repositories updated`;
  };

  const hasMultipleRepos = repoFullNames.length > 1;
  const viewLabel = hasMultipleRepos ? "View PRs" : "View PR";
  const openingLabel = hasMultipleRepos ? "Opening PRs..." : "Opening PR...";
  const openedLabel = hasMultipleRepos ? "PRs updated" : "PR updated";
  const openingDraftLabel = hasMultipleRepos
    ? "Creating draft PRs..."
    : "Creating draft PR...";
  const openedDraftLabel = hasMultipleRepos
    ? "Draft PRs updated"
    : "Draft PR updated";
  const openErrorLabel = hasMultipleRepos
    ? "Failed to open PRs"
    : "Failed to open PR";
  const draftErrorLabel = hasMultipleRepos
    ? "Failed to create draft PRs"
    : "Failed to create draft PR";
  const mergeLoadingLabel = (method: MergeMethod) =>
    hasMultipleRepos
      ? `Merging PRs (${method})...`
      : `Merging PR (${method})...`;
  const mergedLabel = hasMultipleRepos ? "PRs merged" : "PR merged";
  const mergeErrorLabel = hasMultipleRepos
    ? "Failed to merge PRs"
    : "Failed to merge PR";
  const mergeBranchErrorLabel = "Failed to merge branch";

  const openPrMutation = useMutation<
    PostApiIntegrationsGithubPrsOpenResponse,
    DefaultError,
    Options<PostApiIntegrationsGithubPrsOpenData>,
    ToastFeedbackContext
  >({
    ...postApiIntegrationsGithubPrsOpenMutation(),
    onMutate: () => {
      const toastId = toast.loading(openingLabel);
      return { toastId } satisfies ToastFeedbackContext;
    },
    onSuccess: (response, _variables, context) => {
      const actionable = response.results.filter(
        (result) =>
          !result.error &&
          Boolean(result.repoFullName?.trim()) &&
          Boolean(result.number),
      );

      // Get the PR URL(s) for copying
      const prUrls = actionable
        .map((result) => result.url)
        .filter((url): url is string => Boolean(url));

      toast.success(openedLabel, {
        id: context?.toastId,
        description: summarizeResults(response.results),
        action:
          actionable.length > 0
            ? {
              label: actionable.length === 1 ? "View PR" : "View PRs",
              onClick: () => navigateToPrs(actionable),
            }
            : undefined,
        cancel:
          prUrls.length > 0
            ? {
              label: "Copy URL",
              onClick: () => {
                const urlText = prUrls.join("\n");
                navigator.clipboard
                  .writeText(urlText)
                  .then(() => {
                    toast.success("URL copied to clipboard");
                  })
                  .catch(() => {
                    toast.error("Failed to copy URL");
                  });
              },
            }
            : undefined,
      });
    },
    onError: (error, _variables, context) => {
      toast.error(openErrorLabel, {
        id: context?.toastId,
        description:
          getErrorDescription(error) ??
          (error instanceof Error ? error.message : undefined),
      });
    },
  });

  const handleOpenPRs = () => {
    openPrMutation.mutate({
      body: {
        teamSlugOrId,
        taskRunId,
      },
    });
  };

  const createDraftPrMutation = useMutation<
    PullRequestActionResponse,
    SocketMutationErrorInstance | Error,
    void,
    ToastFeedbackContext
  >({
    mutationFn: () => {
      if (!socket) {
        throw new Error("Socket unavailable");
      }
      return new Promise<PullRequestActionResponse>((resolve, reject) => {
        socket.emit("github-create-draft-pr", { taskRunId }, (resp) => {
          if (resp.success) {
            resolve(resp);
          } else {
            reject(new SocketMutationError(resp.error ?? draftErrorLabel, resp));
          }
        });
      });
    },
    onMutate: () => {
      const toastId = toast.loading(openingDraftLabel);
      return { toastId };
    },
    onSuccess: (response, _variables, context) => {
      const actionable = response.results.filter(
        (result) => result.url && !result.error,
      );
      if (actionable.length > 0) {
        navigateToPrs(actionable);
      }
      toast.success(openedDraftLabel, {
        id: context?.toastId,
        description: summarizeResults(response.results),
        action:
          actionable.length > 0
            ? {
              label: actionable.length === 1 ? "View draft" : "View drafts",
              onClick: () => navigateToPrs(actionable),
            }
            : undefined,
      });
    },
    onError: (error, _variables, context) => {
      toast.error(draftErrorLabel, {
        id: context?.toastId,
        description: getErrorDescription(error),
      });
    },
  });

  const mergePrMutation = useMutation<
    PostApiIntegrationsGithubPrsMergeResponse,
    DefaultError,
    Options<PostApiIntegrationsGithubPrsMergeData>,
    ToastFeedbackContext
  >({
    ...postApiIntegrationsGithubPrsMergeMutation(),
    onMutate: (variables) => {
      const method = variables.body?.method ?? "merge";
      const toastId = toast.loading(mergeLoadingLabel(method));
      return { toastId } satisfies ToastFeedbackContext;
    },
    onSuccess: (response, _variables, context) => {
      toast.success(mergedLabel, {
        id: context?.toastId,
        description: summarizeResults(response.results),
      });
    },
    onError: (error, _variables, context) => {
      toast.error(mergeErrorLabel, {
        id: context?.toastId,
        description:
          getErrorDescription(error) ??
          (error instanceof Error ? error.message : undefined),
      });
    },
  });

  const mergeBranchMutation = useMutation<
    MergeBranchResponse,
    SocketMutationErrorInstance | Error,
    void,
    ToastFeedbackContext
  >({
    mutationFn: () => {
      if (!socket) {
        throw new Error("Socket unavailable");
      }
      return new Promise<MergeBranchResponse>((resolve, reject) => {
        socket.emit("github-merge-branch", { taskRunId }, (resp) => {
          if (resp.success) {
            resolve(resp);
          } else {
            reject(
              new SocketMutationError(
                resp.error ?? mergeBranchErrorLabel,
                resp,
              ),
            );
          }
        });
      });
    },
    onMutate: () => {
      const toastId = toast.loading("Merging branch...");
      return { toastId };
    },
    onSuccess: (response, _variables, context) => {
      toast.success("Branch merged", {
        id: context?.toastId,
        description: response.commitSha,
      });
    },
    onError: (error, _variables, context) => {
      toast.error(mergeBranchErrorLabel, {
        id: context?.toastId,
        description: getErrorDescription(error),
      });
    },
  });

  const handleOpenDraftPRs = () => {
    createDraftPrMutation.mutate();
  };

  const handleViewPRs = () => {
    const existing = pullRequests.filter((pr) => pr.url);
    if (existing.length > 0) {
      navigateToPrs(existing);
      return;
    }
    handleOpenDraftPRs();
  };

  const handleMerge = (method: MergeMethod) => {
    mergePrMutation.mutate({
      body: {
        teamSlugOrId,
        taskRunId,
        method,
      },
    });
  };

  const handleMergeBranch = () => {
    mergeBranchMutation.mutate();
  };

  const isOpeningPr = openPrMutation.isPending;
  const isCreatingPr = createDraftPrMutation.isPending;
  const isMerging =
    mergePrMutation.isPending || mergeBranchMutation.isPending;

  const hasAnyRemotePr = pullRequests.some((pr) => pr.url);

  const renderRepoDropdown = () => (
    <Dropdown.Root>
      <Dropdown.Trigger
        aria-label={`${viewLabel} by repository`}
        className={cn(
          "flex items-center justify-center px-2 py-1 h-[26px]",
          "bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white",
          "border border-neutral-300 dark:border-neutral-700",
          "rounded-r hover:bg-neutral-300 dark:hover:bg-neutral-700",
          "disabled:opacity-60 disabled:cursor-not-allowed",
        )}
        disabled={repoFullNames.every(
          (repoName) => !pullRequestMap.get(repoName)?.url,
        )}
      >
        <ChevronDown className="w-3.5 h-3.5" />
      </Dropdown.Trigger>
      <Dropdown.Portal>
        <Dropdown.Positioner sideOffset={5}>
          <Dropdown.Popup className="min-w-[200px]">
            <Dropdown.Arrow />
            {repoFullNames.map((repoName) => {
              const pr = pullRequestMap.get(repoName);
              const hasUrl = Boolean(pr?.url);
              return (
                <Dropdown.Item
                  key={repoName}
                  disabled={!hasUrl}
                  onClick={() => {
                    // Open GitHub URL directly in new tab if available
                    if (pr?.url) {
                      window.open(pr.url, '_blank', 'noopener,noreferrer');
                    } else if (pr?.repoFullName && pr?.number) {
                      // Fallback to internal viewer if URL not available
                      const [owner = "", repo = ""] =
                        pr.repoFullName.split("/", 2);
                      navigate({
                        to: "/$teamSlugOrId/prs-only/$owner/$repo/$number",
                        params: {
                          teamSlugOrId,
                          owner,
                          repo,
                          number: String(pr.number),
                        },
                      });
                    }
                  }}
                >
                  <span className="truncate">{repoName}</span>
                </Dropdown.Item>
              );
            })}
          </Dropdown.Popup>
        </Dropdown.Positioner>
      </Dropdown.Portal>
    </Dropdown.Root>
  );

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
          onMerge={prIsOpen ? handleMerge : () => {
            void handleOpenPRs();
          }}
          isOpen={prIsOpen}
          disabled={
            isOpeningPr ||
            isCreatingPr ||
            isMerging ||
            (!prIsOpen && !hasChanges)
          }
          prCount={repoFullNames.length}
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
      {hasAnyRemotePr ? (
        hasMultipleRepos ? (
          <div className="flex items-stretch">
            <button
              onClick={handleViewPRs}
              className="flex items-center gap-1.5 px-3 py-1 h-[26px] bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 border-r-0 rounded-l hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none disabled:opacity-60 disabled:cursor-not-allowed whitespace-nowrap"
              disabled={isOpeningPr || isCreatingPr || isMerging}
            >
              <ExternalLink className="w-3.5 h-3.5" />
              {viewLabel}
            </button>
            {renderRepoDropdown()}
          </div>
        ) : (
          <button
            onClick={handleViewPRs}
            className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none disabled:opacity-60 disabled:cursor-not-allowed whitespace-nowrap"
            disabled={isOpeningPr || isCreatingPr || isMerging}
          >
            <ExternalLink className="w-3.5 h-3.5" />
            {viewLabel}
          </button>
        )
      ) : (
        <button
          onClick={handleOpenDraftPRs}
          className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none disabled:opacity-60 disabled:cursor-not-allowed whitespace-nowrap"
          disabled={isCreatingPr || isOpeningPr || isMerging || !hasChanges}
        >
          <ExternalLink className="w-3.5 h-3.5" />
          {isCreatingPr
            ? openingDraftLabel
            : hasMultipleRepos
              ? "Open draft PRs"
              : "Open draft PR"}
        </button>
      )}
    </>
  );
}
