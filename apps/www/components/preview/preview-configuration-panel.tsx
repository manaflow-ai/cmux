"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, Shield, Search, X } from "lucide-react";

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

type PreviewConfigurationPanelProps = {
  teamSlugOrId: string;
  hasGithubAppInstallation: boolean;
  providerConnections: ProviderConnection[];
};

export function PreviewConfigurationPanel({
  teamSlugOrId,
  hasGithubAppInstallation,
  providerConnections,
}: PreviewConfigurationPanelProps) {
  const [isInstallingApp, setIsInstallingApp] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Repository selection state
  const [selectedRepo, setSelectedRepo] = useState("");
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
        console.warn("[PreviewConfigPanel] Failed to persist return URL", storageError);
      }

      const response = await fetch("/api/integrations/github/install-state", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId,
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
        team: teamSlugOrId,
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
  }, [repoSearch, teamSlugOrId, selectedInstallationId]);

  // Auto-load repos when installation changes
  useEffect(() => {
    if (selectedInstallationId !== null) {
      void handleSearchRepos();
    }
  }, [selectedInstallationId, handleSearchRepos]);

  const handleContinue = useCallback(() => {
    if (!selectedRepo.trim()) {
      setErrorMessage("Please select a repository");
      return;
    }
    setIsNavigating(true);
    // Navigate to configure page with repo info
    const params = new URLSearchParams({
      repo: selectedRepo,
      installationId: String(selectedInstallationId ?? ""),
      team: teamSlugOrId,
    });
    window.location.href = `/preview/configure?${params.toString()}`;
  }, [selectedRepo, selectedInstallationId, teamSlugOrId]);

  const selectedConnection = activeConnections.find(
    (c) => c.installationId === selectedInstallationId
  );

  return (
    <div className="space-y-10">
      {/* Step 1: GitHub App Installation */}
      <div className={`rounded-2xl border p-6 shadow-xl shadow-black/30 ${
        !hasGithubAppInstallation
          ? "border-sky-500/30 bg-gradient-to-br from-sky-500/10 to-blue-500/10"
          : "border-neutral-800 bg-neutral-950/60"
      }`}>
        <div className="flex items-start gap-4">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/10 text-lg font-bold">
            1
          </div>
          <div className="flex-1">
            <div className="flex items-center justify-between">
              <h3 className="text-lg font-semibold text-white">Install GitHub App</h3>
              <span className={`rounded-full px-3 py-1 text-xs font-medium ${
                hasGithubAppInstallation
                  ? "bg-emerald-500/20 text-emerald-400"
                  : "bg-neutral-800 text-neutral-400"
              }`}>
                {hasGithubAppInstallation ? "✓ Connected" : "Required"}
              </span>
            </div>
            <p className="mt-2 text-sm text-neutral-300">
              Install the cmux GitHub App on your organization or user account to enable preview runs for pull requests.
            </p>
            {!hasGithubAppInstallation && (
              <button
                type="button"
                onClick={handleInstallGithubApp}
                disabled={isInstallingApp}
                className="mt-4 inline-flex items-center justify-center gap-2 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-black shadow-xl transition hover:bg-neutral-100 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {isInstallingApp ? (
                  <>
                    <Loader2 className="h-4 w-4 animate-spin" />
                    Redirecting to GitHub...
                  </>
                ) : (
                  <>
                    <Shield className="h-4 w-4" />
                    Install GitHub App
                  </>
                )}
              </button>
            )}
            {errorMessage && (
              <p className="mt-2 text-xs text-red-400">{errorMessage}</p>
            )}
          </div>
        </div>
      </div>

      {/* Step 2: Configure Preview Environment */}
      {hasGithubAppInstallation && (
        <div className="rounded-2xl border border-neutral-800 bg-neutral-950/60 p-6 shadow-xl shadow-black/30">
          <div className="flex items-start gap-4 mb-6">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-white/10 bg-white/10 text-lg font-bold">
              2
            </div>
            <div className="flex-1">
              <h3 className="text-lg font-semibold text-white">Select and Configure Repository</h3>
              <p className="mt-1 text-sm text-neutral-400">
                Browse repositories and configure your preview environment.
              </p>
            </div>
          </div>

          <div className="space-y-6">
            {/* Organization Picker */}
            {activeConnections.length > 1 && (
              <div>
                <label className="text-sm font-medium text-neutral-200">Organization</label>
                <select
                  value={selectedInstallationId ?? ""}
                  onChange={(event) => {
                    const value = event.target.value;
                    setSelectedInstallationId(value ? Number(value) : null);
                    setRepos([]);
                  }}
                  className="mt-2 w-full rounded-lg border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-white focus:border-sky-500 focus:outline-none"
                >
                  {activeConnections.map((conn) => (
                    <option key={conn.installationId} value={conn.installationId}>
                      {conn.accountLogin || `Installation ${conn.installationId}`}
                    </option>
                  ))}
                </select>
              </div>
            )}

            {/* Repository Selection */}
            <div>
              <label className="text-sm font-medium text-neutral-200">Repository</label>

              {/* Selected Repository Display */}
              {selectedRepo ? (
                <div className="mt-2 flex items-center gap-2 rounded-lg border border-neutral-700 bg-neutral-900 px-3 py-2">
                  <span className="flex-1 text-sm text-white font-mono">{selectedRepo}</span>
                  <button
                    type="button"
                    onClick={() => setSelectedRepo("")}
                    className="text-neutral-400 hover:text-white transition-colors"
                  >
                    <X className="h-4 w-4" />
                  </button>
                </div>
              ) : (
                <>
                  {/* Search Input */}
                  <div className="mt-2 flex flex-col gap-3 md:flex-row">
                    <div className="flex flex-1 items-center gap-2 rounded-lg border border-neutral-700 bg-neutral-900 px-3">
                      <Search className="h-4 w-4 text-neutral-500" />
                      <input
                        type="text"
                        spellCheck={false}
                        value={repoSearch}
                        onChange={(event) => setRepoSearch(event.target.value)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter") {
                            void handleSearchRepos();
                          }
                        }}
                        placeholder="Search repositories..."
                        className="flex-1 border-none bg-transparent py-2 text-sm text-white placeholder:text-neutral-500 focus:outline-none"
                      />
                    </div>
                    <button
                      type="button"
                      onClick={handleSearchRepos}
                      disabled={isLoadingRepos || selectedInstallationId === null}
                      className="inline-flex items-center justify-center gap-2 rounded-lg border border-neutral-700 px-4 py-2 text-sm font-semibold text-white transition hover:border-neutral-500 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {isLoadingRepos ? <Loader2 className="h-4 w-4 animate-spin" /> : <Search className="h-4 w-4" />}
                      Search
                    </button>
                  </div>
                </>
              )}
            </div>

            {/* Repository List */}
            {selectedConnection && !selectedRepo && (
              <div className="rounded-lg border border-neutral-800 bg-neutral-900/40">
                {isLoadingRepos ? (
                  <div className="flex items-center justify-center py-8 text-sm text-neutral-400">
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    Loading repositories...
                  </div>
                ) : repos.length > 0 ? (
                  <ul className="divide-y divide-neutral-800 max-h-64 overflow-y-auto">
                    {repos.map((repo) => (
                      <li
                        key={repo.full_name}
                        className="flex items-center justify-between px-4 py-3 hover:bg-neutral-900/60 transition-colors"
                      >
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-medium text-white">{repo.full_name}</p>
                          {repo.updated_at && (
                            <p className="text-xs text-neutral-500">
                              Updated {new Date(repo.updated_at).toLocaleDateString()}
                            </p>
                          )}
                        </div>
                        <button
                          type="button"
                          onClick={() => setSelectedRepo(repo.full_name)}
                          className="ml-4 rounded-lg bg-sky-500/10 px-3 py-1.5 text-xs font-semibold text-sky-400 transition hover:bg-sky-500/20 hover:text-sky-300"
                        >
                          Select
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <div className="flex flex-col items-center justify-center py-8 text-sm text-neutral-400">
                    <p>No repositories found</p>
                    <p className="mt-1 text-xs text-neutral-500">
                      Click Search to load repositories from {selectedConnection.accountLogin || "this connection"}
                    </p>
                  </div>
                )}
              </div>
            )}

            {/* Continue Button - only show if repo selected */}
            {selectedRepo && (
              <div className="flex flex-col gap-3">
                {errorMessage && (
                  <div className="text-sm text-red-400">{errorMessage}</div>
                )}
                <button
                  type="button"
                  onClick={handleContinue}
                  disabled={isNavigating || !selectedRepo.trim()}
                  className="inline-flex items-center justify-center gap-2 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-black transition hover:bg-neutral-200 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {isNavigating ? (
                    <>
                      <Loader2 className="h-4 w-4 animate-spin" />
                      Loading workspace...
                    </>
                  ) : (
                    "Continue to configure environment"
                  )}
                </button>
                <p className="text-xs text-neutral-500">
                  We&apos;ll provision a workspace where you can configure scripts, environment variables, and test your setup
                </p>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
