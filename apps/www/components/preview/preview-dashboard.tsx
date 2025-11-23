"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, Shield, Search, Github, ExternalLink, Zap, Eye, User } from "lucide-react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Button } from "@/components/ui/button";

type ProviderConnection = {
  installationId: number;
  accountLogin: string | null;
  accountType: string | null;
  isActive: boolean;
};

type RepoSearchResult = {
  full_name: string;
  private: boolean;
  updated_at?: string | null;
};

type StackTeam = {
    slug?: string | null;
    teamId?: string;
    id?: string;
    displayName?: string | null;
    name?: string | null;
};

type PreviewDashboardProps = {
  selectedTeamSlugOrId: string;
  hasGithubAppInstallation: boolean;
  providerConnections: ProviderConnection[];
  isAuthenticated: boolean;
};

function getTeamSlugOrId(team: StackTeam): string {
  return team.slug ?? team.teamId ?? team.id ?? "";
}

function getTeamDisplayName(team: StackTeam): string {
  return team.displayName ?? team.name ?? team.slug ?? team.teamId ?? team.id ?? "team";
}

export function PreviewDashboard({
  selectedTeamSlugOrId,
  hasGithubAppInstallation,
  providerConnections,
  isAuthenticated,
}: PreviewDashboardProps) {
  const router = useRouter();
  const [isInstallingApp, setIsInstallingApp] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Repository selection state
  const [selectedInstallationId, setSelectedInstallationId] = useState<number | null>(null);
  const [repoSearch, setRepoSearch] = useState("");
  const [repos, setRepos] = useState<RepoSearchResult[]>([]);
  const [isLoadingRepos, setIsLoadingRepos] = useState(false);
  const [isNavigating, setIsNavigating] = useState(false);

  const activeConnections = providerConnections.filter((c) => c.isActive);

  // Auto-select first connection
  useEffect(() => {
    if (activeConnections.length > 0 && !selectedInstallationId) {
      setSelectedInstallationId(activeConnections[0]?.installationId ?? null);
    }
  }, [activeConnections, selectedInstallationId]);

  const handleInstallGithubApp = async () => {
    setIsInstallingApp(true);
    setErrorMessage(null);
    try {
      const currentUrl = window.location.href;
      try {
        sessionStorage.setItem("pr_review_return_url", currentUrl);
      } catch (storageError) {
        console.warn("[PreviewDashboard] Failed to persist return URL", storageError);
      }

      const response = await fetch("/api/integrations/github/install-state", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: selectedTeamSlugOrId,
          returnUrl: currentUrl,
        }),
      });
      if (!response.ok) {
        throw new Error(await response.text());
      }
      const payload = (await response.json()) as { state: string };
      const githubAppSlug = process.env.NEXT_PUBLIC_GITHUB_APP_SLUG;
      if (!githubAppSlug) {
        throw new Error("GitHub App slug is not configured");
      }
      const url = new URL(`https://github.com/apps/${githubAppSlug}/installations/new`);
      url.searchParams.set("state", payload.state);
      window.location.href = url.toString();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to start GitHub App install";
      setErrorMessage(message);
      setIsInstallingApp(false);
    }
  };

  const handleSearchRepos = useCallback(async () => {
    if (selectedInstallationId === null) {
      setRepos([]);
      return;
    }
    setIsLoadingRepos(true);
    setErrorMessage(null);
    try {
      const params = new URLSearchParams({
        team: selectedTeamSlugOrId,
        installationId: String(selectedInstallationId),
      });
      if (repoSearch.trim()) {
        params.set("search", repoSearch.trim());
      }
      const response = await fetch(`/api/integrations/github/repos?${params}`);
      if (!response.ok) {
        throw new Error(await response.text());
      }
      const payload = (await response.json()) as { repos: RepoSearchResult[] };
      setRepos(payload.repos);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to load repositories";
      setErrorMessage(message);
    } finally {
      setIsLoadingRepos(false);
    }
  }, [repoSearch, selectedTeamSlugOrId, selectedInstallationId]);

  // Auto-load repos when installation changes
  useEffect(() => {
    if (selectedInstallationId !== null) {
      void handleSearchRepos();
    }
  }, [selectedInstallationId, handleSearchRepos]);

  const handleContinue = useCallback((repoName: string) => {
    if (!repoName.trim()) return;
    setIsNavigating(true);
    const params = new URLSearchParams({
      repo: repoName,
      installationId: String(selectedInstallationId ?? ""),
      team: selectedTeamSlugOrId,
    });
    window.location.href = `/preview/configure?${params.toString()}`;
  }, [selectedInstallationId, selectedTeamSlugOrId]);

  const selectedConnection = activeConnections.find(
    (c) => c.installationId === selectedInstallationId
  );

  return (
    <div className="mx-auto w-full max-w-[1200px] px-6 py-12">
      <div className="mb-12 space-y-4">
        <Link 
          href="https://cmux.dev" 
          className="inline-block text-sm text-neutral-400 hover:text-white transition-colors mb-2"
        >
          back to cmux →
        </Link>
        <h1 className="text-4xl font-bold tracking-tight text-white">
          Screenshot previews for your code reviews
        </h1>
        <p className="max-w-2xl text-lg text-neutral-300">
          Link your repository, configure your dev server, and cmux Preview automatically
          captures screenshots for every pull request.
        </p>
      </div>

      {/* Global Search/Input Bar */}
      <div className="mb-12 relative group">
        <div className="absolute inset-0 -z-10 rounded-xl bg-gradient-to-r from-sky-500/20 via-blue-500/20 to-purple-500/20 blur-xl opacity-50 group-hover:opacity-100 transition-opacity duration-500" />
        <div className="flex items-center gap-3 rounded-xl border border-white/10 bg-black/50 px-4 py-4 shadow-2xl backdrop-blur-sm transition hover:border-white/20">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-white/10">
            <ExternalLink className="h-4 w-4 text-neutral-400" />
          </div>
          <input 
            type="text" 
            placeholder="Enter a Git repository URL to set up previews..." 
            className="flex-1 bg-transparent text-sm text-white placeholder:text-neutral-500 focus:outline-none"
          />
          <Button variant="default" className="bg-white text-black hover:bg-neutral-200">
            Continue
          </Button>
        </div>
      </div>

      <div className="grid gap-8 lg:grid-cols-[1.5fr_1fr]">
        {/* Left Column: Import Git Repository */}
        <div className="space-y-6">
          <h2 className="text-xl font-semibold text-white">Import Git Repository</h2>
          
          <div className="rounded-xl border border-white/10 bg-neutral-900/30 p-6">
            {!isAuthenticated ? (
               <div className="text-center py-8">
                  <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-white/5">
                    <User className="h-6 w-6 text-white" />
                  </div>
                  <h3 className="mb-2 text-lg font-medium text-white">Sign in to continue</h3>
                  <p className="mb-6 text-sm text-neutral-400">
                    Sign in to cmux to import your repositories and start building previews.
                  </p>
                  <Button asChild className="bg-white text-black hover:bg-neutral-200">
                    <Link href="/handler/sign-in?after_auth_return_to=/preview">
                      Sign In
                    </Link>
                  </Button>
               </div>
            ) : !hasGithubAppInstallation ? (
               <div className="text-center py-8">
                  <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-white/5">
                    <Github className="h-6 w-6 text-white" />
                  </div>
                  <h3 className="mb-2 text-lg font-medium text-white">Connect to GitHub</h3>
                  <p className="mb-6 text-sm text-neutral-400">
                    Install the cmux GitHub App to access your repositories.
                  </p>
                  <Button
                    onClick={handleInstallGithubApp}
                    disabled={isInstallingApp}
                    className="inline-flex items-center gap-2 bg-white text-black hover:bg-neutral-200"
                  >
                    {isInstallingApp ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <Shield className="h-4 w-4" />
                    )}
                    Install GitHub App
                  </Button>
                  {errorMessage && (
                    <p className="mt-4 text-xs text-red-400">{errorMessage}</p>
                  )}
               </div>
            ) : (
              <div className="space-y-4">
                <div className="flex gap-3">
                   {/* Team/Org Selector */}
                   <div className="relative min-w-[160px]">
                      <select
                        value={selectedInstallationId ?? ""}
                        onChange={(e) => setSelectedInstallationId(Number(e.target.value))}
                        className="w-full appearance-none rounded-lg border border-white/10 bg-white/5 px-3 py-2.5 text-sm text-white focus:border-white/20 focus:outline-none focus:ring-1 focus:ring-sky-500/50"
                      >
                        {activeConnections.map((conn) => (
                          <option key={conn.installationId} value={conn.installationId}>
                            {conn.accountLogin || `ID: ${conn.installationId}`}
                          </option>
                        ))}
                      </select>
                      <div className="pointer-events-none absolute right-3 top-3">
                         <svg className="h-4 w-4 text-neutral-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                           <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                         </svg>
                      </div>
                   </div>

                   {/* Repo Search */}
                   <div className="relative flex-1">
                      <Search className="absolute left-3 top-2.5 h-4 w-4 text-neutral-500" />
                      <input
                        type="text"
                        value={repoSearch}
                        onChange={(e) => setRepoSearch(e.target.value)}
                        onKeyDown={(e) => e.key === "Enter" && void handleSearchRepos()}
                        placeholder="Search..."
                        className="w-full rounded-lg border border-white/10 bg-white/5 pl-9 pr-3 py-2.5 text-sm text-white focus:border-white/20 focus:outline-none focus:ring-1 focus:ring-sky-500/50"
                      />
                   </div>
                </div>

                {/* Repo List */}
                <div className="min-h-[300px]">
                  {isLoadingRepos ? (
                    <div className="flex justify-center py-12">
                      <Loader2 className="h-6 w-6 animate-spin text-neutral-500" />
                    </div>
                  ) : repos.length > 0 ? (
                    <div className="space-y-2">
                      {repos.map((repo) => (
                        <div
                          key={repo.full_name}
                          className="flex items-center justify-between rounded-lg border border-white/5 bg-white/5 px-4 py-3 transition hover:border-white/10 hover:bg-white/10"
                        >
                          <div className="flex items-center gap-3">
                             <div className="flex h-8 w-8 items-center justify-center rounded-md bg-black/40">
                               <Github className="h-4 w-4 text-white" />
                             </div>
                             <div>
                               <div className="text-sm font-medium text-white">{repo.full_name}</div>
                               {repo.updated_at && (
                                 <div className="text-xs text-neutral-500">
                                   {Math.floor((Date.now() - new Date(repo.updated_at).getTime()) / (1000 * 60 * 60 * 24))}d ago
                                 </div>
                               )}
                             </div>
                          </div>
                          <Button
                            onClick={() => handleContinue(repo.full_name)}
                            disabled={isNavigating}
                            size="sm"
                            className="bg-white text-black hover:bg-neutral-200"
                          >
                            Import
                          </Button>
                        </div>
                      ))}
                    </div>
                  ) : (
                    <div className="flex flex-col items-center justify-center py-12 text-sm text-neutral-500">
                      <p>No repositories found</p>
                      <button onClick={() => void handleSearchRepos()} className="mt-2 text-sky-400 hover:underline">
                        Refresh
                      </button>
                    </div>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Right Column: Setup & Benefits */}
        <div className="space-y-8">
          
          <div className="space-y-4">
            <h3 className="text-lg font-semibold text-white">What is preview.new?</h3>
            <div className="grid gap-4">
               <div className="rounded-xl border border-white/10 bg-neutral-900/30 p-4">
                 <div className="mb-2 flex items-center gap-3">
                    <div className="rounded-lg bg-sky-500/20 p-2 text-sky-400">
                      <Zap className="h-5 w-5" />
                    </div>
                    <h4 className="font-medium text-white">Automated captures</h4>
                 </div>
                 <p className="text-sm text-neutral-400">
                   Every PR triggers a dedicated VM that boots your dev server and captures screenshots automatically.
                 </p>
               </div>

               <div className="rounded-xl border border-white/10 bg-neutral-900/30 p-4">
                 <div className="mb-2 flex items-center gap-3">
                    <div className="rounded-lg bg-emerald-500/20 p-2 text-emerald-400">
                      <Eye className="h-5 w-5" />
                    </div>
                    <h4 className="font-medium text-white">Visual verification</h4>
                 </div>
                 <p className="text-sm text-neutral-400">
                   Catch visual regressions and UI bugs before they ship by comparing screenshots across profiles.
                 </p>
               </div>

               <div className="rounded-xl border border-white/10 bg-neutral-900/30 p-4">
                 <div className="mb-2 flex items-center gap-3">
                    <div className="rounded-lg bg-purple-500/20 p-2 text-purple-400">
                      <Shield className="h-5 w-5" />
                    </div>
                    <h4 className="font-medium text-white">Secure environments</h4>
                 </div>
                 <p className="text-sm text-neutral-400">
                   Environment variables are encrypted and stored securely while maintaining full dev server functionality.
                 </p>
               </div>
            </div>
          </div>

          <div className="space-y-4">
            <h3 className="text-lg font-semibold text-white">How it works</h3>
            <div className="space-y-3">
              {[
                "Install GitHub App",
                "Select repository",
                "Configure scripts",
                "Review screenshots",
              ].map((step, i) => (
                <div key={step} className="flex items-center gap-3 text-sm text-neutral-400">
                  <div className="flex h-6 w-6 items-center justify-center rounded-full border border-white/10 bg-white/5 text-xs font-medium">
                    {i + 1}
                  </div>
                  <span>{step}</span>
                </div>
              ))}
            </div>
          </div>

        </div>
      </div>
    </div>
  );
}