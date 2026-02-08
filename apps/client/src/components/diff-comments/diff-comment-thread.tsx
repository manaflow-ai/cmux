import { useState, useCallback, useRef, useEffect } from "react";
import {
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  MoreHorizontal,
  Pencil,
  Reply,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { formatDistanceToNow } from "date-fns";
import type { DiffComment, DiffCommentReply } from "./types";
import { useDiffComments } from "./use-diff-comments";

interface DiffCommentThreadProps {
  comment: DiffComment;
  currentUserId?: string;
  className?: string;
  compact?: boolean;
  onClose?: () => void;
}

function UserAvatar({ user, size = "sm" }: { user: DiffComment["user"]; size?: "sm" | "md" }) {
  const sizeClass = size === "sm" ? "w-6 h-6 text-[10px]" : "w-8 h-8 text-xs";

  if (user?.profileImageUrl) {
    return (
      <img
        src={user.profileImageUrl}
        alt={user.displayName ?? "User"}
        className={cn("rounded-full object-cover flex-shrink-0", sizeClass)}
      />
    );
  }

  const initial = user?.displayName?.[0]?.toUpperCase() ?? "?";
  return (
    <div
      className={cn(
        "rounded-full bg-neutral-200 dark:bg-neutral-700 flex items-center justify-center font-medium text-neutral-600 dark:text-neutral-300 flex-shrink-0",
        sizeClass
      )}
    >
      {initial}
    </div>
  );
}

function CommentContent({
  content,
  isEditing,
  editContent,
  setEditContent,
  onSave,
  onCancel,
}: {
  content: string;
  isEditing: boolean;
  editContent: string;
  setEditContent: (content: string) => void;
  onSave: () => void;
  onCancel: () => void;
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (isEditing && textareaRef.current) {
      textareaRef.current.focus();
      textareaRef.current.selectionStart = textareaRef.current.value.length;
    }
  }, [isEditing]);

  if (isEditing) {
    return (
      <div className="flex flex-col gap-2">
        <textarea
          ref={textareaRef}
          value={editContent}
          onChange={(e) => setEditContent(e.target.value)}
          className="w-full px-2 py-1.5 text-[13px] bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-blue-500/40"
          rows={3}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              onSave();
            }
            if (e.key === "Escape") {
              onCancel();
            }
          }}
        />
        <div className="flex items-center gap-2 justify-end">
          <button
            type="button"
            onClick={onCancel}
            className="px-2 py-1 text-xs text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onSave}
            disabled={!editContent.trim()}
            className="px-2 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Save
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="text-[13px] text-neutral-700 dark:text-neutral-300 whitespace-pre-wrap break-words">
      {content}
    </div>
  );
}

function CommentActions({
  isOwner,
  isResolved,
  onEdit,
  onDelete,
  onResolve,
  onReply,
}: {
  isOwner: boolean;
  isResolved: boolean;
  onEdit: () => void;
  onDelete: () => void;
  onResolve: () => void;
  onReply: () => void;
}) {
  const [showMenu, setShowMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        setShowMenu(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  return (
    <div className="flex items-center gap-1">
      <button
        type="button"
        onClick={onReply}
        className="p-1 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
        title="Reply"
      >
        <Reply className="w-3.5 h-3.5" />
      </button>
      <button
        type="button"
        onClick={onResolve}
        className={cn(
          "p-1 rounded",
          isResolved
            ? "text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-900/20"
            : "text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800"
        )}
        title={isResolved ? "Unresolve" : "Resolve"}
      >
        {isResolved ? (
          <Undo2 className="w-3.5 h-3.5" />
        ) : (
          <CheckCircle2 className="w-3.5 h-3.5" />
        )}
      </button>
      {isOwner && (
        <div className="relative" ref={menuRef}>
          <button
            type="button"
            onClick={() => setShowMenu(!showMenu)}
            className="p-1 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
          >
            <MoreHorizontal className="w-3.5 h-3.5" />
          </button>
          {showMenu && (
            <div className="absolute right-0 top-full mt-1 z-50 bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md shadow-lg py-1 min-w-[120px]">
              <button
                type="button"
                onClick={() => {
                  onEdit();
                  setShowMenu(false);
                }}
                className="w-full px-3 py-1.5 text-left text-xs text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-700 flex items-center gap-2"
              >
                <Pencil className="w-3 h-3" />
                Edit
              </button>
              <button
                type="button"
                onClick={() => {
                  onDelete();
                  setShowMenu(false);
                }}
                className="w-full px-3 py-1.5 text-left text-xs text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 flex items-center gap-2"
              >
                <Trash2 className="w-3 h-3" />
                Delete
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function ReplyItem({
  reply,
  currentUserId,
}: {
  reply: DiffCommentReply;
  currentUserId?: string;
}) {
  const { updateReply, deleteReply } = useDiffComments();
  const [isEditing, setIsEditing] = useState(false);
  const [editContent, setEditContent] = useState(reply.content);
  const isOwner = currentUserId === reply.userId;

  const handleSave = useCallback(async () => {
    if (editContent.trim()) {
      await updateReply(reply._id, editContent.trim());
      setIsEditing(false);
    }
  }, [editContent, reply._id, updateReply]);

  const handleDelete = useCallback(async () => {
    await deleteReply(reply._id);
  }, [deleteReply, reply._id]);

  return (
    <div className="flex gap-2 py-2 border-t border-neutral-100 dark:border-neutral-800">
      <UserAvatar user={reply.user} size="sm" />
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 mb-1">
          <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
            {reply.user?.displayName ?? "Unknown"}
          </span>
          <span className="text-[10px] text-neutral-400">
            {formatDistanceToNow(new Date(reply.createdAt), { addSuffix: true })}
          </span>
          {isOwner && !isEditing && (
            <div className="ml-auto flex items-center gap-1 opacity-0 group-hover/reply:opacity-100 transition-opacity">
              <button
                type="button"
                onClick={() => setIsEditing(true)}
                className="p-0.5 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
              >
                <Pencil className="w-3 h-3" />
              </button>
              <button
                type="button"
                onClick={handleDelete}
                className="p-0.5 text-neutral-400 hover:text-red-600"
              >
                <Trash2 className="w-3 h-3" />
              </button>
            </div>
          )}
        </div>
        <CommentContent
          content={reply.content}
          isEditing={isEditing}
          editContent={editContent}
          setEditContent={setEditContent}
          onSave={handleSave}
          onCancel={() => {
            setIsEditing(false);
            setEditContent(reply.content);
          }}
        />
      </div>
    </div>
  );
}

export function DiffCommentThread({
  comment,
  currentUserId,
  className,
  compact = false,
  onClose,
}: DiffCommentThreadProps) {
  const { updateComment, deleteComment, resolveComment, addReply } = useDiffComments();
  const [isEditing, setIsEditing] = useState(false);
  const [editContent, setEditContent] = useState(comment.content);
  const [isReplying, setIsReplying] = useState(false);
  const [replyContent, setReplyContent] = useState("");
  const [isCollapsed, setIsCollapsed] = useState(compact && comment.resolved);
  const replyInputRef = useRef<HTMLTextAreaElement>(null);

  const isOwner = currentUserId === comment.userId;

  const handleSave = useCallback(async () => {
    if (editContent.trim()) {
      await updateComment(comment._id, editContent.trim());
      setIsEditing(false);
    }
  }, [editContent, comment._id, updateComment]);

  const handleDelete = useCallback(async () => {
    await deleteComment(comment._id);
  }, [deleteComment, comment._id]);

  const handleResolve = useCallback(async () => {
    await resolveComment(comment._id, !comment.resolved);
  }, [resolveComment, comment._id, comment.resolved]);

  const handleAddReply = useCallback(async () => {
    if (replyContent.trim()) {
      await addReply(comment._id, replyContent.trim());
      setReplyContent("");
      setIsReplying(false);
    }
  }, [addReply, comment._id, replyContent]);

  const handleStartReply = useCallback(() => {
    setIsReplying(true);
    setTimeout(() => replyInputRef.current?.focus(), 0);
  }, []);

  if (isCollapsed) {
    return (
      <div
        className={cn(
          "border border-neutral-200 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 overflow-hidden",
          className
        )}
      >
        <button
          type="button"
          onClick={() => setIsCollapsed(false)}
          className="w-full px-3 py-2 flex items-center gap-2 text-left hover:bg-neutral-50 dark:hover:bg-neutral-800/50"
        >
          <ChevronRight className="w-3.5 h-3.5 text-neutral-400" />
          <Check className="w-3.5 h-3.5 text-green-600 dark:text-green-400" />
          <span className="text-xs text-neutral-500 dark:text-neutral-400 truncate flex-1">
            {comment.content.slice(0, 50)}
            {comment.content.length > 50 ? "..." : ""}
          </span>
          <span className="text-[10px] text-neutral-400">
            {comment.replies.length > 0 && `${comment.replies.length} ${comment.replies.length === 1 ? "reply" : "replies"}`}
          </span>
        </button>
      </div>
    );
  }

  return (
    <div
      className={cn(
        "border border-neutral-200 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 overflow-hidden shadow-sm",
        comment.resolved && "border-green-200 dark:border-green-800/50 bg-green-50/30 dark:bg-green-900/10",
        className
      )}
    >
      {/* Header */}
      <div className="px-3 py-2 border-b border-neutral-100 dark:border-neutral-800 flex items-center gap-2 bg-neutral-50/50 dark:bg-neutral-800/30">
        {compact && (
          <button
            type="button"
            onClick={() => setIsCollapsed(true)}
            className="p-0.5 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
          >
            <ChevronDown className="w-3.5 h-3.5" />
          </button>
        )}
        <UserAvatar user={comment.user} size="sm" />
        <div className="flex-1 min-w-0">
          <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
            {comment.user?.displayName ?? "Unknown"}
          </span>
          <span className="text-[10px] text-neutral-400 ml-2">
            {formatDistanceToNow(new Date(comment.createdAt), { addSuffix: true })}
          </span>
        </div>
        {comment.resolved && (
          <span className="text-[10px] text-green-600 dark:text-green-400 font-medium flex items-center gap-1">
            <Check className="w-3 h-3" />
            Resolved
          </span>
        )}
        {onClose && (
          <button
            type="button"
            onClick={onClose}
            className="p-1 text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
          >
            <X className="w-3.5 h-3.5" />
          </button>
        )}
      </div>

      {/* Comment body */}
      <div className="px-3 py-2">
        <CommentContent
          content={comment.content}
          isEditing={isEditing}
          editContent={editContent}
          setEditContent={setEditContent}
          onSave={handleSave}
          onCancel={() => {
            setIsEditing(false);
            setEditContent(comment.content);
          }}
        />
        {!isEditing && (
          <div className="mt-2 flex items-center justify-end">
            <CommentActions
              isOwner={isOwner}
              isResolved={comment.resolved ?? false}
              onEdit={() => setIsEditing(true)}
              onDelete={handleDelete}
              onResolve={handleResolve}
              onReply={handleStartReply}
            />
          </div>
        )}
      </div>

      {/* Replies */}
      {comment.replies.length > 0 && (
        <div className="px-3 pb-2">
          {comment.replies.map((reply) => (
            <div key={reply._id} className="group/reply">
              <ReplyItem reply={reply} currentUserId={currentUserId} />
            </div>
          ))}
        </div>
      )}

      {/* Reply input */}
      {isReplying && (
        <div className="px-3 py-2 border-t border-neutral-100 dark:border-neutral-800">
          <textarea
            ref={replyInputRef}
            value={replyContent}
            onChange={(e) => setReplyContent(e.target.value)}
            placeholder="Write a reply..."
            className="w-full px-2 py-1.5 text-[13px] bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md resize-none focus:outline-none focus:ring-2 focus:ring-blue-500/40"
            rows={2}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                handleAddReply();
              }
              if (e.key === "Escape") {
                setIsReplying(false);
                setReplyContent("");
              }
            }}
          />
          <div className="flex items-center gap-2 justify-end mt-2">
            <button
              type="button"
              onClick={() => {
                setIsReplying(false);
                setReplyContent("");
              }}
              className="px-2 py-1 text-xs text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 rounded"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={handleAddReply}
              disabled={!replyContent.trim()}
              className="px-2 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Reply
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
