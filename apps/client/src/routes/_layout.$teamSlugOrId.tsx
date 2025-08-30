import { CmuxComments } from "@/components/cmux-comments";
import { Sidebar } from "@/components/Sidebar";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { ExpandTasksProvider } from "@/contexts/expand-tasks/ExpandTasksProvider";
import { isFakeConvexId } from "@/lib/fakeConvexId";
import { api } from "@cmux/convex/api";
import { type Id } from "@cmux/convex/dataModel";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { useQueries, useQuery } from "convex/react";
import { Suspense, useMemo } from "react";

export const Route = createFileRoute("/_layout/$teamSlugOrId")({
  component: LayoutComponentWrapper,
  beforeLoad: async ({ params }) => {
    const teamMemberships = await convexQueryClient.convexClient.query(
      api.teams.listTeamMemberships
    );
    const teamMembership = teamMemberships.find(
      (m) => m.team.slug === params.teamSlugOrId
    );
    if (!teamMembership) {
      throw redirect({ to: "/team-picker" });
    }
  },
  loader: async ({ params }) => {
    void convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.tasks.get, { teamSlugOrId: params.teamSlugOrId })
    );
  },
});

function LayoutComponent() {
  const { teamSlugOrId } = Route.useParams();
  const tasks = useQuery(api.tasks.get, { teamSlugOrId });

  // Sort tasks by creation date (newest first) and take the latest 5
  const recentTasks = useMemo(() => {
    return (
      tasks
        ?.filter((task) => task.createdAt)
        ?.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0)) || []
    );
  }, [tasks]);

  // Create queries object for all recent tasks with memoization, filtering out fake IDs
  const taskRunQueries = useMemo(() => {
    return recentTasks
      .filter((task) => !isFakeConvexId(task._id))
      .reduce(
        (acc, task) => ({
          ...acc,
          [task._id]: {
            query: api.taskRuns.getByTask,
            args: { teamSlugOrId, taskId: task._id },
          },
        }),
        {} as Record<
          Id<"tasks">,
          {
            query: typeof api.taskRuns.getByTask;
            args:
              | ((d: { params: { teamSlugOrId: string } }) => {
                  teamSlugOrId: string;
                  taskId: Id<"tasks">;
                })
              | { teamSlugOrId: string; taskId: Id<"tasks"> };
          }
        >
      );
  }, [recentTasks, teamSlugOrId]);

  // Fetch task runs for all recent tasks using useQueries
  const taskRunResults = useQueries(
    taskRunQueries as Parameters<typeof useQueries>[0]
  );

  // Map tasks with their respective runs
  const tasksWithRuns = useMemo(
    () =>
      recentTasks.map((task) => ({
        ...task,
        runs: taskRunResults[task._id] || [],
      })),
    [recentTasks, taskRunResults]
  );

  return (
    <>
      <ExpandTasksProvider>
        <div className="flex flex-row grow bg-white dark:bg-black">
          <Sidebar
            tasks={tasks}
            tasksWithRuns={tasksWithRuns}
            teamSlugOrId={teamSlugOrId}
          />

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
          zIndex: 9999,
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
  return (
    <>
      <LayoutComponent />
      <CmuxComments teamSlugOrId={teamSlugOrId} />
    </>
  );
}
