// GitDiffViewerWithHeatmap - A GitHub-style diff viewer with heatmap support
// This component wraps the HeatmapDiffViewer and converts ReplaceDiffEntry format

import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { cn } from "@/lib/utils";
import type { ReviewHeatmapLine } from "@/lib/heatmap";
import { HeatmapDiffViewer, type HeatmapColorSettings } from "./index";

// ============================================================================
// Types
// ============================================================================

export type GitDiffViewerWithHeatmapProps = {
  /** Array of diff entries to display */
  diffs: ReplaceDiffEntry[];
  /** Optional heatmap data keyed by file path */
  heatmapByFile?: Map<string, ReviewHeatmapLine[]>;
  /** Global heatmap threshold */
  heatmapThreshold?: number;
  /** Custom heatmap colors */
  heatmapColors?: HeatmapColorSettings;
  /** Callback when controls become available */
  onControlsChange?: (controls: DiffViewerControls) => void;
  /** Custom class names */
  classNames?: {
    container?: string;
    fileDiffRow?: {
      button?: string;
      container?: string;
    };
  };
};

export type DiffViewerControls = {
  expandAll: () => void;
  collapseAll: () => void;
  totalAdditions: number;
  totalDeletions: number;
};

type FileCollapsedState = Map<string, boolean>;

// ============================================================================
// Helper Functions
// ============================================================================

function buildUnifiedDiff(entry: ReplaceDiffEntry): string {
  // If we have a patch, use it directly
  if (entry.patch) {
    return entry.patch;
  }

  // Otherwise, construct a unified diff from old/new content
  const oldContent = entry.oldContent ?? "";
  const newContent = entry.newContent ?? "";
  const oldPath = entry.oldPath ?? entry.filePath;
  const newPath = entry.filePath;

  const header = [
    `diff --git a/${oldPath} b/${newPath}`,
    `--- a/${oldPath}`,
    `+++ b/${newPath}`,
  ];

  const oldLines = oldContent.split(/\r?\n/);
  const newLines = newContent.split(/\r?\n/);

  // Simple diff: show all old as deleted, all new as added
  // This is a simplified approach; for better diffs use a proper diff algorithm
  const hunks: string[] = [];

  if (entry.status === "added") {
    // All lines are additions
    hunks.push(`@@ -0,0 +1,${newLines.length} @@`);
    for (const line of newLines) {
      hunks.push(`+${line}`);
    }
  } else if (entry.status === "deleted") {
    // All lines are deletions
    hunks.push(`@@ -1,${oldLines.length} +0,0 @@`);
    for (const line of oldLines) {
      hunks.push(`-${line}`);
    }
  } else {
    // Modified - show full replacement
    hunks.push(`@@ -1,${oldLines.length} +1,${newLines.length} @@`);
    for (const line of oldLines) {
      hunks.push(`-${line}`);
    }
    for (const line of newLines) {
      hunks.push(`+${line}`);
    }
  }

  return [...header, ...hunks].join("\n");
}

function mapStatusToHeatmapStatus(
  status: ReplaceDiffEntry["status"]
): "added" | "removed" | "modified" | "renamed" | "copied" | "changed" {
  switch (status) {
    case "added":
      return "added";
    case "deleted":
      return "removed";
    case "modified":
      return "modified";
    case "renamed":
      return "renamed";
    default:
      return "changed";
  }
}

// ============================================================================
// Component
// ============================================================================

export const GitDiffViewerWithHeatmap = memo(
  function GitDiffViewerWithHeatmapComponent({
    diffs,
    heatmapByFile,
    heatmapThreshold = 0,
    heatmapColors,
    onControlsChange,
    classNames,
  }: GitDiffViewerWithHeatmapProps) {
    const [collapsedState, setCollapsedState] = useState<FileCollapsedState>(
      () => new Map()
    );
    const containerRef = useRef<HTMLDivElement>(null);

    // Calculate totals
    const { totalAdditions, totalDeletions } = useMemo(() => {
      let additions = 0;
      let deletions = 0;
      for (const diff of diffs) {
        additions += diff.additions ?? 0;
        deletions += diff.deletions ?? 0;
      }
      return { totalAdditions: additions, totalDeletions: deletions };
    }, [diffs]);

    // Build controls and notify parent
    const controls = useMemo<DiffViewerControls>(() => {
      return {
        expandAll: () => {
          setCollapsedState((prev) => {
            const next = new Map(prev);
            for (const diff of diffs) {
              next.set(diff.filePath, false);
            }
            return next;
          });
        },
        collapseAll: () => {
          setCollapsedState((prev) => {
            const next = new Map(prev);
            for (const diff of diffs) {
              next.set(diff.filePath, true);
            }
            return next;
          });
        },
        totalAdditions,
        totalDeletions,
      };
    }, [diffs, totalAdditions, totalDeletions]);

    useEffect(() => {
      onControlsChange?.(controls);
    }, [controls, onControlsChange]);

    const handleCollapseChange = useCallback(
      (filePath: string, collapsed: boolean) => {
        setCollapsedState((prev) => {
          const next = new Map(prev);
          next.set(filePath, collapsed);
          return next;
        });
      },
      []
    );

    // Convert diffs to unified format
    const fileEntries = useMemo(() => {
      return diffs.map((diff) => {
        const diffText = buildUnifiedDiff(diff);
        const heatmap = heatmapByFile?.get(diff.filePath) ?? [];

        return {
          key: diff.filePath,
          diffText,
          filename: diff.filePath,
          status: mapStatusToHeatmapStatus(diff.status),
          additions: diff.additions ?? 0,
          deletions: diff.deletions ?? 0,
          heatmap,
          isBinary: diff.isBinary ?? false,
          contentOmitted: diff.contentOmitted ?? false,
        };
      });
    }, [diffs, heatmapByFile]);

    if (diffs.length === 0) {
      return (
        <div className="flex items-center justify-center h-full p-6">
          <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none">
            No changes to display
          </div>
        </div>
      );
    }

    return (
      <div
        ref={containerRef}
        className={cn(
          "flex flex-col gap-2 px-3.5 pb-28",
          classNames?.container
        )}
      >
        {fileEntries.map((entry) => {
          const isCollapsed = collapsedState.get(entry.key) ?? false;

          // Handle binary or omitted content
          if (entry.isBinary || entry.contentOmitted) {
            return (
              <article
                key={entry.key}
                className="border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 rounded-lg overflow-hidden"
              >
                <div className="px-3.5 py-2.5 text-sm text-neutral-600 dark:text-neutral-400">
                  {entry.isBinary
                    ? `Binary file: ${entry.filename}`
                    : `Content omitted: ${entry.filename}`}
                </div>
              </article>
            );
          }

          return (
            <HeatmapDiffViewer
              key={entry.key}
              diffText={entry.diffText}
              filename={entry.filename}
              status={entry.status}
              additions={entry.additions}
              deletions={entry.deletions}
              reviewHeatmap={entry.heatmap}
              heatmapThreshold={heatmapThreshold}
              heatmapColors={heatmapColors}
              defaultCollapsed={isCollapsed}
              onCollapseChange={(collapsed) =>
                handleCollapseChange(entry.key, collapsed)
              }
              className="rounded-lg overflow-hidden"
            />
          );
        })}

        {/* Cute kitty ASCII art at the end, similar to Monaco viewer */}
        <div className="mt-8 mb-4 flex justify-center">
          <pre className="text-neutral-300 dark:text-neutral-700 text-[10px] leading-tight font-mono select-none whitespace-pre">
            {`
    /\\_____/\\
   /  o   o  \\
  ( ==  ^  == )
   )         (
  (           )
 ( (  )   (  ) )
(__(__)___(__)__)
            `.trim()}
          </pre>
        </div>
      </div>
    );
  }
);
