"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import posthog from "posthog-js";
import {
  Loader2,
  ArrowLeft,
  Eye,
  EyeOff,
  Minus,
  Plus,
  ChevronDown,
  Check,
} from "lucide-react";
import Link from "next/link";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import clsx from "clsx";

const MASKED_ENV_VALUE = "••••••••••••••••";

type EnvVar = { name: string; value: string; isSecret: boolean };

type PreviewTeamOption = {
  id: string;
  slug: string | null;
  slugOrId: string;
  displayName: string;
  name: string | null;
};

type PreviewNewConfigureClientProps = {
  initialTeamSlugOrId: string;
  teams: PreviewTeamOption[];
  repo: string;
  installationId: string | null;
  initialEnvVarsContent?: string | null;
};

const ensureInitialEnvVars = (initial?: EnvVar[]): EnvVar[] => {
  const base = (initial ?? []).map((item) => ({
    name: item.name,
    value: item.value,
    isSecret: item.isSecret ?? true,
  }));
  if (base.length === 0) {
    return [{ name: "", value: "", isSecret: true }];
  }
  const last = base[base.length - 1];
  if (!last || last.name.trim().length > 0 || last.value.trim().length > 0) {
    base.push({ name: "", value: "", isSecret: true });
  }
  return base;
};

function parseEnvBlock(text: string): Array<{ name: string; value: string }> {
  const normalized = text.replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const results: Array<{ name: string; value: string }> = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (
      trimmed.length === 0 ||
      trimmed.startsWith("#") ||
      trimmed.startsWith("//")
    )
      continue;

    const cleanLine = trimmed.replace(/^export\s+/, "").replace(/^set\s+/, "");
    const eqIdx = cleanLine.indexOf("=");

    if (eqIdx === -1) continue;

    const key = cleanLine.slice(0, eqIdx).trim();
    let value = cleanLine.slice(eqIdx + 1).trim();

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    if (key && !/\s/.test(key)) {
      results.push({ name: key, value });
    }
  }

  return results;
}

export function PreviewNewConfigureClient({
  initialTeamSlugOrId,
  teams,
  repo,
  installationId: _installationId,
  initialEnvVarsContent,
}: PreviewNewConfigureClientProps) {
  const initialEnvVars = useMemo(() => {
    const parsed = initialEnvVarsContent
      ? parseEnvBlock(initialEnvVarsContent).map((entry) => ({
          name: entry.name,
          value: entry.value,
          isSecret: true,
        }))
      : undefined;
    return ensureInitialEnvVars(parsed);
  }, [initialEnvVarsContent]);

  const [envVars, setEnvVars] = useState<EnvVar[]>(initialEnvVars);
  const [_hasTouchedEnvVars, setHasTouchedEnvVars] = useState(false);
  const [envNone, setEnvNone] = useState(false);
  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(null);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const selectedTeamSlugOrId = useMemo(
    () => initialTeamSlugOrId || teams[0]?.slugOrId || "",
    [initialTeamSlugOrId, teams]
  );

  const selectedTeam = useMemo(
    () =>
      teams.find((team) => team.slugOrId === selectedTeamSlugOrId) ??
      teams[0] ??
      null,
    [selectedTeamSlugOrId, teams]
  );

  const resolvedTeamSlugOrId =
    selectedTeam?.slugOrId ?? initialTeamSlugOrId ?? teams[0]?.slugOrId ?? "";

  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);

  // Track page view
  useEffect(() => {
    posthog.capture("preview_new_config_view", {
      repo_full_name: repo,
      team_slug_or_id: selectedTeamSlugOrId,
    });
  }, [repo, selectedTeamSlugOrId]);

  useEffect(() => {
    if (pendingFocusIndex !== null) {
      const el = keyInputRefs.current[pendingFocusIndex];
      if (el) {
        setTimeout(() => {
          el.focus();
          try {
            el.scrollIntoView({ block: "nearest" });
          } catch {
            void 0;
          }
        }, 0);
        setPendingFocusIndex(null);
      }
    }
  }, [pendingFocusIndex, envVars]);

  const updateEnvVars = useCallback((updater: (prev: EnvVar[]) => EnvVar[]) => {
    setHasTouchedEnvVars(true);
    setEnvVars((prev) => updater(prev));
  }, []);

  const handleSaveConfiguration = async () => {
    if (!resolvedTeamSlugOrId) {
      setErrorMessage("Select a team before saving.");
      return;
    }

    const now = new Date();
    const dateTime = now.toISOString().replace(/[:.]/g, "-").slice(0, -5);
    const repoName = repo.split("/").pop() || "preview";
    const envName = `${repoName}-${dateTime}`;

    const envVarsContent = formatEnvVarsContent(
      envVars
        .filter((r) => r.name.trim().length > 0)
        .map((r) => ({ name: r.name, value: r.value }))
    );

    setIsSaving(true);
    setErrorMessage(null);

    try {
      // Create environment without a Morph instance (simplified flow)
      const envResponse = await fetch("/api/environments", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: resolvedTeamSlugOrId,
          name: envName,
          envVarsContent,
          selectedRepos: [repo],
          // No morphInstanceId, maintenanceScript, or devScript needed
        }),
      });

      if (!envResponse.ok) {
        throw new Error(await envResponse.text());
      }

      const envData = await envResponse.json();
      const environmentId = envData.id;

      // Create preview config
      const previewResponse = await fetch("/api/preview/configs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: resolvedTeamSlugOrId,
          repoFullName: repo,
          environmentId,
          repoInstallationId: _installationId
            ? Number(_installationId)
            : undefined,
          repoDefaultBranch: "main",
          status: "active",
        }),
      });

      if (!previewResponse.ok) {
        throw new Error(await previewResponse.text());
      }

      // Track configuration completed
      posthog.capture("preview_new_config_completed", {
        repo_full_name: repo,
        team_slug_or_id: selectedTeamSlugOrId,
        has_env_vars: envVarsContent.length > 0,
      });

      window.location.href = "/preview-new";
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to save configuration";
      setErrorMessage(message);
      console.error("Failed to save preview configuration:", error);
    } finally {
      setIsSaving(false);
    }
  };

  // Shared render function for environment variables section
  const renderEnvVarsSection = () => {
    return (
      <details className="group" open>
        <summary className="flex items-center gap-2 cursor-pointer font-semibold text-neutral-900 dark:text-neutral-100 list-none text-base">
          <ChevronDown className="h-4 w-4 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
          <span>Environment Variables</span>
          <span className="ml-1 text-xs font-normal text-neutral-400">(optional)</span>
          <div className="ml-auto flex items-center gap-2">
            <button
              type="button"
              onClick={(e) => {
                e.preventDefault();
                setActiveEnvValueIndex(null);
                setAreEnvValuesHidden((prev) => !prev);
              }}
              className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 transition p-0.5"
              aria-label={areEnvValuesHidden ? "Reveal values" : "Hide values"}
            >
              {areEnvValuesHidden ? (
                <EyeOff className="h-4 w-4" />
              ) : (
                <Eye className="h-4 w-4" />
              )}
            </button>
          </div>
        </summary>
        <div
          className="mt-4 pl-6 space-y-2"
          onPasteCapture={(e) => {
            const text = e.clipboardData?.getData("text") ?? "";
            if (text && (/\n/.test(text) || /(=|:)\s*\S/.test(text))) {
              e.preventDefault();
              const items = parseEnvBlock(text);
              if (items.length > 0) {
                setEnvNone(false);
                updateEnvVars((prev) => {
                  const map = new Map(
                    prev
                      .filter(
                        (r) =>
                          r.name.trim().length > 0 || r.value.trim().length > 0
                      )
                      .map((r) => [r.name, r] as const)
                  );
                  for (const it of items) {
                    if (!it.name) continue;
                    const existing = map.get(it.name);
                    if (existing)
                      map.set(it.name, { ...existing, value: it.value });
                    else
                      map.set(it.name, {
                        name: it.name,
                        value: it.value,
                        isSecret: true,
                      });
                  }
                  const next = Array.from(map.values());
                  next.push({ name: "", value: "", isSecret: true });
                  setPendingFocusIndex(next.length - 1);
                  return next;
                });
              }
            }
          }}
        >
          <div
            className="grid gap-2 text-xs text-neutral-500 items-center mb-1"
            style={{
              gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.5fr) 40px",
            }}
          >
            <span>Name</span>
            <span>Value</span>
            <span />
          </div>
          {envVars.map((row, idx) => {
            const isEditingValue = activeEnvValueIndex === idx;
            const shouldMaskValue =
              areEnvValuesHidden &&
              row.value.trim().length > 0 &&
              !isEditingValue;
            return (
              <div
                key={idx}
                className="grid gap-2 items-center min-h-9"
                style={{
                  gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.5fr) 40px",
                }}
              >
                <input
                  type="text"
                  value={row.name}
                  disabled={envNone}
                  ref={(el) => {
                    keyInputRefs.current[idx] = el;
                  }}
                  onChange={(e) => {
                    setEnvNone(false);
                    updateEnvVars((prev) => {
                      const next = [...prev];
                      if (next[idx])
                        next[idx] = { ...next[idx], name: e.target.value };
                      return next;
                    });
                  }}
                  placeholder="EXAMPLE_NAME"
                  className="w-full min-w-0 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 disabled:opacity-60 disabled:cursor-not-allowed"
                />
                <input
                  type={shouldMaskValue ? "password" : "text"}
                  value={shouldMaskValue ? MASKED_ENV_VALUE : row.value}
                  disabled={envNone}
                  onChange={
                    shouldMaskValue
                      ? undefined
                      : (e) => {
                          setEnvNone(false);
                          updateEnvVars((prev) => {
                            const next = [...prev];
                            if (next[idx])
                              next[idx] = {
                                ...next[idx],
                                value: e.target.value,
                              };
                            return next;
                          });
                        }
                  }
                  onFocus={() => setActiveEnvValueIndex(idx)}
                  onBlur={() =>
                    setActiveEnvValueIndex((current) =>
                      current === idx ? null : current
                    )
                  }
                  readOnly={shouldMaskValue}
                  placeholder="I9JU23NF394R6HH"
                  className="w-full min-w-0 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 disabled:opacity-60 disabled:cursor-not-allowed"
                />
                <button
                  type="button"
                  disabled={envNone || envVars.length <= 1}
                  onClick={() =>
                    updateEnvVars((prev) => {
                      const next = prev.filter((_, i) => i !== idx);
                      return next.length > 0
                        ? next
                        : [{ name: "", value: "", isSecret: true }];
                    })
                  }
                  className={clsx(
                    "h-9 w-9 rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-500 dark:text-neutral-400 grid place-items-center",
                    envNone || envVars.length <= 1
                      ? "opacity-60 cursor-not-allowed"
                      : "hover:bg-neutral-50 dark:hover:bg-neutral-900"
                  )}
                  aria-label="Remove variable"
                >
                  <Minus className="w-4 h-4" />
                </button>
              </div>
            );
          })}
          <div className="mt-1">
            <button
              type="button"
              onClick={() =>
                updateEnvVars((prev) => [
                  ...prev,
                  { name: "", value: "", isSecret: true },
                ])
              }
              disabled={envNone}
              className="inline-flex items-center gap-2 h-9 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900 transition disabled:opacity-60 disabled:cursor-not-allowed"
            >
              <Plus className="w-4 h-4" /> Add variable
            </button>
          </div>
        </div>
        <p className="text-xs text-neutral-400 mt-4 pl-6">
          Tip: Paste a .env file to auto-fill
        </p>
      </details>
    );
  };

  return (
    <div className="min-h-dvh bg-white dark:bg-black font-sans">
      <div className="max-w-2xl mx-auto px-6 py-10">
        {/* Back to preview-new link */}
        <div className="mb-3">
          <Link
            href="/preview-new"
            className="inline-flex items-center gap-1.5 text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
          >
            <ArrowLeft className="h-3 w-3" />
            Back to dashboard
          </Link>
        </div>

        {/* Header */}
        <div className="mb-8">
          <h1 className="text-2xl font-semibold text-neutral-900 dark:text-neutral-100 mb-1">
            Connect repository
          </h1>
          <div className="flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 pt-2">
            <svg
              className="h-4 w-4 shrink-0"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
            </svg>
            <span className="font-sans">{repo}</span>
            <Check className="h-4 w-4 text-emerald-500 ml-1" />
            <span className="text-emerald-600 dark:text-emerald-400 text-xs">Connected</span>
          </div>
        </div>

        {/* Environment Variables Section */}
        <div className="space-y-6">
          {renderEnvVarsSection()}
        </div>

        {/* Error Message */}
        {errorMessage && (
          <div className="rounded-md bg-red-50 dark:bg-red-950/20 border border-red-200 dark:border-red-900/50 p-3 mt-6">
            <p className="text-sm text-red-600 dark:text-red-400">
              {errorMessage}
            </p>
          </div>
        )}

        {/* Save Button */}
        <div className="mt-8 pt-6 border-t border-neutral-200 dark:border-neutral-800">
          <button
            type="button"
            onClick={handleSaveConfiguration}
            disabled={isSaving}
            className="w-full inline-flex items-center justify-center rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-5 py-2.5 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"
          >
            {isSaving ? (
              <>
                <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                Saving...
              </>
            ) : (
              "Save configuration"
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
