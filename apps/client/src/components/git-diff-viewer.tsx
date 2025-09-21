import { useTheme } from "@/components/theme/use-theme";
// No socket usage in refs-only viewer
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { DiffEditor } from "@monaco-editor/react";
import {
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
} from "lucide-react";
import { type editor } from "monaco-editor";
import {
  memo,
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

type Disposable = { dispose: () => void };

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

  const [expandedFiles, setExpandedFiles] = useState<Set<string>>(new Set());
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

  // Maintain minimal reactivity; no debug logging in production
  useEffect(() => {
    // No-op effect to keep hook ordering consistent if needed later
  }, [diffs]);

  // Maintain expansion state across refreshes:
  // - On first load: expand all
  // - On subsequent diffs changes: preserve existing expansions, expand only truly new files
  //   (detected via previous file list, not by expansion set)
  const prevFilesRef = useRef<Set<string> | null>(null);
  useEffect(() => {
    const nextPathsArr = diffs.map((d) => d.filePath);
    const nextPaths = new Set(nextPathsArr);
    setExpandedFiles((prev) => {
      // First load: expand everything
      if (prevFilesRef.current == null) {
        return new Set(nextPaths);
      }
      const next = new Set<string>();
      // Keep expansions that still exist
      for (const p of prev) {
        if (nextPaths.has(p)) next.add(p);
      }
      // Expand only files not seen before (true additions)
      for (const p of nextPaths) {
        if (!prevFilesRef.current.has(p)) next.add(p);
      }
      return next;
    });
    // Update the seen file set after computing the next expansion state
    prevFilesRef.current = nextPaths;
  }, [diffs]);

  const toggleFile = (filePath: string) => {
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
  };

  const expandAll = () => {
    setExpandedFiles(new Set(fileGroups.map((f) => f.filePath)));
  };

  const collapseAll = () => {
    setExpandedFiles(new Set());
  };

  // No per-run cache in refs mode

  const calculateEditorHeight = (oldContent: string, newContent: string) => {
    const oldLines = oldContent.split("\n").length;
    const newLines = newContent.split("\n").length;
    const maxLines = Math.max(oldLines, newLines);
    // approximate using compact line height of 18px + small padding
    return Math.max(100, maxLines * 18 + 24);
  };

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
    // Totals update when diffs change; avoid including function identities
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [totalAdditions, totalDeletions, diffs.length]);

  return (
    <div className="grow bg-white dark:bg-neutral-900">
      {/* Diff sections */}
      <div className="">
        {fileGroups.map((file) => (
          <MemoFileDiffRow
            key={`refs:${file.filePath}`}
            file={file}
            isExpanded={expandedFiles.has(file.filePath)}
            onToggle={() => toggleFile(file.filePath)}
            theme={theme}
            calculateEditorHeight={calculateEditorHeight}
            setEditorRef={(ed) => {
              const key = `refs:${file.filePath}`;
              if (ed) {
                editorRefs.current[key] = ed;
              } else {
                delete editorRefs.current[key];
              }
            }}
            classNames={classNames?.fileDiffRow}
          />
        ))}
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
  const rafIdRef = useRef<number | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const revealedRef = useRef<boolean>(false);
  const editorCleanupRef = useRef<(() => void) | null>(null);

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
    if (!isExpanded && editorCleanupRef.current) {
      editorCleanupRef.current();
    }
  }, [isExpanded]);

  useEffect(() => {
    return () => {
      if (editorCleanupRef.current) {
        editorCleanupRef.current();
      }
    };
  }, []);

  return (
    <div className={cn("bg-white dark:bg-neutral-900", classNames?.container)}>
      <button
        onClick={onToggle}
        className={cn(
          "w-full px-3 py-1.5 flex items-center gap-2 hover:bg-neutral-50 dark:hover:bg-neutral-800/50 transition-colors text-left group pt-1 bg-white dark:bg-neutral-900 border-b border-neutral-200 dark:border-neutral-800 sticky  z-[var(--z-sticky-low)]",
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
              <DiffEditor
                key={`${runId ?? "_"}:${theme ?? "_"}:${file.filePath}`}
                original={file.oldContent}
                modified={file.newContent}
                language={getLanguageFromPath(file.filePath)}
                theme={theme === "dark" ? "vs-dark" : "vs"}
                onMount={(diffEditor, monaco) => {
                  if (editorCleanupRef.current) {
                    editorCleanupRef.current();
                  }
                  revealedRef.current = false;
                  setEditorRef(diffEditor);
                  const container = containerRef.current;
                  if (container) {
                    container.style.visibility = "hidden";
                  }

                  let disposed = false;
                  const disposables: Disposable[] = [];
                  const pushDisposable = (d: Disposable | undefined | null) => {
                    if (d) {
                      disposables.push(d);
                    }
                  };

                  const scheduleMeasureAndLayout = () => {
                    if (disposed) {
                      return;
                    }
                    if (rafIdRef.current != null) {
                      cancelAnimationFrame(rafIdRef.current);
                    }
                    rafIdRef.current = requestAnimationFrame(() => {
                      if (disposed) {
                        return;
                      }
                      const modifiedEditor = diffEditor.getModifiedEditor();
                      const originalEditor = diffEditor.getOriginalEditor();
                      const modifiedContentHeight =
                        modifiedEditor.getContentHeight();
                      const originalContentHeight =
                        originalEditor.getContentHeight();
                      const newHeight = Math.max(
                        120,
                        Math.max(modifiedContentHeight, originalContentHeight) +
                          20
                      );
                      const currentContainer = containerRef.current;
                      if (currentContainer) {
                        const current = parseInt(
                          currentContainer.style.height || "0",
                          10
                        );
                        if (current !== newHeight) {
                          currentContainer.style.height = `${newHeight}px`;
                        }
                        const width = currentContainer.clientWidth || undefined;
                        if (typeof width === "number") {
                          diffEditor.layout({ width, height: newHeight });
                          requestAnimationFrame(() => {
                            if (disposed) {
                              return;
                            }
                            diffEditor.layout({ width, height: newHeight });
                            if (!revealedRef.current) {
                              currentContainer.style.visibility = "visible";
                              revealedRef.current = true;
                            }
                          });
                        } else {
                          diffEditor.layout();
                          requestAnimationFrame(() => {
                            if (disposed) {
                              return;
                            }
                            diffEditor.layout();
                            const containerEl = containerRef.current;
                            if (containerEl && !revealedRef.current) {
                              containerEl.style.visibility = "visible";
                              revealedRef.current = true;
                            }
                          });
                        }
                      } else {
                        diffEditor.layout();
                        requestAnimationFrame(() => {
                          if (disposed) {
                            return;
                          }
                          diffEditor.layout();
                          const containerEl = containerRef.current;
                          if (containerEl && !revealedRef.current) {
                            containerEl.style.visibility = "visible";
                            revealedRef.current = true;
                          }
                        });
                      }
                    });
                  };

                  // Create fresh models per run+file to avoid reuse across runs
                  try {
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
                      file.oldContent,
                      language,
                      originalUri
                    );
                    const modifiedModel = monaco.editor.createModel(
                      file.newContent,
                      language,
                      modifiedUri
                    );
                    diffEditor.setModel({
                      original: originalModel,
                      modified: modifiedModel,
                    });
                  } catch {
                    // ignore if monaco not available
                  }

                  const mod = diffEditor.getModifiedEditor();
                  const orig = diffEditor.getOriginalEditor();
                  pushDisposable(
                    mod.onDidContentSizeChange(scheduleMeasureAndLayout)
                  );
                  pushDisposable(
                    orig.onDidContentSizeChange(scheduleMeasureAndLayout)
                  );
                  pushDisposable(
                    mod.onDidChangeHiddenAreas(scheduleMeasureAndLayout)
                  );
                  pushDisposable(
                    orig.onDidChangeHiddenAreas(scheduleMeasureAndLayout)
                  );
                  pushDisposable(
                    diffEditor.onDidUpdateDiff?.(scheduleMeasureAndLayout)
                  );

                  if (containerRef.current) {
                    if (resizeObserverRef.current) {
                      resizeObserverRef.current.disconnect();
                    }
                    resizeObserverRef.current = new ResizeObserver(() => {
                      if (!disposed) {
                        scheduleMeasureAndLayout();
                      }
                    });
                    resizeObserverRef.current.observe(containerRef.current);
                  }

                  requestAnimationFrame(() => {
                    if (!disposed) {
                      scheduleMeasureAndLayout();
                    }
                  });

                  const cleanup = () => {
                    if (disposed) {
                      return;
                    }
                    disposed = true;
                    setEditorRef(null);
                    for (const disposable of disposables) {
                      try {
                        disposable.dispose();
                      } catch {
                        // ignore
                      }
                    }
                    if (rafIdRef.current != null) {
                      cancelAnimationFrame(rafIdRef.current);
                      rafIdRef.current = null;
                    }
                    if (resizeObserverRef.current) {
                      resizeObserverRef.current.disconnect();
                      resizeObserverRef.current = null;
                    }
                    // Dispose models we created to avoid leaks and reuse
                    try {
                      const model = diffEditor.getModel();
                      model?.original?.dispose?.();
                      model?.modified?.dispose?.();
                    } catch {
                      // ignore if monaco not available
                    }
                    const containerEl = containerRef.current;
                    if (containerEl) {
                      containerEl.style.visibility = "";
                    }
                    revealedRef.current = false;
                    editorCleanupRef.current = null;
                  };

                  editorCleanupRef.current = cleanup;
                }}
                options={{
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
                }}
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
