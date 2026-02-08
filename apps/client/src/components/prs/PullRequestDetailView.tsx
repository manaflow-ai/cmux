import { RunDiffHeatmapReviewSection } from "@/components/RunDiffHeatmapReviewSection";
import { RunScreenshotGallery } from "@/components/RunScreenshotGallery";
import { Markdown } from "@/components/Markdown";
import { MonacoGitDiffViewerWithSidebar } from "@/components/monaco/monaco-git-diff-viewer-with-sidebar";
import type { DiffViewerControls, StreamFileState, StreamFileStatus } from "@/components/heatmap-diff-viewer";
import type { HeatmapColorSettings } from "@/components/heatmap-diff-viewer/heatmap-gradient";
import { Dropdown } from "@/components/ui/dropdown";
import { cachedGetUser } from "@/lib/cachedGetUser";
import type { ReviewHeatmapLine } from "@/lib/heatmap";
import {
  DEFAULT_HEATMAP_MODEL,
  DEFAULT_TOOLTIP_LANGUAGE,
  normalizeHeatmapColors,
  normalizeHeatmapModel,
  normalizeTooltipLanguage,
  type HeatmapModelOptionValue,
  type TooltipLanguageValue,
} from "@/lib/heatmap-settings";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import { stackClientApp } from "@/lib/stack";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { api } from "@cmux/convex/api";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { useQuery as useRQ, useMutation } from "@tanstack/react-query";
import { useQuery as useConvexQuery, useMutation as useConvexMutation } from "convex/react";
import { ExternalLink, X, Check, Copy, GitBranch, Loader2, MessageSquare, MessageSquareText, Images, ChevronDown, ChevronRight, Users, Tag, UserCircle } from "lucide-react";
import * as Dialog from "@radix-ui/react-dialog";
import { Suspense, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useUser } from "@stackframe/react";
import { toast } from "sonner";
import { useClipboard } from "@mantine/hooks";
import clsx from "clsx";
import { MergeButton, type MergeMethod } from "@/components/ui/merge-button";
import { formatDistanceToNow } from "date-fns";
import {
  getApiIntegrationsGithubPrsReviewDataOptions,
  postApiIntegrationsGithubPrsCloseMutation,
  postApiIntegrationsGithubPrsIssueCommentsMutation,
  postApiIntegrationsGithubPrsMergeSimpleMutation,
  postApiIntegrationsGithubPrsReviewsMutation,
} from "@cmux/www-openapi-client/react-query";
import type {
  GetApiIntegrationsGithubPrsReviewDataResponse,
  GithubLabel,
  GithubPullRequestReview,
  GithubUser,
  Options,
  PostApiIntegrationsGithubPrsCloseData,
  PostApiIntegrationsGithubPrsCloseResponse,
  PostApiIntegrationsGithubPrsIssueCommentsData,
  PostApiIntegrationsGithubPrsIssueCommentsResponse,
  PostApiIntegrationsGithubPrsMergeSimpleData,
  PostApiIntegrationsGithubPrsMergeSimpleResponse,
  PostApiIntegrationsGithubPrsReviewsData,
  PostApiIntegrationsGithubPrsReviewsResponse,
} from "@cmux/www-openapi-client";
import { useCombinedWorkflowData, WorkflowRunsBadge, WorkflowRunsSection } from "@/components/WorkflowRunsSection";
import z from "zod";
import type { DiffLineComment, GitDiffViewerProps } from "@/components/codemirror-git-diff-viewer";

const RUN_PENDING_STATUSES = new Set(["in_progress", "queued", "waiting", "pending"]);
const RUN_PASSING_CONCLUSIONS = new Set(["success", "neutral", "skipped"]);
const PR_SYNC_GRACE_MS = 1500;
const PR_FINAL_NOT_FOUND_DELAY_MS = 10000;

const workspaceSettingsSchema = z
  .object({
    heatmapThreshold: z.number().optional(),
    heatmapModel: z.string().optional(),
    heatmapTooltipLanguage: z.string().optional(),
    heatmapColors: z
      .object({
        line: z.object({ start: z.string(), end: z.string() }),
        token: z.object({ start: z.string(), end: z.string() }),
      })
      .optional(),
  })
  .nullish();

const DIFF_HEADER_PREFIXES = [
  "diff --git ",
  "index ",
  "--- ",
  "+++ ",
  "new file mode ",
  "deleted file mode ",
  "similarity index ",
  "rename from ",
  "rename to ",
  "old mode ",
  "new mode ",
  "copy from ",
  "copy to ",
];

function stripDiffHeaders(diffText: string): string {
  const lines = diffText.split("\n");
  const filtered = lines.filter(
    (line) =>
      !DIFF_HEADER_PREFIXES.some((prefix) => line.startsWith(prefix))
  );
  return filtered.join("\n").trimEnd();
}

function buildPatchFromContent(entry: ReplaceDiffEntry): string {
  const oldContent = entry.oldContent ?? "";
  const newContent = entry.newContent ?? "";

  if (!oldContent && !newContent) {
    return "";
  }

  const oldLines = oldContent ? oldContent.split(/\r?\n/) : [];
  const newLines = newContent ? newContent.split(/\r?\n/) : [];

  if (oldLines.length === 1 && oldLines[0] === "") {
    oldLines.length = 0;
  }
  if (newLines.length === 1 && newLines[0] === "") {
    newLines.length = 0;
  }

  const hunks: string[] = [];

  if (entry.status === "added" || oldLines.length === 0) {
    if (newLines.length > 0) {
      hunks.push(`@@ -0,0 +1,${newLines.length} @@`);
      for (const line of newLines) {
        hunks.push(`+${line}`);
      }
    }
  } else if (entry.status === "deleted" || newLines.length === 0) {
    if (oldLines.length > 0) {
      hunks.push(`@@ -1,${oldLines.length} +0,0 @@`);
      for (const line of oldLines) {
        hunks.push(`-${line}`);
      }
    }
  } else {
    hunks.push(`@@ -1,${oldLines.length} +1,${newLines.length} @@`);
    for (const line of oldLines) {
      hunks.push(`-${line}`);
    }
    for (const line of newLines) {
      hunks.push(`+${line}`);
    }
  }

  return hunks.join("\n");
}

function convertDiffsToFileDiffs(
  diffs: ReplaceDiffEntry[]
): Array<{ filePath: string; diffText: string }> {
  return diffs
    .filter((entry) => !entry.isBinary)
    .map((entry) => {
      const rawPatch = entry.patch ?? buildPatchFromContent(entry);
      const diffText = stripDiffHeaders(rawPatch);
      return { filePath: entry.filePath, diffText };
    })
    .filter((entry) => entry.diffText.length > 0);
}

function formatRelativeTime(ts?: number): string | null {
  if (typeof ts !== "number") return null;
  return formatDistanceToNow(new Date(ts), { addSuffix: true });
}

const BOT_LOGIN_SUFFIXES = ["[bot]"];
const KNOWN_BOT_LOGINS = new Set(["vercel", "github-actions", "cmux-agent", "netlify", "codecov"]);

function isBotComment(login?: string): boolean {
  if (!login) return false;
  const lower = login.toLowerCase();
  return (
    BOT_LOGIN_SUFFIXES.some((suffix) => lower.endsWith(suffix)) ||
    KNOWN_BOT_LOGINS.has(lower)
  );
}

function DisclosureSection({
  icon,
  title,
  suffix,
  defaultExpanded = true,
  children,
}: {
  icon: ReactNode;
  title: string;
  suffix?: ReactNode;
  defaultExpanded?: boolean;
  children: ReactNode;
}) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  return (
    <div>
      <button
        type="button"
        onClick={() => setExpanded((prev) => !prev)}
        className="flex items-center gap-1.5 w-full text-left px-4 py-1.5 select-none"
      >
        <span className="text-neutral-400 dark:text-neutral-500">
          {expanded ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
        </span>
        <span className="text-neutral-500 dark:text-neutral-400">{icon}</span>
        <span className="text-[13px] font-medium text-neutral-500 dark:text-neutral-400">
          {title}
        </span>
        {suffix}
      </button>
      {expanded && children}
    </div>
  );
}

function SidebarMetaSection({
  title,
  icon,
  defaultExpanded = true,
  children,
}: {
  title: string;
  icon: ReactNode;
  defaultExpanded?: boolean;
  children: ReactNode;
}) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  return (
    <div className="py-3">
      <button
        type="button"
        onClick={() => setExpanded((prev) => !prev)}
        className="flex items-center gap-1.5 w-full text-left"
      >
        <span className="text-neutral-400 dark:text-neutral-500">
          {expanded ? <ChevronDown className="w-3 h-3" /> : <ChevronRight className="w-3 h-3" />}
        </span>
        <span className="text-neutral-500 dark:text-neutral-400">{icon}</span>
        <span className="text-[11px] font-semibold uppercase tracking-wider text-neutral-500 dark:text-neutral-400 select-none">
          {title}
        </span>
      </button>
      {expanded && <div className="mt-2 pl-[18px]">{children}</div>}
    </div>
  );
}

function ReviewStateBadge({ state }: { state: string }) {
  const upper = state.toUpperCase();
  if (upper === "APPROVED") {
    return (
      <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400 font-medium">
        Approved
      </span>
    );
  }
  if (upper === "CHANGES_REQUESTED") {
    return (
      <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400 font-medium">
        Changes requested
      </span>
    );
  }
  if (upper === "COMMENTED") {
    return (
      <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400 font-medium">
        Commented
      </span>
    );
  }
  return null;
}

function CommentAvatar({ src, alt }: { src?: string; alt?: string }) {
  if (src) {
    return <img src={src} alt={alt ?? ""} className="size-5 rounded-full shrink-0" />;
  }
  return <div className="size-5 rounded-full bg-neutral-300 dark:bg-neutral-700 shrink-0" />;
}

function PRSidebar({
  requestedReviewers,
  assignees,
  labels,
  reviews,
  isLoading,
}: {
  requestedReviewers: Array<GithubUser>;
  assignees: Array<GithubUser>;
  labels: Array<GithubLabel>;
  reviews: Array<GithubPullRequestReview>;
  isLoading: boolean;
}) {
  const reviewerMap = useMemo(() => {
    const map = new Map<string, { user: GithubUser; latestState?: string }>();
    for (const reviewer of requestedReviewers) {
      map.set(reviewer.login, { user: reviewer });
    }
    const sorted = [...reviews]
      .filter((r) => r.user?.login && r.state !== "PENDING")
      .sort((a, b) => {
        const aTime = a.submitted_at ? Date.parse(a.submitted_at) : 0;
        const bTime = b.submitted_at ? Date.parse(b.submitted_at) : 0;
        return aTime - bTime;
      });
    for (const review of sorted) {
      if (!review.user) continue;
      const existing = map.get(review.user.login);
      map.set(review.user.login, {
        user: existing?.user ?? review.user,
        latestState: review.state,
      });
    }
    return Array.from(map.values());
  }, [requestedReviewers, reviews]);

  if (isLoading) {
    return (
      <aside className="hidden lg:block w-[260px] shrink-0 border-l border-neutral-200 dark:border-neutral-800 px-4 py-2 sticky top-[56px] self-start">
        <div className="space-y-4">
          {[1, 2, 3].map((i) => (
            <div key={i} className="space-y-2 py-3">
              <div className="h-3 w-20 bg-neutral-200 dark:bg-neutral-800 rounded animate-pulse" />
              <div className="h-5 w-32 bg-neutral-200 dark:bg-neutral-800 rounded animate-pulse" />
            </div>
          ))}
        </div>
      </aside>
    );
  }

  return (
    <aside className="hidden lg:block w-[260px] shrink-0 border-l border-neutral-200 dark:border-neutral-800 px-4 py-0 sticky top-[56px] self-start">
      <SidebarMetaSection title="Reviewers" icon={<Users className="w-3 h-3" />}>
        {reviewerMap.length > 0 ? (
          <div className="space-y-2">
            {reviewerMap.map(({ user, latestState }) => (
              <div key={user.login} className="flex items-center gap-2">
                <CommentAvatar src={user.avatar_url} alt={user.login} />
                <span className="text-[12px] text-neutral-700 dark:text-neutral-300 truncate">
                  {user.login}
                </span>
                {latestState ? <ReviewStateBadge state={latestState} /> : null}
              </div>
            ))}
          </div>
        ) : (
          <div className="text-[12px] text-neutral-500 dark:text-neutral-500">No reviewers</div>
        )}
      </SidebarMetaSection>

      <div className="border-t border-neutral-100 dark:border-neutral-800/50" />

      <SidebarMetaSection title="Labels" icon={<Tag className="w-3 h-3" />}>
        {labels.length > 0 ? (
          <div className="flex flex-wrap gap-1.5">
            {labels.map((label) => {
              const bgColor = label.color ? `#${label.color}` : undefined;
              return (
                <span
                  key={label.name}
                  className="inline-flex items-center text-[10px] font-medium px-2 py-0.5 rounded-full border border-neutral-200 dark:border-neutral-700"
                  style={
                    bgColor
                      ? { backgroundColor: `${bgColor}20`, borderColor: `${bgColor}40`, color: bgColor }
                      : undefined
                  }
                  title={label.description ?? undefined}
                >
                  {bgColor && (
                    <span className="w-2 h-2 rounded-full mr-1.5 shrink-0" style={{ backgroundColor: bgColor }} />
                  )}
                  {label.name}
                </span>
              );
            })}
          </div>
        ) : (
          <div className="text-[12px] text-neutral-500 dark:text-neutral-500">No labels</div>
        )}
      </SidebarMetaSection>

      <div className="border-t border-neutral-100 dark:border-neutral-800/50" />

      <SidebarMetaSection title="Assignees" icon={<UserCircle className="w-3 h-3" />}>
        {assignees.length > 0 ? (
          <div className="space-y-2">
            {assignees.map((user) => (
              <div key={user.login} className="flex items-center gap-2">
                <CommentAvatar src={user.avatar_url} alt={user.login} />
                <span className="text-[12px] text-neutral-700 dark:text-neutral-300 truncate">
                  {user.login}
                </span>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-[12px] text-neutral-500 dark:text-neutral-500">No assignees</div>
        )}
      </SidebarMetaSection>
    </aside>
  );
}

type PullRequestDetailViewProps = {
  teamSlugOrId: string;
  owner: string;
  repo: string;
  number: string;
};

type DiffControls = DiffViewerControls & {
  expandChecks?: () => void;
  collapseChecks?: () => void;
};

type AdditionsAndDeletionsProps = {
  repoFullName: string;
  ref1: string;
  ref2: string;
};

function PullRequestLoadingState() {
  return (
    <div className="h-full w-full flex items-center justify-center">
      <div className="flex flex-col items-center gap-3 text-neutral-500 dark:text-neutral-400 text-center">
        <Loader2 className="w-5 h-5 animate-spin" />
        <div className="text-sm font-medium">Loading pull request...</div>
        <p className="text-xs text-neutral-400 dark:text-neutral-500">
          Hang tight while we fetch the latest data from GitHub.
        </p>
      </div>
    </div>
  );
}

function PullRequestUnavailableState({ variant }: { variant: "syncing" | "missing" }) {
  const isMissing = variant === "missing";
  return (
    <div className="h-full w-full flex items-center justify-center">
      <div className="flex flex-col items-center gap-3 text-neutral-500 dark:text-neutral-400 text-center">
        {isMissing ? (
          <X className="w-5 h-5 text-neutral-400 dark:text-neutral-500" />
        ) : (
          <GitBranch className="w-5 h-5 text-neutral-400 dark:text-neutral-500" />
        )}
        <div className="text-sm font-medium">
          {isMissing ? "We couldn't find this pull request" : "Still syncing this PR..."}
        </div>
        <p className="text-xs text-neutral-400 dark:text-neutral-500">
          {isMissing
            ? "Double-check the link or refresh; GitHub might not have this PR."
            : "We'll update the view as soon as the pull request finishes creating."}
        </p>
      </div>
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
  const currentUser = useUser({ or: "return-null" });

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

  const expandAllChecks = useCallback(() => setChecksExpandedOverride(true), []);
  const collapseAllChecks = useCallback(() => setChecksExpandedOverride(false), []);

  const [diffControls, setDiffControls] = useState<DiffControls | null>(null);

  const handleDiffControlsChange = useCallback((controls: DiffViewerControls | null) => {
    setDiffControls(controls ? {
      ...controls,
      expandChecks: expandAllChecks,
      collapseChecks: collapseAllChecks,
    } : null);
  }, [expandAllChecks, collapseAllChecks]);

  const [isAiReviewActive, setIsAiReviewActive] = useState(false);
  const [hasVisitedAiReview, setHasVisitedAiReview] = useState(false);

  const handleToggleAiReview = useCallback(() => {
    setIsAiReviewActive((prev) => {
      const next = !prev;
      if (next && !hasVisitedAiReview) {
        setHasVisitedAiReview(true);
      }
      return next;
    });
  }, [hasVisitedAiReview]);

  const prNumber = useMemo(() => Number(number), [number]);
  const repoFullName = useMemo(() => `${owner}/${repo}`, [owner, repo]);

  const previewRuns = useConvexQuery(api.previewRuns.listByTeam, {
    teamSlugOrId,
    limit: 100,
  });

  const matchingPreviewRuns = useMemo(() => {
    if (!previewRuns) {
      return [];
    }
    const normalizedRepo = repoFullName.trim().toLowerCase();
    return previewRuns.filter(
      (run) =>
        run.repoFullName.trim().toLowerCase() === normalizedRepo &&
        run.prNumber === prNumber,
    );
  }, [previewRuns, repoFullName, prNumber]);

  const previewRunForScreenshots = useMemo(() => {
    for (const run of matchingPreviewRuns) {
      if (run.taskRunId && run.taskId && run.screenshotSetId) {
        return run;
      }
    }
    for (const run of matchingPreviewRuns) {
      if (run.taskRunId && run.taskId) {
        return run;
      }
    }
    return null;
  }, [matchingPreviewRuns]);

  const previewRunDiffContext = useConvexQuery(
    api.taskRuns.getRunDiffContext,
    previewRunForScreenshots?.taskId && previewRunForScreenshots?.taskRunId
      ? {
          teamSlugOrId,
          taskId: previewRunForScreenshots.taskId,
          runId: previewRunForScreenshots.taskRunId,
        }
      : "skip",
  );

  const screenshotSets = previewRunDiffContext?.screenshotSets ?? [];
  const screenshotSetsLoading =
    previewRuns === undefined ||
    (previewRunForScreenshots?.taskId &&
      previewRunForScreenshots?.taskRunId &&
      previewRunDiffContext === undefined);

  const [conversationDraft, setConversationDraft] = useState("");
  const [isRequestChangesDialogOpen, setIsRequestChangesDialogOpen] =
    useState(false);
  const [requestChangesBody, setRequestChangesBody] = useState("");

  const reviewDataQuery = useRQ({
    ...getApiIntegrationsGithubPrsReviewDataOptions({
      query: {
        team: teamSlugOrId,
        owner,
        repo,
        number: prNumber,
      },
    }),
    enabled: Boolean(currentPR && Number.isFinite(prNumber) && prNumber > 0),
    staleTime: 10_000,
  });

  useEffect(() => {
    if (!reviewDataQuery.isError) return;
    const err = reviewDataQuery.error as unknown;
    const msg = err instanceof Error ? err.message : String(err ?? "");
    toast.error("Failed to load GitHub review data", { description: msg });
  }, [reviewDataQuery.error, reviewDataQuery.isError]);

  const githubReviewLineComments = useMemo(() => {
    const data = reviewDataQuery.data as GetApiIntegrationsGithubPrsReviewDataResponse | undefined;
    const out: DiffLineComment[] = [];
    for (const c of data?.reviewComments ?? []) {
      const line = typeof c.line === "number" ? c.line : null;
      const side = c.side === "LEFT" ? "left" : c.side === "RIGHT" ? "right" : null;
      if (!line || !side) continue;
      const createdAtRaw =
        typeof c.created_at === "string" ? Date.parse(c.created_at) : NaN;
      const createdAt = Number.isFinite(createdAtRaw) ? createdAtRaw : undefined;
      out.push({
        id: `github:${c.id}`,
        kind: "github",
        filePath: c.path,
        lineNumber: line,
        side,
        body: c.body,
        createdAt,
        author: c.user?.login
          ? { login: c.user.login, avatarUrl: c.user.avatar_url }
          : undefined,
        url: c.html_url,
      });
    }
    return out;
  }, [reviewDataQuery.data]);

  const conversationComments = useMemo(() => {
    const data = reviewDataQuery.data as GetApiIntegrationsGithubPrsReviewDataResponse | undefined;
    return (data?.issueComments ?? []).map((c) => {
      const createdAtRaw =
        typeof c.created_at === "string" ? Date.parse(c.created_at) : NaN;
      const createdAt = Number.isFinite(createdAtRaw) ? createdAtRaw : undefined;
      return {
        id: `issue:${c.id}`,
        body: c.body,
        createdAt,
        authorLogin: c.user?.login,
        authorAvatarUrl: c.user?.avatar_url,
        url: c.html_url,
      };
    });
  }, [reviewDataQuery.data]);

  const previewData = useMemo(() => {
    const data = reviewDataQuery.data as GetApiIntegrationsGithubPrsReviewDataResponse | undefined;
    const pr = data?.pullRequest;
    const createdAtRaw =
      typeof pr?.created_at === "string" ? Date.parse(pr.created_at) : NaN;
    const updatedAtRaw =
      typeof pr?.updated_at === "string" ? Date.parse(pr.updated_at) : NaN;
    const createdAt = Number.isFinite(createdAtRaw) ? createdAtRaw : undefined;
    const updatedAt = Number.isFinite(updatedAtRaw) ? updatedAtRaw : undefined;
    const body = typeof pr?.body === "string" ? pr.body : "";

    return {
      body,
      authorLogin: pr?.user?.login ?? currentPR?.authorLogin ?? undefined,
      authorAvatarUrl: pr?.user?.avatar_url ?? undefined,
      createdAt,
      updatedAt,
    };
  }, [currentPR?.authorLogin, reviewDataQuery.data]);

  const sidebarData = useMemo(() => {
    const data = reviewDataQuery.data as GetApiIntegrationsGithubPrsReviewDataResponse | undefined;
    const pr = data?.pullRequest;
    return {
      requestedReviewers: pr?.requested_reviewers ?? [],
      assignees: pr?.assignees ?? [],
      labels: pr?.labels ?? [],
      reviews: data?.reviews ?? [],
    };
  }, [reviewDataQuery.data]);

  // Git diff query for heatmap streaming review
  const baseRef = currentPR ? normalizeGitRef(currentPR.baseRef) : null;
  const headRef = currentPR ? normalizeGitRef(currentPR.headRef) : null;
  const diffQuery = useRQ({
    ...gitDiffQueryOptions({
      repoFullName: currentPR?.repoFullName ?? "",
      baseRef: baseRef ?? "",
      headRef: headRef ?? "",
    }),
    enabled: Boolean(currentPR?.repoFullName && baseRef && headRef),
  });

  const fileDiffsForReview = useMemo(() => {
    if (!diffQuery.data) {
      return null;
    }
    return convertDiffsToFileDiffs(diffQuery.data);
  }, [diffQuery.data]);

  // Heatmap settings state
  const workspaceSettingsData = useConvexQuery(api.workspaceSettings.get, { teamSlugOrId });
  const workspaceSettings = useMemo(() => {
    const parsed = workspaceSettingsSchema.safeParse(workspaceSettingsData);
    return parsed.success ? parsed.data ?? null : null;
  }, [workspaceSettingsData]);
  const updateWorkspaceSettings = useConvexMutation(api.workspaceSettings.update);

  const [heatmapThreshold, setHeatmapThreshold] = useState<number>(0);
  const [heatmapColors, setHeatmapColors] = useState<HeatmapColorSettings>(
    normalizeHeatmapColors(undefined)
  );
  const [heatmapModel, setHeatmapModel] = useState<HeatmapModelOptionValue>(
    DEFAULT_HEATMAP_MODEL
  );
  const [heatmapTooltipLanguage, setHeatmapTooltipLanguage] =
    useState<TooltipLanguageValue>(DEFAULT_TOOLTIP_LANGUAGE);

  useEffect(() => {
    if (!workspaceSettings) {
      return;
    }
    setHeatmapThreshold(workspaceSettings.heatmapThreshold ?? 0);
    setHeatmapColors(normalizeHeatmapColors(workspaceSettings.heatmapColors));
    setHeatmapModel(normalizeHeatmapModel(workspaceSettings.heatmapModel ?? null));
    setHeatmapTooltipLanguage(
      normalizeTooltipLanguage(workspaceSettings.heatmapTooltipLanguage ?? null)
    );
  }, [workspaceSettings]);

  const handleHeatmapColorsChange = useCallback(
    (next: HeatmapColorSettings) => {
      setHeatmapColors(next);
      void updateWorkspaceSettings({
        teamSlugOrId,
        heatmapColors: next,
      }).catch((error) => {
        console.error("Failed to update heatmap colors:", error);
      });
    },
    [teamSlugOrId, updateWorkspaceSettings]
  );

  // Streaming heatmap review state
  const [streamStateByFile, setStreamStateByFile] = useState<Map<string, StreamFileState>>(
    () => new Map()
  );
  const activeReviewControllerRef = useRef<AbortController | null>(null);
  const activeReviewKeyRef = useRef<string | null>(null);

  const diffLabel = useMemo(() => {
    if (currentPR) {
      return `${currentPR.repoFullName}#${currentPR.number}`;
    }
    return `pr:${owner}/${repo}#${number}`;
  }, [currentPR, owner, repo, number]);

  const startSimpleReview = useCallback(
    async ({
      fileDiffs,
      model,
      language,
      requestKey,
      prDiffLabel,
    }: {
      fileDiffs: Array<{ filePath: string; diffText: string }>;
      model: HeatmapModelOptionValue;
      language: TooltipLanguageValue;
      requestKey: string;
      prDiffLabel: string;
    }) => {
      if (fileDiffs.length === 0) {
        return;
      }

      const existingController = activeReviewControllerRef.current;
      const hasActiveMatchingRequest =
        existingController &&
        activeReviewKeyRef.current === requestKey &&
        !existingController.signal.aborted;
      if (hasActiveMatchingRequest) {
        return;
      }

      existingController?.abort();
      const controller = new AbortController();
      activeReviewControllerRef.current = controller;
      activeReviewKeyRef.current = requestKey;

      setStreamStateByFile(new Map());

      const user = await cachedGetUser(stackClientApp);
      const authHeaders = user ? await user.getAuthHeaders() : undefined;
      const headers = new Headers(authHeaders);
      headers.set("Content-Type", "application/json");

      const url = new URL("/api/code-review/simple", WWW_ORIGIN);
      url.searchParams.set("model", model);
      url.searchParams.set("lang", language);

      try {
        const response = await fetch(url.toString(), {
          method: "POST",
          headers,
          body: JSON.stringify({ fileDiffs, diffLabel: prDiffLabel }),
          signal: controller.signal,
        });

        if (!response.ok) {
          console.error(
            "[simple-review][pr][frontend] Failed to start stream",
            response.status
          );
          return;
        }

        const body = response.body;
        if (!body) {
          console.error(
            "[simple-review][pr][frontend] Response body missing for stream"
          );
          return;
        }

        const reader = body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) {
            break;
          }
          buffer += decoder.decode(value, { stream: true });

          let separatorIndex = buffer.indexOf("\n\n");
          while (separatorIndex !== -1) {
            const rawEvent = buffer.slice(0, separatorIndex);
            buffer = buffer.slice(separatorIndex + 2);
            separatorIndex = buffer.indexOf("\n\n");

            const lines = rawEvent.split("\n");
            for (const line of lines) {
              if (!line.startsWith("data:")) {
                continue;
              }
              const data = line.slice(5).trim();
              if (data.length === 0) {
                continue;
              }
              try {
                const payload = JSON.parse(data) as Record<string, unknown>;
                const type =
                  typeof payload.type === "string" ? payload.type : "";
                const filePath =
                  typeof payload.filePath === "string"
                    ? payload.filePath
                    : null;

                switch (type) {
                  case "file":
                    if (filePath) {
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath);
                        next.set(filePath, {
                          lines: current?.lines ?? [],
                          status: "pending",
                          skipReason: null,
                          summary: null,
                        });
                        return next;
                      });
                    }
                    break;
                  case "skip":
                    if (filePath) {
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath);
                        next.set(filePath, {
                          lines: current?.lines ?? [],
                          status: "skipped",
                          skipReason:
                            typeof payload.reason === "string"
                              ? payload.reason
                              : null,
                          summary: null,
                        });
                        return next;
                      });
                    }
                    break;
                  case "line":
                    if (filePath) {
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath);
                        const newLine: ReviewHeatmapLine = {
                          lineNumber:
                            typeof payload.newLineNumber === "number"
                              ? payload.newLineNumber
                              : null,
                          lineText:
                            typeof payload.codeLine === "string"
                              ? payload.codeLine
                              : null,
                          score:
                            typeof payload.scoreNormalized === "number"
                              ? payload.scoreNormalized
                              : null,
                          reason:
                            typeof payload.shouldReviewWhy === "string"
                              ? payload.shouldReviewWhy
                              : null,
                          mostImportantWord:
                            typeof payload.mostImportantWord === "string"
                              ? payload.mostImportantWord
                              : null,
                        };
                        next.set(filePath, {
                          lines: [...(current?.lines ?? []), newLine],
                          status: current?.status ?? "pending",
                          skipReason: current?.skipReason ?? null,
                          summary: current?.summary ?? null,
                        });
                        return next;
                      });
                    }
                    break;
                  case "file-complete":
                    if (filePath) {
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath);
                        const rawStatus = payload.status;
                        let status: StreamFileStatus = "success";
                        if (rawStatus === "skipped") {
                          status = "skipped";
                        } else if (rawStatus === "error") {
                          status = "error";
                        }
                        next.set(filePath, {
                          lines: current?.lines ?? [],
                          status,
                          skipReason: current?.skipReason ?? null,
                          summary:
                            typeof payload.summary === "string"
                              ? payload.summary
                              : null,
                        });
                        return next;
                      });
                    }
                    break;
                  default:
                    break;
                }
              } catch (parseError) {
                console.error(
                  "[simple-review][pr][frontend] Failed to parse SSE payload",
                  parseError
                );
              }
            }
          }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        const isAbortError =
          message.includes("Stream aborted") || message.includes("aborted");
        if (!isAbortError) {
          console.error("[simple-review][pr][frontend] Stream failed", {
            prDiffLabel,
            message,
            error,
          });
        }
      }
    },
    []
  );

  // Clean up streaming request on unmount
  useEffect(() => {
    return () => {
      activeReviewControllerRef.current?.abort();
    };
  }, []);

  // Auto-trigger the simple review when diff data and settings are ready
  // Only trigger if there's no cached fileOutputs (KV cache hit)
  const hasFileOutputs = fileOutputs && fileOutputs.length > 0;
  useEffect(() => {
    if (!hasVisitedAiReview) {
      return;
    }
    if (!currentPR?.repoFullName || !baseRef || !headRef) {
      return;
    }
    if (diffQuery.isLoading || workspaceSettingsData === undefined) {
      return;
    }
    if (!fileDiffsForReview || fileDiffsForReview.length === 0) {
      return;
    }
    // Skip streaming if we already have cached results
    if (hasFileOutputs) {
      return;
    }

    const diffKey = [
      currentPR.repoFullName,
      baseRef,
      headRef,
      String(diffQuery.dataUpdatedAt),
    ].join("|");
    const settingsKey = `${heatmapModel ?? "default"}|${heatmapTooltipLanguage ?? "default"}`;
    const requestKey = `${diffKey}|${settingsKey}`;

    void startSimpleReview({
      fileDiffs: fileDiffsForReview,
      model: heatmapModel,
      language: heatmapTooltipLanguage,
      requestKey,
      prDiffLabel: diffLabel,
    });
  }, [
    baseRef,
    currentPR?.repoFullName,
    diffLabel,
    diffQuery.dataUpdatedAt,
    diffQuery.isLoading,
    fileDiffsForReview,
    hasFileOutputs,
    headRef,
    heatmapModel,
    heatmapTooltipLanguage,
    hasVisitedAiReview,
    startSimpleReview,
    workspaceSettingsData,
  ]);

  const [shouldShowPrMissingState, setShouldShowPrMissingState] = useState(false);
  const [shouldShowDefinitiveMissingState, setShouldShowDefinitiveMissingState] = useState(false);

  useEffect(() => {
    if (currentPR === null) {
      const timeoutId = setTimeout(() => setShouldShowPrMissingState(true), PR_SYNC_GRACE_MS);
      return () => clearTimeout(timeoutId);
    }
    setShouldShowPrMissingState(false);
  }, [currentPR]);

  useEffect(() => {
    if (currentPR === null) {
      const timeoutId = setTimeout(() => setShouldShowDefinitiveMissingState(true), PR_FINAL_NOT_FOUND_DELAY_MS);
      return () => clearTimeout(timeoutId);
    }
    setShouldShowDefinitiveMissingState(false);
  }, [currentPR]);

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

  const submitReviewMutation = useMutation<
    PostApiIntegrationsGithubPrsReviewsResponse,
    Error,
    Options<PostApiIntegrationsGithubPrsReviewsData>
  >({
    ...postApiIntegrationsGithubPrsReviewsMutation(),
  });

  const createConversationCommentMutation = useMutation<
    PostApiIntegrationsGithubPrsIssueCommentsResponse,
    Error,
    Options<PostApiIntegrationsGithubPrsIssueCommentsData>
  >({
	    ...postApiIntegrationsGithubPrsIssueCommentsMutation(),
	    onSuccess: (data) => {
	      if (!data.success) {
	        toast.error(data.message || "Failed to post comment");
	        return;
	      }
	      toast.success("Comment posted");
	      setConversationDraft("");
	      void reviewDataQuery.refetch();
	    },
    onError: (error) => {
      toast.error(
        `Failed to post comment: ${error instanceof Error ? error.message : String(error)}`
      );
    },
  });

  const submitReview = useCallback(
    async (args: {
      event: "APPROVE" | "REQUEST_CHANGES" | "COMMENT";
      body?: string;
      comments?: Array<{
        path: string;
        line: number;
        side: "LEFT" | "RIGHT";
        body: string;
      }>;
    }) => {
      if (!currentPR) {
        throw new Error("Pull request is not loaded");
      }

      const response = await submitReviewMutation.mutateAsync({
        body: {
          teamSlugOrId,
          owner,
          repo,
          number: currentPR.number,
          event: args.event,
          body: args.body?.trim() || undefined,
          commitId: currentPR.headSha ?? undefined,
          comments:
            args.comments && args.comments.length > 0 ? args.comments : undefined,
        },
      });

      if (!response.success) {
        throw new Error(response.message || "Failed to submit review");
      }

      await reviewDataQuery.refetch();
    },
    [currentPR, owner, repo, reviewDataQuery, submitReviewMutation, teamSlugOrId],
  );

  const handleApproveReview = useCallback(async () => {
    try {
      await submitReview({ event: "APPROVE" });
      toast.success("Approved");
    } catch (error) {
      console.error("Failed to approve review:", error);
      const message = error instanceof Error ? error.message : String(error);
      toast.error(`Failed to approve: ${message}`);
    }
  }, [submitReview]);

  const handleSubmitRequestChanges = useCallback(async () => {
    const text = requestChangesBody.trim();
    if (!text) {
      toast.error("Request changes requires a summary");
      return;
    }

    try {
      await submitReview({ event: "REQUEST_CHANGES", body: text });
      toast.success("Requested changes");
      setRequestChangesBody("");
      setIsRequestChangesDialogOpen(false);
    } catch (error) {
      console.error("Failed to request changes:", error);
      const message = error instanceof Error ? error.message : String(error);
      toast.error(`Failed to request changes: ${message}`);
    }
  }, [requestChangesBody, submitReview]);

  const handleAddGithubLineComment = useCallback<
    NonNullable<GitDiffViewerProps["onAddLineComment"]>
  >(
    async ({ filePath, lineNumber, side, body }) => {
      const text = body.trim();
      if (!text) {
        throw new Error("Comment body is required");
      }

      try {
        await submitReview({
          event: "COMMENT",
          comments: [
            {
              path: filePath,
              line: lineNumber,
              side: side === "left" ? "LEFT" : "RIGHT",
              body: text,
            },
          ],
        });
        toast.success("Comment posted");
      } catch (error) {
        console.error("Failed to post inline comment:", error);
        const message = error instanceof Error ? error.message : String(error);
        toast.error(`Failed to post comment: ${message}`);
        throw error;
      }
    },
    [submitReview],
  );

  const handleSubmitConversationComment = useCallback(
    (body: string) => {
      if (!currentPR) return;
      const text = body.trim();
      if (!text) return;
      createConversationCommentMutation.mutate({
        body: {
          teamSlugOrId,
          owner,
          repo,
          number: currentPR.number,
          body: text,
        },
      });
    },
    [createConversationCommentMutation, currentPR, owner, repo, teamSlugOrId],
  );

  const { checksAllowMerge, checksDisabledReason } = useMemo(() => {
    if (workflowData.isLoading) {
      return {
        checksAllowMerge: false,
        checksDisabledReason: "Loading check status...",
      } as const;
    }

    const runs = workflowData.allRuns;
    if (runs.length === 0) {
      return {
        checksAllowMerge: true,
        checksDisabledReason: undefined,
      } as const;
    }

    const hasPending = runs.some((run) => {
      const status = run.status;
      return typeof status === "string" && RUN_PENDING_STATUSES.has(status);
    });

    if (hasPending) {
      return {
        checksAllowMerge: false,
        checksDisabledReason: "Tests are still running. Wait for all required checks to finish before merging.",
      } as const;
    }

    const allPassing = runs.every((run) => {
      const conclusion = run.conclusion;
      return typeof conclusion === "string" && RUN_PASSING_CONCLUSIONS.has(conclusion);
    });

    if (!allPassing) {
      return {
        checksAllowMerge: false,
        checksDisabledReason: "Some tests have not passed yet. Fix the failing checks before merging.",
      } as const;
    }

    return {
      checksAllowMerge: true,
      checksDisabledReason: undefined,
    } as const;
  }, [workflowData.allRuns, workflowData.isLoading]);

  const disabledBecauseOfChecks = !checksAllowMerge;
  const mergeDisabled =
    mergePrMutation.isPending ||
    closePrMutation.isPending ||
    disabledBecauseOfChecks;
  const mergeDisabledReason = disabledBecauseOfChecks
    ? checksDisabledReason
    : undefined;

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
    if (
      !currentPR ||
      mergePrMutation.isPending ||
      closePrMutation.isPending ||
      disabledBecauseOfChecks
    ) {
      return;
    }
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

  if (currentPR === undefined || (currentPR === null && !shouldShowPrMissingState)) {
    return <PullRequestLoadingState />;
  }

  if (!currentPR) {
    return (
      <PullRequestUnavailableState
        variant={shouldShowDefinitiveMissingState ? "missing" : "syncing"}
      />
    );
  }

  const canReview = currentPR.state === "open" && !currentPR.merged;
  const handleRequestChangesOpenChange = (open: boolean) => {
    if (!open && submitReviewMutation.isPending) {
      return;
    }
    setIsRequestChangesDialogOpen(open);
  };

  return (
    <div className="flex flex-1 min-h-0 flex-col">
      <Dialog.Root
        open={isRequestChangesDialogOpen}
        onOpenChange={handleRequestChangesOpenChange}
      >
        <Dialog.Portal>
          <Dialog.Overlay className="fixed inset-0 bg-neutral-950/50 backdrop-blur-sm z-[var(--z-popover)]" />
          <Dialog.Content className="fixed left-1/2 top-1/2 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-2xl border border-neutral-200 bg-white p-6 shadow-xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-900 z-[calc(var(--z-popover)+1)]">
            <div className="flex items-start justify-between gap-4">
              <div>
                <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-neutral-50">
                  Request changes
                </Dialog.Title>
                <Dialog.Description className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
                  Explain what needs to be fixed before this PR can be approved.
                </Dialog.Description>
              </div>
              <Dialog.Close asChild>
                <button
                  type="button"
                  disabled={submitReviewMutation.isPending}
                  className="rounded-full p-2 text-neutral-500 hover:bg-neutral-100 hover:text-neutral-700 disabled:opacity-50 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-200"
                  aria-label="Close"
                >
                  <X className="h-4 w-4" />
                </button>
              </Dialog.Close>
            </div>

            <div className="mt-4">
              <textarea
                value={requestChangesBody}
                onChange={(e) => setRequestChangesBody(e.target.value)}
                placeholder="Summary (required)"
                rows={6}
                className="w-full px-3 py-2 text-[13px] bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-700 rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-blue-500/40"
              />
            </div>

            <div className="mt-4 flex items-center justify-end gap-2">
              <Dialog.Close asChild>
                <button
                  type="button"
                  disabled={submitReviewMutation.isPending}
                  className="px-3 py-1.5 text-xs font-medium text-neutral-700 dark:text-neutral-200 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded-md transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Cancel
                </button>
              </Dialog.Close>
              <button
                type="button"
                onClick={() => void handleSubmitRequestChanges()}
                disabled={
                  submitReviewMutation.isPending || !requestChangesBody.trim()
                }
                className="inline-flex items-center gap-2 px-3 py-1.5 text-xs font-medium bg-[#cf222e] dark:bg-[#da3633] text-white rounded-md hover:bg-[#cf222e]/90 dark:hover:bg-[#da3633]/90 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {submitReviewMutation.isPending ? (
                  <Loader2 className="w-3.5 h-3.5 animate-spin" />
                ) : null}
                Request changes
              </button>
            </div>
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
      <div className="flex-1 min-h-0 min-w-0 overflow-hidden">
        <div className="h-full overflow-y-auto">
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
                  <WorkflowRunsBadge
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
                      disabled={mergeDisabled}
                      isLoading={mergePrMutation.isPending}
                      disabledReason={mergeDisabledReason}
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
                          disabled={!canReview || submitReviewMutation.isPending}
                          onClick={() => void handleApproveReview()}
                        >
                          Approve
                        </Dropdown.Item>
                        <Dropdown.Item
                          disabled={!canReview || submitReviewMutation.isPending}
                          onClick={() => setIsRequestChangesDialogOpen(true)}
                        >
                          Request changes…
                        </Dropdown.Item>
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
          <div
            className="bg-white dark:bg-neutral-950"
            style={{ "--cmux-diff-header-offset": "56px" } as React.CSSProperties}
          >
            <Suspense fallback={null}>
              <WorkflowRunsSection
                allRuns={workflowData.allRuns}
                isLoading={workflowData.isLoading}
                isExpanded={checksExpanded}
                onToggle={handleToggleChecks}
              />
            </Suspense>

            <div className="flex min-h-0">
              <div className="min-w-0 flex-1 pb-16">
                {/* Description — inline one-liner */}
                <div className="px-4 py-2 flex items-baseline gap-2">
                  <div className="flex items-center gap-1.5 text-[13px] font-medium text-neutral-500 dark:text-neutral-400 select-none shrink-0">
                    <MessageSquareText className="w-3.5 h-3.5" />
                    <span>Description</span>
                  </div>
                  {reviewDataQuery.isPending ? (
                    <div className="h-4 w-48 bg-neutral-200 dark:bg-neutral-800 rounded animate-pulse" />
                  ) : previewData.body.trim().length > 0 ? (
                    <span className="text-[13px] text-neutral-600 dark:text-neutral-400 truncate min-w-0">
                      {previewData.body.split("\n")[0]}
                    </span>
                  ) : (
                    <span className="text-[13px] text-neutral-400 dark:text-neutral-500 italic">
                      No description provided.
                    </span>
                  )}
                </div>

                {/* Previews */}
                <section>
                  {screenshotSetsLoading ? (
                    <div className="px-4 py-2 text-sm text-neutral-500 dark:text-neutral-400">
                      Loading screenshots...
                    </div>
                  ) : screenshotSets.length > 0 ? (
                    <RunScreenshotGallery screenshotSets={screenshotSets} />
                  ) : (
                    <DisclosureSection
                      icon={<Images className="w-3.5 h-3.5" />}
                      title="Previews"
                      suffix={<span className="text-[11px] text-neutral-500 dark:text-neutral-500 select-none">0 items</span>}
                      defaultExpanded={false}
                    >
                      <div className="px-4 pb-3 text-[12px] text-neutral-500 dark:text-neutral-500">
                        No previews yet.
                      </div>
                    </DisclosureSection>
                  )}
                </section>

                {/* Discussion */}
                <DisclosureSection
                  icon={<MessageSquare className="w-3.5 h-3.5" />}
                  title="Discussion"
                  suffix={
                    <span className="text-[11px] text-neutral-500 dark:text-neutral-500 select-none">
                      ({conversationComments.length})
                    </span>
                  }
                >
                  <div className="px-4 pb-4">
                    {reviewDataQuery.isPending ? (
                      <div className="text-[12px] text-neutral-500 dark:text-neutral-500 py-2">
                        Loading discussion...
                      </div>
                    ) : conversationComments.length > 0 ? (
                      <div>
                        {conversationComments
                          .slice()
                          .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0))
                          .map((c) => {
                            const isBot = isBotComment(c.authorLogin);

                            return (
                              <div
                                key={c.id}
                                className="py-3 border-b border-neutral-100 dark:border-neutral-800/40 last:border-b-0"
                              >
                                <div className="flex items-center gap-2 min-w-0">
                                  <CommentAvatar src={c.authorAvatarUrl} alt={c.authorLogin} />
                                  <span className="text-[13px] text-neutral-900 dark:text-neutral-100 font-medium">
                                    {c.authorLogin ?? "Unknown"}
                                  </span>
                                  {isBot && (
                                    <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-neutral-200/80 dark:bg-neutral-800 text-neutral-500 dark:text-neutral-400 font-medium select-none leading-none">
                                      Bot
                                    </span>
                                  )}
                                  <span className="text-[11px] text-neutral-400 dark:text-neutral-500 select-none">
                                    {formatRelativeTime(c.createdAt) ?? ""}
                                  </span>
                                </div>
                                {isBot ? (
                                  <details className="mt-1 ml-7 group">
                                    <summary className="text-[12px] text-neutral-400 dark:text-neutral-500 cursor-pointer select-none hover:text-neutral-600 dark:hover:text-neutral-300 list-none [&::-webkit-details-marker]:hidden flex items-center gap-1">
                                      <ChevronDown className="w-3 h-3 transition-transform -rotate-90 group-open:rotate-0" />
                                      <span>Show comment</span>
                                    </summary>
                                    <div className="mt-2 max-h-[300px] overflow-y-auto text-[13px]">
                                      <Markdown content={c.body} />
                                    </div>
                                  </details>
                                ) : (
                                  <div className="mt-1.5 ml-7 text-[13px]">
                                    <Markdown content={c.body} />
                                  </div>
                                )}
                              </div>
                            );
                          })}
                      </div>
                    ) : null}

                    <div className={clsx("flex items-center gap-2", conversationComments.length > 0 ? "mt-3" : "mt-0")}>
                      <CommentAvatar src={currentUser?.profileImageUrl ?? undefined} />
                      <input
                        type="text"
                        value={conversationDraft}
                        onChange={(e) => setConversationDraft(e.target.value)}
                        placeholder="Add discussion comment"
                        className="flex-1 px-3 py-1.5 text-[13px] bg-transparent border border-neutral-200 dark:border-neutral-800 rounded-md focus:outline-none focus:ring-1 focus:ring-blue-500/40 text-neutral-900 dark:text-white placeholder:text-neutral-400 dark:placeholder:text-neutral-600"
                        onKeyDown={(e) => {
                          if (e.key === "Enter" && !e.shiftKey) {
                            e.preventDefault();
                            handleSubmitConversationComment(conversationDraft);
                          }
                        }}
                        disabled={createConversationCommentMutation.isPending}
                      />
                    </div>
                  </div>
                </DisclosureSection>

                <section className="min-h-0">
                  <Suspense
                    fallback={
                      <div className="flex items-center justify-center h-full">
                        <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none py-4">
                          Loading diffs...
                        </div>
                      </div>
                    }
                  >
                    {currentPR?.repoFullName && currentPR.baseRef && currentPR.headRef ? (
                      isAiReviewActive ? (
                        <RunDiffHeatmapReviewSection
                          repoFullName={currentPR.repoFullName}
                          ref1={normalizeGitRef(currentPR.baseRef)}
                          ref2={normalizeGitRef(currentPR.headRef)}
                          onControlsChange={handleDiffControlsChange}
                          fileOutputs={fileOutputs ?? undefined}
                          streamStateByFile={streamStateByFile}
                          heatmapThreshold={heatmapThreshold}
                          heatmapColors={heatmapColors}
                          onHeatmapColorsChange={handleHeatmapColorsChange}
                          isHeatmapActive={isAiReviewActive}
                          onToggleHeatmap={handleToggleAiReview}
                        />
                      ) : (
                        <MonacoGitDiffViewerWithSidebar
                          diffs={diffQuery.data ?? []}
                          isLoading={diffQuery.isLoading}
                          onControlsChange={handleDiffControlsChange}
                          isHeatmapActive={isAiReviewActive}
                          onToggleHeatmap={handleToggleAiReview}
                          lineComments={githubReviewLineComments}
                          onAddLineComment={
                            canReview ? handleAddGithubLineComment : undefined
                          }
                        />
                      )
                    ) : (
                      <div className="px-6 text-sm text-neutral-600 dark:text-neutral-300">
                        Missing repo or branches to show diff.
                      </div>
                    )}
                  </Suspense>
                </section>
              </div>
              <PRSidebar
                requestedReviewers={sidebarData.requestedReviewers}
                assignees={sidebarData.assignees}
                labels={sidebarData.labels}
                reviews={sidebarData.reviews}
                isLoading={reviewDataQuery.isPending}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default PullRequestDetailView;
