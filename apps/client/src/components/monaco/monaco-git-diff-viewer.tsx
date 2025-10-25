import { DiffEditor, type DiffOnMount } from "@monaco-editor/react";
import type { editor } from "monaco-editor";
import { memo, use, useEffect, useMemo, useRef, useState } from "react";

import { useTheme } from "@/components/theme/use-theme";
import { loaderInitPromise } from "@/lib/monaco-environment";
import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";

import { FileDiffHeader } from "../file-diff-header";
import { kitties } from "../kitties";
import type { GitDiffViewerProps } from "../codemirror-git-diff-viewer";
export type { GitDiffViewerProps } from "../codemirror-git-diff-viewer";

void loaderInitPromise;

type FileDiffRowClassNames = GitDiffViewerProps["classNames"] extends {
  fileDiffRow?: infer T;
}
  ? T
  : { button?: string; container?: string };

type DiffEditorControls = {
  updateCollapsedState: (collapsed: boolean) => void;
  updateTargetMinHeight: (minHeight: number) => void;
};

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

const DEFAULT_EDITOR_MIN_HEIGHT =
  MIN_EDITOR_LINE_FALLBACK * DEFAULT_MONACO_LINE_HEIGHT;

const newlinePattern = /\r?\n/;

function debugGitDiffViewerLog(
  message: string,
  payload?: Record<string, unknown>
) {
  if (!isElectron && import.meta.env.PROD) {
    return;
  }
  if (payload) {
    console.info("[monaco-git-diff-viewer]", message, payload);
  } else {
    console.info("[monaco-git-diff-viewer]", message);
  }
}

function splitContentIntoLines(content: string): string[] {
  if (!content) {
    return [""];
  }

  const parts = content.split(newlinePattern);
  return parts.length > 0 ? parts : [""];
}

type DiffSegmentType = "equal" | "insert" | "delete";

type DiffSegment = {
  type: DiffSegmentType;
  originalStart: number;
  originalEnd: number;
  modifiedStart: number;
  modifiedEnd: number;
};

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
        currentRow[modifiedIndex] = nextRow[modifiedIndex + 1] + 1;
      } else {
        currentRow[modifiedIndex] = Math.max(
          nextRow[modifiedIndex],
          currentRow[modifiedIndex + 1]
        );
      }
    }
  }

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
        dp[originalIndex + 1][modifiedIndex] >=
          dp[originalIndex][modifiedIndex + 1])
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
    const block = blocks[index];

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
}: {
  editorMinHeight: number;
  getVisibilityTarget?: () => Element | null;
  onReady?: (args: {
    diffEditor: editor.IStandaloneDiffEditor;
    container: HTMLElement;
    applyLayout: () => void;
    controls: DiffEditorControls;
  }) => void;
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
        return contentHeight;
      }

      const lineHeight = targetEditor.getOption(
        monacoInstance.editor.EditorOption.lineHeight
      );
      const model = targetEditor.getModel();
      const lineCount = model ? Math.max(1, model.getLineCount()) : 1;

      return lineCount * lineHeight;
    };

    container.style.minHeight = `${targetMinHeight}px`;

    const applyLayout = () => {
      const height = Math.max(
        computeHeight(originalEditor),
        computeHeight(modifiedEditor)
      );

      const modifiedInfo = modifiedEditor.getLayoutInfo();
      const originalInfo = originalEditor.getLayoutInfo();
      const containerWidth =
        container.clientWidth ||
        container.getBoundingClientRect().width ||
        modifiedInfo.width ||
        originalInfo.width;

      const enforcedHeight = Math.max(targetMinHeight, height);

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

    const applyTargetMinHeight = () => {
      if (collapsedState) {
        return;
      }
      container.style.minHeight = `${targetMinHeight}px`;
      container.style.height = "";
      container.style.overflow = "";
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

interface MonacoFileDiffRowProps {
  file: MonacoFileGroup;
  isExpanded: boolean;
  onToggle: () => void;
  editorTheme: string;
  diffOptions: editor.IDiffEditorConstructionOptions;
  classNames?: FileDiffRowClassNames;
}

function MonacoFileDiffRow({
  file,
  isExpanded,
  onToggle,
  editorTheme,
  diffOptions,
  classNames,
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

  useEffect(() => {
    isExpandedRef.current = isExpanded;
    diffControlsRef.current?.updateCollapsedState(!isExpanded);
  }, [isExpanded]);

  useEffect(() => {
    diffControlsRef.current?.updateTargetMinHeight(editorMinHeight);
  }, [editorMinHeight]);

  const onEditorMount = useMemo(
    () =>
      createDiffEditorMount({
        editorMinHeight,
        getVisibilityTarget: () => rowContainerRef.current,
        onReady: ({ controls }) => {
          diffControlsRef.current = controls;
          controls.updateTargetMinHeight(editorMinHeight);
          controls.updateCollapsedState(!isExpandedRef.current);
        },
      }),
    [editorMinHeight]
  );

  return (
    <div
      ref={rowContainerRef}
      className={cn("bg-white dark:bg-neutral-900", classNames?.container)}
    >
      <FileDiffHeader
        filePath={file.filePath}
        oldPath={file.oldPath}
        status={file.status}
        additions={file.additions}
        deletions={file.deletions}
        isExpanded={isExpanded}
        onToggle={onToggle}
        className={classNames?.button}
      />

      <div
        className="overflow-hidden border-b border-neutral-200 dark:border-neutral-800 flex flex-col"
        style={
          isExpanded
            ? { minHeight: editorMinHeight }
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
          <div className="relative" style={{ minHeight: editorMinHeight }}>
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
      </div>
    </div>
  );
}

const MemoMonacoFileDiffRow = memo(MonacoFileDiffRow, (prev, next) => {
  const a = prev.file;
  const b = next.file;
  return (
    prev.isExpanded === next.isExpanded &&
    prev.editorTheme === next.editorTheme &&
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

export function MonacoGitDiffViewer({
  diffs,
  onControlsChange,
  classNames,
  onFileToggle,
}: GitDiffViewerProps) {
  const { theme } = useTheme();

  const kitty = useMemo(() => {
    return kitties[Math.floor(Math.random() * kitties.length)];
  }, []);

  const [expandedFiles, setExpandedFiles] = useState<Set<string>>(
    () => new Set(diffs.map((diff) => diff.filePath))
  );

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

  const expandAll = () => {
    debugGitDiffViewerLog("expandAll invoked", {
      fileCount: fileGroups.length,
    });
    setExpandedFiles(new Set(fileGroups.map((f) => f.filePath)));
  };

  const collapseAll = () => {
    debugGitDiffViewerLog("collapseAll invoked", {
      fileCount: fileGroups.length,
    });
    setExpandedFiles(new Set());
  };

  const toggleFile = (filePath: string) => {
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
  };

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
    // Totals update when diffs change; avoid including function identities
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [totalAdditions, totalDeletions, diffs.length]);

  // const editorTheme = theme === "dark" ? "cmux-dark" : "cmux-light";
  const editorTheme = theme === "dark" ? "dark" : "light";

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

  return (
    <div className="grow bg-white dark:bg-neutral-900">
      <div className="flex flex-col -space-y-[2px]">
        {fileGroups.map((file, index) => (
          <MemoMonacoFileDiffRow
            key={`monaco:${file.filePath}`}
            file={file}
            isExpanded={expandedFiles.has(file.filePath)}
            onToggle={() => toggleFile(file.filePath)}
            editorTheme={editorTheme}
            diffOptions={diffOptions}
            classNames={{
              ...classNames?.fileDiffRow,
              button: cn(
                classNames?.fileDiffRow?.button,
                index === 0 && "!border-t-0"
              ),
            }}
          />
        ))}
        <hr className="border-neutral-200 dark:border-neutral-800" />
        <div className="px-3 py-6 text-center">
          <span className="select-none text-xs text-neutral-500 dark:text-neutral-400">
            You’ve reached the end of the diff!
          </span>
          <div className="grid place-content-center">
            <pre className="mt-2 pb-20 select-none text-left text-[8px] font-mono text-neutral-500 dark:text-neutral-400">
              {kitty}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
