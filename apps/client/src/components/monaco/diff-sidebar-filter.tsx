import {
  memo,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import {
  Check,
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
  Folder,
  FolderOpen,
  Search,
  X,
} from "lucide-react";

import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";

// ============================================================================
// Types
// ============================================================================

type FileTreeNode = {
  name: string;
  path: string;
  children: FileTreeNode[];
  file?: ReplaceDiffEntry;
};

export type DiffSidebarFilterProps = {
  diffs: ReplaceDiffEntry[];
  viewedFiles: Set<string>;
  activePath: string;
  onSelectFile: (path: string) => void;
  onToggleViewed: (path: string) => void;
  className?: string;
};

// ============================================================================
// Constants
// ============================================================================

const SIDEBAR_WIDTH_STORAGE_KEY = "cmux:monaco-diff-sidebar:width";
const SIDEBAR_DEFAULT_WIDTH = 280;
const SIDEBAR_MIN_WIDTH = 200;
const SIDEBAR_MAX_WIDTH = 442;

// ============================================================================
// Utilities
// ============================================================================

function clampSidebarWidth(value: number): number {
  if (Number.isNaN(value)) {
    return SIDEBAR_DEFAULT_WIDTH;
  }
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, value));
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

function getStatusIcon(status: ReplaceDiffEntry["status"]) {
  const iconClass = "w-3.5 h-3.5 flex-shrink-0";
  switch (status) {
    case "added":
      return <FilePlus className={cn(iconClass, "text-green-600 dark:text-green-400")} />;
    case "deleted":
      return <FileMinus className={cn(iconClass, "text-red-600 dark:text-red-400")} />;
    case "modified":
      return <FileEdit className={cn(iconClass, "text-yellow-600 dark:text-yellow-400")} />;
    case "renamed":
      return <FileCode className={cn(iconClass, "text-blue-600 dark:text-blue-400")} />;
    default:
      return <FileText className={cn(iconClass, "text-neutral-500")} />;
  }
}

function filterTree(nodes: FileTreeNode[], filter: string): FileTreeNode[] {
  if (!filter.trim()) {
    return nodes;
  }

  const lowerFilter = filter.toLowerCase();

  const filterNode = (node: FileTreeNode): FileTreeNode | null => {
    // Check if file matches
    if (node.file) {
      const matches = node.path.toLowerCase().includes(lowerFilter);
      return matches ? node : null;
    }

    // Filter children recursively
    const filteredChildren = node.children
      .map(filterNode)
      .filter((child): child is FileTreeNode => child !== null);

    // Keep directory if it has matching children
    if (filteredChildren.length > 0) {
      return {
        ...node,
        children: filteredChildren,
      };
    }

    return null;
  };

  return nodes
    .map(filterNode)
    .filter((node): node is FileTreeNode => node !== null);
}

// ============================================================================
// Components
// ============================================================================

type FileTreeNavigatorProps = {
  nodes: FileTreeNode[];
  activePath: string;
  expandedPaths: Set<string>;
  viewedFiles: Set<string>;
  onToggleDirectory: (path: string) => void;
  onSelectFile: (path: string) => void;
  onToggleViewed: (path: string) => void;
  depth?: number;
};

const FileTreeNavigator = memo(function FileTreeNavigatorComponent({
  nodes,
  activePath,
  expandedPaths,
  viewedFiles,
  onToggleDirectory,
  onSelectFile,
  onToggleViewed,
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
                  "flex w-full items-center gap-1.5 px-2.5 py-1 text-left text-xs transition hover:bg-neutral-100 dark:hover:bg-neutral-800",
                  isExpanded
                    ? "text-neutral-900 dark:text-neutral-100"
                    : "text-neutral-700 dark:text-neutral-300"
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
                    viewedFiles={viewedFiles}
                    onToggleDirectory={onToggleDirectory}
                    onSelectFile={onSelectFile}
                    onToggleViewed={onToggleViewed}
                    depth={depth + 1}
                  />
                </div>
              ) : null}
            </div>
          );
        }

        const file = node.file;
        if (!file) {
          return null;
        }

        const isViewed = viewedFiles.has(node.path);
        // Extra indent for files to align with folder text (account for chevron space)
        const fileIndent = depth * 14 + 32;

        return (
          <div
            key={node.path}
            className={cn(
              "group flex w-full items-center gap-1.5 pr-2 text-xs transition-colors",
              isActive
                ? "bg-sky-100/80 text-sky-900 dark:bg-sky-900/40 dark:text-sky-100"
                : "text-neutral-700 hover:bg-neutral-100 dark:text-neutral-300 dark:hover:bg-neutral-800"
            )}
            style={{ paddingLeft: fileIndent }}
          >
            <button
              type="button"
              onClick={() => onSelectFile(node.path)}
              className={cn(
                "flex flex-1 items-center gap-1.5 py-1 text-left min-w-0 focus:outline-none",
                isActive ? "font-semibold" : ""
              )}
            >
              {getStatusIcon(file.status)}
              <span className="truncate">{node.name}</span>
              <span className="ml-auto flex items-center gap-1.5 text-[11px] font-medium pr-1">
                {file.additions > 0 && (
                  <span className="text-green-600 dark:text-green-400">
                    +{file.additions}
                  </span>
                )}
                {file.deletions > 0 && (
                  <span className="text-red-600 dark:text-red-400">
                    −{file.deletions}
                  </span>
                )}
              </span>
            </button>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                onToggleViewed(node.path);
              }}
              className={cn(
                "flex-shrink-0 h-4 w-4 flex items-center justify-center rounded-[4px] border transition-colors mr-2",
                isViewed
                  ? "border-neutral-400 dark:border-neutral-500 text-neutral-500 dark:text-neutral-400"
                  : "border-neutral-300 dark:border-neutral-600 hover:border-neutral-400 dark:hover:border-neutral-500"
              )}
              title={isViewed ? "Mark as not viewed" : "Mark as viewed"}
            >
              {isViewed && <Check className="h-2.5 w-2.5" />}
            </button>
          </div>
        );
      })}
    </div>
  );
});

// ============================================================================
// Main Component
// ============================================================================

export function DiffSidebarFilter({
  diffs,
  viewedFiles,
  activePath,
  onSelectFile,
  onToggleViewed,
  className,
}: DiffSidebarFilterProps) {
  const sidebarPanelId = useId();
  const [sidebarWidth, setSidebarWidth] = useState<number>(SIDEBAR_DEFAULT_WIDTH);
  const [isResizingSidebar, setIsResizingSidebar] = useState(false);
  const [filterText, setFilterText] = useState("");
  const filterInputRef = useRef<HTMLInputElement>(null);

  const pointerStartXRef = useRef(0);
  const pointerStartWidthRef = useRef<number>(SIDEBAR_DEFAULT_WIDTH);
  const sidebarPointerMoveHandlerRef = useRef<((event: PointerEvent) => void) | null>(null);
  const sidebarPointerUpHandlerRef = useRef<((event: PointerEvent) => void) | null>(null);

  // Sort files by path for tree building
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

  const fileTree = useMemo(() => buildFileTree(sortedFiles), [sortedFiles]);
  const filteredFileTree = useMemo(
    () => filterTree(fileTree, filterText),
    [fileTree, filterText]
  );

  const directoryPaths = useMemo(
    () => collectDirectoryPaths(fileTree),
    [fileTree]
  );

  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => {
    const defaults = new Set<string>(directoryPaths);
    if (activePath) {
      for (const parent of getParentPaths(activePath)) {
        defaults.add(parent);
      }
    }
    return defaults;
  });

  // Sync expanded paths when filter changes - expand all matched directories
  useEffect(() => {
    if (filterText.trim()) {
      const filteredDirPaths = collectDirectoryPaths(filteredFileTree);
      setExpandedPaths(new Set(filteredDirPaths));
    }
  }, [filterText, filteredFileTree]);

  // Load sidebar width from localStorage
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

  // Save sidebar width to localStorage
  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(
      SIDEBAR_WIDTH_STORAGE_KEY,
      String(Math.round(sidebarWidth))
    );
  }, [sidebarWidth]);

  // Cursor style during resize
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

  // Clean up event listeners on unmount
  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    return () => {
      if (sidebarPointerMoveHandlerRef.current) {
        window.removeEventListener("pointermove", sidebarPointerMoveHandlerRef.current);
        sidebarPointerMoveHandlerRef.current = null;
      }
      if (sidebarPointerUpHandlerRef.current) {
        window.removeEventListener("pointerup", sidebarPointerUpHandlerRef.current);
        window.removeEventListener("pointercancel", sidebarPointerUpHandlerRef.current);
        sidebarPointerUpHandlerRef.current = null;
      }
    };
  }, []);

  // Expand parent paths when active path changes
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
        const nextWidth = clampSidebarWidth(pointerStartWidthRef.current + delta);
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
          window.removeEventListener("pointermove", sidebarPointerMoveHandlerRef.current);
          sidebarPointerMoveHandlerRef.current = null;
        }
        if (sidebarPointerUpHandlerRef.current) {
          window.removeEventListener("pointerup", sidebarPointerUpHandlerRef.current);
          window.removeEventListener("pointercancel", sidebarPointerUpHandlerRef.current);
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
    [sidebarWidth]
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
    []
  );

  const handleSidebarResizeDoubleClick = useCallback(() => {
    setSidebarWidth(SIDEBAR_DEFAULT_WIDTH);
  }, []);

  const handleClearFilter = useCallback(() => {
    setFilterText("");
    filterInputRef.current?.focus();
  }, []);

  return (
    <div className={cn("relative h-full min-h-0", className)}>
      <aside
        id={sidebarPanelId}
        className="flex h-full min-h-0 flex-col"
        style={
          {
            width: `${sidebarWidth}px`,
            minWidth: `${SIDEBAR_MIN_WIDTH}px`,
            maxWidth: `${SIDEBAR_MAX_WIDTH}px`,
          } as CSSProperties
        }
      >
        {/* Search input */}
        <div className="flex-shrink-0 p-2">
          <div className="relative">
            <Search className="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-neutral-400" />
            <input
              ref={filterInputRef}
              type="text"
              placeholder="Search files"
              value={filterText}
              onChange={(e) => setFilterText(e.target.value)}
              className={cn(
                "w-full pl-7 pr-7 py-1 text-xs",
                "bg-neutral-100 dark:bg-neutral-800",
                "border border-neutral-200 dark:border-neutral-700",
                "rounded-md",
                "placeholder:text-neutral-500 dark:placeholder:text-neutral-400",
                "text-neutral-900 dark:text-neutral-100",
                "focus:outline-none focus:border-neutral-400 dark:focus:border-neutral-500"
              )}
            />
            {filterText && (
              <button
                type="button"
                onClick={handleClearFilter}
                className="absolute right-2 top-1/2 -translate-y-1/2 p-0.5 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            )}
          </div>
        </div>

        {/* File tree */}
        <div className="flex-1 min-h-0 overflow-y-auto py-1">
          {filteredFileTree.length > 0 ? (
            <FileTreeNavigator
              nodes={filteredFileTree}
              activePath={activePath}
              expandedPaths={expandedPaths}
              viewedFiles={viewedFiles}
              onToggleDirectory={handleToggleDirectory}
              onSelectFile={onSelectFile}
              onToggleViewed={onToggleViewed}
            />
          ) : filterText.trim() ? (
            <div className="px-4 py-8 text-center text-xs text-neutral-500 dark:text-neutral-400">
              No files match &ldquo;{filterText}&rdquo;
            </div>
          ) : null}
        </div>
      </aside>

      {/* Resize handle */}
      <div
        className={cn(
          "absolute top-0 bottom-0 right-0 w-2 cursor-col-resize select-none touch-none group/resize z-10 translate-x-1/2",
          "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-sky-500"
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
        <span className="sr-only">Drag to adjust file navigation width</span>
        <div
          className={cn(
            "absolute top-0 bottom-0 left-1/2 -translate-x-1/2 w-[3px] rounded-full transition-opacity",
            isResizingSidebar
              ? "bg-sky-500 dark:bg-sky-400 opacity-100"
              : "opacity-0 group-hover/resize:opacity-100 group-hover/resize:bg-sky-500 dark:group-hover/resize:bg-sky-400"
          )}
          aria-hidden
        />
      </div>
    </div>
  );
}
