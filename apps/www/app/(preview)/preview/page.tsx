import Link from "next/link";
import { stackServerApp } from "@/lib/utils/stack";
import { ArrowRight, Eye, Zap, Shield } from "lucide-react";
import { getConvex } from "@/lib/utils/get-convex";
import { api } from "@cmux/convex/api";
import { PreviewDashboard } from "@/components/preview/preview-dashboard";

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

export default async function PreviewLandingPage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();
  
  // If user is logged in, show the dashboard
  if (user) {
    const [{ accessToken }, teams, resolvedSearch] = await Promise.all([
      user.getAuthJson(),
      user.listTeams(),
      searchParams,
    ]);

    if (!accessToken) {
      throw new Error("Missing Stack access token");
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
    const selectedTeamSlugOrId = selectedTeam ? getTeamSlugOrId(selectedTeam) : "";

    const convex = getConvex({ accessToken });
    const [providerConnections] = await Promise.all([
      selectedTeamSlugOrId 
        ? convex.query(api.github.listProviderConnections, {
            teamSlugOrId: selectedTeamSlugOrId,
          })
        : Promise.resolve([]),
    ]);

    const hasGithubAppInstallation = providerConnections.some(
      (connection) => connection.isActive,
    );

    return (
      <div className="relative isolate min-h-dvh bg-[#05050a] text-white">
        <div className="absolute inset-0 -z-10 bg-[radial-gradient(circle_at_top,_rgba(4,120,255,0.3),_transparent_45%)]" />
        
        <PreviewDashboard 
          selectedTeamSlugOrId={selectedTeamSlugOrId}
          hasGithubAppInstallation={hasGithubAppInstallation}
          providerConnections={serializeProviderConnections(providerConnections)}
          isAuthenticated={true}
        />
      </div>
    );
  }

  // Marketing Page (Logged out)
  const teams: StackTeam[] = []; 

  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white">
      <div className="absolute inset-0 -z-10 bg-[radial-gradient(circle_at_top,_rgba(4,120,255,0.3),_transparent_45%)]" />
      
      <div className="mx-auto flex w-full max-w-6xl flex-col gap-16 px-4 py-16">
        <header className="space-y-6 text-center">
          <Link 
            href="https://cmux.dev" 
            className="inline-block text-sm text-neutral-400 hover:text-white transition-colors"
          >
            back to cmux →
          </Link>
          <h1 className="text-5xl font-bold tracking-tight">
            Screenshot previews for your code reviews
          </h1>
          <p className="mx-auto max-w-2xl text-lg text-neutral-300">
            Link your repository, configure your dev server, and cmux Preview automatically
            captures screenshots for every pull request—eliminating manual verification steps
            and catching visual regressions before they reach production.
          </p>
        </header>

        <div className="grid gap-8 md:grid-cols-3">
          <div className="rounded-2xl border border-neutral-800 bg-neutral-950/60 p-8 shadow-xl shadow-black/30">
            <div className="mb-4 inline-flex rounded-xl bg-gradient-to-br from-sky-500/40 via-blue-500/40 to-purple-500/40 p-3 text-white shadow-lg">
              <Zap className="h-6 w-6" />
            </div>
            <h3 className="mb-3 text-xl font-semibold">Automated captures</h3>
            <p className="text-neutral-400">
              Every PR triggers a dedicated VM that boots your dev server and captures
              screenshots automatically—no manual setup required.
            </p>
          </div>

          <div className="rounded-2xl border border-neutral-800 bg-neutral-950/60 p-8 shadow-xl shadow-black/30">
            <div className="mb-4 inline-flex rounded-xl bg-gradient-to-br from-emerald-500/40 via-green-500/40 to-teal-500/40 p-3 text-white shadow-lg">
              <Eye className="h-6 w-6" />
            </div>
            <h3 className="mb-3 text-xl font-semibold">Visual verification</h3>
            <p className="text-neutral-400">
              Catch visual regressions and UI bugs before they ship by comparing screenshots
              across different browser profiles and viewport sizes.
            </p>
          </div>

          <div className="rounded-2xl border border-neutral-800 bg-neutral-950/60 p-8 shadow-xl shadow-black/30">
            <div className="mb-4 inline-flex rounded-xl bg-gradient-to-br from-violet-500/40 via-purple-500/40 to-fuchsia-500/40 p-3 text-white shadow-lg">
              <Shield className="h-6 w-6" />
            </div>
            <h3 className="mb-3 text-xl font-semibold">Secure environments</h3>
            <p className="text-neutral-400">
              Environment variables are encrypted and stored securely, ensuring your secrets
              stay safe while maintaining full dev server functionality.
            </p>
          </div>
        </div>

        <section className="space-y-8">
          <div className="text-center">
            <h2 className="mb-4 text-3xl font-semibold">How it works</h2>
            <p className="mx-auto max-w-2xl text-neutral-400">
              Set up once, automate forever. cmux Preview integrates with your GitHub workflow
              to deliver consistent, reliable visual testing.
            </p>
          </div>

          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-4">
            <div className="space-y-3 rounded-xl border border-sky-500/30 bg-gradient-to-br from-sky-500/10 to-blue-500/10 p-6">
              <div className="flex h-10 w-10 items-center justify-center rounded-full bg-sky-500/20 text-lg font-bold text-sky-400 border border-sky-500/30">
                1
              </div>
              <h4 className="text-lg font-semibold">Install GitHub App</h4>
              <p className="text-sm text-neutral-300">
                <strong className="text-white">Required first:</strong> Connect cmux Preview to your repositories by
                installing the GitHub App on your organization or user account.
              </p>
            </div>

            <div className="space-y-3 rounded-xl border border-neutral-800 bg-neutral-900/40 p-6">
              <div className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/10 text-lg font-bold">
                2
              </div>
              <h4 className="text-lg font-semibold">Select repository</h4>
              <p className="text-sm text-neutral-400">
                Browse and select a repository from your installed GitHub App to configure for preview runs.
              </p>
            </div>

            <div className="space-y-3 rounded-xl border border-neutral-800 bg-neutral-900/40 p-6">
              <div className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/10 text-lg font-bold">
                3
              </div>
              <h4 className="text-lg font-semibold">Configure scripts</h4>
              <p className="text-sm text-neutral-400">
                Define your maintenance and dev server scripts, set environment variables, and
                choose your preferred browser profile.
              </p>
            </div>

            <div className="space-y-3 rounded-xl border border-neutral-800 bg-neutral-900/40 p-6">
              <div className="flex h-10 w-10 items-center justify-center rounded-full border border-white/10 bg-white/10 text-lg font-bold">
                4
              </div>
              <h4 className="text-lg font-semibold">Review screenshots</h4>
              <p className="text-sm text-neutral-400">
                When PRs are opened, cmux Preview automatically captures screenshots. Review them in the dashboard
                and ship with confidence.
              </p>
            </div>
          </div>
        </section>

        <div className="rounded-2xl border border-sky-500/20 bg-gradient-to-br from-sky-500/10 to-blue-500/10 p-10 text-center shadow-xl shadow-sky-500/10">
          <h2 className="mb-4 text-3xl font-semibold">Ready to get started?</h2>
          <p className="mb-8 text-neutral-300">
            {teams.length === 0
              ? "Create a team and configure your first preview environment."
              : "Configure your preview environment and start automating visual testing."}
          </p>
          <Link
            href="/handler/sign-in?after_auth_return_to=/preview"
            className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/20 bg-white px-6 py-3 text-base font-semibold text-black shadow-xl transition hover:bg-neutral-100"
          >
            Get started
            <ArrowRight className="h-5 w-5" />
          </Link>
        </div>
      </div>
    </div>
  );
}
