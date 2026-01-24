"use client";

import { Loader2 } from "lucide-react";
import { SETUP_STEPS } from "./setup-steps";
import { OnboardingShell } from "../onboarding-shell";

interface SetupLoadingProps {
  repo: string;
  status: string;
}

export function SetupLoading({ repo, status }: SetupLoadingProps) {
  const repoName = repo.split("/").pop() || repo;

  return (
    <OnboardingShell
      sidebarHeader={
        <div>
          <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">Repository setup</h2>
          <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">Configure {repoName}</p>
          <p className="text-xs text-neutral-500 dark:text-neutral-500 mt-2">
            0/{SETUP_STEPS.length} steps
          </p>
        </div>
      }
      sidebarBody={
        <div className="p-4 space-y-3">
          {SETUP_STEPS.map((step, index) => (
            <div
              key={step.id}
              className="flex items-center gap-3 rounded-xl border border-neutral-200/70 dark:border-neutral-800/80 bg-white/80 dark:bg-neutral-900/40 px-3 py-2"
            >
              <div className="h-7 w-7 rounded-full border border-neutral-200 dark:border-neutral-700 text-[11px] text-neutral-500 dark:text-neutral-400 flex items-center justify-center">
                {index + 1}
              </div>
              <div className="flex-1">
                <p className="text-sm text-neutral-700 dark:text-neutral-200">{step.title}</p>
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  {index === 0 ? "Queued" : "Waiting"}
                </p>
              </div>
              <span className="h-2 w-2 rounded-full bg-neutral-300 dark:bg-neutral-700 animate-pulse" />
            </div>
          ))}
        </div>
      }
      sidebarFooter={
        <div className="rounded-xl border border-neutral-200/70 dark:border-neutral-800 bg-white/90 dark:bg-neutral-900/40 p-3 text-xs text-neutral-500 dark:text-neutral-400">
          <p className="text-neutral-700 dark:text-neutral-200 font-medium mb-1">Provisioning your workspace</p>
          <p>We&apos;ll drop you into a live terminal as soon as the machine is ready.</p>
        </div>
      }
      mainHeader={
        <>
          <div className="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400">
            <span className="inline-flex h-2 w-2 rounded-full bg-amber-400 animate-pulse" />
            Provisioning environment
          </div>
          <div className="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400">
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            {status}
          </div>
        </>
      }
      mainBody={
        <div className="flex-1 p-4 lg:p-6">
          <div className="h-full grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,320px)]">
            <div className="relative rounded-2xl border border-neutral-200/70 dark:border-neutral-800 bg-neutral-100/70 dark:bg-neutral-900/40 overflow-hidden">
              <div className="flex items-center gap-2 px-4 py-2 border-b border-neutral-200/70 dark:border-neutral-800 text-xs text-neutral-500 dark:text-neutral-400 bg-white/70 dark:bg-neutral-950/40">
                <div className="flex items-center gap-2">
                  <span className="h-2 w-2 rounded-full bg-neutral-400" />
                  <span>Setup Agent</span>
                </div>
                <span className="text-neutral-300 dark:text-neutral-600">•</span>
                <span className="text-neutral-400 dark:text-neutral-500">README.md</span>
              </div>

              <div className="flex h-full items-center justify-center p-6">
                <div className="w-full max-w-lg rounded-2xl border border-neutral-200/80 dark:border-neutral-800 bg-white/90 dark:bg-neutral-950/70 shadow-sm">
                  <div className="p-5">
                    <p className="text-xs uppercase tracking-[0.2em] text-neutral-400 dark:text-neutral-500 mb-2">
                      Setup agent
                    </p>
                    <h1 className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
                      Let&apos;s set up your machine together.
                    </h1>
                    <p className="text-sm text-neutral-600 dark:text-neutral-300 mt-2">
                      I&apos;ll guide you through each step and keep the terminal ready for commands.
                    </p>
                    <div className="mt-4 flex items-center gap-2">
                      <div className="flex-1 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900 px-3 py-2 text-xs text-neutral-400 dark:text-neutral-500">
                        I&apos;m ready. Let&apos;s proceed with the setup steps.
                      </div>
                      <button
                        disabled
                        className="px-3 py-2 text-xs font-medium rounded-lg bg-neutral-200 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-500"
                      >
                        Submit
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div className="rounded-2xl border border-neutral-200/70 dark:border-neutral-800 bg-neutral-950/95 text-neutral-100 overflow-hidden">
              <div className="flex items-center gap-2 px-4 py-2 border-b border-neutral-800 text-xs text-neutral-400">
                <span className="h-2 w-2 rounded-full bg-neutral-500 animate-pulse" />
                Terminal
              </div>
              <div className="p-4 font-mono text-xs text-neutral-400 space-y-2">
                <p>$ starting environment…</p>
                <p className="text-neutral-500">waiting for machine readiness</p>
                <div className="flex items-center gap-2 text-neutral-500">
                  <Loader2 className="h-3 w-3 animate-spin" />
                  preparing pty session
                </div>
              </div>
            </div>
          </div>
        </div>
      }
      sidebarClassName="lg:w-80"
    />
  );
}
