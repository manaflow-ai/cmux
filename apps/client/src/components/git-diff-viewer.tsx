import { useTheme } from "@/components/theme/use-theme";
import {
  useGitViewerPreference,
  type GitViewerPreference,
} from "@/contexts/git-viewer-preference";
// No socket usage in refs-only viewer
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { DiffEditor } from "@monaco-editor/react";
import { EditorState, type Extension } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  lineNumbers,
} from "@codemirror/view";
import {
  StreamLanguage,
  defaultHighlightStyle,
  syntaxHighlighting,
} from "@codemirror/language";
import { MergeView } from "@codemirror/merge";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { css } from "@codemirror/lang-css";
import { html } from "@codemirror/lang-html";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { python } from "@codemirror/lang-python";
import { go as goLang } from "@codemirror/lang-go";
import { rust } from "@codemirror/lang-rust";
import { java as javaLang } from "@codemirror/lang-java";
import { php as phpLang } from "@codemirror/lang-php";
import { sql } from "@codemirror/lang-sql";
import {
  cpp as cppMode,
  csharp as csharpLang,
  kotlin as kotlinLang,
  scala as scalaLang,
} from "@codemirror/legacy-modes/mode/clike";
import { swift as swiftLang } from "@codemirror/legacy-modes/mode/swift";
import { ruby as rubyLang } from "@codemirror/legacy-modes/mode/ruby";
import { shell as shellLang } from "@codemirror/legacy-modes/mode/shell";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { toml as tomlLang } from "@codemirror/legacy-modes/mode/toml";
import { properties as propertiesLang } from "@codemirror/legacy-modes/mode/properties";
import { sass as sassMode } from "@codemirror/legacy-modes/mode/sass";
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
  type MutableRefObject,
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
  const { viewer: diffViewerPreference } = useGitViewerPreference();

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
              if (ed)
                editorRefs.current[`refs:${file.filePath}`] = ed;
            }}
            classNames={classNames?.fileDiffRow}
            viewerPreference={diffViewerPreference}
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
  setEditorRef: (ed: editor.IStandaloneDiffEditor) => void;
  runId?: string;
  classNames?: {
    button?: string;
    container?: string;
  };
  viewerPreference: GitViewerPreference;
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
  viewerPreference,
}: FileDiffRowProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const rafIdRef = useRef<number | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const revealedRef = useRef<boolean>(false);

  // Set an initial height before paint to reduce flicker
  useLayoutEffect(() => {
    const initial = calculateEditorHeight(file.oldContent, file.newContent);
    if (containerRef.current) {
      containerRef.current.style.height = `${Math.max(120, initial)}px`;
      containerRef.current.style.visibility = "hidden";
    }
    revealedRef.current = false;
    // Only depend on file contents used for initial sizing
  }, [
    file.oldContent,
    file.newContent,
    calculateEditorHeight,
    viewerPreference,
  ]);

  // No debug logs in production
  useEffect(() => {
    // noop
  }, [isExpanded, file.filePath]);

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
            <div ref={containerRef} className="relative">
              {viewerPreference === "monaco" ? (
                <DiffEditor
                  key={`${runId ?? "_"}:${theme ?? "_"}:${file.filePath}`}
                  original={file.oldContent}
                  modified={file.newContent}
                  language={getLanguageFromPath(file.filePath)}
                  theme={theme === "dark" ? "vs-dark" : "vs"}
                  onMount={(editor, monaco) => {
                    setEditorRef(editor);
                    // Start hidden to avoid intermediate flashes
                    if (containerRef.current) {
                      containerRef.current.style.visibility = "hidden";
                    }

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
                      editor.setModel({
                        original: originalModel,
                        modified: modifiedModel,
                      });
                    } catch {
                      // ignore if monaco not available
                    }
                    const scheduleMeasureAndLayout = () => {
                      if (rafIdRef.current != null) {
                        cancelAnimationFrame(rafIdRef.current);
                      }
                      rafIdRef.current = requestAnimationFrame(() => {
                        const modifiedEditor = editor.getModifiedEditor();
                        const originalEditor = editor.getOriginalEditor();
                        const modifiedContentHeight =
                          modifiedEditor.getContentHeight();
                        const originalContentHeight =
                          originalEditor.getContentHeight();
                        const newHeight = Math.max(
                          120,
                          Math.max(modifiedContentHeight, originalContentHeight) +
                            20
                        );
                        if (containerRef.current) {
                          const current = parseInt(
                            containerRef.current.style.height || "0",
                            10
                          );
                          if (current !== newHeight) {
                            containerRef.current.style.height = `${newHeight}px`;
                          }
                          const width =
                            containerRef.current.clientWidth || undefined;
                          if (typeof width === "number") {
                            editor.layout({ width, height: newHeight });
                            // Double-rAF to ensure Monaco settles after DOM style changes
                            requestAnimationFrame(() => {
                              editor.layout({ width, height: newHeight });
                              if (containerRef.current && !revealedRef.current) {
                                containerRef.current.style.visibility = "visible";
                                revealedRef.current = true;
                              }
                            });
                          } else {
                            editor.layout();
                            requestAnimationFrame(() => {
                              editor.layout();
                              if (containerRef.current && !revealedRef.current) {
                                containerRef.current.style.visibility = "visible";
                                revealedRef.current = true;
                              }
                            });
                          }
                        } else {
                          editor.layout();
                          requestAnimationFrame(() => {
                            editor.layout();
                            if (containerRef.current && !revealedRef.current) {
                              containerRef.current.style.visibility = "visible";
                              revealedRef.current = true;
                            }
                          });
                        }
                      });
                    };
                    const mod = editor.getModifiedEditor();
                    const orig = editor.getOriginalEditor();
                    const d1 = mod.onDidContentSizeChange(
                      scheduleMeasureAndLayout
                    );
                    const d2 = orig.onDidContentSizeChange(
                      scheduleMeasureAndLayout
                    );
                    const d3 = mod.onDidChangeHiddenAreas(
                      scheduleMeasureAndLayout
                    );
                    const d4 = orig.onDidChangeHiddenAreas(
                      scheduleMeasureAndLayout
                    );
                    const d5 = editor.onDidUpdateDiff?.(scheduleMeasureAndLayout);

                    // Observe container size changes to trigger layout
                    if (containerRef.current && !resizeObserverRef.current) {
                      resizeObserverRef.current = new ResizeObserver(() => {
                        scheduleMeasureAndLayout();
                      });
                      resizeObserverRef.current.observe(containerRef.current);
                    }

                    // Kick initial layout after mount using rAF
                    requestAnimationFrame(() => {
                      scheduleMeasureAndLayout();
                    });
                    return () => {
                      d1.dispose();
                      d2.dispose();
                      d3.dispose();
                      d4.dispose();
                      d5?.dispose?.();
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
                        const model = editor.getModel();
                        if (model?.original) {
                          model.original.dispose?.();
                        }
                        if (model?.modified) {
                          model.modified.dispose?.();
                        }
                      } catch (_e) {
                        // ignore if monaco not available
                      }
                    };
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
              ) : (
                <CodeMirrorDiff
                  key={`${runId ?? "_"}:${theme ?? "_"}:${file.filePath}:cm`}
                  containerRef={containerRef}
                  file={file}
                  theme={theme}
                  calculateEditorHeight={calculateEditorHeight}
                />
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

interface CodeMirrorDiffProps {
  containerRef: MutableRefObject<HTMLDivElement | null>;
  file: FileGroup;
  theme: string | undefined;
  calculateEditorHeight: (oldContent: string, newContent: string) => number;
}

function CodeMirrorDiff({
  containerRef,
  file,
  theme,
  calculateEditorHeight,
}: CodeMirrorDiffProps) {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const mergeViewRef = useRef<MergeView | null>(null);
  const rafIdRef = useRef<number | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const revealedRef = useRef(false);

  const languageId = useMemo(
    () => getLanguageFromPath(file.filePath),
    [file.filePath]
  );

  useEffect(() => {
    const mountEl = mountRef.current;
    const containerEl = containerRef.current;
    if (!mountEl || !containerEl) {
      return;
    }

    mountEl.innerHTML = "";
    mountEl.className = "absolute inset-0";
    containerEl.style.visibility = "hidden";
    const fallbackHeight = Math.max(
      120,
      calculateEditorHeight(file.oldContent, file.newContent)
    );

    const scheduleMeasure = () => {
      if (rafIdRef.current != null) {
        cancelAnimationFrame(rafIdRef.current);
      }
      rafIdRef.current = requestAnimationFrame(() => {
        const cmView = mergeViewRef.current;
        const container = containerEl;
        if (!cmView || !container) {
          return;
        }

        const leftHeight = cmView.a?.contentHeight ?? 0;
        const rightHeight = cmView.b?.contentHeight ?? 0;
        const measuredHeight = Math.max(leftHeight, rightHeight);
        const newHeight =
          measuredHeight > 0
            ? Math.max(120, measuredHeight + 20)
            : fallbackHeight;
        const current = parseInt(container.style.height || "0", 10);
        if (!Number.isNaN(newHeight) && current !== newHeight) {
          container.style.height = `${newHeight}px`;
        }
        cmView.dom.style.height = "100%";
        cmView.dom.style.width = "100%";
        if (cmView.a) {
          cmView.a.dom.style.height = "100%";
        }
        if (cmView.b) {
          cmView.b.dom.style.height = "100%";
        }
        if (!revealedRef.current && container) {
          container.style.visibility = "visible";
          revealedRef.current = true;
        }
      });
    };

    const baseExtensions: Extension[] = [
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      EditorView.lineWrapping,
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      drawSelection({ cursorBlinkRate: 0 }),
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      createCodeMirrorTheme(theme === "dark"),
      EditorView.updateListener.of((update) => {
        if (update.docChanged || update.viewportChanged) {
          scheduleMeasure();
        }
      }),
    ];

    const languageExtensions = getCodeMirrorLanguageExtensions(
      file.filePath,
      languageId
    );

    const extensions = [...baseExtensions, ...languageExtensions];

    const view = new MergeView({
      a: {
        doc: file.oldContent,
        extensions,
      },
      b: {
        doc: file.newContent,
        extensions,
      },
      parent: mountEl,
      highlightChanges: true,
      gutter: true,
      orientation: "a-b",
      collapseUnchanged: {
        margin: 3,
        minSize: 40,
      },
    });

    mergeViewRef.current = view;
    revealedRef.current = false;
    scheduleMeasure();
    requestAnimationFrame(() => {
      scheduleMeasure();
    });

    const observer = new ResizeObserver(() => {
      scheduleMeasure();
    });
    observer.observe(containerEl);
    resizeObserverRef.current = observer;

    return () => {
      if (rafIdRef.current != null) {
        cancelAnimationFrame(rafIdRef.current);
        rafIdRef.current = null;
      }
      if (resizeObserverRef.current) {
        resizeObserverRef.current.disconnect();
        resizeObserverRef.current = null;
      }
      mergeViewRef.current?.destroy();
      mergeViewRef.current = null;
      revealedRef.current = false;
      mountEl.innerHTML = "";
      if (containerEl) {
        containerEl.style.visibility = "hidden";
      }
    };
  }, [
    calculateEditorHeight,
    containerRef,
    file.filePath,
    file.newContent,
    file.oldContent,
    languageId,
    theme,
  ]);

  return <div ref={mountRef} className="absolute inset-0" />;
}

const MemoFileDiffRow = memo(FileDiffRow, (prev, next) => {
  const a = prev.file;
  const b = next.file;
  return (
    prev.isExpanded === next.isExpanded &&
    prev.theme === next.theme &&
    prev.viewerPreference === next.viewerPreference &&
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
    mts: "typescript",
    cts: "typescript",
    js: "javascript",
    jsx: "javascript",
    mjs: "javascript",
    cjs: "javascript",
    json: "json",
    md: "markdown",
    mdx: "markdown",
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
    h: "cpp",
    hh: "cpp",
    hpp: "cpp",
    hxx: "cpp",
    cxx: "cpp",
    cpp: "cpp",
    cs: "csharp",
    php: "php",
    rb: "ruby",
    swift: "swift",
    kt: "kotlin",
    scala: "scala",
    sh: "shell",
    bash: "shell",
    zsh: "shell",
    fish: "shell",
    sql: "sql",
    dockerfile: "dockerfile",
    toml: "toml",
    ini: "ini",
    conf: "ini",
    env: "ini",
    properties: "ini",
    vue: "html",
    svelte: "html",
    astro: "html",
    txt: "plaintext",
    log: "plaintext",
    makefile: "shell",
    prisma: "sql",
  };

  return languageMap[ext || ""] || "plaintext";
}

const CODEMIRROR_FONT_FAMILY =
  "'JetBrains Mono', 'SF Mono', Monaco, 'Courier New', monospace";

function getCodeMirrorLanguageExtensions(
  filePath: string,
  languageId: string
): Extension[] {
  const ext = filePath.split(".").pop()?.toLowerCase() ?? "";
  switch (languageId) {
    case "typescript":
      return [javascript({ jsx: ext === "tsx", typescript: true })];
    case "javascript":
      return [javascript({ jsx: ext === "jsx" || ext === "tsx" })];
    case "json":
      return [json()];
    case "markdown":
      return [markdown()];
    case "css":
      return [css()];
    case "scss":
      return [StreamLanguage.define(sassMode)];
    case "html":
      return [html()];
    case "xml":
      return [xml()];
    case "yaml":
      return [yaml()];
    case "python":
      return [python()];
    case "go":
      return [goLang()];
    case "rust":
      return [rust()];
    case "java":
      return [javaLang()];
    case "c":
    case "cpp":
      return [StreamLanguage.define(cppMode)];
    case "csharp":
      return [StreamLanguage.define(csharpLang)];
    case "php":
      return [phpLang()];
    case "ruby":
      return [StreamLanguage.define(rubyLang)];
    case "swift":
      return [StreamLanguage.define(swiftLang)];
    case "kotlin":
      return [StreamLanguage.define(kotlinLang)];
    case "scala":
      return [StreamLanguage.define(scalaLang)];
    case "shell":
      return [StreamLanguage.define(shellLang)];
    case "sql":
      return [sql()];
    case "dockerfile":
      return [StreamLanguage.define(dockerFile)];
    case "toml":
      return [StreamLanguage.define(tomlLang)];
    case "ini":
      return [StreamLanguage.define(propertiesLang)];
    default:
      if (languageId === "plaintext") {
        if (ext === "toml") {
          return [StreamLanguage.define(tomlLang)];
        }
        if (ext === "ini" || ext === "env" || ext === "properties") {
          return [StreamLanguage.define(propertiesLang)];
        }
      }
      return [];
  }
}

function createCodeMirrorTheme(isDark: boolean): Extension {
  const background = isDark ? "#111827" : "#ffffff";
  const gutterBackground = isDark ? "#171717" : "#f5f5f5";
  const gutterColor = isDark ? "#9ca3af" : "#6b7280";
  const selection = isDark
    ? "rgba(59,130,246,0.35)"
    : "rgba(59,130,246,0.25)";

  return EditorView.theme(
    {
      "&": {
        backgroundColor: background,
        color: isDark ? "#e5e7eb" : "#1f2937",
        fontFamily: CODEMIRROR_FONT_FAMILY,
        fontSize: "12px",
      },
      ".cm-editor": {
        height: "100%",
        fontFamily: CODEMIRROR_FONT_FAMILY,
      },
      ".cm-content": {
        fontFamily: CODEMIRROR_FONT_FAMILY,
        fontSize: "12px",
        lineHeight: "18px",
        padding: "0",
      },
      ".cm-line": {
        padding: "0 4px",
      },
      ".cm-activeLine": {
        backgroundColor: isDark
          ? "rgba(255,255,255,0.05)"
          : "rgba(0,0,0,0.04)",
      },
      ".cm-activeLineGutter": {
        backgroundColor: isDark
          ? "rgba(255,255,255,0.08)"
          : "rgba(0,0,0,0.06)",
      },
      ".cm-gutters": {
        backgroundColor: gutterBackground,
        color: gutterColor,
        border: "none",
        fontFamily: CODEMIRROR_FONT_FAMILY,
        fontSize: "12px",
      },
      ".cm-gutterElement": {
        padding: "0 8px 0 4px",
      },
      ".cm-selectionBackground": {
        backgroundColor: selection,
      },
      ".cm-content ::selection": {
        backgroundColor: selection,
      },
      ".cm-cursor": {
        display: "none",
      },
      ".cm-scroller": {
        overflow: "auto",
      },
      ".cm-mergeView": {
        backgroundColor: "inherit",
        height: "100%",
      },
      ".cm-mergeView .cm-editor": {
        height: "100%",
      },
      ".cm-mergeView .cm-gutters": {
        backgroundColor: gutterBackground,
      },
      ".cm-panels": {
        backgroundColor: "inherit",
        color: "inherit",
      },
    },
    { dark: isDark }
  );
}
