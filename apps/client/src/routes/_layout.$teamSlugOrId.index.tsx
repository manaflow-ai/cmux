import { DashboardContent } from "@/components/dashboard/DashboardContent";
import { PRsWorkspace } from "@/components/prs/PRsWorkspace";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/_layout/$teamSlugOrId/")({
  component: IndexComponent,
  loader: async ({ params }) => {
    const { teamSlugOrId } = params;
    void convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.tasks.get, { teamSlugOrId })
    );
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github.listProviderConnections,
      args: { teamSlugOrId },
    });
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github_prs.listPullRequests,
      args: { teamSlugOrId, state: "open", search: "" },
    });
  },
});

// ConvexClientProvider is already applied in the top-level `/_layout` route.
// Avoid nesting providers here to prevent auth/loading thrash.
function IndexComponent() {
  const { teamSlugOrId } = Route.useParams();
  const searchParams = Route.useSearch() as { environmentId?: string };
  return (
    <PRsWorkspace
      teamSlugOrId={teamSlugOrId}
      emptyState={
        <DashboardContent
          teamSlugOrId={teamSlugOrId}
          environmentId={searchParams?.environmentId}
        />
      }
    />
  );
}
