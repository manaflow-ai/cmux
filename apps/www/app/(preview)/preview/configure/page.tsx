import { notFound, redirect } from "next/navigation";
import { stackServerApp } from "@/lib/utils/stack";
import { PreviewConfigureClient } from "@/components/preview/preview-configure-client";

export const dynamic = "force-dynamic";

type PageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

type StackTeam = Awaited<ReturnType<typeof stackServerApp.listTeams>>[number];

function getTeamSlugOrId(team: StackTeam): string {
  const candidate = team as unknown as {
    slug?: string | null;
    teamId?: string;
    id?: string;
  };
  return candidate.slug ?? candidate.teamId ?? candidate.id ?? "";
}

export default async function PreviewConfigurePage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();

  // If user is not authenticated, redirect to sign-in
  if (!user) {
    const currentUrl = "/preview/configure";
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(currentUrl)}`;
    return redirect(signInUrl);
  }

  const [teams, resolvedSearch] = await Promise.all([
    user.listTeams(),
    searchParams,
  ]);

  if (teams.length === 0) {
    notFound();
  }

  const repo = (() => {
    if (!resolvedSearch) {
      return null;
    }
    const value = resolvedSearch.repo;
    if (Array.isArray(value)) {
      return value[0] ?? null;
    }
    return value ?? null;
  })();

  const installationId = (() => {
    if (!resolvedSearch) {
      return null;
    }
    const value = resolvedSearch.installationId;
    if (Array.isArray(value)) {
      return value[0] ?? null;
    }
    return value ?? null;
  })();

  if (!repo) {
    notFound();
  }

  const searchTeam = (() => {
    if (!resolvedSearch) {
      return null;
    }
    const value = resolvedSearch.team;
    if (Array.isArray(value)) {
      return value[0] ?? null;
    }
    return value ?? null;
  })();

  const selectedTeam =
    teams.find((team) => getTeamSlugOrId(team) === searchTeam) ?? teams[0];
  const selectedTeamSlugOrId = getTeamSlugOrId(selectedTeam);

  return (
    <PreviewConfigureClient
      teamSlugOrId={selectedTeamSlugOrId}
      repo={repo}
      installationId={installationId}
    />
  );
}
