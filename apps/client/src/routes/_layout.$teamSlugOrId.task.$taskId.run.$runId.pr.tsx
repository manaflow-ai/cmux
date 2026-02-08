import { FloatingPane } from "@/components/floating-pane";
import { PersistentWebView } from "@/components/persistent-webview";
import { PullRequestDetailView } from "@/components/prs/PullRequestDetailView";
import { isElectron } from "@/lib/electron";
import { getTaskRunPullRequestPersistKey } from "@/lib/persistent-webview-keys";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useEffect, useMemo, useState } from "react";
import clsx from "clsx";
import z from "zod";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";

function parseRepoFullName(
  repoFullName: string | null | undefined,
): { owner: string; repo: string } | null {
  if (!repoFullName) return null;
  const [owner = "", repo = ""] = repoFullName.split("/", 2);
  if (!owner || !repo) return null;
  return { owner, repo };
}

function parseGithubPullRequestUrl(
  url: string | null | undefined,
): { owner: string; repo: string; number: number } | null {
  if (!url) return null;
  const lower = url.toLowerCase();
  if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
    return null;
  }

  try {
    const u = new URL(url);
    const parts = u.pathname.split("/").filter(Boolean);
    const pullIdx = parts.indexOf("pull");
    if (pullIdx < 2 || parts.length <= pullIdx + 1) return null;

    const owner = parts[pullIdx - 2] ?? "";
    const repo = parts[pullIdx - 1] ?? "";
    const numberRaw = parts[pullIdx + 1] ?? "";
    const number = Number(numberRaw);
    if (!owner || !repo || !Number.isFinite(number)) return null;

    return { owner, repo, number };
  } catch (error) {
    console.error("Failed to parse GitHub pull request URL:", error);
    return null;
  }
}

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/pr"
)({
  component: RunPullRequestPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: async (opts) => {
    const { teamSlugOrId, taskId } = opts.params;
    convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.getByTask,
      args: {
        teamSlugOrId,
        taskId,
      },
    });

    convexQueryClient.convexClient.prewarmQuery({
      query: api.tasks.getById,
      args: { teamSlugOrId, id: taskId },
    });
  },
});

function RunPullRequestPage() {
  const { taskId, teamSlugOrId, runId } = Route.useParams();

  const task = useQuery(api.tasks.getById, {
    teamSlugOrId,
    id: taskId,
  });

  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });

  // Get the specific run from the URL parameter
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  const pullRequests = useMemo(
    () => selectedRun?.pullRequests ?? [],
    [selectedRun?.pullRequests]
  );
  const [activeRepo, setActiveRepo] = useState<string | null>(
    () => pullRequests[0]?.repoFullName ?? null
  );

  useEffect(() => {
    if (pullRequests.length === 0) {
      if (activeRepo !== null) {
        setActiveRepo(null);
      }
      return;
    }
    if (
      !activeRepo ||
      !pullRequests.some((pr) => pr.repoFullName === activeRepo)
    ) {
      setActiveRepo(pullRequests[0]?.repoFullName ?? null);
    }
  }, [pullRequests, activeRepo]);

  const activePullRequest = useMemo(() => {
    if (!activeRepo) return null;
    return pullRequests.find((pr) => pr.repoFullName === activeRepo) ?? null;
  }, [pullRequests, activeRepo]);

  const aggregatedUrl = selectedRun?.pullRequestUrl;
  const isPending = aggregatedUrl === "pending";
  const fallbackPullRequestUrl =
    aggregatedUrl && aggregatedUrl !== "pending" ? aggregatedUrl : undefined;

  const persistKey = useMemo(() => {
    const key = activeRepo ? `${runId}:${activeRepo}` : runId;
    return getTaskRunPullRequestPersistKey(key);
  }, [runId, activeRepo]);
  const paneBorderRadius = 6;

  const headerTitle =
    pullRequests.length > 1 ? "Pull Requests" : "Pull Request";
  const activeUrl = activePullRequest?.url ?? fallbackPullRequestUrl;

  const activePullRequestTarget = useMemo(() => {
    const repoFromName = parseRepoFullName(activePullRequest?.repoFullName);
    const url = activePullRequest?.url ?? fallbackPullRequestUrl;
    const parsedFromUrl = parseGithubPullRequestUrl(url);

    const owner = repoFromName?.owner ?? parsedFromUrl?.owner;
    const repo = repoFromName?.repo ?? parsedFromUrl?.repo;
    const number =
      activePullRequest?.number ??
      parsedFromUrl?.number ??
      (pullRequests.length <= 1 ? selectedRun?.pullRequestNumber : undefined);

    if (!owner || !repo) return null;
    if (typeof number !== "number" || !Number.isFinite(number)) return null;
    return { owner, repo, number };
  }, [
    activePullRequest?.number,
    activePullRequest?.repoFullName,
    activePullRequest?.url,
    fallbackPullRequestUrl,
    pullRequests.length,
    selectedRun?.pullRequestNumber,
  ]);

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          {/* Header */}
          <div className="border-b border-neutral-200 dark:border-neutral-800 px-4 py-3 flex items-center justify-between shrink-0">
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                {headerTitle}
              </h2>
              {selectedRun?.pullRequestState && (
                <span className="text-xs px-2 py-0.5 rounded-full bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400">
                  {selectedRun.pullRequestState}
                </span>
              )}
            </div>
            {activeUrl && (
              <a
                href={activeUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-blue-600 dark:text-blue-400 hover:underline flex items-center gap-1"
              >
                Open on GitHub
                <svg
                  className="w-3 h-3"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                  />
                </svg>
              </a>
            )}
          </div>

          {/* Task description */}
          {task?.text && (
            <div className="px-4 py-2 border-b border-neutral-200 dark:border-neutral-800">
              <div className="text-xs text-neutral-600 dark:text-neutral-300">
                <span className="text-neutral-500 dark:text-neutral-400 select-none">
                  Task:{" "}
                </span>
                <span className="font-medium">{task.text}</span>
              </div>
            </div>
          )}

          {/* Main content */}
          <div className="flex-1 bg-white dark:bg-neutral-950">
            {pullRequests.length > 0 ? (
              <div className="flex h-full flex-col">
                <div className="flex flex-wrap border-b border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900/30">
                  {pullRequests.map((pr) => {
                    const isActive = pr.repoFullName === activeRepo;
                    return (
                      <button
                        key={pr.repoFullName}
                        onClick={() => setActiveRepo(pr.repoFullName)}
                        className={clsx(
                          "flex min-w-[160px] items-center justify-between gap-2 px-3 py-2 text-xs transition-colors",
                          isActive
                            ? "border-b-2 border-neutral-900 bg-white text-neutral-900 dark:border-neutral-100 dark:bg-neutral-950 dark:text-neutral-100"
                            : "border-b-2 border-transparent text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
                        )}
                      >
                        <span className="truncate">{pr.repoFullName}</span>
                        <span className="text-[10px] uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                          {pr.state ?? "none"}
                        </span>
                      </button>
                    );
                  })}
                </div>
                <div className="flex-1">
                  {!isElectron ? (
                    activePullRequestTarget ? (
                      <div className="w-full h-full border-0 bg-white dark:bg-neutral-900">
                        <PullRequestDetailView
                          key={`${activePullRequestTarget.owner}/${activePullRequestTarget.repo}#${activePullRequestTarget.number}`}
                          teamSlugOrId={teamSlugOrId}
                          owner={activePullRequestTarget.owner}
                          repo={activePullRequestTarget.repo}
                          number={String(activePullRequestTarget.number)}
                        />
                      </div>
                    ) : activeUrl ? (
                      <div className="flex h-full items-center justify-center px-6 text-sm text-neutral-500 dark:text-neutral-400">
                        Could not load this pull request here.{" "}
                        <a
                          href={activeUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="ml-1 text-blue-600 dark:text-blue-400 hover:underline"
                        >
                          Open on GitHub
                        </a>
                        .
                      </div>
                    ) : (
                      <div className="flex h-full items-center justify-center px-6 text-sm text-neutral-500 dark:text-neutral-400">
                        No pull request is available for this repository yet.
                      </div>
                    )
                  ) : activePullRequest?.url ? (
                    <PersistentWebView
                      persistKey={persistKey}
                      src={activePullRequest.url}
                      className="w-full h-full border-0"
                      borderRadius={paneBorderRadius}
                      forceWebContentsViewIfElectron
                    />
                  ) : (
                    <div className="flex h-full items-center justify-center px-6 text-sm text-neutral-500 dark:text-neutral-400">
                      No pull request URL available for this repository yet.
                    </div>
                  )}
                </div>
              </div>
            ) : isPending ? (
              <div className="flex flex-col items-center justify-center h-full text-neutral-500 dark:text-neutral-400">
                <div className="w-8 h-8 border-2 border-neutral-300 dark:border-neutral-600 border-t-blue-500 rounded-full animate-spin mb-4" />
                <p className="text-sm">Pull request is being created...</p>
              </div>
            ) : fallbackPullRequestUrl ? (
              !isElectron && activePullRequestTarget ? (
                <div className="w-full h-full border-0 bg-white dark:bg-neutral-900">
                  <PullRequestDetailView
                    key={`${activePullRequestTarget.owner}/${activePullRequestTarget.repo}#${activePullRequestTarget.number}`}
                    teamSlugOrId={teamSlugOrId}
                    owner={activePullRequestTarget.owner}
                    repo={activePullRequestTarget.repo}
                    number={String(activePullRequestTarget.number)}
                  />
                </div>
              ) : (
                <PersistentWebView
                  persistKey={persistKey}
                  src={fallbackPullRequestUrl}
                  className="w-full h-full border-0"
                  borderRadius={paneBorderRadius}
                  forceWebContentsViewIfElectron
                />
              )
            ) : (
              <div className="flex flex-col items-center justify-center h-full text-neutral-500 dark:text-neutral-400">
                <svg
                  className="w-16 h-16 mb-4 text-neutral-300 dark:text-neutral-700"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
                  />
                </svg>
                <p className="text-sm font-medium mb-1">No pull request</p>
                <p className="text-xs text-center">
                  This run doesn't have any associated pull requests yet.
                </p>
              </div>
            )}
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
