import type { Id } from "@cmux/convex/dataModel";

export type DiffCommentSide = "left" | "right";

export interface DiffCommentUser {
  id: string;
  displayName?: string;
  profileImageUrl?: string;
}

export interface DiffCommentReply {
  _id: Id<"diffCommentReplies">;
  commentId: Id<"diffComments">;
  content: string;
  userId: string;
  teamId: string;
  createdAt: number;
  updatedAt: number;
  user: DiffCommentUser | null;
}

export interface DiffComment {
  _id: Id<"diffComments">;
  taskRunId: Id<"taskRuns">;
  filePath: string;
  lineNumber: number;
  side: DiffCommentSide;
  content: string;
  resolved?: boolean;
  userId: string;
  teamId: string;
  createdAt: number;
  updatedAt: number;
  user: DiffCommentUser | null;
  replies: DiffCommentReply[];
}

export interface FileCommentCounts {
  [filePath: string]: {
    total: number;
    unresolved: number;
  };
}

export interface DiffCommentsContextValue {
  comments: DiffComment[];
  commentsByFile: Map<string, DiffComment[]>;
  fileCommentCounts: FileCommentCounts;
  isLoading: boolean;
  addComment: (params: {
    filePath: string;
    lineNumber: number;
    side: DiffCommentSide;
    content: string;
  }) => Promise<void>;
  updateComment: (commentId: Id<"diffComments">, content: string) => Promise<void>;
  deleteComment: (commentId: Id<"diffComments">) => Promise<void>;
  resolveComment: (commentId: Id<"diffComments">, resolved: boolean) => Promise<void>;
  addReply: (commentId: Id<"diffComments">, content: string) => Promise<void>;
  updateReply: (replyId: Id<"diffCommentReplies">, content: string) => Promise<void>;
  deleteReply: (replyId: Id<"diffCommentReplies">) => Promise<void>;
  // For showing/hiding the comment input
  activeCommentPosition: { filePath: string; lineNumber: number; side: DiffCommentSide } | null;
  setActiveCommentPosition: (position: { filePath: string; lineNumber: number; side: DiffCommentSide } | null) => void;
}
