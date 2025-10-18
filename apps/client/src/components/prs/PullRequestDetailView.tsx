import { RunDiffSection } from "@/components/RunDiffSection";
import { Dropdown } from "@/components/ui/dropdown";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { api } from "@cmux/convex/api";
import { useQuery as useRQ, useMutation } from "@tanstack/react-query";
import { useQuery as useConvexQuery } from "convex/react";
import { ExternalLink, X, Check, Circle, Clock, AlertCircle, Loader2, ChevronRight, ChevronDown, Copy, GitBranch } from "lucide-react";
import { Suspense, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { useClipboard } from "@mantine/hooks";
import clsx from "clsx";
import { MergeButton, type MergeMethod } from "@/components/ui/merge-button";
import { postApiIntegrationsGithubPrsCloseMutation, postApiIntegrationsGithubPrsMergeSimpleMutation } from "@cmux/www-openapi-client/react-query";
import type { PostApiIntegrationsGithubPrsCloseData, PostApiIntegrationsGithubPrsCloseResponse, PostApiIntegrationsGithubPrsMergeSimpleData, PostApiIntegrationsGithubPrsMergeSimpleResponse, Options } from "@cmux/www-openapi-client";

type PullRequestDetailViewProps = {
  teamSlugOrId: string;
  owner: string;
  repo: string;
  number: string;
};

type DiffControls = {
  expandAll: () => void;
  collapseAll: () => void;
  totalAdditions: number;
  totalDeletions: number;
  expandChecks?: () => void;
  collapseChecks?: () => void;
};

type AdditionsAndDeletionsProps = {
  repoFullName: string;
  ref1: string;
  ref2: string;
};

type WorkflowRunsProps = {
  teamSlugOrId: string;
  repoFullName: string;
  prNumber: number;
  headSha?: string;
};

type CombinedRun = ReturnType<typeof useCombinedWorkflowData>['allRuns'][number];

function useCombinedWorkflowData({ teamSlugOrId, repoFullName, prNumber, headSha }: WorkflowRunsProps) {
  const workflowRuns = useConvexQuery(api.github_workflows.getWorkflowRunsForPr, {
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
    limit: 50,
  });

  const checkRuns = useConvexQuery(api.github_check_runs.getCheckRunsForPr, {
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
    limit: 50,
  });

  const deployments = useConvexQuery(api.github_deployments.getDeploymentsForPr, {
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
    limit: 50,
  });

  const commitStatuses = useConvexQuery(api.github_commit_statuses.getCommitStatusesForPr, {
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
    limit: 50,
  });

  const isLoading = workflowRuns === undefined || checkRuns === undefined || deployments === undefined || commitStatuses === undefined;

  const allRuns = useMemo(() => [
    ...(workflowRuns || []).map(run => ({ ...run, type: 'workflow', name: run.workflowName, timestamp: run.runStartedAt, url: run.htmlUrl })),
    ...(checkRuns || []).map(run => {
      const url = run.htmlUrl || `https://github.com/${repoFullName}/pull/${prNumber}/checks?check_run_id=${run.checkRunId}`;
      return { ...run, type: 'check', timestamp: run.startedAt, url };
    }),
    ...(deployments || []).filter(dep => dep.environment !== 'Preview').map(dep => ({
      ...dep,
      type: 'deployment',
      name: dep.description || dep.environment || 'Deployment',
      timestamp: dep.createdAt,
      status: dep.state === 'pending' || dep.state === 'queued' || dep.state === 'in_progress' ? 'in_progress' : 'completed',
      conclusion: dep.state === 'success' ? 'success' : dep.state === 'failure' || dep.state === 'error' ? 'failure' : undefined,
      url: dep.targetUrl
    })),
    ...(commitStatuses || []).map(status => ({
      ...status,
      type: 'status',
      name: status.context,
      timestamp: status.updatedAt,
      status: status.state === 'pending' ? 'in_progress' : 'completed',
      conclusion: status.state === 'success' ? 'success' : status.state === 'failure' || status.state === 'error' ? 'failure' : undefined,
      url: status.targetUrl
    })),
  ], [workflowRuns, checkRuns, deployments, commitStatuses, repoFullName, prNumber]);

  return { allRuns, isLoading };
}

function WorkflowRuns({ allRuns, isLoading }: { allRuns: CombinedRun[]; isLoading: boolean }) {
  if (isLoading || allRuns.length === 0) {
    return null;
  }

  const hasAnyRunning = allRuns.some(
    (run) => run.status === "in_progress" || run.status === "queued" || run.status === "waiting" || run.status === "pending"
  );
  const hasAnyFailure = allRuns.some(
    (run) => run.conclusion === "failure" || run.conclusion === "timed_out" || run.conclusion === "action_required"
  );
  const allPassed = allRuns.length > 0 && allRuns.every(
    (run) => run.conclusion === "success" || run.conclusion === "neutral" || run.conclusion === "skipped"
  );

  const { icon, colorClass, statusText } = hasAnyRunning
    ? {
      icon: <Clock className="w-[10px] h-[10px] animate-pulse" />,
      colorClass: "text-yellow-600 dark:text-yellow-400",
      statusText: "Running",
    }
    : hasAnyFailure
      ? {
        icon: <X className="w-[10px] h-[10px]" />,
        colorClass: "text-red-600 dark:text-red-400",
        statusText: "Failed",
      }
      : allPassed
        ? {
          icon: <Check className="w-[10px] h-[10px]" />,
          colorClass: "text-green-600 dark:text-green-400",
          statusText: "Passed",
        }
        : {
          icon: <Circle className="w-[10px] h-[10px]" />,
          colorClass: "text-neutral-500 dark:text-neutral-400",
          statusText: "Checks",
        };

  return (
    <div className={`flex items-center gap-1 ml-2 shrink-0 ${colorClass}`}>
      {icon}
      <span className="text-[9px] font-medium select-none">{statusText}</span>
    </div>
  );
}

function WorkflowRunsSection({
  allRuns,
  isLoading,
  isExpanded,
  onToggle,
}: {
  allRuns: CombinedRun[];
  isLoading: boolean;
  isExpanded: boolean;
  onToggle: () => void;
}) {
  const sortedRuns = useMemo(() => allRuns.slice().sort((a, b) => {
    const getStatusPriority = (run: typeof a) => {
      if (run.conclusion === "failure" || run.conclusion === "timed_out" || run.conclusion === "action_required") return 0;
      if (run.status === "in_progress" || run.status === "queued" || run.status === "waiting" || run.status === "pending") return 1;
      if (run.conclusion === "success" || run.conclusion === "neutral" || run.conclusion === "skipped") return 2;
      if (run.conclusion === "cancelled") return 3;
      return 4;
    };

    const priorityA = getStatusPriority(a);
    const priorityB = getStatusPriority(b);

    if (priorityA !== priorityB) {
      return priorityA - priorityB;
    }

    return (b.timestamp ?? 0) - (a.timestamp ?? 0);
  }), [allRuns]);

  const runningRuns = sortedRuns.filter(
    (run) => run.status === "in_progress" || run.status === "queued" || run.status === "waiting" || run.status === "pending"
  );
  const hasAnyRunning = runningRuns.length > 0;
  const failedRuns = sortedRuns.filter(
    (run) => run.conclusion === "failure" || run.conclusion === "timed_out" || run.conclusion === "action_required"
  );
  const hasAnyFailure = failedRuns.length > 0;
  const passedRuns = sortedRuns.filter(
    (run) => run.conclusion === "success" || run.conclusion === "neutral" || run.conclusion === "skipped"
  );
  const allPassed = sortedRuns.length > 0 && passedRuns.length === sortedRuns.length;

  if (isLoading) {
    return (
      <div>
        <div className="w-full flex items-center pl-3 pr-2.5 py-1.5 border-y border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900">
          <div className="flex items-center" style={{ width: '20px' }}>
            <div className="w-3.5 h-3.5 bg-neutral-200 dark:bg-neutral-700 rounded animate-pulse" />
          </div>
          <div className="flex items-center" style={{ width: '20px' }}>
            <div className="w-3 h-3 bg-neutral-200 dark:bg-neutral-700 rounded animate-pulse" />
          </div>
          <div className="h-3 w-24 bg-neutral-200 dark:bg-neutral-700 rounded animate-pulse" />
        </div>
      </div>
    );
  }

  if (allRuns.length === 0) {
    return null;
  }

  const { summaryIcon, summaryText, summaryColorClass } = hasAnyRunning
    ? {
      summaryIcon: <Loader2 className="w-3 h-3 animate-spin" strokeWidth={2} />,
      summaryText: (() => {
        const parts: string[] = [];
        if (passedRuns.length > 0) {
          parts.push(`${passedRuns.length} passed`);
        }
        if (failedRuns.length > 0) {
          parts.push(`${failedRuns.length} failed`);
        }
        parts.push(`${runningRuns.length} running`);
        return parts.join(", ");
      })(),
      summaryColorClass: "text-yellow-600 dark:text-yellow-500",
    }
    : hasAnyFailure
      ? {
        summaryIcon: <X className="w-3 h-3" strokeWidth={2} />,
        summaryText: `${failedRuns.length} ${failedRuns.length === 1 ? "check" : "checks"} failed`,
        summaryColorClass: "text-red-600 dark:text-red-500",
      }
      : allPassed
        ? {
          summaryIcon: <Check className="w-3 h-3" strokeWidth={2} />,
          summaryText: "All checks passed",
          summaryColorClass: "text-green-600 dark:text-green-500",
        }
        : {
          summaryIcon: <Circle className="w-3 h-3" strokeWidth={2} />,
          summaryText: `${sortedRuns.length} ${sortedRuns.length === 1 ? "check" : "checks"}`,
          summaryColorClass: "text-neutral-500 dark:text-neutral-400",
        };

  const getStatusIcon = (status?: string, conclusion?: string) => {
    if (conclusion === "success") {
      return <Check className="w-3 h-3 text-green-600 dark:text-green-400" strokeWidth={2} />;
    }
    if (conclusion === "failure") {
      return <X className="w-3 h-3 text-red-600 dark:text-red-400" strokeWidth={2} />;
    }
    if (conclusion === "cancelled") {
      return <Circle className="w-3 h-3 text-neutral-500 dark:text-neutral-400" strokeWidth={2} />;
    }
    if (status === "in_progress" || status === "queued") {
      return <Loader2 className="w-3 h-3 text-yellow-600 dark:text-yellow-500 animate-spin" strokeWidth={2} />;
    }
    return <AlertCircle className="w-3 h-3 text-neutral-500 dark:text-neutral-400" strokeWidth={2} />;
  };

  const formatTimeAgo = (timestamp?: number) => {
    if (!timestamp) return "";
    const seconds = Math.floor((Date.now() - timestamp) / 1000);
    if (seconds < 60) return "just now";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return `${days}d ago`;
  };

  const getStatusDescription = (run: typeof allRuns[0]) => {
    const parts: string[] = [];

    if (run.conclusion === "success") {
      if (run.type === 'workflow' && 'runDuration' in run && run.runDuration) {
        const mins = Math.floor(run.runDuration / 60);
        const secs = run.runDuration % 60;
        parts.push(`Successful in ${mins}m ${secs}s`);
      } else {
        parts.push("Successful");
      }
    } else if (run.conclusion === "failure") {
      parts.push("Failed");
    } else if (run.conclusion === "cancelled") {
      parts.push("Cancelled");
    } else if (run.conclusion === "skipped") {
      parts.push("Skipped");
    } else if (run.conclusion === "timed_out") {
      parts.push("Timed out");
    } else if (run.conclusion === "action_required") {
      parts.push("Action required");
    } else if (run.conclusion === "neutral") {
      parts.push("Neutral");
    } else if (run.status === "in_progress") {
      parts.push("In progress");
    } else if (run.status === "queued") {
      parts.push("Queued");
    } else if (run.status === "waiting") {
      parts.push("Waiting");
    } else if (run.status === "pending") {
      parts.push("Pending");
    }

    const timeAgo = formatTimeAgo(run.timestamp);
    if (timeAgo) {
      parts.push(timeAgo);
    }

    return parts.join(" — ");
  };

  return (
    <div>
      <button
        onClick={onToggle}
        className="w-full flex items-center pl-3 pr-2.5 py-1.5 border-y border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900 hover:bg-neutral-100 dark:hover:bg-neutral-800/50 transition-colors group"
      >
        <div className="flex items-center" style={{ width: '20px' }}>
          <div className="text-neutral-400 dark:text-neutral-500 group-hover:text-neutral-600 dark:group-hover:text-neutral-400">
            {isExpanded ? (
              <ChevronDown className="w-3.5 h-3.5" />
            ) : (
              <ChevronRight className="w-3.5 h-3.5" />
            )}
          </div>
        </div>
        <div className="flex items-center" style={{ width: '20px' }}>
          <div className={`${summaryColorClass}`}>
            {summaryIcon}
          </div>
        </div>
        <span className={`text-[11px] font-semibold ${summaryColorClass}`}>{summaryText}</span>
      </button>
      {isExpanded && (
        <div className="divide-y divide-neutral-200 dark:divide-neutral-800 border-b border-neutral-200 dark:border-neutral-800">
          {sortedRuns.map((run) => {
            const appLabel = run.type === 'check' && 'appSlug' in run && run.appSlug
              ? `[${run.appSlug}]`
              : run.type === 'check' && 'appName' in run && run.appName
                ? `[${run.appName}]`
                : run.type === 'deployment'
                  ? '[deployment]'
                  : run.type === 'status'
                    ? '[status]'
                    : null;

            return (
              <a
                key={`${run.type}-${run._id}`}
                href={run.url || '#'}
                target="_blank"
                rel="noreferrer"
                className="flex items-center justify-between gap-2 pl-8 pr-3 py-1 hover:bg-neutral-50 dark:hover:bg-neutral-800/50 transition-colors group"
              >
                <div className="flex items-center gap-1.5 flex-1 min-w-0">
                  <div className="shrink-0">
                    {getStatusIcon(run.status, run.conclusion)}
                  </div>
                  <div className="flex-1 min-w-0 flex items-center gap-1.5">
                    <div className="text-[11px] text-neutral-900 dark:text-neutral-100 font-normal truncate">
                      {run.name}
                    </div>
                    {appLabel && (
                      <span className="text-[10px] text-neutral-500 dark:text-neutral-500 shrink-0">
                        {appLabel}
                      </span>
                    )}
                  </div>
                  <div className="text-[11px] text-neutral-600 dark:text-neutral-400 shrink-0">
                    {getStatusDescription(run)}
                  </div>
                </div>
                {run.url && (
                  <div className="p-1 shrink-0">
                    <ExternalLink className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-400" />
                  </div>
                )}
              </a>
            );
          })}
        </div>
      )}
    </div>
  );
}

function AdditionsAndDeletions({
  repoFullName,
  ref1,
  ref2,
}: AdditionsAndDeletionsProps) {
  const diffsQuery = useRQ(
    gitDiffQueryOptions({
      repoFullName,
      baseRef: normalizeGitRef(ref1),
      headRef: normalizeGitRef(ref2),
    })
  );

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
      {diffsQuery.isPending ? (
        <>
          <span className="inline-block rounded bg-neutral-200 dark:bg-neutral-800 min-w-[20px] h-[14px] animate-pulse" />
          <span className="inline-block rounded bg-neutral-200 dark:bg-neutral-800 min-w-[20px] h-[14px] animate-pulse" />
        </>
      ) : totals ? (
        <>
          <span className="text-green-600 dark:text-green-400 font-medium select-none">
            +{totals.add}
          </span>
          <span className="text-red-600 dark:text-red-400 font-medium select-none">
            -{totals.del}
          </span>
        </>
      ) : null}
    </div>
  );
}


export function PullRequestDetailView({
  teamSlugOrId,
  owner,
  repo,
  number,
}: PullRequestDetailViewProps) {
  const clipboard = useClipboard({ timeout: 2000 });

  const currentPR = useConvexQuery(api.github_prs.getPullRequest, {
    teamSlugOrId,
    repoFullName: `${owner}/${repo}`,
    number: Number(number),
  });

  const fileOutputs = useConvexQuery(api.codeReview.listFileOutputsForPr, {
    teamSlugOrId,
    repoFullName: `${owner}/${repo}`,
    prNumber: Number(number),
    commitRef: currentPR?.headSha ?? undefined,
  });

  const commitRefForLogging = currentPR?.headSha ?? null;

  useEffect(() => {
    if (fileOutputs && fileOutputs.length > 0) {
      console.log("[code-review] File outputs", {
        repoFullName: `${owner}/${repo}`,
        prNumber: Number(number),
        commitRef: commitRefForLogging,
        outputs: fileOutputs,
      });
    }
  }, [fileOutputs, commitRefForLogging, owner, repo, number]);

  const workflowData = useCombinedWorkflowData({
    teamSlugOrId,
    repoFullName: currentPR?.repoFullName || '',
    prNumber: currentPR?.number || 0,
    headSha: currentPR?.headSha,
  });

  const hasAnyFailure = useMemo(() => {
    return workflowData.allRuns.some(
      (run) => run.conclusion === "failure" || run.conclusion === "timed_out" || run.conclusion === "action_required"
    );
  }, [workflowData.allRuns]);

  const [checksExpandedOverride, setChecksExpandedOverride] = useState<boolean | null>(null);
  const checksExpanded = checksExpandedOverride !== null ? checksExpandedOverride : hasAnyFailure;

  const handleToggleChecks = () => {
    setChecksExpandedOverride(!checksExpanded);
  };

  const expandAllChecks = () => setChecksExpandedOverride(true);
  const collapseAllChecks = () => setChecksExpandedOverride(false);

  const [diffControls, setDiffControls] = useState<DiffControls | null>(null);

  const handleDiffControlsChange = (controls: DiffControls | null) => {
    setDiffControls(controls ? {
      ...controls,
      expandChecks: expandAllChecks,
      collapseChecks: collapseAllChecks,
    } : null);
  };

  const closePrMutation = useMutation<
    PostApiIntegrationsGithubPrsCloseResponse,
    Error,
    Options<PostApiIntegrationsGithubPrsCloseData>
  >({
    ...postApiIntegrationsGithubPrsCloseMutation(),
    onSuccess: (data) => {
      toast.success(data.message || `PR #${currentPR?.number} closed successfully`);
    },
    onError: (error) => {
      toast.error(`Failed to close PR: ${error instanceof Error ? error.message : String(error)}`);
    },
  });

  const mergePrMutation = useMutation<
    PostApiIntegrationsGithubPrsMergeSimpleResponse,
    Error,
    Options<PostApiIntegrationsGithubPrsMergeSimpleData>
  >({
    ...postApiIntegrationsGithubPrsMergeSimpleMutation(),
    onSuccess: (data) => {
      toast.success(data.message || `PR #${currentPR?.number} merged successfully`);
    },
    onError: (error) => {
      toast.error(`Failed to merge PR: ${error instanceof Error ? error.message : String(error)}`);
    },
  });

  const handleClosePR = () => {
    if (!currentPR) return;
    closePrMutation.mutate({
      body: {
        teamSlugOrId,
        owner,
        repo,
        number: currentPR.number,
      },
    });
  };

  const handleMergePR = (method: MergeMethod) => {
    if (!currentPR) return;
    mergePrMutation.mutate({
      body: {
        teamSlugOrId,
        owner,
        repo,
        number: currentPR.number,
        method,
      },
    });
  };

  if (!currentPR) {
    return (
      <div className="h-full w-full flex items-center justify-center text-neutral-500 dark:text-neutral-400">
        PR not found
      </div>
    );
  }

  const gitDiffViewerClassNames = {
    fileDiffRow: { button: "top-[56px]" },
  };

  return (
    <div className="flex flex-1 min-h-0 flex-col">
      <div className="flex-1 min-h-0">
        <div className="px-0 py-0">
          <div className="bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white px-3.5 sticky top-0 z-[var(--z-sticky)] py-2">
            <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 gap-y-1">
              <div className="col-start-1 row-start-1 flex items-center gap-2 relative min-w-0">
                <h1
                  className="text-sm font-bold truncate min-w-0"
                  title={currentPR.title}
                >
                  {currentPR.title}
                </h1>
                <Suspense
                  fallback={
                    <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0" />
                  }
                >
                  <AdditionsAndDeletions
                    repoFullName={currentPR.repoFullName}
                    ref1={currentPR.baseRef || ""}
                    ref2={currentPR.headRef || ""}
                  />
                </Suspense>
                <Suspense fallback={null}>
                  <WorkflowRuns
                    allRuns={workflowData.allRuns}
                    isLoading={workflowData.isLoading}
                  />
                </Suspense>
              </div>

              <div className="col-start-3 row-start-1 row-span-2 self-center flex items-center gap-2 shrink-0">
                {currentPR.state === "open" && !currentPR.merged && (
                  <>
                    <MergeButton
                      onMerge={handleMergePR}
                      isOpen={true}
                      disabled={
                        mergePrMutation.isPending ||
                        closePrMutation.isPending
                      }
                      isLoading={mergePrMutation.isPending}
                    />
                    <button
                      onClick={handleClosePR}
                      disabled={mergePrMutation.isPending || closePrMutation.isPending}
                      className="flex items-center gap-1.5 px-3 py-1 h-[26px] bg-[#cf222e] dark:bg-[#da3633] text-white rounded hover:bg-[#cf222e]/90 dark:hover:bg-[#da3633]/90 disabled:opacity-50 disabled:cursor-not-allowed font-medium text-xs select-none whitespace-nowrap transition-colors"
                    >
                      {closePrMutation.isPending ? (
                        <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      ) : (
                        <X className="w-3.5 h-3.5" />
                      )}
                      {closePrMutation.isPending ? "Closing..." : "Close PR"}
                    </button>
                  </>
                )}
                {currentPR.htmlUrl ? (
                  <a
                    className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none whitespace-nowrap"
                    href={currentPR.htmlUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <ExternalLink className="w-3.5 h-3.5" />
                    Open on GitHub
                  </a>
                ) : null}
                <Dropdown.Root>
                  <Dropdown.Trigger
                    className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
                    aria-label="More actions"
                  >
                    ⋯
                  </Dropdown.Trigger>
                  <Dropdown.Portal>
                    <Dropdown.Positioner sideOffset={5}>
                      <Dropdown.Popup>
                        <Dropdown.Arrow />
                        <Dropdown.Item
                          onClick={() => {
                            diffControls?.expandAll?.();
                            diffControls?.expandChecks?.();
                          }}
                        >
                          Expand all
                        </Dropdown.Item>
                        <Dropdown.Item
                          onClick={() => {
                            diffControls?.collapseAll?.();
                            diffControls?.collapseChecks?.();
                          }}
                        >
                          Collapse all
                        </Dropdown.Item>
                      </Dropdown.Popup>
                    </Dropdown.Positioner>
                  </Dropdown.Portal>
                </Dropdown.Root>
              </div>

              <div className="col-start-1 row-start-2 col-span-2 flex items-center gap-2 text-xs text-neutral-400 min-w-0">
                <span className="font-mono text-neutral-600 dark:text-neutral-300 truncate min-w-0 max-w-full select-none text-[11px]">
                  {currentPR.repoFullName}#{currentPR.number} •{" "}
                  {currentPR.authorLogin || ""}
                </span>
                <span className="text-neutral-500 dark:text-neutral-600 select-none">
                  •
                </span>
                <span className="font-mono text-[11px] text-neutral-600 dark:text-neutral-300 flex items-center gap-1">
                  <button
                    onClick={() => {
                      if (currentPR.headRef) {
                        clipboard.copy(currentPR.headRef);
                      }
                    }}
                    className="flex items-center gap-1 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors cursor-pointer group"
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
                    {currentPR.headRef || "?"}
                  </button>
                  <span className="select-none">→</span>
                  <span className="font-mono">{currentPR.baseRef || "?"}</span>
                </span>
              </div>
            </div>
          </div>
          <div className="bg-white dark:bg-neutral-950">
            <Suspense fallback={null}>
              <WorkflowRunsSection
                allRuns={workflowData.allRuns}
                isLoading={workflowData.isLoading}
                isExpanded={checksExpanded}
                onToggle={handleToggleChecks}
              />
            </Suspense>
            <Suspense
              fallback={
                <div className="flex items-center justify-center h-full">
                  <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none py-4">
                    Loading diffs...
                  </div>
                </div>
              }
            >
              {currentPR?.repoFullName &&
                currentPR.baseRef &&
                currentPR.headRef ? (
                <RunDiffSection
                  repoFullName={currentPR.repoFullName}
                  ref1={normalizeGitRef(currentPR.baseRef)}
                  ref2={normalizeGitRef(currentPR.headRef)}
                  onControlsChange={handleDiffControlsChange}
                  classNames={gitDiffViewerClassNames}
                />
              ) : (
                <div className="px-6 text-sm text-neutral-600 dark:text-neutral-300">
                  Missing repo or branches to show diff.
                </div>
              )}
            </Suspense>
          </div>
        </div>
      </div>
    </div>
  );
}

export default PullRequestDetailView;
