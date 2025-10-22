import { Suspense, use } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { waitUntil } from "@vercel/functions";
import { ExternalLink, GitPullRequest } from "lucide-react";
import { type Team } from "@stackframe/stack";

import { PullRequestDiffViewer } from "@/components/pr/pull-request-diff-viewer";
import {
  fetchPullRequest,
  fetchPullRequestFiles,
  type GithubPullRequest,
  type GithubPullRequestFile,
} from "@/lib/github/fetch-pull-request";
import { isGithubApiError } from "@/lib/github/errors";
import { cn } from "@/lib/utils";
import { stackServerApp } from "@/lib/utils/stack";
import {
  getConvexHttpActionBaseUrl,
  startCodeReviewJob,
} from "@/lib/services/code-review/start-code-review";
import { type Team } from "@stackframe/stack";

type PageParams = {
  teamSlugOrId: string;
  repo: string;
  pullNumber: string;
};

type PageProps = {
  params: Promise<PageParams>;
};

export const dynamic = "force-dynamic";

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
  const user = await stackServerApp.getUser({ or: "redirect" });
  const selectedTeam = user.selectedTeam || (await getFirstTeam());
  if (!selectedTeam) {
    throw notFound();
  }
  const {
    teamSlugOrId: githubOwner,
    repo,
    pullNumber: pullNumberRaw,
  } = await params;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    return {
      title: `Invalid pull request • ${githubOwner}/${repo}`,
    };
  }

  try {
    const pullRequest = await fetchPullRequest(githubOwner, repo, pullNumber);

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
  const user = await stackServerApp.getUser({ or: "redirect" });
  const selectedTeam = user.selectedTeam || (await getFirstTeam());
  if (!selectedTeam) {
    throw notFound();
  }

  const {
    teamSlugOrId: githubOwner,
    repo,
    pullNumber: pullNumberRaw,
  } = await params;
  const pullNumber = parsePullNumber(pullNumberRaw);

  if (pullNumber === null) {
    notFound();
  }

  const pullRequestPromise = fetchPullRequest(githubOwner, repo, pullNumber);
  const pullRequestFilesPromise = fetchPullRequestFiles(
    githubOwner,
    repo,
    pullNumber
  );

  scheduleCodeReviewStart({
    teamSlugOrId: selectedTeam.id,
    githubOwner,
    repo,
    pullNumber,
    pullRequestPromise,
  });

  return (
    <div className="min-h-dvh bg-neutral-50 text-neutral-900">
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

        const { backgroundTask } = await startCodeReviewJob({
          accessToken,
          callbackBaseUrl,
          payload: {
            teamSlugOrId,
            githubLink,
            prNumber: pullNumber,
            commitRef,
            force: false,
          },
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
    <section className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm">
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
      <PullRequestChangeSummary
        changedFiles={changedFiles}
        additions={additions}
        deletions={deletions}
      />
      {githubUrl ? <GitHubLinkButton href={githubUrl} /> : null}
    </aside>
  );
}

function PullRequestChangeSummary({
  changedFiles,
  additions,
  deletions,
}: {
  changedFiles: number;
  additions: number;
  deletions: number;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-neutral-600">
        <GitPullRequest className="inline h-3 w-3" /> {changedFiles}
      </span>
      <span className="text-neutral-400">•</span>
      <span className="text-emerald-700">+{additions}</span>
      <span className="text-rose-700">-{deletions}</span>
    </div>
  );
}

function GitHubLinkButton({ href }: { href: string }) {
  return (
    <a
      className="inline-flex items-center gap-1.5 rounded-md border border-neutral-300 bg-white px-3 py-1.5 font-medium text-neutral-700 transition hover:border-neutral-400 hover:text-neutral-900"
      href={href}
      target="_blank"
      rel="noreferrer"
    >
      GitHub
      <ExternalLink className="h-3 w-3" />
    </a>
  );
}

type PullRequestFilesPromise = ReturnType<typeof fetchPullRequestFiles>;

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

    return (
      <PullRequestDiffContent
        files={files}
        fileCount={totals.fileCount}
        additions={totals.additions}
        deletions={totals.deletions}
        teamSlugOrId={teamSlugOrId}
        repoFullName={fallbackRepoFullName}
        pullNumber={pullNumber}
        commitRef={commitRef}
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

function summarizeFiles(files: GithubPullRequestFile[]): {
  fileCount: number;
  additions: number;
  deletions: number;
} {
  return files.reduce(
    (acc, file) => {
      acc.fileCount += 1;
      acc.additions += file.additions;
      acc.deletions += file.deletions;
      return acc;
    },
    { fileCount: 0, additions: 0, deletions: 0 }
  );
}

function PullRequestDiffContent({
  files,
  fileCount,
  additions,
  deletions,
  teamSlugOrId,
  repoFullName,
  pullNumber,
  commitRef,
}: {
  files: GithubPullRequestFile[];
  fileCount: number;
  additions: number;
  deletions: number;
  teamSlugOrId: string;
  repoFullName: string;
  pullNumber: number;
  commitRef?: string;
}) {
  return (
    <section className="flex flex-col gap-4">
      <PullRequestDiffSummary
        fileCount={fileCount}
        additions={additions}
        deletions={deletions}
      />
      <PullRequestDiffViewerWrapper
        files={files}
        teamSlugOrId={teamSlugOrId}
        repoFullName={repoFullName}
        pullNumber={pullNumber}
        commitRef={commitRef}
      />
    </section>
  );
}

function PullRequestDiffSummary({
  fileCount,
  additions,
  deletions,
}: {
  fileCount: number;
  additions: number;
  deletions: number;
}) {
  return (
    <header className="flex flex-wrap items-center justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold text-neutral-900">
          Files changed
        </h2>
        <p className="text-sm text-neutral-600">
          {fileCount} file{fileCount === 1 ? "" : "s"}, {additions} additions,{" "}
          {deletions} deletions
        </p>
      </div>
    </header>
  );
}

function PullRequestDiffViewerWrapper({
  files,
  teamSlugOrId,
  repoFullName,
  pullNumber,
  commitRef,
}: {
  files: GithubPullRequestFile[];
  teamSlugOrId: string;
  repoFullName: string;
  pullNumber: number;
  commitRef?: string;
}) {
  return (
    <PullRequestDiffViewer
      files={files}
      teamSlugOrId={teamSlugOrId}
      repoFullName={repoFullName}
      prNumber={pullNumber}
      commitRef={commitRef}
    />
  );
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
    <div className="rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm">
      <div className="animate-pulse space-y-4">
        <div className="h-4 w-32 rounded bg-neutral-200" />
        <div className="h-8 w-3/4 rounded bg-neutral-200" />
        <div className="h-4 w-1/2 rounded bg-neutral-200" />
        <div className="h-4 w-full rounded bg-neutral-200" />
      </div>
    </div>
  );
}

function DiffViewerSkeleton() {
  return (
    <div className="space-y-4">
      <div className="h-6 w-48 rounded bg-neutral-200" />
      <div className="space-y-3">
        {Array.from({ length: 3 }).map((_, index) => (
          <div
            key={index}
            className="h-32 rounded-xl border border-neutral-200 bg-neutral-100"
          />
        ))}
      </div>
    </div>
  );
}

function ErrorPanel({
  title,
  message,
  documentationUrl,
}: {
  title: string;
  message: string;
  documentationUrl?: string;
}) {
  return (
    <div className="rounded-xl border border-rose-200 bg-rose-50 p-6 text-sm text-rose-700">
      <p className="font-semibold">{title}</p>
      <p className="mt-2 leading-relaxed">{message}</p>
      {documentationUrl ? (
        <p className="mt-3 text-xs text-rose-600 underline">
          <Link href={documentationUrl} target="_blank" rel="noreferrer">
            View GitHub documentation
          </Link>
        </p>
      ) : null}
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
