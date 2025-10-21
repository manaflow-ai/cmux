import { api } from "@cmux/convex/api";
import { type Doc, type Id } from "@cmux/convex/dataModel";
import type { RunEnvironmentSummary } from "@/types/task";
import { useUser } from "@stackframe/react";
import { Link, useParams } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { formatDistanceToNow } from "date-fns";
import {
  AlertCircle,
  CheckCircle2,
  Clock,
  Loader2,
  Play,
  Sparkles,
  Trophy,
  XCircle,
} from "lucide-react";
import { useMemo } from "react";
import CmuxLogoMark from "./logo/cmux-logo-mark";
import { TaskMessage } from "./task-message";

interface TimelineEvent {
  id: string;
  type:
    | "task_created"
    | "run_started"
    | "run_completed"
    | "run_failed"
    | "crown_evaluation";
  timestamp: number;
  runId?: Id<"taskRuns">;
  agentName?: string;
  status?: "pending" | "running" | "completed" | "failed";
  exitCode?: number;
  isCrowned?: boolean;
  crownReason?: string;
  summary?: string;
  userId?: string;
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
}

type CrownEvaluationStatus =
  | {
      state: "pending" | "running";
      title: string;
      description: string;
      detail?: string;
    }
  | {
      state: "error";
      title: string;
      description: string;
    };

type TaskRunStats = {
  total: number;
  completed: number;
  running: number;
  failed: number;
};

function flattenTaskRuns(runs: TaskRunWithChildren[]): Doc<"taskRuns">[] {
  const result: Doc<"taskRuns">[] = [];
  for (const run of runs) {
    result.push(run);
    if (run.children?.length) {
      result.push(...flattenTaskRuns(run.children));
    }
  }
  return result;
}

function pluralize(count: number, singular: string, plural?: string): string {
  if (count === 1) {
    return singular;
  }
  return plural ?? `${singular}s`;
}

export function TaskTimeline({
  task,
  taskRuns,
  crownEvaluation,
}: TaskTimelineProps) {
  const user = useUser();
  const params = useParams({ from: "/_layout/$teamSlugOrId/task/$taskId" });
  const taskComments = useQuery(api.taskComments.listByTask, {
    teamSlugOrId: params.teamSlugOrId,
    taskId: params.taskId as Id<"tasks">,
  });

  const flattenedRuns = useMemo(
    () => (taskRuns ? flattenTaskRuns(taskRuns) : []),
    [taskRuns]
  );

  const runStats = useMemo<TaskRunStats>(() => {
    const stats: TaskRunStats = {
      total: flattenedRuns.length,
      completed: 0,
      running: 0,
      failed: 0,
    };

    for (const run of flattenedRuns) {
      if (run.status === "completed") {
        stats.completed += 1;
      } else if (run.status === "running") {
        stats.running += 1;
      } else if (run.status === "failed") {
        stats.failed += 1;
      }
    }

    return stats;
  }, [flattenedRuns]);

  const crownEvaluationStatus = useMemo<CrownEvaluationStatus | null>(() => {
    if (!task) {
      return null;
    }

    const pending = task.crownEvaluationError === "pending_evaluation";
    const running = task.crownEvaluationError === "in_progress";

    if (running) {
      const completedText =
        runStats.completed > 0
          ? `${runStats.completed} completed ${pluralize(runStats.completed, "implementation")}`
          : "the available implementations";

      const detail =
        runStats.running > 0
          ? `${runStats.running} ${pluralize(runStats.running, "agent")} still running.`
          : undefined;

      return {
        state: "running",
        title: "Crown evaluation in progress",
        description: `Claude is reviewing ${completedText} to decide the winner.`,
        detail,
      };
    }

    if (pending) {
      const readyText =
        runStats.completed > 0
          ? `${runStats.completed} ${pluralize(runStats.completed, "implementation")} ready for evaluation.`
          : "Waiting for the first implementation to complete.";

      const detail =
        runStats.running > 0
          ? `${runStats.running} ${pluralize(runStats.running, "agent")} still running.`
          : undefined;

      return {
        state: "pending",
        title: "Crown evaluation queued",
        description: `${readyText} Claude will begin once enough implementations are ready.`,
        detail,
      };
    }

    if (task.crownEvaluationError) {
      return {
        state: "error",
        title: "Crown evaluation failed",
        description: task.crownEvaluationError,
      };
    }

    return null;
  }, [runStats, task]);

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

    if (!flattenedRuns.length) {
      return timelineEvents;
    }

    // Add run events
    flattenedRuns.forEach((run) => {
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
        timelineEvents.push({
          id: `${run._id}-end`,
          type: run.status === "failed" ? "run_failed" : "run_completed",
          timestamp: run.completedAt,
          runId: run._id,
          agentName: run.agentName,
          status: run.status,
          exitCode: run.exitCode,
          summary: run.summary,
          isCrowned: run.isCrowned,
          crownReason: run.crownReason,
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
  }, [task, flattenedRuns, crownEvaluation]);

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
            {event.summary && (
              <div className="mt-2 text-sm text-neutral-600 dark:text-neutral-400 bg-neutral-50 dark:bg-neutral-900 rounded-md p-3">
                {event.summary}
              </div>
            )}
            {event.crownReason && (
              <div className="mt-2 text-[13px] text-amber-700 dark:text-amber-400 bg-amber-50 dark:bg-amber-900/20 rounded-md p-3">
                <Trophy className="inline size-3 mr-2" />
                {event.crownReason}
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

      {crownEvaluationStatus && (
        <div
          className={`flex items-start gap-3 rounded-lg border p-3 text-sm text-neutral-800 dark:text-neutral-100 ${crownEvaluationStatus.state === "error" ? "border-red-200 bg-red-50 dark:border-red-900/60 dark:bg-red-950/30" : "border-blue-200 bg-blue-50 dark:border-blue-900/60 dark:bg-blue-950/20"}`}
        >
          {crownEvaluationStatus.state === "error" ? (
            <AlertCircle className="mt-0.5 h-4 w-4 text-red-600 dark:text-red-400" />
          ) : (
            <Loader2 className="mt-0.5 h-4 w-4 animate-spin text-blue-600 dark:text-blue-400" />
          )}
          <div className="space-y-1">
            <p className="font-medium text-neutral-900 dark:text-neutral-100">
              {crownEvaluationStatus.title}
            </p>
            <p className="text-xs text-neutral-700 dark:text-neutral-300">
              {crownEvaluationStatus.description}
            </p>
            {crownEvaluationStatus.state !== "error" &&
            crownEvaluationStatus.detail ? (
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                {crownEvaluationStatus.detail}
              </p>
            ) : null}
          </div>
        </div>
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
