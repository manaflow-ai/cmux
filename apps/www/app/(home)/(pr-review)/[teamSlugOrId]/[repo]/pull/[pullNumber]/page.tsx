import { Suspense, use } from "react";
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { waitUntil } from "@vercel/functions";
import { type Team } from "@stackframe/stack";

import {
  fetchPullRequest,
  fetchPullRequestFiles,
  toGithubFileChange,
  type GithubPullRequest,
  type GithubFileChange,
} from "@/lib/github/fetch-pull-request";
import { isGithubApiError } from "@/lib/github/errors";
import { isRepoPublic } from "@/lib/github/check-repo-visibility";
import { cn } from "@/lib/utils";
import { stackServerApp } from "@/lib/utils/stack";
import { runSimpleAnthropicReviewStream } from "@/lib/services/code-review/run-simple-anthropic-review";
import {
  getConvexHttpActionBaseUrl,
  startCodeReviewJob,
} from "@/lib/services/code-review/start-code-review";
import { getInstallationForRepo } from "@/lib/utils/github-app-token";
import {
  DiffViewerSkeleton,
  ErrorPanel,
  ReviewChangeSummary,
  ReviewDiffContent,
  ReviewGitHubLinkButton,
} from "../../_components/review-diff-content";
import { PrivateRepoPrompt } from "../../_components/private-repo-prompt";
import { TeamOnboardingPrompt } from "../../_components/team-onboarding-prompt";
import { env } from "@/lib/utils/www-env";

const ENABLE_IMMEDIATE_CODE_REVIEW = false;

type PageParams = {
  teamSlugOrId: string;
  repo: string;
  pullNumber: string;
};

type PageProps = {
  params: Promise<PageParams>;
};

export const dynamic = "force-dynamic";

type GithubAccountAccessor = {
  getAccessToken: () => Promise<{ accessToken?: string | null }>;
};

type GithubConnectedUser = {
  getConnectedAccount: (
    provider: "github"
  ) => Promise<GithubAccountAccessor | null>;
};

async function resolveGithubAccessToken(
  user: GithubConnectedUser | null
): Promise<string | null> {
  if (!user) {
    return null;
  }

  const account = await user.getConnectedAccount("github");
  if (!account) {
    return null;
  }

  const { accessToken } = await account.getAccessToken();
  if (!accessToken || accessToken.trim().length === 0) {
    return null;
  }

  return accessToken;
}

async function getFirstTeam(): Promise<Team | null> {
  const teams = await stackServerApp.listTeams();
  const firstTeam = teams[0];
  if (!firstTeam) {
    return null;
  }
  return firstTeam;
}

export async function generateMetadata({
  params,
}: PageProps): Promise<Metadata> {
  const resolvedParams = await params;
  const {
    teamSlugOrId: githubOwner,
    repo,
    pullNumber: pullNumberRaw,
  } = resolvedParams;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    return {
      title: `Invalid pull request • ${githubOwner}/${repo}`,
    };
  }

  // Check if repo is public
  const repoIsPublic = await isRepoPublic(githubOwner, repo);

  // Get user if available
  const user = await stackServerApp.getUser({ or: "anonymous" });

  // For private repos without user, or if user doesn't have a team, return basic metadata
  if (!repoIsPublic && !user) {
    return {
      title: `${githubOwner}/${repo} · #${pullNumber}`,
    };
  }

  const githubAccessToken = user ? await resolveGithubAccessToken(user) : null;
  const disableCacheForAuthedUser =
    typeof githubAccessToken === "string" && githubAccessToken.trim().length > 0;

  try {
    const pullRequest = await fetchPullRequest(githubOwner, repo, pullNumber, {
      authToken: githubAccessToken,
      disableCache: disableCacheForAuthedUser,
    });

    return {
      title: `${pullRequest.title} · #${pullRequest.number} · ${githubOwner}/${repo}`,
      description: pullRequest.body?.slice(0, 160),
    };
  } catch (error) {
    if (isGithubApiError(error) && error.status === 404) {
      return {
        title: `${githubOwner}/${repo} · #${pullNumber}`,
      };
    }

    throw error;
  }
}

export default async function PullRequestPage({ params }: PageProps) {
  const resolvedParams = await params;

  const {
    teamSlugOrId: githubOwner,
    repo,
    pullNumber: pullNumberRaw,
  } = resolvedParams;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    notFound();
  }

  // Check if the repository is public
  const repoIsPublic = await isRepoPublic(githubOwner, repo);

  // Get user (including anonymous users) - middleware has already checked for cookies
  const user = await stackServerApp.getUser({
    or: "anonymous",
  });

  console.log(
    "[PullRequestPage] user:",
    user?.id,
    "repoIsPublic:",
    repoIsPublic
  );

  // For private repos, reject anonymous users and redirect to auth
  if (!repoIsPublic && user && !user.primaryEmail) {
    const { redirect } = await import("next/navigation");
    redirect(`/${githubOwner}/${repo}/pull/${pullNumber}/auth`);
  }

  // For private repos, require a team. For public repos, teams are optional.
  let selectedTeam: Team | null = null;
  if (!repoIsPublic) {
    // Private repos require authentication and a team
    selectedTeam = user!.selectedTeam || (await getFirstTeam());
    if (!selectedTeam) {
      return (
        <TeamOnboardingPrompt
          githubOwner={resolvedParams.teamSlugOrId}
          repo={resolvedParams.repo}
          pullNumber={parsePullNumber(resolvedParams.pullNumber) ?? 0}
        />
      );
    }
  } else {
    // Public repos: try to get a team but don't require it (for anonymous users)
    selectedTeam = user!.selectedTeam || (await getFirstTeam());
  }

  const githubAccessToken = await resolveGithubAccessToken(user!);
  const disableCacheForAuthedUser =
    typeof githubAccessToken === "string" && githubAccessToken.trim().length > 0;

  let initialPullRequest: GithubPullRequest;
  try {
    initialPullRequest = await fetchPullRequest(githubOwner, repo, pullNumber, {
      authToken: githubAccessToken,
      disableCache: disableCacheForAuthedUser,
    });
  } catch (error) {
    if (isGithubApiError(error) && error.status === 404) {
      // For private repos, check if app is installed
      if (!repoIsPublic && selectedTeam) {
        // Check if GitHub app is installed for this repo
        const installationId = await getInstallationForRepo(
          `${githubOwner}/${repo}`
        );

        // If app is NOT installed, show install prompt
        // If app IS installed, the PR simply doesn't exist
        if (!installationId) {
          return (
            <PrivateRepoPrompt
              teamSlugOrId={selectedTeam.id}
              repo={repo}
              githubOwner={githubOwner}
              githubAppSlug={env.NEXT_PUBLIC_GITHUB_APP_SLUG}
            />
          );
        }
      }

      // App is installed but PR doesn't exist, or public repo PR not found
      notFound();
    }
    throw error;
  }

  const headCommitRef = initialPullRequest.head?.sha ?? null;

  const pullRequestPromise = Promise.resolve(initialPullRequest);
  const pullRequestFilesPromise = fetchPullRequestFiles(
    githubOwner,
    repo,
    pullNumber,
    {
      authToken: githubAccessToken,
      ref: headCommitRef ?? undefined,
    }
  ).then((files) => files.map(toGithubFileChange));

  // Schedule code review in background (non-blocking)
  if (selectedTeam && ENABLE_IMMEDIATE_CODE_REVIEW) {
    scheduleCodeReviewStart({
      teamSlugOrId: selectedTeam.id,
      githubOwner,
      repo,
      pullNumber,
      pullRequestPromise,
    });
  }

  return (
    <div className="min-h-dvh bg-neutral-50 text-neutral-900">
      <div className="flex w-full flex-col gap-3 pb-4 pt-10 px-3">
        <Suspense fallback={<PullRequestHeaderSkeleton />}>
          <PullRequestHeader
            promise={pullRequestPromise}
            githubOwner={githubOwner}
            repo={repo}
          />
        </Suspense>

        <Suspense fallback={<DiffViewerSkeleton />}>
          <PullRequestDiffSection
            filesPromise={pullRequestFilesPromise}
            pullRequestPromise={pullRequestPromise}
            teamSlugOrId={selectedTeam?.id ?? ""}
            githubOwner={githubOwner}
            repo={repo}
            pullNumber={pullNumber}
          />
        </Suspense>
      </div>
    </div>
  );
}

type PullRequestPromise = ReturnType<typeof fetchPullRequest>;

function scheduleCodeReviewStart({
  teamSlugOrId,
  githubOwner,
  repo,
  pullNumber,
  pullRequestPromise,
}: {
  teamSlugOrId: string;
  githubOwner: string;
  repo: string;
  pullNumber: number;
  pullRequestPromise: Promise<GithubPullRequest>;
}): void {
  waitUntil(
    (async () => {
      try {
        const pullRequest = await pullRequestPromise;
        const fallbackRepoFullName =
          pullRequest.base?.repo?.full_name ??
          pullRequest.head?.repo?.full_name ??
          `${githubOwner}/${repo}`;
        const githubLink =
          pullRequest.html_url ??
          `https://github.com/${fallbackRepoFullName}/pull/${pullNumber}`;
        const commitRef = pullRequest.head?.sha ?? undefined;
        const baseCommitRef = pullRequest.base?.sha ?? undefined;

        if (!commitRef) {
          console.error(
            "[code-review] Missing head commit SHA; skipping schedule",
            {
              githubOwner,
              repo,
              pullNumber,
            }
          );
          return;
        }
        if (!baseCommitRef) {
          console.error(
            "[code-review] Missing base commit SHA; skipping schedule",
            {
              githubOwner,
              repo,
              pullNumber,
            }
          );
          return;
        }

        const dedupeMetadata = {
          teamSlugOrId,
          repoFullName: fallbackRepoFullName,
          prNumber: pullNumber,
          commitRef,
          baseCommitRef,
          force: false,
        };
        console.info(
          "[code-review] Scheduling automated review",
          dedupeMetadata
        );

        const callbackBaseUrl = getConvexHttpActionBaseUrl();
        if (!callbackBaseUrl) {
          console.error("[code-review] Convex HTTP base URL is not configured");
          return;
        }

        const user = await stackServerApp.getUser({ or: "anonymous" });
        if (!user) {
          console.warn("[code-review] No user found; skipping callback");
          return;
        }

        let accessToken: string | null = null;
        let githubAccessToken: string | null = null;

        try {
          const authJson = await user.getAuthJson();
          accessToken = authJson.accessToken ?? null;

          const githubAccount = await user.getConnectedAccount("github");
          if (!githubAccount) {
            console.warn(
              "[code-review] GitHub account not connected, proceeding without token"
            );
          } else {
            const tokenResult = await githubAccount.getAccessToken();
            githubAccessToken = tokenResult.accessToken ?? null;
            if (!githubAccessToken) {
              console.warn(
                "[code-review] GitHub access token unavailable, proceeding without token"
              );
            }
          }
        } catch (error) {
          console.warn(
            "[code-review] Failed to get user auth info; skipping callback",
            error
          );
          return;
        }

        const repoIsPrivate =
          pullRequest.base?.repo?.private ??
          pullRequest.head?.repo?.private ??
          false;

        const shouldAttemptSimpleReview =
          !repoIsPrivate ||
          (typeof githubAccessToken === "string" &&
            githubAccessToken.trim().length > 0);

        const simpleReviewToken = repoIsPrivate
          ? githubAccessToken
          : (githubAccessToken ?? null);

        let simpleReviewPromise: Promise<unknown> | null = null;

        if (shouldAttemptSimpleReview) {
          simpleReviewPromise = runSimpleAnthropicReviewStream({
            prIdentifier: githubLink,
            githubToken: simpleReviewToken,
          }).catch((error) => {
            const message =
              error instanceof Error ? error.message : String(error ?? "");
            console.error("[simple-review][page] Stream failed", {
              githubLink,
              message,
            });
          });
        } else {
          console.warn(
            "[simple-review][page] Skipping stream; repository is private and no token available",
            {
              githubLink,
              pullNumber,
            }
          );
        }

        if (!accessToken) {
          console.warn(
            "[code-review] No access token available; skipping automated job start"
          );
          if (simpleReviewPromise) {
            await simpleReviewPromise;
          }
          return;
        }

        const { job, deduplicated, backgroundTask } = await startCodeReviewJob({
          accessToken,
          githubAccessToken,
          callbackBaseUrl,
          payload: {
            teamSlugOrId,
            githubLink,
            prNumber: pullNumber,
            commitRef,
            headCommitRef: commitRef,
            baseCommitRef,
            force: false,
          },
        });
        console.info("[code-review] Reservation result", {
          jobId: job.jobId,
          deduplicated,
          jobState: job.state,
          repoFullName: job.repoFullName,
          prNumber: job.prNumber,
          commitRef: job.commitRef,
          baseCommitRef: job.baseCommitRef,
          teamId: job.teamId,
        });

        const followUpTasks: Promise<unknown>[] = [];
        if (backgroundTask) {
          followUpTasks.push(backgroundTask);
        }
        if (simpleReviewPromise) {
          followUpTasks.push(simpleReviewPromise);
        }
        if (followUpTasks.length > 0) {
          await Promise.all(followUpTasks);
        }
      } catch (error) {
        const context = {
          teamSlugOrId,
          githubOwner,
          repo,
          pullNumber,
        };
        if (isGithubApiError(error) && error.status === 404) {
          console.warn(
            "[code-review] Skipping auto-start; GitHub app not installed or repository access missing",
            context
          );
        } else {
          console.error(
            "[code-review] Skipping auto-start due to PR fetch error",
            context,
            error
          );
        }
      }
    })()
  );
}

function PullRequestHeader({
  promise,
  githubOwner,
  repo,
}: {
  promise: PullRequestPromise;
  githubOwner: string;
  repo: string;
}) {
  try {
    const pullRequest = use(promise);
    return (
      <PullRequestHeaderContent
        pullRequest={pullRequest}
        githubOwner={githubOwner}
        repo={repo}
      />
    );
  } catch (error) {
    if (isGithubApiError(error)) {
      const message =
        error.status === 404
          ? "This pull request could not be found or you might not have access to view it."
          : error.message;

      return (
        <ErrorPanel
          title="Unable to load pull request"
          message={message}
          documentationUrl={error.documentationUrl}
        />
      );
    }

    throw error;
  }
}

function PullRequestHeaderContent({
  pullRequest,
  githubOwner,
  repo,
}: {
  pullRequest: GithubPullRequest;
  githubOwner: string;
  repo: string;
}) {
  const statusBadge = getStatusBadge(pullRequest);
  const createdAtLabel = formatRelativeTimeFromNow(
    new Date(pullRequest.created_at)
  );
  const updatedAtLabel = formatRelativeTimeFromNow(
    new Date(pullRequest.updated_at)
  );
  const authorLogin = pullRequest.user?.login ?? null;

  return (
    <section className="border border-neutral-200 bg-white px-5 p-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <PullRequestHeaderSummary
          statusLabel={statusBadge.label}
          statusClassName={statusBadge.className}
          pullNumber={pullRequest.number}
          githubOwner={githubOwner}
          repo={repo}
          title={pullRequest.title}
          authorLogin={authorLogin}
          createdAtLabel={createdAtLabel}
          updatedAtLabel={updatedAtLabel}
        />

        <PullRequestHeaderActions
          changedFiles={pullRequest.changed_files}
          additions={pullRequest.additions}
          deletions={pullRequest.deletions}
          githubUrl={pullRequest.html_url}
        />
      </div>
    </section>
  );
}

function PullRequestHeaderSummary({
  statusLabel,
  statusClassName,
  pullNumber,
  githubOwner,
  repo,
  title,
  authorLogin,
  createdAtLabel,
  updatedAtLabel,
}: {
  statusLabel: string;
  statusClassName: string;
  pullNumber: number;
  githubOwner: string;
  repo: string;
  title: string;
  authorLogin: string | null;
  createdAtLabel: string;
  updatedAtLabel: string;
}) {
  return (
    <div className="flex-1 min-w-0">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <PullRequestStatusBadge
          label={statusLabel}
          className={statusClassName}
        />
        <span className="font-mono text-neutral-500">#{pullNumber}</span>
        <span className="text-neutral-500">
          {githubOwner}/{repo}
        </span>
      </div>

      <h1 className="mt-2 text-xl font-semibold leading-tight text-neutral-900">
        {title}
      </h1>

      <PullRequestHeaderMeta
        authorLogin={authorLogin}
        createdAtLabel={createdAtLabel}
        updatedAtLabel={updatedAtLabel}
      />
    </div>
  );
}

function PullRequestStatusBadge({
  label,
  className,
}: {
  label: string;
  className: string;
}) {
  return (
    <span
      className={cn(
        "px-2 py-0.5 font-semibold uppercase tracking-wide",
        className
      )}
    >
      {label}
    </span>
  );
}

function PullRequestHeaderMeta({
  authorLogin,
  createdAtLabel,
  updatedAtLabel,
}: {
  authorLogin: string | null;
  createdAtLabel: string;
  updatedAtLabel: string;
}) {
  return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-neutral-600">
      {authorLogin ? (
        <>
          <span className="font-medium text-neutral-900">@{authorLogin}</span>
          <span className="text-neutral-400">•</span>
        </>
      ) : null}
      <span>{createdAtLabel}</span>
      <span className="text-neutral-400">•</span>
      <span>Updated {updatedAtLabel}</span>
    </div>
  );
}

function PullRequestHeaderActions({
  changedFiles,
  additions,
  deletions,
  githubUrl,
}: {
  changedFiles: number;
  additions: number;
  deletions: number;
  githubUrl?: string | null;
}) {
  return (
    <aside className="flex flex-wrap items-center gap-3 text-xs">
      <ReviewChangeSummary
        changedFiles={changedFiles}
        additions={additions}
        deletions={deletions}
      />
      {githubUrl ? <ReviewGitHubLinkButton href={githubUrl} /> : null}
    </aside>
  );
}

type PullRequestFilesPromise = Promise<GithubFileChange[]>;

function PullRequestDiffSection({
  filesPromise,
  pullRequestPromise,
  githubOwner,
  teamSlugOrId,
  repo,
  pullNumber,
}: {
  filesPromise: PullRequestFilesPromise;
  pullRequestPromise: PullRequestPromise;
  githubOwner: string;
  teamSlugOrId: string;
  repo: string;
  pullNumber: number;
}) {
  try {
    const files = use(filesPromise);
    const pullRequest = use(pullRequestPromise);
    const fallbackRepoFullName =
      pullRequest.base?.repo?.full_name ??
      pullRequest.head?.repo?.full_name ??
      `${githubOwner}/${repo}`;
    const commitRef = pullRequest.head?.sha ?? undefined;
    const baseCommitRef = pullRequest.base?.sha ?? undefined;
    const pullRequestTitleRaw =
      typeof pullRequest.title === "string" ? pullRequest.title : "";
    const pullRequestTitle =
      pullRequestTitleRaw.trim().length > 0 ? pullRequestTitleRaw.trim() : null;
    const fallbackPullRequestUrl = `https://github.com/${fallbackRepoFullName}/pull/${pullNumber}`;
    const pullRequestHtmlUrl =
      typeof pullRequest.html_url === "string"
        ? pullRequest.html_url.trim()
        : "";
    const pullRequestUrl =
      pullRequestHtmlUrl.length > 0
        ? pullRequestHtmlUrl
        : fallbackPullRequestUrl;

    return (
      <ReviewDiffContent
        files={files}
        teamSlugOrId={teamSlugOrId}
        repoFullName={fallbackRepoFullName}
        reviewTarget={{ type: "pull_request", prNumber: pullNumber }}
        commitRef={commitRef}
        baseCommitRef={baseCommitRef}
        pullRequestTitle={pullRequestTitle}
        pullRequestUrl={pullRequestUrl}
      />
    );
  } catch (error) {
    if (isGithubApiError(error)) {
      const message =
        error.status === 404
          ? "File changes for this pull request could not be retrieved. The pull request may be private or missing."
          : error.message;

      return (
        <ErrorPanel
          title="Unable to load pull request files"
          message={message}
          documentationUrl={error.documentationUrl}
        />
      );
    }

    throw error;
  }
}

function getStatusBadge(pullRequest: GithubPullRequest): {
  label: string;
  className: string;
} {
  if (pullRequest.merged) {
    return {
      label: "Merged",
      className: "bg-purple-100 text-purple-700",
    };
  }

  if (pullRequest.state === "closed") {
    return {
      label: "Closed",
      className: "bg-rose-100 text-rose-700",
    };
  }

  if (pullRequest.draft) {
    return {
      label: "Draft",
      className: "bg-neutral-200 text-neutral-700",
    };
  }

  return {
    label: "Open",
    className: "bg-emerald-100 text-emerald-700",
  };
}

function PullRequestHeaderSkeleton() {
  return (
    <div className="border border-neutral-200 bg-white p-6">
      <div className="animate-pulse space-y-4">
        <div className="h-4 w-32 bg-neutral-200" />
        <div className="h-8 w-3/4 bg-neutral-200" />
        <div className="h-4 w-1/2 bg-neutral-200" />
        <div className="h-4 w-full bg-neutral-200" />
      </div>
    </div>
  );
}

function parsePullNumber(raw: string): number | null {
  if (!/^\d+$/.test(raw)) {
    return null;
  }

  const numericValue = Number.parseInt(raw, 10);

  if (!Number.isFinite(numericValue) || numericValue <= 0) {
    return null;
  }

  return numericValue;
}

function formatRelativeTimeFromNow(date: Date): string {
  const now = Date.now();
  const diffInSeconds = Math.round((now - date.getTime()) / 1000);

  const segments: {
    threshold: number;
    divisor: number;
    unit: Intl.RelativeTimeFormatUnit;
  }[] = [
    { threshold: 45, divisor: 1, unit: "second" },
    { threshold: 2700, divisor: 60, unit: "minute" }, // 45 minutes
    { threshold: 64_800, divisor: 3_600, unit: "hour" }, // 18 hours
    { threshold: 561_600, divisor: 86_400, unit: "day" }, // 6.5 days
    { threshold: 2_419_200, divisor: 604_800, unit: "week" }, // 4 weeks
    { threshold: 28_512_000, divisor: 2_629_746, unit: "month" }, // 11 months
  ];

  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

  for (const segment of segments) {
    if (Math.abs(diffInSeconds) < segment.threshold) {
      const value = Math.round(diffInSeconds / segment.divisor);
      return rtf.format(-value, segment.unit);
    }
  }

  const years = Math.round(diffInSeconds / 31_556_952);
  return rtf.format(-years, "year");
}
