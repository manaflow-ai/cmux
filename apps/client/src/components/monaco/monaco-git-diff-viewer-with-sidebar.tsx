import { DiffEditor, type DiffOnMount } from "@monaco-editor/react";
import { Flame, MessageSquare, PanelLeftClose, PanelLeft, X } from "lucide-react";
import type { editor } from "monaco-editor";
import {
  memo,
  use,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createRoot, type Root } from "react-dom/client";

import { useTheme } from "@/components/theme/use-theme";
import { Markdown } from "@/components/Markdown";
import { loaderInitPromise } from "@/lib/monaco-environment";
import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import type { Id } from "@cmux/convex/dataModel";

import { FileDiffHeaderWithViewed } from "../file-diff-header-with-viewed";
import { kitties } from "../kitties";
import type { DiffLineComment, DiffLineCommentSide, GitDiffViewerProps } from "../codemirror-git-diff-viewer";
import { DiffSidebarFilter } from "./diff-sidebar-filter";
import {
  DiffCommentsProvider,
  DiffCommentsSidebar,
  useDiffCommentsOptional,
  DiffCommentInput,
  InlineCommentWidget,
  AddCommentControl,
  type DiffCommentSide,
} from "../diff-comments";
import { formatDistanceToNow } from "date-fns";

void loaderInitPromise;

// ============================================================================
// Types
// ============================================================================

type DiffEditorControls = {
  updateCollapsedState: (collapsed: boolean) => void;
  updateTargetMinHeight: (minHeight: number) => void;
};

type MonacoFileGroup = {
  filePath: string;
  oldPath?: string;
  status: ReplaceDiffEntry["status"];
  additions: number;
  deletions: number;
  oldContent: string;
  newContent: string;
  patch?: string;
  isBinary: boolean;
  contentOmitted: boolean;
  language: string;
  editorMetrics: EditorLayoutMetrics | null;
};

type CollapsedLayoutEstimate = {
  visibleLineCount: number;
  collapsedRegionCount: number;
  hiddenLineCount: number;
};

type EditorLayoutMetrics = {
  visibleLineCount: number;
  limitedVisibleLineCount: number;
  collapsedRegionCount: number;
  editorMinHeight: number;
  hiddenLineCount: number;
};

type DiffBlock =
  | {
      kind: "changed";
      originalLength: number;
      modifiedLength: number;
    }
  | {
      kind: "unchanged";
      originalLength: number;
      modifiedLength: number;
    };

export type MonacoGitDiffViewerWithSidebarProps = GitDiffViewerProps & {
  isHeatmapActive?: boolean;
  onToggleHeatmap?: () => void;
  // Comments support
  teamSlugOrId?: string;
  taskRunId?: Id<"taskRuns">;
  currentUserId?: string;
};

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_MONACO_LINE_HEIGHT = 20;
const MONACO_VERTICAL_PADDING = 0;
const MIN_EDITOR_LINE_FALLBACK = 4;
const HIDDEN_REGION_BASE_PLACEHOLDER_HEIGHT = 20;
const HIDDEN_REGION_PER_LINE_HEIGHT = 0.6;
const INTERSECTION_VISIBILITY_MARGIN_PX = 96;

const HIDE_UNCHANGED_REGIONS_SETTINGS = {
  revealLineCount: 2,
  minimumLineCount: 6,
  contextLineCount: 3,
} as const;

const DEFAULT_EDITOR_MIN_HEIGHT =
  MIN_EDITOR_LINE_FALLBACK * DEFAULT_MONACO_LINE_HEIGHT;

const newlinePattern = /\r?\n/;

const LANGUAGE_BY_EXTENSION: Record<string, string> = {
  ts: "typescript",
  tsx: "typescript",
  js: "javascript",
  jsx: "javascript",
  json: "json",
  md: "markdown",
  markdown: "markdown",
  yml: "yaml",
  yaml: "yaml",
  py: "python",
  rs: "rust",
  go: "go",
  java: "java",
  kt: "kotlin",
  swift: "swift",
  css: "css",
  scss: "scss",
  less: "less",
  html: "html",
  htm: "html",
  sh: "shell",
  bash: "shell",
  zsh: "shell",
  c: "c",
  h: "c",
  cpp: "cpp",
  cxx: "cpp",
  hpp: "cpp",
  m: "objective-c",
  mm: "objective-c",
  php: "php",
  rb: "ruby",
  sql: "sql",
  toml: "toml",
  ini: "ini",
  conf: "ini",
  xml: "xml",
  vue: "vue",
  svelte: "svelte",
  dart: "dart",
  scala: "scala",
};

// ============================================================================
// Utilities
// ============================================================================

function debugGitDiffViewerLog(
  message: string,
  payload?: Record<string, unknown>
) {
  if (!isElectron && import.meta.env.PROD) {
    return;
  }
  if (payload) {
    console.info("[monaco-git-diff-viewer-with-sidebar]", message, payload);
  } else {
    console.info("[monaco-git-diff-viewer-with-sidebar]", message);
  }
}

function splitContentIntoLines(content: string): string[] {
  if (!content) {
    return [""];
  }

  const parts = content.split(newlinePattern);
  return parts.length > 0 ? parts : [""];
}

function computeDiffBlocks(
  originalLines: readonly string[],
  modifiedLines: readonly string[]
): DiffBlock[] {
  const originalLength = originalLines.length;
  const modifiedLength = modifiedLines.length;

  if (originalLength === 0 && modifiedLength === 0) {
    return [];
  }

  const dp: Uint32Array[] = Array.from(
    { length: originalLength + 1 },
    () => new Uint32Array(modifiedLength + 1)
  );

  for (
    let originalIndex = originalLength - 1;
    originalIndex >= 0;
    originalIndex -= 1
  ) {
    const currentRow = dp[originalIndex];
    const nextRow = dp[originalIndex + 1];

    for (
      let modifiedIndex = modifiedLength - 1;
      modifiedIndex >= 0;
      modifiedIndex -= 1
    ) {
      if (originalLines[originalIndex] === modifiedLines[modifiedIndex]) {
        currentRow![modifiedIndex] = nextRow![modifiedIndex + 1]! + 1;
      } else {
        currentRow![modifiedIndex] = Math.max(
          nextRow![modifiedIndex]!,
          currentRow![modifiedIndex + 1]!
        );
      }
    }
  }

  type DiffSegmentType = "equal" | "insert" | "delete";

  type DiffSegment = {
    type: DiffSegmentType;
    originalStart: number;
    originalEnd: number;
    modifiedStart: number;
    modifiedEnd: number;
  };

  const segments: DiffSegment[] = [];
  let currentSegment: DiffSegment | null = null;

  const pushSegment = () => {
    if (currentSegment) {
      segments.push(currentSegment);
      currentSegment = null;
    }
  };

  let originalIndex = 0;
  let modifiedIndex = 0;

  while (originalIndex < originalLength || modifiedIndex < modifiedLength) {
    const originalExhausted = originalIndex >= originalLength;
    const modifiedExhausted = modifiedIndex >= modifiedLength;

    if (
      !originalExhausted &&
      !modifiedExhausted &&
      originalLines[originalIndex] === modifiedLines[modifiedIndex]
    ) {
      if (!currentSegment || currentSegment.type !== "equal") {
        pushSegment();
        currentSegment = {
          type: "equal",
          originalStart: originalIndex,
          originalEnd: originalIndex,
          modifiedStart: modifiedIndex,
          modifiedEnd: modifiedIndex,
        };
      }

      originalIndex += 1;
      modifiedIndex += 1;
      currentSegment.originalEnd = originalIndex;
      currentSegment.modifiedEnd = modifiedIndex;
      continue;
    }

    if (
      modifiedExhausted ||
      (!originalExhausted &&
        dp[originalIndex + 1]![modifiedIndex]! >=
          dp[originalIndex]![modifiedIndex + 1]!)
    ) {
      if (!currentSegment || currentSegment.type !== "delete") {
        pushSegment();
        currentSegment = {
          type: "delete",
          originalStart: originalIndex,
          originalEnd: originalIndex,
          modifiedStart: modifiedIndex,
          modifiedEnd: modifiedIndex,
        };
      }

      originalIndex += 1;
      currentSegment.originalEnd = originalIndex;
    } else {
      if (!currentSegment || currentSegment.type !== "insert") {
        pushSegment();
        currentSegment = {
          type: "insert",
          originalStart: originalIndex,
          originalEnd: originalIndex,
          modifiedStart: modifiedIndex,
          modifiedEnd: modifiedIndex,
        };
      }

      modifiedIndex += 1;
      currentSegment.modifiedEnd = modifiedIndex;
    }
  }

  pushSegment();

  const blocks: DiffBlock[] = [];
  let pendingChange: Extract<DiffBlock, { kind: "changed" }> | null = null;

  for (const segment of segments) {
    const originalSpan = segment.originalEnd - segment.originalStart;
    const modifiedSpan = segment.modifiedEnd - segment.modifiedStart;

    if (segment.type === "equal") {
      if (pendingChange) {
        blocks.push(pendingChange);
        pendingChange = null;
      }

      if (originalSpan > 0 || modifiedSpan > 0) {
        blocks.push({
          kind: "unchanged",
          originalLength: originalSpan,
          modifiedLength: modifiedSpan,
        });
      }

      continue;
    }

    if (!pendingChange) {
      pendingChange = {
        kind: "changed",
        originalLength: 0,
        modifiedLength: 0,
      };
    }

    pendingChange.originalLength += originalSpan;
    pendingChange.modifiedLength += modifiedSpan;
  }

  if (pendingChange) {
    blocks.push(pendingChange);
  }

  return blocks;
}

function estimateCollapsedLayout(
  original: string,
  modified: string
): CollapsedLayoutEstimate {
  const originalLines = splitContentIntoLines(original);
  const modifiedLines = splitContentIntoLines(modified);
  const blocks = computeDiffBlocks(originalLines, modifiedLines);

  if (blocks.length === 0) {
    return {
      visibleLineCount: Math.max(
        HIDE_UNCHANGED_REGIONS_SETTINGS.minimumLineCount,
        MIN_EDITOR_LINE_FALLBACK
      ),
      collapsedRegionCount: 0,
      hiddenLineCount: 0,
    };
  }

  const hasChange = blocks.some(
    (block) =>
      block.kind === "changed" &&
      (block.originalLength > 0 || block.modifiedLength > 0)
  );

  if (!hasChange) {
    const totalLines = Math.max(originalLines.length, modifiedLines.length);
    const visibleLineCount = Math.min(
      totalLines,
      Math.max(
        HIDE_UNCHANGED_REGIONS_SETTINGS.minimumLineCount,
        MIN_EDITOR_LINE_FALLBACK
      )
    );

    return {
      visibleLineCount,
      collapsedRegionCount: 0,
      hiddenLineCount: 0,
    };
  }

  let visibleLineCount = 0;
  let collapsedRegionCount = 0;
  let hiddenLineCount = 0;

  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index]!;

    if (block.kind === "changed") {
      visibleLineCount += Math.max(block.originalLength, block.modifiedLength);
      continue;
    }

    const blockLength = Math.max(block.originalLength, block.modifiedLength);

    if (blockLength === 0) {
      continue;
    }

    const hasPreviousChange =
      index > 0 && blocks[index - 1]?.kind === "changed";
    const hasNextChange =
      index < blocks.length - 1 && blocks[index + 1]?.kind === "changed";

    let visibleBudget = 0;

    if (hasPreviousChange) {
      visibleBudget += HIDE_UNCHANGED_REGIONS_SETTINGS.contextLineCount;
    }

    if (hasNextChange) {
      visibleBudget += HIDE_UNCHANGED_REGIONS_SETTINGS.contextLineCount;
    }

    if (!hasPreviousChange && !hasNextChange) {
      visibleBudget = Math.max(
        HIDE_UNCHANGED_REGIONS_SETTINGS.minimumLineCount,
        MIN_EDITOR_LINE_FALLBACK
      );
    } else {
      visibleBudget = Math.max(
        visibleBudget,
        HIDE_UNCHANGED_REGIONS_SETTINGS.minimumLineCount
      );
    }

    const displayedLines = Math.min(blockLength, visibleBudget);
    visibleLineCount += displayedLines;

    if (displayedLines < blockLength) {
      collapsedRegionCount += 1;
      hiddenLineCount += blockLength - displayedLines;
    }
  }

  visibleLineCount = Math.max(visibleLineCount, MIN_EDITOR_LINE_FALLBACK);

  return { visibleLineCount, collapsedRegionCount, hiddenLineCount };
}

function computeEditorLayoutMetrics(
  original: string,
  modified: string
): EditorLayoutMetrics {
  const { visibleLineCount, collapsedRegionCount, hiddenLineCount } =
    estimateCollapsedLayout(original, modified);

  const limitedVisibleLineCount = Math.min(
    Math.max(visibleLineCount, MIN_EDITOR_LINE_FALLBACK),
    120
  );

  const lineHeightPortion =
    limitedVisibleLineCount * DEFAULT_MONACO_LINE_HEIGHT +
    MONACO_VERTICAL_PADDING;

  const placeholderPortion =
    collapsedRegionCount * HIDDEN_REGION_BASE_PLACEHOLDER_HEIGHT +
    hiddenLineCount * HIDDEN_REGION_PER_LINE_HEIGHT;

  return {
    visibleLineCount,
    limitedVisibleLineCount,
    collapsedRegionCount,
    editorMinHeight: lineHeightPortion + placeholderPortion,
    hiddenLineCount,
  };
}

function guessMonacoLanguage(filePath: string): string {
  const lastDot = filePath.lastIndexOf(".");
  if (lastDot === -1 || lastDot === filePath.length - 1) {
    return "plaintext";
  }
  const ext = filePath.slice(lastDot + 1).toLowerCase();
  return LANGUAGE_BY_EXTENSION[ext] ?? "plaintext";
}

function createDiffEditorMount({
  editorMinHeight,
  getVisibilityTarget,
  onReady,
  onHeightSettled,
}: {
  editorMinHeight: number;
  getVisibilityTarget?: () => Element | null;
  onReady?: (args: {
    diffEditor: editor.IStandaloneDiffEditor;
    container: HTMLElement;
    applyLayout: () => void;
    controls: DiffEditorControls;
  }) => void;
  onHeightSettled?: (height: number) => void;
}): DiffOnMount {
  return (diffEditor, monacoInstance) => {
    const originalEditor = diffEditor.getOriginalEditor();
    const modifiedEditor = diffEditor.getModifiedEditor();
    const container = diffEditor.getContainerDomNode() as HTMLElement | null;

    if (!container) {
      return;
    }

    const disposables: Array<{ dispose: () => void }> = [];
    const originalVisibility = container.style.visibility;
    const originalTransform = container.style.transform;
    let isContainerVisible = container.style.visibility !== "hidden";
    let collapsedState = false;
    let targetMinHeight = Math.max(editorMinHeight, DEFAULT_EDITOR_MIN_HEIGHT);
    let resolvedContentHeight: number | null = null;

    const hasResolvedHeight = () => resolvedContentHeight !== null;

    const getEffectiveMinHeight = () => {
      if (resolvedContentHeight !== null) {
        return resolvedContentHeight;
      }

      return Math.max(targetMinHeight, DEFAULT_EDITOR_MIN_HEIGHT);
    };

    const applyTargetMinHeight = () => {
      if (collapsedState) {
        return;
      }

      if (hasResolvedHeight()) {
        container.style.minHeight = "";
      } else {
        container.style.minHeight = `${getEffectiveMinHeight()}px`;
      }
      container.style.height = "";
      container.style.overflow = "";
    };

    const updateResolvedContentHeight = (nextHeight: number) => {
      const normalizedHeight = Math.max(nextHeight, DEFAULT_MONACO_LINE_HEIGHT);

      if (resolvedContentHeight === normalizedHeight) {
        return;
      }

      resolvedContentHeight = normalizedHeight;
      applyTargetMinHeight();
      onHeightSettled?.(normalizedHeight);
    };

    const parentElement = container.parentElement;
    let layoutAnchor: HTMLElement | null = null;

    if (parentElement) {
      layoutAnchor = document.createElement("div");
      layoutAnchor.dataset.monacoDiffLayoutAnchor = "true";
      layoutAnchor.style.position = "absolute";
      layoutAnchor.style.top = "0";
      layoutAnchor.style.left = "0";
      layoutAnchor.style.right = "0";
      layoutAnchor.style.height = "1px";
      layoutAnchor.style.pointerEvents = "none";
      layoutAnchor.style.visibility = "hidden";

      parentElement.insertBefore(layoutAnchor, container);

      disposables.push({
        dispose: () => {
          if (layoutAnchor && layoutAnchor.parentElement === parentElement) {
            parentElement.removeChild(layoutAnchor);
          }
        },
      });
    }

    const computeHeight = (targetEditor: editor.IStandaloneCodeEditor) => {
      const contentHeight = targetEditor.getContentHeight();
      if (contentHeight > 0) {
        return { height: contentHeight, measured: true };
      }

      const lineHeight = targetEditor.getOption(
        monacoInstance.editor.EditorOption.lineHeight
      );
      const model = targetEditor.getModel();
      const lineCount = model ? Math.max(1, model.getLineCount()) : 1;

      return { height: lineCount * lineHeight, measured: false };
    };

    applyTargetMinHeight();

    const applyLayout = () => {
      const originalHeightInfo = computeHeight(originalEditor);
      const modifiedHeightInfo = computeHeight(modifiedEditor);
      const height = Math.max(
        originalHeightInfo.height,
        modifiedHeightInfo.height
      );
      const heightMatchesOriginal =
        originalHeightInfo.height >= modifiedHeightInfo.height &&
        originalHeightInfo.measured;
      const heightMatchesModified =
        modifiedHeightInfo.height >= originalHeightInfo.height &&
        modifiedHeightInfo.measured;

      if ((heightMatchesOriginal || heightMatchesModified) && height > 0) {
        updateResolvedContentHeight(height);
      }

      const modifiedInfo = modifiedEditor.getLayoutInfo();
      const originalInfo = originalEditor.getLayoutInfo();
      const containerWidth =
        container.clientWidth ||
        container.getBoundingClientRect().width ||
        modifiedInfo.width ||
        originalInfo.width;

      const enforcedHeight = Math.max(getEffectiveMinHeight(), height);

      if (containerWidth > 0 && enforcedHeight > 0) {
        diffEditor.layout({ width: containerWidth, height: enforcedHeight });
      }

      scheduleVisibilityEvaluation();
    };

    const showContainer = () => {
      if (isContainerVisible) {
        return;
      }

      isContainerVisible = true;
      container.style.visibility = originalVisibility || "visible";
      container.style.transform = originalTransform || "";
    };

    const hideContainer = () => {
      if (!isContainerVisible) {
        return;
      }

      isContainerVisible = false;
      container.style.visibility = "hidden";
      container.style.transform = "translateX(100000px)";
    };

    const updateCollapsedState = (collapsed: boolean) => {
      collapsedState = collapsed;
      if (collapsed) {
        container.style.minHeight = "0px";
        container.style.height = "0px";
        container.style.overflow = "hidden";
      } else {
        applyTargetMinHeight();
        applyLayout();
      }
    };

    const updateTargetMinHeight = (nextTarget: number) => {
      targetMinHeight = Math.max(nextTarget, DEFAULT_EDITOR_MIN_HEIGHT);
      resolvedContentHeight = null;
      if (!collapsedState) {
        applyTargetMinHeight();
        applyLayout();
      }
    };

    const observer = new ResizeObserver(() => {
      applyLayout();
    });

    if (observer) {
      observer.observe(container);
      disposables.push({ dispose: () => observer.disconnect() });
    }

    const intersectionAnchor = layoutAnchor ?? container;
    const resolvedVisibilityTarget = getVisibilityTarget?.() ?? null;
    const intersectionTarget =
      resolvedVisibilityTarget ??
      intersectionAnchor.closest("article") ??
      intersectionAnchor;

    let visibilityRafHandle: number | null = null;

    const evaluateVisibility = () => {
      if (!intersectionTarget) {
        return;
      }

      const viewportHeight =
        typeof window === "undefined"
          ? 0
          : window.innerHeight || document.documentElement.clientHeight || 0;

      if (viewportHeight === 0) {
        return;
      }

      const { top, bottom } = intersectionTarget.getBoundingClientRect();
      const shouldHideEvaluated =
        bottom < -INTERSECTION_VISIBILITY_MARGIN_PX ||
        top > viewportHeight + INTERSECTION_VISIBILITY_MARGIN_PX;

      if (shouldHideEvaluated) {
        hideContainer();
      } else {
        showContainer();
      }
    };

    const scheduleVisibilityEvaluation = () => {
      if (typeof window === "undefined") {
        evaluateVisibility();
        return;
      }

      if (visibilityRafHandle !== null) {
        return;
      }

      visibilityRafHandle = window.requestAnimationFrame(() => {
        visibilityRafHandle = null;
        evaluateVisibility();
      });
    };

    const intersectionObserver = new IntersectionObserver(
      (entries) => {
        const viewportHeight =
          typeof window === "undefined"
            ? 0
            : window.innerHeight || document.documentElement.clientHeight || 0;

        for (const entry of entries) {
          if (entry.target !== intersectionTarget) {
            continue;
          }

          const { top, bottom } = entry.boundingClientRect;
          const isAboveViewport = bottom <= 0;
          const isBelowViewport = top >= viewportHeight;
          const beyondMargin =
            bottom < -INTERSECTION_VISIBILITY_MARGIN_PX ||
            top > viewportHeight + INTERSECTION_VISIBILITY_MARGIN_PX;
          const shouldHide =
            viewportHeight > 0 &&
            (isAboveViewport || isBelowViewport) &&
            beyondMargin;

          if (shouldHide) {
            hideContainer();
          } else {
            showContainer();

            if (entry.isIntersecting || entry.intersectionRatio > 0) {
              applyLayout();
            }
          }

          scheduleVisibilityEvaluation();
        }
      },
      {
        threshold: 0,
        rootMargin: `${INTERSECTION_VISIBILITY_MARGIN_PX}px 0px ${INTERSECTION_VISIBILITY_MARGIN_PX}px 0px`,
      }
    );

    if (intersectionObserver) {
      intersectionObserver.observe(intersectionTarget);
      disposables.push({
        dispose: () => intersectionObserver.unobserve(intersectionTarget),
      });
      disposables.push({ dispose: () => intersectionObserver.disconnect() });
    }

    const onScroll = () => {
      scheduleVisibilityEvaluation();
    };
    const onResize = () => {
      scheduleVisibilityEvaluation();
    };

    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onResize);

    disposables.push({
      dispose: () => {
        window.removeEventListener("scroll", onScroll);
        window.removeEventListener("resize", onResize);

        if (visibilityRafHandle !== null) {
          window.cancelAnimationFrame(visibilityRafHandle);
          visibilityRafHandle = null;
        }
      },
    });

    showContainer();
    scheduleVisibilityEvaluation();
    disposables.push({
      dispose: () => {
        isContainerVisible = true;
        container.style.visibility = originalVisibility || "visible";
        container.style.transform = originalTransform || "";
      },
    });

    const onOriginalContentChange = originalEditor.onDidChangeModelContent(
      () => {
        applyLayout();
      }
    );

    const onModifiedContentChange = modifiedEditor.onDidChangeModelContent(
      () => {
        applyLayout();
      }
    );

    const onOriginalConfigChange = originalEditor.onDidChangeConfiguration(
      (event) => {
        if (event.hasChanged(monacoInstance.editor.EditorOption.lineHeight)) {
          applyLayout();
        }
      }
    );

    const onModifiedConfigChange = modifiedEditor.onDidChangeConfiguration(
      (event) => {
        if (event.hasChanged(monacoInstance.editor.EditorOption.lineHeight)) {
          applyLayout();
        }
      }
    );

    const onOriginalSizeChange = originalEditor.onDidContentSizeChange(() => {
      applyLayout();
    });

    const onModifiedSizeChange = modifiedEditor.onDidContentSizeChange(() => {
      applyLayout();
    });

    const onOriginalHiddenAreasChange = originalEditor.onDidChangeHiddenAreas(
      () => {
        applyLayout();
      }
    );

    const onModifiedHiddenAreasChange = modifiedEditor.onDidChangeHiddenAreas(
      () => {
        applyLayout();
      }
    );

    const onDidUpdateDiff = diffEditor.onDidUpdateDiff(() => {
      applyLayout();
    });

    disposables.push(
      onOriginalContentChange,
      onModifiedContentChange,
      onOriginalConfigChange,
      onModifiedConfigChange,
      onOriginalSizeChange,
      onModifiedSizeChange,
      onOriginalHiddenAreasChange,
      onModifiedHiddenAreasChange,
      onDidUpdateDiff
    );

    const disposeListener = diffEditor.onDidDispose(() => {
      disposables.forEach((disposable) => {
        try {
          disposable.dispose();
        } catch (error) {
          console.error("Failed to dispose Monaco listener", error);
        }
      });
    });

    disposables.push(disposeListener);

    applyLayout();

    onReady?.({
      diffEditor,
      container,
      applyLayout,
      controls: {
        updateCollapsedState,
        updateTargetMinHeight,
      },
    });
  };
}

// ============================================================================
// Sub-components
// ============================================================================

type ReviewInlineZoneHandle = {
  zoneId: string;
  zone: editor.IViewZone;
  domNode: HTMLDivElement;
  root: Root;
  resizeObserver: ResizeObserver;
};

type FileDiffRowClassNames = GitDiffViewerProps["classNames"] extends {
  fileDiffRow?: infer T;
}
  ? T
  : { button?: string; container?: string };

interface MonacoFileDiffRowProps {
  file: MonacoFileGroup;
  isExpanded: boolean;
  isViewed: boolean;
  onToggle: () => void;
  onToggleViewed: () => void;
  editorTheme: string;
  diffOptions: editor.IDiffEditorConstructionOptions;
  classNames?: FileDiffRowClassNames;
  anchorId?: string;
  currentUserId?: string;
  commentsEnabled?: boolean;
  onExpandFile?: () => void;
  fileLineComments: DiffLineComment[];
  onAddLineComment?: GitDiffViewerProps["onAddLineComment"];
}

function formatRelativeTime(ts?: number): string | null {
  if (typeof ts !== "number") return null;
  return formatDistanceToNow(new Date(ts), { addSuffix: true });
}

function sideLabel(side: DiffLineCommentSide): string {
  return side === "left" ? "Original" : "Modified";
}

function LineCommentInput({
  filePath,
  lineNumber,
  side,
  onClose,
  onSubmit,
}: {
  filePath: string;
  lineNumber: number;
  side: DiffLineCommentSide;
  onClose: () => void;
  onSubmit: (body: string) => Promise<void>;
}) {
  const [content, setContent] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    textareaRef.current?.focus();
  }, []);

  const handleSubmit = useCallback(async () => {
    const next = content.trim();
    if (!next || isSubmitting) return;
    setIsSubmitting(true);
    try {
      await onSubmit(next);
      setContent("");
      onClose();
    } catch (error) {
      console.error("[monaco-git-diff-viewer-with-sidebar] Failed to add line comment:", error);
    } finally {
      setIsSubmitting(false);
    }
  }, [content, isSubmitting, onClose, onSubmit]);

  return (
    <div className="border border-blue-300 dark:border-blue-700 rounded-lg bg-white dark:bg-neutral-900 shadow-lg overflow-hidden">
      <div className="px-3 py-2 border-b border-neutral-100 dark:border-neutral-800 flex items-center justify-between bg-blue-50/50 dark:bg-blue-900/20">
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">
            Add comment
          </span>
          <span className="text-[10px] text-neutral-400 truncate">
            {filePath} • Line {lineNumber} • {sideLabel(side)}
          </span>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="p-1 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
          aria-label="Close comment input"
        >
          <X className="w-3.5 h-3.5" />
        </button>
      </div>
      <div className="p-3">
        <textarea
          ref={textareaRef}
          value={content}
          onChange={(e) => setContent(e.target.value)}
          placeholder="Write a comment... (Cmd+Enter to add)"
          className="w-full px-3 py-2 text-[13px] bg-neutral-50 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400 dark:focus:border-blue-600"
          rows={3}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              void handleSubmit();
            }
            if (e.key === "Escape") {
              onClose();
            }
          }}
        />
        <div className="flex items-center gap-2 justify-end mt-3">
          <button
            type="button"
            onClick={onClose}
            className="px-3 py-1.5 text-xs font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded-md transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => void handleSubmit()}
            disabled={!content.trim() || isSubmitting}
            className="px-3 py-1.5 text-xs font-medium bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? "Adding..." : "Add comment"}
          </button>
        </div>
      </div>
    </div>
  );
}

function LineCommentThread({ comment }: { comment: DiffLineComment }) {
  const authorLabel =
    comment.author?.login ??
    (comment.kind === "draft" ? "Draft" : "Unknown");
  const timestampLabel = formatRelativeTime(comment.createdAt);

  return (
    <div
      className={cn(
        "border border-neutral-200 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 overflow-hidden shadow-sm",
        comment.kind === "draft" &&
          "border-blue-200 dark:border-blue-900/40 bg-blue-50/20 dark:bg-blue-900/10"
      )}
    >
      <div className="px-3 py-2 border-b border-neutral-100 dark:border-neutral-800 flex items-center gap-2 bg-neutral-50/50 dark:bg-neutral-800/30">
        <div className="flex-1 min-w-0">
          <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
            {authorLabel}
          </span>
          {timestampLabel ? (
            <span className="text-[10px] text-neutral-400 ml-2">
              {timestampLabel}
            </span>
          ) : null}
        </div>
        {comment.kind === "draft" ? (
          <span className="text-[10px] font-medium text-blue-600 dark:text-blue-400 bg-blue-100 dark:bg-blue-900/30 px-1.5 py-0.5 rounded-full">
            Draft
          </span>
        ) : null}
        {comment.url ? (
          <a
            href={comment.url}
            target="_blank"
            rel="noreferrer"
            className="text-[10px] text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 underline underline-offset-2"
          >
            View
          </a>
      ) : null}
      </div>
      <div className="px-3 py-2">
        <Markdown content={comment.body} />
      </div>
    </div>
  );
}

function MonacoFileDiffRow({
  file,
  isExpanded,
  isViewed,
  onToggle,
  onToggleViewed,
  editorTheme,
  diffOptions,
  classNames,
  anchorId,
  currentUserId,
  commentsEnabled,
  onExpandFile,
  fileLineComments,
  onAddLineComment,
}: MonacoFileDiffRowProps) {
  const canRenderEditor =
    !file.isBinary &&
    !file.contentOmitted &&
    file.status !== "deleted" &&
    file.status !== "renamed";

  const editorMinHeight = Math.max(
    file.editorMetrics?.editorMinHeight ?? DEFAULT_EDITOR_MIN_HEIGHT,
    DEFAULT_EDITOR_MIN_HEIGHT
  );

  const diffControlsRef = useRef<DiffEditorControls | null>(null);
  const isExpandedRef = useRef(isExpanded);
  const rowContainerRef = useRef<HTMLDivElement | null>(null);
  const [isHeightSettled, setIsHeightSettled] = useState(false);
  const originalEditorRef = useRef<editor.IStandaloneCodeEditor | null>(null);
  const modifiedEditorRef = useRef<editor.IStandaloneCodeEditor | null>(null);
  const originalReviewDecorationsRef =
    useRef<editor.IEditorDecorationsCollection | null>(null);
  const modifiedReviewDecorationsRef =
    useRef<editor.IEditorDecorationsCollection | null>(null);
  const originalReviewThreadZonesRef = useRef<Map<number, ReviewInlineZoneHandle>>(
    new Map(),
  );
  const modifiedReviewThreadZonesRef = useRef<Map<number, ReviewInlineZoneHandle>>(
    new Map(),
  );
  const reviewInputZoneRef = useRef<{
    side: DiffLineCommentSide;
    lineNumber: number;
    handle: ReviewInlineZoneHandle;
  } | null>(null);

  // Comments state
  const commentsContext = useDiffCommentsOptional();
  const [selectedLineForComment, setSelectedLineForComment] = useState<{
    lineNumber: number;
    side: "left" | "right";
  } | null>(null);

  const reviewCommentsEnabled = Boolean(onAddLineComment);
  const [selectedLineForReviewComment, setSelectedLineForReviewComment] =
    useState<{
      lineNumber: number;
      side: DiffLineCommentSide;
    } | null>(null);

  // Get comments for this file
  const fileComments = useMemo(() => {
    if (!commentsContext || !commentsEnabled) return [];
    return commentsContext.commentsByFile.get(file.filePath) ?? [];
  }, [commentsContext, commentsEnabled, file.filePath]);

  const unresolvedCount = fileComments.filter((c) => !c.resolved).length;

  // Handle adding a comment
  const handleAddComment = useCallback((lineNumber: number, side: DiffCommentSide) => {
    if (!commentsContext || !commentsEnabled) return;

    // Expand the file if collapsed
    if (!isExpanded && onExpandFile) {
      onExpandFile();
    }

    // Set the active comment position
    setSelectedLineForComment({ lineNumber, side });
    commentsContext.setActiveCommentPosition({
      filePath: file.filePath,
      lineNumber,
      side,
    });
  }, [commentsContext, commentsEnabled, isExpanded, onExpandFile, file.filePath]);

  useEffect(() => {
    setIsHeightSettled(false);
  }, [file.filePath, editorMinHeight]);

  useEffect(() => {
    if (isExpanded) return;
    setSelectedLineForReviewComment(null);
  }, [isExpanded]);

  useEffect(() => {
    if (reviewCommentsEnabled) return;
    setSelectedLineForReviewComment(null);
  }, [reviewCommentsEnabled]);

  useEffect(() => {
    isExpandedRef.current = isExpanded;
    diffControlsRef.current?.updateCollapsedState(!isExpanded);
  }, [isExpanded]);

  useEffect(() => {
    diffControlsRef.current?.updateTargetMinHeight(editorMinHeight);
  }, [editorMinHeight]);

  const handleHeightSettled = useCallback(() => {
    setIsHeightSettled(true);
  }, []);

  const onEditorMount = useMemo(
    () =>
      createDiffEditorMount({
        editorMinHeight,
        getVisibilityTarget: () => rowContainerRef.current,
        onReady: ({ diffEditor, controls }) => {
          diffControlsRef.current = controls;
          controls.updateTargetMinHeight(editorMinHeight);
          controls.updateCollapsedState(!isExpandedRef.current);

          const originalEditor = diffEditor.getOriginalEditor();
          const modifiedEditor = diffEditor.getModifiedEditor();
          originalEditorRef.current = originalEditor;
          modifiedEditorRef.current = modifiedEditor;

          originalReviewDecorationsRef.current =
            originalEditor.createDecorationsCollection();
          modifiedReviewDecorationsRef.current =
            modifiedEditor.createDecorationsCollection();
        },
        onHeightSettled: handleHeightSettled,
      }),
    [editorMinHeight, handleHeightSettled]
  );

  // Close comment input
  const handleCloseCommentInput = useCallback(() => {
    setSelectedLineForComment(null);
    commentsContext?.setActiveCommentPosition(null);
  }, [commentsContext]);

  const handleCloseReviewCommentInput = useCallback(() => {
    setSelectedLineForReviewComment(null);
  }, []);

  // Check if we're actively adding a comment to this file
  const isAddingComment =
    commentsContext?.activeCommentPosition?.filePath === file.filePath &&
    selectedLineForComment !== null;

  const handleEditorClick = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      if (!reviewCommentsEnabled) return;
      if (!isExpanded) return;

      const target = e.target;
      if (!(target instanceof HTMLElement)) return;

      const lineNumberEl = target.closest(".line-numbers");
      if (!lineNumberEl) {
        return;
      }

      const lineText = lineNumberEl.textContent?.trim();
      const lineNumber = lineText ? parseInt(lineText, 10) : NaN;
      if (!Number.isFinite(lineNumber) || lineNumber < 1) {
        return;
      }

      const rect = lineNumberEl.getBoundingClientRect();
      const containerRect = rowContainerRef.current?.getBoundingClientRect();
      if (!containerRect) return;
      const relativeX = rect.left - containerRect.left;
      const midpoint = containerRect.width / 2;
      const side: DiffLineCommentSide = relativeX < midpoint ? "left" : "right";
      setSelectedLineForReviewComment((prev) => {
        if (prev && prev.lineNumber === lineNumber && prev.side === side) {
          return null;
        }
        return { lineNumber, side };
      });
    },
    [isExpanded, reviewCommentsEnabled],
  );

  const handleSubmitLineComment = useCallback(
    async (body: string) => {
      if (!onAddLineComment) return;
      if (!selectedLineForReviewComment) return;
      await onAddLineComment({
        filePath: file.filePath,
        lineNumber: selectedLineForReviewComment.lineNumber,
        side: selectedLineForReviewComment.side,
        body,
      });
    },
    [file.filePath, onAddLineComment, selectedLineForReviewComment],
  );

  const disposeReviewZoneHandle = useCallback(
    (
      codeEditor: editor.IStandaloneCodeEditor,
      handle: ReviewInlineZoneHandle,
    ) => {
      try {
        handle.resizeObserver.disconnect();
      } catch (error) {
        console.error("[monaco-git-diff-viewer-with-sidebar] Failed to disconnect resize observer:", error);
      }

      try {
        codeEditor.changeViewZones((accessor) => {
          accessor.removeZone(handle.zoneId);
        });
      } catch (error) {
        console.error("[monaco-git-diff-viewer-with-sidebar] Failed to remove view zone:", error);
      }

      try {
        handle.root.unmount();
      } catch (error) {
        console.error("[monaco-git-diff-viewer-with-sidebar] Failed to unmount review zone root:", error);
      }
    },
    [],
  );

  const clearReviewUi = useCallback(() => {
    const originalEditor = originalEditorRef.current;
    const modifiedEditor = modifiedEditorRef.current;

    if (originalEditor) {
      for (const handle of originalReviewThreadZonesRef.current.values()) {
        disposeReviewZoneHandle(originalEditor, handle);
      }
    }
    if (modifiedEditor) {
      for (const handle of modifiedReviewThreadZonesRef.current.values()) {
        disposeReviewZoneHandle(modifiedEditor, handle);
      }
    }

    originalReviewThreadZonesRef.current.clear();
    modifiedReviewThreadZonesRef.current.clear();

    const input = reviewInputZoneRef.current;
    if (input) {
      const editorForInput =
        input.side === "left" ? originalEditor : modifiedEditor;
      if (editorForInput) {
        disposeReviewZoneHandle(editorForInput, input.handle);
      }
      reviewInputZoneRef.current = null;
    }

    originalReviewDecorationsRef.current?.clear();
    modifiedReviewDecorationsRef.current?.clear();
  }, [disposeReviewZoneHandle]);

  useEffect(() => {
    return () => {
      clearReviewUi();
    };
  }, [clearReviewUi]);

  useEffect(() => {
    const originalEditor = originalEditorRef.current;
    const modifiedEditor = modifiedEditorRef.current;

    if (!originalEditor || !modifiedEditor) {
      return;
    }

    if (!isExpanded) {
      clearReviewUi();
      return;
    }

    const isValidLine = (
      codeEditor: editor.IStandaloneCodeEditor,
      lineNumber: number,
    ) => {
      const model = codeEditor.getModel();
      if (!model) return false;
      if (!Number.isFinite(lineNumber) || lineNumber < 1) return false;
      return lineNumber <= model.getLineCount();
    };

    const createZone = (args: {
      codeEditor: editor.IStandaloneCodeEditor;
      afterLineNumber: number;
      render: (root: Root) => void;
    }): ReviewInlineZoneHandle => {
      const { codeEditor, afterLineNumber, render } = args;

      const domNode = document.createElement("div");
      domNode.className = "cmux-monaco-review-zone";

      const root = createRoot(domNode);
      render(root);

      const zone: editor.IViewZone = {
        afterLineNumber,
        heightInPx: 120,
        domNode,
        suppressMouseDown: true,
      };

      let zoneId = "";
      codeEditor.changeViewZones((accessor) => {
        zoneId = accessor.addZone(zone);
      });

      const updateHeight = () => {
        const height = Math.ceil(domNode.getBoundingClientRect().height);
        if (!Number.isFinite(height) || height <= 0) return;
        if (zone.heightInPx === height) return;
        codeEditor.changeViewZones((accessor) => {
          zone.heightInPx = height;
          accessor.layoutZone(zoneId);
        });
      };

      const resizeObserver = new ResizeObserver(() => {
        updateHeight();
      });
      resizeObserver.observe(domNode);
      requestAnimationFrame(updateHeight);

      return { zoneId, zone, domNode, root, resizeObserver };
    };

    const renderThreadGroup = (args: {
      root: Root;
      lineNumber: number;
      side: DiffLineCommentSide;
      comments: DiffLineComment[];
    }) => {
      args.root.render(
        <div className="px-3 py-2">
          <div className="text-[10px] text-neutral-500 dark:text-neutral-400 mb-2 font-mono select-none">
            Line {args.lineNumber} ({args.side === "left" ? "original" : "modified"})
          </div>
          <div className="space-y-2">
            {args.comments.map((comment) => (
              <LineCommentThread key={comment.id} comment={comment} />
            ))}
          </div>
        </div>,
      );
    };

    const syncThreadZonesForSide = (args: {
      codeEditor: editor.IStandaloneCodeEditor;
      side: DiffLineCommentSide;
      zones: Map<number, ReviewInlineZoneHandle>;
      groups: Map<number, DiffLineComment[]>;
    }) => {
      const { codeEditor, side, zones, groups } = args;

      // Remove zones that are no longer needed
      for (const [lineNumber, handle] of zones.entries()) {
        if (!groups.has(lineNumber)) {
          disposeReviewZoneHandle(codeEditor, handle);
          zones.delete(lineNumber);
        }
      }

      // Add / update zones
      for (const [lineNumber, comments] of groups.entries()) {
        if (!isValidLine(codeEditor, lineNumber)) {
          continue;
        }

        const existing = zones.get(lineNumber);
        if (existing) {
          renderThreadGroup({ root: existing.root, lineNumber, side, comments });
          requestAnimationFrame(() => {
            const height = Math.ceil(existing.domNode.getBoundingClientRect().height);
            if (!Number.isFinite(height) || height <= 0) return;
            if (existing.zone.heightInPx === height) return;
            codeEditor.changeViewZones((accessor) => {
              existing.zone.heightInPx = height;
              accessor.layoutZone(existing.zoneId);
            });
          });
          continue;
        }

        const handle = createZone({
          codeEditor,
          afterLineNumber: lineNumber,
          render: (root) => renderThreadGroup({ root, lineNumber, side, comments }),
        });
        zones.set(lineNumber, handle);
      }
    };

    const groupCommentsBySideLine = () => {
      const originalGroups = new Map<number, DiffLineComment[]>();
      const modifiedGroups = new Map<number, DiffLineComment[]>();
      for (const comment of fileLineComments) {
        const groups = comment.side === "left" ? originalGroups : modifiedGroups;
        const existing = groups.get(comment.lineNumber) ?? [];
        existing.push(comment);
        groups.set(comment.lineNumber, existing);
      }

      for (const comments of originalGroups.values()) {
        comments.sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0));
      }
      for (const comments of modifiedGroups.values()) {
        comments.sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0));
      }

      return { originalGroups, modifiedGroups };
    };

    const { originalGroups, modifiedGroups } = groupCommentsBySideLine();
    syncThreadZonesForSide({
      codeEditor: originalEditor,
      side: "left",
      zones: originalReviewThreadZonesRef.current,
      groups: originalGroups,
    });
    syncThreadZonesForSide({
      codeEditor: modifiedEditor,
      side: "right",
      zones: modifiedReviewThreadZonesRef.current,
      groups: modifiedGroups,
    });

    const shouldShowInput = reviewCommentsEnabled && selectedLineForReviewComment;
    const existingInput = reviewInputZoneRef.current;

    if (!shouldShowInput) {
      if (existingInput) {
        const editorForInput =
          existingInput.side === "left" ? originalEditor : modifiedEditor;
        disposeReviewZoneHandle(editorForInput, existingInput.handle);
        reviewInputZoneRef.current = null;
      }
    } else if (selectedLineForReviewComment) {
      const desiredSide = selectedLineForReviewComment.side;
      const desiredLine = selectedLineForReviewComment.lineNumber;

      if (
        existingInput &&
        existingInput.side === desiredSide &&
        existingInput.lineNumber === desiredLine
      ) {
        existingInput.handle.root.render(
          <div className="px-3 py-2">
            <LineCommentInput
              filePath={file.filePath}
              lineNumber={desiredLine}
              side={desiredSide}
              onClose={handleCloseReviewCommentInput}
              onSubmit={handleSubmitLineComment}
            />
          </div>,
        );
      } else {
        if (existingInput) {
          const editorForInput =
            existingInput.side === "left" ? originalEditor : modifiedEditor;
          disposeReviewZoneHandle(editorForInput, existingInput.handle);
          reviewInputZoneRef.current = null;
        }

        const editorForInput =
          desiredSide === "left" ? originalEditor : modifiedEditor;
        if (isValidLine(editorForInput, desiredLine)) {
          const handle = createZone({
            codeEditor: editorForInput,
            afterLineNumber: desiredLine,
            render: (root) => {
              root.render(
                <div className="px-3 py-2">
                  <LineCommentInput
                    filePath={file.filePath}
                    lineNumber={desiredLine}
                    side={desiredSide}
                    onClose={handleCloseReviewCommentInput}
                    onSubmit={handleSubmitLineComment}
                  />
                </div>,
              );
            },
          });
          reviewInputZoneRef.current = {
            side: desiredSide,
            lineNumber: desiredLine,
            handle,
          };
        }
      }
    }

    const applyDecorations = (args: {
      codeEditor: editor.IStandaloneCodeEditor;
      collection: editor.IEditorDecorationsCollection | null;
      commentLines: Iterable<number>;
      selectedLine: number | null;
    }) => {
      if (!args.collection) return;
      const selected = args.selectedLine;
      const unique = new Set<number>();
      for (const line of args.commentLines) {
        unique.add(line);
      }
      if (typeof selected === "number") {
        unique.add(selected);
      }

      const decorations: editor.IModelDeltaDecoration[] = [];
      for (const lineNumber of Array.from(unique.values()).sort((a, b) => a - b)) {
        if (!isValidLine(args.codeEditor, lineNumber)) {
          continue;
        }

        const isSelected = selected === lineNumber;
        decorations.push({
          range: {
            startLineNumber: lineNumber,
            startColumn: 1,
            endLineNumber: lineNumber,
            endColumn: 1,
          },
          options: {
            isWholeLine: true,
            className: isSelected
              ? "cmux-monaco-review-line-selected"
              : "cmux-monaco-review-line",
          },
        });
      }

      args.collection.set(decorations);
    };

    const selectedOriginalLine =
      selectedLineForReviewComment?.side === "left"
        ? selectedLineForReviewComment.lineNumber
        : null;
    const selectedModifiedLine =
      selectedLineForReviewComment?.side === "right"
        ? selectedLineForReviewComment.lineNumber
        : null;

    applyDecorations({
      codeEditor: originalEditor,
      collection: originalReviewDecorationsRef.current,
      commentLines: originalGroups.keys(),
      selectedLine: selectedOriginalLine,
    });
    applyDecorations({
      codeEditor: modifiedEditor,
      collection: modifiedReviewDecorationsRef.current,
      commentLines: modifiedGroups.keys(),
      selectedLine: selectedModifiedLine,
    });
  }, [
    clearReviewUi,
    disposeReviewZoneHandle,
    file.filePath,
    fileLineComments,
    handleCloseReviewCommentInput,
    handleSubmitLineComment,
    isExpanded,
    reviewCommentsEnabled,
    selectedLineForReviewComment,
  ]);

  return (
    <div
      id={anchorId}
      ref={rowContainerRef}
      className={cn(
        "bg-white dark:bg-neutral-900",
        classNames?.container
      )}
    >
      <FileDiffHeaderWithViewed
        filePath={file.filePath}
        oldPath={file.oldPath}
        status={file.status}
        additions={file.additions}
        deletions={file.deletions}
        isExpanded={isExpanded}
        isViewed={isViewed}
        onToggle={onToggle}
        onToggleViewed={onToggleViewed}
        className={classNames?.button}
        commentCount={commentsEnabled ? fileComments.length : undefined}
        unresolvedCommentCount={commentsEnabled ? unresolvedCount : undefined}
      />

      <div
        className="overflow-hidden flex flex-col"
        style={
          isExpanded
            ? isHeightSettled
              ? undefined
              : { minHeight: editorMinHeight }
            : { minHeight: 0, height: 0 }
        }
        aria-hidden={!isExpanded}
      >
        {file.status === "renamed" ? (
          <div className="grow space-y-2 bg-neutral-50 px-3 py-6 text-center text-xs text-neutral-500 dark:bg-neutral-900/50 dark:text-neutral-400 grid place-content-center">
            <p className="select-none">File was renamed.</p>
            {file.oldPath ? (
              <p className="select-none font-mono text-[11px] text-neutral-600 dark:text-neutral-300">
                {file.oldPath} → {file.filePath}
              </p>
            ) : null}
          </div>
        ) : file.isBinary ? (
          <div className="grow bg-neutral-50 px-3 py-6 text-center text-xs text-neutral-500 dark:bg-neutral-900/50 dark:text-neutral-400 grid place-content-center">
            Binary file not shown
          </div>
        ) : file.status === "deleted" ? (
          <div className="grow bg-neutral-50 px-3 py-6 text-center text-xs text-neutral-500 dark:bg-neutral-900/50 dark:text-neutral-400 grid place-content-center">
            File was deleted
          </div>
        ) : file.contentOmitted ? (
          <div className="grow bg-neutral-50 px-3 py-6 text-center text-xs text-neutral-500 dark:bg-neutral-900/50 dark:text-neutral-400 grid place-content-center">
            Diff content omitted due to size
          </div>
        ) : canRenderEditor ? (
          <div
            className="relative"
            style={isHeightSettled ? undefined : { minHeight: editorMinHeight }}
            onClick={handleEditorClick}
          >
            <DiffEditor
              language={file.language}
              original={file.oldContent}
              modified={file.newContent}
              theme={editorTheme}
              options={diffOptions}
              onMount={onEditorMount}
              keepCurrentModifiedModel={true}
              keepCurrentOriginalModel={true}
            />
          </div>
        ) : null}

        {/* Add comment control bar (only when expanded and comments enabled) */}
        {commentsEnabled && isExpanded && (
          <div className="flex items-center justify-between px-3 py-1.5 border-t border-neutral-200/50 dark:border-neutral-800/50 bg-neutral-50/30 dark:bg-neutral-900/30">
            <AddCommentControl
              onAddComment={handleAddComment}
            />
          </div>
        )}

        {/* Comment input (appears when adding a new comment) */}
        {isAddingComment && selectedLineForComment && (
          <div className="px-4 py-3 border-t border-blue-200 dark:border-blue-800 bg-blue-50/50 dark:bg-blue-900/20">
            <div className="text-xs font-mono text-neutral-500 dark:text-neutral-400 mb-2 flex items-center gap-1.5">
              <MessageSquare className="w-3.5 h-3.5" />
              <span>Line {selectedLineForComment.lineNumber}</span>
              <span className="text-neutral-400 dark:text-neutral-500">
                ({selectedLineForComment.side === "left" ? "original" : "modified"})
              </span>
            </div>
            <DiffCommentInput
              filePath={file.filePath}
              lineNumber={selectedLineForComment.lineNumber}
              side={selectedLineForComment.side}
              onClose={handleCloseCommentInput}
            />
          </div>
        )}

        {/* File comments section */}
        {commentsEnabled && fileComments.length > 0 && isExpanded && (
          <InlineCommentWidget
            filePath={file.filePath}
            currentUserId={currentUserId}
          />
        )}
      </div>
    </div>
  );
}

const MemoMonacoFileDiffRow = memo(MonacoFileDiffRow, (prev, next) => {
  const a = prev.file;
  const b = next.file;
  return (
    prev.isExpanded === next.isExpanded &&
    prev.isViewed === next.isViewed &&
    prev.editorTheme === next.editorTheme &&
    prev.anchorId === next.anchorId &&
    prev.currentUserId === next.currentUserId &&
    prev.commentsEnabled === next.commentsEnabled &&
    prev.onExpandFile === next.onExpandFile &&
    prev.fileLineComments === next.fileLineComments &&
    prev.onAddLineComment === next.onAddLineComment &&
    a.filePath === b.filePath &&
    a.oldPath === b.oldPath &&
    a.status === b.status &&
    a.additions === b.additions &&
    a.deletions === b.deletions &&
    a.isBinary === b.isBinary &&
    a.contentOmitted === b.contentOmitted &&
    a.language === b.language &&
    a.oldContent === b.oldContent &&
    a.newContent === b.newContent
  );
});

// ============================================================================
// Main Component
// ============================================================================

function MonacoGitDiffViewerWithSidebarInner({
  diffs,
  isLoading,
  onControlsChange,
  classNames,
  onFileToggle,
  lineComments,
  onAddLineComment,
  isHeatmapActive,
  onToggleHeatmap,
  currentUserId,
  commentsEnabled,
}: MonacoGitDiffViewerWithSidebarProps & { commentsEnabled: boolean }) {
  const { theme } = useTheme();

  const kitty = useMemo(() => {
    return kitties[Math.floor(Math.random() * kitties.length)];
  }, []);

  // Sidebar collapsed state
  const [isSidebarCollapsed, setIsSidebarCollapsed] = useState(false);

  // Comments sidebar collapsed state
  const [isCommentsSidebarCollapsed, setIsCommentsSidebarCollapsed] = useState(true);

  // Get comments context if available
  const commentsContext = useDiffCommentsOptional();
  const totalComments = commentsContext?.comments.length ?? 0;
  const unresolvedComments = commentsContext?.comments.filter((c) => !c.resolved).length ?? 0;

  // All files expanded by default
  const [expandedFiles, setExpandedFiles] = useState<Set<string>>(
    () => new Set(diffs.map((diff) => diff.filePath))
  );

  // Viewed files state
  const [viewedFiles, setViewedFiles] = useState<Set<string>>(() => new Set());

  // Active path for sidebar navigation
  const [activePath, setActivePath] = useState<string>(() => {
    return diffs[0]?.filePath ?? "";
  });

  // Sync expanded files when diffs change (e.g., after loading)
  useEffect(() => {
    if (diffs.length > 0) {
      setExpandedFiles((prev) => {
        const newSet = new Set(prev);
        for (const diff of diffs) {
          // Add any new files to expanded set
          if (!prev.has(diff.filePath)) {
            newSet.add(diff.filePath);
          }
        }
        return newSet;
      });
    }
  }, [diffs]);

  // Keyboard shortcuts: F to toggle files sidebar, C to toggle comments sidebar
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't trigger if user is typing in an input/textarea
      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement ||
        (e.target instanceof HTMLElement && e.target.isContentEditable)
      ) {
        return;
      }
      if (e.key === "f" || e.key === "F") {
        e.preventDefault();
        setIsSidebarCollapsed((prev) => !prev);
      }
      if ((e.key === "c" || e.key === "C") && commentsEnabled) {
        e.preventDefault();
        setIsCommentsSidebarCollapsed((prev) => !prev);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [commentsEnabled]);

  const fileGroups: MonacoFileGroup[] = useMemo(
    () =>
      diffs.map((diff) => {
        const oldContent = diff.oldContent ?? "";
        const newContent = diff.newContent ?? "";
        const shouldMeasure =
          !diff.isBinary &&
          !diff.contentOmitted &&
          diff.status !== "deleted" &&
          diff.status !== "renamed";

        const editorMetrics = shouldMeasure
          ? computeEditorLayoutMetrics(oldContent, newContent)
          : null;

        return {
          filePath: diff.filePath,
          oldPath: diff.oldPath,
          status: diff.status,
          additions: diff.additions,
          deletions: diff.deletions,
          oldContent,
          newContent,
          patch: diff.patch,
          isBinary: diff.isBinary,
          contentOmitted: diff.contentOmitted ?? false,
          language: guessMonacoLanguage(diff.filePath),
          editorMetrics,
        };
      }),
    [diffs]
  );

  const expandAll = useCallback(() => {
    debugGitDiffViewerLog("expandAll invoked", {
      fileCount: fileGroups.length,
    });
    setExpandedFiles(new Set(fileGroups.map((f) => f.filePath)));
  }, [fileGroups]);

  const collapseAll = useCallback(() => {
    debugGitDiffViewerLog("collapseAll invoked", {
      fileCount: fileGroups.length,
    });
    setExpandedFiles(new Set());
  }, [fileGroups]);

  const toggleFile = useCallback(
    (filePath: string) => {
      setExpandedFiles((prev) => {
        const next = new Set(prev);
        const wasExpanded = next.has(filePath);
        if (wasExpanded) {
          next.delete(filePath);
        } else {
          next.add(filePath);
        }
        try {
          onFileToggle?.(filePath, !wasExpanded);
        } catch {
          // ignore
        }
        return next;
      });
    },
    [onFileToggle]
  );

  const handleToggleViewed = useCallback((filePath: string) => {
    setViewedFiles((prev) => {
      const next = new Set(prev);
      const wasViewed = next.has(filePath);
      if (wasViewed) {
        next.delete(filePath);
        // When un-viewing, expand the file
        setExpandedFiles((expanded) => {
          const updated = new Set(expanded);
          updated.add(filePath);
          return updated;
        });
      } else {
        next.add(filePath);
        // When marking as viewed, collapse the file
        setExpandedFiles((expanded) => {
          const updated = new Set(expanded);
          updated.delete(filePath);
          return updated;
        });
      }
      return next;
    });
  }, []);

  const handleSelectFile = useCallback((filePath: string) => {
    setActivePath(filePath);

    // Scroll to the file
    if (typeof window !== "undefined") {
      const element = document.getElementById(filePath);
      if (element) {
        element.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    }
  }, []);

  const totalAdditions = diffs.reduce((sum, diff) => sum + diff.additions, 0);
  const totalDeletions = diffs.reduce((sum, diff) => sum + diff.deletions, 0);

  const controlsHandlerRef = useRef<
    | ((args: {
        expandAll: () => void;
        collapseAll: () => void;
        totalAdditions: number;
        totalDeletions: number;
      }) => void)
    | null
  >(null);

  useEffect(() => {
    controlsHandlerRef.current = onControlsChange ?? null;
  }, [onControlsChange]);

  useEffect(() => {
    controlsHandlerRef.current?.({
      expandAll,
      collapseAll,
      totalAdditions,
      totalDeletions,
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [totalAdditions, totalDeletions, diffs.length]);

  const editorTheme = theme === "dark" ? "cmux-dark" : "cmux-light";

  const diffOptions = useMemo<editor.IDiffEditorConstructionOptions>(
    () => ({
      renderSideBySide: true,
      enableSplitViewResizing: true,
      automaticLayout: false,
      readOnly: true,
      originalEditable: false,
      lineHeight: DEFAULT_MONACO_LINE_HEIGHT,
      minimap: { enabled: false },
      renderOverviewRuler: false,
      wordWrap: "on",
      scrollBeyondLastLine: false,
      scrollbar: {
        vertical: "hidden",
        horizontal: "hidden",
        handleMouseWheel: false,
        alwaysConsumeMouseWheel: false,
      },
      hideUnchangedRegions: {
        enabled: true,
        ...HIDE_UNCHANGED_REGIONS_SETTINGS,
      },
    }),
    []
  );

  use(loaderInitPromise);

  const lineCommentsByFile = useMemo(() => {
    const map = new Map<string, DiffLineComment[]>();
    for (const comment of lineComments ?? []) {
      const existing = map.get(comment.filePath) ?? [];
      existing.push(comment);
      map.set(comment.filePath, existing);
    }
    for (const [, comments] of map) {
      comments.sort((a, b) => {
        if (a.lineNumber !== b.lineNumber) return a.lineNumber - b.lineNumber;
        const timeA = a.createdAt ?? 0;
        const timeB = b.createdAt ?? 0;
        return timeA - timeB;
      });
    }
    return map;
  }, [lineComments]);

  // Loading state - show skeleton
  if (isLoading) {
    return (
      <div className="grow flex flex-col bg-white dark:bg-neutral-900 min-h-0">
        {/* Header bar skeleton */}
        <div className="flex-shrink-0 flex items-center gap-2 px-2 py-1.5 border-b border-neutral-200/80 dark:border-neutral-800/70">
          <div className="flex items-center gap-1.5 px-2 py-1">
            <div className="w-4 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
            <div className="w-10 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
          </div>
          <div className="flex items-center gap-2">
            <div className="w-6 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
            <div className="w-6 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
          </div>
        </div>

        {/* Content area */}
        <div className="flex flex-1 min-h-0">
          {/* Sidebar skeleton */}
          <div className="w-[280px] h-full border-r border-neutral-200/80 dark:border-neutral-800/70">
            <div className="p-2">
              <div className="h-8 bg-neutral-100 dark:bg-neutral-800 rounded-md animate-pulse" />
            </div>
            <div className="space-y-0.5 px-2">
              {[1, 2, 3].map((i) => (
                <div key={i} className="flex items-center gap-2 px-2 py-1">
                  <div className="w-4 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
                  <div className="h-4 bg-neutral-100 dark:bg-neutral-800 rounded flex-1 animate-pulse" />
                </div>
              ))}
            </div>
          </div>
          {/* Content skeleton */}
          <div className="flex-1 min-w-0">
            <div className="flex flex-col">
              {[1, 2].map((i) => (
                <div key={i} className="border-b border-neutral-200/80 dark:border-neutral-800/70">
                  <div className="flex items-center gap-2 px-4 py-3">
                    <div className="w-4 h-4 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
                    <div className="h-4 w-48 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
                    <div className="ml-auto flex gap-2">
                      <div className="h-4 w-8 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
                      <div className="h-4 w-8 bg-neutral-100 dark:bg-neutral-800 rounded animate-pulse" />
                    </div>
                  </div>
                  <div className="h-32 bg-neutral-50 dark:bg-neutral-900/50 animate-pulse" />
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    );
  }

  // No diff detected - show header with empty state message
  if (diffs.length === 0) {
    return (
      <div className="grow flex flex-col bg-white dark:bg-neutral-900 min-h-0">
        {/* Header row - matching Description/Previews spacing */}
        <div className="px-2 py-1.5 flex items-center gap-2">
          <div className="flex items-center gap-1.5 px-2 py-0.5 text-[13px] font-medium text-neutral-600 dark:text-neutral-400">
            <PanelLeft className="w-3.5 h-3.5" />
            <span>Files</span>
          </div>
        </div>
        <div className="grow flex flex-col items-center justify-center px-3 pb-3">
          <p className="text-xs text-neutral-500 dark:text-neutral-400 py-1">
            No diff detected
          </p>
          <pre className="mt-2 select-none text-left text-[8px] font-mono text-neutral-500 dark:text-neutral-400">
            {kitty}
          </pre>
        </div>
      </div>
    );
  }

  // Has diffs - show full UI with sidebar
  return (
    <div className="grow flex flex-col bg-white dark:bg-neutral-900 min-h-0">
      {/* Header bar */}
      <div className="flex-shrink-0 flex items-center gap-2 px-2 py-1.5 border-b border-neutral-200/80 dark:border-neutral-800/70">
        <button
          type="button"
          onClick={() => setIsSidebarCollapsed(!isSidebarCollapsed)}
          className="flex items-center gap-1.5 px-2 py-0.5 rounded text-[13px] font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors"
          title={isSidebarCollapsed ? "Show files (F)" : "Hide files (F)"}
        >
          {isSidebarCollapsed ? (
            <PanelLeft className="w-3.5 h-3.5" />
          ) : (
            <PanelLeftClose className="w-3.5 h-3.5" />
          )}
          <span>Files</span>
        </button>
        <div className="flex items-center gap-2 text-[11px] font-medium">
          <span className="text-green-600 dark:text-green-400">+{totalAdditions}</span>
          <span className="text-red-600 dark:text-red-400">−{totalDeletions}</span>
        </div>
        <div className="flex items-center gap-2 ml-auto">
          {commentsEnabled && (
            <button
              type="button"
              onClick={() => setIsCommentsSidebarCollapsed(!isCommentsSidebarCollapsed)}
              className={cn(
                "flex items-center gap-1.5 text-[11px] font-medium transition-colors",
                isCommentsSidebarCollapsed
                  ? "text-neutral-500 dark:text-neutral-400"
                  : "text-blue-600 dark:text-blue-400"
              )}
              title={isCommentsSidebarCollapsed ? "Show comments (C)" : "Hide comments (C)"}
            >
              <MessageSquare className="w-3 h-3" />
              <span>Comments</span>
              {totalComments > 0 && (
                <span className={cn(
                  "px-1.5 py-0.5 text-[10px] font-medium rounded-full",
                  unresolvedComments > 0
                    ? "bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400"
                    : "bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400"
                )}>
                  {unresolvedComments > 0 ? unresolvedComments : totalComments}
                </span>
              )}
            </button>
          )}
          {onToggleHeatmap && (
            <button
              type="button"
              onClick={onToggleHeatmap}
              className="flex items-center gap-1.5 text-[11px] font-medium text-neutral-500 dark:text-neutral-400"
              title={isHeatmapActive ? "Switch to standard diff" : "Switch to heatmap diff"}
            >
              <Flame className="w-3 h-3" />
              <span>Diff Heatmap</span>
            </button>
          )}
        </div>
      </div>

      {/* Content area */}
      <div className="flex flex-1 min-h-0">
        {/* Sidebar */}
        {!isSidebarCollapsed && (
          <div className="flex-shrink-0 self-stretch border-r border-neutral-200/80 dark:border-neutral-800/70">
            <DiffSidebarFilter
              diffs={diffs}
              viewedFiles={viewedFiles}
              activePath={activePath}
              onSelectFile={handleSelectFile}
              onToggleViewed={handleToggleViewed}
              className="sticky top-[var(--cmux-diff-header-offset,0px)] h-[calc(100vh-var(--cmux-diff-header-offset,0px)-41px)]"
              commentCounts={commentsEnabled ? commentsContext?.fileCommentCounts : undefined}
            />
          </div>
        )}

        {/* Main content */}
        <div className="flex-1 min-w-0">
          <div className="flex flex-col">
            {fileGroups.map((file) => (
              <MemoMonacoFileDiffRow
                key={`monaco:${file.filePath}`}
                file={file}
                isExpanded={expandedFiles.has(file.filePath)}
                isViewed={viewedFiles.has(file.filePath)}
                onToggle={() => toggleFile(file.filePath)}
                onToggleViewed={() => handleToggleViewed(file.filePath)}
                editorTheme={editorTheme}
                diffOptions={diffOptions}
                classNames={classNames?.fileDiffRow}
                anchorId={file.filePath}
                currentUserId={currentUserId}
                commentsEnabled={commentsEnabled}
                onExpandFile={() => {
                  if (!expandedFiles.has(file.filePath)) {
                    toggleFile(file.filePath);
                  }
                }}
                fileLineComments={lineCommentsByFile.get(file.filePath) ?? []}
                onAddLineComment={onAddLineComment}
              />
            ))}
            <div className="px-3 py-6 text-center">
              <span className="select-none text-xs text-neutral-500 dark:text-neutral-400">
                You've reached the end of the diff!
              </span>
              <div className="grid place-content-center">
                <pre className="mt-2 pb-12 select-none text-left text-[8px] font-mono text-neutral-500 dark:text-neutral-400">
                  {kitty}
                </pre>
              </div>
            </div>
          </div>
        </div>

        {/* Comments sidebar */}
        {commentsEnabled && !isCommentsSidebarCollapsed && (
          <div className="flex-shrink-0 w-[320px] self-stretch border-l border-neutral-200/80 dark:border-neutral-800/70 bg-white dark:bg-neutral-900">
            <DiffCommentsSidebar
              currentUserId={currentUserId}
              className="sticky top-[var(--cmux-diff-header-offset,0px)] h-[calc(100vh-var(--cmux-diff-header-offset,0px)-41px)] overflow-y-auto"
              onNavigateToComment={(comment) => {
                // Navigate to the file and scroll to it
                const element = document.getElementById(comment.filePath);
                if (element) {
                  element.scrollIntoView({ behavior: "smooth", block: "start" });
                }
              }}
            />
          </div>
        )}
      </div>
    </div>
  );
}

// Public component that wraps the inner component with DiffCommentsProvider
export function MonacoGitDiffViewerWithSidebar(props: MonacoGitDiffViewerWithSidebarProps) {
  const { teamSlugOrId, taskRunId, currentUserId, ...rest } = props;

  // Only enable comments if we have both teamSlugOrId and taskRunId
  const commentsEnabled = Boolean(teamSlugOrId && taskRunId);

  if (commentsEnabled && teamSlugOrId && taskRunId) {
    return (
      <DiffCommentsProvider teamSlugOrId={teamSlugOrId} taskRunId={taskRunId}>
        <MonacoGitDiffViewerWithSidebarInner
          {...rest}
          teamSlugOrId={teamSlugOrId}
          taskRunId={taskRunId}
          currentUserId={currentUserId}
          commentsEnabled={commentsEnabled}
        />
      </DiffCommentsProvider>
    );
  }

  return (
    <MonacoGitDiffViewerWithSidebarInner
      {...rest}
      currentUserId={currentUserId}
      commentsEnabled={false}
    />
  );
}
