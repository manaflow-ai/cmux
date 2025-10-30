"use client";

import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useId,
  useDeferredValue,
} from "react";
import type {
  ReactElement,
  ReactNode,
  KeyboardEvent as ReactKeyboardEvent,
  CSSProperties,
  ChangeEvent,
} from "react";
import {
  ChevronLeft,
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
  Sparkles,
  Copy,
  Check,
  Loader2,
  Star,
  AlertTriangle,
} from "lucide-react";
import {
  Decoration,
  Diff,
  Hunk,
  computeNewLineNumber,
  computeOldLineNumber,
  parseDiff,
  pickRanges,
  getChangeKey,
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
import type { GithubFileChange } from "@/lib/github/fetch-pull-request";
import { cn } from "@/lib/utils";
import CmuxLogo from "@/components/logo/cmux-logo";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { refractor } from "refractor/all";

import {
  MaterialSymbolsFolderOpenSharp,
  MaterialSymbolsFolderSharp,
} from "../icons/material-symbols";
import {
  parseReviewHeatmap,
  prepareDiffHeatmapArtifacts,
  renderDiffHeatmapFromArtifacts,
  type DiffHeatmap,
  type DiffHeatmapArtifacts,
  type ReviewHeatmapLine,
  type ResolvedHeatmapLine,
} from "./heatmap";
import {
  ReviewCompletionNotificationCard,
  type ReviewCompletionNotificationCardState,
} from "./review-completion-notification-card";
import clsx from "clsx";
import { kitties } from "./kitty";

type PullRequestDiffViewerProps = {
  files: GithubFileChange[];
  teamSlugOrId: string;
  repoFullName: string;
  prNumber?: number | null;
  comparisonSlug?: string | null;
  jobType?: "pull_request" | "comparison";
  commitRef?: string;
  baseCommitRef?: string;
  pullRequestTitle?: string;
  pullRequestUrl?: string;
};

type ParsedFileDiff = {
  file: GithubFileChange;
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

type FileOutput =
  | FunctionReturnType<typeof api.codeReview.listFileOutputsForPr>[number]
  | FunctionReturnType<
      typeof api.codeReview.listFileOutputsForComparison
    >[number];

type HeatmapTooltipMeta = {
  score: number;
  reason: string | null;
};

type FileDiffViewModel = {
  entry: ParsedFileDiff;
  review: FileOutput | null;
  reviewHeatmap: ReviewHeatmapLine[];
  diffHeatmapArtifacts: DiffHeatmapArtifacts | null;
  changeKeyByLine: Map<string, string>;
  streamState: StreamFileState | null;
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

type FocusNavigateOptions = {
  source?: "keyboard" | "pointer";
};

type ActiveTooltipTarget = {
  filePath: string;
  lineNumber: number;
  side: DiffLineSide;
};

type ShowAutoTooltipOptions = {
  sticky?: boolean;
};

type HeatmapTooltipTheme = {
  contentClass: string;
  titleClass: string;
  reasonClass: string;
};

type NavigateOptions = {
  updateAnchor?: boolean;
  updateHash?: boolean;
};

type DiffLineSide = "new" | "old";

type DiffLineLocation = {
  side: DiffLineSide;
  lineNumber: number;
};

type LineTooltipMap = Record<DiffLineSide, Map<number, HeatmapTooltipMeta>>;

type StreamFileStatus = "pending" | "success" | "skipped" | "error";

type StreamFileState = {
  lines: ReviewHeatmapLine[];
  status: StreamFileStatus;
  skipReason?: string | null;
  summary?: string | null;
};

const SIDEBAR_WIDTH_STORAGE_KEY = "cmux:pr-diff-viewer:file-tree-width";
const SIDEBAR_DEFAULT_WIDTH = 330;
const SIDEBAR_MIN_WIDTH = 240;
const SIDEBAR_MAX_WIDTH = 520;

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
    const aLine = a.lineNumber ?? Number.MAX_SAFE_INTEGER;
    const bLine = b.lineNumber ?? Number.MAX_SAFE_INTEGER;
    if (aLine !== bLine) {
      return aLine - bLine;
    }
    return (a.lineText ?? "").localeCompare(b.lineText ?? "");
  });
}

function clampSidebarWidth(value: number): number {
  if (Number.isNaN(value)) {
    return SIDEBAR_DEFAULT_WIDTH;
  }
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, value));
}

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
  file?: GithubFileChange;
  isLoading?: boolean;
};

type FileStatusMeta = {
  icon: ReactElement;
  colorClassName: string;
  label: string;
};

function getFileStatusMeta(
  status: GithubFileChange["status"] | undefined
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

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error("Failed to copy text:", err);
    }
  }, [text]);

  return (
    <button
      type="button"
      onClick={handleCopy}
      className="flex items-center gap-1.5 rounded px-2 py-1 text-xs font-medium text-sky-700 transition-colors hover:bg-sky-100"
      aria-label={copied ? "Copied to clipboard" : "Copy to clipboard"}
    >
      {copied ? (
        <>
          <Check className="h-3.5 w-3.5" aria-hidden />
          <span>Copied!</span>
        </>
      ) : (
        <>
          <Copy className="h-3.5 w-3.5" aria-hidden />
          <span>Copy</span>
        </>
      )}
    </button>
  );
}

const DEBUG_LOG = false;

export function PullRequestDiffViewer({
  files,
  teamSlugOrId,
  repoFullName,
  prNumber,
  comparisonSlug,
  jobType,
  commitRef,
  baseCommitRef,
  pullRequestTitle,
  pullRequestUrl,
}: PullRequestDiffViewerProps) {
  const normalizedJobType: "pull_request" | "comparison" =
    jobType ?? (comparisonSlug ? "comparison" : "pull_request");

  const [streamStateByFile, setStreamStateByFile] = useState<
    Map<string, StreamFileState>
  >(() => new Map());

  useEffect(() => {
    if (normalizedJobType !== "pull_request") {
      return;
    }
    if (typeof prNumber !== "number" || Number.isNaN(prNumber)) {
      return;
    }
    if (!repoFullName) {
      return;
    }

    const controller = new AbortController();
    setStreamStateByFile(new Map());
    const params = new URLSearchParams({
      repoFullName,
      prNumber: String(prNumber),
    });

    (async () => {
      try {
        const response = await fetch(
          `/api/pr-review/simple?${params.toString()}`,
          {
            signal: controller.signal,
          }
        );

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
                    if (DEBUG_LOG) {
                      console.info(
                        "[simple-review][frontend][status]",
                        payload
                      );
                    }
                    break;
                  case "file":
                    if (DEBUG_LOG) {
                      console.info("[simple-review][frontend][file]", payload);
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
                    if (DEBUG_LOG) {
                      console.info("[simple-review][frontend][skip]", payload);
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
                    if (DEBUG_LOG) {
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
                    if (DEBUG_LOG) {
                      console.info("[simple-review][frontend][hunk]", payload);
                    }
                    break;
                  case "line": {
                    if (DEBUG_LOG) {
                      console.info("[simple-review][frontend][line]", payload);
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
                    const normalizedScore = Math.max(0, Math.min(rawScore, 1));
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
                    if (DEBUG_LOG) {
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
                    console.info("[simple-review][frontend][event]", payload);
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
    })();

    return () => {
      controller.abort();
    };
  }, [normalizedJobType, prNumber, repoFullName, setStreamStateByFile]);

  const prQueryArgs = useMemo(
    () =>
      normalizedJobType !== "pull_request" ||
      prNumber === null ||
      prNumber === undefined
        ? ("skip" as const)
        : {
            teamSlugOrId,
            repoFullName,
            prNumber,
            ...(commitRef ? { commitRef } : {}),
            ...(baseCommitRef ? { baseCommitRef } : {}),
          },
    [
      normalizedJobType,
      teamSlugOrId,
      repoFullName,
      prNumber,
      commitRef,
      baseCommitRef,
    ]
  );

  const comparisonQueryArgs = useMemo(
    () =>
      normalizedJobType !== "comparison" || !comparisonSlug
        ? ("skip" as const)
        : {
            teamSlugOrId,
            repoFullName,
            comparisonSlug,
            ...(commitRef ? { commitRef } : {}),
            ...(baseCommitRef ? { baseCommitRef } : {}),
          },
    [
      normalizedJobType,
      teamSlugOrId,
      repoFullName,
      comparisonSlug,
      commitRef,
      baseCommitRef,
    ]
  );

  const prFileOutputs = useConvexQuery(
    api.codeReview.listFileOutputsForPr,
    prQueryArgs
  );
  const comparisonFileOutputs = useConvexQuery(
    api.codeReview.listFileOutputsForComparison,
    comparisonQueryArgs
  );

  const fileOutputs =
    normalizedJobType === "comparison" ? comparisonFileOutputs : prFileOutputs;

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

  const sortedFiles = useMemo(() => {
    // Sort files to match the tree structure order
    // The tree displays files depth-first, so we need to sort by path segments
    return [...files].sort((a, b) => {
      const aSegments = a.filename.split("/");
      const bSegments = b.filename.split("/");
      const minLength = Math.min(aSegments.length, bSegments.length);

      // Compare segment by segment
      for (let i = 0; i < minLength; i++) {
        const aSegment = aSegments[i]!;
        const bSegment = bSegments[i]!;

        // At the last segment for one of the paths
        const aIsLast = i === aSegments.length - 1;
        const bIsLast = i === bSegments.length - 1;

        if (aSegment === bSegment) {
          // Same segment, continue to next level
          continue;
        }

        // If one is a file and one is a directory at this level, directory comes first
        if (aIsLast && !bIsLast) return 1; // a is file, b is directory
        if (!aIsLast && bIsLast) return -1; // a is directory, b is file

        // Both are directories or both are files at this level, sort alphabetically
        return aSegment.localeCompare(bSegment);
      }

      // One path is a prefix of the other
      // Shorter path (file in parent dir) comes before longer path (file in subdir)
      return aSegments.length - bSegments.length;
    });
  }, [files]);

  const totalFileCount = sortedFiles.length;

  const processedFileCount = useMemo(() => {
    if (fileOutputs === undefined && streamStateByFile.size === 0) {
      return null;
    }

    let count = 0;
    for (const file of sortedFiles) {
      const streamState = streamStateByFile.get(file.filename);
      const isStreamComplete =
        streamState !== undefined && streamState.status !== "pending";
      const isProcessed =
        fileOutputIndex.has(file.filename) || isStreamComplete;
      if (isProcessed) {
        count += 1;
      }
    }

    return count;
  }, [fileOutputs, fileOutputIndex, sortedFiles, streamStateByFile]);

  const isLoadingFileOutputs =
    fileOutputs === undefined &&
    (streamStateByFile.size === 0 ||
      Array.from(streamStateByFile.values()).some(
        (state) => state.status === "pending"
      ));

  const pendingFileCount = useMemo(() => {
    if (processedFileCount === null) {
      return Math.max(totalFileCount, 0);
    }
    return Math.max(totalFileCount - processedFileCount, 0);
  }, [processedFileCount, totalFileCount]);

  const [heatmapThresholdInput, setHeatmapThresholdInput] = useState(0);
  const heatmapThreshold = useDeferredValue(heatmapThresholdInput);

  const [isNotificationSupported, setIsNotificationSupported] = useState(false);
  const [notificationPermission, setNotificationPermission] =
    useState<NotificationPermission | null>(null);
  const [shouldNotifyOnCompletion, setShouldNotifyOnCompletion] =
    useState(false);
  const [isRequestingNotification, setIsRequestingNotification] =
    useState(false);
  const previousPendingCountRef = useRef<number | null>(null);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const supported = "Notification" in window;
    setIsNotificationSupported(supported);

    if (!supported) {
      return;
    }

    setNotificationPermission(Notification.permission);
  }, []);

  useEffect(() => {
    if (notificationPermission === "denied") {
      setShouldNotifyOnCompletion(false);
    }
  }, [notificationPermission]);

  useEffect(() => {
    const previousPending = previousPendingCountRef.current;
    previousPendingCountRef.current = pendingFileCount;

    if (
      !isNotificationSupported ||
      notificationPermission !== "granted" ||
      !shouldNotifyOnCompletion
    ) {
      return;
    }

    if (
      pendingFileCount === 0 &&
      (previousPending === null || previousPending > 0)
    ) {
      try {
        const completionMessage =
          totalFileCount === 1
            ? "Finished reviewing the last file."
            : "Finished reviewing all files in this review.";
        const isPullRequestReview = normalizedJobType === "pull_request";
        const sanitizedTitle =
          typeof pullRequestTitle === "string"
            ? pullRequestTitle.replace(/\s+/g, " ").trim()
            : "";
        const effectiveTitle =
          sanitizedTitle.length > 0 ? sanitizedTitle : null;
        const sanitizedUrl =
          typeof pullRequestUrl === "string" ? pullRequestUrl.trim() : "";
        const hasValidPrNumber =
          typeof prNumber === "number" && Number.isFinite(prNumber);
        const trimmedRepoFullName =
          repoFullName.trim().length > 0 ? repoFullName.trim() : null;
        const fallbackUrl =
          isPullRequestReview && hasValidPrNumber && trimmedRepoFullName
            ? `https://github.com/${trimmedRepoFullName}/pull/${prNumber}`
            : null;
        const effectiveUrl =
          sanitizedUrl.length > 0 ? sanitizedUrl : fallbackUrl;
        const repoDescriptor =
          trimmedRepoFullName && hasValidPrNumber
            ? `${trimmedRepoFullName}#${prNumber}`
            : trimmedRepoFullName;

        const detailLines: string[] = [];

        if (isPullRequestReview) {
          const descriptorParts: string[] = [];
          if (effectiveTitle) {
            descriptorParts.push(`“${effectiveTitle}”`);
          }
          if (repoDescriptor) {
            descriptorParts.push(repoDescriptor);
          }

          if (descriptorParts.length > 0) {
            detailLines.push(descriptorParts.join(" • "));
          }

          if (effectiveUrl) {
            detailLines.push(effectiveUrl);
          }
        }

        const bodyLines = [completionMessage, ...detailLines].filter(
          (line) => line && line.length > 0
        );
        const body = bodyLines.join("\n");
        const titleSubject =
          isPullRequestReview && (effectiveTitle || repoDescriptor)
            ? (effectiveTitle ?? repoDescriptor)
            : null;
        const notificationTitle =
          titleSubject && titleSubject.length > 0
            ? `Review complete • ${titleSubject}`
            : "Automated review complete";

        new Notification(notificationTitle, {
          body,
          tag: "cmux-review-complete",
        });
      } catch {
        // Ignore notification errors (for example, blocked constructors)
      } finally {
        setShouldNotifyOnCompletion(false);
      }
    }
  }, [
    isNotificationSupported,
    notificationPermission,
    pendingFileCount,
    shouldNotifyOnCompletion,
    totalFileCount,
    normalizedJobType,
    pullRequestTitle,
    pullRequestUrl,
    repoFullName,
    prNumber,
  ]);

  const handleEnableCompletionNotification = useCallback(async () => {
    if (!isNotificationSupported) {
      return;
    }

    if (notificationPermission === "granted") {
      setShouldNotifyOnCompletion(true);
      return;
    }

    if (notificationPermission === "denied") {
      return;
    }

    setIsRequestingNotification(true);
    try {
      const permission = await Notification.requestPermission();
      setNotificationPermission(permission);
      if (permission === "granted") {
        setShouldNotifyOnCompletion(true);
      }
    } catch {
      // Ignore errors while requesting permission
    } finally {
      setIsRequestingNotification(false);
    }
  }, [isNotificationSupported, notificationPermission]);

  const hasKnownPendingFiles =
    processedFileCount !== null && pendingFileCount > 0;

  const handleDisableCompletionNotification = useCallback(() => {
    setShouldNotifyOnCompletion(false);
  }, []);

  const notificationCardState =
    useMemo<ReviewCompletionNotificationCardState | null>(() => {
      if (
        !isNotificationSupported ||
        !hasKnownPendingFiles ||
        notificationPermission === null
      ) {
        return null;
      }

      if (notificationPermission === "denied") {
        return { kind: "blocked" };
      }

      if (shouldNotifyOnCompletion) {
        return {
          kind: "enabled",
          onDisable: handleDisableCompletionNotification,
        };
      }

      return {
        kind: "prompt",
        isRequesting: isRequestingNotification,
        onEnable: handleEnableCompletionNotification,
      };
    }, [
      handleDisableCompletionNotification,
      handleEnableCompletionNotification,
      hasKnownPendingFiles,
      isNotificationSupported,
      isRequestingNotification,
      notificationPermission,
      shouldNotifyOnCompletion,
    ]);

  const parsedDiffs = useMemo<ParsedFileDiff[]>(() => {
    return sortedFiles.map((file) => {
      if (!file.patch) {
        const renameMessage =
          file.status === "renamed"
            ? buildRenameMissingDiffMessage(file)
            : null;
        return {
          file,
          anchorId: file.filename,
          diff: null,
          error: renameMessage ?? undefined,
        };
      }

      try {
        const [diff] = parseDiff(buildDiffText(file), {
          nearbySequences: "zip",
        });
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
  }, [sortedFiles]);

  const fileEntries = useMemo<FileDiffViewModel[]>(() => {
    return parsedDiffs.map((entry) => {
      const review = fileOutputIndex.get(entry.file.filename) ?? null;
      const streamState = streamStateByFile.get(entry.file.filename) ?? null;
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
      if (entry.diff && reviewHeatmap.length > 0 && !diffHeatmapArtifacts) {
        console.debug("[simple-review][frontend] No artifacts derived", {
          filePath: entry.file.filename,
          reviewHeatmapCount: reviewHeatmap.length,
        });
      }

      return {
        entry,
        review,
        reviewHeatmap,
        diffHeatmapArtifacts,
        changeKeyByLine: buildChangeKeyIndex(entry.diff),
        streamState,
      };
    });
  }, [parsedDiffs, fileOutputIndex, streamStateByFile]);

  const thresholdedFileEntries = useMemo(
    () =>
      fileEntries.map((fileEntry) => ({
        ...fileEntry,
        diffHeatmap: fileEntry.diffHeatmapArtifacts
          ? renderDiffHeatmapFromArtifacts(
              fileEntry.diffHeatmapArtifacts,
              heatmapThreshold
            )
          : null,
      })),
    [fileEntries, heatmapThreshold]
  );

  const errorTargets = useMemo<ReviewErrorTarget[]>(() => {
    const targets: ReviewErrorTarget[] = [];

    for (const fileEntry of thresholdedFileEntries) {
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
            filePath: entry.file.filename,
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
  }, [thresholdedFileEntries]);

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
    (target: ReviewErrorTarget, options?: ShowAutoTooltipOptions) => {
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
    // Add loading state to file nodes
    const addLoadingState = (nodes: FileTreeNode[]): FileTreeNode[] => {
      return nodes.map((node) => {
        if (node.file) {
          // This is a file node - check if it's been processed
          const streamState = streamStateByFile.get(node.file.filename);
          const isLoading =
            !fileOutputIndex.has(node.file.filename) &&
            (!streamState || streamState.status === "pending");
          return {
            ...node,
            isLoading,
            children: addLoadingState(node.children),
          };
        }
        // This is a directory node
        return {
          ...node,
          children: addLoadingState(node.children),
        };
      });
    };
    return addLoadingState(tree);
  }, [sortedFiles, fileOutputIndex, streamStateByFile]);
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
    sortedFiles.some((file) => file.filename === hydratedInitialPath)
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
    const hash = decodeURIComponent(window.location.hash.slice(1));
    if (hash && sortedFiles.some((file) => file.filename === hash)) {
      setActivePath(hash);
      setActiveAnchor(hash);
    }
  }, [sortedFiles]);

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
        // Find all visible entries and sort by their position from the top
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .map((entry) => ({
            id: entry.target.id,
            top: entry.target.getBoundingClientRect().top,
          }))
          .sort((a, b) => a.top - b.top);

        // Set the active anchor to the topmost visible file
        if (visible.length > 0 && visible[0]?.id) {
          setActiveAnchor(visible[0].id);
        }
      },
      {
        // Consider a file active when it's in the top 40% of the viewport
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
  }, [parsedDiffs]);

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
    (event: ReactKeyboardEvent<HTMLDivElement>) => {
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
    },
    []
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
        handleFocusNext({ source: "keyboard" });
      } else if (key === "k") {
        event.preventDefault();
        handleFocusPrevious({ source: "keyboard" });
      }
    };

    window.addEventListener("keydown", handleKeydown);

    return () => {
      window.removeEventListener("keydown", handleKeydown);
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

    const frame = window.requestAnimationFrame(() => {
      const article = document.getElementById(focusedError.anchorId);
      if (article) {
        scrollElementToViewportCenter(article);
      }
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [focusedError, handleNavigate]);

  const kitty = useMemo(() => {
    return kitties[Math.floor(Math.random() * kitties.length)];
  }, []);

  if (totalFileCount === 0) {
    return (
      <div className="border border-neutral-200 bg-white p-8 text-sm text-neutral-600">
        This pull request does not introduce any file changes.
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-stretch lg:gap-0">
        <aside
          id={sidebarPanelId}
          className="relative w-full lg:sticky lg:top-2 lg:h-[calc(100vh)] lg:flex-none lg:overflow-y-auto lg:w-[var(--pr-diff-sidebar-width)] lg:min-w-[15rem] lg:max-w-[32.5rem]"
          style={
            {
              "--pr-diff-sidebar-width": `${sidebarWidth}px`,
            } as CSSProperties
          }
        >
          <div className="flex flex-col gap-3">
            <div className="lg:sticky lg:top-0 lg:z-10 lg:bg-white">
              <ReviewProgressIndicator
                totalFileCount={totalFileCount}
                processedFileCount={processedFileCount}
                isLoading={isLoadingFileOutputs}
              />
            </div>
            <CmuxPromoCard />
            {notificationCardState ? (
              <ReviewCompletionNotificationCard state={notificationCardState} />
            ) : null}
            <HeatmapThresholdControl
              value={heatmapThresholdInput}
              onChange={setHeatmapThresholdInput}
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
            <div>
              <FileTreeNavigator
                nodes={fileTree}
                activePath={activeAnchor}
                expandedPaths={expandedPaths}
                onToggleDirectory={handleToggleDirectory}
                onSelectFile={handleNavigate}
              />
            </div>
          </div>
          <div className="h-[40px]" />
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

        <div className="flex-1 min-w-0 space-y-3">
          {thresholdedFileEntries.map(
            ({ entry, review, diffHeatmap, streamState }) => {
              const isFocusedFile =
                focusedError?.filePath === entry.file.filename;
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
                autoTooltipTarget.filePath === entry.file.filename
                  ? {
                      side: autoTooltipTarget.side,
                      lineNumber: autoTooltipTarget.lineNumber,
                    }
                  : null;

              const isLoading =
                !fileOutputIndex.has(entry.file.filename) &&
                (!streamState || streamState.status === "pending");

              return (
                <FileDiffCard
                  key={entry.anchorId}
                  entry={entry}
                  isActive={entry.anchorId === activeAnchor}
                  review={review}
                  diffHeatmap={diffHeatmap}
                  focusedLine={focusedLine}
                  focusedChangeKey={focusedChangeKey}
                  autoTooltipLine={autoTooltipLine}
                  isLoading={isLoading}
                  streamState={streamState}
                />
              );
            }
          )}
          <div className="h-[70dvh] w-full">
            <div className="px-3 py-6 text-center">
              <span className="select-none text-xs text-neutral-500">
                You&apos;ve reached the end of the diff!
              </span>
              <div className="grid place-content-center pb-4">
                <pre className="mt-2 select-none text-left text-[8px] font-mono text-neutral-500">
                  {kitty}
                </pre>
              </div>
              <a
                href="https://github.com/manaflow-ai/cmux"
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 border border-neutral-200 px-3 py-1.5 text-xs font-semibold text-neutral-500 transition hover:border-neutral-300 hover:bg-neutral-50 select-none"
              >
                <Star className="h-3.5 w-3.5" aria-hidden />
                Star on GitHub
              </a>
            </div>
          </div>
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
  const isFullyProcessed =
    processedFileCount !== null && pendingFileCount === 0;
  const shouldPulsePending =
    processedFileCount === null || pendingFileCount > 0;

  return (
    <div
      className="border border-neutral-200 bg-white p-5 pt-4 transition"
      aria-live="polite"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="text-sm font-medium text-neutral-700">
            Automated review progress
          </p>
          <p className="sr-only">{statusText}</p>
        </div>
        <div className="flex items-center gap-2 text-xs font-semibold">
          {isFullyProcessed ? (
            <span
              className={cn(
                "bg-emerald-100 px-2 py-0.5 text-emerald-700",
                isLoading ? "animate-pulse" : undefined
              )}
            >
              All files processed
            </span>
          ) : (
            <>
              <span
                className={cn(
                  "bg-emerald-100 px-2 py-0.5 text-emerald-700",
                  isLoading ? "animate-pulse" : undefined
                )}
              >
                {processedBadgeText}
              </span>
              <span
                className={cn(
                  "bg-amber-100 px-2 py-0.5 text-amber-700",
                  shouldPulsePending ? "animate-pulse" : undefined
                )}
              >
                {pendingBadgeText}
              </span>
            </>
          )}
        </div>
      </div>
      <div className="mt-3 h-2 bg-neutral-200">
        <div
          className="h-full bg-sky-500 transition-[width] duration-300 ease-out"
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

function CmuxPromoCard() {
  return (
    <div className="border border-neutral-200 bg-white p-5 pt-4 text-sm text-neutral-700">
      <div className="flex flex-col gap-1">
        <div className="flex flex-row items-center justify-start gap-2 text-center">
          <p className="text-xs font-mono leading-relaxed text-neutral-900 font-bold">
            From the creators of
          </p>
          <a
            href="https://cmux.dev"
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Visit cmux.dev"
            className="inline-flex w-fit items-center justify-start transform translate-y-[-1px] translate-x-[-2.5px]"
          >
            <CmuxLogo
              height={28}
              label="cmux.dev"
              wordmarkText="cmux.dev"
              wordmarkFill="#0f172a"
            />
          </a>
        </div>
        <div className="mb-1">
          <p className="text-xs font-mono leading-relaxed text-neutral-500">
            We also made a Claude Code/Codex manager! Check out cmux if you want
            heatmaps for your vibe coded diffs (coming soon)!
          </p>
        </div>
        <div className="flex flex-wrap gap-2 pt-1">
          <a
            href="https://cmux.dev"
            target="_blank"
            rel="noopener noreferrer"
            className="font-mono inline-flex items-center justify-center bg-neutral-900 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-neutral-800"
          >
            Explore cmux
          </a>
          <a
            href="https://github.com/manaflow-ai/cmux"
            target="_blank"
            rel="noopener noreferrer"
            className="font-mono inline-flex items-center gap-1 border border-neutral-200 px-3 py-1.5 text-xs font-semibold text-neutral-700 transition hover:border-neutral-300 hover:bg-neutral-50"
          >
            <Star className="h-3.5 w-3.5" aria-hidden />
            Star on GitHub
          </a>
        </div>
      </div>
    </div>
  );
}

function HeatmapThresholdControl({
  value,
  onChange,
}: {
  value: number;
  onChange: (next: number) => void;
}) {
  const sliderId = useId();
  const descriptionId = `${sliderId}-description`;
  const percent = Math.round(Math.min(Math.max(value, 0), 1) * 100);

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

  return (
    <div className="rounded border border-neutral-200 bg-white px-4 py-3 text-sm text-neutral-700">
      <div className="flex items-center justify-between gap-3">
        <label htmlFor={sliderId} className="font-medium text-neutral-700">
          &ldquo;Should review&rdquo; threshold
        </label>
        <span className="text-xs font-semibold text-neutral-600">
          ≥ <span className="tabular-nums">{percent}%</span>
        </span>
      </div>
      <input
        id={sliderId}
        type="range"
        min={0}
        max={100}
        step={5}
        value={percent}
        onChange={handleSliderChange}
        className="mt-3 w-full accent-sky-500"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent}
        aria-valuetext={`"Should review" threshold ${percent} percent`}
        aria-describedby={descriptionId}
      />
      <p id={descriptionId} className="mt-2 text-xs text-neutral-500">
        Only show heatmap highlights with a score at or above this value.
      </p>
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
      <div className="flex items-center gap-3 border border-sky-200 bg-white/95 px-3 py-1 text-xs font-medium text-neutral-700 backdrop-blur dark:border-sky-800/60 dark:bg-neutral-900/95 dark:text-neutral-200">
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
                onClick={() => onPrevious()}
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
                ⇧ K
              </span>
            </TooltipContent>
          </Tooltip>
          <Tooltip delayDuration={120}>
            <TooltipTrigger asChild>
              <button
                type="button"
                onClick={() => onNext()}
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
                ⇧ J
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
                  "flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-sm transition hover:bg-neutral-100",
                  isExpanded ? "text-neutral-900" : "text-neutral-700"
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
                  <MaterialSymbolsFolderOpenSharp
                    className="h-4 w-4 text-neutral-500 flex-shrink-0 pr-0.5"
                    style={{ minWidth: "14px", minHeight: "14px" }}
                  />
                ) : (
                  <MaterialSymbolsFolderSharp
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
              "flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-sm transition hover:bg-neutral-100",
              isActive
                ? "bg-sky-100/80 text-sky-900 font-semibold"
                : "text-neutral-700"
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

function FileDiffCard({
  entry,
  isActive,
  review,
  diffHeatmap,
  focusedLine,
  focusedChangeKey,
  autoTooltipLine,
  isLoading,
  streamState,
}: {
  entry: ParsedFileDiff;
  isActive: boolean;
  review: FileOutput | null;
  diffHeatmap: DiffHeatmap | null;
  focusedLine: DiffLineLocation | null;
  focusedChangeKey: string | null;
  autoTooltipLine: DiffLineLocation | null;
  isLoading: boolean;
  streamState: StreamFileState | null;
}) {
  const { file, diff, anchorId, error } = entry;
  const cardRef = useRef<HTMLElement | null>(null);
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

  useEffect(() => {
    if (!focusedChangeKey) {
      return;
    }
    setIsCollapsed(false);
  }, [focusedChangeKey]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    if (!focusedChangeKey) {
      return;
    }
    const currentCard = cardRef.current;
    if (!currentCard) {
      return;
    }

    const targetCell = currentCard.querySelector<HTMLElement>(
      `[data-change-key="${focusedChangeKey}"]`
    );
    if (!targetCell) {
      return;
    }

    const targetRow = targetCell.closest("tr");
    const scrollTarget =
      targetRow instanceof HTMLElement ? targetRow : targetCell;
    window.requestAnimationFrame(() => {
      scrollElementToViewportCenter(scrollTarget);
    });
  }, [focusedChangeKey]);

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

  const renderHeatmapToken = useMemo<RenderToken | undefined>(() => {
    if (!lineTooltips || lineTooltips.new.size === 0) {
      return undefined;
    }

    const renderTokenWithTooltip: RenderToken = (
      token,
      renderDefault,
      index
    ) => {
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
          const tooltipMeta = lineTooltips.new.get(lineNumber);
          if (tooltipMeta) {
            const rendered = renderDefault(token, index);
            return (
              <Tooltip
                key={`heatmap-char-${lineNumber}-${index}`}
                delayDuration={120}
              >
                <TooltipTrigger asChild>
                  <span className="cmux-heatmap-char-wrapper">{rendered}</span>
                </TooltipTrigger>
                <TooltipContent
                  side="bottom"
                  align="start"
                  sideOffset={0}
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

      const isAutoTooltipOpen =
        autoTooltipLine !== null &&
        autoTooltipLine.side === side &&
        autoTooltipLine.lineNumber === lineNumber;

      return wrapInAnchor(
        <HeatmapGutterTooltip
          key={`heatmap-gutter-${side}-${lineNumber}`}
          isAutoOpen={isAutoTooltipOpen}
          tooltipMeta={tooltipMeta}
        >
          {content}
        </HeatmapGutterTooltip>
      );
    };

    return renderGutterWithTooltip;
  }, [lineTooltips, autoTooltipLine]);

  const tokens = useMemo<HunkTokens | null>(() => {
    if (!diff) {
      return null;
    }

    const enhancers =
      diffHeatmap &&
      (diffHeatmap.newRanges.length > 0 || diffHeatmap.oldRanges.length > 0)
        ? [pickRanges(diffHeatmap.oldRanges, diffHeatmap.newRanges)]
        : undefined;

    if (language && refractor.registered(language)) {
      try {
        return tokenize(diff.hunks, {
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
      diff.hunks,
      enhancers
        ? {
            enhancers,
          }
        : undefined
    );
  }, [diff, language, diffHeatmap]);

  const reviewContent = useMemo(() => {
    if (!review) {
      return null;
    }

    return JSON.stringify(review.codexReviewOutput, null, 2);
    // return extractAutomatedReviewText(review.codexReviewOutput);
  }, [review]);

  // const showReview = Boolean(reviewContent);
  const showReview = false;

  return (
    <TooltipProvider
      delayDuration={120}
      skipDelayDuration={100}
      disableHoverableContent
    >
      <article
        id={anchorId}
        ref={cardRef}
        className={cn(
          "border border-neutral-200 bg-white transition focus:outline-none",
          isActive ? "" : ""
        )}
        tabIndex={-1}
        aria-current={isActive}
      >
        <div className="flex flex-col divide-y divide-neutral-200">
          <button
            type="button"
            onClick={() => setIsCollapsed((previous) => !previous)}
            className={clsx(
              "sticky top-0 z-10 flex w-full items-center gap-0 border-neutral-200 bg-neutral-50 px-3.5 py-2.5 text-left font-sans font-medium transition hover:bg-neutral-100 focus:outline-none focus-visible:outline-none"
            )}
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
                "flex h-5 w-5 items-center justify-center pl-2",
                statusMeta.colorClassName
              )}
            >
              {statusMeta.icon}
              <span className="sr-only">{statusMeta.label}</span>
            </span>

            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
              <span className="pl-1.5 text-sm text-neutral-700 truncate flex items-center gap-2">
                {file.filename}
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
                      className="rounded-md border border-neutral-200 bg-white px-2.5 py-1.5 text-xs text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                    >
                      AI review in progress...
                    </TooltipContent>
                  </Tooltip>
                ) : streamState?.status === "skipped" ? (
                  <Tooltip delayDuration={300}>
                    <TooltipTrigger asChild>
                      <span className="inline-flex items-center text-amber-600">
                        <AlertTriangle className="h-3 w-3" aria-hidden />
                      </span>
                    </TooltipTrigger>
                    <TooltipContent
                      side="bottom"
                      align="start"
                      className="rounded-md border border-neutral-200 bg-white px-2.5 py-1.5 text-xs text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                    >
                      {streamState.skipReason ??
                        streamState.summary ??
                        "AI skipped this file"}
                    </TooltipContent>
                  </Tooltip>
                ) : streamState?.status === "error" ? (
                  <Tooltip delayDuration={300}>
                    <TooltipTrigger asChild>
                      <span className="inline-flex items-center text-rose-600">
                        <AlertTriangle className="h-3 w-3" aria-hidden />
                      </span>
                    </TooltipTrigger>
                    <TooltipContent
                      side="bottom"
                      align="start"
                      className="rounded-md border border-neutral-200 bg-white px-2.5 py-1.5 text-xs text-neutral-700 shadow-md dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                    >
                      {streamState.summary ?? "AI review failed"}
                    </TooltipContent>
                  </Tooltip>
                ) : null}
              </span>
            </div>

            <div className="flex items-center gap-2 text-[13px] font-medium text-neutral-600">
              <span className="text-emerald-600">+{file.additions}</span>
              <span className="text-rose-600">-{file.deletions}</span>
            </div>
          </button>

          {showReview && reviewContent ? (
            <div className="border-b border-neutral-200 bg-sky-50 px-4 py-2">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-sky-700">
                  <Sparkles className="h-4 w-4" aria-hidden />
                  Automated review
                </div>
                <CopyButton text={reviewContent} />
              </div>
              <pre className="mt-2 max-h-[9.5rem] overflow-auto whitespace-pre-wrap break-words font-sans text-sm leading-relaxed text-neutral-900">
                {reviewContent}
              </pre>
            </div>
          ) : null}

          {!isCollapsed &&
            (diff ? (
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
                  const hasFocus =
                    focusedLine !== null &&
                    normalizedChanges.some((change) =>
                      doesChangeMatchLine(change, focusedLine)
                    );
                  if (hasFocus) {
                    classNames.push("cmux-heatmap-focus");
                  }
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
                      const currentTier = extractHeatmapTier(bestHeatmapClass);
                      const nextTier = extractHeatmapTier(candidate);
                      if (nextTier > currentTier) {
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

                  classNames.push("text-neutral-800");

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
            ))}
        </div>
      </article>
    </TooltipProvider>
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
    <Tooltip delayDuration={120} open={isOpen} onOpenChange={handleOpenChange}>
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

function HeatmapTooltipBody({
  score,
  reason,
}: {
  score: number;
  reason: string | null;
}) {
  const theme = getHeatmapTooltipTheme(score);
  return (
    <div className="text-left text-xs leading-relaxed">
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
          "bg-orange-100 border-orange-300 text-neutral-900 shadow-lg shadow-orange-200/70",
        titleClass: "text-neutral-900",
        reasonClass: "text-neutral-800",
      };
    case 3:
      return {
        contentClass:
          "bg-amber-100 border-amber-300 text-neutral-900 shadow-lg shadow-amber-200/70",
        titleClass: "text-neutral-900",
        reasonClass: "text-neutral-800",
      };
    case 2:
      return {
        contentClass:
          "bg-yellow-100 border-yellow-200 text-neutral-900 shadow-lg shadow-yellow-200/60",
        titleClass: "text-neutral-900",
        reasonClass: "text-neutral-800",
      };
    case 1:
      return {
        contentClass:
          "bg-yellow-50 border-yellow-200 text-neutral-900 shadow-lg shadow-yellow-200/50",
        titleClass: "text-neutral-900",
        reasonClass: "text-neutral-700",
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

function _extractAutomatedReviewText(value: unknown): string | null {
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
      return _extractAutomatedReviewText(
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
    const rawLine = typeof record.line === "string" ? record.line : null;
    const line = rawLine?.trim() ?? null;
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

    let changeFlag: string | null = null;
    if (typeof rawLine === "string") {
      if (rawLine.startsWith("+")) {
        changeFlag = "Added";
      } else if (rawLine.startsWith("-")) {
        changeFlag = "Removed";
      }
    }

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

function scrollElementToViewportCenter(
  element: HTMLElement,
  { behavior = "auto" }: { behavior?: ScrollBehavior } = {}
): void {
  if (typeof window === "undefined") {
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

function buildDiffText(file: GithubFileChange): string {
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

function buildFileTree(files: GithubFileChange[]): FileTreeNode[] {
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

function buildRenameMissingDiffMessage(file: GithubFileChange): string {
  const previousPath = file.previous_filename;
  if (previousPath) {
    return `File renamed from ${previousPath} to ${file.filename}.`;
  }
  return "File renamed without diff details.";
}
