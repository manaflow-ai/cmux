import { api } from "@cmux/convex/api";
import { type Doc, type Id } from "@cmux/convex/dataModel";
import type { RunEnvironmentSummary } from "@/types/task";
import { useUser } from "@stackframe/react";
import { Link, useParams, useNavigate } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { formatDistanceToNow } from "date-fns";
import {
  AlertCircle,
  CheckCircle2,
  Clock,
  FileText,
  Play,
  Shield,
  Sparkles,
  Trophy,
  XCircle,
} from "lucide-react";
import { useMemo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import CmuxLogoMark from "./logo/cmux-logo-mark";
import { TaskMessage } from "./task-message";

type TaskRunStatus = "pending" | "running" | "completed" | "failed" | "skipped";

interface TimelineEvent {
  id: string;
  type:
    | "task_created"
    | "run_started"
    | "run_completed"
    | "run_failed"
    | "run_skipped"
    | "crown_evaluation";
  timestamp: number;
  runId?: Id<"taskRuns">;
  agentName?: string;
  status?: TaskRunStatus;
  exitCode?: number;
  isCrowned?: boolean;
  crownReason?: string;
  summary?: string;
  userId?: string;
  // New fields for enhanced activity bar
  screenshotUrl?: string | null;
  screenshotCapturedAt?: number;
}

interface CodeReviewFileSummary {
  filePath: string;
  summary: string | null;
  criticalCount: number;
  warningCount: number;
}

interface CodeReviewSummary {
  state: "pending" | "running" | "completed" | "failed" | "error";
  filesReviewed: number;
  criticalCount: number;
  warningCount: number;
  infoCount: number;
  totalFindings: number;
  topFiles?: CodeReviewFileSummary[];
}

type TaskRunWithChildren = Doc<"taskRuns"> & {
  children?: TaskRunWithChildren[];
  environment?: RunEnvironmentSummary | null;
};

interface TaskTimelineProps {
  task?: Doc<"tasks"> | null;
  taskRuns: TaskRunWithChildren[] | null;
  crownEvaluation?: {
    evaluatedAt?: number;
    winnerRunId?: Id<"taskRuns">;
    reason?: string;
  } | null;
  // New props for enhanced activity bar
  screenshotUrls?: Record<string, { url: string | null; capturedAt: number } | null>;
  codeReviewSummary?: CodeReviewSummary | null;
}

export function TaskTimeline({
  task,
  taskRuns,
  crownEvaluation,
  screenshotUrls,
  codeReviewSummary,
}: TaskTimelineProps) {
  const user = useUser();
  const navigate = useNavigate();
  const params = useParams({ from: "/_layout/$teamSlugOrId/task/$taskId" });
  const taskComments = useQuery(api.taskComments.listByTask, {
    teamSlugOrId: params.teamSlugOrId,
    taskId: params.taskId as Id<"tasks">,
  });

  const events = useMemo(() => {
    const timelineEvents: TimelineEvent[] = [];

    // Add task creation event
    if (task?.createdAt) {
      timelineEvents.push({
        id: "task-created",
        type: "task_created",
        timestamp: task.createdAt,
        userId: task.userId,
      });
    }

    if (!taskRuns) return timelineEvents;

    // Flatten the tree structure to get all runs
    const flattenRuns = (runs: TaskRunWithChildren[]): Doc<"taskRuns">[] => {
      const result: Doc<"taskRuns">[] = [];
      runs.forEach((run) => {
        result.push(run);
        if (run.children?.length) {
          result.push(...flattenRuns(run.children));
        }
      });
      return result;
    };

    const allRuns = flattenRuns(taskRuns);

    // Add run events
    allRuns.forEach((run) => {
      // Run started event
      timelineEvents.push({
        id: `${run._id}-start`,
        type: "run_started",
        timestamp: run.createdAt,
        runId: run._id,
        agentName: run.agentName,
        status: run.status,
      });

      // Run completed/failed event
      if (run.completedAt) {
        const endEventType: TimelineEvent["type"] =
          run.status === "failed"
            ? "run_failed"
            : run.status === "skipped"
              ? "run_skipped"
              : "run_completed";

        // Get screenshot URL for this run
        const screenshotData = screenshotUrls?.[run._id];

        timelineEvents.push({
          id: `${run._id}-end`,
          type: endEventType,
          timestamp: run.completedAt,
          runId: run._id,
          agentName: run.agentName,
          status: run.status,
          exitCode: run.exitCode,
          summary: run.summary,
          isCrowned: run.isCrowned,
          crownReason: run.crownReason,
          screenshotUrl: screenshotData?.url ?? null,
          screenshotCapturedAt: screenshotData?.capturedAt,
        });
      }
    });

    // Add crown evaluation event if exists
    if (crownEvaluation?.evaluatedAt) {
      timelineEvents.push({
        id: "crown-evaluation",
        type: "crown_evaluation",
        timestamp: crownEvaluation.evaluatedAt,
        runId: crownEvaluation.winnerRunId,
        crownReason: crownEvaluation.reason,
      });
    }

    // Sort by timestamp
    return timelineEvents.sort((a, b) => a.timestamp - b.timestamp);
  }, [task, taskRuns, crownEvaluation, screenshotUrls]);

  if (!events.length && !task) {
    return (
      <div className="flex items-center justify-center py-12 text-neutral-500">
        <Clock className="h-5 w-5 mr-2" />
        <span className="text-sm">No activity yet</span>
      </div>
    );
  }

  const ActivityEvent = ({ event }: { event: TimelineEvent }) => {
    const agentName = event.agentName || "Agent";

    let icon;
    let content;

    switch (event.type) {
      case "task_created":
        icon = (
          <img
            src={user?.profileImageUrl || ""}
            alt={user?.primaryEmail || "User"}
            className="size-4 rounded-full"
          />
        );
        content = (
          <>
            <span className="font-medium text-neutral-900 dark:text-neutral-100">
              {user?.displayName || user?.primaryEmail || "User"}
            </span>
            <span className="text-neutral-600 dark:text-neutral-400">
              {" "}
              created the task
            </span>
            <span className="text-neutral-500 dark:text-neutral-500 ml-1">
              {formatDistanceToNow(event.timestamp, { addSuffix: true })}
            </span>
          </>
        );
        break;
      case "run_started":
        icon = (
          <div className="size-4 rounded-full bg-blue-100 dark:bg-blue-900/30 flex items-center justify-center">
            <Play className="size-[9px] text-blue-600 dark:text-blue-400" />
          </div>
        );
        content = event.runId ? (
          <Link
            to="/$teamSlugOrId/task/$taskId/run/$runId"
            params={{
              teamSlugOrId: params.teamSlugOrId,
              taskId: params.taskId,
              runId: event.runId,
              taskRunId: event.runId,
            }}
            className="hover:underline inline"
          >
            <span className="font-medium text-neutral-900 dark:text-neutral-100">
              {agentName}
            </span>
            <span className="text-neutral-600 dark:text-neutral-400">
              {" "}
              started working
            </span>
            <span className="text-neutral-500 dark:text-neutral-500 ml-1">
              {formatDistanceToNow(event.timestamp, { addSuffix: true })}
            </span>
          </Link>
        ) : (
          <>
            <span className="font-medium text-neutral-900 dark:text-neutral-100">
              {agentName}
            </span>
            <span className="text-neutral-600 dark:text-neutral-400">
              {" "}
              started working
            </span>
            <span className="text-neutral-500 dark:text-neutral-500 ml-1">
              {formatDistanceToNow(event.timestamp, { addSuffix: true })}
            </span>
          </>
        );
        break;
      case "run_completed":
        icon = event.isCrowned ? (
          <div className="size-4 rounded-full bg-amber-100 dark:bg-amber-900/30 flex items-center justify-center">
            <Trophy className="size-2.5 text-amber-600 dark:text-amber-400" />
          </div>
        ) : (
          <div className="size-4 rounded-full bg-green-100 dark:bg-green-900/30 flex items-center justify-center">
            <CheckCircle2 className="size-2.5 text-green-600 dark:text-green-400" />
          </div>
        );
        content = (
          <>
            {event.runId ? (
              <Link
                to="/$teamSlugOrId/task/$taskId/run/$runId"
                params={{
                  teamSlugOrId: params.teamSlugOrId,
                  taskId: params.taskId,
                  runId: event.runId,
                  taskRunId: event.runId,
                }}
                className="hover:underline inline"
              >
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {event.isCrowned
                    ? " completed and won the crown"
                    : " completed"}
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </Link>
            ) : (
              <>
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {event.isCrowned
                    ? " completed and won the crown"
                    : " completed"}
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </>
            )}
            {/* Summary with markdown support */}
            {event.summary && (
              <div className="mt-3 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50/50 dark:bg-neutral-900/50 p-3">
                <div className="flex items-start gap-2">
                  <FileText className="size-3.5 mt-0.5 text-neutral-500 dark:text-neutral-400 shrink-0" />
                  <div className="text-sm text-neutral-700 dark:text-neutral-300 prose prose-sm prose-neutral dark:prose-invert max-w-none prose-p:my-1 prose-headings:my-1.5">
                    <ReactMarkdown remarkPlugins={[remarkGfm]}>
                      {event.summary}
                    </ReactMarkdown>
                  </div>
                </div>
              </div>
            )}

            {/* Code review summary card - shown for crowned runs */}
            {event.isCrowned && codeReviewSummary && (
              <div className="mt-3 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50/50 dark:bg-neutral-900/50 overflow-hidden">
                {/* Header */}
                <div className="flex items-center gap-2 px-3 py-2 border-b border-neutral-200 dark:border-neutral-800">
                  <Shield className="size-4 text-blue-600 dark:text-blue-400" />
                  <span className="text-sm font-medium text-neutral-700 dark:text-neutral-200">
                    Code Review
                  </span>
                  <span className={`ml-auto text-xs px-1.5 py-0.5 rounded ${
                    codeReviewSummary.state === "completed"
                      ? "bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400"
                      : codeReviewSummary.state === "running" || codeReviewSummary.state === "pending"
                        ? "bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400"
                        : "bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400"
                  }`}>
                    {codeReviewSummary.state}
                  </span>
                </div>

                {/* Overall stats */}
                {codeReviewSummary.state === "completed" && (
                  <div className="px-3 py-2 border-b border-neutral-200 dark:border-neutral-800 flex gap-4 text-xs bg-neutral-100/50 dark:bg-neutral-800/50">
                    {codeReviewSummary.criticalCount > 0 && (
                      <span className="flex items-center gap-1 text-red-600 dark:text-red-400">
                        <AlertCircle className="size-3" />
                        {codeReviewSummary.criticalCount} critical
                      </span>
                    )}
                    {codeReviewSummary.warningCount > 0 && (
                      <span className="flex items-center gap-1 text-amber-600 dark:text-amber-400">
                        <AlertCircle className="size-3" />
                        {codeReviewSummary.warningCount} warnings
                      </span>
                    )}
                    {codeReviewSummary.totalFindings === 0 && (
                      <span className="text-green-600 dark:text-green-400">
                        No issues found
                      </span>
                    )}
                    <span className="text-neutral-500 dark:text-neutral-400 ml-auto">
                      {codeReviewSummary.filesReviewed} files reviewed
                    </span>
                  </div>
                )}

                {/* File-level findings */}
                {codeReviewSummary.state === "completed" &&
                  codeReviewSummary.topFiles &&
                  codeReviewSummary.topFiles.length > 0 && (
                    <div className="divide-y divide-neutral-200 dark:divide-neutral-800">
                      {codeReviewSummary.topFiles.map((file) => (
                        <div
                          key={file.filePath}
                          className="px-3 py-2 text-xs"
                        >
                          <div className="flex items-center gap-2">
                            <code className="font-mono text-neutral-700 dark:text-neutral-300 truncate flex-1">
                              {file.filePath}
                            </code>
                            {(file.criticalCount > 0 || file.warningCount > 0) && (
                              <div className="flex gap-2 shrink-0">
                                {file.criticalCount > 0 && (
                                  <span className="text-red-600 dark:text-red-400">
                                    {file.criticalCount} critical
                                  </span>
                                )}
                                {file.warningCount > 0 && (
                                  <span className="text-amber-600 dark:text-amber-400">
                                    {file.warningCount} warning
                                  </span>
                                )}
                              </div>
                            )}
                          </div>
                          {file.summary && (
                            <p className="mt-1 text-neutral-600 dark:text-neutral-400 line-clamp-2">
                              {file.summary}
                            </p>
                          )}
                        </div>
                      ))}
                    </div>
                  )}
              </div>
            )}

            {/* Screenshot thumbnail */}
            {event.screenshotUrl && (
              <div className="mt-3">
                <button
                  type="button"
                  onClick={() => {
                    if (event.runId) {
                      void navigate({
                        to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
                        params: {
                          teamSlugOrId: params.teamSlugOrId,
                          taskId: params.taskId,
                          runId: event.runId,
                        },
                      });
                    }
                  }}
                  className="block rounded-lg border border-neutral-200 dark:border-neutral-800 overflow-hidden hover:border-neutral-400 dark:hover:border-neutral-600 transition-colors"
                >
                  <img
                    src={event.screenshotUrl}
                    alt="Screenshot preview"
                    className="w-full max-w-[200px] h-auto"
                    loading="lazy"
                  />
                </button>
                {event.screenshotCapturedAt && (
                  <div className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                    Captured {formatDistanceToNow(event.screenshotCapturedAt, { addSuffix: true })}
                  </div>
                )}
              </div>
            )}
          </>
        );
        break;
      case "run_failed":
        icon = (
          <div className="size-4 rounded-full bg-red-100 dark:bg-red-900/30 flex items-center justify-center">
            <XCircle className="size-2.5 text-red-600 dark:text-red-400" />
          </div>
        );
        content = (
          <>
            {event.runId ? (
              <Link
                to="/$teamSlugOrId/task/$taskId/run/$runId"
                params={{
                  teamSlugOrId: params.teamSlugOrId,
                  taskId: params.taskId,
                  runId: event.runId,
                  taskRunId: event.runId,
                }}
                className="hover:underline inline"
              >
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  failed
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </Link>
            ) : (
              <>
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  failed
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </>
            )}
            {event.exitCode !== undefined && event.exitCode !== 0 && (
              <div className="mt-1 text-xs text-red-600 dark:text-red-400">
                Exit code: {event.exitCode}
              </div>
            )}
          </>
        );
        break;
      case "run_skipped":
        icon = (
          <div className="size-4 rounded-full bg-amber-100 dark:bg-amber-900/30 flex items-center justify-center">
            <AlertCircle className="size-2.5 text-amber-600 dark:text-amber-400" />
          </div>
        );
        content = (
          <>
            {event.runId ? (
              <Link
                to="/$teamSlugOrId/task/$taskId/run/$runId"
                params={{
                  teamSlugOrId: params.teamSlugOrId,
                  taskId: params.taskId,
                  runId: event.runId,
                  taskRunId: event.runId,
                }}
                className="hover:underline inline"
              >
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  skipped execution
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </Link>
            ) : (
              <>
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  {agentName}
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  skipped execution
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </>
            )}
          </>
        );
        break;
      case "crown_evaluation":
        icon = (
          <div className="size-4 rounded-full bg-purple-100 dark:bg-purple-900/30 flex items-center justify-center">
            <Sparkles className="size-2.5 text-purple-600 dark:text-purple-400" />
          </div>
        );
        content = (
          <>
            {event.runId ? (
              <Link
                to="/$teamSlugOrId/task/$taskId/run/$runId"
                params={{
                  teamSlugOrId: params.teamSlugOrId,
                  taskId: params.taskId,
                  runId: event.runId,
                  taskRunId: event.runId,
                }}
                className="hover:underline inline"
              >
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  Crown evaluation
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  completed
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </Link>
            ) : (
              <>
                <span className="font-medium text-neutral-900 dark:text-neutral-100">
                  Crown evaluation
                </span>
                <span className="text-neutral-600 dark:text-neutral-400">
                  {" "}
                  completed
                </span>
                <span className="text-neutral-500 dark:text-neutral-500 ml-1">
                  {formatDistanceToNow(event.timestamp, { addSuffix: true })}
                </span>
              </>
            )}
            {event.crownReason && (
              <div className="mt-2 text-[13px] text-purple-700 dark:text-purple-400 bg-purple-50 dark:bg-purple-900/20 rounded-md p-3">
                {event.crownReason}
              </div>
            )}
          </>
        );
        break;
      default:
        icon = (
          <div className="size-4 rounded-full bg-neutral-100 dark:bg-neutral-800 flex items-center justify-center">
            <AlertCircle className="size-2.5 text-neutral-600 dark:text-neutral-400" />
          </div>
        );
        content = (
          <>
            <span className="text-neutral-600 dark:text-neutral-400">
              Unknown event
            </span>
            <span className="text-neutral-500 dark:text-neutral-500 ml-1">
              {formatDistanceToNow(event.timestamp, { addSuffix: true })}
            </span>
          </>
        );
    }

    return (
      <>
        <div className="shrink-0 flex items-start justify-center">{icon}</div>
        <div className="flex-1 min-w-0 flex items-center">
          <div className="text-xs">
            <div>{content}</div>
          </div>
        </div>
      </>
    );
  };

  return (
    <div className="space-y-2">
      {/* Prompt Message */}
      {task?.text && (
        <TaskMessage
          authorName={
            user?.displayName || user?.primaryEmail?.split("@")[0] || "User"
          }
          authorImageUrl={user?.profileImageUrl || ""}
          authorAlt={user?.primaryEmail || "User"}
          timestamp={task.createdAt}
          content={task.text}
        />
      )}

      <div>
        {/* Timeline Events */}
        <div className="space-y-4 pl-5">
          {events.map((event, index) => (
            <div key={event.id} className="relative flex gap-3">
              <ActivityEvent event={event} />
              {index < events.length - 1 && (
                <div className="absolute left-1.5 top-5 -bottom-3 w-px transform translate-x-[1px] bg-neutral-200 dark:bg-neutral-800" />
              )}
            </div>
          ))}
        </div>
      </div>
      {/* Task Comments (chronological) */}
      {taskComments && taskComments.length > 0 ? (
        <div className="space-y-2 pt-2">
          {taskComments.map((c) => (
            <TaskMessage
              key={c._id}
              authorName={
                c.userId === "cmux"
                  ? "cmux"
                  : user?.displayName ||
                    user?.primaryEmail?.split("@")[0] ||
                    "User"
              }
              avatar={
                c.userId === "cmux" ? (
                  <CmuxLogoMark height={20} label="cmux" />
                ) : undefined
              }
              authorImageUrl={
                c.userId === "cmux" ? undefined : user?.profileImageUrl || ""
              }
              authorAlt={
                c.userId === "cmux" ? "cmux" : user?.primaryEmail || "User"
              }
              timestamp={c.createdAt}
              content={c.content}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
