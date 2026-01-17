import { Dropdown } from "@/components/ui/dropdown";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { useArchiveTask } from "@/hooks/useArchiveTask";
import {
  useResumeMorphWorkspace,
  useRefreshMorphGitHubAuth,
} from "@/hooks/useMorphWorkspace";
import { useOpenWithActions } from "@/hooks/useOpenWithActions";
import { useTaskRename } from "@/hooks/useTaskRename";
import { isElectron } from "@/lib/electron";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import {
  getTaskRunPersistKey,
  getTaskRunBrowserPersistKey,
} from "@/lib/persistent-webview-keys";
import { persistentIframeManager } from "@/lib/persistentIframeManager";
import type { AnnotatedTaskRun, TaskRunWithChildren } from "@/types/task";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { api } from "@cmux/convex/api";
import { type Doc, type Id } from "@cmux/convex/dataModel";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import {
  aggregatePullRequestState,
  type RunPullRequestState,
} from "@cmux/shared/pull-request-state";
import {
  Link,
  useLocation,
  useNavigate,
  type LinkProps,
} from "@tanstack/react-router";
import clsx from "clsx";
import { useMutation, useQuery } from "convex/react";
import { toast } from "sonner";
import { useSetTaskReadState } from "@/hooks/useMarkTaskAsRead";
import {
  AlertTriangle,
  Archive as ArchiveIcon,
  ArchiveRestore as ArchiveRestoreIcon,
  CheckCircle,
  Circle,
  ChevronRight,
  Cloud,
  Copy as CopyIcon,
  Crown,
  EllipsisVertical,
  ExternalLink,
  Eye,
  EyeOff,
  GitBranch,
  GitCompare,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  Globe,
  Monitor,
  Pencil,
  Pin,
  PinOff,
  Play,
  Plus,
  RefreshCw,
  TerminalSquare,
  Loader2,
  Trash2,
  XCircle,
} from "lucide-react";
import {
  Fragment,
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type MouseEvent,
  type ReactElement,
  type ReactNode,
} from "react";
import { VSCodeIcon } from "./icons/VSCodeIcon";
import { SidebarListItem } from "./sidebar/SidebarListItem";
import { annotateAgentOrdinals } from "./task-tree/annotateAgentOrdinals";

type PreviewService = NonNullable<TaskRunWithChildren["networking"]>[number];
type TaskRunStatus = "pending" | "running" | "completed" | "failed" | "skipped";

/**
 * Feature flag to show/hide preview URLs in the sidebar.
 * Set to true to re-enable preview URLs and "Add preview URL" button.
 */
const SHOW_PREVIEW_URLS = false;

function getStatusIcon(status: TaskRunStatus): ReactElement {
  switch (status) {
    case "pending":
      return <Circle className="w-3 h-3 text-neutral-400" />;
    case "running":
      return <Loader2 className="w-3 h-3 text-blue-500 animate-spin" />;
    case "completed":
      return <CheckCircle className="w-3 h-3 text-green-500" />;
    case "failed":
      return <XCircle className="w-3 h-3 text-red-500" />;
    case "skipped":
      return <AlertTriangle className="w-3 h-3 text-amber-500" />;
  }
}

type TaskWithGeneratedBranch = Doc<"tasks"> & {
  generatedBranchName?: string | null;
};

function sanitizeBranchName(input?: string | null): string | null {
  if (!input) return null;
  const trimmed = input.trim();
  if (!trimmed) return null;
  let normalized = trimmed;
  // Strip "cmux/" prefix for display
  if (normalized.startsWith("cmux/")) {
    normalized = normalized.slice("cmux/".length).trim();
    if (!normalized) return null;
  }
  // Note: Don't strip the suffix here - generatedBranchName already has it stripped by the backend
  // (deriveGeneratedBranchName in taskRuns.ts). Only strip for raw branch names that still have
  // the random suffix (e.g., baseBranch which may be "cmux/fix-bug-abc12").
  return normalized;
}

function getTaskBranch(task: TaskWithGeneratedBranch): string | null {
  const fromGenerated = sanitizeBranchName(task.generatedBranchName);
  if (fromGenerated) {
    return fromGenerated;
  }
  return sanitizeBranchName(task.baseBranch);
}

interface TaskTreeProps {
  task: TaskWithGeneratedBranch;
  level?: number;
  // When true, expand the task node on initial mount
  defaultExpanded?: boolean;
  teamSlugOrId: string;
  // Whether this task has unread notifications (show a dot indicator)
  hasUnreadNotification?: boolean;
}

interface SidebarArchiveOverlayProps {
  icon: ReactNode;
  label: string;
  onArchive: () => void;
  groupName: "task" | "run";
  isLoading?: boolean;
}

function SidebarArchiveOverlay({
  icon,
  label,
  onArchive,
  groupName,
  isLoading,
}: SidebarArchiveOverlayProps) {
  const hoverShow =
    groupName === "task"
      ? "group-hover/task:opacity-100 group-hover/task:pointer-events-auto group-data-[focus-visible=true]/task:opacity-100 group-data-[focus-visible=true]/task:pointer-events-auto"
      : "group-hover/run:opacity-100 group-hover/run:pointer-events-auto group-data-[focus-visible=true]/run:opacity-100 group-data-[focus-visible=true]/run:pointer-events-auto";

  return (
    <div className="flex items-center gap-1">
      <Tooltip delayDuration={0}>
        <TooltipTrigger asChild>
          <button
            type="button"
            aria-label={isLoading ? "Archiving..." : label}
            disabled={isLoading}
            className={clsx(
              "flex h-4 w-4 -mr-0.5 items-center justify-center rounded-sm text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-50 pointer-events-none focus-visible:pointer-events-auto focus-visible:opacity-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-400 dark:focus-visible:outline-neutral-500",
              isLoading
                ? "opacity-100 pointer-events-auto cursor-not-allowed"
                : clsx("opacity-0", hoverShow)
            )}
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              if (!isLoading) {
                onArchive();
              }
            }}
          >
            {isLoading ? (
              <Loader2 className="w-3 h-3 animate-spin" />
            ) : (
              <ArchiveIcon className="w-3 h-3" />
            )}
          </button>
        </TooltipTrigger>
        <TooltipContent side="right">
          {isLoading ? "Archiving..." : label}
        </TooltipContent>
      </Tooltip>
      {icon ? (
        <div className="flex items-center justify-center">{icon}</div>
      ) : null}
    </div>
  );
}

// Extract the display text logic to avoid re-creating it on every render
function getRunDisplayText(run: TaskRunWithChildren): string {
  const fromRun = run.agentName?.trim();
  if (fromRun && fromRun.length > 0) {
    return fromRun;
  }

  if (run.summary) {
    return run.summary;
  }

  return run.prompt.substring(0, 50) + "...";
}

function flattenRuns(
  runs: TaskRunWithChildren[] | undefined
): TaskRunWithChildren[] {
  if (!runs) return [];
  const acc: TaskRunWithChildren[] = [];
  const traverse = (items: TaskRunWithChildren[]) => {
    for (const item of items) {
      acc.push(item);
      if (item.children.length > 0) {
        traverse(item.children);
      }
    }
  };
  traverse(runs);
  return acc;
}

function findRunInTree(
  runs: TaskRunWithChildren[],
  targetId: Id<"taskRuns">
): TaskRunWithChildren | null {
  for (const run of runs) {
    if (run._id === targetId) {
      return run;
    }
    if (run.children.length > 0) {
      const childMatch = findRunInTree(run.children, targetId);
      if (childMatch) {
        return childMatch;
      }
    }
  }
  return null;
}

function collectRunIds(
  node: TaskRunWithChildren,
  includeChildren: boolean,
  acc: Set<Id<"taskRuns">>
) {
  acc.add(node._id);
  if (!includeChildren) {
    return;
  }
  for (const child of node.children) {
    collectRunIds(child, true, acc);
  }
}

function applyArchiveStateToNode(
  run: TaskRunWithChildren,
  ids: Set<Id<"taskRuns">>,
  archive: boolean
): [TaskRunWithChildren, boolean] {
  let nextChildren: TaskRunWithChildren[] | null = null;
  let childrenChanged = false;

  for (let i = 0; i < run.children.length; i += 1) {
    const child = run.children[i];
    const [nextChild, childChanged] = applyArchiveStateToNode(
      child,
      ids,
      archive
    );
    if (childChanged) {
      if (!nextChildren) {
        nextChildren = run.children.slice(0, i);
      }
      nextChildren.push(nextChild);
      childrenChanged = true;
    } else if (nextChildren) {
      nextChildren.push(nextChild);
    }
  }

  const shouldUpdate = ids.has(run._id);
  const nextIsArchived = shouldUpdate ? archive : run.isArchived;
  const nodeChanged = childrenChanged || nextIsArchived !== run.isArchived;

  if (!nodeChanged) {
    return [run, false];
  }

  return [
    {
      ...run,
      isArchived: nextIsArchived,
      children: nextChildren ?? run.children,
    },
    true,
  ];
}

function applyArchiveStateToRuns(
  runs: TaskRunWithChildren[],
  ids: Set<Id<"taskRuns">>,
  archive: boolean
): TaskRunWithChildren[] {
  let changed = false;
  const nextRuns = runs.map((run) => {
    const [nextRun, nodeChanged] = applyArchiveStateToNode(run, ids, archive);
    if (nodeChanged) {
      changed = true;
    }
    return nextRun;
  });
  return changed ? nextRuns : runs;
}

function updateRunArchiveStateLocal(
  runs: TaskRunWithChildren[],
  targetId: Id<"taskRuns">,
  archive: boolean,
  includeChildren: boolean
): TaskRunWithChildren[] {
  const target = findRunInTree(runs, targetId);
  if (!target) {
    return runs;
  }
  const ids = new Set<Id<"taskRuns">>();
  collectRunIds(target, includeChildren, ids);
  return applyArchiveStateToRuns(runs, ids, archive);
}

type TaskRunExpansionState = Partial<Record<Id<"taskRuns">, boolean>>;

interface TaskRunExpansionContextValue {
  expandedRuns: TaskRunExpansionState;
  setRunExpanded: (runId: Id<"taskRuns">, expanded: boolean) => void;
}

const TaskRunExpansionContext =
  createContext<TaskRunExpansionContextValue | null>(null);

function useTaskRunExpansionContext(): TaskRunExpansionContextValue {
  const context = useContext(TaskRunExpansionContext);

  if (!context) {
    throw new Error(
      "useTaskRunExpansionContext must be used within TaskRunExpansionContext"
    );
  }

  return context;
}

function TaskTreeInner({
  task,
  level = 0,
  defaultExpanded = false,
  teamSlugOrId,
  hasUnreadNotification = false,
}: TaskTreeProps) {
  const navigate = useNavigate();

  // Get the current route to determine if this task is selected
  const location = useLocation();
  const isTaskSelected = useMemo(
    () => location.pathname.includes(`/task/${task._id}`),
    [location.pathname, task._id]
  );

  const [expandedRuns, setExpandedRuns] = useState<TaskRunExpansionState>({});
  const setRunExpanded = useCallback(
    (runId: Id<"taskRuns">, expanded: boolean) => {
      setExpandedRuns((prev) => {
        if (prev[runId] === expanded) {
          return prev;
        }

        return { ...prev, [runId]: expanded };
      });
    },
    [setExpandedRuns]
  );

  const expansionContextValue = useMemo(
    () => ({ expandedRuns, setRunExpanded }),
    [expandedRuns, setRunExpanded]
  );

  // Default to collapsed unless this task is selected or flagged to expand
  const [isExpanded, setIsExpanded] = useState<boolean>(
    isTaskSelected || defaultExpanded
  );
  const isOptimisticTask = isFakeConvexId(task._id);
  const canRenameTask = !isOptimisticTask;
  const taskRuns = useQuery(
    api.taskRuns.getByTask,
    isOptimisticTask
      ? "skip"
      : { teamSlugOrId, taskId: task._id, includeArchived: true }
  );
  const runsLoading = !isOptimisticTask && taskRuns === undefined;
  const flattenedRuns = useMemo(() => flattenRuns(taskRuns), [taskRuns]);
  const activeRunsFlat = useMemo(
    () => flattenedRuns.filter((run) => !run.isArchived),
    [flattenedRuns]
  );
  const hasVisibleRuns = activeRunsFlat.length > 0;
  const showRunNumbers = flattenedRuns.length > 1;

  // For local workspaces, find the first run to navigate to VSCode view
  // Use the run even when VSCode isn't ready yet (loading state)
  const localWorkspaceRun = useMemo(() => {
    if (!task.isLocalWorkspace) {
      return null;
    }
    // Find the first active run (prefer one with running VSCode, but accept any)
    return activeRunsFlat[0] ?? null;
  }, [task.isLocalWorkspace, activeRunsFlat]);

  // Check if VSCode is actually ready for the local workspace run
  const localWorkspaceVscodeReady = useMemo(() => {
    return localWorkspaceRun?.vscode?.status === "running" && localWorkspaceRun?.vscode?.url;
  }, [localWorkspaceRun]);

  const runMenuEntries = useMemo(
    () =>
      annotateAgentOrdinals(flattenedRuns).map((run) => ({
        id: run._id,
        label: getRunDisplayText(run),
        ordinal: run.agentOrdinal,
        isArchived: Boolean(run.isArchived),
      })),
    [flattenedRuns]
  );
  const prefetched = useRef(false);
  const prefetchTaskRuns = useCallback(() => {
    if (prefetched.current || isOptimisticTask) {
      return;
    }
    prefetched.current = true;
    void convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.getByTask,
      args: { teamSlugOrId, taskId: task._id, includeArchived: true },
    });
  }, [isOptimisticTask, task._id, teamSlugOrId]);

  const archiveTaskRun = useMutation(api.taskRuns.archive).withOptimisticUpdate(
    (localStore, args) => {
      if (!args.taskId) {
        return;
      }
      const variants: Array<{
        teamSlugOrId: string;
        taskId: Id<"tasks">;
        includeArchived?: boolean;
      }> = [
        { teamSlugOrId: args.teamSlugOrId, taskId: args.taskId },
        {
          teamSlugOrId: args.teamSlugOrId,
          taskId: args.taskId,
          includeArchived: true,
        },
      ];

      for (const variant of variants) {
        const current = localStore.getQuery(api.taskRuns.getByTask, variant);
        if (!current) {
          continue;
        }
        const updated = updateRunArchiveStateLocal(
          current,
          args.id,
          args.archive,
          args.includeChildren ?? false
        );
        if (updated !== current) {
          localStore.setQuery(api.taskRuns.getByTask, variant, updated);
        }
      }
    }
  );

  const handleRunArchiveToggle = useCallback(
    async (runId: Id<"taskRuns">, shouldArchive: boolean) => {
      try {
        await archiveTaskRun({
          teamSlugOrId,
          id: runId,
          archive: shouldArchive,
          taskId: task._id,
        });
      } catch (error) {
        console.error(error);
        toast.error(
          shouldArchive
            ? "Failed to archive task run"
            : "Failed to restore task run"
        );
      }
    },
    [archiveTaskRun, task._id, teamSlugOrId]
  );

  // Memoize the toggle handler
  const handleToggle = useCallback(
    (_event?: MouseEvent<HTMLButtonElement | HTMLAnchorElement>) => {
      setIsExpanded((prev) => {
        const next = !prev;
        if (next) {
          prefetchTaskRuns();
        }
        return next;
      });
    },
    [prefetchTaskRuns]
  );

  const handlePrefetch = useCallback(() => {
    prefetchTaskRuns();
  }, [prefetchTaskRuns]);

  // Expand when task becomes selected
  useEffect(() => {
    if (!isTaskSelected) {
      return;
    }

    // Expand the task if not already expanded
    setIsExpanded(true);
  }, [isTaskSelected]);
  const [isTaskLinkFocusVisible, setIsTaskLinkFocusVisible] = useState(false);
  const handleTaskLinkFocus = useCallback(
    (event: FocusEvent<HTMLAnchorElement>) => {
      handlePrefetch();
      setIsTaskLinkFocusVisible(event.currentTarget.matches(":focus-visible"));
    },
    [handlePrefetch]
  );
  const handleTaskLinkBlur = useCallback(() => {
    setIsTaskLinkFocusVisible(false);
  }, []);

  const { archiveWithUndo, unarchive, isArchiving } =
    useArchiveTask(teamSlugOrId);
  const taskIsArchiving = isArchiving(task._id);

  const {
    isRenaming,
    renameValue,
    renameError,
    isRenamePending,
    renameInputRef,
    handleRenameChange,
    handleRenameKeyDown,
    handleRenameBlur,
    handleRenameFocus,
    handleStartRenaming,
  } = useTaskRename({
    taskId: task._id,
    teamSlugOrId,
    currentText: task.text ?? "",
    canRename: canRenameTask,
  });

  const handleCopyDescription = useCallback(() => {
    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(task.text);
    }
  }, [task.text]);

  const handleArchive = useCallback(() => {
    archiveWithUndo(task);
  }, [archiveWithUndo, task]);

  const handleUnarchive = useCallback(() => {
    unarchive(task._id);
  }, [unarchive, task._id]);

  // Mutations for pinning/unpinning tasks with optimistic updates
  const pinTask = useMutation(api.tasks.pin).withOptimisticUpdate(
    (localStore, args) => {
      const now = Date.now();

      // Update the task in the main task list
      const tasks = localStore.getQuery(api.tasks.get, {
        teamSlugOrId: args.teamSlugOrId,
      });
      if (tasks) {
        const updatedTasks = tasks.map((t) =>
          t._id === args.id ? { ...t, pinned: true, updatedAt: now, hasUnread: t.hasUnread ?? false } : t
        );
        localStore.setQuery(
          api.tasks.get,
          { teamSlugOrId: args.teamSlugOrId },
          updatedTasks
        );
      }

      // Update the pinned items query
      const pinned =
        localStore.getQuery(api.tasks.getPinned, {
          teamSlugOrId: args.teamSlugOrId,
        }) || [];
      const taskToPin = tasks?.find((t) => t._id === args.id);
      if (taskToPin) {
        // Insert at the beginning since it's the most recently updated
        localStore.setQuery(
          api.tasks.getPinned,
          { teamSlugOrId: args.teamSlugOrId },
          [{ ...taskToPin, pinned: true, updatedAt: now, hasUnread: taskToPin.hasUnread ?? false }, ...pinned]
        );
      }
    }
  );

  const unpinTask = useMutation(api.tasks.unpin).withOptimisticUpdate(
    (localStore, args) => {
      const now = Date.now();

      // Update the task in the main task list
      const tasks = localStore.getQuery(api.tasks.get, {
        teamSlugOrId: args.teamSlugOrId,
      });
      if (tasks) {
        const updatedTasks = tasks.map((t) =>
          t._id === args.id ? { ...t, pinned: false, updatedAt: now } : t
        );
        localStore.setQuery(
          api.tasks.get,
          { teamSlugOrId: args.teamSlugOrId },
          updatedTasks
        );
      }

      // Update the pinned items query
      const pinned =
        localStore.getQuery(api.tasks.getPinned, {
          teamSlugOrId: args.teamSlugOrId,
        }) || [];
      localStore.setQuery(
        api.tasks.getPinned,
        { teamSlugOrId: args.teamSlugOrId },
        pinned.filter((t) => t._id !== args.id)
      );
    }
  );

  const handlePin = useCallback(() => {
    pinTask({
      teamSlugOrId,
      id: task._id,
    });
  }, [pinTask, teamSlugOrId, task._id]);

  const handleUnpin = useCallback(() => {
    unpinTask({
      teamSlugOrId,
      id: task._id,
    });
  }, [unpinTask, teamSlugOrId, task._id]);

  // Mutation for marking task as read/unread (with optimistic updates)
  const setTaskReadState = useSetTaskReadState(teamSlugOrId);

  const handleMarkAsRead = useCallback(() => {
    setTaskReadState(task._id, true);
  }, [setTaskReadState, task._id]);

  const handleMarkAsUnread = useCallback(() => {
    setTaskReadState(task._id, false);
  }, [setTaskReadState, task._id]);

  const inferredBranch = getTaskBranch(task);
  const trimmedTaskText = (task.text ?? "").trim();
  const trimmedPullRequestTitle = task.pullRequestTitle?.trim();
  const taskTitleValue =
    trimmedTaskText ||
    trimmedPullRequestTitle ||
    task.pullRequestTitle ||
    task.text;
  const taskSecondaryParts: string[] = [];
  if (inferredBranch) {
    taskSecondaryParts.push(inferredBranch);
  }
  if (task.projectFullName) {
    taskSecondaryParts.push(task.projectFullName);
  }
  if (trimmedPullRequestTitle && trimmedPullRequestTitle !== taskTitleValue) {
    taskSecondaryParts.push(trimmedPullRequestTitle);
  }
  const taskSecondary = taskSecondaryParts.join(" • ");
  const taskListPaddingLeft = 10 + level * 4;
  const taskTitleClassName = clsx(
    "inline-flex flex-1 min-w-0 items-center h-[18px] text-[13px] leading-[18px] text-neutral-900 dark:text-neutral-100 transition-colors duration-200",
    isRenaming &&
      "!font-normal !overflow-visible !whitespace-normal [text-overflow:clip]",
    isRenamePending && "text-neutral-400/70 dark:text-neutral-500/70"
  );
  const renameInputElement = (
    <input
      ref={renameInputRef}
      type="text"
      value={renameValue}
      onChange={handleRenameChange}
      onKeyDown={handleRenameKeyDown}
      onBlur={handleRenameBlur}
      disabled={isRenamePending}
      autoFocus
      onFocus={handleRenameFocus}
      placeholder="Task name"
      aria-label="Task name"
      aria-invalid={renameError ? true : undefined}
      autoComplete="off"
      spellCheck={false}
      className={clsx(
        "inline-flex w-full items-center bg-transparent text-[13px] font-medium text-neutral-900 caret-neutral-600 transition-colors duration-200",
        "leading-[18px] h-[18px] px-0 py-0 align-middle",
        "placeholder:text-neutral-400 outline-none border-none focus-visible:outline-none focus-visible:ring-0 appearance-none",
        "dark:text-neutral-100 dark:caret-neutral-200 dark:placeholder:text-neutral-500",
        isRenamePending &&
          "text-neutral-400/70 dark:text-neutral-500/70 cursor-wait"
      )}
    />
  );
  const taskTitleContent = isRenaming ? renameInputElement : taskTitleValue;
  const isCrownEvaluating = task.crownEvaluationStatus === "in_progress";
  const isLocalWorkspace = task.isLocalWorkspace;
  const isCloudWorkspace = task.isCloudWorkspace;
  const canExpand = true;

  const taskLeadingIcon = (() => {
    if (isCrownEvaluating) {
      return (
        <Tooltip delayDuration={0}>
          <TooltipTrigger asChild>
            <div className="relative flex items-center justify-center">
              <Crown className="w-3 h-3 text-neutral-500 group-hover:animate-pulse group-hover:text-neutral-400" />
              <span className="sr-only">Crown evaluation in progress</span>
            </div>
          </TooltipTrigger>
          <TooltipContent
            side="right"
            sideOffset={6}
            className="max-w-sm p-3 text-left z-[var(--z-overlay)]"
          >
            <p className="font-medium text-sm">Selecting best implementation</p>
            <p className="text-xs text-muted-foreground">
              Evaluating runs to choose the best implementation...
            </p>
          </TooltipContent>
        </Tooltip>
      );
    }

    if (task.mergeStatus && task.mergeStatus !== "none") {
      switch (task.mergeStatus) {
        case "pr_draft":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />
              </TooltipTrigger>
              <TooltipContent side="right">Draft PR</TooltipContent>
            </Tooltip>
          );
        case "pr_open":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
              </TooltipTrigger>
              <TooltipContent side="right">PR Open</TooltipContent>
            </Tooltip>
          );
        case "pr_approved":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
              </TooltipTrigger>
              <TooltipContent side="right">PR Approved</TooltipContent>
            </Tooltip>
          );
        case "pr_changes_requested":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitPullRequest className="w-3 h-3 text-yellow-500" />
              </TooltipTrigger>
              <TooltipContent side="right">Changes Requested</TooltipContent>
            </Tooltip>
          );
        case "pr_merged":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitMerge className="w-3 h-3 text-purple-500" />
              </TooltipTrigger>
              <TooltipContent side="right">Merged</TooltipContent>
            </Tooltip>
          );
        case "pr_closed":
          return (
            <Tooltip>
              <TooltipTrigger asChild>
                <GitPullRequestClosed className="w-3 h-3 text-red-500" />
              </TooltipTrigger>
              <TooltipContent side="right">PR Closed</TooltipContent>
            </Tooltip>
          );
        default:
          return null;
      }
    }

    if (task.isCompleted) {
      return <CheckCircle className="w-3 h-3 text-green-500" />;
    }

    if (isLocalWorkspace) {
      return <Monitor className="w-3 h-3 text-neutral-400" />;
    }

    if (isCloudWorkspace) {
      return <Cloud className="w-3 h-3 text-neutral-400" />;
    }

    return <Circle className="w-3 h-3 text-neutral-400 animate-pulse" />;
  })();

  const shouldShowTaskArchiveOverlay =
    !task.isArchived &&
    (Boolean(taskLeadingIcon) || isLocalWorkspace || isCloudWorkspace);

  const taskMetaIcon = shouldShowTaskArchiveOverlay ? (
    <SidebarArchiveOverlay
      icon={taskLeadingIcon}
      label="Archive"
      onArchive={handleArchive}
      groupName="task"
      isLoading={taskIsArchiving}
    />
  ) : (
    taskLeadingIcon
  );

  return (
    <TaskRunExpansionContext.Provider value={expansionContextValue}>
      <div className="select-none flex flex-col">
        <ContextMenu.Root>
          <ContextMenu.Trigger>
              <Link
                to="/$teamSlugOrId/task/$taskId"
                params={{ teamSlugOrId, taskId: task._id }}
                search={{ runId: undefined }}
                activeOptions={{ exact: true }}
                className={clsx(
                  "group/task block",
                  // For local workspaces, manually add active class since we navigate to VSCode sub-route
                  localWorkspaceRun && isTaskSelected && "active"
                )}
              data-focus-visible={isTaskLinkFocusVisible ? "true" : undefined}
              onMouseEnter={handlePrefetch}
              onFocus={handleTaskLinkFocus}
              onBlur={handleTaskLinkBlur}
              onClick={(event) => {
                if (
                  event.defaultPrevented ||
                  event.metaKey ||
                  event.ctrlKey ||
                  event.shiftKey ||
                  event.altKey
                ) {
                  return;
                }
                if (isRenaming) {
                  event.preventDefault();
                  return;
                }
                // For local workspaces, expand and navigate to VSCode view
                if (localWorkspaceRun) {
                  event.preventDefault();
                  setIsExpanded(true);
                  void navigate({
                    to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                    params: {
                      teamSlugOrId,
                      taskId: task._id,
                      runId: localWorkspaceRun._id,
                    },
                  });
                  return;
                }
                handleToggle(event);
              }}
            >
              <SidebarListItem
                paddingLeft={taskListPaddingLeft}
                toggle={{
                  expanded: isExpanded,
                  onToggle: handleToggle,
                  visible: canExpand,
                  hasNotification: hasUnreadNotification,
                }}
                title={taskTitleContent}
                titleClassName={taskTitleClassName}
                secondary={taskSecondary || undefined}
                meta={taskMetaIcon || undefined}
                className={clsx(isRenaming && "pr-2")}
              />
            </Link>
          </ContextMenu.Trigger>
          {isRenaming && renameError ? (
            <div
              className="mt-1 text-[11px] text-red-500 dark:text-red-400"
              style={{ paddingLeft: taskListPaddingLeft }}
            >
              {renameError}
            </div>
          ) : null}
          <ContextMenu.Portal>
            <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
              <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleCopyDescription}
                >
                  <CopyIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Copy description</span>
                </ContextMenu.Item>
                {canRenameTask ? (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleStartRenaming}
                  >
                    <Pencil className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Rename</span>
                  </ContextMenu.Item>
                ) : null}
                {task.pinned ? (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleUnpin}
                  >
                    <PinOff className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Unpin</span>
                  </ContextMenu.Item>
                ) : (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handlePin}
                  >
                    <Pin className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Pin</span>
                  </ContextMenu.Item>
                )}
                {hasUnreadNotification ? (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleMarkAsRead}
                  >
                    <Eye className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Mark as read</span>
                  </ContextMenu.Item>
                ) : (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleMarkAsUnread}
                  >
                    <EyeOff className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Mark as unread</span>
                  </ContextMenu.Item>
                )}
                <ContextMenu.SubmenuRoot>
                  <ContextMenu.SubmenuTrigger className="flex items-center gap-2 cursor-default py-1.5 pr-4 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700">
                    <ArchiveIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Task Runs</span>
                    <ChevronRight className="w-3 h-3 ml-auto text-neutral-400 dark:text-neutral-500" />
                  </ContextMenu.SubmenuTrigger>
                  <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
                    <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 data-[ending-style]:transition-[opacity] data-[ending-style]:duration-100 data-[ending-style]:ease-out data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700 max-w-xs">
                      {runsLoading ? (
                        <div className="flex items-center gap-2 px-3 py-2 text-xs text-neutral-500 dark:text-neutral-400">
                          <Loader2 className="w-3 h-3 animate-spin text-neutral-400" />
                          <span>Loading task runs…</span>
                        </div>
                      ) : (
                        <div className="max-h-64 overflow-y-auto">
                          {runMenuEntries.length > 0 ? (
                            runMenuEntries.map((run) => (
                              <ContextMenu.Item
                                key={run.id}
                                closeOnClick={false}
                                className="flex items-center justify-between gap-3 cursor-default py-1.5 pr-4 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                                onClick={() =>
                                  handleRunArchiveToggle(
                                    run.id,
                                    !run.isArchived
                                  )
                                }
                              >
                                <div className="flex min-w-0 items-center gap-2">
                                  <span className="truncate text-left">
                                    {run.label}
                                  </span>
                                  {showRunNumbers ? (
                                    <span className="text-[11px] font-semibold text-neutral-500 dark:text-neutral-400 flex-shrink-0">
                                      {run.ordinal}
                                    </span>
                                  ) : null}
                                </div>
                                <span className="ml-2 flex flex-shrink-0 items-center text-neutral-500 dark:text-neutral-400">
                                  {run.isArchived ? (
                                    <EyeOff className="w-3.5 h-3.5" />
                                  ) : (
                                    <Eye className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                                  )}
                                </span>
                              </ContextMenu.Item>
                            ))
                          ) : (
                            <div className="px-3 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                              No task runs yet
                            </div>
                          )}
                        </div>
                      )}
                    </ContextMenu.Popup>
                  </ContextMenu.Positioner>
                </ContextMenu.SubmenuRoot>
                {task.isArchived ? (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleUnarchive}
                  >
                    <ArchiveRestoreIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Unarchive</span>
                  </ContextMenu.Item>
                ) : (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleArchive}
                  >
                    <ArchiveIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Archive</span>
                  </ContextMenu.Item>
                )}
              </ContextMenu.Popup>
            </ContextMenu.Positioner>
          </ContextMenu.Portal>
        </ContextMenu.Root>

        {/* For local workspaces, show VSCode link when expanded (with loading state if not ready) */}
        {isExpanded && localWorkspaceRun ? (
          <TaskRunDetailLink
            to="/$teamSlugOrId/task/$taskId/run/$runId/vscode"
            params={{
              teamSlugOrId,
              taskId: task._id,
              runId: localWorkspaceRun._id,
            }}
            icon={
              <VSCodeIcon className="w-3 h-3 mr-2 text-neutral-400 grayscale opacity-60" />
            }
            label="VS Code"
            indentLevel={level + 1}
            trailing={!localWorkspaceVscodeReady ? (
              <Loader2 className="w-3 h-3 animate-spin text-neutral-400" />
            ) : undefined}
          />
        ) : null}

        {/* For non-local workspaces, show normal task runs content */}
        {isExpanded && !localWorkspaceRun ? (
          <TaskRunsContent
            taskId={task._id}
            teamSlugOrId={teamSlugOrId}
            level={level}
            runs={taskRuns}
            isLoading={runsLoading}
            onArchiveToggle={handleRunArchiveToggle}
            hasVisibleRuns={hasVisibleRuns}
            showRunNumbers={showRunNumbers}
          />
        ) : null}
      </div>
    </TaskRunExpansionContext.Provider>
  );
}

interface TaskRunsContentProps {
  taskId: Id<"tasks">;
  teamSlugOrId: string;
  level: number;
  runs: TaskRunWithChildren[] | undefined;
  isLoading: boolean;
  onArchiveToggle: (runId: Id<"taskRuns">, archive: boolean) => void;
  hasVisibleRuns: boolean;
  showRunNumbers: boolean;
}

function TaskRunsContent({
  taskId,
  teamSlugOrId,
  level,
  runs,
  isLoading,
  onArchiveToggle,
  hasVisibleRuns,
  showRunNumbers,
}: TaskRunsContentProps) {
  const location = useLocation();
  const optimisticTask = isFakeConvexId(taskId);

  const annotatedRuns = useMemo(
    () => (runs && runs.length > 0 ? annotateAgentOrdinals(runs) : []),
    [runs]
  );

  const runIdFromSearch = useMemo(() => {
    if (
      location.search &&
      typeof location.search === "object" &&
      location.search !== null &&
      "runId" in location.search &&
      typeof location.search.runId === "string"
    ) {
      const parsed = typedZid("taskRuns").safeParse(location.search.runId);
      if (parsed.success) {
        return parsed.data;
      }
    }
    return undefined;
  }, [location.search]);

  const firstVisibleRunId = useMemo(() => {
    for (const run of annotatedRuns) {
      if (!run.isArchived) {
        return run._id;
      }
    }
    return null;
  }, [annotatedRuns]);

  const shouldHighlightDefaultRun = useMemo(() => {
    if (!annotatedRuns.length || !hasVisibleRuns) {
      return false;
    }
    const isTaskRoute = location.pathname.includes(`/task/${taskId}`);
    const hasRunSegment = location.pathname.includes(`/task/${taskId}/run/`);
    const hasExplicitRunSelection = Boolean(runIdFromSearch);
    return isTaskRoute && !hasRunSegment && !hasExplicitRunSelection;
  }, [
    annotatedRuns.length,
    hasVisibleRuns,
    location.pathname,
    runIdFromSearch,
    taskId,
  ]);

  if (optimisticTask) {
    return (
      <TaskRunsMessage level={level}>
        <span className="italic">No task runs yet</span>
      </TaskRunsMessage>
    );
  }

  if (isLoading) {
    return (
      <TaskRunsMessage level={level}>
        <Loader2 className="w-3 h-3 animate-spin text-neutral-400" />
        <span>Loading task runs…</span>
      </TaskRunsMessage>
    );
  }

  if (annotatedRuns.length === 0) {
    return (
      <TaskRunsMessage level={level}>
        <span className="italic">No task runs yet</span>
      </TaskRunsMessage>
    );
  }

  if (!hasVisibleRuns) {
    return (
      <TaskRunsMessage level={level} fixedHeight={24.33}>
        <span className="italic">All task runs hidden</span>
      </TaskRunsMessage>
    );
  }

  return (
    <div className="flex flex-col">
      {annotatedRuns.map((run) => (
        <TaskRunTree
          key={run._id}
          run={run}
          level={level + 1}
          taskId={taskId}
          teamSlugOrId={teamSlugOrId}
          isDefaultSelected={
            shouldHighlightDefaultRun && firstVisibleRunId === run._id
          }
          onArchiveToggle={onArchiveToggle}
          showRunNumbers={showRunNumbers}
        />
      ))}
    </div>
  );
}

function TaskRunsMessage({
  level,
  children,
  fixedHeight,
}: {
  level: number;
  children: ReactNode;
  fixedHeight?: number;
}) {
  const paddingLeft = 10 + (level + 1) * 16;
  return (
    <div
      className={clsx(
        "flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400 select-none",
        fixedHeight ? "py-0" : "py-2"
      )}
      style={
        fixedHeight
          ? {
              paddingLeft,
              height: `${fixedHeight}px`,
              minHeight: `${fixedHeight}px`,
            }
          : { paddingLeft }
      }
    >
      {children}
    </div>
  );
}

interface TaskRunTreeProps {
  run: AnnotatedTaskRun;
  level: number;
  taskId: Id<"tasks">;
  teamSlugOrId: string;
  isDefaultSelected?: boolean;
  onArchiveToggle: (runId: Id<"taskRuns">, archive: boolean) => void;
  showRunNumbers: boolean;
}

function TaskRunTreeInner({
  run,
  level,
  taskId,
  teamSlugOrId,
  isDefaultSelected = false,
  onArchiveToggle,
  showRunNumbers,
}: TaskRunTreeProps) {
  const location = useLocation();
  const { expandedRuns, setRunExpanded } = useTaskRunExpansionContext();
  const defaultExpanded = Boolean(run.isCrowned);
  const isExpanded = expandedRuns[run._id] ?? defaultExpanded;
  const runIdFromSearch = useMemo(() => {
    if (
      location.search &&
      typeof location.search === "object" &&
      location.search !== null &&
      "runId" in location.search
    ) {
      const value = location.search.runId;
      if (typeof value === "string") {
        const parsed = typedZid("taskRuns").safeParse(value);
        if (parsed.success) {
          return parsed.data;
        }
      }
    }
    return undefined;
  }, [location.search]);
  const isRunRoute = useMemo(
    () =>
      location.pathname.includes(
        `/${teamSlugOrId}/task/${taskId}/run/${run._id}`
      ),
    [location.pathname, teamSlugOrId, taskId, run._id]
  );
  const isRunSelected = useMemo(
    () => isDefaultSelected || runIdFromSearch === run._id || isRunRoute,
    [isDefaultSelected, isRunRoute, run._id, runIdFromSearch]
  );

  const hasExpandedManually = useRef<Id<"taskRuns"> | null>(null);

  useEffect(() => {
    if (
      isRunSelected &&
      !isExpanded &&
      hasExpandedManually.current !== run._id
    ) {
      setRunExpanded(run._id, true);
    }
  }, [isExpanded, isRunSelected, run._id, setRunExpanded]);

  const hasChildren = run.children.length > 0;

  // Memoize the display text to avoid recalculating on every render
  const baseDisplayText = useMemo(() => {
    const base = getRunDisplayText(run);
    // if (!run.hasDuplicateAgentName) {
    //   return base;
    // }
    // const ordinal = run.agentOrdinal;
    // return ordinal ? `${base} (${ordinal})` : base;
    return base;
  }, [run]);
  const runNumberSuffix =
    showRunNumbers && run.agentOrdinal ? (
      <span className="text-[11px] font-semibold text-neutral-500 dark:text-neutral-400 tabular-nums">
        {run.agentOrdinal}
      </span>
    ) : null;

  // Memoize the toggle handler
  const handleToggle = useCallback(
    (_event?: MouseEvent<HTMLButtonElement | HTMLAnchorElement>) => {
      hasExpandedManually.current = run._id;
      setRunExpanded(run._id, !isExpanded);
    },
    [isExpanded, run._id, setRunExpanded]
  );
  const handleArchiveRun = useCallback(() => {
    onArchiveToggle(run._id, true);
  }, [onArchiveToggle, run._id]);

  const isLocalWorkspaceRunEntry = run.isLocalWorkspace;
  const isCloudWorkspaceRunEntry = run.isCloudWorkspace;

  const statusIcon = getStatusIcon(run.status);

  const shouldHideStatusIcon =
    (isLocalWorkspaceRunEntry || isCloudWorkspaceRunEntry) &&
    run.status !== "failed";

  const pullRequestState = useMemo<RunPullRequestState | null>(() => {
    if (run.pullRequests && run.pullRequests.length > 0) {
      const summary = aggregatePullRequestState(run.pullRequests);
      return summary.state === "none" ? null : summary.state;
    }
    const explicit = run.pullRequestState;
    if (explicit && explicit !== "none") {
      return explicit;
    }
    if (run.pullRequestUrl && run.pullRequestUrl !== "pending") {
      return run.pullRequestIsDraft ? "draft" : "open";
    }
    return null;
  }, [
    run.pullRequestIsDraft,
    run.pullRequestState,
    run.pullRequestUrl,
    run.pullRequests,
  ]);

  const pullRequestIcon = useMemo<ReactNode>(() => {
    if (run.status !== "completed") {
      return null;
    }
    if (!pullRequestState || pullRequestState === "none") {
      return null;
    }

    let tooltipLabel: string;
    let icon: ReactElement;

    switch (pullRequestState) {
      case "draft":
        tooltipLabel = "Draft PR";
        icon = <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />;
        break;
      case "open":
        tooltipLabel = "PR Open";
        icon = (
          <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
        );
        break;
      case "merged":
        tooltipLabel = "Merged";
        icon = <GitMerge className="w-3 h-3 text-purple-500" />;
        break;
      case "closed":
        tooltipLabel = "PR Closed";
        icon = <GitPullRequestClosed className="w-3 h-3 text-red-500" />;
        break;
      case "unknown":
        tooltipLabel = "PR Status Unknown";
        icon = <GitPullRequest className="w-3 h-3 text-neutral-500" />;
        break;
      default:
        return null;
    }

    return (
      <Tooltip>
        <TooltipTrigger asChild>{icon}</TooltipTrigger>
        <TooltipContent side="right">{tooltipLabel}</TooltipContent>
      </Tooltip>
    );
  }, [pullRequestState, run.status]);

  const hideStatusIcon = shouldHideStatusIcon && !pullRequestIcon;
  const resolvedStatusIcon = hideStatusIcon ? null : statusIcon;

  const statusIconWithTooltip =
    run.status === "failed" && run.errorMessage ? (
      <Tooltip>
        <TooltipTrigger asChild>
          {resolvedStatusIcon ?? statusIcon}
        </TooltipTrigger>
        <TooltipContent
          side="right"
          className="max-w-xs whitespace-pre-wrap break-words"
        >
          {run.errorMessage}
        </TooltipContent>
      </Tooltip>
    ) : (
      resolvedStatusIcon
    );

  const runLeadingIcon = pullRequestIcon ?? statusIconWithTooltip;

  const shouldShowRunArchiveOverlay =
    !run.isArchived &&
    (Boolean(runLeadingIcon) ||
      isLocalWorkspaceRunEntry ||
      isCloudWorkspaceRunEntry);

  const crownIcon = run.isCrowned ? (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <Crown className="w-3 h-3 text-yellow-500" />
      </TooltipTrigger>
      {run.crownReason ? (
        <TooltipContent
          side="right"
          sideOffset={6}
          className="max-w-sm p-3 z-[var(--z-global-blocking)]"
        >
          <div className="space-y-1.5">
            <p className="font-medium text-sm text-neutral-200">
              Evaluation Reason
            </p>
            <p className="text-xs text-neutral-400">{run.crownReason}</p>
          </div>
        </TooltipContent>
      ) : null}
    </Tooltip>
  ) : null;

  // Combine crown + status icon, with archive overlay on the left of everything
  const iconsContent = crownIcon ? (
    <div className="flex items-center gap-1">
      {crownIcon}
      {runLeadingIcon}
    </div>
  ) : (
    runLeadingIcon
  );

  const leadingContent = shouldShowRunArchiveOverlay ? (
    <SidebarArchiveOverlay
      icon={iconsContent}
      label="Archive"
      onArchive={handleArchiveRun}
      groupName="run"
    />
  ) : (
    iconsContent
  );

  // Generate VSCode URL if available - used for "Open with" actions
  const hasActiveVSCode = run.vscode?.status === "running";
  const vscodeUrl = useMemo(
    () => (hasActiveVSCode && run.vscode?.url) || null,
    [hasActiveVSCode, run]
  );
  const vscodeProvider = run.vscode?.provider;

  // Collect running preview ports and custom previews
  const previewServices = useMemo(() => {
    if (!run.networking) return [];
    return run.networking.filter((service) => service.status === "running");
  }, [run.networking]);

  const {
    actions: openWithActions,
    executeOpenAction,
    copyBranch: copyRunBranch,
    ports: portActions,
    executePortAction,
  } = useOpenWithActions({
    vscodeUrl,
    vscodeProvider,
    worktreePath: run.worktreePath,
    branch: run.newBranch,
    networking: run.networking,
  });

  const resumeWorkspace = useResumeMorphWorkspace({
    taskRunId: run._id,
    teamSlugOrId,
  });

  const handleResumeWorkspace = useCallback(() => {
    if (resumeWorkspace.isPending) {
      return;
    }

    void resumeWorkspace.mutateAsync({
      path: { taskRunId: run._id },
      body: { teamSlugOrId },
    });
  }, [resumeWorkspace, run._id, teamSlugOrId]);

  const refreshGitHubAuth = useRefreshMorphGitHubAuth({
    taskRunId: run._id,
    teamSlugOrId,
  });

  const handleRefreshGitHubAuth = useCallback(() => {
    if (refreshGitHubAuth.isPending) {
      return;
    }

    void refreshGitHubAuth.mutateAsync({
      path: { taskRunId: run._id },
      body: { teamSlugOrId },
    });
  }, [refreshGitHubAuth, run._id, teamSlugOrId]);

  const shouldRenderPullRequestLink = Boolean(
    (run.pullRequestUrl && run.pullRequestUrl !== "pending") ||
      run.pullRequests?.some((pr) => pr.url)
  );
  const hasOpenWithActions = openWithActions.length > 0;
  const hasPortActions = portActions.length > 0;
  const canCopyBranch = Boolean(copyRunBranch);
  const hasCollapsibleContent = true;
  const [isRunLinkFocusVisible, setIsRunLinkFocusVisible] = useState(false);
  const handleRunLinkFocus = useCallback(
    (event: FocusEvent<HTMLAnchorElement>) => {
      setIsRunLinkFocusVisible(event.currentTarget.matches(":focus-visible"));
    },
    []
  );
  const handleRunLinkBlur = useCallback(() => {
    setIsRunLinkFocusVisible(false);
  }, []);

  return (
    <div className={clsx({ hidden: run.isArchived })}>
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <Link
            to="/$teamSlugOrId/task/$taskId"
            params={{
              teamSlugOrId,
              taskId,
            }}
            search={(prev) => ({
              ...(prev ?? {}),
              runId: run._id,
            })}
            className="group/run block"
            data-focus-visible={isRunLinkFocusVisible ? "true" : undefined}
            activeOptions={{ exact: false }}
            onFocus={handleRunLinkFocus}
            onBlur={handleRunLinkBlur}
            onClick={(event) => {
              if (
                event.defaultPrevented ||
                event.button !== 0 ||
                event.metaKey ||
                event.ctrlKey ||
                event.shiftKey ||
                event.altKey
              ) {
                return;
              }

              handleToggle();
            }}
          >
            <SidebarListItem
              containerClassName={clsx("mt-px", { active: isRunSelected })}
              paddingLeft={10 + level * 16}
              toggle={{
                expanded: isExpanded,
                onToggle: handleToggle,
                visible: hasCollapsibleContent,
              }}
              title={baseDisplayText}
              titleClassName="text-[13px] text-neutral-700 dark:text-neutral-300"
              titleSuffix={runNumberSuffix ?? undefined}
              meta={leadingContent}
            />
          </Link>
        </ContextMenu.Trigger>
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
            <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
              {canCopyBranch ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={copyRunBranch}
                >
                  <GitBranch className="w-3.5 h-3.5" />
                  Copy branch name
                </ContextMenu.Item>
              ) : null}
              {run.vscode?.provider === "morph" ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleResumeWorkspace}
                  disabled={resumeWorkspace.isPending}
                >
                  <Play className="w-3.5 h-3.5" />
                  {resumeWorkspace.isPending ? "Resuming…" : "Resume VM"}
                </ContextMenu.Item>
              ) : null}
              {run.vscode?.provider === "morph" ? (
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleRefreshGitHubAuth}
                  disabled={refreshGitHubAuth.isPending}
                >
                  <RefreshCw className="w-3.5 h-3.5" />
                  {refreshGitHubAuth.isPending
                    ? "Refreshing…"
                    : "Refresh GitHub auth"}
                </ContextMenu.Item>
              ) : null}
              {hasOpenWithActions ? (
                <ContextMenu.SubmenuRoot>
                  <ContextMenu.SubmenuTrigger className="flex items-center gap-2 cursor-default py-1.5 pr-4 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700">
                    <ExternalLink className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Open with</span>
                    <ChevronRight className="w-3 h-3 ml-auto text-neutral-400 dark:text-neutral-500" />
                  </ContextMenu.SubmenuTrigger>
                  <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
                    <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 data-[ending-style]:transition-[opacity] data-[ending-style]:duration-100 data-[ending-style]:ease-out data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700 max-w-xs">
                      <div className="max-h-64 overflow-y-auto">
                        {openWithActions.map((action) => {
                          const Icon = action.Icon;
                          return (
                            <ContextMenu.Item
                              key={action.id}
                              className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                              onClick={() => executeOpenAction(action)}
                            >
                              {Icon ? <Icon className="w-3.5 h-3.5" /> : null}
                              {action.name}
                            </ContextMenu.Item>
                          );
                        })}
                      </div>
                    </ContextMenu.Popup>
                  </ContextMenu.Positioner>
                </ContextMenu.SubmenuRoot>
              ) : null}
              {hasPortActions ? (
                <ContextMenu.SubmenuRoot>
                  <ContextMenu.SubmenuTrigger className="flex items-center gap-2 cursor-default py-1.5 pr-4 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700">
                    <Globe className="w-3 h-3 text-neutral-600 dark:text-neutral-300" />
                    <span>Forwarded ports</span>
                    <ChevronRight className="w-3 h-3 ml-auto text-neutral-400 dark:text-neutral-500" />
                  </ContextMenu.SubmenuTrigger>
                  <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
                    <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 data-[ending-style]:transition-[opacity] data-[ending-style]:duration-100 data-[ending-style]:ease-out data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700 max-w-xs">
                      <div className="max-h-64 overflow-y-auto">
                        {portActions.map((port) => (
                          <ContextMenu.Item
                            key={port.port}
                            className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                            onClick={() => executePortAction(port)}
                          >
                            <Globe className="w-3 h-3" />
                            Port {port.port}
                          </ContextMenu.Item>
                        ))}
                      </div>
                    </ContextMenu.Popup>
                  </ContextMenu.Positioner>
                </ContextMenu.SubmenuRoot>
              ) : null}
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={handleArchiveRun}
              >
                <ArchiveIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                <span>Hide</span>
              </ContextMenu.Item>
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>

      <TaskRunDetails
        run={run}
        level={level}
        taskId={taskId}
        teamSlugOrId={teamSlugOrId}
        isExpanded={isExpanded}
        hasChildren={hasChildren}
        shouldRenderPullRequestLink={shouldRenderPullRequestLink}
        previewServices={previewServices}
        customPreviews={run.customPreviews || []}
        environmentError={run.environmentError}
        onArchiveToggle={onArchiveToggle}
        showRunNumbers={showRunNumbers}
        isLocalWorkspace={Boolean(isLocalWorkspaceRunEntry)}
        isCloudWorkspace={Boolean(isCloudWorkspaceRunEntry)}
      />
    </div>
  );
}

interface TaskRunDetailLinkProps {
  to: LinkProps["to"];
  params: LinkProps["params"];
  icon: ReactNode;
  label: string;
  indentLevel: number;
  className?: string;
  onClick?: (event: MouseEvent<HTMLAnchorElement>) => void;
  trailing?: ReactNode;
  onReload?: () => void;
}

function TaskRunDetailLink({
  to,
  params,
  icon,
  label,
  indentLevel,
  className,
  onClick,
  trailing,
  onReload,
}: TaskRunDetailLinkProps) {
  const linkElement = (
    <Link
      to={to}
      params={params}
      activeOptions={{ exact: true }}
      className={clsx(
        "flex items-center justify-between gap-2 px-2 py-1 text-xs rounded-md hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 cursor-default mt-px",
        "[&.active]:bg-neutral-200/75 dark:[&.active]:bg-neutral-800/65",
        "[&.active]:hover:bg-neutral-200/75 dark:[&.active]:hover:bg-neutral-800/65",
        className
      )}
      style={{ paddingLeft: `${24 + indentLevel * 8}px` }}
      onClick={onClick}
    >
      <span className="flex min-w-0 items-center">
        {icon}
        <span className="text-neutral-600 dark:text-neutral-400">{label}</span>
      </span>
      {trailing ? (
        <span className="flex shrink-0 items-center">{trailing}</span>
      ) : null}
    </Link>
  );

  if (!onReload) {
    return linkElement;
  }

  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger>{linkElement}</ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
          <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
            <ContextMenu.Item
              className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
              onClick={onReload}
            >
              <RefreshCw className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
              <span>Reload</span>
            </ContextMenu.Item>
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  );
}

interface AddPreviewInputProps {
  indentLevel: number;
  onAdd: (url: string) => Promise<number>;
  currentCount: number;
  taskId: Id<"tasks">;
  runId: Id<"taskRuns">;
  teamSlugOrId: string;
}

function AddPreviewInput({
  indentLevel,
  onAdd,
  currentCount,
  taskId,
  runId,
  teamSlugOrId,
}: AddPreviewInputProps) {
  const navigate = useNavigate();

  const handleClick = () => {
    // Use next index as optimistic previewId
    const previewId = String(currentCount);

    // Navigate immediately (optimistic)
    void navigate({
      to: "/$teamSlugOrId/task/$taskId/run/$runId/preview/$previewId",
      params: { teamSlugOrId, taskId, runId, previewId },
    });

    // Persist in background
    void onAdd("about:blank").catch((error) => {
      console.error("Failed to create preview", error);
    });
  };

  return (
    <button
      onClick={handleClick}
      className="w-full flex items-center gap-2 px-2 py-1 text-xs rounded-md hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 mt-px text-neutral-500 dark:text-neutral-400"
      style={{ paddingLeft: `${24 + indentLevel * 8}px` }}
    >
      <Plus className="w-3 h-3 text-neutral-400" />
      <span>Add preview URL</span>
    </button>
  );
}

interface TaskRunDetailsProps {
  run: AnnotatedTaskRun;
  level: number;
  taskId: Id<"tasks">;
  teamSlugOrId: string;
  isExpanded: boolean;
  hasChildren: boolean;
  shouldRenderPullRequestLink: boolean;
  previewServices: PreviewService[];
  customPreviews: Array<{
    url: string;
    createdAt: number;
  }>;
  environmentError?: {
    maintenanceError?: string;
    devError?: string;
  };
  onArchiveToggle: (runId: Id<"taskRuns">, archive: boolean) => void;
  showRunNumbers: boolean;
  isLocalWorkspace: boolean;
  isCloudWorkspace: boolean;
}

function TaskRunDetails({
  run,
  level,
  taskId,
  teamSlugOrId,
  isExpanded,
  hasChildren,
  shouldRenderPullRequestLink,
  previewServices,
  customPreviews,
  environmentError,
  onArchiveToggle,
  showRunNumbers,
  isLocalWorkspace,
  isCloudWorkspace,
}: TaskRunDetailsProps) {
  const location = useLocation();
  const navigate = useNavigate();

  // Extract current previewId from URL if on preview route
  const currentPreviewId = location.pathname.includes("/preview/")
    ? location.pathname.split("/preview/")[1]?.split("/")[0]
    : undefined;

  const addCustomPreview = useMutation(
    api.taskRuns.addCustomPreview
  ).withOptimisticUpdate((localStore, args) => {
    const newPreview = {
      url: args.url,
      createdAt: Date.now(),
    };

    // Update all queries that might have this task run
    const taskRunsQuery = localStore.getQuery(api.taskRuns.getByTask, {
      teamSlugOrId: args.teamSlugOrId,
      taskId,
    });

    if (taskRunsQuery) {
      localStore.setQuery(
        api.taskRuns.getByTask,
        { teamSlugOrId: args.teamSlugOrId, taskId },
        taskRunsQuery.map((r) =>
          r._id === args.runId
            ? {
                ...r,
                customPreviews: [...(r.customPreviews || []), newPreview],
              }
            : r
        )
      );
    }
  });

  const removeCustomPreview = useMutation(
    api.taskRuns.removeCustomPreview
  ).withOptimisticUpdate((localStore, args) => {
    // Update all queries that might have this task run
    const taskRunsQuery = localStore.getQuery(api.taskRuns.getByTask, {
      teamSlugOrId: args.teamSlugOrId,
      taskId,
    });

    if (taskRunsQuery) {
      localStore.setQuery(
        api.taskRuns.getByTask,
        { teamSlugOrId: args.teamSlugOrId, taskId },
        taskRunsQuery.map((r) =>
          r._id === args.runId
            ? {
                ...r,
                customPreviews: (r.customPreviews || []).filter(
                  (_, i) => i !== args.index
                ),
              }
            : r
        )
      );
    }
  });

  const handleAddPreview = useCallback(
    async (url: string): Promise<number> => {
      try {
        const index = await addCustomPreview({
          teamSlugOrId,
          runId: run._id,
          url,
        });
        return index;
      } catch (error) {
        console.error("Failed to add preview", error);
        throw error;
      }
    },
    [addCustomPreview, run._id, teamSlugOrId]
  );

  const handleRemovePreview = useCallback(
    (index: number, currentPreviewId?: string) => {
      void removeCustomPreview({
        teamSlugOrId,
        runId: run._id,
        index,
      }).catch((error) => {
        console.error("Failed to remove preview", error);
      });

      // If we're currently viewing the tab being closed, navigate to another tab
      if (currentPreviewId === String(index)) {
        const remainingPreviews = customPreviews.filter((_, i) => i !== index);

        if (remainingPreviews.length > 0) {
          // Navigate to previous tab (or next if it was the first)
          const nextIndex = index > 0 ? index - 1 : 0;
          void navigate({
            to: "/$teamSlugOrId/task/$taskId/run/$runId/preview/$previewId",
            params: {
              teamSlugOrId,
              taskId,
              runId: run._id,
              previewId: String(nextIndex),
            },
          });
        } else if (previewServices.length > 0) {
          // Navigate to first port preview if available
          void navigate({
            to: "/$teamSlugOrId/task/$taskId/run/$runId/preview/$previewId",
            params: {
              teamSlugOrId,
              taskId,
              runId: run._id,
              previewId: String(previewServices[0].port),
            },
          });
        } else {
          // No tabs left, navigate to main taskrun page
          void navigate({
            to: "/$teamSlugOrId/task/$taskId/run/$runId",
            params: {
              teamSlugOrId,
              taskId,
              runId: run._id,
              taskRunId: run._id,
            },
          });
        }
      }
    },
    [
      removeCustomPreview,
      run._id,
      teamSlugOrId,
      customPreviews,
      previewServices,
      navigate,
      taskId,
    ]
  );

  const handleReloadVSCode = useCallback(() => {
    persistentIframeManager.reloadIframe(getTaskRunPersistKey(run._id));
  }, [run._id]);

  const handleReloadBrowser = useCallback(() => {
    persistentIframeManager.reloadIframe(getTaskRunBrowserPersistKey(run._id));
  }, [run._id]);

  const handleReloadTerminals = useCallback(() => {
    window.location.reload();
  }, []);

  if (!isExpanded) {
    return null;
  }

  const indentLevel = level + 1;
  const hasEnvironmentError = Boolean(
    environmentError?.maintenanceError || environmentError?.devError
  );

  const environmentErrorIndicator = hasEnvironmentError ? (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <AlertTriangle className="w-3 h-3 text-neutral-700" />
      </TooltipTrigger>
      <TooltipContent
        side="right"
        sideOffset={6}
        className="max-w-sm p-3 z-[var(--z-global-blocking)]"
      >
        <div className="space-y-1.5">
          <p className="font-medium text-sm text-neutral-200">Scripts error</p>
          {environmentError?.maintenanceError && (
            <p className="text-xs text-neutral-400">
              Maintenance: {environmentError.maintenanceError}
            </p>
          )}
          {environmentError?.devError && (
            <p className="text-xs text-neutral-400">
              Dev: {environmentError.devError}
            </p>
          )}
        </div>
      </TooltipContent>
    </Tooltip>
  ) : null;

  // Determine loading/error state for the detail links
  const isVSCodeReady = run.vscode?.status === "running";
  const isRunFailed = run.status === "failed";

  // Show error icon with tooltip if run failed, otherwise show loading spinner
  const statusIndicator = isRunFailed ? (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <XCircle className="w-3 h-3 text-red-500" />
      </TooltipTrigger>
      {run.errorMessage ? (
        <TooltipContent
          side="right"
          className="max-w-xs whitespace-pre-wrap break-words"
        >
          {run.errorMessage}
        </TooltipContent>
      ) : null}
    </Tooltip>
  ) : !isVSCodeReady ? (
    <Loader2 className="w-3 h-3 animate-spin text-neutral-400" />
  ) : null;

  // For VSCode, combine environment error with status indicator
  const vscodeTrailing = environmentErrorIndicator || statusIndicator;

  return (
    <Fragment>
      <TaskRunDetailLink
        to="/$teamSlugOrId/task/$taskId/run/$runId/vscode"
        params={{
          teamSlugOrId,
          taskId,
          runId: run._id,
        }}
        icon={
          <VSCodeIcon className="w-3 h-3 mr-2 text-neutral-400 grayscale opacity-60" />
        }
        label="VS Code"
        indentLevel={indentLevel}
        trailing={vscodeTrailing}
        onReload={handleReloadVSCode}
      />

      {!isCloudWorkspace ? (
        <TaskRunDetailLink
          to="/$teamSlugOrId/task/$taskId/run/$runId/diff"
          params={{ teamSlugOrId, taskId, runId: run._id }}
          icon={<GitCompare className="w-3 h-3 mr-2 text-neutral-400" />}
          label="Git diff"
          indentLevel={indentLevel}
        />
      ) : null}

      {!isLocalWorkspace ? (
        <TaskRunDetailLink
          to="/$teamSlugOrId/task/$taskId/run/$runId/browser"
          params={{ teamSlugOrId, taskId, runId: run._id }}
          icon={<Monitor className="w-3 h-3 mr-2 text-neutral-400" />}
          label="Browser"
          indentLevel={indentLevel}
          trailing={statusIndicator}
          onReload={handleReloadBrowser}
        />
      ) : null}

      {!isLocalWorkspace ? (
        <TaskRunDetailLink
          to="/$teamSlugOrId/task/$taskId/run/$runId/terminals"
          params={{ teamSlugOrId, taskId, runId: run._id }}
          icon={<TerminalSquare className="w-3 h-3 mr-2 text-neutral-400" />}
          label="Terminals"
          indentLevel={indentLevel}
          trailing={statusIndicator}
          onReload={handleReloadTerminals}
        />
      ) : null}

      {shouldRenderPullRequestLink ? (
        <TaskRunDetailLink
          to="/$teamSlugOrId/task/$taskId/run/$runId/pr"
          params={{ teamSlugOrId, taskId, runId: run._id }}
          icon={<GitPullRequest className="w-3 h-3 mr-2 text-neutral-400" />}
          label="Pull Request"
          indentLevel={indentLevel}
        />
      ) : null}

      {/* Hide preview ports and custom previews for preview screenshot jobs */}
      {SHOW_PREVIEW_URLS && !run.isPreviewJob && (
        <>
          {previewServices.map((service) => (
            <div key={service.port} className="relative group mt-px">
              <TaskRunDetailLink
                to="/$teamSlugOrId/task/$taskId/run/$runId/preview/$previewId"
                params={{
                  teamSlugOrId,
                  taskId,
                  runId: run._id,
                  previewId: `${service.port}`,
                }}
                icon={
                  <ExternalLink className="w-3 h-3 mr-2 text-neutral-400" />
                }
                label={`Preview (port ${service.port})`}
                indentLevel={indentLevel}
                className="pr-10"
                onClick={(event) => {
                  if (event.metaKey || event.ctrlKey) {
                    event.preventDefault();
                    window.open(service.url, "_blank", "noopener,noreferrer");
                  }
                }}
              />

              <Dropdown.Root>
                <Dropdown.Trigger
                  onClick={(event) => event.stopPropagation()}
                  className={clsx(
                    "absolute right-2 top-1/2 -translate-y-1/2",
                    "p-1 rounded flex items-center gap-1",
                    "bg-neutral-100/80 dark:bg-neutral-700/80",
                    "hover:bg-neutral-200/80 dark:hover:bg-neutral-600/80",
                    "text-neutral-600 dark:text-neutral-400"
                  )}
                >
                  <EllipsisVertical className="w-2.5 h-2.5" />
                </Dropdown.Trigger>
                <Dropdown.Portal>
                  <Dropdown.Positioner
                    sideOffset={8}
                    side={isElectron ? "left" : "bottom"}
                  >
                    <Dropdown.Popup>
                      <Dropdown.Arrow />
                      <Dropdown.Item
                        onClick={() => {
                          window.open(
                            service.url,
                            "_blank",
                            "noopener,noreferrer"
                          );
                        }}
                        className="flex items-center gap-2"
                      >
                        <ExternalLink className="w-3.5 h-3.5" />
                        Open in new tab
                      </Dropdown.Item>
                    </Dropdown.Popup>
                  </Dropdown.Positioner>
                </Dropdown.Portal>
              </Dropdown.Root>
            </div>
          ))}

          {customPreviews.map((preview, index) => (
            <div key={index} className="relative group mt-px">
              <TaskRunDetailLink
                to="/$teamSlugOrId/task/$taskId/run/$runId/preview/$previewId"
                params={{
                  teamSlugOrId,
                  taskId,
                  runId: run._id,
                  previewId: String(index),
                }}
                icon={
                  <ExternalLink className="w-3 h-3 mr-2 text-neutral-400" />
                }
                label={preview.url}
                indentLevel={indentLevel}
                className="pr-10"
                onClick={(event) => {
                  if (event.metaKey || event.ctrlKey) {
                    event.preventDefault();
                    window.open(preview.url, "_blank", "noopener,noreferrer");
                  }
                }}
              />

              <Dropdown.Root>
                <Dropdown.Trigger
                  onClick={(event) => event.stopPropagation()}
                  className={clsx(
                    "absolute right-2 top-1/2 -translate-y-1/2",
                    "p-1 rounded flex items-center gap-1",
                    "bg-neutral-100/80 dark:bg-neutral-700/80",
                    "hover:bg-neutral-200/80 dark:hover:bg-neutral-600/80",
                    "text-neutral-600 dark:text-neutral-400"
                  )}
                >
                  <EllipsisVertical className="w-2.5 h-2.5" />
                </Dropdown.Trigger>
                <Dropdown.Portal>
                  <Dropdown.Positioner
                    sideOffset={8}
                    side={isElectron ? "left" : "bottom"}
                  >
                    <Dropdown.Popup>
                      <Dropdown.Arrow />
                      <Dropdown.Item
                        onClick={() => {
                          window.open(
                            preview.url,
                            "_blank",
                            "noopener,noreferrer"
                          );
                        }}
                        className="flex items-center gap-2"
                      >
                        <ExternalLink className="w-3.5 h-3.5" />
                        Open in new tab
                      </Dropdown.Item>
                      <Dropdown.Item
                        onClick={() =>
                          handleRemovePreview(index, currentPreviewId)
                        }
                        className="flex items-center gap-2 text-red-600 dark:text-red-400"
                      >
                        <Trash2 className="w-3.5 h-3.5" />
                        Remove preview
                      </Dropdown.Item>
                    </Dropdown.Popup>
                  </Dropdown.Positioner>
                </Dropdown.Portal>
              </Dropdown.Root>
            </div>
          ))}

          <AddPreviewInput
            indentLevel={indentLevel}
            onAdd={handleAddPreview}
            currentCount={customPreviews.length}
            taskId={taskId}
            runId={run._id}
            teamSlugOrId={teamSlugOrId}
          />
        </>
      )}

      {hasChildren ? (
        <div className="flex flex-col">
          {run.children.map((childRun) => (
            <TaskRunTree
              key={childRun._id}
              run={childRun}
              level={level + 1}
              taskId={taskId}
              teamSlugOrId={teamSlugOrId}
              onArchiveToggle={onArchiveToggle}
              showRunNumbers={showRunNumbers}
            />
          ))}
        </div>
      ) : null}
    </Fragment>
  );
}

export interface VSCodeIconProps {
  className?: string;
}

// Prevent unnecessary re-renders of large trees during unrelated state changes
export const TaskTree = memo(TaskTreeInner);
const TaskRunTree = memo(TaskRunTreeInner);

export type { AnnotatedTaskRun, TaskRunWithChildren } from "./task-tree/types";
