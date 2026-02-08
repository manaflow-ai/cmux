import { PullRequestDetailView } from "@/components/prs/PullRequestDetailView";
import { createFileRoute } from "@tanstack/react-router";
import { preloadPullRequestDetail } from "../lib/preloadPullRequestDetail";

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/prs/$owner/$repo/$number"
)({
  component: PRDetailsRoute,
  loader: async (opts) => {
    const { teamSlugOrId, owner, repo, number } = opts.params;
    void preloadPullRequestDetail({
      queryClient: opts.context.queryClient,
      teamSlugOrId,
      owner,
      repo,
      number,
    });
  },
});

function PRDetailsRoute() {
  const { teamSlugOrId, owner, repo, number } = Route.useParams();
  return (
    <PullRequestDetailView
      key={`${owner}/${repo}#${number}`}
      teamSlugOrId={teamSlugOrId}
      owner={owner}
      repo={repo}
      number={number}
    />
  );
}
