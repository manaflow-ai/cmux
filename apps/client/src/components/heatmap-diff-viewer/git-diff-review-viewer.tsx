import {
  memo,
  useCallback,
  useDeferredValue,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type CSSProperties,
} from "react";
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Folder,
  FolderOpen,
  Loader2,
} from "lucide-react";
import {
  computeNewLineNumber,
  computeOldLineNumber,
  getChangeKey,
  parseDiff,
  type FileData,
} from "react-diff-view";

import { cn } from "@/lib/utils";
import {
  parseReviewHeatmap,
  prepareDiffHeatmapArtifacts,
  renderDiffHeatmapFromArtifacts,
  type DiffHeatmap,
  type DiffHeatmapArtifacts,
  type ResolvedHeatmapLine,
  type ReviewHeatmapLine,
} from "@/lib/heatmap";
import { HeatmapDiffViewer } from "./heatmap-diff-viewer";
import { kitties } from "../kitties";
import type { HeatmapColorSettings } from "./heatmap-gradient";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { Tooltip, TooltipContent, TooltipTrigger, TooltipProvider } from "@/components/ui/tooltip";
import {
  DEFAULT_HEATMAP_MODEL,
  DEFAULT_TOOLTIP_LANGUAGE,
  HEATMAP_MODEL_OPTIONS,
  TOOLTIP_LANGUAGE_OPTIONS,
  normalizeHeatmapColors,
  normalizeHeatmapModel,
  normalizeTooltipLanguage,
  type HeatmapModelOptionValue,
  type TooltipLanguageValue,
} from "@/lib/heatmap-settings";

type DiffLineSide = "new" | "old";

type DiffLineLocation = {
  side: DiffLineSide;
  lineNumber: number;
};

type ParsedFileDiff = {
  entry: ReplaceDiffEntry;
  anchorId: string;
  diff: FileData | null;
  diffText: string;
  error?: string;
};

type FileDiffViewModel = {
  entry: ParsedFileDiff;
  reviewHeatmap: ReviewHeatmapLine[];
  diffHeatmapArtifacts: DiffHeatmapArtifacts | null;
  diffHeatmap: DiffHeatmap | null;
  changeKeyByLine: Map<string, string>;
};

type ReviewErrorTarget = {
  id: string;
  anchorId: string;
  filePath: string;
  lineNumber: number;
  side: DiffLineSide;
  reason: string | null;
  score: number | null;
  changeKey: string | null;
};

type ActiveTooltipTarget = {
  filePath: string;
  lineNumber: number;
  side: DiffLineSide;
};

type FocusNavigateOptions = {
  source?: "keyboard" | "button";
};

type NavigateOptions = {
  updateAnchor?: boolean;
  updateHash?: boolean;
};

type HeatmapFileStatus =
  | "added"
  | "removed"
  | "modified"
  | "renamed"
  | "copied"
  | "changed";

type FileTreeNode = {
  name: string;
  path: string;
  children: FileTreeNode[];
  file?: ReplaceDiffEntry;
  isLoading?: boolean;
};

type HeatmapFileOutput = {
  filePath: string;
  codexReviewOutput: unknown;
};

export type StreamFileStatus = "pending" | "success" | "skipped" | "error";

export type StreamFileState = {
  lines: ReviewHeatmapLine[];
  status: StreamFileStatus;
  skipReason?: string | null;
  summary?: string | null;
};

type DiffViewerControls = {
  expandAll: () => void;
  collapseAll: () => void;
  totalAdditions: number;
  totalDeletions: number;
};

type GitDiffHeatmapReviewViewerProps = {
  diffs: ReplaceDiffEntry[];
  fileOutputs?: HeatmapFileOutput[];
  streamStateByFile?: Map<string, StreamFileState>;
  primaryRepoFullName?: string | null;
  shouldPrefixDiffs?: boolean;
  heatmapThreshold?: number;
  heatmapColors?: HeatmapColorSettings;
  heatmapModel?: string | null;
  heatmapTooltipLanguage?: string | null;
  onHeatmapThresholdChange?: (next: number) => void;
  onHeatmapColorsChange?: (next: HeatmapColorSettings) => void;
  onHeatmapModelChange?: (next: HeatmapModelOptionValue) => void;
  onHeatmapTooltipLanguageChange?: (next: TooltipLanguageValue) => void;
  onControlsChange?: (controls: DiffViewerControls) => void;
};

const SIDEBAR_WIDTH_STORAGE_KEY = "cmux:git-diff-viewer:file-tree-width";
const SIDEBAR_DEFAULT_WIDTH = 280;
const SIDEBAR_MIN_WIDTH = 200;
const SIDEBAR_MAX_WIDTH = 442;

function clampSidebarWidth(value: number): number {
  if (Number.isNaN(value)) {
    return SIDEBAR_DEFAULT_WIDTH;
  }
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, value));
}

function mapStatusToHeatmapStatus(
  status: ReplaceDiffEntry["status"]
): HeatmapFileStatus {
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

function mergeHeatmapLines(
  primary: ReviewHeatmapLine[],
  fallback: ReviewHeatmapLine[]
): ReviewHeatmapLine[] {
  if (fallback.length === 0) {
    return primary;
  }

  const lineMap = new Map<string, ReviewHeatmapLine>();

  for (const entry of primary) {
    const normalized =
      typeof entry.lineText === "string"
        ? entry.lineText.replace(/\s+/g, " ").trim()
        : "";
    const key = `${entry.lineNumber ?? "unknown"}:${normalized}`;
    lineMap.set(key, entry);
  }

  for (const entry of fallback) {
    const normalized =
      typeof entry.lineText === "string"
        ? entry.lineText.replace(/\s+/g, " ").trim()
        : "";
    const key = `${entry.lineNumber ?? "unknown"}:${normalized}`;
    if (!lineMap.has(key)) {
      lineMap.set(key, entry);
    }
  }

  return Array.from(lineMap.values()).sort((a, b) => {
    const aLine = a.lineNumber ?? -1;
    const bLine = b.lineNumber ?? -1;
    if (aLine !== bLine) {
      return aLine - bLine;
    }
    return (a.lineText ?? "").localeCompare(b.lineText ?? "");
  });
}

/**
 * Simple Myers-like diff algorithm to compute line changes
 * Returns an array of operations: "=" for equal, "-" for delete, "+" for insert
 */
function computeLineDiff(
  oldLines: string[],
  newLines: string[]
): Array<{ type: "=" | "-" | "+"; oldIdx?: number; newIdx?: number; line: string }> {
  // Build a simple LCS-based diff
  const m = oldLines.length;
  const n = newLines.length;

  // Create LCS table
  const dp: number[][] = Array.from({ length: m + 1 }, () => Array(n + 1).fill(0));

  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      if (oldLines[i - 1] === newLines[j - 1]) {
        dp[i]![j] = (dp[i - 1]?.[j - 1] ?? 0) + 1;
      } else {
        dp[i]![j] = Math.max(dp[i - 1]?.[j] ?? 0, dp[i]?.[j - 1] ?? 0);
      }
    }
  }

  // Backtrack to find the diff
  let i = m;
  let j = n;
  const operations: Array<{ type: "=" | "-" | "+"; oldIdx?: number; newIdx?: number; line: string }> = [];

  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldLines[i - 1] === newLines[j - 1]) {
      operations.unshift({ type: "=", oldIdx: i - 1, newIdx: j - 1, line: oldLines[i - 1]! });
      i--;
      j--;
    } else if (j > 0 && (i === 0 || (dp[i]?.[j - 1] ?? 0) >= (dp[i - 1]?.[j] ?? 0))) {
      operations.unshift({ type: "+", newIdx: j - 1, line: newLines[j - 1]! });
      j--;
    } else if (i > 0) {
      operations.unshift({ type: "-", oldIdx: i - 1, line: oldLines[i - 1]! });
      i--;
    }
  }

  return operations;
}

/**
 * Generate unified diff hunks from line operations with context
 */
function generateUnifiedHunks(
  operations: Array<{ type: "=" | "-" | "+"; oldIdx?: number; newIdx?: number; line: string }>,
  contextLines: number = 3
): string[] {
  const hunks: string[] = [];

  // Find ranges of changes with context
  const changeIndices: number[] = [];
  for (let i = 0; i < operations.length; i++) {
    if (operations[i]?.type !== "=") {
      changeIndices.push(i);
    }
  }

  if (changeIndices.length === 0) {
    // No changes - return empty
    return [];
  }

  // Group changes into hunks (merge if within 2*contextLines of each other)
  const hunkRanges: Array<{ start: number; end: number }> = [];
  let currentStart = Math.max(0, (changeIndices[0] ?? 0) - contextLines);
  let currentEnd = Math.min(operations.length - 1, (changeIndices[0] ?? 0) + contextLines);

  for (let i = 1; i < changeIndices.length; i++) {
    const changeIdx = changeIndices[i]!;
    const rangeStart = Math.max(0, changeIdx - contextLines);
    const rangeEnd = Math.min(operations.length - 1, changeIdx + contextLines);

    if (rangeStart <= currentEnd + 1) {
      // Merge with current hunk
      currentEnd = rangeEnd;
    } else {
      // Start new hunk
      hunkRanges.push({ start: currentStart, end: currentEnd });
      currentStart = rangeStart;
      currentEnd = rangeEnd;
    }
  }
  hunkRanges.push({ start: currentStart, end: currentEnd });

  // Generate each hunk
  for (const range of hunkRanges) {
    let oldStart = 1;
    let newStart = 1;

    // Calculate starting line numbers
    for (let i = 0; i < range.start; i++) {
      const op = operations[i];
      if (op?.type === "=" || op?.type === "-") {
        oldStart++;
      }
      if (op?.type === "=" || op?.type === "+") {
        newStart++;
      }
    }

    let oldCount = 0;
    let newCount = 0;
    const lines: string[] = [];

    for (let i = range.start; i <= range.end; i++) {
      const op = operations[i];
      if (!op) continue;

      if (op.type === "=") {
        lines.push(` ${op.line}`);
        oldCount++;
        newCount++;
      } else if (op.type === "-") {
        lines.push(`-${op.line}`);
        oldCount++;
      } else if (op.type === "+") {
        lines.push(`+${op.line}`);
        newCount++;
      }
    }

    hunks.push(`@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`);
    hunks.push(...lines);
  }

  return hunks;
}

function buildUnifiedDiffFromContent(entry: ReplaceDiffEntry): string {
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

  // Handle empty file edge cases
  if (oldLines.length === 1 && oldLines[0] === "") {
    oldLines.length = 0;
  }
  if (newLines.length === 1 && newLines[0] === "") {
    newLines.length = 0;
  }

  let hunks: string[] = [];

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
    // Compute actual diff using LCS algorithm
    const operations = computeLineDiff(oldLines, newLines);
    hunks = generateUnifiedHunks(operations, 3);

    // If no hunks (files are identical), return early
    if (hunks.length === 0) {
      return "";
    }
  }

  return [...header, ...hunks].join("\n");
}

function buildDiffText(entry: ReplaceDiffEntry): string | null {
  const patch = entry.patch ?? buildUnifiedDiffFromContent(entry);
  if (!patch) {
    return null;
  }
  if (patch.startsWith("diff --git")) {
    return patch;
  }

  const oldPath =
    entry.status === "added" ? "/dev/null" : entry.oldPath ?? entry.filePath;
  const newPath = entry.status === "deleted" ? "/dev/null" : entry.filePath;

  const gitOldLabel = `a/${entry.oldPath ?? entry.filePath}`;
  const gitNewLabel = `b/${entry.filePath}`;
  const oldLabel = oldPath === "/dev/null" ? "/dev/null" : gitOldLabel;
  const newLabel = newPath === "/dev/null" ? "/dev/null" : gitNewLabel;

  return [
    `diff --git ${gitOldLabel} ${gitNewLabel}`,
    `--- ${oldLabel}`,
    `+++ ${newLabel}`,
    patch,
    "",
  ].join("\n");
}

function buildRenameMissingDiffMessage(entry: ReplaceDiffEntry): string {
  const previousPath = entry.oldPath;
  if (!previousPath) {
    return "File renamed without diff details.";
  }
  return `File renamed from ${previousPath} to ${entry.filePath} without diff details.`;
}

function buildChangeKeyIndex(diff: FileData | null): Map<string, string> {
  const map = new Map<string, string>();
  if (!diff) {
    return map;
  }

  for (const hunk of diff.hunks) {
    for (const change of hunk.changes) {
      const newLineNumber = computeNewLineNumber(change);
      if (newLineNumber > 0) {
        map.set(buildLineKey("new", newLineNumber), getChangeKey(change));
      }

      const oldLineNumber = computeOldLineNumber(change);
      if (oldLineNumber > 0) {
        map.set(buildLineKey("old", oldLineNumber), getChangeKey(change));
      }
    }
  }

  return map;
}

function buildLineKey(side: DiffLineSide, lineNumber: number): string {
  return `${side}:${lineNumber}`;
}

function findScrollContainer(element: HTMLElement | null): HTMLElement | null {
  if (typeof window === "undefined" || !element) {
    return null;
  }

  let current: HTMLElement | null = element.parentElement;
  while (current) {
    if (current === document.body || current === document.documentElement) {
      return null;
    }
    const style = window.getComputedStyle(current);
    const overflowY = style.overflowY;
    const overflow = style.overflow;
    if (
      overflowY === "auto" ||
      overflowY === "scroll" ||
      overflowY === "overlay" ||
      overflow === "auto" ||
      overflow === "scroll" ||
      overflow === "overlay"
    ) {
      return current;
    }
    current = current.parentElement;
  }
  return null;
}

function scrollElementToViewportCenter(
  element: HTMLElement,
  {
    behavior = "auto",
    scrollContainer,
  }: { behavior?: ScrollBehavior; scrollContainer?: HTMLElement | null } = {}
): void {
  if (typeof window === "undefined") {
    return;
  }

  if (scrollContainer) {
    const containerRect = scrollContainer.getBoundingClientRect();
    const elementRect = element.getBoundingClientRect();
    const viewportHeight = scrollContainer.clientHeight;
    if (viewportHeight === 0) {
      return;
    }
    const currentScrollTop = scrollContainer.scrollTop;
    const currentScrollLeft = scrollContainer.scrollLeft;
    const scrollHeight = scrollContainer.scrollHeight;

    const elementTop = elementRect.top - containerRect.top + currentScrollTop;
    const halfViewport = Math.max((viewportHeight - elementRect.height) / 2, 0);
    const rawTargetTop = elementTop - halfViewport;
    const maxScrollTop = Math.max(scrollHeight - viewportHeight, 0);
    const targetTop = Math.max(0, Math.min(rawTargetTop, maxScrollTop));

    scrollContainer.scrollTo({
      top: targetTop,
      left: currentScrollLeft,
      behavior,
    });
    return;
  }

  const rect = element.getBoundingClientRect();
  const viewportHeight =
    window.innerHeight || document.documentElement?.clientHeight || 0;
  if (viewportHeight === 0) {
    return;
  }

  const currentScrollY =
    window.scrollY ??
    window.pageYOffset ??
    document.documentElement?.scrollTop ??
    0;
  const currentScrollX =
    window.scrollX ??
    window.pageXOffset ??
    document.documentElement?.scrollLeft ??
    0;
  const scrollHeight = document.documentElement?.scrollHeight ?? 0;

  const halfViewport = Math.max((viewportHeight - rect.height) / 2, 0);
  const rawTargetTop = rect.top + currentScrollY - halfViewport;
  const maxScrollTop = Math.max(scrollHeight - viewportHeight, 0);
  const targetTop = Math.max(0, Math.min(rawTargetTop, maxScrollTop));

  window.scrollTo({
    top: targetTop,
    left: currentScrollX,
    behavior,
  });
}

function buildFileTree(files: ReplaceDiffEntry[]): FileTreeNode[] {
  const root: FileTreeNode = {
    name: "",
    path: "",
    children: [],
  };

  for (const file of files) {
    const segments = file.filePath.split("/");
    let current = root;

    segments.forEach((segment, index) => {
      const path =
        index === 0
          ? segment
          : `${current.path ? `${current.path}/` : ""}${segment}`;

      let child = current.children.find((node) => node.name === segment);

      if (!child) {
        child = {
          name: segment,
          path,
          children: [],
        };
        current.children.push(child);
      }

      if (index === segments.length - 1) {
        child.file = file;
      }

      current = child;
    });
  }

  return root.children;
}

function collectDirectoryPaths(nodes: FileTreeNode[]): string[] {
  const paths: string[] = [];

  for (const node of nodes) {
    if (node.children.length > 0) {
      paths.push(node.path);
      paths.push(...collectDirectoryPaths(node.children));
    }
  }

  return paths;
}

function getParentPaths(path: string): string[] {
  const parts = path.split("/");
  const parents: string[] = [];
  for (let i = 1; i < parts.length; i += 1) {
    parents.push(parts.slice(0, i).join("/"));
  }
  return parents;
}

const COLOR_SECTION_METADATA: Record<
  keyof HeatmapColorSettings,
  { title: string; helper: string }
> = {
  line: {
    title: "Line background gradient",
    helper: "",
  },
  token: {
    title: "Token highlight gradient",
    helper: "",
  },
};

function isValidHexColor(value: string): boolean {
  return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(value);
}

const ReviewProgressIndicator = memo(function ReviewProgressIndicator({
  totalFileCount,
  processedFileCount,
  isLoading,
}: {
  totalFileCount: number;
  processedFileCount: number | null;
  isLoading: boolean;
}) {
  const pendingFileCount =
    processedFileCount === null
      ? Math.max(totalFileCount, 0)
      : Math.max(totalFileCount - processedFileCount, 0);
  const progressPercent =
    processedFileCount === null || totalFileCount === 0
      ? 0
      : Math.min(100, (processedFileCount / totalFileCount) * 100);
  const statusText =
    processedFileCount === null
      ? "Loading file progress..."
      : pendingFileCount === 0
        ? "All files processed"
        : `${processedFileCount} processed • ${pendingFileCount} pending`;
  const processedBadgeText =
    processedFileCount === null ? "— done" : `${processedFileCount} done`;
  const pendingBadgeText =
    processedFileCount === null ? "— waiting" : `${pendingFileCount} waiting`;
  const isFullyProcessed =
    processedFileCount !== null && pendingFileCount === 0;
  const shouldPulsePending =
    processedFileCount === null || pendingFileCount > 0;

  return (
    <div className="border border-neutral-200 bg-white px-4 py-3 text-xs text-neutral-600 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-300">
      <div className="flex items-center justify-between gap-2 text-[11px] font-semibold uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
        <span>Review progress</span>
        <span>{Math.round(progressPercent)}%</span>
      </div>
      <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-neutral-100 dark:bg-neutral-800">
        <div
          className={cn(
            "h-full rounded-full bg-sky-500 transition-all duration-300",
            isLoading ? "animate-pulse" : "",
            isFullyProcessed ? "bg-emerald-500" : ""
          )}
          style={{ width: `${progressPercent}%` }}
        />
      </div>
      <div className="mt-2 text-xs font-medium text-neutral-600 dark:text-neutral-300">
        {statusText}
      </div>
      <div className="mt-2 flex flex-wrap gap-2 text-[11px] font-semibold text-neutral-500 dark:text-neutral-400">
        <span className="rounded-full bg-neutral-100 px-2 py-0.5 dark:bg-neutral-800">
          {processedBadgeText}
        </span>
        <span
          className={cn(
            "rounded-full bg-neutral-100 px-2 py-0.5 dark:bg-neutral-800",
            shouldPulsePending ? "animate-pulse" : ""
          )}
        >
          {pendingBadgeText}
        </span>
      </div>
    </div>
  );
});

function HeatmapThresholdControl({
  value,
  onChange,
  colors,
  onColorsChange,
  selectedModel,
  onModelChange,
  selectedLanguage,
  onLanguageChange,
}: {
  value: number;
  onChange: (next: number) => void;
  colors: HeatmapColorSettings;
  onColorsChange: (next: HeatmapColorSettings) => void;
  selectedModel: HeatmapModelOptionValue;
  onModelChange: (next: HeatmapModelOptionValue) => void;
  selectedLanguage: TooltipLanguageValue;
  onLanguageChange: (next: TooltipLanguageValue) => void;
}) {
  const sliderId = useId();
  const descriptionId = `${sliderId}-description`;

  // Convert normalized value (0-1) to display percent (0-100)
  const displayPercent = Math.round(Math.min(Math.max(value, 0), 1) * 100);

  // Update parent on every change for smooth updates via useDeferredValue
  const handleSliderChange = useCallback(
    (event: ChangeEvent<HTMLInputElement>) => {
      const numeric = Number.parseInt(event.target.value, 10);
      if (Number.isNaN(numeric)) {
        return;
      }
      const normalized = Math.min(Math.max(numeric / 100, 0), 1);
      onChange(normalized);
    },
    [onChange]
  );

  const handleColorChange = useCallback(
    (section: keyof HeatmapColorSettings, stop: keyof HeatmapColorSettings["line"]) =>
      (event: ChangeEvent<HTMLInputElement>) => {
        const nextValue = event.target.value;
        if (
          !isValidHexColor(nextValue) ||
          nextValue === colors[section][stop]
        ) {
          return;
        }
        onColorsChange({
          ...colors,
          [section]: {
            ...colors[section],
            [stop]: nextValue,
          },
        });
      },
    [colors, onColorsChange]
  );

  const handleModelSelectChange = useCallback(
    (event: ChangeEvent<HTMLSelectElement>) => {
      const nextValue = normalizeHeatmapModel(event.target.value);
      onModelChange(nextValue);
    },
    [onModelChange]
  );

  const handleLanguageSelectChange = useCallback(
    (event: ChangeEvent<HTMLSelectElement>) => {
      const nextValue = normalizeTooltipLanguage(event.target.value);
      onLanguageChange(nextValue);
    },
    [onLanguageChange]
  );

  return (
    <div className="rounded border border-neutral-200 bg-white p-5 pt-4 text-sm text-neutral-700 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200">
      <div className="flex items-center justify-between gap-2">
        <label htmlFor={sliderId} className="text-xs font-medium text-neutral-700 dark:text-neutral-200">
          &ldquo;Should review&rdquo; threshold
        </label>
        <span className="flex-shrink-0 text-xs font-semibold text-neutral-600 dark:text-neutral-300">
          ≥ <span className="tabular-nums">{displayPercent}%</span>
        </span>
      </div>
      <input
        id={sliderId}
        type="range"
        min={0}
        max={100}
        step={1}
        value={displayPercent}
        onChange={handleSliderChange}
        className="mt-3 w-full accent-sky-500"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={displayPercent}
        aria-valuetext={`"Should review" threshold ${displayPercent} percent`}
        aria-describedby={descriptionId}
      />
      <p id={descriptionId} className="mt-2 text-xs text-neutral-500 dark:text-neutral-400">
        Only show heatmap highlights with a score at or above this value.
      </p>
      <div className="mt-4 space-y-5">
        {(
          Object.keys(COLOR_SECTION_METADATA) as Array<keyof HeatmapColorSettings>
        ).map((section) => {
          const meta = COLOR_SECTION_METADATA[section];
          return (
            <div key={section} className="space-y-2">
              <p className="text-xs font-semibold text-neutral-700 dark:text-neutral-200">
                {meta.title}
              </p>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <label className="flex items-center justify-between gap-3 text-xs font-medium text-neutral-700 dark:text-neutral-200">
                  <span className="flex-1 text-left">Low score</span>
                  <input
                    type="color"
                    value={colors[section].start}
                    onChange={handleColorChange(section, "start")}
                    className="h-8 w-16 cursor-pointer rounded border border-neutral-300 bg-transparent p-0 dark:border-neutral-600"
                    aria-label={`${meta.title} low score color`}
                  />
                </label>
                <label className="flex items-center justify-between gap-3 text-xs font-medium text-neutral-700 dark:text-neutral-200">
                  <span className="flex-1 text-left">High score</span>
                  <input
                    type="color"
                    value={colors[section].end}
                    onChange={handleColorChange(section, "end")}
                    className="h-8 w-16 cursor-pointer rounded border border-neutral-300 bg-transparent p-0 dark:border-neutral-600"
                    aria-label={`${meta.title} high score color`}
                  />
                </label>
              </div>
            </div>
          );
        })}
      </div>
      <div className="mt-4 grid grid-cols-1 gap-4">
        <div className="space-y-2">
          <p className="text-xs font-semibold text-neutral-700 dark:text-neutral-200">Model</p>
          <div className="relative">
            <select
              value={selectedModel}
              onChange={handleModelSelectChange}
              aria-label="Heatmap model preference"
              className="w-full appearance-none border border-neutral-300 bg-white px-3 py-1.5 text-xs font-semibold text-neutral-800 transition focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
            >
              {HEATMAP_MODEL_OPTIONS.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
            <ChevronDown
              className="pointer-events-none absolute right-3 top-1/2 h-3 w-3 -translate-y-1/2 text-neutral-500"
              aria-hidden
            />
          </div>
        </div>
        <div className="space-y-2">
          <p className="text-xs font-semibold text-neutral-700 dark:text-neutral-200">
            Tooltip Language
          </p>
          <div className="relative">
            <select
              value={selectedLanguage}
              onChange={handleLanguageSelectChange}
              aria-label="Tooltip language preference"
              className="w-full appearance-none border border-neutral-300 bg-white px-3 py-1.5 text-xs font-semibold text-neutral-800 transition focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
            >
              {TOOLTIP_LANGUAGE_OPTIONS.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
            <ChevronDown
              className="pointer-events-none absolute right-3 top-1/2 h-3 w-3 -translate-y-1/2 text-neutral-500"
              aria-hidden
            />
          </div>
        </div>
      </div>
    </div>
  );
}

type ErrorNavigatorProps = {
  totalCount: number;
  currentIndex: number | null;
  onPrevious: (options?: FocusNavigateOptions) => void;
  onNext: (options?: FocusNavigateOptions) => void;
};

function ErrorNavigator({
  totalCount,
  currentIndex,
  onPrevious,
  onNext,
}: ErrorNavigatorProps) {
  if (totalCount === 0) {
    return null;
  }

  const hasSelection =
    typeof currentIndex === "number" &&
    currentIndex >= 0 &&
    currentIndex < totalCount;
  const displayIndex = hasSelection ? currentIndex + 1 : null;

  return (
    <TooltipProvider delayDuration={120} skipDelayDuration={120}>
      <div className="flex items-center gap-3 border border-neutral-200 bg-white/95 px-3 py-1 text-xs font-medium text-neutral-700 backdrop-blur dark:border-neutral-700 dark:bg-neutral-900/95 dark:text-neutral-200">
        <span aria-live="polite" className="flex items-center gap-1">
          {hasSelection && displayIndex !== null ? (
            <>
              <span>Highlight</span>
              <span className="font-mono tabular-nums">{displayIndex}</span>
              <span>of</span>
              <span className="font-mono tabular-nums">{totalCount}</span>
            </>
          ) : (
            <>
              <span className="font-mono tabular-nums">{totalCount}</span>
              <span>{totalCount === 1 ? "highlight" : "highlights"}</span>
            </>
          )}
        </span>
        <div className="flex items-center gap-1">
          <Tooltip delayDuration={120}>
            <TooltipTrigger asChild>
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onPrevious();
                }}
                className="inline-flex h-6 w-6 items-center justify-center border border-neutral-200 bg-white text-neutral-600 transition hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-sky-500 disabled:cursor-not-allowed disabled:opacity-40 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:bg-neutral-800"
                aria-label="Go to previous highlight (Shift+K)"
                disabled={totalCount === 0}
              >
                <ChevronLeft className="h-3.5 w-3.5" aria-hidden />
              </button>
            </TooltipTrigger>
            <TooltipContent
              side="bottom"
              align="center"
              className="flex items-center gap-2 rounded-md border border-neutral-200 bg-white px-2 py-1 text-[11px] font-medium text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
            >
              <span>Previous highlight</span>
              <span className="rounded border border-neutral-200 bg-neutral-50 px-1 py-0.5 font-mono text-[10px] uppercase text-neutral-500 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-300">
                Shift+K
              </span>
            </TooltipContent>
          </Tooltip>
          <Tooltip delayDuration={120}>
            <TooltipTrigger asChild>
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onNext();
                }}
                className="inline-flex h-6 w-6 items-center justify-center border border-neutral-200 bg-white text-neutral-600 transition hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-sky-500 disabled:cursor-not-allowed disabled:opacity-40 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:bg-neutral-800"
                aria-label="Go to next highlight (Shift+J)"
                disabled={totalCount === 0}
              >
                <ChevronRight className="h-3.5 w-3.5" aria-hidden />
              </button>
            </TooltipTrigger>
            <TooltipContent
              side="bottom"
              align="center"
              className="flex items-center gap-2 rounded-md border border-neutral-200 bg-white px-2 py-1 text-[11px] font-medium text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
            >
              <span>Next highlight</span>
              <span className="rounded border border-neutral-200 bg-neutral-50 px-1 py-0.5 font-mono text-[10px] uppercase text-neutral-500 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-300">
                Shift+J
              </span>
            </TooltipContent>
          </Tooltip>
        </div>
      </div>
    </TooltipProvider>
  );
}

type FileTreeNavigatorProps = {
  nodes: FileTreeNode[];
  activePath: string;
  expandedPaths: Set<string>;
  onToggleDirectory: (path: string) => void;
  onSelectFile: (path: string) => void;
  depth?: number;
};

function FileTreeNavigator({
  nodes,
  activePath,
  expandedPaths,
  onToggleDirectory,
  onSelectFile,
  depth = 0,
}: FileTreeNavigatorProps) {
  return (
    <div className="space-y-0.5">
      {nodes.map((node) => {
        const isDirectory = node.children.length > 0;
        const isExpanded = expandedPaths.has(node.path);
        const isActive = activePath === node.path;

        if (isDirectory) {
          return (
            <div key={node.path}>
              <button
                type="button"
                onClick={() => onToggleDirectory(node.path)}
                className={cn(
                  "flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-sm transition hover:bg-neutral-100 dark:hover:bg-neutral-800",
                  isExpanded ? "text-neutral-900 dark:text-neutral-100" : "text-neutral-700 dark:text-neutral-300"
                )}
                style={{ paddingLeft: depth * 14 + 10 }}
              >
                {isExpanded ? (
                  <ChevronDown
                    className="h-4 w-4 text-neutral-500 flex-shrink-0"
                    style={{ minWidth: "16px", minHeight: "16px" }}
                  />
                ) : (
                  <ChevronRight
                    className="h-4 w-4 text-neutral-500 flex-shrink-0"
                    style={{ minWidth: "16px", minHeight: "16px" }}
                  />
                )}
                {isExpanded ? (
                  <FolderOpen
                    className="h-4 w-4 text-neutral-500 flex-shrink-0 pr-0.5"
                    style={{ minWidth: "14px", minHeight: "14px" }}
                  />
                ) : (
                  <Folder
                    className="h-4 w-4 text-neutral-500 flex-shrink-0 pr-0.5"
                    style={{ minWidth: "14px", minHeight: "14px" }}
                  />
                )}
                <span className="truncate">{node.name}</span>
              </button>
              {isExpanded ? (
                <div className="mt-0.5">
                  <FileTreeNavigator
                    nodes={node.children}
                    activePath={activePath}
                    expandedPaths={expandedPaths}
                    onToggleDirectory={onToggleDirectory}
                    onSelectFile={onSelectFile}
                    depth={depth + 1}
                  />
                </div>
              ) : null}
            </div>
          );
        }

        return (
          <button
            key={node.path}
            type="button"
            onClick={() => onSelectFile(node.path)}
            className={cn(
              "flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-sm transition hover:bg-neutral-100 dark:hover:bg-neutral-800",
              isActive
                ? "bg-sky-100/80 text-sky-900 font-semibold dark:bg-sky-900/40 dark:text-sky-100"
                : "text-neutral-700 dark:text-neutral-300"
            )}
            style={{ paddingLeft: depth * 14 + 32 }}
          >
            <span className="truncate">{node.name}</span>
            {node.isLoading ? (
              <Tooltip delayDuration={300}>
                <TooltipTrigger asChild>
                  <span className="inline-flex items-center ml-auto">
                    <Loader2 className="h-3.5 w-3.5 text-sky-500 animate-spin flex-shrink-0" />
                  </span>
                </TooltipTrigger>
                <TooltipContent
                  side="right"
                  align="center"
                  showArrow={false}
                  className="rounded-md border border-neutral-200 bg-white px-2.5 py-1.5 text-xs text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                >
                  AI review in progress...
                </TooltipContent>
              </Tooltip>
            ) : null}
          </button>
        );
      })}
    </div>
  );
}

type FileDiffCardProps = {
  entry: ParsedFileDiff;
  status: HeatmapFileStatus;
  reviewHeatmap: ReviewHeatmapLine[];
  diffHeatmap: DiffHeatmap | null;
  scrollContainer: HTMLElement | null;
  focusedLine: DiffLineLocation | null;
  focusedChangeKey: string | null;
  autoTooltipLine: DiffLineLocation | null;
  isLoading: boolean;
  isCollapsed: boolean;
  filePath: string;
  onFileCollapseChange: (filePath: string, collapsed: boolean) => void;
  heatmapThreshold: number;
  heatmapColors: HeatmapColorSettings;
};

function areDiffLineLocationsEqual(
  a: DiffLineLocation | null,
  b: DiffLineLocation | null
): boolean {
  if (a === b) return true;
  if (a === null || b === null) return false;
  return a.side === b.side && a.lineNumber === b.lineNumber;
}

function areReviewHeatmapLinesEqual(
  a: ReviewHeatmapLine[],
  b: ReviewHeatmapLine[]
): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const lineA = a[i];
    const lineB = b[i];
    if (!lineA || !lineB) return false;
    if (
      lineA.lineNumber !== lineB.lineNumber ||
      lineA.lineText !== lineB.lineText ||
      lineA.score !== lineB.score ||
      lineA.reason !== lineB.reason
    ) {
      return false;
    }
  }
  return true;
}

function areFileDiffCardPropsEqual(
  prev: FileDiffCardProps,
  next: FileDiffCardProps
): boolean {
  return (
    prev.entry === next.entry &&
    prev.status === next.status &&
    prev.focusedChangeKey === next.focusedChangeKey &&
    prev.isLoading === next.isLoading &&
    prev.isCollapsed === next.isCollapsed &&
    prev.filePath === next.filePath &&
    prev.onFileCollapseChange === next.onFileCollapseChange &&
    prev.heatmapThreshold === next.heatmapThreshold &&
    prev.heatmapColors === next.heatmapColors &&
    prev.scrollContainer === next.scrollContainer &&
    areDiffLineLocationsEqual(prev.focusedLine, next.focusedLine) &&
    areDiffLineLocationsEqual(prev.autoTooltipLine, next.autoTooltipLine) &&
    prev.diffHeatmap === next.diffHeatmap &&
    areReviewHeatmapLinesEqual(prev.reviewHeatmap, next.reviewHeatmap)
  );
}

const FileDiffCard = memo(function FileDiffCardComponent({
  entry,
  status,
  reviewHeatmap,
  diffHeatmap,
  scrollContainer,
  focusedLine,
  focusedChangeKey,
  autoTooltipLine,
  isLoading,
  isCollapsed,
  filePath,
  onFileCollapseChange,
  heatmapThreshold,
  heatmapColors,
}: FileDiffCardProps) {
  const cardRef = useRef<HTMLDivElement | null>(null);

  // Memoize the collapse handler for this specific file
  const handleCollapseChange = useCallback(
    (collapsed: boolean) => {
      onFileCollapseChange(filePath, collapsed);
    },
    [filePath, onFileCollapseChange]
  );

  useEffect(() => {
    if (!focusedChangeKey) {
      return;
    }
    onFileCollapseChange(filePath, false);
  }, [focusedChangeKey, filePath, onFileCollapseChange]);

  useEffect(() => {
    if (!focusedChangeKey) {
      return;
    }
    const currentCard = cardRef.current;
    if (!currentCard) {
      return;
    }

    // Use a double requestAnimationFrame to ensure DOM has fully laid out
    // after the card expands. The first frame schedules the work, the second
    // ensures the layout pass is complete before scrolling.
    const frameId = window.requestAnimationFrame(() => {
      const innerFrameId = window.requestAnimationFrame(() => {
        const targetCell = currentCard.querySelector<HTMLElement>(
          `[data-change-key="${focusedChangeKey}"]`
        );
        if (!targetCell) {
          return;
        }

        const targetRow = targetCell.closest("tr");
        const scrollTarget =
          targetRow instanceof HTMLElement ? targetRow : targetCell;
        scrollElementToViewportCenter(scrollTarget, { scrollContainer });
      });
      // Store inner frame ID for cleanup
      (currentCard as HTMLDivElement & { _innerFrameId?: number })._innerFrameId = innerFrameId;
    });

    return () => {
      window.cancelAnimationFrame(frameId);
      const innerFrameId = (currentCard as HTMLDivElement & { _innerFrameId?: number })._innerFrameId;
      if (innerFrameId !== undefined) {
        window.cancelAnimationFrame(innerFrameId);
      }
    };
  }, [focusedChangeKey, scrollContainer]);

  return (
    <div id={entry.anchorId} ref={cardRef}>
      <HeatmapDiffViewer
        diffText={entry.diffText}
        parsedDiff={entry.diff}
        filename={entry.entry.filePath}
        status={status}
        additions={entry.entry.additions ?? 0}
        deletions={entry.entry.deletions ?? 0}
        reviewHeatmap={reviewHeatmap}
        heatmapThreshold={heatmapThreshold}
        diffHeatmap={diffHeatmap}
        heatmapColors={heatmapColors}
        focusedLine={focusedLine}
        autoTooltipLine={autoTooltipLine}
        isLoading={isLoading}
        errorMessage={entry.error ?? null}
        defaultCollapsed={isCollapsed}
        onCollapseChange={handleCollapseChange}
        className="border-x border-b border-neutral-200 dark:border-neutral-700"
      />
    </div>
  );
}, areFileDiffCardPropsEqual);

export function GitDiffHeatmapReviewViewer({
  diffs,
  fileOutputs,
  streamStateByFile,
  primaryRepoFullName,
  shouldPrefixDiffs = false,
  heatmapThreshold = 0,
  heatmapColors,
  heatmapModel,
  heatmapTooltipLanguage,
  onHeatmapThresholdChange,
  onHeatmapColorsChange,
  onHeatmapModelChange,
  onHeatmapTooltipLanguageChange,
  onControlsChange,
}: GitDiffHeatmapReviewViewerProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [scrollContainer, setScrollContainer] = useState<HTMLElement | null>(null);
  const kitty = useMemo(() => {
    return kitties[Math.floor(Math.random() * kitties.length)];
  }, []);
  // Use useDeferredValue to defer color changes and prevent blocking renders
  // when color pickers are being used. This matches the 0github implementation.
  const normalizedHeatmapColors = useMemo(
    () => normalizeHeatmapColors(heatmapColors),
    [heatmapColors]
  );
  const effectiveHeatmapColors = useDeferredValue(normalizedHeatmapColors);
  const effectiveHeatmapModel = normalizeHeatmapModel(
    heatmapModel ?? DEFAULT_HEATMAP_MODEL
  );
  const effectiveTooltipLanguage = normalizeTooltipLanguage(
    heatmapTooltipLanguage ?? DEFAULT_TOOLTIP_LANGUAGE
  );

  const deferredHeatmapThreshold = useDeferredValue(heatmapThreshold);
  const emptyStreamStateMap = useMemo(
    () => new Map<string, StreamFileState>(),
    []
  );
  const streamStateMap = streamStateByFile ?? emptyStreamStateMap;

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    setScrollContainer(findScrollContainer(rootRef.current));
  }, []);

  const fileOutputIndex = useMemo(() => {
    const map = new Map<string, HeatmapFileOutput>();
    for (const output of fileOutputs ?? []) {
      const key =
        shouldPrefixDiffs && primaryRepoFullName
          ? `${primaryRepoFullName}:${output.filePath}`
          : output.filePath;
      map.set(key, output);
    }
    return map;
  }, [fileOutputs, primaryRepoFullName, shouldPrefixDiffs]);

  const sortedFiles = useMemo(() => {
    return [...diffs].sort((a, b) => {
      const aSegments = a.filePath.split("/");
      const bSegments = b.filePath.split("/");
      const minLength = Math.min(aSegments.length, bSegments.length);

      for (let i = 0; i < minLength; i += 1) {
        const aSegment = aSegments[i]!;
        const bSegment = bSegments[i]!;
        const aIsLast = i === aSegments.length - 1;
        const bIsLast = i === bSegments.length - 1;

        if (aSegment === bSegment) {
          continue;
        }

        if (aIsLast && !bIsLast) return 1;
        if (!aIsLast && bIsLast) return -1;

        return aSegment.localeCompare(bSegment);
      }

      return aSegments.length - bSegments.length;
    });
  }, [diffs]);

  const parsedDiffs = useMemo<ParsedFileDiff[]>(() => {
    return sortedFiles.map((entry) => {
      if (entry.isBinary) {
        return {
          entry,
          anchorId: entry.filePath,
          diff: null,
          diffText: "",
          error: `Binary file: ${entry.filePath}`,
        };
      }
      if (entry.contentOmitted) {
        return {
          entry,
          anchorId: entry.filePath,
          diff: null,
          diffText: "",
          error: `Content omitted: ${entry.filePath}`,
        };
      }

      const diffText = buildDiffText(entry);
      if (!diffText) {
        const renameMessage =
          entry.status === "renamed"
            ? buildRenameMissingDiffMessage(entry)
            : null;
        return {
          entry,
          anchorId: entry.filePath,
          diff: null,
          diffText: "",
          error: renameMessage ?? undefined,
        };
      }

      try {
        const [diff] = parseDiff(diffText, {
          nearbySequences: "zip",
        });
        return {
          entry,
          anchorId: entry.filePath,
          diff: diff ?? null,
          diffText,
        };
      } catch (error) {
        const message =
          error instanceof Error
            ? error.message
            : "Unable to parse diff payload.";
        return {
          entry,
          anchorId: entry.filePath,
          diff: null,
          diffText,
          error: message,
        };
      }
    });
  }, [sortedFiles]);

  const fileEntries = useMemo<FileDiffViewModel[]>(() => {
    return parsedDiffs.map((entry) => {
      const review = fileOutputIndex.get(entry.entry.filePath) ?? null;
      const streamState = streamStateMap.get(entry.entry.filePath) ?? null;
      const streamedHeatmap = streamState?.lines ?? [];
      const reviewHeatmapFromCodex = review
        ? parseReviewHeatmap(review.codexReviewOutput)
        : [];
      const reviewHeatmap = mergeHeatmapLines(
        streamedHeatmap,
        reviewHeatmapFromCodex
      );
      const diffHeatmapArtifacts =
        entry.diff && reviewHeatmap.length > 0
          ? prepareDiffHeatmapArtifacts(entry.diff, reviewHeatmap)
          : null;

      return {
        entry,
        reviewHeatmap,
        diffHeatmapArtifacts,
        diffHeatmap: diffHeatmapArtifacts
          ? renderDiffHeatmapFromArtifacts(
              diffHeatmapArtifacts,
              deferredHeatmapThreshold
            )
          : null,
        changeKeyByLine: buildChangeKeyIndex(entry.diff),
      };
    });
  }, [
    deferredHeatmapThreshold,
    fileOutputIndex,
    parsedDiffs,
    streamStateMap,
  ]);

  const errorTargets = useMemo<ReviewErrorTarget[]>(() => {
    const targets: ReviewErrorTarget[] = [];

    for (const fileEntry of fileEntries) {
      const { entry, diffHeatmap, changeKeyByLine } = fileEntry;
      if (!diffHeatmap || diffHeatmap.totalEntries === 0) {
        continue;
      }

      const addTargets = (
        entriesMap: Map<number, ResolvedHeatmapLine>,
        side: DiffLineSide
      ) => {
        if (entriesMap.size === 0) {
          return;
        }

        const sortedEntries = Array.from(entriesMap.entries()).sort(
          (a, b) => a[0] - b[0]
        );

        for (const [lineNumber, metadata] of sortedEntries) {
          targets.push({
            id: `${entry.anchorId}:${side}:${lineNumber}`,
            anchorId: entry.anchorId,
            filePath: entry.entry.filePath,
            lineNumber,
            side,
            reason: metadata.reason ?? null,
            score: metadata.score ?? null,
            changeKey:
              changeKeyByLine.get(buildLineKey(side, lineNumber)) ?? null,
          });
        }
      };

      addTargets(diffHeatmap.entries, "new");
      addTargets(diffHeatmap.oldEntries, "old");
    }

    return targets;
  }, [fileEntries]);

  const targetCount = errorTargets.length;
  const [focusedErrorIndex, setFocusedErrorIndex] = useState<number | null>(
    null
  );
  const [autoTooltipTarget, setAutoTooltipTarget] =
    useState<ActiveTooltipTarget | null>(null);
  const autoTooltipTimeoutRef = useRef<number | null>(null);
  const focusChangeOriginRef = useRef<"user" | "auto">("auto");

  const clearAutoTooltip = useCallback(() => {
    if (
      typeof window !== "undefined" &&
      autoTooltipTimeoutRef.current !== null
    ) {
      window.clearTimeout(autoTooltipTimeoutRef.current);
      autoTooltipTimeoutRef.current = null;
    }
    setAutoTooltipTarget(null);
  }, []);

  const showAutoTooltipForTarget = useCallback(
    (target: ReviewErrorTarget, options?: { sticky?: boolean }) => {
      if (typeof window === "undefined") {
        return;
      }

      if (autoTooltipTimeoutRef.current !== null) {
        window.clearTimeout(autoTooltipTimeoutRef.current);
        autoTooltipTimeoutRef.current = null;
      }

      setAutoTooltipTarget({
        filePath: target.filePath,
        lineNumber: target.lineNumber,
        side: target.side,
      });

      const shouldStick = options?.sticky ?? false;

      if (!shouldStick) {
        autoTooltipTimeoutRef.current = window.setTimeout(() => {
          setAutoTooltipTarget((current) => {
            if (
              current &&
              current.filePath === target.filePath &&
              current.lineNumber === target.lineNumber &&
              current.side === target.side
            ) {
              return null;
            }
            return current;
          });
          autoTooltipTimeoutRef.current = null;
        }, 1800);
      }
    },
    []
  );

  useEffect(() => {
    if (targetCount === 0) {
      focusChangeOriginRef.current = "auto";
      setFocusedErrorIndex(null);
      return;
    }

    focusChangeOriginRef.current = "auto";
    setFocusedErrorIndex((previous) => {
      if (previous === null) {
        return previous;
      }
      if (previous >= targetCount) {
        return targetCount - 1;
      }
      return previous;
    });
  }, [targetCount]);

  useEffect(() => {
    if (targetCount === 0) {
      clearAutoTooltip();
    }
  }, [targetCount, clearAutoTooltip]);

  useEffect(() => {
    return () => {
      if (
        typeof window !== "undefined" &&
        autoTooltipTimeoutRef.current !== null
      ) {
        window.clearTimeout(autoTooltipTimeoutRef.current);
      }
    };
  }, []);

  const focusedError =
    focusedErrorIndex === null
      ? null
      : (errorTargets[focusedErrorIndex] ?? null);

  const fileTree = useMemo(() => {
    const tree = buildFileTree(sortedFiles);
    const addLoadingState = (nodes: FileTreeNode[]): FileTreeNode[] => {
      return nodes.map((node) => {
        if (node.file) {
          const streamState = streamStateMap.get(node.file.filePath);
          const isLoading =
            !fileOutputIndex.has(node.file.filePath) &&
            (!streamState || streamState.status === "pending");
          return {
            ...node,
            isLoading,
            children: addLoadingState(node.children),
          };
        }
        return {
          ...node,
          children: addLoadingState(node.children),
        };
      });
    };
    return addLoadingState(tree);
  }, [sortedFiles, fileOutputIndex, streamStateMap]);

  const directoryPaths = useMemo(
    () => collectDirectoryPaths(fileTree),
    [fileTree]
  );

  const hydratedInitialPath =
    typeof window !== "undefined"
      ? decodeURIComponent(window.location.hash.slice(1))
      : "";

  const firstPath = parsedDiffs[0]?.entry.filePath ?? "";
  const initialPath =
    hydratedInitialPath &&
    sortedFiles.some((file) => file.filePath === hydratedInitialPath)
      ? hydratedInitialPath
      : firstPath;

  const sidebarPanelId = useId();
  const [sidebarWidth, setSidebarWidth] = useState<number>(
    SIDEBAR_DEFAULT_WIDTH
  );
  const [isResizingSidebar, setIsResizingSidebar] = useState(false);
  const pointerStartXRef = useRef(0);
  const pointerStartWidthRef = useRef<number>(SIDEBAR_DEFAULT_WIDTH);
  const sidebarPointerMoveHandlerRef = useRef<
    ((event: PointerEvent) => void) | null
  >(null);
  const sidebarPointerUpHandlerRef = useRef<
    ((event: PointerEvent) => void) | null
  >(null);

  const [activePath, setActivePath] = useState<string>(initialPath);
  const [activeAnchor, setActiveAnchor] = useState<string>(initialPath);

  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => {
    const defaults = new Set<string>(directoryPaths);
    for (const parent of getParentPaths(initialPath)) {
      defaults.add(parent);
    }
    return defaults;
  });

  const [collapsedState, setCollapsedState] = useState<Map<string, boolean>>(
    () => new Map()
  );

  const totalAdditions = useMemo(
    () => diffs.reduce((sum, diff) => sum + (diff.additions ?? 0), 0),
    [diffs]
  );
  const totalDeletions = useMemo(
    () => diffs.reduce((sum, diff) => sum + (diff.deletions ?? 0), 0),
    [diffs]
  );

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

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const storedWidth = window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY);
    if (!storedWidth) {
      return;
    }
    const parsedWidth = Number.parseInt(storedWidth, 10);
    const clampedWidth = clampSidebarWidth(parsedWidth);
    setSidebarWidth((previous) =>
      previous === clampedWidth ? previous : clampedWidth
    );
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(
      SIDEBAR_WIDTH_STORAGE_KEY,
      String(Math.round(sidebarWidth))
    );
  }, [sidebarWidth]);

  useEffect(() => {
    if (typeof document === "undefined") {
      return;
    }
    if (!isResizingSidebar) {
      return;
    }
    const previousCursor = document.body.style.cursor;
    document.body.style.cursor = "col-resize";
    return () => {
      document.body.style.cursor = previousCursor;
    };
  }, [isResizingSidebar]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    return () => {
      if (sidebarPointerMoveHandlerRef.current) {
        window.removeEventListener(
          "pointermove",
          sidebarPointerMoveHandlerRef.current
        );
        sidebarPointerMoveHandlerRef.current = null;
      }
      if (sidebarPointerUpHandlerRef.current) {
        window.removeEventListener(
          "pointerup",
          sidebarPointerUpHandlerRef.current
        );
        window.removeEventListener(
          "pointercancel",
          sidebarPointerUpHandlerRef.current
        );
        sidebarPointerUpHandlerRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    setExpandedPaths(() => {
      const defaults = new Set<string>(directoryPaths);
      for (const parent of getParentPaths(activePath)) {
        defaults.add(parent);
      }
      return defaults;
    });
  }, [directoryPaths, activePath]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const hash = decodeURIComponent(window.location.hash.slice(1));
    if (hash && sortedFiles.some((file) => file.filePath === hash)) {
      setActivePath(hash);
      setActiveAnchor(hash);
    }
  }, [sortedFiles]);

  useEffect(() => {
    if (!activePath) {
      return;
    }

    setExpandedPaths((previous) => {
      const next = new Set(previous);
      for (const parent of getParentPaths(activePath)) {
        next.add(parent);
      }
      return next;
    });
  }, [activePath]);

  useEffect(() => {
    if (parsedDiffs.length === 0) {
      return;
    }
    if (typeof window === "undefined") {
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .map((entry) => ({
            id: entry.target.id,
            top: entry.target.getBoundingClientRect().top,
          }))
          .sort((a, b) => a.top - b.top);

        if (visible.length > 0 && visible[0]?.id) {
          setActiveAnchor(visible[0].id);
        }
      },
      {
        root: scrollContainer ?? null,
        rootMargin: "0px 0px -60% 0px",
        threshold: 0,
      }
    );

    const elements = parsedDiffs
      .map((entry) => document.getElementById(entry.anchorId))
      .filter((element): element is HTMLElement => Boolean(element));

    elements.forEach((element) => observer.observe(element));

    return () => {
      elements.forEach((element) => observer.unobserve(element));
      observer.disconnect();
    };
  }, [parsedDiffs, scrollContainer]);

  const handleSidebarResizePointerDown = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (event.pointerType === "mouse" && event.button !== 0) {
        return;
      }
      if (typeof window === "undefined") {
        return;
      }
      event.preventDefault();
      const handleElement = event.currentTarget;
      const pointerId = event.pointerId;
      pointerStartXRef.current = event.clientX;
      pointerStartWidthRef.current = sidebarWidth;
      setIsResizingSidebar(true);

      try {
        handleElement.focus({ preventScroll: true });
      } catch {
        handleElement.focus();
      }

      const handlePointerMove = (moveEvent: PointerEvent) => {
        const delta = moveEvent.clientX - pointerStartXRef.current;
        const nextWidth = clampSidebarWidth(
          pointerStartWidthRef.current + delta
        );
        setSidebarWidth((previous) =>
          previous === nextWidth ? previous : nextWidth
        );
      };

      const handlePointerTerminate = (upEvent: PointerEvent) => {
        if (upEvent.pointerId !== pointerId) {
          return;
        }
        if (handleElement.hasPointerCapture?.(pointerId)) {
          try {
            handleElement.releasePointerCapture(pointerId);
          } catch {
            // Ignore release failures.
          }
        }
        setIsResizingSidebar(false);
        if (sidebarPointerMoveHandlerRef.current) {
          window.removeEventListener(
            "pointermove",
            sidebarPointerMoveHandlerRef.current
          );
          sidebarPointerMoveHandlerRef.current = null;
        }
        if (sidebarPointerUpHandlerRef.current) {
          window.removeEventListener(
            "pointerup",
            sidebarPointerUpHandlerRef.current
          );
          window.removeEventListener(
            "pointercancel",
            sidebarPointerUpHandlerRef.current
          );
          sidebarPointerUpHandlerRef.current = null;
        }
      };

      sidebarPointerMoveHandlerRef.current = handlePointerMove;
      sidebarPointerUpHandlerRef.current = handlePointerTerminate;

      window.addEventListener("pointermove", handlePointerMove);
      window.addEventListener("pointerup", handlePointerTerminate);
      window.addEventListener("pointercancel", handlePointerTerminate);

      try {
        handleElement.setPointerCapture(pointerId);
      } catch {
        // Ignore pointer capture failures (e.g., Safari).
      }
    },
    [sidebarWidth, setIsResizingSidebar, setSidebarWidth]
  );

  const handleSidebarResizeKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      const key = event.key;
      if (key === "ArrowLeft" || key === "ArrowRight") {
        event.preventDefault();
        const delta = key === "ArrowLeft" ? -16 : 16;
        setSidebarWidth((previous) => clampSidebarWidth(previous + delta));
        return;
      }
      if (key === "Home") {
        event.preventDefault();
        setSidebarWidth(SIDEBAR_MIN_WIDTH);
        return;
      }
      if (key === "End") {
        event.preventDefault();
        setSidebarWidth(SIDEBAR_MAX_WIDTH);
        return;
      }
      if ((event.metaKey || event.ctrlKey) && key === "0") {
        event.preventDefault();
        setSidebarWidth(SIDEBAR_DEFAULT_WIDTH);
      }
    },
    [setSidebarWidth]
  );

  const handleSidebarResizeDoubleClick = useCallback(() => {
    setSidebarWidth(SIDEBAR_DEFAULT_WIDTH);
  }, [setSidebarWidth]);

  const handleNavigate = useCallback(
    (path: string, options?: NavigateOptions) => {
      setActivePath(path);

      const shouldUpdateAnchor = options?.updateAnchor ?? true;
      if (shouldUpdateAnchor) {
        setActiveAnchor(path);
      }

      if (typeof window === "undefined") {
        return;
      }

      const shouldUpdateHash = options?.updateHash ?? true;
      if (shouldUpdateHash) {
        window.location.hash = encodeURIComponent(path);
      }

      if (scrollContainer) {
        const target = document.getElementById(path);
        if (target) {
          target.scrollIntoView({ behavior: "auto", block: "start" });
        }
      }
    },
    [scrollContainer]
  );

  const handleFocusPrevious = useCallback(
    (options?: FocusNavigateOptions) => {
      if (targetCount === 0) {
        return;
      }

      focusChangeOriginRef.current = "user";
      const isKeyboard = options?.source === "keyboard";

      setFocusedErrorIndex((previous) => {
        const nextIndex =
          previous === null
            ? targetCount - 1
            : (previous - 1 + targetCount) % targetCount;
        const target = errorTargets[nextIndex] ?? null;

        if (isKeyboard) {
          if (target) {
            showAutoTooltipForTarget(target, { sticky: true });
          } else {
            clearAutoTooltip();
          }
        } else {
          clearAutoTooltip();
        }

        return nextIndex;
      });
    },
    [targetCount, errorTargets, clearAutoTooltip, showAutoTooltipForTarget]
  );

  const handleFocusNext = useCallback(
    (options?: FocusNavigateOptions) => {
      if (targetCount === 0) {
        return;
      }

      focusChangeOriginRef.current = "user";
      const isKeyboard = options?.source === "keyboard";

      setFocusedErrorIndex((previous) => {
        const nextIndex = previous === null ? 0 : (previous + 1) % targetCount;
        const target = errorTargets[nextIndex] ?? null;

        if (isKeyboard) {
          if (target) {
            showAutoTooltipForTarget(target, { sticky: true });
          } else {
            clearAutoTooltip();
          }
        } else {
          clearAutoTooltip();
        }

        return nextIndex;
      });
    },
    [targetCount, errorTargets, clearAutoTooltip, showAutoTooltipForTarget]
  );

  const handleToggleDirectory = useCallback((path: string) => {
    setExpandedPaths((previous) => {
      const next = new Set(previous);
      if (next.has(path)) {
        next.delete(path);
      } else {
        next.add(path);
      }
      return next;
    });
  }, []);

  // Stable callback for file collapse changes - avoids breaking FileDiffCard memoization
  const handleFileCollapseChange = useCallback(
    (filePath: string, collapsed: boolean) => {
      setCollapsedState((prev) => {
        const next = new Map(prev);
        next.set(filePath, collapsed);
        return next;
      });
    },
    []
  );

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    if (targetCount === 0) {
      return;
    }

    const handleKeydown = (event: KeyboardEvent) => {
      if (!event.shiftKey || event.metaKey || event.altKey || event.ctrlKey) {
        return;
      }

      const activeElement = document.activeElement;
      if (
        activeElement &&
        activeElement !== document.body &&
        activeElement instanceof HTMLElement &&
        (activeElement.tagName === "INPUT" ||
          activeElement.tagName === "TEXTAREA" ||
          activeElement.tagName === "SELECT" ||
          activeElement.isContentEditable)
      ) {
        return;
      }

      const key = event.key.toLowerCase();
      if (key === "j") {
        event.preventDefault();
        event.stopPropagation();
        handleFocusNext({ source: "keyboard" });
      } else if (key === "k") {
        event.preventDefault();
        event.stopPropagation();
        handleFocusPrevious({ source: "keyboard" });
      }
    };

    // Use capture phase to intercept before other handlers
    window.addEventListener("keydown", handleKeydown, true);

    return () => {
      window.removeEventListener("keydown", handleKeydown, true);
    };
  }, [handleFocusNext, handleFocusPrevious, targetCount]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        clearAutoTooltip();
      }
    };

    window.addEventListener("keydown", handleEscape);

    return () => {
      window.removeEventListener("keydown", handleEscape);
    };
  }, [clearAutoTooltip]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    if (!focusedError) {
      return;
    }

    const origin = focusChangeOriginRef.current;
    focusChangeOriginRef.current = "auto";
    const isUserInitiated = origin === "user";

    handleNavigate(focusedError.filePath, {
      updateAnchor: isUserInitiated,
      updateHash: isUserInitiated,
    });

    if (!isUserInitiated) {
      return;
    }

    if (focusedError.changeKey) {
      return;
    }

    // Use double requestAnimationFrame to ensure DOM is fully laid out
    // before attempting scroll, preventing flash/jitter
    let innerFrameId: number | undefined;
    const frame = window.requestAnimationFrame(() => {
      innerFrameId = window.requestAnimationFrame(() => {
        const article = document.getElementById(focusedError.anchorId);
        if (article) {
          scrollElementToViewportCenter(article, { scrollContainer });
        }
      });
    });

    return () => {
      window.cancelAnimationFrame(frame);
      if (innerFrameId !== undefined) {
        window.cancelAnimationFrame(innerFrameId);
      }
    };
  }, [focusedError, handleNavigate, scrollContainer]);

  const totalFileCount = sortedFiles.length;
  const processedFileCount = useMemo(() => {
    if (fileOutputs === undefined && streamStateMap.size === 0) {
      return null;
    }
    let count = 0;
    for (const file of sortedFiles) {
      const streamState = streamStateMap.get(file.filePath);
      const isStreamComplete =
        streamState !== undefined && streamState.status !== "pending";
      const isProcessed =
        fileOutputIndex.has(file.filePath) || isStreamComplete;
      if (isProcessed) {
        count += 1;
      }
    }
    return count;
  }, [fileOutputs, fileOutputIndex, sortedFiles, streamStateMap]);

  const isLoadingFileOutputs =
    fileOutputs === undefined &&
    (streamStateMap.size === 0 ||
      Array.from(streamStateMap.values()).some(
        (state) => state.status === "pending"
      ));

  if (totalFileCount === 0) {
    return (
      <div className="border border-neutral-200 bg-white p-8 text-sm text-neutral-600 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-300">
        This diff does not introduce any file changes.
      </div>
    );
  }

  return (
    <div ref={rootRef} className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-stretch lg:gap-0">
        <aside
          id={sidebarPanelId}
          className="relative w-full lg:sticky lg:top-[var(--cmux-diff-header-offset,0px)] lg:h-[calc(100vh-var(--cmux-diff-header-offset,0px))] lg:flex-none lg:flex lg:flex-col lg:w-[var(--pr-diff-sidebar-width)] lg:min-w-[15rem] lg:max-w-[32.5rem] lg:pl-3"
          style={
            {
              "--pr-diff-sidebar-width": `${sidebarWidth}px`,
            } as CSSProperties
          }
        >
          {/* Fixed at top - does not scroll */}
          <div className="flex-shrink-0 flex flex-col gap-3">
            <ReviewProgressIndicator
              totalFileCount={totalFileCount}
              processedFileCount={processedFileCount}
              isLoading={isLoadingFileOutputs}
            />
            <HeatmapThresholdControl
              value={heatmapThreshold}
              onChange={(next) => onHeatmapThresholdChange?.(next)}
              colors={effectiveHeatmapColors}
              onColorsChange={(next) => onHeatmapColorsChange?.(next)}
              selectedModel={effectiveHeatmapModel}
              onModelChange={(next) => onHeatmapModelChange?.(next)}
              selectedLanguage={effectiveTooltipLanguage}
              onLanguageChange={(next) => onHeatmapTooltipLanguageChange?.(next)}
            />
            {targetCount > 0 ? (
              <div className="flex justify-center">
                <ErrorNavigator
                  totalCount={targetCount}
                  currentIndex={focusedErrorIndex}
                  onPrevious={handleFocusPrevious}
                  onNext={handleFocusNext}
                />
              </div>
            ) : null}
          </div>
          {/* Scrollable content below - only the file tree */}
          <div className="flex flex-col gap-3 lg:overflow-y-auto lg:overscroll-contain lg:flex-1 lg:mt-3">
            <div>
              <FileTreeNavigator
                nodes={fileTree}
                activePath={activeAnchor}
                expandedPaths={expandedPaths}
                onToggleDirectory={handleToggleDirectory}
                onSelectFile={handleNavigate}
              />
            </div>
            <div className="h-[40px]" />
          </div>
        </aside>

        <div className="relative hidden lg:flex lg:flex-none lg:self-stretch lg:px-1 group/resize">
          <div
            className={cn(
              "flex h-full w-full cursor-col-resize select-none items-center justify-center touch-none rounded",
              "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-sky-500",
              isResizingSidebar
                ? "bg-sky-200/60 dark:bg-sky-900/40"
                : "bg-transparent hover:bg-sky-100/60 dark:hover:bg-sky-900/40"
            )}
            role="separator"
            aria-label="Resize file navigation panel"
            aria-orientation="vertical"
            aria-controls={sidebarPanelId}
            aria-valuenow={Math.round(sidebarWidth)}
            aria-valuemin={SIDEBAR_MIN_WIDTH}
            aria-valuemax={SIDEBAR_MAX_WIDTH}
            tabIndex={0}
            onPointerDown={handleSidebarResizePointerDown}
            onKeyDown={handleSidebarResizeKeyDown}
            onDoubleClick={handleSidebarResizeDoubleClick}
          >
            <span className="sr-only">
              Drag to adjust file navigation width
            </span>
            <div
              className={cn(
                "h-full w-[3px] rounded-full transition-opacity",
                isResizingSidebar
                  ? "bg-sky-500 dark:bg-sky-400 opacity-100"
                  : "bg-neutral-400 opacity-0 group-hover/resize:opacity-100 dark:bg-neutral-500"
              )}
              aria-hidden
            />
          </div>
        </div>

        <div className="flex-1 min-w-0 space-y-3 pr-3">
          {fileEntries.map((fileEntry) => {
            const status = mapStatusToHeatmapStatus(fileEntry.entry.entry.status);
            const isFocusedFile =
              focusedError?.filePath === fileEntry.entry.entry.filePath;
            const focusedLine = isFocusedFile
              ? focusedError
                ? {
                    side: focusedError.side,
                    lineNumber: focusedError.lineNumber,
                  }
                : null
              : null;
            const focusedChangeKey = isFocusedFile
              ? (focusedError?.changeKey ?? null)
              : null;
            const autoTooltipLine =
              isFocusedFile &&
              autoTooltipTarget &&
              autoTooltipTarget.filePath === fileEntry.entry.entry.filePath
                ? {
                    side: autoTooltipTarget.side,
                    lineNumber: autoTooltipTarget.lineNumber,
                  }
                : null;
            const streamState = streamStateMap.get(
              fileEntry.entry.entry.filePath
            );
            const isLoading =
              !fileOutputIndex.has(fileEntry.entry.entry.filePath) &&
              (!streamState || streamState.status === "pending");
            const isCollapsed =
              collapsedState.get(fileEntry.entry.entry.filePath) ?? false;

            return (
              <FileDiffCard
                key={fileEntry.entry.anchorId}
                entry={fileEntry.entry}
                status={status}
                reviewHeatmap={fileEntry.reviewHeatmap}
                diffHeatmap={fileEntry.diffHeatmap}
                scrollContainer={scrollContainer}
                focusedLine={focusedLine}
                focusedChangeKey={focusedChangeKey}
                autoTooltipLine={autoTooltipLine}
                isLoading={isLoading}
                isCollapsed={isCollapsed}
                filePath={fileEntry.entry.entry.filePath}
                onFileCollapseChange={handleFileCollapseChange}
                heatmapThreshold={heatmapThreshold}
                heatmapColors={effectiveHeatmapColors}
              />
            );
          })}
          <div className="h-[70dvh] w-full">
            <div className="px-3 py-6 text-center">
              <span className="select-none text-xs text-neutral-500 dark:text-neutral-400">
                You&apos;ve reached the end of the diff!
              </span>
              <div className="grid place-content-center">
                <pre className="mt-2 pb-20 select-none text-left text-[8px] font-mono text-neutral-500 dark:text-neutral-400">
                  {kitty}
                </pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
