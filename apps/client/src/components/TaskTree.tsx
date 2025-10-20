import { Dropdown } from "@/components/ui/dropdown";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { useArchiveTask } from "@/hooks/useArchiveTask";
import { useOpenWithActions } from "@/hooks/useOpenWithActions";
import { isElectron } from "@/lib/electron";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import type { AnnotatedTaskRun, TaskRunWithChildren } from "@/types/task";
import { ContextMenu } from "@base-ui-components/react/context-menu";
import { api } from "@cmux/convex/api";
import { type Doc, type Id } from "@cmux/convex/dataModel";
import { Link, useLocation, type LinkProps } from "@tanstack/react-router";
import clsx from "clsx";
import { useQuery as useConvexQuery } from "convex/react";
import {
  AlertTriangle,
  Archive as ArchiveIcon,
  ArchiveRestore as ArchiveRestoreIcon,
  CheckCircle,
  Circle,
  Copy as CopyIcon,
  Crown,
  EllipsisVertical,
  ExternalLink,
  GitBranch,
  GitCompare,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  Globe,
  Monitor,
  Loader2,
  Terminal as TerminalIcon,
  XCircle,
} from "lucide-react";
import {
  Fragment,
  createContext,
  memo,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
  type ReactNode,
} from "react";
import { VSCodeIcon } from "./icons/VSCodeIcon";
import { SidebarListItem } from "./sidebar/SidebarListItem";
import { annotateAgentOrdinals } from "./task-tree/annotateAgentOrdinals";

type PreviewService = NonNullable<TaskRunWithChildren["networking"]>[number];

type TaskWithGeneratedBranch = Doc<"tasks"> & {
  generatedBranchName?: string | null;
};

function sanitizeBranchName(input?: string | null): string | null {
  if (!input) return null;
  const trimmed = input.trim();
  if (!trimmed) return null;
  const idx = trimmed.lastIndexOf("-");
  if (idx <= 0) return trimmed;
  const candidate = trimmed.slice(0, idx);
  return candidate || trimmed;
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
}: TaskTreeProps) {
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
  const prefetched = useRef(false);
  const prefetchTaskRuns = useCallback(() => {
    if (prefetched.current || isFakeConvexId(task._id)) {
      return;
    }
    prefetched.current = true;
    void convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.getByTask,
      args: { teamSlugOrId, taskId: task._id },
    });
  }, [task._id, teamSlugOrId]);

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

  const { archiveWithUndo, unarchive } = useArchiveTask(teamSlugOrId);

  const handleCopyDescription = useCallback(() => {
    if (navigator?.clipboard?.writeText) {
      navigator.clipboard.writeText(task.text).catch(() => { });
    }
  }, [task.text]);

  const handleArchive = useCallback(() => {
    archiveWithUndo(task);
  }, [archiveWithUndo, task]);

  const handleUnarchive = useCallback(() => {
    unarchive(task._id);
  }, [unarchive, task._id]);

  const inferredBranch = getTaskBranch(task);
  const taskSecondaryParts: string[] = [];
  if (inferredBranch) {
    taskSecondaryParts.push(inferredBranch);
  }
  if (task.projectFullName) {
    taskSecondaryParts.push(task.projectFullName);
  }
  const taskSecondary = taskSecondaryParts.join(" • ");

  const canExpand = true;

  const taskLeadingIcon = (() => {
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

    return task.isCompleted ? (
      <CheckCircle className="w-3 h-3 text-green-500" />
    ) : (
      <Circle className="w-3 h-3 text-neutral-400 animate-pulse" />
    );
  })();

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
              className="group block"
              onMouseEnter={handlePrefetch}
              onFocus={handlePrefetch}
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
                handleToggle(event);
              }}
            >
              <SidebarListItem
                paddingLeft={10 + level * 4}
                toggle={{
                  expanded: isExpanded,
                  onToggle: handleToggle,
                  visible: canExpand,
                }}
                title={task.pullRequestTitle || task.text}
                titleClassName="text-[13px] text-neutral-900 dark:text-neutral-100"
                secondary={taskSecondary || undefined}
                meta={taskLeadingIcon || undefined}
              />
            </Link>
          </ContextMenu.Trigger>
          <ContextMenu.Portal>
            <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
              <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
                <ContextMenu.Item
                  className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                  onClick={handleCopyDescription}
                >
                  <CopyIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                  <span>Copy Description</span>
                </ContextMenu.Item>
                {task.isArchived ? (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleUnarchive}
                  >
                    <ArchiveRestoreIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Unarchive Task</span>
                  </ContextMenu.Item>
                ) : (
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={handleArchive}
                  >
                    <ArchiveIcon className="w-3.5 h-3.5 text-neutral-600 dark:text-neutral-300" />
                    <span>Archive Task</span>
                  </ContextMenu.Item>
                )}
              </ContextMenu.Popup>
            </ContextMenu.Positioner>
          </ContextMenu.Portal>
        </ContextMenu.Root>

        {isExpanded ? (
          <TaskRunsContent
            taskId={task._id}
            teamSlugOrId={teamSlugOrId}
            level={level}
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
}

function TaskRunsContent({
  taskId,
  teamSlugOrId,
  level,
}: TaskRunsContentProps) {
  const optimisticTask = isFakeConvexId(taskId);
  const runs = useConvexQuery(
    api.taskRuns.getByTask,
    optimisticTask ? "skip" : { teamSlugOrId, taskId }
  );

  const annotatedRuns = useMemo(
    () => (runs && runs.length > 0 ? annotateAgentOrdinals(runs) : []),
    [runs]
  );

  if (optimisticTask) {
    return (
      <TaskRunsMessage level={level}>
        <span className="italic">No task runs yet</span>
      </TaskRunsMessage>
    );
  }

  if (runs === undefined) {
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

  return (
    <div className="flex flex-col">
      {annotatedRuns.map((run) => (
        <TaskRunTree
          key={run._id}
          run={run}
          level={level + 1}
          taskId={taskId}
          teamSlugOrId={teamSlugOrId}
        />
      ))}
    </div>
  );
}

function TaskRunsMessage({
  level,
  children,
}: {
  level: number;
  children: ReactNode;
}) {
  const paddingLeft = 10 + (level + 1) * 16;
  return (
    <div
      className="flex items-center gap-2 py-2 text-xs text-neutral-500 dark:text-neutral-400 select-none"
      style={{ paddingLeft }}
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
}

function TaskRunTreeInner({
  run,
  level,
  taskId,
  teamSlugOrId,
}: TaskRunTreeProps) {
  const { expandedRuns, setRunExpanded } = useTaskRunExpansionContext();
  const defaultExpanded = Boolean(run.isCrowned);
  const isExpanded = expandedRuns[run._id] ?? defaultExpanded;
  const hasChildren = run.children.length > 0;

  // Memoize the display text to avoid recalculating on every render
  const displayText = useMemo(() => {
    const base = getRunDisplayText(run);
    if (!run.hasDuplicateAgentName) {
      return base;
    }
    const ordinal = run.agentOrdinal;
    return ordinal ? `${base} (${ordinal})` : base;
  }, [run]);

  // Memoize the toggle handler
  const handleToggle = useCallback(
    (_event?: MouseEvent<HTMLButtonElement | HTMLAnchorElement>) => {
      setRunExpanded(run._id, !isExpanded);
    },
    [isExpanded, run._id, setRunExpanded]
  );

  const statusIcon = {
    pending: <Circle className="w-3 h-3 text-neutral-400" />,
    running: <Loader2 className="w-3 h-3 text-blue-500 animate-spin" />,
    completed: <CheckCircle className="w-3 h-3 text-green-500" />,
    failed: <XCircle className="w-3 h-3 text-red-500" />,
  }[run.status];

  const runLeadingIcon =
    run.status === "failed" && run.errorMessage ? (
      <Tooltip>
        <TooltipTrigger asChild>{statusIcon}</TooltipTrigger>
        <TooltipContent
          side="right"
          className="max-w-xs whitespace-pre-wrap break-words"
        >
          {run.errorMessage}
        </TooltipContent>
      </Tooltip>
    ) : (
      statusIcon
    );

  const crownIcon = run.isCrowned ? (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <Crown className="w-3 h-3 text-yellow-500" />
      </TooltipTrigger>
      {run.crownReason ? (
        <TooltipContent
          side="right"
          sideOffset={6}
          className="max-w-sm p-3 z-[var(--z-overlay)]"
        >
          <div className="space-y-1.5">
            <p className="font-medium text-sm text-neutral-200">Evaluation Reason</p>
            <p className="text-xs text-neutral-400">{run.crownReason}</p>
          </div>
        </TooltipContent>
      ) : null}
    </Tooltip>
  ) : null;

  const leadingContent = crownIcon ? (
    <div className="flex items-center gap-1">
      {crownIcon}
      {runLeadingIcon}
    </div>
  ) : (
    runLeadingIcon
  );

  // Generate VSCode URL if available
  const hasActiveVSCode = run.vscode?.status === "running";
  const vscodeUrl = useMemo(
    () => (hasActiveVSCode && run.vscode?.url) || null,
    [hasActiveVSCode, run]
  );

  // Collect running preview ports
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
    worktreePath: run.worktreePath,
    branch: run.newBranch,
    networking: run.networking,
  });

  const shouldRenderDiffLink = true;
  const shouldRenderBrowserLink = run.vscode?.provider === "morph";
  const shouldRenderPullRequestLink = Boolean(
    (run.pullRequestUrl && run.pullRequestUrl !== "pending") ||
    run.pullRequests?.some((pr) => pr.url)
  );
  const shouldRenderPreviewLink = previewServices.length > 0;
  const hasOpenWithActions = openWithActions.length > 0;
  const hasPortActions = portActions.length > 0;
  const canCopyBranch = Boolean(copyRunBranch);
  const shouldShowCopyDivider =
    canCopyBranch && (hasOpenWithActions || hasPortActions);
  const shouldShowOpenWithDivider = hasOpenWithActions && hasPortActions;
  const hasCollapsibleContent =
    hasChildren ||
    hasActiveVSCode ||
    shouldRenderDiffLink ||
    shouldRenderBrowserLink ||
    shouldRenderPullRequestLink ||
    shouldRenderPreviewLink;

  return (
    <Fragment>
      <ContextMenu.Root>
        <ContextMenu.Trigger>
          <div
            onClick={() => {
              if (!hasCollapsibleContent) {
                return;
              }
              handleToggle();
            }}
          >
            <SidebarListItem
              containerClassName="mt-px"
              paddingLeft={10 + level * 16}
              toggle={{
                expanded: isExpanded,
                onToggle: handleToggle,
                visible: hasCollapsibleContent,
              }}
              title={displayText}
              titleClassName="text-[13px] text-neutral-700 dark:text-neutral-300"
              meta={leadingContent}
            />
          </div>
        </ContextMenu.Trigger>
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="outline-none z-[var(--z-context-menu)]">
            <ContextMenu.Popup className="origin-[var(--transform-origin)] rounded-md bg-white dark:bg-neutral-800 py-1 text-neutral-900 dark:text-neutral-100 shadow-lg shadow-gray-200 outline-1 outline-neutral-200 transition-[opacity] data-[ending-style]:opacity-0 dark:shadow-none dark:-outline-offset-1 dark:outline-neutral-700">
              {canCopyBranch ? (
                <>
                  <ContextMenu.Item
                    className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                    onClick={copyRunBranch}
                  >
                    <GitBranch className="w-3.5 h-3.5" />
                    Copy branch name
                  </ContextMenu.Item>
                  {shouldShowCopyDivider ? (
                    <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                  ) : null}
                </>
              ) : null}
              {hasOpenWithActions ? (
                <>
                  <div className="px-3 py-1 text-[11px] font-medium text-neutral-500 dark:text-neutral-400 select-none">
                    Open with
                  </div>
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
                  {shouldShowOpenWithDivider ? (
                    <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                  ) : null}
                </>
              ) : null}
              {hasPortActions ? (
                <>
                  <div className="px-3 py-1 text-[11px] font-medium text-neutral-500 dark:text-neutral-400 select-none">
                    Forwarded ports
                  </div>
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
                  <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                </>
              ) : null}
              <ContextMenu.Item
                className="flex items-center gap-2 cursor-default py-1.5 pr-8 pl-3 text-[13px] leading-5 outline-none select-none data-[highlighted]:relative data-[highlighted]:z-0 data-[highlighted]:text-white data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0 data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-700"
                onClick={() => setRunExpanded(run._id, !isExpanded)}
              >
                {isExpanded ? "Collapse details" : "Expand details"}
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
      hasActiveVSCode={hasActiveVSCode}
      hasChildren={hasChildren}
      shouldRenderBrowserLink={shouldRenderBrowserLink}
      shouldRenderPullRequestLink={shouldRenderPullRequestLink}
      previewServices={previewServices}
      environmentError={run.environmentError}
    />
    </Fragment>
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
}: TaskRunDetailLinkProps) {
  return (
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
        <span className="ml-2 flex shrink-0 items-center">{trailing}</span>
      ) : null}
    </Link>
  );
}

interface TaskRunDetailsProps {
  run: AnnotatedTaskRun;
  level: number;
  taskId: Id<"tasks">;
  teamSlugOrId: string;
  isExpanded: boolean;
  hasActiveVSCode: boolean;
  hasChildren: boolean;
  shouldRenderBrowserLink: boolean;
  shouldRenderPullRequestLink: boolean;
  previewServices: PreviewService[];
  environmentError?: {
    maintenanceError?: string;
    devError?: string;
  };
}

function TaskRunDetails({
  run,
  level,
  taskId,
  teamSlugOrId,
  isExpanded,
  hasActiveVSCode,
  hasChildren,
  shouldRenderBrowserLink,
  shouldRenderPullRequestLink,
  previewServices,
  environmentError,
}: TaskRunDetailsProps) {
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
        className="max-w-sm p-3 z-[var(--z-overlay)]"
      >
        <div className="space-y-1.5">
          <p className="font-medium text-sm text-neutral-200">Environment Issue</p>
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

  return (
    <Fragment>
      {hasActiveVSCode && (
        <TaskRunDetailLink
          to="/$teamSlugOrId/task/$taskId/run/$runId"
          params={{
            teamSlugOrId,
            taskId,
            runId: run._id,
            taskRunId: run._id,
          }}
          icon={
            <VSCodeIcon className="w-3 h-3 mr-2 text-neutral-400 grayscale opacity-60" />
          }
          label="VS Code"
          indentLevel={indentLevel}
          trailing={environmentErrorIndicator}
        />
      )}

      <TaskRunDetailLink
        to="/$teamSlugOrId/task/$taskId/run/$runId/diff"
        params={{ teamSlugOrId, taskId, runId: run._id }}
      icon={<GitCompare className="w-3 h-3 mr-2 text-neutral-400" />}
      label="Git diff"
      indentLevel={indentLevel}
    />

    {shouldRenderBrowserLink ? (
      <TaskRunDetailLink
        to="/$teamSlugOrId/task/$taskId/run/$runId/browser"
        params={{ teamSlugOrId, taskId, runId: run._id }}
        icon={<Monitor className="w-3 h-3 mr-2 text-neutral-400" />}
        label="Browser"
        indentLevel={indentLevel}
      />
    ) : null}

    <TaskRunDetailLink
      to="/$teamSlugOrId/task/$taskId/run/$runId/terminals"
      params={{ teamSlugOrId, taskId, runId: run._id }}
      icon={<TerminalIcon className="w-3 h-3 mr-2 text-neutral-400" />}
      label="Terminals"
      indentLevel={indentLevel}
    />

    {shouldRenderPullRequestLink ? (
      <TaskRunDetailLink
        to="/$teamSlugOrId/task/$taskId/run/$runId/pr"
        params={{ teamSlugOrId, taskId, runId: run._id }}
        icon={<GitPullRequest className="w-3 h-3 mr-2 text-neutral-400" />}
          label="Pull Request"
          indentLevel={indentLevel}
        />
      ) : null}

      {previewServices.map((service) => (
        <div key={service.port} className="relative group mt-px">
          <TaskRunDetailLink
            to="/$teamSlugOrId/task/$taskId/run/$runId/preview/$port"
            params={{
              teamSlugOrId,
              taskId,
              runId: run._id,
              port: `${service.port}`,
            }}
            icon={<ExternalLink className="w-3 h-3 mr-2 text-neutral-400" />}
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
                      window.open(service.url, "_blank", "noopener,noreferrer");
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

      {hasChildren ? (
        <div className="flex flex-col">
          {run.children.map((childRun) => (
            <TaskRunTree
              key={childRun._id}
              run={childRun}
              level={level + 1}
              taskId={taskId}
              teamSlugOrId={teamSlugOrId}
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
