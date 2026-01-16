import { ClaimsBoard } from "@/components/ClaimsBoard";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { normalizeGitRef } from "@/lib/refWithOrigin";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type { ReplaceDiffEntry } from "@cmux/shared";
import type { TaskRunWithChildren } from "@/types/task";
import { useQueries } from "@tanstack/react-query";
import { useQuery } from "convex/react";
import { useMemo } from "react";
import { api } from "@cmux/convex/api";

interface ClaimsBoardPanelProps {
  task: Doc<"tasks"> | null;
  taskRuns: TaskRunWithChildren[] | null;
  crownEvaluation?: {
    evaluatedAt?: number;
    winnerRunId?: Id<"taskRuns">;
    reason?: string;
  } | null;
  screenshotUrls?: Record<string, { url: string | null; capturedAt: number } | null>;
  teamSlugOrId: string;
  taskId: Id<"tasks">;
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

function buildUnifiedDiff(entries: ReplaceDiffEntry[]): string {
  const parts = entries
    .map((entry) => {
      const patch = entry.patch ?? buildPatchFromContent(entry);
      if (!patch) return "";
      if (patch.startsWith("diff --git ")) {
        return patch.trimEnd();
      }
      const oldPath = entry.oldPath ?? entry.filePath;
      const oldLabel = entry.status === "added" ? "/dev/null" : `a/${oldPath}`;
      const newLabel = entry.status === "deleted" ? "/dev/null" : `b/${entry.filePath}`;
      return [
        `diff --git a/${oldPath} b/${entry.filePath}`,
        `--- ${oldLabel}`,
        `+++ ${newLabel}`,
        patch,
      ].join("\n").trimEnd();
    })
    .filter((part) => part.length > 0);

  return parts.join("\n");
}

export function ClaimsBoardPanel({
  task,
  taskRuns,
  crownEvaluation,
  teamSlugOrId,
  taskId,
}: ClaimsBoardPanelProps) {
  // Get the crowned run or the first run
  const targetRun = useMemo(() => {
    if (!taskRuns?.length) return null;

    if (crownEvaluation?.winnerRunId) {
      // Find the crowned run in taskRuns
      const findRun = (runs: TaskRunWithChildren[]): TaskRunWithChildren | null => {
        for (const run of runs) {
          if (run._id === crownEvaluation.winnerRunId) return run;
          const found = findRun(run.children || []);
          if (found) return found;
        }
        return null;
      };
      return findRun(taskRuns) || taskRuns[0];
    }
    // Fall back to first run
    return taskRuns[0];
  }, [crownEvaluation, taskRuns]);

  const targetRunId = targetRun?._id ?? null;

  const normalizedBaseBranch = useMemo(() => {
    const candidate = task?.baseBranch;
    if (candidate && candidate.trim()) {
      return normalizeGitRef(candidate);
    }
    return normalizeGitRef("main");
  }, [task?.baseBranch]);

  const normalizedHeadBranch = useMemo(
    () => normalizeGitRef(targetRun?.newBranch),
    [targetRun?.newBranch],
  );

  const environmentRepos = useMemo<string[]>(() => {
    const repos = targetRun?.environment?.selectedRepos ?? [];
    const trimmed = repos
      .map((repo: string | undefined) => repo?.trim())
      .filter((repo): repo is string => Boolean(repo));
    return Array.from(new Set(trimmed));
  }, [targetRun]);

  const repoFullNames = useMemo(() => {
    const names = new Set<string>();
    if (task?.projectFullName?.trim()) {
      names.add(task.projectFullName.trim());
    }
    for (const repo of environmentRepos) {
      names.add(repo);
    }
    return Array.from(names);
  }, [task?.projectFullName, environmentRepos]);

  const diffQueries = useQueries({
    queries: repoFullNames.map((repoFullName) => ({
      ...gitDiffQueryOptions({
        repoFullName,
        baseRef: normalizedBaseBranch || undefined,
        headRef: normalizedHeadBranch ?? "",
      }),
      enabled:
        Boolean(repoFullName?.trim()) && Boolean(normalizedHeadBranch?.trim()),
    })),
  });

  const allDiffs = useMemo(() => {
    return diffQueries.flatMap((query) => query.data ?? []);
  }, [diffQueries]);

  const gitDiff = useMemo(() => buildUnifiedDiff(allDiffs), [allDiffs]);

  // Fetch full screenshot sets using getRunDiffContext
  const runDiffContext = useQuery(
    api.taskRuns.getRunDiffContext,
    targetRunId && teamSlugOrId && taskId
      ? { teamSlugOrId, taskId, runId: targetRunId }
      : "skip"
  );

  // Get all screenshots from screenshot sets
  const screenshots = useMemo(() => {
    const screenshotSets = runDiffContext?.screenshotSets ?? [];
    if (screenshotSets.length === 0) return [];

    // Flatten all images from all screenshot sets
    const allScreenshots: Array<{ url: string; description?: string }> = [];

    for (const set of screenshotSets) {
      for (const image of set.images) {
        if (image.url) {
          allScreenshots.push({
            url: image.url,
            description: image.description || image.fileName || "Screenshot",
          });
        }
      }
    }

    return allScreenshots;
  }, [runDiffContext?.screenshotSets]);

  return (
    <ClaimsBoard
      task={task}
      runId={targetRunId}
      teamSlugOrId={teamSlugOrId}
      taskPrompt={task?.description ?? ""}
      gitDiff={gitDiff}
      screenshots={screenshots}
    />
  );
}
