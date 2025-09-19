import { getLastTeamSlugOrId } from "@/lib/lastTeam";
import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  beforeLoad: () => {
    if (typeof window !== "undefined") {
      const last = getLastTeamSlugOrId();
      if (last && last.trim().length > 0) {
        throw redirect({
          to: "/$teamSlugOrId",
          params: { teamSlugOrId: last },
        });
      }
    }
    throw redirect({ to: "/team-picker" });
  },
  component: () => null,
});
