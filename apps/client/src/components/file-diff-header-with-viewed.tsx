import { cn } from "@/lib/utils";
import {
  Check,
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
  MessageSquare,
} from "lucide-react";
import type { ReplaceDiffEntry } from "@cmux/shared/diff-types";

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

export interface FileDiffHeaderWithViewedProps {
  filePath: string;
  oldPath?: string;
  status: ReplaceDiffEntry["status"];
  additions: number;
  deletions: number;
  isExpanded: boolean;
  isViewed: boolean;
  onToggle: () => void;
  onToggleViewed: () => void;
  className?: string;
  commentCount?: number;
  unresolvedCommentCount?: number;
  onAddComment?: () => void;
}

export function FileDiffHeaderWithViewed({
  filePath,
  oldPath,
  status,
  additions,
  deletions,
  isExpanded,
  isViewed,
  onToggle,
  onToggleViewed,
  className,
  commentCount,
  unresolvedCommentCount,
  onAddComment,
}: FileDiffHeaderWithViewedProps) {
  return (
    <div
      className={cn(
        "w-full px-3 py-2 flex items-center text-left bg-neutral-50/80 dark:bg-neutral-900/70 border-b border-neutral-200/80 dark:border-neutral-800/70 sticky top-[var(--cmux-diff-header-offset,0px)] z-[var(--z-sticky-low)]",
        className
      )}
    >
      {/* Expand/collapse toggle */}
      <button
        type="button"
        onClick={onToggle}
        className="flex items-center flex-1 min-w-0"
      >
        <div className="flex items-center" style={{ width: "20px" }}>
          <div className="text-neutral-400 dark:text-neutral-500">
            {isExpanded ? (
              <ChevronDown className="w-3.5 h-3.5" />
            ) : (
              <ChevronRight className="w-3.5 h-3.5" />
            )}
          </div>
        </div>
        <div className="flex items-center" style={{ width: "20px" }}>
          <div className={cn("flex-shrink-0", getStatusColor(status))}>
            {getStatusIcon(status)}
          </div>
        </div>
        <div className="flex-1 min-w-0 flex items-center justify-between gap-3">
          <div className="min-w-0 flex flex-col">
            <span className="font-sans font-medium text-[13px] text-neutral-700 dark:text-neutral-300 truncate select-none">
              {filePath}
            </span>
            {status === "renamed" && oldPath ? (
              <span className="font-sans text-[11px] font-medium text-neutral-500 dark:text-neutral-400 truncate select-none">
                Renamed from {oldPath}
              </span>
            ) : null}
          </div>
          <div className="flex items-center gap-2 text-[11px]">
            {commentCount !== undefined && commentCount > 0 && (
              <span
                className={cn(
                  "flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[10px] font-medium",
                  unresolvedCommentCount && unresolvedCommentCount > 0
                    ? "bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400"
                    : "bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400"
                )}
              >
                <MessageSquare className="w-3 h-3" />
                {unresolvedCommentCount && unresolvedCommentCount > 0
                  ? unresolvedCommentCount
                  : commentCount}
              </span>
            )}
            <span className="text-green-600 dark:text-green-400 font-medium select-none">
              +{additions}
            </span>
            <span className="text-red-600 dark:text-red-400 font-medium select-none">
              −{deletions}
            </span>
          </div>
        </div>
      </button>

      {/* Actions */}
      <div className="flex items-center gap-1 ml-2">
        {/* Add comment button */}
        {onAddComment && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              onAddComment();
            }}
            className="flex items-center gap-1 px-1.5 py-1 rounded-md text-[11px] font-medium text-neutral-400 dark:text-neutral-500 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors"
            title="Add comment"
          >
            <MessageSquare className="h-3.5 w-3.5" />
          </button>
        )}

        {/* Viewed checkbox */}
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onToggleViewed();
          }}
          className={cn(
            "flex items-center gap-1 px-1.5 py-1 rounded-md text-[11px] font-medium",
            "text-neutral-500 dark:text-neutral-400"
          )}
        >
          <div
            className={cn(
              "h-3.5 w-3.5 flex items-center justify-center rounded-[3px] border transition-colors",
              isViewed
                ? "border-neutral-400 dark:border-neutral-500 text-neutral-500 dark:text-neutral-400"
                : "border-neutral-300 dark:border-neutral-600"
            )}
          >
            {isViewed && <Check className="h-2.5 w-2.5" />}
          </div>
          <span className="hidden sm:inline">Viewed</span>
        </button>
      </div>
    </div>
  );
}
