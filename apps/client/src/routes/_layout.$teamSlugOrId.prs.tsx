import { PRsWorkspace } from "@/components/prs/PRsWorkspace";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { api } from "@cmux/convex/api";
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/_layout/$teamSlugOrId/prs")({
  component: PRsPage,
  loader: async (opts) => {
    const { teamSlugOrId } = opts.params;
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

function PRsPage() {
  const { teamSlugOrId } = Route.useParams();
  return <PRsWorkspace teamSlugOrId={teamSlugOrId} />;
}
