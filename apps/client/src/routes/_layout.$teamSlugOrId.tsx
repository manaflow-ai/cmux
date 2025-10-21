import { CmuxComments } from "@/components/cmux-comments";
import { CommandBar } from "@/components/CommandBar";
import { Sidebar } from "@/components/Sidebar";
import { SIDEBAR_PRS_DEFAULT_LIMIT } from "@/components/sidebar/const";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { ExpandTasksProvider } from "@/contexts/expand-tasks/ExpandTasksProvider";
import { cachedGetUser } from "@/lib/cachedGetUser";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { stackClientApp } from "@/lib/stack";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute, Outlet, redirect, useNavigate } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { Suspense, useEffect, useMemo, useRef } from "react";
import { isElectron } from "@/lib/electron";
import { typedZid } from "@cmux/shared/utils/typed-zid";

export const Route = createFileRoute("/_layout/$teamSlugOrId")({
  component: LayoutComponentWrapper,
  beforeLoad: async ({ params, location }) => {
    const user = await cachedGetUser(stackClientApp);
    if (!user) {
      throw redirect({
        to: "/sign-in",
        search: {
          after_auth_return_to: location.pathname,
        },
      });
    }
    const { teamSlugOrId } = params;
    const teamMemberships = await convexQueryClient.convexClient.query(
      api.teams.listTeamMemberships,
    );
    const teamMembership = teamMemberships.find((membership) => {
      const team = membership.team;
      const membershipTeamId = team?.teamId ?? membership.teamId;
      const membershipSlug = team?.slug;
      return (
        membershipSlug === teamSlugOrId || membershipTeamId === teamSlugOrId
      );
    });
    if (!teamMembership) {
      throw redirect({ to: "/team-picker" });
    }
  },
  loader: async ({ params }) => {
    void convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.tasks.get, { teamSlugOrId: params.teamSlugOrId }),
    );
    void convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.github_prs.listPullRequests, {
        teamSlugOrId: params.teamSlugOrId,
        state: "open",
        limit: SIDEBAR_PRS_DEFAULT_LIMIT,
      }),
    );
  },
});

type TaskRunNavigationPayload = {
  teamSlugOrId: string;
  taskId: string;
  runId: string;
};

function isTaskRunNavigationPayload(
  value: unknown
): value is TaskRunNavigationPayload {
  if (!value || typeof value !== "object") {
    return false;
  }
  const candidate = value as Partial<TaskRunNavigationPayload>;
  return (
    typeof candidate.teamSlugOrId === "string" &&
    typeof candidate.taskId === "string" &&
    typeof candidate.runId === "string"
  );
}

function abbreviateText(text: string, limit: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= limit) {
    return trimmed;
  }
  if (limit <= 3) {
    return trimmed.slice(0, limit);
  }
  return `${trimmed.slice(0, limit - 3)}...`;
}

function buildNotificationBody(
  agentName?: string | null,
  crownReason?: string | null
): string {
  const parts: string[] = [];
  if (agentName && agentName.trim()) {
    parts.push(agentName.trim());
  }
  if (crownReason && crownReason.trim()) {
    parts.push(crownReason.trim());
  }
  if (parts.length === 0) {
    return "Crowned run ready to review.";
  }
  return abbreviateText(parts.join(" - "), 120);
}

function LayoutComponent() {
  const { teamSlugOrId } = Route.useParams();
  const navigate = useNavigate();
  const tasks = useQuery(api.tasks.get, { teamSlugOrId });
  const tasksWithRuns = useQuery(
    api.tasks.getTasksWithTaskRuns,
    isElectron ? { teamSlugOrId } : "skip"
  );
  const notifiedRunsRef = useRef<Set<string>>(new Set());
  const notificationsPrimedRef = useRef(false);

  useEffect(() => {
    notifiedRunsRef.current.clear();
    notificationsPrimedRef.current = false;
  }, [teamSlugOrId]);

  useEffect(() => {
    if (!isElectron) {
      return;
    }
    const maybeWindow =
      typeof window === "undefined" ? undefined : window;
    const cmux = maybeWindow?.cmux;
    if (!cmux?.on) {
      return;
    }
    const off = cmux.on("task-run:open-diff", (payload: unknown) => {
      if (!isTaskRunNavigationPayload(payload)) {
        return;
      }
      navigate({
        to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
        params: {
          teamSlugOrId: payload.teamSlugOrId,
          taskId: typedZid("tasks").parse(payload.taskId),
          runId: typedZid("taskRuns").parse(payload.runId),
        },
      });
    });

    return () => {
      off?.();
    };
  }, [navigate]);

  useEffect(() => {
    if (!isElectron) {
      return;
    }
    if (!Array.isArray(tasksWithRuns) || tasksWithRuns.length === 0) {
      return;
    }
    const maybeWindow =
      typeof window === "undefined" ? undefined : window;
    const cmux = maybeWindow?.cmux;
    const showTaskComplete = cmux?.notifications?.showTaskComplete;
    if (!showTaskComplete) {
      return;
    }

    if (!notificationsPrimedRef.current) {
      for (const task of tasksWithRuns) {
        const run = task.selectedTaskRun;
        if (!run) {
          continue;
        }
        if (!task.isCompleted || run.status !== "completed" || !run.isCrowned) {
          continue;
        }
        const key = `${task._id}:${run._id}`;
        notifiedRunsRef.current.add(key);
      }
      notificationsPrimedRef.current = true;
      return;
    }

    for (const task of tasksWithRuns) {
      const run = task.selectedTaskRun;
      if (!run) {
        continue;
      }
      if (!task.isCompleted || run.status !== "completed" || !run.isCrowned) {
        continue;
      }
      const key = `${task._id}:${run._id}`;
      if (notifiedRunsRef.current.has(key)) {
        continue;
      }

      notifiedRunsRef.current.add(key);
      const title = `Task crowned: ${abbreviateText(task.text, 60)}`;
      const body = buildNotificationBody(run.agentName, run.crownReason);

      void showTaskComplete({
        teamSlugOrId,
        taskId: `${task._id}`,
        runId: `${run._id}`,
        title,
        body,
      })
        .then((result) => {
          if (result && !result.ok) {
            console.warn("Task completion notification skipped", result.reason);
          }
        })
        .catch((error) => {
          console.error("Failed to deliver task completion notification", error);
        });
    }
  }, [tasksWithRuns, teamSlugOrId]);

  // Sort tasks by creation date (newest first) and take the latest 5
  const recentTasks = useMemo(() => {
    return (
      tasks
        ?.filter((task) => task.createdAt)
        ?.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0)) || []
    );
  }, [tasks]);

  const displayTasks = tasks === undefined ? undefined : recentTasks;

  return (
    <>
      <CommandBar teamSlugOrId={teamSlugOrId} />

      <ExpandTasksProvider>
        <div className="flex flex-row grow min-h-0 h-dvh bg-white dark:bg-black">
          <Sidebar tasks={displayTasks} teamSlugOrId={teamSlugOrId} />

          {/* <div className="flex flex-col grow overflow-hidden bg-white dark:bg-neutral-950"> */}
          <Suspense fallback={<div>Loading...</div>}>
            <Outlet />
          </Suspense>
          {/* </div> */}
        </div>
      </ExpandTasksProvider>

      <button
        onClick={() => {
          const msg = window.prompt("Enter debug note");
          if (msg) {
            // Prefix allows us to easily grep in the console.

            console.log(`[USER NOTE] ${msg}`);
          }
        }}
        className="hidden"
        style={{
          position: "fixed",
          bottom: "16px",
          right: "16px",
          zIndex: "var(--z-overlay)",
          background: "#ffbf00",
          color: "#000",
          border: "none",
          borderRadius: "4px",
          padding: "8px 12px",
          cursor: "default",
          fontSize: "12px",
          fontWeight: 600,
          boxShadow: "0 2px 4px rgba(0,0,0,0.15)",
        }}
      >
        Add Debug Note
      </button>
    </>
  );
}

// ConvexClientProvider is already applied in the top-level `/_layout` route.
// Avoid nesting providers here to prevent auth/loading thrash.
function LayoutComponentWrapper() {
  const { teamSlugOrId } = Route.useParams();
  useEffect(() => {
    setLastTeamSlugOrId(teamSlugOrId);
  }, [teamSlugOrId]);
  return (
    <>
      <LayoutComponent />
      <CmuxComments teamSlugOrId={teamSlugOrId} />
    </>
  );
}
