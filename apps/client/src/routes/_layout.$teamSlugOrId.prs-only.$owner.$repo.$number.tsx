import { FloatingPane } from "@/components/floating-pane";
import { PullRequestDetailView } from "@/components/prs/PullRequestDetailView";
import { createFileRoute } from "@tanstack/react-router";
import { preloadPullRequestDetail } from "../lib/preloadPullRequestDetail";

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/prs-only/$owner/$repo/$number"
)({
  component: PROnlyRoute,
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

function PROnlyRoute() {
  const { teamSlugOrId, owner, repo, number } = Route.useParams();
  return (
    <FloatingPane>
      <div className="min-w-0 min-h-0 h-full flex flex-col">
        <div className="flex-1 min-h-0 h-full overflow-y-auto bg-white dark:bg-neutral-900">
          <PullRequestDetailView
            key={`${owner}/${repo}#${number}`}
            teamSlugOrId={teamSlugOrId}
            owner={owner}
            repo={repo}
            number={number}
          />
        </div>
      </div>
    </FloatingPane>
  );
}
