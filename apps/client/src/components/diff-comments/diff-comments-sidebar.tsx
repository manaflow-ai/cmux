import { useState, useMemo, useCallback } from "react";
import {
  MessageSquare,
  Check,
  Filter,
  ChevronDown,
  ChevronRight,
  FileCode,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useDiffComments } from "./use-diff-comments";
import { DiffCommentThread } from "./diff-comment-thread";
import type { DiffComment } from "./types";

interface DiffCommentsSidebarProps {
  currentUserId?: string;
  className?: string;
  onNavigateToComment?: (comment: DiffComment) => void;
}

type FilterMode = "all" | "unresolved" | "resolved";

interface FileGroup {
  filePath: string;
  comments: DiffComment[];
  unresolvedCount: number;
}

export function DiffCommentsSidebar({
  currentUserId,
  className,
  onNavigateToComment,
}: DiffCommentsSidebarProps) {
  const { comments, isLoading } = useDiffComments();
  const [filterMode, setFilterMode] = useState<FilterMode>("all");
  const [collapsedFiles, setCollapsedFiles] = useState<Set<string>>(new Set());
  const [showFilterMenu, setShowFilterMenu] = useState(false);

  // Group and filter comments
  const { fileGroups, totalCount, unresolvedCount, resolvedCount } = useMemo(() => {
    const filteredComments = comments.filter((comment) => {
      if (filterMode === "unresolved") return !comment.resolved;
      if (filterMode === "resolved") return comment.resolved;
      return true;
    });

    const groupMap = new Map<string, DiffComment[]>();
    for (const comment of filteredComments) {
      const existing = groupMap.get(comment.filePath) ?? [];
      existing.push(comment);
      groupMap.set(comment.filePath, existing);
    }

    const groups: FileGroup[] = Array.from(groupMap.entries())
      .map(([filePath, fileComments]) => ({
        filePath,
        comments: fileComments.sort((a, b) => a.lineNumber - b.lineNumber),
        unresolvedCount: fileComments.filter((c) => !c.resolved).length,
      }))
      .sort((a, b) => a.filePath.localeCompare(b.filePath));

    return {
      fileGroups: groups,
      totalCount: comments.length,
      unresolvedCount: comments.filter((c) => !c.resolved).length,
      resolvedCount: comments.filter((c) => c.resolved).length,
    };
  }, [comments, filterMode]);

  const toggleFileCollapse = useCallback((filePath: string) => {
    setCollapsedFiles((prev) => {
      const next = new Set(prev);
      if (next.has(filePath)) {
        next.delete(filePath);
      } else {
        next.add(filePath);
      }
      return next;
    });
  }, []);

  const filterLabel = useMemo(() => {
    switch (filterMode) {
      case "unresolved":
        return `Unresolved (${unresolvedCount})`;
      case "resolved":
        return `Resolved (${resolvedCount})`;
      default:
        return `All (${totalCount})`;
    }
  }, [filterMode, totalCount, unresolvedCount, resolvedCount]);

  if (isLoading) {
    return (
      <div className={cn("flex flex-col", className)}>
        <div className="px-3 py-2 border-b border-neutral-200 dark:border-neutral-800">
          <div className="flex items-center gap-2">
            <MessageSquare className="w-4 h-4 text-neutral-400" />
            <span className="text-sm font-medium text-neutral-600 dark:text-neutral-400">
              Comments
            </span>
          </div>
        </div>
        <div className="flex-1 flex items-center justify-center">
          <span className="text-xs text-neutral-400">Loading comments...</span>
        </div>
      </div>
    );
  }

  if (comments.length === 0) {
    return (
      <div className={cn("flex flex-col", className)}>
        <div className="px-3 py-2 border-b border-neutral-200 dark:border-neutral-800">
          <div className="flex items-center gap-2">
            <MessageSquare className="w-4 h-4 text-neutral-400" />
            <span className="text-sm font-medium text-neutral-600 dark:text-neutral-400">
              Comments
            </span>
          </div>
        </div>
        <div className="flex-1 flex flex-col items-center justify-center p-6 text-center">
          <MessageSquare className="w-8 h-8 text-neutral-300 dark:text-neutral-600 mb-2" />
          <span className="text-sm text-neutral-500 dark:text-neutral-400">
            No comments yet
          </span>
          <span className="text-xs text-neutral-400 mt-1">
            Click on a line to add a comment
          </span>
        </div>
      </div>
    );
  }

  return (
    <div className={cn("flex flex-col", className)}>
      {/* Header */}
      <div className="px-3 py-2 border-b border-neutral-200 dark:border-neutral-800 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <MessageSquare className="w-4 h-4 text-neutral-400" />
          <span className="text-sm font-medium text-neutral-600 dark:text-neutral-400">
            Comments
          </span>
          {unresolvedCount > 0 && (
            <span className="px-1.5 py-0.5 text-[10px] font-medium bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400 rounded-full">
              {unresolvedCount}
            </span>
          )}
        </div>

        {/* Filter dropdown */}
        <div className="relative">
          <button
            type="button"
            onClick={() => setShowFilterMenu(!showFilterMenu)}
            className="flex items-center gap-1 px-2 py-1 text-xs text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
          >
            <Filter className="w-3 h-3" />
            <span>{filterLabel}</span>
            <ChevronDown className="w-3 h-3" />
          </button>
          {showFilterMenu && (
            <div className="absolute right-0 top-full mt-1 z-50 bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md shadow-lg py-1 min-w-[140px]">
              <button
                type="button"
                onClick={() => {
                  setFilterMode("all");
                  setShowFilterMenu(false);
                }}
                className={cn(
                  "w-full px-3 py-1.5 text-left text-xs flex items-center justify-between",
                  filterMode === "all"
                    ? "bg-neutral-100 dark:bg-neutral-700 text-neutral-900 dark:text-white"
                    : "text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-700/50"
                )}
              >
                <span>All comments</span>
                <span className="text-neutral-400">{totalCount}</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  setFilterMode("unresolved");
                  setShowFilterMenu(false);
                }}
                className={cn(
                  "w-full px-3 py-1.5 text-left text-xs flex items-center justify-between",
                  filterMode === "unresolved"
                    ? "bg-neutral-100 dark:bg-neutral-700 text-neutral-900 dark:text-white"
                    : "text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-700/50"
                )}
              >
                <span>Unresolved</span>
                <span className="text-neutral-400">{unresolvedCount}</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  setFilterMode("resolved");
                  setShowFilterMenu(false);
                }}
                className={cn(
                  "w-full px-3 py-1.5 text-left text-xs flex items-center justify-between",
                  filterMode === "resolved"
                    ? "bg-neutral-100 dark:bg-neutral-700 text-neutral-900 dark:text-white"
                    : "text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-700/50"
                )}
              >
                <span className="flex items-center gap-1">
                  <Check className="w-3 h-3 text-green-500" />
                  Resolved
                </span>
                <span className="text-neutral-400">{resolvedCount}</span>
              </button>
            </div>
          )}
        </div>
      </div>

      {/* Comments list */}
      <div className="flex-1 overflow-y-auto">
        {fileGroups.length === 0 ? (
          <div className="p-4 text-center text-xs text-neutral-400">
            No {filterMode} comments
          </div>
        ) : (
          <div className="divide-y divide-neutral-100 dark:divide-neutral-800">
            {fileGroups.map((group) => (
              <div key={group.filePath}>
                {/* File header */}
                <button
                  type="button"
                  onClick={() => toggleFileCollapse(group.filePath)}
                  className="w-full px-3 py-2 flex items-center gap-2 text-left hover:bg-neutral-50 dark:hover:bg-neutral-800/50 sticky top-0 bg-white dark:bg-neutral-900 z-10"
                >
                  {collapsedFiles.has(group.filePath) ? (
                    <ChevronRight className="w-3.5 h-3.5 text-neutral-400 flex-shrink-0" />
                  ) : (
                    <ChevronDown className="w-3.5 h-3.5 text-neutral-400 flex-shrink-0" />
                  )}
                  <FileCode className="w-3.5 h-3.5 text-neutral-400 flex-shrink-0" />
                  <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300 truncate flex-1">
                    {group.filePath.split("/").pop()}
                  </span>
                  <span className="text-[10px] text-neutral-400 flex-shrink-0">
                    {group.comments.length}
                  </span>
                  {group.unresolvedCount > 0 && (
                    <span className="w-2 h-2 rounded-full bg-blue-500 flex-shrink-0" />
                  )}
                </button>

                {/* File path tooltip on hover (shows full path) */}
                <div className="px-3 -mt-1 mb-1">
                  <span className="text-[10px] text-neutral-400 truncate block">
                    {group.filePath}
                  </span>
                </div>

                {/* Comments */}
                {!collapsedFiles.has(group.filePath) && (
                  <div className="px-2 pb-2 space-y-2">
                    {group.comments.map((comment) => (
                      <div
                        key={comment._id}
                        onClick={() => onNavigateToComment?.(comment)}
                        className="cursor-pointer"
                      >
                        <DiffCommentThread
                          comment={comment}
                          currentUserId={currentUserId}
                          compact
                        />
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
