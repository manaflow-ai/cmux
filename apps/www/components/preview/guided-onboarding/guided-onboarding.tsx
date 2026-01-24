"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import posthog from "posthog-js";
import { SetupLoading } from "./setup-loading";
import { SetupWorkspace } from "./setup-workspace";

type Phase = "starting" | "ready" | "saving" | "complete" | "error";

interface GuidedOnboardingProps {
  teamSlugOrId: string;
  repo: string;
  installationId: string | null;
  initialEnvVarsContent?: string | null;
}

export function GuidedOnboarding({
  teamSlugOrId,
  repo,
  installationId,
  initialEnvVarsContent,
}: GuidedOnboardingProps) {
  const [phase, setPhase] = useState<Phase>("starting");
  const [status, setStatus] = useState("Waiting for machine to start");
  const [vscodeUrl, setVscodeUrl] = useState<string | null>(null);
  const [sandboxId, setSandboxId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const hasStarted = useRef(false);

  const startSandbox = useCallback(async () => {
    setStatus("Starting machine...");

    try {
      const response = await fetch("/api/sandboxes/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({
          teamSlugOrId,
          repoUrl: `https://github.com/${repo}`,
          isCloudWorkspace: true,
          metadata: {
            source: "preview-new-onboarding",
          },
        }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(errorText || `HTTP ${response.status}`);
      }

      const data = await response.json();
      setVscodeUrl(data.vscodeUrl);
      setSandboxId(data.instanceId);

      // Spawn Claude Code to help with environment setup
      setStatus("Starting setup assistant...");
      try {
        const repoName = repo.split("/").pop() || repo;
        const spawnResponse = await fetch(`/api/sandboxes/${data.instanceId}/spawn-agent`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            teamSlugOrId,
            prompt: `You are helping set up the development environment for the ${repoName} repository.

Your goal is to guide the user through:
1. Installing dependencies (check package.json, requirements.txt, Cargo.toml, etc.)
2. Setting up environment variables (look for .env.example, .env.template)
3. Starting the development server

Be concise and helpful. Start by exploring the repository structure and identifying what needs to be done. Ask the user questions if you need clarification.

Important: The user can see and interact with the terminal. Guide them through each step and explain what commands do.`,
          }),
        });

        if (!spawnResponse.ok) {
          console.warn("Failed to spawn Claude Code agent, continuing without it");
        } else {
          console.log("Claude Code agent spawned for environment setup");
        }
      } catch (spawnErr) {
        // Non-fatal: continue even if agent spawn fails
        console.warn("Failed to spawn Claude Code agent:", spawnErr);
      }

      setStatus("Machine ready");
      setPhase("ready");

      posthog.capture("guided_onboarding_sandbox_ready", {
        repo_full_name: repo,
        sandbox_id: data.instanceId,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Failed to start machine";
      console.error("Failed to start sandbox:", err);
      setError(message);
      setPhase("error");
    }
  }, [repo, teamSlugOrId]);

  // Start the sandbox when component mounts
  useEffect(() => {
    if (hasStarted.current) return;
    hasStarted.current = true;

    posthog.capture("guided_onboarding_started", {
      repo_full_name: repo,
      team_slug_or_id: teamSlugOrId,
    });

    startSandbox();
  }, [repo, teamSlugOrId, startSandbox]);

  const handleComplete = useCallback(
    async (config: Record<string, string>) => {
      setPhase("saving");

      const repoName = repo.split("/").pop() || "preview";
      const dateTime = new Date().toISOString().replace(/[:.]/g, "-").slice(0, -5);
      const envName = `${repoName}-${dateTime}`;

      const envVarsContent = initialEnvVarsContent || "";
      const browserNotes = config["browser-setup"]?.trim();
      const additionalNotes = config["additional-notes"]?.trim();
      const description = [
        browserNotes ? `Browser setup:\\n${browserNotes}` : null,
        additionalNotes ? `Additional notes:\\n${additionalNotes}` : null,
      ]
        .filter((note): note is string => Boolean(note))
        .join("\\n\\n");

      try {
        // Create environment
        const envResponse = await fetch("/api/environments", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            teamSlugOrId,
            name: envName,
            envVarsContent: envVarsContent || initialEnvVarsContent || "",
            selectedRepos: [repo],
            maintenanceScript: config["install-deps"],
            devScript: config["dev-server"],
            description: description || "",
          }),
        });

        if (!envResponse.ok) {
          throw new Error(await envResponse.text());
        }

        const envData = await envResponse.json();

        // Create preview config
        const previewResponse = await fetch("/api/preview/configs", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            teamSlugOrId,
            repoFullName: repo,
            environmentId: envData.id,
            repoInstallationId: installationId ? Number(installationId) : undefined,
            repoDefaultBranch: "main",
            status: "active",
          }),
        });

        if (!previewResponse.ok) {
          throw new Error(await previewResponse.text());
        }

        posthog.capture("guided_onboarding_completed", {
          repo_full_name: repo,
          team_slug_or_id: teamSlugOrId,
          sandbox_id: sandboxId,
        });

        setPhase("complete");

        // Redirect to dashboard
        setTimeout(() => {
          window.location.href = "/preview-new";
        }, 1500);
      } catch (err) {
        const message = err instanceof Error ? err.message : "Failed to save configuration";
        console.error("Failed to save:", err);
        setError(message);
        setPhase("error");
      }
    },
    [repo, teamSlugOrId, installationId, sandboxId, initialEnvVarsContent]
  );

  const handleFinishLater = useCallback(() => {
    posthog.capture("guided_onboarding_finish_later", {
      repo_full_name: repo,
      team_slug_or_id: teamSlugOrId,
    });
    window.location.href = "/preview-new";
  }, [repo, teamSlugOrId]);

  const handleRetry = useCallback(() => {
    setError(null);
    setPhase("starting");
    hasStarted.current = false;
    startSandbox();
  }, [startSandbox]);

  // Loading state
  if (phase === "starting") {
    return <SetupLoading repo={repo} status={status} />;
  }

  // Error state
  if (phase === "error") {
    return (
      <div className="min-h-dvh bg-[#0d1117] text-neutral-100 flex items-center justify-center">
        <div className="max-w-md text-center px-6">
          <div className="w-16 h-16 rounded-full bg-red-500/10 flex items-center justify-center mx-auto mb-4">
            <svg className="w-8 h-8 text-red-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
          </div>
          <h2 className="text-lg font-medium mb-2">Setup failed</h2>
          <p className="text-sm text-neutral-400 mb-6">{error}</p>
          <div className="flex gap-3 justify-center">
            <button
              onClick={handleRetry}
              className="px-4 py-2 text-sm font-medium bg-neutral-800 hover:bg-neutral-700 text-neutral-200 rounded transition"
            >
              Try again
            </button>
            <button
              onClick={handleFinishLater}
              className="px-4 py-2 text-sm font-medium text-neutral-400 hover:text-neutral-200 transition"
            >
              Go to dashboard
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Saving/Complete state
  if (phase === "saving" || phase === "complete") {
    return (
      <div className="min-h-dvh bg-[#0d1117] text-neutral-100 flex items-center justify-center">
        <div className="text-center">
          {phase === "saving" ? (
            <>
              <div className="w-8 h-8 border-2 border-neutral-600 border-t-neutral-100 rounded-full animate-spin mx-auto mb-4" />
              <p className="text-sm text-neutral-400">Saving configuration...</p>
            </>
          ) : (
            <>
              <div className="w-16 h-16 rounded-full bg-emerald-500/10 flex items-center justify-center mx-auto mb-4">
                <svg className="w-8 h-8 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                </svg>
              </div>
              <h2 className="text-lg font-medium mb-2">Setup complete!</h2>
              <p className="text-sm text-neutral-400">Redirecting to dashboard...</p>
            </>
          )}
        </div>
      </div>
    );
  }

  // Ready state - show workspace
  if (vscodeUrl) {
    return (
      <SetupWorkspace
        repo={repo}
        vscodeUrl={vscodeUrl}
        teamSlugOrId={teamSlugOrId}
        onComplete={handleComplete}
        onFinishLater={handleFinishLater}
      />
    );
  }

  return null;
}
