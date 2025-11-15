import { notFound } from "next/navigation";
import Link from "next/link";
import { stackServerApp } from "@/lib/utils/stack";
import { getConvex } from "@/lib/utils/get-convex";
import { api } from "@cmux/convex/api";
import { PreviewConfigurationPanel } from "@/components/preview/preview-configuration-panel";

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

function getTeamDisplayName(team: StackTeam): string {
  const candidate = team as unknown as {
    displayName?: string | null;
    name?: string | null;
    slug?: string | null;
    teamId?: string;
    id?: string;
  };
  return (
    candidate.displayName ??
    candidate.name ??
    candidate.slug ??
    candidate.teamId ??
    candidate.id ??
    "team"
  );
}

function serializeProviderConnections(
  connections: Array<{
    installationId: number;
    accountLogin: string | null | undefined;
    accountType: string | null | undefined;
    type: string | null | undefined;
    isActive: boolean;
  }>
) {
  return connections.map((conn) => ({
    installationId: conn.installationId,
    accountLogin: conn.accountLogin ?? null,
    accountType: conn.accountType ?? null,
    isActive: conn.isActive,
  }));
}

export default async function PreviewGetStartedPage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();

  // If user is not authenticated, redirect to sign-in with return URL
  if (!user) {
    const { redirect: nextRedirect } = await import("next/navigation");
    const currentUrl = "/preview/get-started";
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(currentUrl)}`;
    return nextRedirect(signInUrl);
  }

  const [{ accessToken }, teams, resolvedSearch] = await Promise.all([
    user.getAuthJson(),
    user.listTeams(),
    searchParams,
  ]);

  if (!accessToken) {
    throw new Error("Missing Stack access token");
  }

  if (teams.length === 0) {
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

  const convex = getConvex({ accessToken });
  const [providerConnections] = await Promise.all([
    convex.query(api.github.listProviderConnections, {
      teamSlugOrId: selectedTeamSlugOrId,
    }),
  ]);

  const hasGithubAppInstallation = providerConnections.some(
    (connection) => connection.isActive,
  );

  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white">
      <div className="absolute inset-0 -z-10 bg-[radial-gradient(circle_at_top,_rgba(4,120,255,0.3),_transparent_45%)]" />
      <div className="mx-auto flex w-full max-w-6xl flex-col gap-10 px-4 py-10">
        <header className="flex flex-col gap-4 border-b border-white/5 pb-6 md:flex-row md:items-center md:justify-between">
          <div>
            <p className="text-xs uppercase tracking-[0.3em] text-sky-400">
              cmux Preview
            </p>
            <h1 className="mt-2 text-3xl font-semibold">Automated screenshot previews</h1>
            <p className="mt-2 text-sm text-neutral-300">
              Link a repository, describe how to boot the dev server, and cmux Preview spins up a dedicated VM to capture screenshots for every pull request.
            </p>
          </div>
          <Link
            href="/preview"
            className="text-sm text-neutral-400 underline-offset-4 hover:text-white hover:underline"
          >
            Back to overview
          </Link>
        </header>

        <div className="flex flex-wrap gap-3 border-b border-white/5 pb-6 text-sm text-neutral-400">
          {teams.map((team) => {
            const slugOrId = getTeamSlugOrId(team);
            const isActive = slugOrId === selectedTeamSlugOrId;
            return (
              <Link
                key={slugOrId}
                href={`/preview/get-started?team=${encodeURIComponent(slugOrId)}`}
                className={`rounded-full border px-4 py-1 ${
                  isActive
                    ? "border-white bg-white/10 text-white"
                    : "border-white/20 bg-white/5 hover:border-white/40"
                }`}
              >
                {getTeamDisplayName(team)}
              </Link>
            );
          })}
        </div>

        <PreviewConfigurationPanel
          teamSlugOrId={selectedTeamSlugOrId}
          hasGithubAppInstallation={hasGithubAppInstallation}
          providerConnections={serializeProviderConnections(providerConnections)}
        />
      </div>
    </div>
  );
}
