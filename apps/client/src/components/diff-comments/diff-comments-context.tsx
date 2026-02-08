import { useCallback, useMemo, useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import type {
  DiffComment,
  DiffCommentsContextValue,
  DiffCommentSide,
  FileCommentCounts,
} from "./types";
import { DiffCommentsContext } from "./diff-comments-context-value";

interface DiffCommentsProviderProps {
  teamSlugOrId: string;
  taskRunId: Id<"taskRuns">;
  children: React.ReactNode;
}

export function DiffCommentsProvider({
  teamSlugOrId,
  taskRunId,
  children,
}: DiffCommentsProviderProps) {
  const [activeCommentPosition, setActiveCommentPosition] = useState<{
    filePath: string;
    lineNumber: number;
    side: DiffCommentSide;
  } | null>(null);

  // Fetch comments
  const commentsQuery = useQuery(api.diffComments.listByTaskRun, {
    teamSlugOrId,
    taskRunId,
  });

  // Memoize comments array to avoid unnecessary rerenders
  const comments = useMemo<DiffComment[]>(() => {
    return (commentsQuery ?? []) as DiffComment[];
  }, [commentsQuery]);

  const isLoading = commentsQuery === undefined;

  // Group comments by file
  const commentsByFile = useMemo(() => {
    const map = new Map<string, DiffComment[]>();
    for (const comment of comments) {
      const existing = map.get(comment.filePath) ?? [];
      existing.push(comment);
      map.set(comment.filePath, existing);
    }
    return map;
  }, [comments]);

  // Get file comment counts
  const fileCommentCounts = useMemo<FileCommentCounts>(() => {
    const counts: FileCommentCounts = {};
    for (const comment of comments) {
      if (!counts[comment.filePath]) {
        counts[comment.filePath] = { total: 0, unresolved: 0 };
      }
      counts[comment.filePath].total += 1;
      if (!comment.resolved) {
        counts[comment.filePath].unresolved += 1;
      }
    }
    return counts;
  }, [comments]);

  // Mutations
  const createMutation = useMutation(api.diffComments.create);
  const updateMutation = useMutation(api.diffComments.update);
  const removeMutation = useMutation(api.diffComments.remove);
  const setResolvedMutation = useMutation(api.diffComments.setResolved);
  const addReplyMutation = useMutation(api.diffComments.addReply);
  const updateReplyMutation = useMutation(api.diffComments.updateReply);
  const removeReplyMutation = useMutation(api.diffComments.removeReply);

  const addComment = useCallback(
    async (params: {
      filePath: string;
      lineNumber: number;
      side: DiffCommentSide;
      content: string;
    }) => {
      await createMutation({
        teamSlugOrId,
        taskRunId,
        filePath: params.filePath,
        lineNumber: params.lineNumber,
        side: params.side,
        content: params.content,
      });
      setActiveCommentPosition(null);
    },
    [createMutation, teamSlugOrId, taskRunId]
  );

  const updateComment = useCallback(
    async (commentId: Id<"diffComments">, content: string) => {
      await updateMutation({
        teamSlugOrId,
        commentId,
        content,
      });
    },
    [updateMutation, teamSlugOrId]
  );

  const deleteComment = useCallback(
    async (commentId: Id<"diffComments">) => {
      await removeMutation({
        teamSlugOrId,
        commentId,
      });
    },
    [removeMutation, teamSlugOrId]
  );

  const resolveComment = useCallback(
    async (commentId: Id<"diffComments">, resolved: boolean) => {
      await setResolvedMutation({
        teamSlugOrId,
        commentId,
        resolved,
      });
    },
    [setResolvedMutation, teamSlugOrId]
  );

  const addReply = useCallback(
    async (commentId: Id<"diffComments">, content: string) => {
      await addReplyMutation({
        teamSlugOrId,
        commentId,
        content,
      });
    },
    [addReplyMutation, teamSlugOrId]
  );

  const updateReply = useCallback(
    async (replyId: Id<"diffCommentReplies">, content: string) => {
      await updateReplyMutation({
        teamSlugOrId,
        replyId,
        content,
      });
    },
    [updateReplyMutation, teamSlugOrId]
  );

  const deleteReply = useCallback(
    async (replyId: Id<"diffCommentReplies">) => {
      await removeReplyMutation({
        teamSlugOrId,
        replyId,
      });
    },
    [removeReplyMutation, teamSlugOrId]
  );

  const value: DiffCommentsContextValue = useMemo(
    () => ({
      comments,
      commentsByFile,
      fileCommentCounts,
      isLoading,
      addComment,
      updateComment,
      deleteComment,
      resolveComment,
      addReply,
      updateReply,
      deleteReply,
      activeCommentPosition,
      setActiveCommentPosition,
    }),
    [
      comments,
      commentsByFile,
      fileCommentCounts,
      isLoading,
      addComment,
      updateComment,
      deleteComment,
      resolveComment,
      addReply,
      updateReply,
      deleteReply,
      activeCommentPosition,
    ]
  );

  return (
    <DiffCommentsContext.Provider value={value}>
      {children}
    </DiffCommentsContext.Provider>
  );
}
