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
  teamSlugOrId,
  repoFullName,
  reviewTarget,
  commitRef,
  baseCommitRef,
  sharingScope,
}: {
  files: GithubFileChange[];
  teamSlugOrId: string;
  repoFullName: string;
  reviewTarget:
    | { type: "pull_request"; prNumber: number }
    | { type: "comparison"; slug: string };
  commitRef?: string;
  baseCommitRef?: string;
  sharingScope?: "team" | "shared";
}) {
  return (
    <section className="flex flex-col gap-1">
      <ReviewDiffViewerWrapper
        files={files}
        teamSlugOrId={teamSlugOrId}
        repoFullName={repoFullName}
        reviewTarget={reviewTarget}
        commitRef={commitRef}
        baseCommitRef={baseCommitRef}
        sharingScope={sharingScope}
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
      <span className="text-neutral-600">
        <GitPullRequest className="inline h-3 w-3" /> {changedFiles}
      </span>
      <span className="text-neutral-400">•</span>
      <span className="text-emerald-700">+{additions}</span>
      <span className="text-rose-700">-{deletions}</span>
    </div>
  );
}

export function ReviewGitHubLinkButton({ href }: { href: string }) {
  return (
    <a
      className="inline-flex items-center gap-1.5 border border-neutral-300 bg-white px-3 py-1.5 font-medium text-neutral-700 transition hover:border-neutral-400 hover:text-neutral-900"
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
  sharingScope,
}: {
  files: GithubFileChange[];
  teamSlugOrId: string;
  repoFullName: string;
  reviewTarget:
    | { type: "pull_request"; prNumber: number }
    | { type: "comparison"; slug: string };
  commitRef?: string;
  baseCommitRef?: string;
  sharingScope?: "team" | "shared";
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
      sharingScope={sharingScope}
    />
  );
}

export function DiffViewerSkeleton() {
  return (
    <div className="space-y-4">
      <div className="h-6 w-48 bg-neutral-200" />
      <div className="space-y-3">
        {Array.from({ length: 3 }).map((_, index) => (
          <div
            key={index}
            className="h-32 border border-neutral-200 bg-neutral-100"
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
    <div className="border border-rose-200 bg-rose-50 p-6 text-sm text-rose-700">
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
