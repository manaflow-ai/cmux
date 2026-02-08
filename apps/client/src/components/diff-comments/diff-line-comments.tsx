import { useState, useCallback, useMemo } from "react";
import { MessageSquare, Plus } from "lucide-react";
import { cn } from "@/lib/utils";
import { useDiffCommentsOptional } from "./use-diff-comments";
import { DiffCommentThread } from "./diff-comment-thread";
import { DiffCommentInput } from "./diff-comment-input";
import type { DiffCommentSide } from "./types";

interface DiffLineCommentsProps {
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  currentUserId?: string;
  className?: string;
}

// Floating comment thread that appears next to a line
export function DiffLineComments({
  filePath,
  lineNumber,
  side,
  currentUserId,
  className,
}: DiffLineCommentsProps) {
  const context = useDiffCommentsOptional();

  // Get comments for this specific line - memoized unconditionally
  const lineComments = useMemo(() => {
    if (!context) return [];
    const fileComments = context.commentsByFile.get(filePath) ?? [];
    return fileComments.filter(
      (c) => c.lineNumber === lineNumber && c.side === side
    );
  }, [context, filePath, lineNumber, side]);

  // Check if input is active for this position
  const isInputActive = useMemo(() => {
    if (!context) return false;
    return (
      context.activeCommentPosition?.filePath === filePath &&
      context.activeCommentPosition?.lineNumber === lineNumber &&
      context.activeCommentPosition?.side === side
    );
  }, [context, filePath, lineNumber, side]);

  const handleCloseInput = useCallback(() => {
    context?.setActiveCommentPosition(null);
  }, [context]);

  if (!context) {
    return null;
  }

  if (lineComments.length === 0 && !isInputActive) {
    return null;
  }

  return (
    <div className={cn("flex flex-col gap-2 py-2", className)}>
      {/* Existing comments */}
      {lineComments.map((comment) => (
        <DiffCommentThread
          key={comment._id}
          comment={comment}
          currentUserId={currentUserId}
        />
      ))}

      {/* New comment input */}
      {isInputActive && (
        <DiffCommentInput
          filePath={filePath}
          lineNumber={lineNumber}
          side={side}
          onClose={handleCloseInput}
        />
      )}
    </div>
  );
}

// Line gutter indicator showing comment count
interface CommentLineIndicatorProps {
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  onClick?: () => void;
}

export function CommentLineIndicator({
  filePath,
  lineNumber,
  side,
  onClick,
}: CommentLineIndicatorProps) {
  const context = useDiffCommentsOptional();

  const lineComments = useMemo(() => {
    if (!context) return [];
    const fileComments = context.commentsByFile.get(filePath) ?? [];
    return fileComments.filter(
      (c) => c.lineNumber === lineNumber && c.side === side
    );
  }, [context, filePath, lineNumber, side]);

  const unresolvedCount = useMemo(
    () => lineComments.filter((c) => !c.resolved).length,
    [lineComments]
  );

  if (!context || lineComments.length === 0) {
    return null;
  }

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex items-center justify-center w-5 h-5 rounded-sm transition-colors",
        unresolvedCount > 0
          ? "bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400 hover:bg-blue-200 dark:hover:bg-blue-800/40"
          : "bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400 hover:bg-green-200 dark:hover:bg-green-800/40"
      )}
      title={`${lineComments.length} comment${lineComments.length === 1 ? "" : "s"}`}
    >
      <MessageSquare className="w-3 h-3" />
    </button>
  );
}

// Add comment button that appears on hover
interface AddCommentButtonProps {
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  className?: string;
}

export function AddCommentButton({
  filePath,
  lineNumber,
  side,
  className,
}: AddCommentButtonProps) {
  const context = useDiffCommentsOptional();

  const handleClick = useCallback(() => {
    context?.setActiveCommentPosition({ filePath, lineNumber, side });
  }, [context, filePath, lineNumber, side]);

  if (!context) {
    return null;
  }

  return (
    <button
      type="button"
      onClick={handleClick}
      className={cn(
        "flex items-center justify-center w-5 h-5 rounded-sm bg-blue-500 text-white opacity-0 group-hover:opacity-100 transition-opacity hover:bg-blue-600",
        className
      )}
      title="Add comment"
    >
      <Plus className="w-3 h-3" />
    </button>
  );
}

// Component that wraps a diff row to add comment interaction
interface DiffRowWithCommentsProps {
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  currentUserId?: string;
  children: React.ReactNode;
  className?: string;
}

export function DiffRowWithComments({
  filePath,
  lineNumber,
  side,
  currentUserId,
  children,
  className,
}: DiffRowWithCommentsProps) {
  const context = useDiffCommentsOptional();
  const [isHovered, setIsHovered] = useState(false);
  const [showComments, setShowComments] = useState(false);

  const lineComments = useMemo(() => {
    if (!context) return [];
    const fileComments = context.commentsByFile.get(filePath) ?? [];
    return fileComments.filter(
      (c) => c.lineNumber === lineNumber && c.side === side
    );
  }, [context, filePath, lineNumber, side]);

  const hasComments = lineComments.length > 0;
  const unresolvedCount = useMemo(
    () => lineComments.filter((c) => !c.resolved).length,
    [lineComments]
  );

  const isInputActive = useMemo(() => {
    if (!context) return false;
    return (
      context.activeCommentPosition?.filePath === filePath &&
      context.activeCommentPosition?.lineNumber === lineNumber &&
      context.activeCommentPosition?.side === side
    );
  }, [context, filePath, lineNumber, side]);

  const handleToggleComments = useCallback(() => {
    setShowComments((prev) => !prev);
  }, []);

  const handleAddComment = useCallback(() => {
    context?.setActiveCommentPosition({ filePath, lineNumber, side });
    setShowComments(true);
  }, [context, filePath, lineNumber, side]);

  const handleCloseInput = useCallback(() => {
    context?.setActiveCommentPosition(null);
    if (lineComments.length === 0) {
      setShowComments(false);
    }
  }, [context, lineComments.length]);

  if (!context) {
    return <>{children}</>;
  }

  return (
    <div
      className={cn("group relative", className)}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
    >
      {/* Main content */}
      <div className="flex items-stretch">
        {/* Comment indicator/button column */}
        <div className="w-6 flex-shrink-0 flex items-center justify-center">
          {hasComments ? (
            <button
              type="button"
              onClick={handleToggleComments}
              className={cn(
                "flex items-center justify-center w-5 h-5 rounded-sm transition-colors",
                unresolvedCount > 0
                  ? "bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400 hover:bg-blue-200 dark:hover:bg-blue-800/40"
                  : "bg-green-100 dark:bg-green-900/30 text-green-600 dark:text-green-400 hover:bg-green-200 dark:hover:bg-green-800/40"
              )}
              title={`${lineComments.length} comment${lineComments.length === 1 ? "" : "s"}`}
            >
              <MessageSquare className="w-3 h-3" />
            </button>
          ) : isHovered ? (
            <button
              type="button"
              onClick={handleAddComment}
              className="flex items-center justify-center w-5 h-5 rounded-sm bg-blue-500 text-white hover:bg-blue-600 transition-colors"
              title="Add comment"
            >
              <Plus className="w-3 h-3" />
            </button>
          ) : null}
        </div>

        {/* Row content */}
        <div className="flex-1 min-w-0">{children}</div>
      </div>

      {/* Comment threads */}
      {(showComments || isInputActive) && (
        <div className="ml-6 mr-2 mb-2">
          <DiffLineComments
            filePath={filePath}
            lineNumber={lineNumber}
            side={side}
            currentUserId={currentUserId}
          />
          {isInputActive && lineComments.length === 0 && (
            <DiffCommentInput
              filePath={filePath}
              lineNumber={lineNumber}
              side={side}
              onClose={handleCloseInput}
            />
          )}
        </div>
      )}
    </div>
  );
}
