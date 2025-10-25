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
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { Suspense, useEffect, useMemo } from "react";

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

  const displayTasks = tasks === undefined ? undefined : recentTasks;

  return (
    <ExpandTasksProvider>
      <CommandBar teamSlugOrId={teamSlugOrId} />

      <div className="flex flex-row grow min-h-0 h-dvh bg-white dark:bg-black">
        <Sidebar tasks={displayTasks} teamSlugOrId={teamSlugOrId} />

        {/* <div className="flex flex-col grow overflow-hidden bg-white dark:bg-neutral-950"> */}
        <Suspense fallback={<div>Loading...</div>}>
          <Outlet />
        </Suspense>
        {/* </div> */}
      </div>

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
    </ExpandTasksProvider>
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
