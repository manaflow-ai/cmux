"use client";

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import type { ReactElement } from "react";
import {
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
  Folder,
  Sparkles,
} from "lucide-react";
import {
  Decoration,
  Diff,
  Hunk,
  computeNewLineNumber,
  isDelete,
  isInsert,
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

import { api } from "@cmux/convex/api";
import { useConvexQuery } from "@convex-dev/react-query";
import type { FunctionReturnType } from "convex/server";
import type { GithubPullRequestFile } from "@/lib/github/fetch-pull-request";
import { cn } from "@/lib/utils";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { refractor } from "refractor/all";

import { buildDiffHeatmap, parseReviewHeatmap } from "./heatmap";

type PullRequestDiffViewerProps = {
  files: GithubPullRequestFile[];
  teamSlugOrId: string;
  repoFullName: string;
  prNumber: number;
  commitRef?: string;
};

type ParsedFileDiff = {
  file: GithubPullRequestFile;
  anchorId: string;
  diff: FileData | null;
  error?: string;
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

type RefractorLike = {
  highlight(code: string, language: string): unknown;
};

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

type FileOutput = FunctionReturnType<
  typeof api.codeReview.listFileOutputsForPr
>[number];

type HeatmapTooltipMeta = {
  score: number;
  reason: string | null;
};

type HeatmapTooltipTheme = {
  contentClass: string;
  titleClass: string;
  reasonClass: string;
};

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
    const language = extensionToLanguage[part];
    if (language) {
      return language;
    }
  }

  return null;
}

type FileTreeNode = {
  name: string;
  path: string;
  children: FileTreeNode[];
  file?: GithubPullRequestFile;
};

type FileStatusMeta = {
  icon: ReactElement;
  colorClassName: string;
  label: string;
};

function getFileStatusMeta(
  status: GithubPullRequestFile["status"] | undefined
): FileStatusMeta {
  const iconClassName = "h-3.5 w-3.5";

  switch (status) {
    case "added":
      return {
        icon: <FilePlus className={iconClassName} />,
        colorClassName: "text-emerald-600",
        label: "Added file",
      };
    case "removed":
      return {
        icon: <FileMinus className={iconClassName} />,
        colorClassName: "text-rose-600",
        label: "Removed file",
      };
    case "modified":
    case "changed":
      return {
        icon: <FileEdit className={iconClassName} />,
        colorClassName: "text-amber-600",
        label: "Modified file",
      };
    case "renamed":
      return {
        icon: <FileCode className={iconClassName} />,
        colorClassName: "text-sky-600",
        label: "Renamed file",
      };
    case "copied":
      return {
        icon: <FileCode className={iconClassName} />,
        colorClassName: "text-sky-600",
        label: "Copied file",
      };
    default:
      return {
        icon: <FileText className={iconClassName} />,
        colorClassName: "text-neutral-500",
        label: "File change",
      };
  }
}

export function PullRequestDiffViewer({
  files,
  teamSlugOrId,
  repoFullName,
  prNumber,
  commitRef,
}: PullRequestDiffViewerProps) {
  const fileOutputArgs = useMemo(
    () => ({
      teamSlugOrId,
      repoFullName,
      prNumber,
      ...(commitRef ? { commitRef } : {}),
    }),
    [teamSlugOrId, repoFullName, prNumber, commitRef]
  );

  const fileOutputs = useConvexQuery(
    api.codeReview.listFileOutputsForPr,
    fileOutputArgs
  );

  useEffect(() => {
    if (!fileOutputs) {
      return;
    }

    console.log("[code-review] automatedCodeReviewFileOutputs", {
      args: fileOutputArgs,
      outputs: fileOutputs,
    });
  }, [fileOutputs, fileOutputArgs]);

  const fileOutputIndex = useMemo(() => {
    if (!fileOutputs) {
      return new Map<string, FileOutput>();
    }

    const map = new Map<string, FileOutput>();
    for (const output of fileOutputs) {
      map.set(output.filePath, output);
    }
    return map;
  }, [fileOutputs]);

  const totalFileCount = files.length;

  const processedFileCount = useMemo(() => {
    if (fileOutputs === undefined) {
      return null;
    }

    let count = 0;
    for (const file of files) {
      if (fileOutputIndex.has(file.filename)) {
        count += 1;
      }
    }

    return count;
  }, [fileOutputs, fileOutputIndex, files]);

  const isLoadingFileOutputs = fileOutputs === undefined;

  const parsedDiffs = useMemo<ParsedFileDiff[]>(() => {
    return files.map((file) => {
      if (!file.patch) {
        return {
          file,
          anchorId: file.filename,
          diff: null,
          error:
            "GitHub did not return a textual diff for this file. It may be binary or too large.",
        };
      }

      try {
        const [diff] = parseDiff(buildDiffText(file));
        return {
          file,
          anchorId: file.filename,
          diff: diff ?? null,
        };
      } catch (error) {
        const message =
          error instanceof Error
            ? error.message
            : "Unable to parse GitHub patch payload.";
        return {
          file,
          anchorId: file.filename,
          diff: null,
          error: message,
        };
      }
    });
  }, [files]);

  const fileTree = useMemo(() => buildFileTree(files), [files]);
  const directoryPaths = useMemo(
    () => collectDirectoryPaths(fileTree),
    [fileTree]
  );

  const hydratedInitialPath =
    typeof window !== "undefined"
      ? decodeURIComponent(window.location.hash.slice(1))
      : "";

  const firstPath = parsedDiffs[0]?.file.filename ?? "";
  const initialPath =
    hydratedInitialPath &&
    files.some((file) => file.filename === hydratedInitialPath)
      ? hydratedInitialPath
      : firstPath;

  const [activePath, setActivePath] = useState<string>(initialPath);
  const [activeAnchor, setActiveAnchor] = useState<string>(initialPath);

  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => {
    const defaults = new Set<string>(directoryPaths);
    for (const parent of getParentPaths(initialPath)) {
      defaults.add(parent);
    }
    return defaults;
  });

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
    const hash = decodeURIComponent(window.location.hash.slice(1));
    if (hash && files.some((file) => file.filename === hash)) {
      setActivePath(hash);
      setActiveAnchor(hash);
    }
  }, [files]);

  useEffect(() => {
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
          .sort(
            (a, b) =>
              a.target.getBoundingClientRect().top -
              b.target.getBoundingClientRect().top
          );

        if (visible[0]?.target.id) {
          setActiveAnchor(visible[0].target.id);
          return;
        }

        const nearest = entries
          .map((entry) => ({
            id: entry.target.id,
            top: entry.target.getBoundingClientRect().top,
          }))
          .sort((a, b) => Math.abs(a.top) - Math.abs(b.top))[0];

        if (nearest?.id) {
          setActiveAnchor(nearest.id);
        }
      },
      {
        rootMargin: "-128px 0px -55% 0px",
        threshold: [0, 0.2, 0.4, 0.6, 1],
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
  }, [parsedDiffs]);

  const handleNavigate = useCallback((path: string) => {
    setActivePath(path);
    setActiveAnchor(path);

    if (typeof window === "undefined") {
      return;
    }

    window.location.hash = encodeURIComponent(path);
  }, []);

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

  if (totalFileCount === 0) {
    return (
      <div className="rounded-2xl border border-neutral-200 bg-white p-8 text-sm text-neutral-600 shadow-sm">
        This pull request does not introduce any file changes.
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <ReviewProgressIndicator
        totalFileCount={totalFileCount}
        processedFileCount={processedFileCount}
        isLoading={isLoadingFileOutputs}
      />

      <div className="flex flex-col gap-6 lg:flex-row lg:items-start lg:gap-10">
        <aside className="lg:sticky lg:top-6 lg:h-[calc(100vh-96px)] lg:w-72 lg:overflow-y-auto">
          <div className="rounded-xl border border-neutral-200 bg-white p-3 shadow-sm">
            <FileTreeNavigator
              nodes={fileTree}
              activePath={activeAnchor}
              expandedPaths={expandedPaths}
              onToggleDirectory={handleToggleDirectory}
              onSelectFile={handleNavigate}
            />
          </div>
        </aside>

        <div className="flex-1 space-y-6">
          {parsedDiffs.map((entry) => (
            <FileDiffCard
              key={entry.anchorId}
              entry={entry}
              isActive={entry.anchorId === activeAnchor}
              review={fileOutputIndex.get(entry.file.filename) ?? null}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

function ReviewProgressIndicator({
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

  return (
    <div
      className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm transition"
      aria-live="polite"
    >
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <p className="text-sm font-medium text-neutral-700">
            Automated review progress
          </p>
          <p className="text-xs text-neutral-500">
            {statusText}
          </p>
        </div>
        <div className="flex items-center gap-2 text-xs font-semibold">
          <span
            className={cn(
              "rounded-md bg-emerald-100 px-2 py-0.5 text-emerald-700",
              isLoading ? "animate-pulse" : undefined
            )}
          >
            {processedBadgeText}
          </span>
          <span
            className={cn(
              "rounded-md bg-amber-100 px-2 py-0.5 text-amber-700",
              isLoading ? "animate-pulse" : undefined
            )}
          >
            {pendingBadgeText}
          </span>
        </div>
      </div>
      <div className="mt-3 h-2 rounded-full bg-neutral-200">
        <div
          className="h-full rounded-full bg-sky-500 transition-[width] duration-300 ease-out"
          style={{ width: `${progressPercent}%` }}
          role="progressbar"
          aria-label="Automated review progress"
          aria-valuemin={0}
          aria-valuemax={totalFileCount}
          aria-valuenow={processedFileCount ?? 0}
        />
      </div>
    </div>
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
                  "flex w-full items-center gap-1.5 rounded-md px-2.5 py-1 text-left text-sm font-medium transition hover:bg-neutral-100",
                  isExpanded ? "text-neutral-900" : "text-neutral-700"
                )}
                style={{ paddingLeft: depth * 14 + 10 }}
              >
                {isExpanded ? (
                  <ChevronDown className="h-4 w-4 text-neutral-500" />
                ) : (
                  <ChevronRight className="h-4 w-4 text-neutral-500" />
                )}
                <Folder className="h-4 w-4 text-neutral-500" />
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
              "flex w-full items-center gap-1 rounded-md px-2.5 py-1 text-left text-sm transition hover:bg-neutral-100",
              isActive
                ? "bg-sky-100/80 text-sky-900 shadow-sm"
                : "text-neutral-700"
            )}
            style={{ paddingLeft: depth * 14 + 32 }}
          >
            <span className="truncate font-medium">{node.name}</span>
          </button>
        );
      })}
    </div>
  );
}

function FileDiffCard({
  entry,
  isActive,
  review,
}: {
  entry: ParsedFileDiff;
  isActive: boolean;
  review: FileOutput | null;
}) {
  const { file, diff, anchorId, error } = entry;
  const [isCollapsed, setIsCollapsed] = useState(false);
  const language = useMemo(() => inferLanguage(file.filename), [file.filename]);
  const statusMeta = useMemo(
    () => getFileStatusMeta(file.status),
    [file.status]
  );

  useEffect(() => {
    if (isActive) {
      setIsCollapsed(false);
    }
  }, [isActive]);

  const reviewHeatmapLines = useMemo(() => {
    if (!review) {
      return [];
    }

    return parseReviewHeatmap(review.codexReviewOutput);
  }, [review]);

  const diffHeatmap = useMemo(() => {
    if (!diff || reviewHeatmapLines.length === 0) {
      return null;
    }

    return buildDiffHeatmap(diff, reviewHeatmapLines);
  }, [diff, reviewHeatmapLines]);

  useEffect(() => {
    if (!review) {
      return;
    }

    console.log("[diff-viewer] heatmap payload", {
      file: file.filename,
      raw: review.codexReviewOutput,
      parsedHeatmap: reviewHeatmapLines,
      hydrated: diffHeatmap,
    });
  }, [review, reviewHeatmapLines, diffHeatmap, file.filename]);

  const lineTooltips = useMemo(() => {
    if (!diffHeatmap) {
      return null;
    }

    const tooltipMap = new Map<number, HeatmapTooltipMeta>();
    for (const [lineNumber, metadata] of diffHeatmap.entries.entries()) {
      const score = metadata.score ?? null;
      if (score === null || score <= 0) {
        continue;
      }

      tooltipMap.set(lineNumber, {
        score,
        reason: metadata.reason ?? null,
      });
    }

    return tooltipMap.size > 0 ? tooltipMap : null;
  }, [diffHeatmap]);

  const renderHeatmapToken = useMemo<RenderToken | undefined>(() => {
    if (!lineTooltips) {
      return undefined;
    }

    const renderTokenWithTooltip: RenderToken = (token, renderDefault, index) => {
      if (token && typeof token === "object") {
        const tokenRecord = token as Record<string, unknown>;
        const className =
          typeof tokenRecord.className === "string"
            ? tokenRecord.className
            : null;
        const lineNumber =
          typeof tokenRecord.lineNumber === "number"
            ? tokenRecord.lineNumber
            : null;

        if (
          className &&
          lineNumber !== null &&
          (className.includes("cmux-heatmap-char") ||
            className.includes("cmux-heatmap-char-tier"))
        ) {
          const tooltipMeta = lineTooltips.get(lineNumber);
          if (tooltipMeta) {
            const rendered = renderDefault(token, index);
            return (
              <Tooltip key={`heatmap-char-${lineNumber}-${index}`} delayDuration={120}>
                <TooltipTrigger asChild>
                  <span className="cmux-heatmap-char-wrapper">{rendered}</span>
                </TooltipTrigger>
                <TooltipContent
                  side="top"
                  align="start"
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

  const renderHeatmapGutter = useMemo<RenderGutter | undefined>(() => {
    if (!lineTooltips) {
      return undefined;
    }

    const renderGutterWithTooltip: RenderGutter = ({
      change,
      side,
      renderDefault,
      wrapInAnchor,
    }) => {
      const content = renderDefault();
      if (side !== "new") {
        return wrapInAnchor(content);
      }

      const lineNumber = computeNewLineNumber(change);
      if (lineNumber <= 0) {
        return wrapInAnchor(content);
      }

      const tooltipMeta = lineTooltips.get(lineNumber);
      if (!tooltipMeta) {
        return wrapInAnchor(content);
      }

      const tooltipNode = (
        <Tooltip key={`heatmap-gutter-${lineNumber}`} delayDuration={120}>
          <TooltipTrigger asChild>
            <span className="cmux-heatmap-gutter">{content}</span>
          </TooltipTrigger>
          <TooltipContent
            side="top"
            align="start"
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

      return wrapInAnchor(tooltipNode);
    };

    return renderGutterWithTooltip;
  }, [lineTooltips]);

  const tokens = useMemo<HunkTokens | null>(() => {
    if (!diff) {
      return null;
    }

    const enhancers =
      diffHeatmap && diffHeatmap.newRanges.length > 0
        ? [pickRanges([], diffHeatmap.newRanges)]
        : undefined;

    if (language && refractor.registered(language)) {
      try {
        return tokenize(diff.hunks, {
          highlight: true,
          language,
          refractor: refractorAdapter,
          ...(enhancers ? { enhancers } : {}),
        });
      } catch (error) {
        console.warn("[diff-viewer] highlight failed", file.filename, error);
      }
    }

    return tokenize(
      diff.hunks,
      enhancers
        ? {
            enhancers,
          }
        : undefined
    );
  }, [diff, language, file.filename, diffHeatmap]);

  const reviewContent = useMemo(() => {
    if (!review) {
      return null;
    }

    return extractAutomatedReviewText(review.codexReviewOutput);
  }, [review]);

  const showReview = Boolean(reviewContent);

  return (
    <TooltipProvider
      delayDuration={120}
      skipDelayDuration={100}
      disableHoverableContent
    >
      <article
        id={anchorId}
        className={cn(
          "overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm transition focus:outline-none",
          isActive ? "ring-1 ring-sky-200" : "ring-0"
        )}
        tabIndex={-1}
        aria-current={isActive}
      >
        <button
          type="button"
          onClick={() => setIsCollapsed((previous) => !previous)}
          className="flex w-full items-center gap-3 border-b border-neutral-200 bg-neutral-50/80 px-3.5 py-2.5 text-left transition hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-500"
          aria-expanded={!isCollapsed}
        >
        <span className="flex h-5 w-5 items-center justify-center text-neutral-400">
          {isCollapsed ? (
            <ChevronRight className="h-3.5 w-3.5" />
          ) : (
            <ChevronDown className="h-3.5 w-3.5" />
          )}
        </span>

        <span
          className={cn(
            "flex h-5 w-5 items-center justify-center",
            statusMeta.colorClassName
          )}
        >
          {statusMeta.icon}
          <span className="sr-only">{statusMeta.label}</span>
        </span>

        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="font-mono text-xs text-neutral-700 truncate">
            {file.filename}
          </span>
          {file.previous_filename ? (
            <span className="font-mono text-[11px] text-neutral-500 truncate">
              Renamed from {file.previous_filename}
            </span>
          ) : null}
        </div>

        <div className="flex items-center gap-2 text-[11px] font-medium text-neutral-600">
          <span className="text-emerald-600">+{file.additions}</span>
          <span className="text-rose-600">-{file.deletions}</span>
        </div>
      </button>

      {showReview ? (
        <div className="border-b border-neutral-200 bg-sky-50 px-4 py-4">
          <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-sky-700">
            <Sparkles className="h-4 w-4" aria-hidden />
            Automated review
          </div>
          <pre className="mt-2 max-h-[9.5rem] overflow-hidden whitespace-pre-wrap break-words font-sans text-sm leading-relaxed text-neutral-900">
            {reviewContent}
          </pre>
        </div>
      ) : null}

      {!isCollapsed ? (
        diff ? (
          <Diff
            diffType={diff.type}
            hunks={diff.hunks}
            viewType="split"
            optimizeSelection
            className="diff-syntax system-mono overflow-auto bg-white text-xs leading-5 text-neutral-800"
            gutterClassName="system-mono bg-white text-xs text-neutral-500"
            codeClassName="system-mono text-xs text-neutral-800"
            tokens={tokens ?? undefined}
            renderToken={renderHeatmapToken}
            renderGutter={renderHeatmapGutter}
            generateLineClassName={({ changes, defaultGenerate }) => {
              const defaultClassName = defaultGenerate();
              const classNames: string[] = ["system-mono text-xs py-1"];
              const normalizedChanges = changes.filter(
                (change): change is ChangeData => Boolean(change)
              );
              const hasInsert = normalizedChanges.some((change) =>
                isInsert(change)
              );
              const hasDelete = normalizedChanges.some((change) =>
                isDelete(change)
              );
              if (diffHeatmap && diffHeatmap.lineClasses.size > 0) {
                let bestHeatmapClass: string | null = null;
                for (const change of normalizedChanges) {
                  const newLineNumber = computeNewLineNumber(change);
                  if (newLineNumber <= 0) {
                    continue;
                  }
                  const candidate = diffHeatmap.lineClasses.get(newLineNumber);
                  if (!candidate) {
                    continue;
                  }
                  if (!bestHeatmapClass) {
                    bestHeatmapClass = candidate;
                    continue;
                  }
                  const currentTier = extractHeatmapTier(bestHeatmapClass);
                  const nextTier = extractHeatmapTier(candidate);
                  if (nextTier > currentTier) {
                    bestHeatmapClass = candidate;
                  }
                }

                if (bestHeatmapClass) {
                  classNames.push(bestHeatmapClass);
                }
              }

              if (hasInsert) {
                classNames.push("bg-emerald-50 text-emerald-900");
              } else if (hasDelete) {
                classNames.push("bg-rose-50 text-rose-900");
              } else {
                classNames.push("bg-white text-neutral-800");
              }

              return cn(defaultClassName, classNames);
            }}
          >
            {(hunks) =>
              hunks.map((hunk) => (
                <Fragment key={hunk.content}>
                  <Decoration>
                    <div className="bg-sky-50 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-sky-700">
                      {hunk.content}
                    </div>
                  </Decoration>
                  <Hunk hunk={hunk} />
                </Fragment>
              ))
            }
          </Diff>
        ) : (
          <div className="bg-neutral-50 px-4 py-6 text-sm text-neutral-600">
            {error ??
              "Diff content is unavailable for this file. It might be binary or too large to display."}
          </div>
        )
      ) : null}
      </article>
    </TooltipProvider>
  );
}

function HeatmapTooltipBody({
  score,
  reason,
}: {
  score: number;
  reason: string | null;
}) {
  const theme = getHeatmapTooltipTheme(score);
  return (
    <div className="space-y-1 text-left text-xs leading-relaxed">
      <p className={cn("font-semibold", theme.titleClass)}>Worth a closer look</p>
      {reason ? (
        <p className={cn("text-xs", theme.reasonClass)}>{reason}</p>
      ) : null}
    </div>
  );
}

const HEATMAP_SCORE_TIERS = [0.2, 0.4, 0.6, 0.8] as const;

function getHeatmapTooltipTheme(score: number): HeatmapTooltipTheme {
  const tier = (() => {
    for (let index = HEATMAP_SCORE_TIERS.length - 1; index >= 0; index -= 1) {
      if (score >= HEATMAP_SCORE_TIERS[index]!) {
        return index + 1;
      }
    }
    return score > 0 ? 1 : 0;
  })();

  switch (tier) {
    case 4:
      return {
        contentClass:
          "bg-rose-900/95 border-rose-500/40 text-rose-50 shadow-lg shadow-rose-950/40",
        titleClass: "text-rose-100",
        reasonClass: "text-rose-200",
      };
    case 3:
      return {
        contentClass:
          "bg-rose-800/95 border-rose-400/40 text-rose-50 shadow-lg shadow-rose-950/30",
        titleClass: "text-rose-100",
        reasonClass: "text-rose-200",
      };
    case 2:
      return {
        contentClass:
          "bg-amber-800/95 border-amber-400/40 text-amber-50 shadow-lg shadow-amber-950/30",
        titleClass: "text-amber-100",
        reasonClass: "text-amber-200",
      };
    case 1:
      return {
        contentClass:
          "bg-amber-900/95 border-amber-500/40 text-amber-50 shadow-lg shadow-amber-950/40",
        titleClass: "text-amber-100",
        reasonClass: "text-amber-200",
      };
    default:
      return {
        contentClass:
          "bg-neutral-900/95 border-neutral-700/60 text-neutral-100 shadow-lg shadow-black/40",
        titleClass: "text-neutral-100",
        reasonClass: "text-neutral-300",
      };
  }
}

function extractHeatmapTier(className: string): number {
  const match = className.match(/cmux-heatmap-tier-(\d+)/);
  if (!match) {
    return 0;
  }

  const parsed = Number.parseInt(match[1] ?? "0", 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function extractAutomatedReviewText(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }

  if (typeof value === "object") {
    if (
      "response" in value &&
      typeof (value as { response?: unknown }).response === "string"
    ) {
      return extractAutomatedReviewText(
        (value as { response: string }).response
      );
    }

    if (
      "lines" in value &&
      Array.isArray((value as { lines?: unknown }).lines)
    ) {
      const formatted = formatLineReviews(
        (value as { lines: unknown[] }).lines
      );
      if (formatted) {
        return formatted;
      }
    }

    try {
      return JSON.stringify(value, null, 2);
    } catch {
      return String(value);
    }
  }

  return String(value);
}

function formatLineReviews(entries: unknown[]): string | null {
  const summaries: string[] = [];

  for (const entry of entries) {
    if (typeof entry !== "object" || entry === null) {
      continue;
    }

    const record = entry as Record<string, unknown>;
    const line = typeof record.line === "string" ? record.line.trim() : null;
    if (!line) {
      continue;
    }

    const reason =
      typeof record.shouldReviewWhy === "string"
        ? record.shouldReviewWhy.trim()
        : null;

    const score =
      typeof record.shouldBeReviewedScore === "number"
        ? record.shouldBeReviewedScore
        : null;

    const changeFlag = record.hasChanged === false ? null : "Changed";

    const parts: string[] = [`Line ${line}`];
    if (changeFlag) {
      parts.push(changeFlag);
    }
    if (reason) {
      parts.push(reason);
    }
    if (typeof score === "number" && Number.isFinite(score)) {
      parts.push(`importance ${(score * 100).toFixed(0)}%`);
    }

    summaries.push(parts.join(" • "));
  }

  if (summaries.length === 0) {
    return null;
  }

  return summaries.join("\n\n");
}

function buildDiffText(file: GithubPullRequestFile): string {
  const oldPath =
    file.status === "added"
      ? "/dev/null"
      : (file.previous_filename ?? file.filename);
  const newPath = file.status === "removed" ? "/dev/null" : file.filename;

  const gitOldLabel = `a/${file.previous_filename ?? file.filename}`;
  const gitNewLabel = `b/${file.filename}`;
  const oldLabel = oldPath === "/dev/null" ? "/dev/null" : gitOldLabel;
  const newLabel = newPath === "/dev/null" ? "/dev/null" : gitNewLabel;

  return [
    `diff --git ${gitOldLabel} ${gitNewLabel}`,
    `--- ${oldLabel}`,
    `+++ ${newLabel}`,
    file.patch,
    "",
  ].join("\n");
}

function buildFileTree(files: GithubPullRequestFile[]): FileTreeNode[] {
  const root: FileTreeNode = {
    name: "",
    path: "",
    children: [],
  };

  for (const file of files) {
    const segments = file.filename.split("/");
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

  const sortNodes = (nodes: FileTreeNode[]) => {
    nodes.sort((a, b) => {
      const aIsDir = a.children.length > 0;
      const bIsDir = b.children.length > 0;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      return a.name.localeCompare(b.name);
    });
    nodes.forEach((node) => {
      if (node.children.length > 0) {
        sortNodes(node.children);
      }
    });
  };

  sortNodes(root.children);

  const collapseNode = (node: FileTreeNode): FileTreeNode => {
    if (node.children.length === 0) {
      return node;
    }

    let current = node;

    while (
      current.file === undefined &&
      current.children.length === 1 &&
      current.children[0].file === undefined
    ) {
      const child = current.children[0];
      current = {
        name: current.name ? `${current.name}/${child.name}` : child.name,
        path: child.path,
        children: child.children,
        file: child.file,
      };
    }

    return {
      ...current,
      children: current.children.map((child) => collapseNode(child)),
    };
  };

  const collapsedChildren = root.children.map((child) => collapseNode(child));

  return collapsedChildren;
}

function collectDirectoryPaths(nodes: FileTreeNode[]): string[] {
  const directories: string[] = [];
  const stack = [...nodes];

  while (stack.length > 0) {
    const node = stack.pop();
    if (!node) {
      continue;
    }

    if (node.children.length === 0) {
      continue;
    }

    if (node.path) {
      directories.push(node.path);
    }

    stack.push(...node.children);
  }

  return directories;
}

function getParentPaths(path: string): string[] {
  if (!path) return [];
  const segments = path.split("/");
  const parents: string[] = [];
  for (let index = 1; index < segments.length; index += 1) {
    parents.push(segments.slice(0, index).join("/"));
  }
  return parents;
}
