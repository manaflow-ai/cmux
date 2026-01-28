import { gitDiffQueryOptions } from "@/queries/git-diff";
import { useQueries } from "@tanstack/react-query";
import { useMemo, useRef } from "react";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import {
  GitDiffHeatmapReviewViewer,
  type StreamFileState,
} from "@/components/heatmap-diff-viewer";
import type { HeatmapColorSettings } from "@/components/heatmap-diff-viewer/heatmap-gradient";
import type { DiffViewerControls } from "@/components/heatmap-diff-viewer";
import { kitties } from "./kitties";

export interface RunDiffHeatmapReviewSectionProps {
  repoFullName: string;
  ref1: string;
  ref2: string;
  onControlsChange?: (controls: DiffViewerControls) => void;
  additionalRepoFullNames?: string[];
  withRepoPrefix?: boolean;
  metadataByRepo?: Record<
    string,
    {
      lastKnownBaseSha?: string;
      lastKnownMergeCommitSha?: string;
    }
  >;
  heatmapThreshold: number;
  heatmapColors: HeatmapColorSettings;
  streamStateByFile?: Map<string, StreamFileState>;
  fileOutputs?: Array<{
    filePath: string;
    codexReviewOutput: unknown;
  }>;
  onHeatmapColorsChange?: (next: HeatmapColorSettings) => void;
  isHeatmapActive?: boolean;
  onToggleHeatmap?: () => void;
}

function applyRepoPrefix(
  entry: ReplaceDiffEntry,
  prefix: string | null,
): ReplaceDiffEntry {
  if (!prefix) {
    return entry;
  }
  const normalizedPrefix = prefix.endsWith(":") ? prefix : `${prefix}:`;
  return {
    ...entry,
    filePath: `${normalizedPrefix}${entry.filePath}`,
    oldPath: entry.oldPath
      ? `${normalizedPrefix}${entry.oldPath}`
      : entry.oldPath,
  };
}

export function RunDiffHeatmapReviewSection(
  props: RunDiffHeatmapReviewSectionProps,
) {
  const {
    repoFullName,
    ref1,
    ref2,
    onControlsChange,
    additionalRepoFullNames,
    withRepoPrefix,
    metadataByRepo,
    heatmapThreshold,
    heatmapColors,
    streamStateByFile,
    fileOutputs,
    onHeatmapColorsChange,
    isHeatmapActive,
    onToggleHeatmap,
  } = props;

  const repoFullNames = useMemo(() => {
    const unique = new Set<string>();
    if (repoFullName?.trim()) {
      unique.add(repoFullName.trim());
    }
    additionalRepoFullNames
      ?.map((name) => name?.trim())
      .filter((name): name is string => Boolean(name))
      .forEach((name) => unique.add(name));
    return Array.from(unique);
  }, [repoFullName, additionalRepoFullNames]);

  const canFetch = repoFullNames.length > 0 && Boolean(ref1) && Boolean(ref2);

  const queries = useQueries({
    queries: repoFullNames.map((repo) => ({
      ...gitDiffQueryOptions({
        repoFullName: repo,
        baseRef: ref1,
        headRef: ref2,
        lastKnownBaseSha: metadataByRepo?.[repo]?.lastKnownBaseSha,
        lastKnownMergeCommitSha:
          metadataByRepo?.[repo]?.lastKnownMergeCommitSha,
      }),
      enabled: canFetch,
    })),
  });

  const combinedDiffsRef = useRef<ReplaceDiffEntry[]>([]);
  const prevDepsRef = useRef<{
    queryData: Array<ReplaceDiffEntry[] | undefined>;
    repoFullNames: string[];
    shouldPrefix: boolean;
  }>({ queryData: [], repoFullNames: [], shouldPrefix: false });

  const shouldPrefix = withRepoPrefix ?? repoFullNames.length > 1;

  const currentQueryData = queries.map((q) => q.data);
  const depsChanged =
    currentQueryData.length !== prevDepsRef.current.queryData.length ||
    currentQueryData.some((data, i) => data !== prevDepsRef.current.queryData[i]) ||
    repoFullNames.length !== prevDepsRef.current.repoFullNames.length ||
    repoFullNames.some((name, i) => name !== prevDepsRef.current.repoFullNames[i]) ||
    shouldPrefix !== prevDepsRef.current.shouldPrefix;

  if (depsChanged) {
    prevDepsRef.current = {
      queryData: currentQueryData,
      repoFullNames: [...repoFullNames],
      shouldPrefix,
    };
    combinedDiffsRef.current = repoFullNames.flatMap((repo, index) => {
      const data = queries[index]?.data ?? [];
      const prefix = shouldPrefix ? `${repo}:` : null;
      return data.map((entry) => applyRepoPrefix(entry, prefix));
    });
  }

  const combinedDiffs = combinedDiffsRef.current;

  const kitty = useMemo(
    () => kitties[Math.floor(Math.random() * kitties.length)],
    []
  );

  if (combinedDiffs.length === 0) {
    return (
      <div className="grow bg-white dark:bg-neutral-900 px-3 py-6">
        <div className="text-center">
          <span className="select-none text-xs text-neutral-500 dark:text-neutral-400">
            No diff detected
          </span>
          <div className="grid place-content-center">
            <pre className="mt-2 select-none text-left text-[8px] font-mono text-neutral-500 dark:text-neutral-400">
              {kitty}
            </pre>
          </div>
        </div>
      </div>
    );
  }

  return (
    <GitDiffHeatmapReviewViewer
      diffs={combinedDiffs}
      fileOutputs={fileOutputs}
      streamStateByFile={streamStateByFile}
      primaryRepoFullName={repoFullName}
      shouldPrefixDiffs={shouldPrefix}
      heatmapThreshold={heatmapThreshold}
      heatmapColors={heatmapColors}
      onHeatmapColorsChange={onHeatmapColorsChange}
      onControlsChange={onControlsChange}
      isHeatmapActive={isHeatmapActive}
      onToggleHeatmap={onToggleHeatmap}
    />
  );
}
