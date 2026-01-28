import { cn } from "@/lib/utils";
import {
  ChevronDown,
  ChevronRight,
  FileCode,
  FileEdit,
  FileMinus,
  FilePlus,
  FileText,
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

export interface FileDiffHeaderProps {
  filePath: string;
  oldPath?: string;
  status: ReplaceDiffEntry["status"];
  additions: number;
  deletions: number;
  isExpanded: boolean;
  onToggle: () => void;
  className?: string;
}

export function FileDiffHeader({
  filePath,
  oldPath,
  status,
  additions,
  deletions,
  isExpanded,
  onToggle,
  className,
}: FileDiffHeaderProps) {
  return (
    <button
      onClick={onToggle}
      className={cn(
        "w-full px-3 py-2 flex items-center hover:bg-neutral-100/70 dark:hover:bg-neutral-800/60 transition-colors text-left group bg-neutral-50/80 dark:bg-neutral-900/70 border-b border-neutral-200/80 dark:border-neutral-800/70 sticky top-[var(--cmux-diff-header-offset,0px)] z-[var(--z-sticky-low)]",
        className
      )}
    >
      <div className="flex items-center" style={{ width: "20px" }}>
        <div className="text-neutral-400 dark:text-neutral-500 group-hover:text-neutral-600 dark:group-hover:text-neutral-400">
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
          <span className="text-green-600 dark:text-green-400 font-medium select-none">
            +{additions}
          </span>
          <span className="text-red-600 dark:text-red-400 font-medium select-none">
            −{deletions}
          </span>
        </div>
      </div>
    </button>
  );
}
