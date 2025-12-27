// HeatmapDiffViewer - A GitHub-style diff viewer with heatmap highlighting
// Adapted from apps/www/components/pr/pull-request-diff-viewer.tsx

import {
  Fragment,
  memo,
  useMemo,
  useState,
  useCallback,
  useEffect,
  useRef,
  type ReactNode,
} from "react";
import {
  Decoration,
  Diff,
  Hunk,
  computeNewLineNumber,
  computeOldLineNumber,
  parseDiff,
  pickRanges,
  tokenize,
  type ChangeData,
  type FileData,
  type HunkTokens,
  type RenderGutter,
  type RenderToken,
} from "react-diff-view";
import "react-diff-view/style/index.css";
import { refractor } from "refractor/all";
import {
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
  Loader2,
} from "lucide-react";

import { cn } from "@/lib/utils";
import { useTheme } from "@/components/theme/use-theme";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  type DiffHeatmap,
  type ReviewHeatmapLine,
  type ResolvedHeatmapLine,
  HEATMAP_CHAR_CLASS_PREFIX,
  extractHeatmapGradientStep,
  prepareDiffHeatmapArtifacts,
  renderDiffHeatmapFromArtifacts,
} from "@/lib/heatmap";
import {
  buildThemedHeatmapGradientStyles,
  DEFAULT_HEATMAP_COLORS,
  type HeatmapColorSettings,
} from "./heatmap-gradient";

// ============================================================================
// Types
// ============================================================================

export type HeatmapDiffViewerProps = {
  /** The raw git diff string */
  diffText: string;
  /** Pre-parsed diff data (optional, avoids parsing on each render) */
  parsedDiff?: FileData | null;
  /** The filename being displayed */
  filename: string;
  /** File status: added, removed, modified, renamed, etc. */
  status?: "added" | "removed" | "modified" | "renamed" | "copied" | "changed";
  /** Number of lines added */
  additions?: number;
  /** Number of lines deleted */
  deletions?: number;
  /** Heatmap review data */
  reviewHeatmap?: ReviewHeatmapLine[];
  /** Threshold for filtering heatmap entries (0-1) */
  heatmapThreshold?: number;
  /** Precomputed heatmap for this diff (optional, avoids recalculation) */
  diffHeatmap?: DiffHeatmap | null;
  /** Custom heatmap colors */
  heatmapColors?: HeatmapColorSettings;
  /** Focused line for navigation */
  focusedLine?: DiffLineLocation | null;
  /** Auto-open tooltip target */
  autoTooltipLine?: DiffLineLocation | null;
  /** Display loading state for AI review */
  isLoading?: boolean;
  /** Optional message when diff is unavailable */
  errorMessage?: string | null;
  /** Whether the card starts collapsed */
  defaultCollapsed?: boolean;
  /** Callback when collapse state changes */
  onCollapseChange?: (collapsed: boolean) => void;
  /** Custom class name for the container */
  className?: string;
};

type DiffLineSide = "new" | "old";

type DiffLineLocation = {
  side: DiffLineSide;
  lineNumber: number;
};

type HeatmapTooltipMeta = {
  score: number;
  reason: string | null;
};

type LineTooltipMap = Record<DiffLineSide, Map<number, HeatmapTooltipMeta>>;

type HeatmapTooltipTheme = {
  contentClass: string;
  titleClass: string;
  reasonClass: string;
};

type FileStatusMeta = {
  icon: React.ReactElement;
  colorClassName: string;
  label: string;
};

type RefractorNode =
  | {
      type: "text";
      value: string;
    }
  | {
      type: string;
      children?: RefractorNode[];
      [key: string]: unknown;
    };

type RefractorLike = {
  highlight(code: string, language: string): unknown;
};

// ============================================================================
// Constants
// ============================================================================

const extensionToLanguage: Record<string, string> = {
  bash: "bash",
  c: "c",
  cc: "cpp",
  cmake: "cmake",
  coffee: "coffeescript",
  conf: "ini",
  cpp: "cpp",
  cjs: "javascript",
  cs: "csharp",
  css: "css",
  cxx: "cpp",
  dockerfile: "dockerfile",
  gql: "graphql",
  graphql: "graphql",
  h: "c",
  hh: "cpp",
  hpp: "cpp",
  htm: "markup",
  html: "markup",
  hxx: "cpp",
  ini: "ini",
  java: "java",
  js: "javascript",
  json: "json",
  json5: "json",
  jsx: "jsx",
  kt: "kotlin",
  kts: "kotlin",
  less: "less",
  m: "objectivec",
  md: "markdown",
  mdx: "markdown",
  mk: "makefile",
  mjs: "javascript",
  mm: "objectivec",
  php: "php",
  prisma: "prisma",
  ps1: "powershell",
  psm1: "powershell",
  py: "python",
  rs: "rust",
  rb: "ruby",
  sass: "scss",
  scss: "scss",
  sh: "bash",
  sql: "sql",
  svg: "markup",
  swift: "swift",
  toml: "toml",
  ts: "typescript",
  tsx: "tsx",
  vue: "vue",
  xml: "markup",
  yaml: "yaml",
  yml: "yaml",
  zsh: "bash",
  svelte: "svelte",
  go: "go",
  diff: "diff",
  env: "bash",
  lock: "yaml",
};

const filenameLanguageMap: Record<string, string> = {
  dockerfile: "dockerfile",
  "docker-compose.yml": "yaml",
  "cmakelists.txt": "cmake",
  makefile: "makefile",
  gitignore: "bash",
  env: "bash",
  "env.example": "bash",
  gemfile: "ruby",
  podfile: "ruby",
  brewfile: "ruby",
  "package-lock.json": "json",
  "yarn.lock": "yaml",
  "pnpm-lock.yaml": "yaml",
  "bun.lock": "toml",
};

const HEATMAP_SCORE_TIERS = [0.2, 0.4, 0.6, 0.8] as const;

// ============================================================================
// Utilities
// ============================================================================

function createRefractorAdapter(base: RefractorLike) {
  const isNodeWithChildren = (
    value: unknown
  ): value is { children: RefractorNode[] } => {
    return (
      typeof value === "object" &&
      value !== null &&
      "children" in value &&
      Array.isArray((value as { children?: unknown }).children)
    );
  };

  return {
    highlight(code: string, language: string): RefractorNode[] {
      const result = base.highlight(code, language);

      if (Array.isArray(result)) {
        return result;
      }

      if (isNodeWithChildren(result)) {
        return result.children;
      }

      const fallbackNode: RefractorNode = {
        type: "text",
        value: code,
      };

      return [fallbackNode];
    },
  };
}

const refractorAdapter = createRefractorAdapter(refractor);

function inferLanguage(filename: string): string | null {
  const lowerPath = filename.toLowerCase();
  const segments = lowerPath.split("/");
  const basename = segments[segments.length - 1] ?? lowerPath;

  if (filenameLanguageMap[lowerPath]) {
    return filenameLanguageMap[lowerPath];
  }

  if (filenameLanguageMap[basename]) {
    return filenameLanguageMap[basename];
  }

  const dotSegments = basename.split(".").filter(Boolean);

  for (let index = dotSegments.length - 1; index >= 0; index -= 1) {
    const part = dotSegments[index];
    if (part) {
      const language = extensionToLanguage[part];
      if (language) {
        return language;
      }
    }
  }

  return null;
}

function getFileStatusMeta(
  status: HeatmapDiffViewerProps["status"] | undefined
): FileStatusMeta {
  const iconClassName = "h-3.5 w-3.5";

  switch (status) {
    case "added":
      return {
        icon: <FilePlus className={iconClassName} />,
        colorClassName: "text-emerald-600 dark:text-emerald-400",
        label: "Added file",
      };
    case "removed":
      return {
        icon: <FileMinus className={iconClassName} />,
        colorClassName: "text-rose-600 dark:text-rose-400",
        label: "Removed file",
      };
    case "modified":
    case "changed":
      return {
        icon: <FileEdit className={iconClassName} />,
        colorClassName: "text-amber-600 dark:text-amber-400",
        label: "Modified file",
      };
    case "renamed":
      return {
        icon: <FileCode className={iconClassName} />,
        colorClassName: "text-sky-600 dark:text-sky-400",
        label: "Renamed file",
      };
    case "copied":
      return {
        icon: <FileCode className={iconClassName} />,
        colorClassName: "text-sky-600 dark:text-sky-400",
        label: "Copied file",
      };
    default:
      return {
        icon: <FileText className={iconClassName} />,
        colorClassName: "text-neutral-500 dark:text-neutral-400",
        label: "File change",
      };
  }
}

function selectTooltipMeta(
  className: string,
  lineNumber: number,
  tooltipMap: LineTooltipMap
): HeatmapTooltipMeta | undefined {
  const isOldToken = className.includes("cmux-heatmap-char-old");
  const primarySource = isOldToken ? tooltipMap.old : tooltipMap.new;
  const fallbackSource = isOldToken ? tooltipMap.new : tooltipMap.old;
  return primarySource.get(lineNumber) ?? fallbackSource.get(lineNumber);
}

function getHeatmapTooltipTheme(score: number): HeatmapTooltipTheme {
  const tier = (() => {
    for (let index = HEATMAP_SCORE_TIERS.length - 1; index >= 0; index -= 1) {
      const threshold = HEATMAP_SCORE_TIERS[index];
      if (threshold !== undefined && score >= threshold) {
        return index + 1;
      }
    }
    return score > 0 ? 1 : 0;
  })();

  switch (tier) {
    case 4:
      return {
        contentClass:
          "bg-orange-100 dark:bg-orange-900/80 border-orange-300 dark:border-orange-700 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-orange-200/70 dark:shadow-orange-900/40",
        titleClass: "text-neutral-900 dark:text-neutral-100",
        reasonClass: "text-neutral-800 dark:text-neutral-200",
      };
    case 3:
      return {
        contentClass:
          "bg-amber-100 dark:bg-amber-900/80 border-amber-300 dark:border-amber-700 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-amber-200/70 dark:shadow-amber-900/40",
        titleClass: "text-neutral-900 dark:text-neutral-100",
        reasonClass: "text-neutral-800 dark:text-neutral-200",
      };
    case 2:
      return {
        contentClass:
          "bg-yellow-100 dark:bg-yellow-900/80 border-yellow-200 dark:border-yellow-700 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-yellow-200/60 dark:shadow-yellow-900/40",
        titleClass: "text-neutral-900 dark:text-neutral-100",
        reasonClass: "text-neutral-800 dark:text-neutral-200",
      };
    case 1:
      return {
        contentClass:
          "bg-yellow-50 dark:bg-yellow-950/80 border-yellow-200 dark:border-yellow-800 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-yellow-200/50 dark:shadow-yellow-900/30",
        titleClass: "text-neutral-900 dark:text-neutral-100",
        reasonClass: "text-neutral-700 dark:text-neutral-300",
      };
    default:
      return {
        contentClass:
          "bg-neutral-900/95 dark:bg-neutral-800/95 border-neutral-700/60 dark:border-neutral-600/60 text-neutral-100 shadow-lg shadow-black/40",
        titleClass: "text-neutral-100",
        reasonClass: "text-neutral-300",
      };
  }
}

function doesChangeMatchLine(
  change: ChangeData,
  target: DiffLineLocation
): boolean {
  if (target.side === "new") {
    const newLineNumber = computeNewLineNumber(change);
    return newLineNumber > 0 && newLineNumber === target.lineNumber;
  }

  const oldLineNumber = computeOldLineNumber(change);
  return oldLineNumber > 0 && oldLineNumber === target.lineNumber;
}

// ============================================================================
// Tooltip Components
// ============================================================================

function HeatmapTooltipBody({
  score,
  reason,
}: {
  score: number;
  reason: string | null;
}) {
  const theme = getHeatmapTooltipTheme(score);
  // Only show the reason/comment - no "Review importance: X%" prefix
  return (
    <div className="text-left text-xs leading-relaxed">
      {reason ? (
        <p className={cn("text-xs", theme.reasonClass)}>{reason}</p>
      ) : null}
    </div>
  );
}

function HeatmapGutterTooltip({
  children,
  tooltipMeta,
  isAutoOpen,
}: {
  children: ReactNode;
  tooltipMeta: HeatmapTooltipMeta;
  isAutoOpen: boolean;
}) {
  const [isManuallyOpen, setIsManuallyOpen] = useState(false);
  const [isHovering, setIsHovering] = useState(false);
  const wasAutoOpenRef = useRef(isAutoOpen);

  const handleOpenChange = useCallback((nextOpen: boolean) => {
    setIsManuallyOpen(nextOpen);
  }, []);

  useEffect(() => {
    if (isAutoOpen) {
      setIsManuallyOpen(false);
    } else if (wasAutoOpenRef.current && isHovering) {
      setIsManuallyOpen(true);
    }
    wasAutoOpenRef.current = isAutoOpen;
  }, [isAutoOpen, isHovering]);

  const handlePointerEnter = useCallback(() => {
    setIsHovering(true);
  }, []);

  const handlePointerLeave = useCallback(() => {
    setIsHovering(false);
  }, []);

  const isOpen = isAutoOpen || isManuallyOpen;
  const theme = getHeatmapTooltipTheme(tooltipMeta.score);

  return (
    <Tooltip delayDuration={0} open={isOpen} onOpenChange={handleOpenChange}>
      <TooltipTrigger asChild>
        <span
          className="cmux-heatmap-gutter"
          onPointerEnter={handlePointerEnter}
          onPointerLeave={handlePointerLeave}
        >
          {children}
        </span>
      </TooltipTrigger>
      <TooltipContent
        side="left"
        align="start"
        showArrow={false}
        className={cn(
          "max-w-xs space-y-1 text-left leading-relaxed border backdrop-blur",
          theme.contentClass
        )}
      >
        <HeatmapTooltipBody
          score={tooltipMeta.score}
          reason={tooltipMeta.reason}
        />
      </TooltipContent>
    </Tooltip>
  );
}

// ============================================================================
// Main Component
// ============================================================================

export const HeatmapDiffViewer = memo(function HeatmapDiffViewerComponent({
  diffText,
  parsedDiff: providedParsedDiff,
  filename,
  status,
  additions = 0,
  deletions = 0,
  reviewHeatmap = [],
  heatmapThreshold = 0,
  diffHeatmap: providedDiffHeatmap,
  heatmapColors = DEFAULT_HEATMAP_COLORS,
  focusedLine = null,
  autoTooltipLine = null,
  isLoading = false,
  errorMessage = null,
  defaultCollapsed = false,
  onCollapseChange,
  className,
}: HeatmapDiffViewerProps) {
  const { resolvedTheme } = useTheme();
  const [isCollapsed, setIsCollapsed] = useState(defaultCollapsed);

  // Parse the diff
  const parsedDiff = useMemo<FileData | null>(() => {
    if (providedParsedDiff !== undefined) {
      return providedParsedDiff;
    }
    if (!diffText) {
      return null;
    }

    try {
      const [diff] = parseDiff(diffText, {
        nearbySequences: "zip",
      });
      return diff ?? null;
    } catch (error) {
      console.error("Failed to parse diff:", error);
      return null;
    }
  }, [diffText, providedParsedDiff]);

  // Build heatmap artifacts
  const diffHeatmapArtifacts = useMemo(() => {
    if (providedDiffHeatmap !== undefined) {
      return null;
    }
    if (!parsedDiff || reviewHeatmap.length === 0) {
      return null;
    }
    return prepareDiffHeatmapArtifacts(parsedDiff, reviewHeatmap);
  }, [parsedDiff, providedDiffHeatmap, reviewHeatmap]);

  // Render the heatmap with threshold
  const diffHeatmap = useMemo<DiffHeatmap | null>(() => {
    if (providedDiffHeatmap !== undefined) {
      return providedDiffHeatmap;
    }
    if (!diffHeatmapArtifacts) {
      return null;
    }
    return renderDiffHeatmapFromArtifacts(diffHeatmapArtifacts, heatmapThreshold);
  }, [diffHeatmapArtifacts, heatmapThreshold, providedDiffHeatmap]);

  // Infer language for syntax highlighting
  const language = useMemo(() => inferLanguage(filename), [filename]);

  // Get file status metadata
  const statusMeta = useMemo(() => getFileStatusMeta(status), [status]);

  // Generate heatmap gradient CSS
  const heatmapGradientCss = useMemo(
    () => buildThemedHeatmapGradientStyles(heatmapColors),
    [heatmapColors]
  );

  // Build line tooltips map
  const lineTooltips = useMemo<LineTooltipMap | null>(() => {
    if (!diffHeatmap) {
      return null;
    }

    const tooltipMap: LineTooltipMap = {
      new: new Map<number, HeatmapTooltipMeta>(),
      old: new Map<number, HeatmapTooltipMeta>(),
    };

    const assignTooltips = (
      source: Map<number, ResolvedHeatmapLine>,
      target: Map<number, HeatmapTooltipMeta>
    ) => {
      for (const [lineNumber, metadata] of source.entries()) {
        const score = metadata.score ?? null;
        if (score === null || score <= 0) {
          continue;
        }

        target.set(lineNumber, {
          score,
          reason: metadata.reason ?? null,
        });
      }
    };

    assignTooltips(diffHeatmap.entries, tooltipMap.new);
    assignTooltips(diffHeatmap.oldEntries, tooltipMap.old);

    if (tooltipMap.new.size === 0 && tooltipMap.old.size === 0) {
      return null;
    }

    return tooltipMap;
  }, [diffHeatmap]);

  // Token renderer with tooltips
  const renderHeatmapToken = useMemo<RenderToken | undefined>(() => {
    if (
      !lineTooltips ||
      (lineTooltips.new.size === 0 && lineTooltips.old.size === 0)
    ) {
      return undefined;
    }

    const renderTokenWithTooltip: RenderToken = (
      token,
      renderDefault,
      index
    ) => {
      if (token && typeof token === "object") {
        const tokenRecord = token as Record<string, unknown>;
        const tokenClassName =
          typeof tokenRecord.className === "string"
            ? tokenRecord.className
            : null;
        const lineNumber =
          typeof tokenRecord.lineNumber === "number"
            ? tokenRecord.lineNumber
            : null;

        if (
          tokenClassName &&
          lineNumber !== null &&
          (tokenClassName.includes("cmux-heatmap-char") ||
            tokenClassName.includes(HEATMAP_CHAR_CLASS_PREFIX))
        ) {
          const tooltipMeta = selectTooltipMeta(
            tokenClassName,
            lineNumber,
            lineTooltips
          );
          if (tooltipMeta) {
            const rendered = renderDefault(token, index);
            return (
              <Tooltip
                key={`heatmap-char-${lineNumber}-${index}`}
                delayDuration={0}
              >
                <TooltipTrigger asChild>
                  <span className="cmux-heatmap-char-wrapper">{rendered}</span>
                </TooltipTrigger>
                <TooltipContent
                  side="bottom"
                  align="start"
                  sideOffset={0}
                  showArrow={false}
                  className={cn(
                    "max-w-xs space-y-1 text-left leading-relaxed border backdrop-blur",
                    getHeatmapTooltipTheme(tooltipMeta.score).contentClass
                  )}
                >
                  <HeatmapTooltipBody
                    score={tooltipMeta.score}
                    reason={tooltipMeta.reason}
                  />
                </TooltipContent>
              </Tooltip>
            );
          }
        }
      }

      return renderDefault(token, index);
    };
    return renderTokenWithTooltip;
  }, [lineTooltips]);

  // Gutter renderer with tooltips and +/- indicators
  const renderHeatmapGutter = useMemo<RenderGutter>(() => {
    const renderGutterWithIndicator: RenderGutter = ({
      change,
      side,
      renderDefault,
      wrapInAnchor,
    }) => {
      const lineNumberContent = renderDefault();

      // Determine the change indicator based on change type
      const changeType = (change as { type?: string }).type;
      let indicator: ReactNode = null;

      if (changeType === "insert" && side === "new") {
        indicator = (
          <span className="text-emerald-600 dark:text-emerald-400 select-none font-medium w-4 inline-block text-center">
            +
          </span>
        );
      } else if (changeType === "delete" && side === "old") {
        indicator = (
          <span className="text-rose-600 dark:text-rose-400 select-none font-medium w-4 inline-block text-center">
            −
          </span>
        );
      } else {
        // For normal/unchanged lines, add a spacer to maintain alignment
        indicator = (
          <span className="w-4 inline-block select-none" aria-hidden="true">
            {" "}
          </span>
        );
      }

      const content = (
        <span className="inline-flex items-center">
          {indicator}
          {lineNumberContent}
        </span>
      );

      // If no tooltips, just return the content with indicator
      if (!lineTooltips) {
        return wrapInAnchor(content);
      }

      const tooltipSource =
        side === "new" ? lineTooltips.new : lineTooltips.old;

      if (tooltipSource.size === 0) {
        return wrapInAnchor(content);
      }

      const lineNumber =
        side === "new"
          ? computeNewLineNumber(change)
          : computeOldLineNumber(change);
      if (lineNumber <= 0) {
        return wrapInAnchor(content);
      }

      const tooltipMeta = tooltipSource.get(lineNumber);
      if (!tooltipMeta) {
        return wrapInAnchor(content);
      }

      const isAutoOpen =
        autoTooltipLine !== null &&
        autoTooltipLine.side === side &&
        autoTooltipLine.lineNumber === lineNumber;

      return wrapInAnchor(
        <HeatmapGutterTooltip
          key={`heatmap-gutter-${side}-${lineNumber}`}
          isAutoOpen={isAutoOpen}
          tooltipMeta={tooltipMeta}
        >
          {content}
        </HeatmapGutterTooltip>
      );
    };

    return renderGutterWithIndicator;
  }, [autoTooltipLine, lineTooltips]);

  // Tokenize with syntax highlighting
  const tokens = useMemo<HunkTokens | null>(() => {
    if (!parsedDiff) {
      return null;
    }

    const enhancers =
      diffHeatmap &&
      (diffHeatmap.newRanges.length > 0 || diffHeatmap.oldRanges.length > 0)
        ? [pickRanges(diffHeatmap.oldRanges, diffHeatmap.newRanges)]
        : undefined;

    if (language && refractor.registered(language)) {
      try {
        return tokenize(parsedDiff.hunks, {
          highlight: true,
          language,
          refractor: refractorAdapter,
          ...(enhancers ? { enhancers } : {}),
        });
      } catch {
        // Ignore highlight errors; fall back to default tokenization.
      }
    }

    return tokenize(
      parsedDiff.hunks,
      enhancers
        ? {
            enhancers,
          }
        : undefined
    );
  }, [parsedDiff, language, diffHeatmap]);

  // Handle collapse toggle
  const handleToggleCollapse = useCallback(() => {
    setIsCollapsed((prev) => {
      const next = !prev;
      onCollapseChange?.(next);
      return next;
    });
  }, [onCollapseChange]);

  // Sync with parent collapse state
  useEffect(() => {
    setIsCollapsed(defaultCollapsed);
  }, [defaultCollapsed]);

  const isDarkMode = resolvedTheme === "dark";

  return (
    <TooltipProvider
      delayDuration={0}
      skipDelayDuration={0}
      disableHoverableContent
    >
      <style
        data-heatmap-gradient
        dangerouslySetInnerHTML={{ __html: heatmapGradientCss }}
      />
      <article
        className={cn(
          "bg-white dark:bg-neutral-900 transition",
          className
        )}
      >
        <div className="flex flex-col divide-y divide-neutral-200 dark:divide-neutral-800">
          {/* Header */}
          <button
            type="button"
            onClick={handleToggleCollapse}
            className={cn(
              "sticky top-[var(--cmux-diff-header-offset,0px)] z-10 flex w-full items-center gap-0",
              "border-t border-neutral-200 dark:border-neutral-700",
              "bg-neutral-50 dark:bg-neutral-900/95",
              "px-3.5 py-2.5 text-left font-sans font-medium transition",
              "hover:bg-neutral-100 dark:hover:bg-neutral-800/80",
              "focus:outline-none focus-visible:outline-none"
            )}
            aria-expanded={!isCollapsed}
          >
            <span className="flex h-5 w-5 items-center justify-center text-neutral-400 dark:text-neutral-500">
              {isCollapsed ? (
                <ChevronRight className="h-3.5 w-3.5" />
              ) : (
                <ChevronDown className="h-3.5 w-3.5" />
              )}
            </span>

            <span
              className={cn(
                "flex h-5 w-5 items-center justify-center pl-2",
                statusMeta.colorClassName
              )}
            >
              {statusMeta.icon}
              <span className="sr-only">{statusMeta.label}</span>
            </span>

            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
              <span className="pl-1.5 text-sm text-neutral-700 dark:text-neutral-300 truncate">
                {filename}
              </span>
            </div>

            <div className="flex items-center gap-2 text-[13px] font-medium">
              {isLoading ? (
                <Tooltip delayDuration={300}>
                  <TooltipTrigger asChild>
                    <span className="inline-flex items-center">
                      <Loader2 className="h-3.5 w-3.5 text-sky-500 animate-spin flex-shrink-0" />
                    </span>
                  </TooltipTrigger>
                  <TooltipContent
                    side="bottom"
                    align="start"
                    showArrow={false}
                    className="rounded-md border border-neutral-200 bg-white px-2.5 py-1.5 text-xs text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                  >
                    AI review in progress...
                  </TooltipContent>
                </Tooltip>
              ) : null}
              <span className="text-emerald-600 dark:text-emerald-400">
                +{additions}
              </span>
              <span className="text-rose-600 dark:text-rose-400">
                -{deletions}
              </span>
            </div>
          </button>

          {/* Diff Content */}
          {!isCollapsed && (
            parsedDiff ? (
              <Diff
                diffType={parsedDiff.type}
                hunks={parsedDiff.hunks}
                viewType="split"
                optimizeSelection
                className={cn(
                  "diff-syntax system-mono overflow-auto text-xs leading-5",
                  "bg-white dark:bg-neutral-950",
                  "text-neutral-800 dark:text-neutral-200"
                )}
                gutterClassName={cn(
                  "system-mono text-xs",
                  "bg-white dark:bg-neutral-950",
                  "text-neutral-500 dark:text-neutral-400"
                )}
                codeClassName={cn(
                  "system-mono text-xs",
                  "text-neutral-800 dark:text-neutral-200"
                )}
                tokens={tokens ?? undefined}
                renderToken={renderHeatmapToken}
                renderGutter={renderHeatmapGutter}
                generateLineClassName={({ changes, defaultGenerate }) => {
                  const defaultClassName = defaultGenerate();
                  const classNames: string[] = ["system-mono text-xs py-1"];
                  const normalizedChanges = changes.filter(
                    (change): change is ChangeData => Boolean(change)
                  );
                  const hasFocus =
                    focusedLine !== null &&
                    normalizedChanges.some((change) =>
                      doesChangeMatchLine(change, focusedLine)
                    );
                  if (hasFocus) {
                    classNames.push("cmux-heatmap-focus");
                  }

                  // Apply heatmap line classes
                  if (
                    diffHeatmap &&
                    (diffHeatmap.lineClasses.size > 0 ||
                      diffHeatmap.oldLineClasses.size > 0)
                  ) {
                    let bestHeatmapClass: string | null = null;

                    const considerClass = (candidate: string | undefined) => {
                      if (!candidate) {
                        return;
                      }
                      if (!bestHeatmapClass) {
                        bestHeatmapClass = candidate;
                        return;
                      }
                      const currentStep =
                        extractHeatmapGradientStep(bestHeatmapClass);
                      const nextStep = extractHeatmapGradientStep(candidate);
                      if (nextStep > currentStep) {
                        bestHeatmapClass = candidate;
                      }
                    };

                    for (const change of normalizedChanges) {
                      const newLineNumber = computeNewLineNumber(change);
                      if (newLineNumber > 0) {
                        considerClass(
                          diffHeatmap.lineClasses.get(newLineNumber)
                        );
                      }
                      const oldLineNumber = computeOldLineNumber(change);
                      if (oldLineNumber > 0) {
                        considerClass(
                          diffHeatmap.oldLineClasses.get(oldLineNumber)
                        );
                      }
                    }

                    if (bestHeatmapClass) {
                      classNames.push(bestHeatmapClass);
                    }
                  }

                  classNames.push(
                    isDarkMode
                      ? "text-neutral-200"
                      : "text-neutral-800"
                  );

                  return cn(defaultClassName, classNames);
                }}
              >
                {(hunks) =>
                  hunks.map((hunk) => (
                    <Fragment key={hunk.content}>
                      <Decoration>
                        <div className="bg-sky-50 dark:bg-sky-950/50 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-sky-700 dark:text-sky-300">
                          {hunk.content}
                        </div>
                      </Decoration>
                      <Hunk hunk={hunk} />
                    </Fragment>
                  ))
                }
              </Diff>
            ) : (
              <div className="bg-neutral-50 dark:bg-neutral-900 px-4 py-6 text-sm text-neutral-600 dark:text-neutral-400">
                {errorMessage ??
                  "Diff content is unavailable for this file. It might be binary or too large to display."}
              </div>
            )
          )}
        </div>
      </article>
    </TooltipProvider>
  );
});
