import { useTheme } from "@/components/theme/use-theme";
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import {
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
} from "lucide-react";
import * as monaco from "monaco-editor";
import { type editor } from "monaco-editor";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { kitties } from "./kitties";

type FileDiffRowClassNames = {
  button?: string;
  container?: string;
};

type GitDiffViewerClassNames = {
  fileDiffRow?: FileDiffRowClassNames;
};

export interface GitDiffViewerProps {
  diffs: ReplaceDiffEntry[];
  onControlsChange?: (controls: {
    expandAll: () => void;
    collapseAll: () => void;
    totalAdditions: number;
    totalDeletions: number;
  }) => void;
  classNames?: GitDiffViewerClassNames;
  onFileToggle?: (filePath: string, isExpanded: boolean) => void;
}

type FileGroup = {
  filePath: string;
  oldPath?: string;
  status: ReplaceDiffEntry["status"];
  additions: number;
  deletions: number;
  oldContent: string;
  newContent: string;
  patch?: string;
  isBinary: boolean;
};

function getStatusColor(status: ReplaceDiffEntry["status"]) {
  switch (status) {
    case "added":
      return "text-green-600 dark:text-green-400";
    case "deleted":
      return "text-red-600 dark:text-red-400";
    case "modified":
      return "text-yellow-600 dark:text-yellow-400";
    case "renamed":
      return "text-blue-600 dark:text-blue-400";
    default:
      return "text-neutral-500";
  }
}

function getStatusIcon(status: ReplaceDiffEntry["status"]) {
  const iconClass = "w-3.5 h-3.5 flex-shrink-0";
  switch (status) {
    case "added":
      return <FilePlus className={iconClass} />;
    case "deleted":
      return <FileMinus className={iconClass} />;
    case "modified":
      return <FileEdit className={iconClass} />;
    case "renamed":
      return <FileCode className={iconClass} />;
    default:
      return <FileText className={iconClass} />;
  }
}

export function GitDiffViewer({
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
    new Set(diffs.map((d) => d.filePath))
  );
  const editorRefs = useRef<Record<string, editor.IStandaloneDiffEditor>>({});

  // Group diffs by file
  const fileGroups: FileGroup[] = useMemo(
    () =>
      (diffs || []).map((diff) => ({
        filePath: diff.filePath,
        oldPath: diff.oldPath,
        status: diff.status,
        additions: diff.additions,
        deletions: diff.deletions,
        oldContent: diff.oldContent || "",
        newContent: diff.newContent || "",
        patch: diff.patch,
        isBinary: diff.isBinary,
      })),
    [diffs]
  );

  const toggleFile = useCallback(
    (filePath: string) => {
      setExpandedFiles((prev) => {
        const newExpanded = new Set(prev);
        const wasExpanded = newExpanded.has(filePath);
        if (wasExpanded) newExpanded.delete(filePath);
        else newExpanded.add(filePath);
        try {
          onFileToggle?.(filePath, !wasExpanded);
        } catch {
          // ignore
        }
        return newExpanded;
      });
    },
    [onFileToggle]
  );

  const expandAll = useCallback(() => {
    setExpandedFiles(new Set(fileGroups.map((f) => f.filePath)));
  }, [fileGroups]);

  const collapseAll = useCallback(() => {
    setExpandedFiles(new Set());
  }, []);

  // No per-run cache in refs mode

  const calculateEditorHeight = useCallback(
    (oldContent: string, newContent: string) => {
      const oldLines = oldContent.split("\n").length;
      const newLines = newContent.split("\n").length;
      const maxLines = Math.max(oldLines, newLines);
      // approximate using compact line height of 18px + small padding
      return Math.max(100, maxLines * 18 + 24);
    },
    []
  );

  // Compute totals consistently before any conditional early-returns
  const totalAdditions = diffs.reduce((sum, d) => sum + d.additions, 0);
  const totalDeletions = diffs.reduce((sum, d) => sum + d.deletions, 0);

  // Keep a stable ref to the controls handler to avoid effect loops
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
  }, [collapseAll, expandAll, totalAdditions, totalDeletions, diffs.length]);

  const diffRowProps = useMemo(
    () =>
      fileGroups.map((file) => {
        const diffKey = `refs:${file.filePath}`;
        return {
          file,
          diffKey,
          onToggle: () => toggleFile(file.filePath),
          setEditorRef: (ed: editor.IStandaloneDiffEditor | null) => {
            if (ed) {
              editorRefs.current[diffKey] = ed;
            } else {
              delete editorRefs.current[diffKey];
            }
          },
        };
      }),
    [editorRefs, fileGroups, toggleFile]
  );

  return (
    <div className="grow bg-white dark:bg-neutral-900">
      {/* Diff sections */}
      <div className="">
        {diffRowProps.map(({ file, diffKey, onToggle, setEditorRef }) => (
          <MemoFileDiffRow
            key={diffKey}
            file={file}
            isExpanded={expandedFiles.has(file.filePath)}
            onToggle={onToggle}
            theme={theme}
            calculateEditorHeight={calculateEditorHeight}
            setEditorRef={setEditorRef}
            classNames={classNames?.fileDiffRow}
          />
        ))}
        <hr className="border-neutral-200 dark:border-neutral-800" />
        {/* End-of-diff message */}
        <div className="px-3 py-6 text-center">
          <span className="text-xs text-neutral-500 dark:text-neutral-400 select-none">
            You’ve reached the end of the diff!
          </span>
          <div className="grid place-content-center">
            <pre className="text-[8px] text-left text-neutral-500 dark:text-neutral-400 select-none mt-2 pb-20 font-mono">
              {kitty}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}

interface FileDiffRowProps {
  file: FileGroup;
  isExpanded: boolean;
  onToggle: () => void;
  theme: string | undefined;
  calculateEditorHeight: (oldContent: string, newContent: string) => number;
  setEditorRef: (ed: editor.IStandaloneDiffEditor | null) => void;
  runId?: string;
  classNames?: {
    button?: string;
    container?: string;
  };
}

function FileDiffRow({
  file,
  isExpanded,
  onToggle,
  theme,
  calculateEditorHeight,
  setEditorRef,
  runId,
  classNames,
}: FileDiffRowProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const diffContainerRef = useRef<HTMLDivElement | null>(null);
  const diffEditorRef = useRef<editor.IStandaloneDiffEditor | null>(null);
  const rafIdRef = useRef<number | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const modelsRef = useRef<{
    original: editor.ITextModel;
    modified: editor.ITextModel;
  } | null>(null);
  const layoutSchedulerRef = useRef<(() => void) | null>(null);
  const themeRef = useRef(theme);
  const revealedRef = useRef<boolean>(false);

  const diffEditorOptions =
    useMemo<monaco.editor.IStandaloneDiffEditorConstructionOptions>(
      () => ({
        readOnly: true,
        renderSideBySide: true,
        minimap: { enabled: false },
        scrollBeyondLastLine: false,
        fontSize: 12,
        lineHeight: 18,
        fontFamily:
          "'JetBrains Mono', 'SF Mono', Monaco, 'Courier New', monospace",
        wordWrap: "on",
        automaticLayout: false,
        renderOverviewRuler: false,
        scrollbar: {
          vertical: "hidden",
          horizontal: "auto",
          verticalScrollbarSize: 8,
          horizontalScrollbarSize: 8,
          handleMouseWheel: true,
          alwaysConsumeMouseWheel: false,
        },
        lineNumbers: "on",
        renderLineHighlight: "none",
        hideCursorInOverviewRuler: true,
        overviewRulerBorder: false,
        overviewRulerLanes: 0,
        renderValidationDecorations: "off",
        diffWordWrap: "on",
        renderIndicators: true,
        renderMarginRevertIcon: false,
        lineDecorationsWidth: 12,
        lineNumbersMinChars: 4,
        glyphMargin: false,
        folding: false,
        contextmenu: false,
        renderWhitespace: "selection",
        guides: {
          indentation: false,
        },
        padding: { top: 2, bottom: 2 },
        hideUnchangedRegions: {
          enabled: true,
          revealLineCount: 3,
          minimumLineCount: 50,
          contextLineCount: 3,
        },
      }),
      []
    );

  const modelSeedRef = useRef({
    old: file.oldContent,
    modified: file.newContent,
  });
  const modelSeedKeyRef = useRef<string | null>(null);
  const modelSeedKey = `${runId ?? "_"}:${file.filePath}`;
  if (modelSeedKeyRef.current !== modelSeedKey) {
    modelSeedKeyRef.current = modelSeedKey;
    modelSeedRef.current = {
      old: file.oldContent,
      modified: file.newContent,
    };
  }

  // Set an initial height before paint to reduce flicker
  useLayoutEffect(() => {
    const initial = calculateEditorHeight(file.oldContent, file.newContent);
    if (containerRef.current) {
      containerRef.current.style.height = `${Math.max(120, initial)}px`;
    }
    // Only depend on file contents used for initial sizing
  }, [file.oldContent, file.newContent, calculateEditorHeight]);

  // No debug logs in production
  useEffect(() => {
    // noop
  }, [isExpanded, file.filePath]);

  useEffect(() => {
    themeRef.current = theme;
    if (!diffEditorRef.current) {
      return;
    }
    const themeName = theme === "dark" ? "vs-dark" : "vs";
    monaco.editor.setTheme(themeName);
    layoutSchedulerRef.current?.();
  }, [theme]);

  useEffect(() => {
    if (!isExpanded) {
      return;
    }

    const container = diffContainerRef.current;
    if (!container) {
      return;
    }

    if (typeof window === "undefined") {
      return;
    }

    if (containerRef.current) {
      containerRef.current.style.visibility = "hidden";
    }
    revealedRef.current = false;

    const diffEditor = monaco.editor.createDiffEditor(
      container,
      diffEditorOptions
    );
    diffEditorRef.current = diffEditor;
    setEditorRef(diffEditor);

    const language = getLanguageFromPath(file.filePath);
    const originalUri = monaco.Uri.parse(
      `inmemory://diff/${runId ?? "_"}/${encodeURIComponent(
        file.filePath
      )}?side=original`
    );
    const modifiedUri = monaco.Uri.parse(
      `inmemory://diff/${runId ?? "_"}/${encodeURIComponent(
        file.filePath
      )}?side=modified`
    );

    const originalModel = monaco.editor.createModel(
      modelSeedRef.current.old,
      language,
      originalUri
    );
    const modifiedModel = monaco.editor.createModel(
      modelSeedRef.current.modified,
      language,
      modifiedUri
    );
    diffEditor.setModel({
      original: originalModel,
      modified: modifiedModel,
    });
    modelsRef.current = {
      original: originalModel,
      modified: modifiedModel,
    };

    const scheduleMeasureAndLayout = () => {
      if (rafIdRef.current != null) {
        cancelAnimationFrame(rafIdRef.current);
      }
      rafIdRef.current = requestAnimationFrame(() => {
        const instance = diffEditorRef.current;
        if (!instance) {
          return;
        }
        const modifiedEditor = instance.getModifiedEditor();
        const originalEditor = instance.getOriginalEditor();
        const modifiedContentHeight = modifiedEditor.getContentHeight();
        const originalContentHeight = originalEditor.getContentHeight();
        const newHeight = Math.max(
          120,
          Math.max(modifiedContentHeight, originalContentHeight) + 20
        );
        if (containerRef.current) {
          const currentHeight = parseInt(
            containerRef.current.style.height || "0",
            10
          );
          if (currentHeight !== newHeight) {
            containerRef.current.style.height = `${newHeight}px`;
          }
          const width = containerRef.current.clientWidth || undefined;
          if (typeof width === "number") {
            instance.layout({ width, height: newHeight });
            requestAnimationFrame(() => {
              instance.layout({ width, height: newHeight });
              if (containerRef.current && !revealedRef.current) {
                containerRef.current.style.visibility = "visible";
                revealedRef.current = true;
              }
            });
          } else {
            instance.layout();
            requestAnimationFrame(() => {
              instance.layout();
              if (containerRef.current && !revealedRef.current) {
                containerRef.current.style.visibility = "visible";
                revealedRef.current = true;
              }
            });
          }
        } else {
          instance.layout();
          requestAnimationFrame(() => {
            instance.layout();
            if (containerRef.current && !revealedRef.current) {
              containerRef.current.style.visibility = "visible";
              revealedRef.current = true;
            }
          });
        }
      });
    };

    layoutSchedulerRef.current = scheduleMeasureAndLayout;

    const modifiedEditor = diffEditor.getModifiedEditor();
    const originalEditor = diffEditor.getOriginalEditor();
    const disposables: monaco.IDisposable[] = [
      modifiedEditor.onDidContentSizeChange(scheduleMeasureAndLayout),
      originalEditor.onDidContentSizeChange(scheduleMeasureAndLayout),
      modifiedEditor.onDidChangeHiddenAreas(scheduleMeasureAndLayout),
      originalEditor.onDidChangeHiddenAreas(scheduleMeasureAndLayout),
    ];
    const updateDiffDisposable = diffEditor.onDidUpdateDiff?.(
      scheduleMeasureAndLayout
    );
    if (updateDiffDisposable) {
      disposables.push(updateDiffDisposable);
    }

    if (typeof ResizeObserver !== "undefined" && containerRef.current) {
      if (resizeObserverRef.current) {
        resizeObserverRef.current.disconnect();
      }
      const observer = new ResizeObserver(() => {
        scheduleMeasureAndLayout();
      });
      resizeObserverRef.current = observer;
      observer.observe(containerRef.current);
    }

    const rafHandle = requestAnimationFrame(() => {
      scheduleMeasureAndLayout();
    });

    const currentTheme = themeRef.current === "dark" ? "vs-dark" : "vs";
    monaco.editor.setTheme(currentTheme);

    return () => {
      try {
        layoutSchedulerRef.current = null;
        for (const disposable of disposables) {
          disposable.dispose();
        }
        if (rafIdRef.current != null) {
          cancelAnimationFrame(rafIdRef.current);
          rafIdRef.current = null;
        }
        cancelAnimationFrame(rafHandle);
        if (resizeObserverRef.current) {
          resizeObserverRef.current.disconnect();
          resizeObserverRef.current = null;
        }
        try {
          diffEditor.setModel(null);
        } catch {
          // ignore
        }
        if (modelsRef.current) {
          modelsRef.current.original.dispose();
          modelsRef.current.modified.dispose();
          modelsRef.current = null;
        }
        diffEditor.dispose();
        if (diffEditorRef.current === diffEditor) {
          diffEditorRef.current = null;
        }
        setEditorRef(null);
        revealedRef.current = false;
      } catch (error) {
        console.error("Error disposing diff editor", error);
      }
    };
  }, [diffEditorOptions, file.filePath, isExpanded, runId, setEditorRef]);

  useEffect(() => {
    const instance = diffEditorRef.current;
    if (!instance) {
      return;
    }
    const models = instance.getModel();
    if (!models?.original || !models.modified) {
      return;
    }
    const language = getLanguageFromPath(file.filePath);
    if (models.original.getLanguageId() !== language) {
      monaco.editor.setModelLanguage(models.original, language);
    }
    if (models.modified.getLanguageId() !== language) {
      monaco.editor.setModelLanguage(models.modified, language);
    }
    if (models.original.getValue() !== file.oldContent) {
      models.original.setValue(file.oldContent);
    }
    if (models.modified.getValue() !== file.newContent) {
      models.modified.setValue(file.newContent);
    }
    layoutSchedulerRef.current?.();
  }, [file.filePath, file.newContent, file.oldContent]);

  return (
    <div className={cn("bg-white dark:bg-neutral-900", classNames?.container)}>
      <button
        onClick={onToggle}
        className={cn(
          "w-full px-3 py-1.5 flex items-center gap-2 hover:bg-neutral-50 dark:hover:bg-neutral-800/50 transition-colors text-left group pt-1 bg-white dark:bg-neutral-900 border-t border-neutral-200 dark:border-neutral-800 sticky z-[var(--z-sticky-low)]",
          classNames?.button
        )}
      >
        <div className="text-neutral-400 dark:text-neutral-500 group-hover:text-neutral-600 dark:group-hover:text-neutral-400">
          {isExpanded ? (
            <ChevronDown className="w-3.5 h-3.5" />
          ) : (
            <ChevronRight className="w-3.5 h-3.5" />
          )}
        </div>
        <div className={cn("flex-shrink-0", getStatusColor(file.status))}>
          {getStatusIcon(file.status)}
        </div>
        <div className="flex-1 min-w-0 flex items-start justify-between gap-3">
          <div className="min-w-0 flex flex-col">
            <span className="font-mono text-xs text-neutral-700 dark:text-neutral-300 truncate select-none">
              {file.filePath}
            </span>
            {file.status === "renamed" && file.oldPath ? (
              <span className="font-mono text-[10px] text-neutral-500 dark:text-neutral-400 truncate select-none">
                Renamed from {file.oldPath}
              </span>
            ) : null}
          </div>
          <div className="flex items-center gap-2 text-[11px]">
            <span className="text-green-600 dark:text-green-400 font-medium select-none">
              +{file.additions}
            </span>
            <span className="text-red-600 dark:text-red-400 font-medium select-none">
              −{file.deletions}
            </span>
          </div>
        </div>
      </button>

      {isExpanded && (
        <div className="border-t border-neutral-200 dark:border-neutral-800 overflow-hidden">
          {file.status === "renamed" ? (
            <div className="px-3 py-6 text-center text-neutral-500 dark:text-neutral-400 text-xs bg-neutral-50 dark:bg-neutral-900/50 space-y-2">
              <p className="select-none">File was renamed.</p>
              {file.oldPath ? (
                <p className="font-mono text-[11px] text-neutral-600 dark:text-neutral-300 select-none">
                  {file.oldPath} → {file.filePath}
                </p>
              ) : null}
            </div>
          ) : file.isBinary ? (
            <div className="px-3 py-6 text-center text-neutral-500 dark:text-neutral-400 text-xs bg-neutral-50 dark:bg-neutral-900/50">
              Binary file not shown
            </div>
          ) : file.status === "deleted" ? (
            <div className="px-3 py-6 text-center text-neutral-500 dark:text-neutral-400 text-xs bg-neutral-50 dark:bg-neutral-900/50">
              File was deleted
            </div>
          ) : (
            <div ref={containerRef}>
              <div
                ref={diffContainerRef}
                className="relative w-full h-full"
                data-testid="git-diff-viewer-monaco-container"
              />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

const MemoFileDiffRow = memo(FileDiffRow, (prev, next) => {
  const a = prev.file;
  const b = next.file;
  return (
    prev.isExpanded === next.isExpanded &&
    prev.theme === next.theme &&
    a.filePath === b.filePath &&
    a.oldPath === b.oldPath &&
    a.status === b.status &&
    a.additions === b.additions &&
    a.deletions === b.deletions &&
    a.isBinary === b.isBinary &&
    (a.patch || "") === (b.patch || "") &&
    a.oldContent === b.oldContent &&
    a.newContent === b.newContent
  );
});

function getLanguageFromPath(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase();
  const languageMap: Record<string, string> = {
    ts: "typescript",
    tsx: "typescript",
    js: "javascript",
    jsx: "javascript",
    json: "json",
    md: "markdown",
    css: "css",
    scss: "scss",
    html: "html",
    xml: "xml",
    yaml: "yaml",
    yml: "yaml",
    py: "python",
    go: "go",
    rs: "rust",
    java: "java",
    c: "c",
    cpp: "cpp",
    cs: "csharp",
    php: "php",
    rb: "ruby",
    swift: "swift",
    kt: "kotlin",
    scala: "scala",
    sh: "shell",
    bash: "shell",
    sql: "sql",
    dockerfile: "dockerfile",
  };

  return languageMap[ext || ""] || "plaintext";
}
