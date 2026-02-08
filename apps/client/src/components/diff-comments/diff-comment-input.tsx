import { useState, useRef, useEffect, useCallback } from "react";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";
import type { DiffCommentSide } from "./types";
import { useDiffComments } from "./use-diff-comments";

interface DiffCommentInputProps {
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  onClose: () => void;
  className?: string;
}

export function DiffCommentInput({
  filePath,
  lineNumber,
  side,
  onClose,
  className,
}: DiffCommentInputProps) {
  const { addComment } = useDiffComments();
  const [content, setContent] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    textareaRef.current?.focus();
  }, []);

  const handleSubmit = useCallback(async () => {
    if (!content.trim() || isSubmitting) return;

    setIsSubmitting(true);
    try {
      await addComment({
        filePath,
        lineNumber,
        side,
        content: content.trim(),
      });
      setContent("");
      onClose();
    } catch (error) {
      console.error("Failed to add comment:", error);
    } finally {
      setIsSubmitting(false);
    }
  }, [content, isSubmitting, addComment, filePath, lineNumber, side, onClose]);

  return (
    <div
      className={cn(
        "border border-blue-300 dark:border-blue-700 rounded-lg bg-white dark:bg-neutral-900 shadow-lg overflow-hidden",
        className
      )}
    >
      {/* Header */}
      <div className="px-3 py-2 border-b border-neutral-100 dark:border-neutral-800 flex items-center justify-between bg-blue-50/50 dark:bg-blue-900/20">
        <div className="flex items-center gap-2">
          <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">
            Add comment
          </span>
          <span className="text-[10px] text-neutral-400">
            Line {lineNumber}
          </span>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="p-1 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
        >
          <X className="w-3.5 h-3.5" />
        </button>
      </div>

      {/* Input area */}
      <div className="p-3">
        <textarea
          ref={textareaRef}
          value={content}
          onChange={(e) => setContent(e.target.value)}
          placeholder="Write a comment... (Cmd+Enter to submit)"
          className="w-full px-3 py-2 text-[13px] bg-neutral-50 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400 dark:focus:border-blue-600"
          rows={3}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              handleSubmit();
            }
            if (e.key === "Escape") {
              onClose();
            }
          }}
        />
        <div className="flex items-center gap-2 justify-end mt-3">
          <button
            type="button"
            onClick={onClose}
            className="px-3 py-1.5 text-xs font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded-md transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={!content.trim() || isSubmitting}
            className="px-3 py-1.5 text-xs font-medium bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? "Adding..." : "Add comment"}
          </button>
        </div>
      </div>
    </div>
  );
}
