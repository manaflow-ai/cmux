import { createFileRoute, Outlet } from "@tanstack/react-router";
import z from "zod";

export const Route = createFileRoute("/_layout/$teamSlugOrId/environments")({
  component: EnvironmentsLayout,
  validateSearch: (search: Record<string, unknown>) => {
    const step = z.enum(["select", "configure"]).optional().parse(search.step);
    const selectedRepos = z
      .array(z.string())
      .optional()
      .parse(search.selectedRepos);
    const connectionLogin = z.string().optional().parse(search.connectionLogin);
    const repoSearch = z.string().optional().parse(search.repoSearch);
    const instanceId = z.string().optional().parse(search.instanceId);
    return {
      step,
      selectedRepos,
      connectionLogin,
      repoSearch,
      instanceId,
    };
  },
});

function EnvironmentsLayout() {
  return <Outlet />;
}

