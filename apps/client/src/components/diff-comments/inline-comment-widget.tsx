import { useState, useCallback, useRef, useEffect } from "react";
import { MessageSquare, Plus, X, ChevronDown, ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDiffCommentsOptional } from "./use-diff-comments";
import { DiffCommentThread } from "./diff-comment-thread";
import { DiffCommentInput } from "./diff-comment-input";
import type { DiffComment, DiffCommentSide } from "./types";

interface InlineCommentWidgetProps {
  filePath: string;
  currentUserId?: string;
  className?: string;
}

// Groups comments by line number and displays them in a clean inline format
export function InlineCommentWidget({
  filePath,
  currentUserId,
  className,
}: InlineCommentWidgetProps) {
  const context = useDiffCommentsOptional();
  const [expandedLines, setExpandedLines] = useState<Set<string>>(new Set());
  const [addingCommentLine, setAddingCommentLine] = useState<{
    lineNumber: number;
    side: DiffCommentSide;
  } | null>(null);

  if (!context) return null;

  const fileComments = context.commentsByFile.get(filePath) ?? [];

  if (fileComments.length === 0 && !addingCommentLine) {
    return null;
  }

  // Group comments by line
  const commentsByLine = new Map<string, DiffComment[]>();
  for (const comment of fileComments) {
    const key = `${comment.side}:${comment.lineNumber}`;
    const existing = commentsByLine.get(key) ?? [];
    existing.push(comment);
    commentsByLine.set(key, existing);
  }

  // Sort lines by line number
  const sortedLines = Array.from(commentsByLine.entries()).sort((a, b) => {
    const [, lineA] = a[0].split(":");
    const [, lineB] = b[0].split(":");
    return parseInt(lineA ?? "0", 10) - parseInt(lineB ?? "0", 10);
  });

  const toggleLine = (key: string) => {
    setExpandedLines((prev) => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  };

  const handleCloseInput = () => {
    setAddingCommentLine(null);
    context.setActiveCommentPosition(null);
  };

  return (
    <div className={cn("border-t border-neutral-200 dark:border-neutral-800", className)}>
      {/* Comments header */}
      <div className="px-4 py-2 bg-neutral-50/50 dark:bg-neutral-800/30 border-b border-neutral-200 dark:border-neutral-800 flex items-center gap-2">
        <MessageSquare className="w-4 h-4 text-neutral-400" />
        <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">
          Comments
        </span>
        <span className="text-xs text-neutral-400">
          ({fileComments.length})
        </span>
      </div>

      {/* Comment threads */}
      <div className="divide-y divide-neutral-100 dark:divide-neutral-800/50">
        {sortedLines.map(([key, comments]) => {
          const [side, lineStr] = key.split(":");
          const lineNumber = parseInt(lineStr ?? "0", 10);
          const unresolvedCount = comments.filter((c) => !c.resolved).length;
          const isExpanded = expandedLines.has(key) || expandedLines.size === 0;

          return (
            <div key={key} className="bg-white dark:bg-neutral-900">
              {/* Line header */}
              <button
                type="button"
                onClick={() => toggleLine(key)}
                className="w-full px-4 py-2 flex items-center gap-2 text-left hover:bg-neutral-50 dark:hover:bg-neutral-800/50"
              >
                {isExpanded ? (
                  <ChevronDown className="w-3.5 h-3.5 text-neutral-400" />
                ) : (
                  <ChevronRight className="w-3.5 h-3.5 text-neutral-400" />
                )}
                <span className="text-xs font-mono text-neutral-500 dark:text-neutral-400">
                  Line {lineNumber}
                </span>
                <span className="text-[10px] text-neutral-400 dark:text-neutral-500">
                  {side === "left" ? "(original)" : "(modified)"}
                </span>
                <div className="ml-auto flex items-center gap-2">
                  {unresolvedCount > 0 ? (
                    <span className="px-1.5 py-0.5 text-[10px] font-medium bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400 rounded-full">
                      {unresolvedCount} unresolved
                    </span>
                  ) : (
                    <span className="px-1.5 py-0.5 text-[10px] font-medium bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400 rounded-full">
                      Resolved
                    </span>
                  )}
                  <span className="text-[10px] text-neutral-400">
                    {comments.length} {comments.length === 1 ? "comment" : "comments"}
                  </span>
                </div>
              </button>

              {/* Comment threads */}
              {isExpanded && (
                <div className="px-4 pb-3 space-y-2">
                  {comments.map((comment) => (
                    <DiffCommentThread
                      key={comment._id}
                      comment={comment}
                      currentUserId={currentUserId}
                    />
                  ))}
                </div>
              )}
            </div>
          );
        })}

        {/* New comment input */}
        {addingCommentLine && (
          <div className="p-4 bg-blue-50/30 dark:bg-blue-900/10">
            <div className="text-xs font-mono text-neutral-500 dark:text-neutral-400 mb-2">
              Line {addingCommentLine.lineNumber}
              <span className="text-neutral-400 dark:text-neutral-500 ml-1">
                ({addingCommentLine.side === "left" ? "original" : "modified"})
              </span>
            </div>
            <DiffCommentInput
              filePath={filePath}
              lineNumber={addingCommentLine.lineNumber}
              side={addingCommentLine.side}
              onClose={handleCloseInput}
            />
          </div>
        )}
      </div>
    </div>
  );
}

// Simple add comment button with line number input
interface AddCommentControlProps {
  onAddComment: (lineNumber: number, side: DiffCommentSide) => void;
}

export function AddCommentControl({ onAddComment }: AddCommentControlProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [lineNumber, setLineNumber] = useState("");
  const [side, setSide] = useState<DiffCommentSide>("right");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen && inputRef.current) {
      inputRef.current.focus();
    }
  }, [isOpen]);

  const handleSubmit = useCallback(() => {
    const num = parseInt(lineNumber, 10);
    if (!isNaN(num) && num > 0) {
      onAddComment(num, side);
      setIsOpen(false);
      setLineNumber("");
    }
  }, [lineNumber, side, onAddComment]);

  if (!isOpen) {
    return (
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className="flex items-center gap-1.5 px-2 py-1 text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded transition-colors"
      >
        <Plus className="w-3.5 h-3.5" />
        <span>Comment</span>
      </button>
    );
  }

  return (
    <div className="flex items-center gap-2 px-2 py-1 bg-neutral-100 dark:bg-neutral-800 rounded">
      <span className="text-xs text-neutral-500 dark:text-neutral-400">Line:</span>
      <input
        ref={inputRef}
        type="number"
        min="1"
        value={lineNumber}
        onChange={(e) => setLineNumber(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            handleSubmit();
          }
          if (e.key === "Escape") {
            setIsOpen(false);
            setLineNumber("");
          }
        }}
        placeholder="1"
        className="w-16 px-1.5 py-0.5 text-xs bg-white dark:bg-neutral-900 border border-neutral-300 dark:border-neutral-600 rounded focus:outline-none focus:ring-1 focus:ring-blue-500"
      />
      <select
        value={side}
        onChange={(e) => setSide(e.target.value as DiffCommentSide)}
        className="px-1.5 py-0.5 text-xs bg-white dark:bg-neutral-900 border border-neutral-300 dark:border-neutral-600 rounded focus:outline-none focus:ring-1 focus:ring-blue-500"
      >
        <option value="right">Modified</option>
        <option value="left">Original</option>
      </select>
      <button
        type="button"
        onClick={handleSubmit}
        disabled={!lineNumber || parseInt(lineNumber, 10) < 1}
        className="px-2 py-0.5 text-xs bg-blue-500 text-white rounded hover:bg-blue-600 disabled:opacity-50 disabled:cursor-not-allowed"
      >
        Add
      </button>
      <button
        type="button"
        onClick={() => {
          setIsOpen(false);
          setLineNumber("");
        }}
        className="p-0.5 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
      >
        <X className="w-3.5 h-3.5" />
      </button>
    </div>
  );
}
