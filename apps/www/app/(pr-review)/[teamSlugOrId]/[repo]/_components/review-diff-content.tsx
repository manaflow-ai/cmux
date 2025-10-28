import Link from "next/link";
import { ExternalLink, GitPullRequest } from "lucide-react";

import { PullRequestDiffViewer } from "@/components/pr/pull-request-diff-viewer";
import type { GithubFileChange } from "@/lib/github/fetch-pull-request";

export function summarizeFiles(files: GithubFileChange[]): {
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

export function ReviewDiffContent({
  files,
  fileCount,
  additions,
  deletions,
  teamSlugOrId,
  repoFullName,
  reviewTarget,
  commitRef,
  baseCommitRef,
}: {
  files: GithubFileChange[];
  fileCount: number;
  additions: number;
  deletions: number;
  teamSlugOrId: string;
  repoFullName: string;
  reviewTarget:
    | { type: "pull_request"; prNumber: number }
    | { type: "comparison"; slug: string };
  commitRef?: string;
  baseCommitRef?: string;
}) {
  return (
    <section className="flex flex-col gap-4">
      <ReviewDiffSummary
        fileCount={fileCount}
        additions={additions}
        deletions={deletions}
      />
      <ReviewDiffViewerWrapper
        files={files}
        teamSlugOrId={teamSlugOrId}
        repoFullName={repoFullName}
        reviewTarget={reviewTarget}
        commitRef={commitRef}
        baseCommitRef={baseCommitRef}
      />
    </section>
  );
}

export function ReviewDiffSummary({
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
        <h2 className="text-lg font-semibold text-neutral-900 dark:text-neutral-50">
          Files changed
        </h2>
        <p className="text-sm text-neutral-600 dark:text-neutral-400">
          {fileCount} file{fileCount === 1 ? "" : "s"}, {additions} additions,{" "}
          {deletions} deletions
        </p>
      </div>
    </header>
  );
}

export function ReviewChangeSummary({
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
      <span className="text-neutral-600 dark:text-neutral-300">
        <GitPullRequest className="inline h-3 w-3" aria-hidden /> {changedFiles}
      </span>
      <span className="text-neutral-400 dark:text-neutral-600">•</span>
      <span className="text-emerald-700 dark:text-emerald-400">+{additions}</span>
      <span className="text-rose-700 dark:text-rose-400">-{deletions}</span>
    </div>
  );
}

export function ReviewGitHubLinkButton({ href }: { href: string }) {
  return (
    <a
      className="inline-flex items-center gap-1.5 rounded-md border border-neutral-300 bg-white px-3 py-1.5 font-medium text-neutral-700 transition hover:border-neutral-400 hover:text-neutral-900 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200 dark:hover:border-neutral-600 dark:hover:text-neutral-50"
      href={href}
      target="_blank"
      rel="noreferrer"
    >
      GitHub
      <ExternalLink className="h-3 w-3" />
    </a>
  );
}

export function ReviewDiffViewerWrapper({
  files,
  teamSlugOrId,
  repoFullName,
  reviewTarget,
  commitRef,
  baseCommitRef,
}: {
  files: GithubFileChange[];
  teamSlugOrId: string;
  repoFullName: string;
  reviewTarget:
    | { type: "pull_request"; prNumber: number }
    | { type: "comparison"; slug: string };
  commitRef?: string;
  baseCommitRef?: string;
}) {
  return (
    <PullRequestDiffViewer
      files={files}
      teamSlugOrId={teamSlugOrId}
      repoFullName={repoFullName}
      jobType={reviewTarget.type}
      prNumber={
        reviewTarget.type === "pull_request" ? reviewTarget.prNumber : null
      }
      comparisonSlug={
        reviewTarget.type === "comparison" ? reviewTarget.slug : null
      }
      commitRef={commitRef}
      baseCommitRef={baseCommitRef}
    />
  );
}

export function DiffViewerSkeleton() {
  return (
    <div className="space-y-4">
      <div className="h-6 w-48 rounded bg-neutral-200 dark:bg-neutral-700" />
      <div className="space-y-3">
        {Array.from({ length: 3 }).map((_, index) => (
          <div
            key={index}
            className="h-32 rounded-xl border border-neutral-200 bg-neutral-100 dark:border-neutral-700 dark:bg-neutral-800"
          />
        ))}
      </div>
    </div>
  );
}

export function ErrorPanel({
  title,
  message,
  documentationUrl,
}: {
  title: string;
  message: string;
  documentationUrl?: string;
}) {
  return (
    <div className="rounded-xl border border-rose-200 bg-rose-50 p-6 text-sm text-rose-700 dark:border-rose-500/40 dark:bg-rose-500/10 dark:text-rose-200">
      <p className="font-semibold">{title}</p>
      <p className="mt-2 leading-relaxed">{message}</p>
      {documentationUrl ? (
        <p className="mt-3 text-xs text-rose-600 underline dark:text-rose-300">
          <Link href={documentationUrl} target="_blank" rel="noreferrer">
            View GitHub documentation
          </Link>
        </p>
      ) : null}
    </div>
  );
}
