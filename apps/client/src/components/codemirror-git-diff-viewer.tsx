import { useTheme } from "@/components/theme/use-theme";
import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { memo, useEffect, useMemo, useRef, useState } from "react";
import {
  createMergeBaseExtensions,
  getLanguageExtensions,
} from "@/lib/codemirror/merge-extensions";
import {
  createDiffMergeView,
  type DiffMergeViewInstance,
} from "@/lib/codemirror/diff-merge-view";
import { kitties } from "./kitties";
import { FileDiffHeader } from "./file-diff-header";

type FileDiffRowClassNames = {
  button?: string;
  container?: string;
};

type GitDiffViewerClassNames = {
  fileDiffRow?: FileDiffRowClassNames;
};

export interface GitDiffViewerProps {
  diffs: ReplaceDiffEntry[];
  isLoading?: boolean;
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

function debugGitDiffViewerLog(
  message: string,
  payload?: Record<string, unknown>,
) {
  if (!isElectron && import.meta.env.PROD) {
    return;
  }
  if (payload) {
    console.info("[git-diff-viewer]", message, payload);
  } else {
    console.info("[git-diff-viewer]", message);
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
    () => new Set(diffs.map((diff) => diff.filePath)),
  );

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
    [diffs],
  );

  const toggleFile = (filePath: string) => {
    setExpandedFiles((prev) => {
      const newExpanded = new Set(prev);
      const wasExpanded = newExpanded.has(filePath);
      if (wasExpanded) newExpanded.delete(filePath);
      else newExpanded.add(filePath);
      debugGitDiffViewerLog("toggled file", {
        filePath,
        expanded: !wasExpanded,
      });
      try {
        onFileToggle?.(filePath, !wasExpanded);
      } catch {
        // ignore
      }
      return newExpanded;
    });
  };

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
      <div className="flex flex-col -space-y-px">
        {/* - space-y-px is to account for the border between each file diff row */}
        {fileGroups.map((file) => (
          <MemoFileDiffRow
            key={`refs:${file.filePath}`}
            file={file}
            isExpanded={expandedFiles.has(file.filePath)}
            onToggle={() => toggleFile(file.filePath)}
            theme={theme}
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
  classNames,
}: FileDiffRowProps) {
  const mergeHostRef = useRef<HTMLDivElement | null>(null);
  const mergeViewRef = useRef<DiffMergeViewInstance | null>(null);

  const shouldRenderEditor =
    isExpanded &&
    !file.isBinary &&
    file.status !== "deleted" &&
    file.status !== "renamed";

  const baseExtensions = useMemo(
    () => createMergeBaseExtensions(theme),
    [theme],
  );

  const languageExtensions = useMemo(
    () => getLanguageExtensions(file.filePath),
    [file.filePath],
  );

  useEffect(() => {
    if (!shouldRenderEditor) {
      if (mergeViewRef.current) {
        mergeViewRef.current.destroy();
        mergeViewRef.current = null;
      }
      if (mergeHostRef.current) {
        mergeHostRef.current.textContent = "";
      }
      return;
    }

    const host = mergeHostRef.current;
    if (!host) {
      return;
    }

    host.textContent = "";

    const extensions = [...baseExtensions, ...languageExtensions];

    const mergeView = createDiffMergeView({
      oldContent: file.oldContent ?? "",
      newContent: file.newContent ?? "",
      extensions,
      parent: host,
    });

    mergeViewRef.current = mergeView;

    debugGitDiffViewerLog("merge editor mounted", {
      filePath: file.filePath,
    });

    return () => {
      mergeView.destroy();
      mergeViewRef.current = null;
      host.textContent = "";
    };
  }, [
    shouldRenderEditor,
    file.oldContent,
    file.newContent,
    baseExtensions,
    languageExtensions,
    file.filePath,
  ]);

  return (
    <div className={cn("bg-white dark:bg-neutral-900", classNames?.container)}>
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

      {isExpanded && (
        <div className="overflow-hidden">
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
            <div className="relative">
              <div ref={mergeHostRef} className="h-full" />
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
