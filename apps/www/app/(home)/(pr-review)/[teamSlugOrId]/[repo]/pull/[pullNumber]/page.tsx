import { Suspense, use } from "react";
import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
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
import {
  getConvexHttpActionBaseUrl,
  startCodeReviewJob,
} from "@/lib/services/code-review/start-code-review";
import {
  DiffViewerSkeleton,
  ErrorPanel,
  ReviewChangeSummary,
  ReviewDiffContent,
  ReviewGitHubLinkButton,
} from "../../_components/review-diff-content";
import { PrivateRepoPrompt } from "../../_components/private-repo-prompt";
import { PublicRepoAnonymousPrompt } from "../../_components/public-repo-anonymous-prompt";
import { TeamOnboardingPrompt } from "../../_components/team-onboarding-prompt";
import { env } from "@/lib/utils/www-env";

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

function buildPullRequestPath({
  teamSlugOrId,
  repo,
  pullNumber,
}: PageParams): string {
  return `/${encodeURIComponent(teamSlugOrId)}/${encodeURIComponent(repo)}/pull/${encodeURIComponent(pullNumber)}`;
}

function redirectToSignIn(returnPath: string): never {
  const normalizedPath = returnPath.startsWith("/")
    ? returnPath
    : `/${returnPath}`;
  const searchParams = new URLSearchParams({
    after_auth_return_to: normalizedPath,
  });
  const signInUrl = `${stackServerApp.urls.signIn}?${searchParams.toString()}`;

  redirect(signInUrl);
}

async function requireSignedInUser(returnPath: string) {
  const user = await stackServerApp.getUser({ or: "return-null" });

  if (!user) {
    redirectToSignIn(returnPath);
  }

  return user;
}

async function getUserOrAnonymous() {
  const user = await stackServerApp.getUser({
    or: "anonymous"
  });

  return user;
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
  const user = await getUserOrAnonymous();

  // For private repos without user, or if user doesn't have a team, return basic metadata
  if (!repoIsPublic && !user) {
    return {
      title: `${githubOwner}/${repo} · #${pullNumber}`,
    };
  }

  const githubAccessToken = user ? await resolveGithubAccessToken(user) : null;

  try {
    const pullRequest = await fetchPullRequest(githubOwner, repo, pullNumber, {
      authToken: githubAccessToken,
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
  const returnPath = buildPullRequestPath(resolvedParams);

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

  // For public repos, check if there's an existing user first (don't create anonymous yet)
  // For private repos, require authentication
  const user = repoIsPublic
    ? await stackServerApp.getUser({ or: "anonymous" })
    : await requireSignedInUser(returnPath);

  // For public repos without an existing user, show anonymous prompt
  if (repoIsPublic && !user) {
    return (
      <PublicRepoAnonymousPrompt
        teamSlugOrId={githubOwner}
        repo={repo}
        githubOwner={githubOwner}
        pullNumber={pullNumber}
        stackProjectId={env.NEXT_PUBLIC_STACK_PROJECT_ID}
        stackPublishableKey={env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY}
      />
    );
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

  let initialPullRequest: GithubPullRequest;
  try {
    initialPullRequest = await fetchPullRequest(githubOwner, repo, pullNumber, {
      authToken: githubAccessToken,
    });
  } catch (error) {
    if (isGithubApiError(error) && error.status === 404) {
      // For private repos, show the install prompt
      // For public repos without a team, we can't do anything
      if (!repoIsPublic && selectedTeam) {
        return (
          <PrivateRepoPrompt
            teamSlugOrId={selectedTeam.id}
            repo={repo}
            githubOwner={githubOwner}
            githubAppSlug={env.NEXT_PUBLIC_GITHUB_APP_SLUG}
          />
        );
      }
      // For public repos or when no team, just throw - shouldn't happen for public repos
      throw error;
    }
    throw error;
  }

  const pullRequestPromise = Promise.resolve(initialPullRequest);
  const pullRequestFilesPromise = fetchPullRequestFiles(
    githubOwner,
    repo,
    pullNumber,
    { authToken: githubAccessToken }
  ).then((files) => files.map(toGithubFileChange));

  // Only schedule code review if we have a team
  if (selectedTeam) {
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
            teamSlugOrId={selectedTeam?.id ?? githubOwner}
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

        const user = await stackServerApp.getUser({ or: "return-null" });
        if (!user) {
          return;
        }

        const [{ accessToken }, githubAccount] = await Promise.all([
          user.getAuthJson(),
          user.getConnectedAccount("github"),
        ]);
        if (!accessToken) {
          return;
        }
        if (!githubAccount) {
          console.warn(
            "[code-review] Skipping auto-start: GitHub account not connected"
          );
          return;
        }
        const { accessToken: githubAccessToken } =
          await githubAccount.getAccessToken();
        if (!githubAccessToken) {
          console.warn(
            "[code-review] Skipping auto-start: GitHub access token unavailable"
          );
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

        if (backgroundTask) {
          await backgroundTask;
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
    <section className="border border-neutral-200 bg-white p-4">
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

    return (
      <ReviewDiffContent
        files={files}
        teamSlugOrId={teamSlugOrId}
        repoFullName={fallbackRepoFullName}
        reviewTarget={{ type: "pull_request", prNumber: pullNumber }}
        commitRef={commitRef}
        baseCommitRef={baseCommitRef}
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
