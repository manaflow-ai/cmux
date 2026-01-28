import { FloatingPane } from "@/components/floating-pane";
import { MessageSquareText } from "lucide-react";
import { RunDiffHeatmapReviewSection } from "@/components/RunDiffHeatmapReviewSection";
import type {
  DiffViewerControls,
  StreamFileState,
  StreamFileStatus,
} from "@/components/heatmap-diff-viewer";
import { MonacoGitDiffViewerWithSidebar } from "@/components/monaco/monaco-git-diff-viewer-with-sidebar";
import { RunScreenshotGallery } from "@/components/RunScreenshotGallery";
import { TaskDetailHeader } from "@/components/task-detail-header";
import { useSocket } from "@/contexts/socket/use-socket";
import { cachedGetUser } from "@/lib/cachedGetUser";
import type { ReviewHeatmapLine } from "@/lib/heatmap";
import { stackClientApp } from "@/lib/stack";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { api } from "@cmux/convex/api";
import type { CreateLocalWorkspaceResponse, ReplaceDiffEntry } from "@cmux/shared";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery as useRQ } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation } from "convex/react";
import {
  Suspense,
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { toast } from "sonner";
import z from "zod";
import {
  DEFAULT_HEATMAP_MODEL,
  DEFAULT_TOOLTIP_LANGUAGE,
  normalizeHeatmapColors,
  normalizeHeatmapModel,
  normalizeTooltipLanguage,
  type HeatmapModelOptionValue,
  type TooltipLanguageValue,
} from "@/lib/heatmap-settings";
import type { HeatmapColorSettings } from "@/components/heatmap-diff-viewer/heatmap-gradient";
import { useCombinedWorkflowData, WorkflowRunsSection } from "@/components/WorkflowRunsSection";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";

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

/**
 * Build a unified diff patch from oldContent/newContent when no patch is available.
 * This handles cases like untracked (newly added) files where the git-diff socket
 * returns content but not a patch.
 */
function buildPatchFromContent(entry: ReplaceDiffEntry): string {
  const oldContent = entry.oldContent ?? "";
  const newContent = entry.newContent ?? "";

  // If both are empty, nothing to diff
  if (!oldContent && !newContent) {
    return "";
  }

  const oldLines = oldContent ? oldContent.split(/\r?\n/) : [];
  const newLines = newContent ? newContent.split(/\r?\n/) : [];

  // Handle empty content edge cases (single empty string from split)
  if (oldLines.length === 1 && oldLines[0] === "") {
    oldLines.length = 0;
  }
  if (newLines.length === 1 && newLines[0] === "") {
    newLines.length = 0;
  }

  const hunks: string[] = [];

  if (entry.status === "added" || oldLines.length === 0) {
    // Purely added file
    if (newLines.length > 0) {
      hunks.push(`@@ -0,0 +1,${newLines.length} @@`);
      for (const line of newLines) {
        hunks.push(`+${line}`);
      }
    }
  } else if (entry.status === "deleted" || newLines.length === 0) {
    // Purely deleted file
    if (oldLines.length > 0) {
      hunks.push(`@@ -1,${oldLines.length} +0,0 @@`);
      for (const line of oldLines) {
        hunks.push(`-${line}`);
      }
    }
  } else {
    // Modified file - generate a simple diff showing all old lines as removed and all new as added
    // This is a simplified approach; for complex diffs, proper LCS would be better but this
    // ensures heatmap review can process the file.
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

/** Convert ReplaceDiffEntry[] to the format expected by the simple review API */
function convertDiffsToFileDiffs(
  diffs: ReplaceDiffEntry[],
  options?: { prefix?: string | null }
): Array<{ filePath: string; diffText: string }> {
  const prefix =
    typeof options?.prefix === "string" && options.prefix.trim().length > 0
      ? options.prefix.trim()
      : null;
  return diffs
    .filter((entry) => !entry.isBinary)
    .map((entry) => {
      const filePath = prefix ? `${prefix}:${entry.filePath}` : entry.filePath;
      // Use existing patch if available, otherwise build from content
      const rawPatch = entry.patch ?? buildPatchFromContent(entry);
      const diffText = stripDiffHeaders(rawPatch);
      return { filePath, diffText };
    })
    .filter((entry) => entry.diffText.length > 0);
}

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

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

type DiffControls = DiffViewerControls;

function WorkflowRunsWrapper({
  teamSlugOrId,
  repoFullName,
  prNumber,
  headSha,
  checksExpandedByRepo,
  setChecksExpandedByRepo,
}: {
  teamSlugOrId: string;
  repoFullName: string;
  prNumber: number;
  headSha?: string;
  checksExpandedByRepo: Record<string, boolean | null>;
  setChecksExpandedByRepo: React.Dispatch<React.SetStateAction<Record<string, boolean | null>>>;
}) {
  const workflowData = useCombinedWorkflowData({
    teamSlugOrId,
    repoFullName,
    prNumber,
    headSha,
  });

  // Auto-expand if there are failures (only on initial load)
  const hasAnyFailure = useMemo(() => {
    return workflowData.allRuns.some(
      (run) =>
        run.conclusion === "failure" ||
        run.conclusion === "timed_out" ||
        run.conclusion === "action_required"
    );
  }, [workflowData.allRuns]);

  const isExpanded = checksExpandedByRepo[repoFullName] ?? hasAnyFailure;

  return (
    <WorkflowRunsSection
      allRuns={workflowData.allRuns}
      isLoading={workflowData.isLoading}
      isExpanded={isExpanded}
      onToggle={() => {
        setChecksExpandedByRepo((prev) => ({
          ...prev,
          [repoFullName]: !isExpanded,
        }));
      }}
    />
  );
}

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/diff",
)({
  component: RunDiffPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: (opts) => {
    const { runId } = opts.params;

    convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.getRunDiffContext,
      args: { teamSlugOrId: opts.params.teamSlugOrId, taskId: opts.params.taskId, runId },
    });

    void opts.context.queryClient
      .ensureQueryData(
        convexQuery(api.taskRuns.getRunDiffContext, {
          teamSlugOrId: opts.params.teamSlugOrId,
          taskId: opts.params.taskId,
          runId,
        }),
      )
      .then(async (context) => {
        if (!context) {
          return;
        }

        const { task, taskRuns } = context;

        if (task) {
          opts.context.queryClient.setQueryData(
            convexQuery(api.tasks.getById, {
              teamSlugOrId: opts.params.teamSlugOrId,
              id: opts.params.taskId,
            }).queryKey,
            task,
          );
        }

        if (taskRuns) {
          opts.context.queryClient.setQueryData(
            convexQuery(api.taskRuns.getByTask, {
              teamSlugOrId: opts.params.teamSlugOrId,
              taskId: opts.params.taskId,
            }).queryKey,
            taskRuns,
          );
        }

        const selectedTaskRun = taskRuns.find((run) => run._id === runId);
        if (!task || !selectedTaskRun?.newBranch) {
          return;
        }

        const trimmedProjectFullName = task.projectFullName?.trim();
        const targetRepos = new Set<string>();
        for (const repo of selectedTaskRun.environment?.selectedRepos ?? []) {
          const trimmed = repo?.trim();
          if (trimmed) {
            targetRepos.add(trimmed);
          }
        }
        if (trimmedProjectFullName) {
          targetRepos.add(trimmedProjectFullName);
        }

        if (targetRepos.size === 0) {
          return;
        }

        const baseRefForDiff = normalizeGitRef(task.baseBranch || "main");
        const headRefForDiff = normalizeGitRef(selectedTaskRun.newBranch);
        if (!headRefForDiff || !baseRefForDiff) {
          return;
        }

        // NOTE: We intentionally do NOT pass lastKnownBaseSha or lastKnownMergeCommitSha for task run diffs.
        // These merge hints are designed for finding already-merged PRs, not for comparing open feature branches.
        // Passing stale hints from the base branch (e.g., main) can cause the diff to use the wrong comparison
        // base, resulting in extra unrelated files appearing in the diff.
        const prefetches = Array.from(targetRepos).map(async (repoFullName) => {
          return opts.context.queryClient
            .ensureQueryData(
              gitDiffQueryOptions({
                baseRef: baseRefForDiff,
                headRef: headRefForDiff,
                repoFullName,
              }),
            )
            .catch(() => undefined);
        });

        await Promise.all(prefetches);
      })
      .catch(() => undefined);

    return undefined;
  },
});

function RunDiffPage() {
  const { taskId, teamSlugOrId, runId } = Route.useParams();
  const [diffControls, setDiffControls] = useState<DiffControls | null>(null);
  const [isAiReviewActive, setIsAiReviewActive] = useState(false);
  const [hasVisitedAiReview, setHasVisitedAiReview] = useState(false);
  const { socket } = useSocket();
  // Use React Query-wrapped Convex queries to avoid real-time subscriptions
  // that cause excessive re-renders. The data is prefetched in the loader.
  const taskQuery = useRQ({
    ...convexQuery(api.tasks.getById, { teamSlugOrId, id: taskId }),
    enabled: Boolean(teamSlugOrId && taskId),
  });
  const task = taskQuery.data;
  const taskRunsQuery = useRQ({
    ...convexQuery(api.taskRuns.getByTask, { teamSlugOrId, taskId }),
    enabled: Boolean(teamSlugOrId && taskId),
  });
  const taskRuns = taskRunsQuery.data;
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  // Query for existing linked local workspace (to prevent creating duplicates)
  const linkedLocalWorkspaceQuery = useRQ({
    ...convexQuery(api.tasks.getLinkedLocalWorkspace, {
      teamSlugOrId,
      cloudTaskRunId: runId,
    }),
    enabled: Boolean(teamSlugOrId && runId),
  });
  const linkedLocalWorkspace = linkedLocalWorkspaceQuery.data;

  const [streamStateByFile, setStreamStateByFile] = useState<
    Map<string, StreamFileState>
  >(() => new Map());
  // Defer the stream state to batch rapid SSE updates and prevent render thrashing.
  // This allows React to process multiple line events before triggering expensive
  // re-computations in the diff viewer component.
  const deferredStreamStateByFile = useDeferredValue(streamStateByFile);
  const activeReviewControllerRef = useRef<AbortController | null>(null);
  const activeReviewKeyRef = useRef<string | null>(null);

  // Query workspace settings for heatmap configuration
  const workspaceSettingsQuery = useRQ({
    ...convexQuery(api.workspaceSettings.get, { teamSlugOrId }),
    enabled: Boolean(teamSlugOrId),
  });
  const workspaceSettings = useMemo(() => {
    const parsed = workspaceSettingsSchema.safeParse(workspaceSettingsQuery.data);
    return parsed.success ? parsed.data ?? null : null;
  }, [workspaceSettingsQuery.data]);
  const updateWorkspaceSettings = useMutation(api.workspaceSettings.update);
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

  const runDiffContextQuery = useRQ({
    ...convexQuery(api.taskRuns.getRunDiffContext, {
      teamSlugOrId,
      taskId,
      runId,
    }),
    enabled: Boolean(teamSlugOrId && taskId && runId),
  });

  const screenshotSets = runDiffContextQuery.data?.screenshotSets ?? [];
  const screenshotSetsLoading =
    runDiffContextQuery.isLoading && screenshotSets.length === 0;

  // Get PR information from the selected run
  const pullRequests = useMemo(() => {
    return selectedRun?.pullRequests?.filter(
      (pr) => pr.number !== undefined && pr.number !== null
    ) as Array<{ repoFullName: string; number: number; url?: string }> | undefined;
  }, [selectedRun]);

  // Track expanded state for each PR's checks
  const [checksExpandedByRepo, setChecksExpandedByRepo] = useState<Record<string, boolean | null>>({});

  const expandAllChecks = useCallback(() => {
    if (!pullRequests) return;
    const newState: Record<string, boolean | null> = {};
    for (const pr of pullRequests) {
      newState[pr.repoFullName] = true;
    }
    setChecksExpandedByRepo(newState);
  }, [pullRequests]);

  const collapseAllChecks = useCallback(() => {
    if (!pullRequests) return;
    const newState: Record<string, boolean | null> = {};
    for (const pr of pullRequests) {
      newState[pr.repoFullName] = false;
    }
    setChecksExpandedByRepo(newState);
  }, [pullRequests]);

  const environmentRepos = useMemo(() => {
    const repos = selectedRun?.environment?.selectedRepos ?? [];
    const trimmed = repos
      .map((repo) => repo?.trim())
      .filter((repo): repo is string => Boolean(repo));
    return Array.from(new Set(trimmed));
  }, [selectedRun]);

  const repoFullNames = useMemo(() => {
    if (task?.projectFullName) {
      return [task.projectFullName];
    }
    return environmentRepos;
  }, [task?.projectFullName, environmentRepos]);

  const [primaryRepo, ...additionalRepos] = repoFullNames;
  const shouldPrefixDiffs = repoFullNames.length > 1;

  // NOTE: We intentionally do NOT pass lastKnownBaseSha or lastKnownMergeCommitSha for task run diffs.
  // These merge hints are designed for finding already-merged PRs, not for comparing open feature branches.
  // Passing stale hints from the base branch (e.g., main) can cause the diff to use the wrong comparison
  // base, resulting in extra unrelated files appearing in the diff.

  // Fetch diffs for heatmap review (this reuses the cached data from RunDiffSection)
  const baseRefForHeatmap = normalizeGitRef(task?.baseBranch || "main");
  const headRefForHeatmap = normalizeGitRef(selectedRun?.newBranch);
  const diffQueryEnabled = Boolean(primaryRepo) && Boolean(baseRefForHeatmap) && Boolean(headRefForHeatmap);
  const diffQuery = useRQ({
    ...gitDiffQueryOptions({
      repoFullName: primaryRepo ?? "",
      baseRef: baseRefForHeatmap,
      headRef: headRefForHeatmap ?? "",
      // Do not pass merge hints - let the native diff code compute the correct merge-base
    }),
    enabled: diffQueryEnabled,
  });

  // Convert diffs to the format expected by the simple review API
  const fileDiffsForReview = useMemo(() => {
    if (!diffQuery.data) {
      return undefined;
    }
    const prefix = shouldPrefixDiffs && primaryRepo ? primaryRepo : null;
    return convertDiffsToFileDiffs(diffQuery.data, { prefix });
  }, [diffQuery.data, primaryRepo, shouldPrefixDiffs]);

  const reviewLabel = useMemo(() => {
    const baseBranch = task?.baseBranch || "main";
    if (primaryRepo && selectedRun?.newBranch) {
      return `${primaryRepo} ${baseBranch}...${selectedRun.newBranch}`;
    }
    return `task:${taskId} run:${runId}`;
  }, [primaryRepo, runId, selectedRun?.newBranch, task?.baseBranch, taskId]);

  const startSimpleReview = useCallback(
    async ({
      fileDiffs,
      model,
      language,
      requestKey,
      diffLabel,
    }: {
      fileDiffs: Array<{ filePath: string; diffText: string }>;
      model: HeatmapModelOptionValue;
      language: TooltipLanguageValue;
      requestKey: string;
      diffLabel: string;
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
          body: JSON.stringify({ fileDiffs, diffLabel }),
          signal: controller.signal,
        });

        if (!response.ok) {
          console.error(
            "[simple-review][frontend] Failed to start stream",
            response.status
          );
          return;
        }

        const body = response.body;
        if (!body) {
          console.error(
            "[simple-review][frontend] Response body missing for stream"
          );
          return;
        }

        const reader = body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        const shouldLog = false;

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
                  case "status":
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][status]",
                        payload
                      );
                    }
                    break;
                  case "file":
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][file]",
                        payload
                      );
                    }
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
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][skip]",
                        payload
                      );
                    }
                    if (filePath) {
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath) ?? {
                          lines: [],
                          status: "pending",
                          skipReason: null,
                          summary: null,
                        };
                        next.set(filePath, {
                          ...current,
                          skipReason:
                            typeof payload.reason === "string"
                              ? payload.reason
                              : (current.skipReason ?? null),
                          summary:
                            typeof payload.reason === "string"
                              ? payload.reason
                              : (current.summary ?? null),
                        });
                        return next;
                      });
                    }
                    break;
                  case "file-complete":
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][file-complete]",
                        payload
                      );
                    }
                    if (filePath) {
                      const status =
                        payload.status === "skipped" ||
                        payload.status === "error" ||
                        payload.status === "success"
                          ? (payload.status as StreamFileStatus)
                          : "success";
                      const summary =
                        typeof payload.summary === "string"
                          ? payload.summary
                          : undefined;
                      setStreamStateByFile((previous) => {
                        const next = new Map(previous);
                        const current = next.get(filePath) ?? {
                          lines: [],
                          status: "pending",
                          skipReason: null,
                          summary: null,
                        };
                        next.set(filePath, {
                          ...current,
                          status,
                          summary: summary ?? current.summary ?? null,
                        });
                        return next;
                      });
                    }
                    break;
                  case "hunk":
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][hunk]",
                        payload
                      );
                    }
                    break;
                  case "line": {
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][line]",
                        payload
                      );
                    }
                    if (!filePath) {
                      break;
                    }
                    const linePayload = payload.line as
                      | Record<string, unknown>
                      | undefined;
                    if (!linePayload) {
                      break;
                    }
                    const rawScore =
                      typeof linePayload.scoreNormalized === "number"
                        ? linePayload.scoreNormalized
                        : typeof linePayload.score === "number"
                          ? linePayload.score / 100
                          : null;
                    if (rawScore === null || rawScore <= 0) {
                      break;
                    }
                    const normalizedScore = Math.max(
                      0,
                      Math.min(rawScore, 1)
                    );
                    const lineNumber =
                      typeof linePayload.newLineNumber === "number"
                        ? linePayload.newLineNumber
                        : typeof linePayload.oldLineNumber === "number"
                          ? linePayload.oldLineNumber
                          : null;
                    const lineText =
                      typeof linePayload.diffLine === "string"
                        ? linePayload.diffLine
                        : typeof linePayload.codeLine === "string"
                          ? linePayload.codeLine
                          : null;
                    const normalizedText =
                      typeof lineText === "string"
                        ? lineText.replace(/\s+/g, " ").trim()
                        : null;
                    if (!normalizedText) {
                      break;
                    }

                    const reviewLine: ReviewHeatmapLine = {
                      lineNumber,
                      lineText,
                      score: normalizedScore,
                      reason:
                        typeof linePayload.shouldReviewWhy === "string"
                          ? linePayload.shouldReviewWhy
                          : null,
                      mostImportantWord:
                        typeof linePayload.mostImportantWord === "string"
                          ? linePayload.mostImportantWord
                          : null,
                    };

                    setStreamStateByFile((previous) => {
                      const next = new Map(previous);
                      const current = next.get(filePath) ?? {
                        lines: [],
                        status: "pending",
                        skipReason: null,
                        summary: null,
                      };
                      const lineKey = `${reviewLine.lineNumber ?? "unknown"}:${
                        reviewLine.lineText ?? ""
                      }`;
                      const filtered = current.lines.filter((line) => {
                        const existingKey = `${line.lineNumber ?? "unknown"}:${
                          line.lineText ?? ""
                        }`;
                        return existingKey !== lineKey;
                      });
                      const updated = [...filtered, reviewLine].sort((a, b) => {
                        const aLine = a.lineNumber ?? Number.MAX_SAFE_INTEGER;
                        const bLine = b.lineNumber ?? Number.MAX_SAFE_INTEGER;
                        if (aLine !== bLine) {
                          return aLine - bLine;
                        }
                        return (a.lineText ?? "").localeCompare(
                          b.lineText ?? ""
                        );
                      });
                      next.set(filePath, {
                        ...current,
                        lines: updated,
                      });
                      return next;
                    });
                    break;
                  }
                  case "complete":
                    if (shouldLog) {
                      console.info(
                        "[simple-review][frontend][complete]",
                        payload
                      );
                    }
                    setStreamStateByFile((previous) => {
                      let changed = false;
                      const next = new Map(previous);
                      for (const [path, state] of next.entries()) {
                        if (state.status === "pending") {
                          next.set(path, {
                            ...state,
                            status: "success",
                          });
                          changed = true;
                        }
                      }
                      return changed ? next : previous;
                    });
                    break;
                  case "error":
                    console.error("[simple-review][frontend][error]", payload);
                    break;
                  default:
                    console.info(
                      "[simple-review][frontend][event]",
                      payload
                    );
                }
              } catch (error) {
                console.warn(
                  "[simple-review][frontend] Failed to parse SSE data",
                  { data, error }
                );
              }
            }
          }
        }

        if (buffer.trim().length > 0) {
          console.debug("[simple-review][frontend] Remaining buffer", buffer);
        }
      } catch (error) {
        if (controller.signal.aborted) {
          return;
        }
        console.error("[simple-review][frontend] Stream failed", error);
      }
    },
    [setStreamStateByFile]
  );

  // Handler for toggling AI review - track when user first visits AI review
  const handleToggleAiReview = useCallback(() => {
    setIsAiReviewActive((prev) => {
      const next = !prev;
      if (next && !hasVisitedAiReview) {
        setHasVisitedAiReview(true);
      }
      return next;
    });
  }, [hasVisitedAiReview]);

  // Auto-trigger the simple review when diff data and settings are ready,
  // but ONLY after user has visited the AI review tab (lazy loading).
  useEffect(() => {
    // Don't start the review until user has visited AI review mode
    if (!hasVisitedAiReview) {
      return;
    }
    if (!primaryRepo || !selectedRun?.newBranch) {
      return;
    }
    if (diffQuery.isLoading || workspaceSettingsQuery.isLoading) {
      return;
    }
    if (!fileDiffsForReview || fileDiffsForReview.length === 0) {
      return;
    }

    const diffKey = [
      primaryRepo,
      baseRefForHeatmap ?? "",
      headRefForHeatmap ?? "",
      String(diffQuery.dataUpdatedAt),
      shouldPrefixDiffs ? "prefixed" : "plain",
    ].join("|");
    const settingsKey = `${heatmapModel ?? "default"}|${heatmapTooltipLanguage ?? "default"}`;
    const requestKey = `${diffKey}|${settingsKey}`;

    void startSimpleReview({
      fileDiffs: fileDiffsForReview,
      model: heatmapModel,
      language: heatmapTooltipLanguage,
      requestKey,
      diffLabel: reviewLabel,
    });
  }, [
    baseRefForHeatmap,
    diffQuery.dataUpdatedAt,
    diffQuery.isLoading,
    fileDiffsForReview,
    hasVisitedAiReview,
    heatmapModel,
    heatmapTooltipLanguage,
    headRefForHeatmap,
    primaryRepo,
    reviewLabel,
    selectedRun?.newBranch,
    shouldPrefixDiffs,
    startSimpleReview,
    workspaceSettingsQuery.isLoading,
  ]);

  const taskRunId = selectedRun?._id ?? runId;
  const baseBranch = task?.baseBranch ?? "main";

  const handleOpenLocalWorkspace = useCallback(() => {
    // If query is still loading, don't allow creation to prevent duplicates
    if (linkedLocalWorkspaceQuery.isLoading) {
      toast.info("Checking for existing workspace...", {
        description: "Please wait a moment and try again",
      });
      return;
    }

    // If a linked local workspace already exists, just show a message
    if (linkedLocalWorkspace) {
      toast.info("Local workspace already exists", {
        description: "VS Code (Local) is available in the sidebar",
      });
      return;
    }

    if (!socket) {
      toast.error("Socket not connected");
      return;
    }

    if (!primaryRepo) {
      toast.error("No repository information available");
      return;
    }

    if (!selectedRun?.newBranch) {
      toast.error("No branch information available");
      return;
    }

    const loadingToast = toast.loading("Creating local workspace...");

    socket.emit(
      "create-local-workspace",
      {
        teamSlugOrId,
        projectFullName: primaryRepo,
        repoUrl: `https://github.com/${primaryRepo}.git`,
        branch: selectedRun.newBranch,
        baseBranch,
        linkedFromCloudTaskRunId: selectedRun._id, // Link to the current cloud task run
      },
      (response: CreateLocalWorkspaceResponse) => {
        if (response.success && response.workspacePath) {
          toast.success("Local workspace created!", {
            id: loadingToast,
            description: "VS Code (Local) is now available in the sidebar",
          });
          // Don't navigate - the local VS Code entry will appear under the current task run
        } else {
          toast.error(response.error || "Failed to create workspace", {
            id: loadingToast,
          });
        }
      }
    );
  }, [socket, teamSlugOrId, primaryRepo, selectedRun?.newBranch, selectedRun?._id, linkedLocalWorkspace, linkedLocalWorkspaceQuery.isLoading, baseBranch]);

  // 404 if selected run is missing
  if (!selectedRun) {
    return (
      <div className="p-6 text-sm text-neutral-600 dark:text-neutral-300">
        404 – Run not found
      </div>
    );
  }

  const baseRef = normalizeGitRef(task?.baseBranch || "main");
  const headRef = normalizeGitRef(selectedRun.newBranch);
  const hasDiffSources =
    Boolean(primaryRepo) && Boolean(baseRef) && Boolean(headRef);

  // Only show the "Open local workspace" button for regular tasks (not local/cloud workspaces)
  const isWorkspace = task?.isLocalWorkspace || task?.isCloudWorkspace;

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col relative isolate">
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col">
          <TaskDetailHeader
            task={task}
            taskRuns={taskRuns ?? null}
            selectedRun={selectedRun ?? null}
            taskRunId={taskRunId}
            onExpandAll={diffControls?.expandAll}
            onCollapseAll={diffControls?.collapseAll}
            onExpandAllChecks={expandAllChecks}
            onCollapseAllChecks={collapseAllChecks}
            onOpenLocalWorkspace={isWorkspace ? undefined : handleOpenLocalWorkspace}
            teamSlugOrId={teamSlugOrId}
          />
          {task?.text && (
            <div className="px-2 py-1.5 flex items-center gap-2">
              <button
                type="button"
                onClick={() => {
                  navigator.clipboard.writeText(task.text);
                  toast.success("Copied to clipboard");
                }}
                className="flex items-center gap-1.5 px-2 py-0.5 rounded text-[13px] font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors"
                title="Copy description"
              >
                <MessageSquareText className="w-3.5 h-3.5" />
                <span>Description</span>
              </button>
              <span className="text-xs text-neutral-500 dark:text-neutral-400">{task.text}</span>
            </div>
          )}
          <div className="bg-white dark:bg-neutral-900 flex-1 min-h-0 flex flex-col">
            {pullRequests && pullRequests.length > 0 && (
              <Suspense fallback={null}>
                {pullRequests.map((pr) => (
                  <WorkflowRunsWrapper
                    key={pr.repoFullName}
                    teamSlugOrId={teamSlugOrId}
                    repoFullName={pr.repoFullName}
                    prNumber={pr.number}
                    headSha={undefined}
                    checksExpandedByRepo={checksExpandedByRepo}
                    setChecksExpandedByRepo={setChecksExpandedByRepo}
                  />
                ))}
              </Suspense>
            )}
            {screenshotSetsLoading ? (
              <div className="border-b border-neutral-200 dark:border-neutral-800 bg-neutral-50/60 dark:bg-neutral-950/40 px-3.5 py-3 text-sm text-neutral-500 dark:text-neutral-400">
                Loading screenshots...
              </div>
            ) : screenshotSets.length > 0 ? (
              <RunScreenshotGallery
                screenshotSets={screenshotSets}
                highlightedSetId={selectedRun?.latestScreenshotSetId ?? null}
              />
            ) : null}
            <div
              className="flex-1 min-h-0"
              style={{ "--cmux-diff-header-offset": "56px" } as React.CSSProperties}
            >
              <Suspense
                fallback={
                  <div className="flex h-full items-center justify-center">
                    <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none">
                      Loading diffs...
                    </div>
                  </div>
                }
              >
                {hasDiffSources ? (
                  isAiReviewActive ? (
                    <RunDiffHeatmapReviewSection
                      repoFullName={primaryRepo as string}
                      additionalRepoFullNames={additionalRepos}
                      withRepoPrefix={shouldPrefixDiffs}
                      ref1={baseRef}
                      ref2={headRef}
                      onControlsChange={setDiffControls}
                      streamStateByFile={deferredStreamStateByFile}
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
                      onControlsChange={setDiffControls}
                      isHeatmapActive={isAiReviewActive}
                      onToggleHeatmap={handleToggleAiReview}
                    />
                  )
                ) : (
                  <div className="flex h-full items-center justify-center p-6 text-sm text-neutral-600 dark:text-neutral-300">
                    Missing repo or branches to show diff.
                  </div>
                )}
              </Suspense>
            </div>
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
