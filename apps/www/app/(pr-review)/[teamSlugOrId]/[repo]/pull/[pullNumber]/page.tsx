import { Suspense, use } from "react";
import type { Metadata } from "next";
import { cookies } from "next/headers";
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
  summarizeFiles,
} from "../../_components/review-diff-content";
import {
  DEFAULT_THEME,
  THEME_COOKIE_NAME,
  isThemePreference,
} from "./theme";
import { PageThemeProvider, ThemeToggleButton } from "./theme-provider";

type PageParams = {
  teamSlugOrId: string;
  repo: string;
  pullNumber: string;
};

type PageProps = {
  params: Promise<PageParams>;
};

export const dynamic = "force-dynamic";

function buildPullRequestPath({ teamSlugOrId, repo, pullNumber }: PageParams): string {
  return `/${encodeURIComponent(teamSlugOrId)}/${encodeURIComponent(repo)}/pull/${encodeURIComponent(pullNumber)}`;
}

function redirectToSignIn(returnPath: string): never {
  const normalizedPath = returnPath.startsWith("/") ? returnPath : `/${returnPath}`;
  const searchParams = new URLSearchParams({ after_auth_return_to: normalizedPath });
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

async function getFirstTeam(): Promise<Team | null> {
  const teams = await stackServerApp.listTeams();
  const firstTeam = teams[0];
  if (!firstTeam) {
    return null;
  }
  return firstTeam;
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const resolvedParams = await params;
  const returnPath = buildPullRequestPath(resolvedParams);
  const user = await requireSignedInUser(returnPath);
  const selectedTeam = user.selectedTeam || (await getFirstTeam());
  if (!selectedTeam) {
    throw notFound();
  }
  const { teamSlugOrId: githubOwner, repo, pullNumber: pullNumberRaw } = resolvedParams;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    return {
      title: `Invalid pull request • ${githubOwner}/${repo}`,
    };
  }

  try {
    const pullRequest = await fetchPullRequest(
      githubOwner,
      repo,
      pullNumber
    );

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
  const user = await requireSignedInUser(returnPath);
  const selectedTeam = user.selectedTeam || (await getFirstTeam());
  if (!selectedTeam) {
    throw notFound();
  }

  const { teamSlugOrId: githubOwner, repo, pullNumber: pullNumberRaw } = resolvedParams;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    notFound();
  }

  const pullRequestPromise = fetchPullRequest(githubOwner, repo, pullNumber);
  const pullRequestFilesPromise = fetchPullRequestFiles(
    githubOwner,
    repo,
    pullNumber
  ).then((files) => files.map(toGithubFileChange));

  scheduleCodeReviewStart({
    teamSlugOrId: selectedTeam.id,
    githubOwner,
    repo,
    pullNumber,
    pullRequestPromise,
  });

  const themeCookie = cookies().get(THEME_COOKIE_NAME)?.value;
  const initialTheme = isThemePreference(themeCookie)
    ? themeCookie
    : DEFAULT_THEME;

  return (
    <PageThemeProvider initialTheme={initialTheme}>
      <div className="min-h-dvh bg-neutral-50 text-neutral-900 transition-colors dark:bg-neutral-950 dark:text-neutral-100">
        <div className="flex w-full flex-col gap-8 px-6 pb-16 pt-10 sm:px-8 lg:px-12">
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
              teamSlugOrId={selectedTeam.id}
              githubOwner={githubOwner}
              repo={repo}
              pullNumber={pullNumber}
            />
          </Suspense>
        </div>
      </div>
    </PageThemeProvider>
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
          console.error("[code-review] Missing head commit SHA; skipping schedule", {
            githubOwner,
            repo,
            pullNumber,
          });
          return;
        }
        if (!baseCommitRef) {
          console.error("[code-review] Missing base commit SHA; skipping schedule", {
            githubOwner,
            repo,
            pullNumber,
          });
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
        console.info("[code-review] Scheduling automated review", dedupeMetadata);

        const callbackBaseUrl = getConvexHttpActionBaseUrl();
        if (!callbackBaseUrl) {
          console.error("[code-review] Convex HTTP base URL is not configured");
          return;
        }

        const user = await stackServerApp.getUser({ or: "return-null" });
        if (!user) {
          return;
        }

        const { accessToken } = await user.getAuthJson();
        if (!accessToken) {
          return;
        }

        const { job, deduplicated, backgroundTask } = await startCodeReviewJob({
          accessToken,
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
        console.error(
          "[code-review] Skipping auto-start due to PR fetch error",
          {
            teamSlugOrId,
            githubOwner,
            repo,
            pullNumber,
          },
          error
        );
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
    <section className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm dark:border-neutral-800 dark:bg-neutral-900 dark:shadow-lg dark:shadow-black/10">
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
      <div className="flex flex-wrap items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400">
        <PullRequestStatusBadge
          label={statusLabel}
          className={statusClassName}
        />
        <span className="font-mono text-neutral-500 dark:text-neutral-400">
          #{pullNumber}
        </span>
        <span className="text-neutral-500 dark:text-neutral-400">
          {githubOwner}/{repo}
        </span>
      </div>

      <h1 className="mt-2 text-xl font-semibold leading-tight text-neutral-900 dark:text-neutral-50">
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
        "rounded-md px-2 py-0.5 font-semibold uppercase tracking-wide",
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
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-neutral-600 dark:text-neutral-400">
      {authorLogin ? (
        <>
          <span className="font-medium text-neutral-900 dark:text-neutral-100">
            @{authorLogin}
          </span>
          <span className="text-neutral-400 dark:text-neutral-500">•</span>
        </>
      ) : null}
      <span>{createdAtLabel}</span>
      <span className="text-neutral-400 dark:text-neutral-500">•</span>
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
    <aside className="flex flex-wrap items-center gap-3 text-xs text-neutral-600 dark:text-neutral-300">
      <ThemeToggleButton />
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
    const totals = summarizeFiles(files);
    const fallbackRepoFullName =
      pullRequest.base?.repo?.full_name ??
      pullRequest.head?.repo?.full_name ??
      `${githubOwner}/${repo}`;
    const commitRef = pullRequest.head?.sha ?? undefined;
    const baseCommitRef = pullRequest.base?.sha ?? undefined;

    return (
      <ReviewDiffContent
        files={files}
        fileCount={totals.fileCount}
        additions={totals.additions}
        deletions={totals.deletions}
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
      className: "bg-purple-100 text-purple-700 dark:bg-purple-500/20 dark:text-purple-200",
    };
  }

  if (pullRequest.state === "closed") {
    return {
      label: "Closed",
      className: "bg-rose-100 text-rose-700 dark:bg-rose-500/20 dark:text-rose-200",
    };
  }

  if (pullRequest.draft) {
    return {
      label: "Draft",
      className: "bg-neutral-200 text-neutral-700 dark:bg-neutral-700/60 dark:text-neutral-200",
    };
  }

  return {
    label: "Open",
    className: "bg-emerald-100 text-emerald-700 dark:bg-emerald-500/20 dark:text-emerald-200",
  };
}

function PullRequestHeaderSkeleton() {
  return (
    <div className="rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm dark:border-neutral-800 dark:bg-neutral-900">
      <div className="animate-pulse space-y-4">
        <div className="h-4 w-32 rounded bg-neutral-200 dark:bg-neutral-700" />
        <div className="h-8 w-3/4 rounded bg-neutral-200 dark:bg-neutral-700" />
        <div className="h-4 w-1/2 rounded bg-neutral-200 dark:bg-neutral-700" />
        <div className="h-4 w-full rounded bg-neutral-200 dark:bg-neutral-700" />
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
