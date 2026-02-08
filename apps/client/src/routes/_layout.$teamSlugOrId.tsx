import { CmuxComments } from "@/components/cmux-comments";
import { CommandBar } from "@/components/CommandBar";
import { OfflineIndicator } from "@/components/offline-indicator";
import { Sidebar } from "@/components/Sidebar";
import { SIDEBAR_PRS_DEFAULT_LIMIT } from "@/components/sidebar/const";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { ExpandTasksProvider } from "@/contexts/expand-tasks/ExpandTasksProvider";
import { cachedGetUser } from "@/lib/cachedGetUser";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { stackClientApp } from "@/lib/stack";
import { api } from "@cmux/convex/api";
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery as useRQ } from "@tanstack/react-query";
import { Suspense, useEffect } from "react";
import { env } from "@/client-env";

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
      api.teams.listTeamMemberships
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
    // In web mode, exclude local workspaces
    const excludeLocalWorkspaces = env.NEXT_PUBLIC_WEB_MODE || undefined;
    convexQueryClient.convexClient.prewarmQuery({
      query: api.tasks.getWithNotificationOrder,
      args: { teamSlugOrId: params.teamSlugOrId, excludeLocalWorkspaces },
    });
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github_prs.listPullRequests,
      args: {
        teamSlugOrId: params.teamSlugOrId,
        state: "open",
        limit: SIDEBAR_PRS_DEFAULT_LIMIT,
      },
    });
  },
});

function LayoutComponent() {
  const { teamSlugOrId } = Route.useParams();
  // In web mode, exclude local workspaces
  const excludeLocalWorkspaces = env.NEXT_PUBLIC_WEB_MODE || undefined;
  // Use React Query-wrapped Convex queries to avoid real-time subscriptions
  // that cause excessive re-renders cascading to all child components.
  // Uses getWithNotificationOrder which sorts tasks with unread notifications first
  const tasksQuery = useRQ({
    ...convexQuery(api.tasks.getWithNotificationOrder, { teamSlugOrId, excludeLocalWorkspaces }),
    enabled: Boolean(teamSlugOrId),
  });
  const tasks = tasksQuery.data;

  // Tasks are already sorted by the query (unread notifications first, then by createdAt)
  const displayTasks = tasks;

  return (
    <ExpandTasksProvider>
      <CommandBar teamSlugOrId={teamSlugOrId} />

      <div className="flex flex-row grow min-h-0 h-dvh bg-white dark:bg-black overflow-x-auto snap-x snap-mandatory md:overflow-x-visible md:snap-none">
        <Sidebar tasks={displayTasks} teamSlugOrId={teamSlugOrId} />

        <div className="min-w-full md:min-w-0 grow snap-start snap-always flex flex-col">
          <Suspense fallback={<div>Loading...</div>}>
            <Outlet />
          </Suspense>
        </div>
      </div>

      <div className="fixed bottom-4 right-4 z-[var(--z-overlay)]">
        <OfflineIndicator />
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
