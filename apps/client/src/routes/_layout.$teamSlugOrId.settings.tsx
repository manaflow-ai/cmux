import { ContainerSettings } from "@/components/ContainerSettings";
import { FloatingPane } from "@/components/floating-pane";
import { ProviderStatusSettings } from "@/components/provider-status-settings";
import { useTheme } from "@/components/theme/use-theme";
import { TitleBar } from "@/components/TitleBar";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { AGENT_CONFIGS, type AgentConfig } from "@cmux/shared/agentConfig";
import { API_KEY_MODELS_BY_ENV } from "@cmux/shared/model-usage";
import { convexQuery } from "@convex-dev/react-query";
import { Switch } from "@heroui/react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useConvex } from "convex/react";
import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

export const Route = createFileRoute("/_layout/$teamSlugOrId/settings")({
  component: SettingsComponent,
});

function SettingsComponent() {
  const { teamSlugOrId } = Route.useParams();
  const { resolvedTheme, setTheme } = useTheme();
  const convex = useConvex();
  const [apiKeyValues, setApiKeyValues] = useState<Record<string, string>>({});
  const [originalApiKeyValues, setOriginalApiKeyValues] = useState<
    Record<string, string>
  >({});
  const [showKeys, setShowKeys] = useState<Record<string, boolean>>({});
  const [isSaving, setIsSaving] = useState(false);
  const [teamSlug, setTeamSlug] = useState<string>("");
  const [originalTeamSlug, setOriginalTeamSlug] = useState<string>("");
  const [teamName, setTeamName] = useState<string>("");
  const [originalTeamName, setOriginalTeamName] = useState<string>("");
  const [teamNameError, setTeamNameError] = useState<string>("");
  const [teamSlugError, setTeamSlugError] = useState<string>("");
  const [worktreePath, setWorktreePath] = useState<string>("");
  const [originalWorktreePath, setOriginalWorktreePath] = useState<string>("");
  const [autoPrEnabled, setAutoPrEnabled] = useState<boolean>(false);
  const [originalAutoPrEnabled, setOriginalAutoPrEnabled] =
    useState<boolean>(false);
  // const [isSaveButtonVisible, setIsSaveButtonVisible] = useState(true);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const saveButtonRef = useRef<HTMLDivElement>(null);
  const usedListRefs = useRef<Record<string, HTMLSpanElement | null>>({});
  const [expandedUsedList, setExpandedUsedList] = useState<
    Record<string, boolean>
  >({});
  const [overflowUsedList, setOverflowUsedList] = useState<
    Record<string, boolean>
  >({});
  const [containerSettingsData, setContainerSettingsData] = useState<{
    maxRunningContainers: number;
    reviewPeriodMinutes: number;
    autoCleanupEnabled: boolean;
    stopImmediatelyOnCompletion: boolean;
    minContainersToKeep: number;
  } | null>(null);
  const [originalContainerSettingsData, setOriginalContainerSettingsData] =
    useState<typeof containerSettingsData>(null);

  // Get all required API keys from agent configs
  const apiKeys = Array.from(
    new Map(
      AGENT_CONFIGS.flatMap((config: AgentConfig) => config.apiKeys || []).map(
        (key) => [key.envVar, key]
      )
    ).values()
  );

  // Global mapping of envVar -> models (from shared)
  const apiKeyModelsByEnv = API_KEY_MODELS_BY_ENV;

  // Query existing API keys
  const { data: existingKeys } = useQuery(
    convexQuery(api.apiKeys.getAll, { teamSlugOrId })
  );

  // Query team info (slug)
  const { data: teamInfo } = useQuery(
    convexQuery(api.teams.get, { teamSlugOrId })
  );

  // Query workspace settings
  const { data: workspaceSettings } = useQuery(
    convexQuery(api.workspaceSettings.get, { teamSlugOrId })
  );

  // Initialize form values when data loads
  useEffect(() => {
    if (existingKeys) {
      const values: Record<string, string> = {};
      existingKeys.forEach((key: Doc<"apiKeys">) => {
        values[key.envVar] = key.value;
      });
      setApiKeyValues(values);
      setOriginalApiKeyValues(values);
    }
  }, [existingKeys]);

  // Initialize team slug when data loads
  useEffect(() => {
    if (teamInfo) {
      const s = teamInfo.slug || "";
      setTeamSlug(s);
      setOriginalTeamSlug(s);
      setTeamSlugError("");
      const n =
        (teamInfo as unknown as { name?: string; displayName?: string }).name ||
        (teamInfo as unknown as { name?: string; displayName?: string })
          .displayName ||
        "";
      setTeamName(n);
      setOriginalTeamName(n);
      setTeamNameError("");
    }
  }, [teamInfo]);

  // Client-side validators
  const validateName = (val: string): string => {
    const t = val.trim();
    if (t.length === 0) return "Name is required";
    if (t.length > 32) return "Name must be at most 32 characters";
    return "";
  };

  const validateSlug = (val: string): string => {
    const t = val.trim();
    if (t.length === 0) return "Slug is required";
    if (t.length < 3 || t.length > 48) return "Slug must be 3–48 characters";
    if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(t))
      return "Use lowercase letters, numbers, and hyphens; start/end with letter or number";
    return "";
  };

  // Initialize worktree path when data loads
  useEffect(() => {
    if (workspaceSettings !== undefined) {
      setWorktreePath(workspaceSettings?.worktreePath || "");
      setOriginalWorktreePath(workspaceSettings?.worktreePath || "");
      const enabled = (
        workspaceSettings as unknown as { autoPrEnabled?: boolean }
      )?.autoPrEnabled;
      const effective = enabled === undefined ? false : Boolean(enabled);
      setAutoPrEnabled(effective);
      setOriginalAutoPrEnabled(effective);
    }
  }, [workspaceSettings]);

  // Track save button visibility
  // Footer-based save button; no visibility tracking needed

  // Recompute overflow detection for "Used for agents" lines
  useEffect(() => {
    const recompute = () => {
      const updates: Record<string, boolean> = {};
      for (const key of Object.keys(usedListRefs.current)) {
        const el = usedListRefs.current[key];
        if (!el) continue;
        updates[key] = el.scrollWidth > el.clientWidth;
      }
      setOverflowUsedList((prev) => {
        let changed = false;
        const next: Record<string, boolean> = { ...prev };
        for (const k of Object.keys(updates)) {
          if (prev[k] !== updates[k]) {
            next[k] = updates[k];
            changed = true;
          }
        }
        return changed ? next : prev;
      });
    };

    recompute();
    const handler = () => recompute();
    window.addEventListener("resize", handler);
    const id = window.setTimeout(recompute, 0);
    return () => {
      window.removeEventListener("resize", handler);
      window.clearTimeout(id);
    };
  }, [apiKeys, apiKeyModelsByEnv]);

  // Mutation to save API keys
  const saveApiKeyMutation = useMutation({
    mutationFn: async (data: {
      envVar: string;
      value: string;
      displayName: string;
      description?: string;
    }) => {
      return await convex.mutation(api.apiKeys.upsert, {
        teamSlugOrId,
        ...data,
      });
    },
  });

  const handleApiKeyChange = (envVar: string, value: string) => {
    setApiKeyValues((prev) => ({ ...prev, [envVar]: value }));
  };

  const toggleShowKey = (envVar: string) => {
    setShowKeys((prev) => ({ ...prev, [envVar]: !prev[envVar] }));
  };

  const handleContainerSettingsChange = useCallback(
    (data: {
      maxRunningContainers: number;
      reviewPeriodMinutes: number;
      autoCleanupEnabled: boolean;
      stopImmediatelyOnCompletion: boolean;
      minContainersToKeep: number;
    }) => {
      setContainerSettingsData(data);
      if (!originalContainerSettingsData) {
        setOriginalContainerSettingsData(data);
      }
    },
    [originalContainerSettingsData]
  );

  // Check if there are any changes
  const hasChanges = () => {
    // Check worktree path changes
    const worktreePathChanged = worktreePath !== originalWorktreePath;

    // Check all required API keys for changes
    const apiKeysChanged = apiKeys.some((keyConfig) => {
      const currentValue = apiKeyValues[keyConfig.envVar] || "";
      const originalValue = originalApiKeyValues[keyConfig.envVar] || "";
      return currentValue !== originalValue;
    });

    // Check container settings changes
    const containerSettingsChanged =
      containerSettingsData &&
      originalContainerSettingsData &&
      JSON.stringify(containerSettingsData) !==
        JSON.stringify(originalContainerSettingsData);

    // Auto PR toggle changes
    const autoPrChanged = autoPrEnabled !== originalAutoPrEnabled;

    return (
      worktreePathChanged ||
      autoPrChanged ||
      apiKeysChanged ||
      containerSettingsChanged
    );
  };

  const saveApiKeys = async () => {
    setIsSaving(true);

    try {
      let savedCount = 0;
      let deletedCount = 0;

      // Save worktree path / auto PR if changed
      if (
        worktreePath !== originalWorktreePath ||
        autoPrEnabled !== originalAutoPrEnabled
      ) {
        await convex.mutation(api.workspaceSettings.update, {
          teamSlugOrId,
          worktreePath: worktreePath || undefined,
          autoPrEnabled,
        });
        setOriginalWorktreePath(worktreePath);
        setOriginalAutoPrEnabled(autoPrEnabled);
      }

      // Save container settings if changed
      if (
        containerSettingsData &&
        originalContainerSettingsData &&
        JSON.stringify(containerSettingsData) !==
          JSON.stringify(originalContainerSettingsData)
      ) {
        await convex.mutation(api.containerSettings.update, {
          teamSlugOrId,
          ...containerSettingsData,
        });
        setOriginalContainerSettingsData(containerSettingsData);
      }

      for (const key of apiKeys) {
        const value = apiKeyValues[key.envVar] || "";
        const originalValue = originalApiKeyValues[key.envVar] || "";

        // Only save if the value has changed
        if (value !== originalValue) {
          if (value.trim()) {
            // Save or update the key
            await saveApiKeyMutation.mutateAsync({
              envVar: key.envVar,
              value: value.trim(),
              displayName: key.displayName,
              description: key.description,
            });
            savedCount++;
          } else if (originalValue) {
            // Delete the key if it was cleared
            await convex.mutation(api.apiKeys.remove, {
              teamSlugOrId,
              envVar: key.envVar,
            });
            deletedCount++;
          }
        }
      }

      // Update original values to reflect saved state
      setOriginalApiKeyValues(apiKeyValues);

      // After successful save, hide all API key inputs
      setShowKeys({});

      if (savedCount > 0 || deletedCount > 0) {
        const actions = [];
        if (savedCount > 0) {
          actions.push(`saved ${savedCount} key${savedCount > 1 ? "s" : ""}`);
        }
        if (deletedCount > 0) {
          actions.push(
            `removed ${deletedCount} key${deletedCount > 1 ? "s" : ""}`
          );
        }
        toast.success(`Successfully ${actions.join(" and ")}`);
      } else {
        toast.info("No changes to save");
      }
    } catch (error) {
      toast.error("Failed to save API keys. Please try again.");
      console.error("Error saving API keys:", error);
    } finally {
      setIsSaving(false);
    }
  };

  const saveTeamSlug = async () => {
    const newSlug = teamSlug.trim();
    if (!newSlug) {
      toast.error("Slug cannot be empty");
      return;
    }
    setIsSaving(true);
    try {
      await convex.mutation(api.teams.setSlug, {
        teamSlugOrId,
        slug: newSlug,
      });
      setOriginalTeamSlug(newSlug);
      toast.success("Team slug updated");
      // Navigate to the new URL with the updated slug
      window.location.href = `/${newSlug}/settings`;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      toast.error(msg || "Failed to update slug");
    } finally {
      setIsSaving(false);
    }
  };

  const saveTeamName = async () => {
    const newName = teamName.trim();
    if (!newName) {
      toast.error("Name cannot be empty");
      return;
    }
    setIsSaving(true);
    try {
      await convex.mutation(api.teams.setName, {
        teamSlugOrId,
        name: newName,
      });
      setOriginalTeamName(newName);
      toast.success("Team name updated");
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      toast.error(msg || "Failed to update name");
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <FloatingPane header={<TitleBar title="Settings" />}>
      <div
        ref={scrollContainerRef}
        className="flex flex-col grow overflow-auto select-none relative"
      >
        <div className="p-6 max-w-3xl">
          {/* Header */}
          <div className="mb-6">
            <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
              Settings
            </h1>
            <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
              Manage your workspace preferences and configuration
            </p>
          </div>

          {/* Settings Sections */}
          <div className="space-y-4">
            {/* Team name */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Team Name
                </h2>
              </div>
              <div className="p-4">
                <div>
                  <label
                    htmlFor="teamName"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    Display Name
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    How your team is displayed across cmux.
                  </p>
                  <input
                    type="text"
                    id="teamName"
                    value={teamName}
                    onChange={(e) => {
                      const v = e.target.value;
                      setTeamName(v);
                      setTeamNameError(validateName(v));
                    }}
                    placeholder="Your Team"
                    aria-invalid={teamNameError ? true : undefined}
                    aria-describedby={
                      teamNameError ? "team-name-error" : undefined
                    }
                    className={`w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 ${
                      teamNameError
                        ? "border-red-500 focus:ring-red-500"
                        : "border-neutral-300 dark:border-neutral-700 focus:ring-blue-500"
                    }`}
                  />
                  {teamNameError && (
                    <p
                      id="team-name-error"
                      className="mt-2 text-xs text-red-600 dark:text-red-500"
                    >
                      {teamNameError}
                    </p>
                  )}
                </div>

                {/* URL Preview removed
                <div className="pt-2">
                  <label className="block text-xs font-medium text-neutral-500 dark:text-neutral-400 mb-1">Preview</label>
                  <div className="rounded-xl border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 overflow-hidden">
                    <div className="flex items-center gap-3 px-3 sm:px-4 h-9 border-b border-neutral-200 dark:border-neutral-800 bg-neutral-50/70 dark:bg-neutral-900/70">
                      window controls
                      <div className="flex items-center gap-1.5">
                        <span className="h-2.5 w-2.5 rounded-full bg-[#ff5f56]" aria-hidden />
                        <span className="h-2.5 w-2.5 rounded-full bg-[#ffbd2e]" aria-hidden />
                        <span className="h-2.5 w-2.5 rounded-full bg-[#27c93f]" aria-hidden />
                      </div>
                      <div className="flex-1 flex items-center justify-center">
                        <div className="flex items-center gap-2 min-w-0 max-w-full px-3 h-7 rounded-full border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-xs sm:text-sm text-neutral-700 dark:text-neutral-300 shadow-[inset_0_1px_0_rgba(255,255,255,0.5)] dark:shadow-none">
                          <svg className="h-3.5 w-3.5 text-green-600 dark:text-green-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                            <path d="M10 13a5 5 0 0 1 7 7l-7-7z"></path>
                            <path d="M14.5 12.5a5 5 0 1 0-7 7"></path>
                          </svg>
                          <span className="truncate">
                            {`https://cmux.dev/${(teamSlug || "your-team").replace(/^\/+/, "")}`}
                          </span>
                        </div>
                      </div>
                      <div className="w-6" aria-hidden />
                    </div>
                    <div className="p-3 text-xs text-neutral-500 dark:text-neutral-400">
                      This is how your workspace URL appears once the slug is saved.
                    </div>
                  </div>
                </div>
                */}
              </div>
              <div className="px-4 py-3 border-t border-neutral-200 dark:border-neutral-800 flex items-center justify-end">
                <button
                  className="px-3 py-1.5 text-sm rounded-md bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-50"
                  disabled={
                    isSaving ||
                    teamName.trim() === originalTeamName.trim() ||
                    Boolean(teamNameError) ||
                    validateName(teamName) !== ""
                  }
                  onClick={() => void saveTeamName()}
                >
                  Save
                </button>
              </div>
            </div>

            {/* Team URL */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Team URL
                </h2>
              </div>
              <div className="p-4">
                <div>
                  <label
                    htmlFor="teamSlug"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    URL Slug
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Set the slug used in links, e.g. /your-team.
                    Lowercase letters, numbers, and hyphens. 3–48 characters.
                  </p>
                  <div
                    className={`inline-flex items-center w-full rounded-lg bg-white dark:bg-neutral-900 border ${
                      teamSlugError
                        ? "border-red-500"
                        : "border-neutral-300 dark:border-neutral-700"
                    }`}
                  >
                    <span
                      aria-hidden
                      className="px-3 py-2 text-sm text-neutral-500 dark:text-neutral-400 select-none bg-neutral-50 dark:bg-neutral-800/50 border-r border-neutral-200 dark:border-neutral-700 rounded-l-lg"
                    >
                      cmux.dev/
                    </span>
                    <input
                      id="teamSlug"
                      aria-label="Team slug"
                      type="text"
                      value={teamSlug}
                      onChange={(e) => {
                        const v = e.target.value.toLowerCase();
                        setTeamSlug(v);
                        setTeamSlugError(validateSlug(v));
                      }}
                      placeholder="your-team"
                      aria-invalid={teamSlugError ? true : undefined}
                      aria-describedby={
                        teamSlugError ? "team-slug-error" : undefined
                      }
                      className="flex-1 bg-transparent border-0 outline-none focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-inset px-3 py-2 text-sm text-neutral-900 dark:text-neutral-100 rounded-r-lg"
                    />
                  </div>
                  {teamSlugError && (
                    <p
                      id="team-slug-error"
                      className="mt-2 text-xs text-red-600 dark:text-red-500"
                    >
                      {teamSlugError}
                    </p>
                  )}
                </div>
              </div>
              <div className="px-4 py-3 border-t border-neutral-200 dark:border-neutral-800 flex items-center justify-end">
                <button
                  className="px-3 py-1.5 text-sm rounded-md bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-50"
                  disabled={
                    isSaving ||
                    teamSlug.trim() === originalTeamSlug.trim() ||
                    Boolean(teamSlugError) ||
                    validateSlug(teamSlug) !== ""
                  }
                  onClick={() => void saveTeamSlug()}
                >
                  Save
                </button>
              </div>
            </div>

            {/* Appearance */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Appearance
                </h2>
              </div>
              <div className="p-4">
                <div>
                  <label className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                    Theme
                  </label>
                  <div className="grid grid-cols-3 gap-2">
                    <button
                      onClick={() => setTheme("light")}
                      className={`p-2 border-2 ${resolvedTheme === "light" ? "border-blue-500 bg-neutral-50 dark:bg-neutral-800" : "border-neutral-200 dark:border-neutral-700"} rounded-lg text-sm font-medium text-neutral-700 dark:text-neutral-300 transition-colors`}
                    >
                      Light
                    </button>
                    <button
                      onClick={() => setTheme("dark")}
                      className={`p-2 border-2 ${resolvedTheme === "dark" ? "border-blue-500 bg-neutral-50 dark:bg-neutral-800" : "border-neutral-200 dark:border-neutral-700"} rounded-lg text-sm font-medium text-neutral-700 dark:text-neutral-300 transition-colors`}
                    >
                      Dark
                    </button>
                    <button
                      onClick={() => setTheme("system")}
                      className={`p-2 border-2 ${resolvedTheme === "system" ? "border-blue-500 bg-neutral-50 dark:bg-neutral-800" : "border-neutral-200 dark:border-neutral-700"} rounded-lg text-sm font-medium text-neutral-700 dark:text-neutral-300 transition-colors`}
                    >
                      System
                    </button>
                  </div>
                </div>
              </div>
            </div>

            {/* Crown Evaluator */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Crown Evaluator
                </h2>
              </div>
              <div className="p-4">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <label className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Auto pull request for crown winner
                    </label>
                    <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                      When enabled, cmux automatically creates a pull request
                      for the winning model’s code diff.
                    </p>
                  </div>
                  <Switch
                    aria-label="Auto pull request for crown winner"
                    size="sm"
                    color="primary"
                    isSelected={autoPrEnabled}
                    onValueChange={setAutoPrEnabled}
                  />
                </div>
              </div>
            </div>

            {/* Worktree Path */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Worktree Location
                </h2>
              </div>
              <div className="p-4">
                <div>
                  <label
                    htmlFor="worktreePath"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    Custom Worktree Path
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Specify where to store git worktrees. Leave empty to use the
                    default location. You can use ~ for your home directory.
                  </p>
                  <input
                    type="text"
                    id="worktreePath"
                    value={worktreePath}
                    onChange={(e) => setWorktreePath(e.target.value)}
                    className="w-full px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100"
                    placeholder="~/my-custom-worktrees"
                    autoComplete="off"
                  />
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-2">
                    Default location: ~/cmux
                  </p>
                </div>
              </div>
            </div>

            {/* AI Provider Authentication */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  AI Provider Authentication
                </h2>
              </div>
              <div className="p-4">
                {/* OAuth Providers Notice TODO: this is not valid */}
                <div className="mb-4 p-3 bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-800 rounded-lg hidden">
                  <div className="flex items-start gap-2">
                    <svg
                      className="w-4 h-4 text-blue-600 dark:text-blue-400 mt-0.5 flex-shrink-0"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={2}
                        d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                    <div className="space-y-2">
                      <p className="text-sm font-medium text-blue-900 dark:text-blue-100">
                        OAuth-based providers (Gemini, AMP)
                      </p>
                      <p className="text-xs text-blue-700 dark:text-blue-300">
                        These providers use OAuth authentication. When you first
                        run them, they'll open a browser for you to authorize
                        access. No API keys needed.
                      </p>
                    </div>
                  </div>
                </div>

                {/* API Keys Section */}
                <div className="space-y-3">
                  {apiKeys.length === 0 ? (
                    <p className="text-sm text-neutral-500 dark:text-neutral-400">
                      No API keys required for the configured agents.
                    </p>
                  ) : (
                    <>
                      <div className="mb-3">
                        <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100 mb-1">
                          API Key Authentication
                        </h3>
                        <div className="text-xs text-neutral-500 dark:text-neutral-400 space-y-1">
                          <p>You can authenticate providers in two ways:</p>
                          <ul className="list-disc ml-4 space-y-0.5">
                            <li>
                              Start a coding CLI (Claude Code, Codex CLI, Gemini
                              CLI, Amp, Opencode) and complete its sign-in; cmux
                              reuses that authentication.
                            </li>
                            <li>
                              Or enter API keys here and cmux will use them
                              directly.
                            </li>
                          </ul>
                        </div>
                      </div>

                      {/* Group API keys by provider for better organization */}
                      {apiKeys.map((key) => {
                        const getProviderInfo = (envVar: string) => {
                          switch (envVar) {
                            case "ANTHROPIC_API_KEY":
                              return {
                                url: "https://console.anthropic.com/settings/keys",
                              };
                            case "OPENAI_API_KEY":
                              return {
                                url: "https://platform.openai.com/api-keys",
                              };
                            case "OPENROUTER_API_KEY":
                              return {
                                url: "https://openrouter.ai/keys",
                              };
                            case "GEMINI_API_KEY":
                              return {
                                url: "https://console.cloud.google.com/apis/credentials",
                              };
                            case "MODEL_STUDIO_API_KEY":
                              return {
                                url: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key",
                              };
                            case "AMP_API_KEY":
                              return {
                                url: "https://ampcode.com/settings",
                              };
                            case "CURSOR_API_KEY":
                              return {
                                url: "https://cursor.com/dashboard?tab=integrations",
                              };
                            default:
                              return null;
                          }
                        };

                        const providerInfo = getProviderInfo(key.envVar);
                        const usedModels = apiKeyModelsByEnv[key.envVar] ?? [];

                        return (
                          <div
                            key={key.envVar}
                            className="border border-neutral-200 dark:border-neutral-800 rounded-lg p-3 space-y-2"
                          >
                            <div className="flex-1 min-w-0">
                              <div className="flex items-start justify-between">
                                <div className="min-w-0">
                                  <label
                                    htmlFor={key.envVar}
                                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300"
                                  >
                                    {key.displayName}
                                  </label>
                                  {usedModels.length > 0 && (
                                    <div className="mt-1 space-y-1">
                                      <div className="flex items-center gap-2 min-w-0">
                                        <p className="text-xs text-neutral-500 dark:text-neutral-400 flex-1 min-w-0">
                                          Used for agents:{" "}
                                          <span className="inline-flex items-center gap-1 min-w-0 align-middle w-full">
                                            <span
                                              ref={(el) => {
                                                usedListRefs.current[
                                                  key.envVar
                                                ] = el;
                                              }}
                                              className={`font-medium min-w-0 ${
                                                expandedUsedList[key.envVar]
                                                  ? "flex-1 whitespace-normal break-words"
                                                  : "flex-1 truncate"
                                              }`}
                                            >
                                              {usedModels.join(", ")}
                                            </span>
                                            {overflowUsedList[key.envVar] && (
                                              <a
                                                href="#"
                                                onClick={(e) => {
                                                  e.preventDefault();
                                                  setExpandedUsedList(
                                                    (prev) => ({
                                                      ...prev,
                                                      [key.envVar]:
                                                        !prev[key.envVar],
                                                    })
                                                  );
                                                }}
                                                className="flex-none text-[10px] text-blue-600 hover:underline dark:text-blue-400"
                                              >
                                                {expandedUsedList[key.envVar]
                                                  ? "Hide more"
                                                  : "Show more"}
                                              </a>
                                            )}
                                          </span>
                                        </p>
                                      </div>
                                    </div>
                                  )}
                                </div>
                                {providerInfo?.url && (
                                  <a
                                    href={providerInfo.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="text-xs text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 flex items-center gap-1 whitespace-nowrap"
                                  >
                                    Get key
                                    <svg
                                      className="w-3 h-3"
                                      fill="none"
                                      stroke="currentColor"
                                      viewBox="0 0 24 24"
                                    >
                                      <path
                                        strokeLinecap="round"
                                        strokeLinejoin="round"
                                        strokeWidth={2}
                                        d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                                      />
                                    </svg>
                                  </a>
                                )}
                              </div>
                            </div>

                            <div className="md:w-[min(100%,480px)] md:flex-shrink-0 self-start">
                              <div className="relative">
                                <input
                                  type={
                                    showKeys[key.envVar] ? "text" : "password"
                                  }
                                  id={key.envVar}
                                  value={apiKeyValues[key.envVar] || ""}
                                  onChange={(e) =>
                                    handleApiKeyChange(
                                      key.envVar,
                                      e.target.value
                                    )
                                  }
                                  className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs"
                                  placeholder={
                                    key.envVar === "ANTHROPIC_API_KEY"
                                      ? "sk-ant-api03-..."
                                      : key.envVar === "OPENAI_API_KEY"
                                        ? "sk-proj-..."
                                        : key.envVar === "OPENROUTER_API_KEY"
                                          ? "sk-or-v1-..."
                                          : `Enter your ${key.displayName}`
                                  }
                                />
                                <button
                                  type="button"
                                  onClick={() => toggleShowKey(key.envVar)}
                                  className="absolute inset-y-0 right-0 pr-3 flex items-center text-neutral-500"
                                >
                                  {showKeys[key.envVar] ? (
                                    <svg
                                      className="h-5 w-5"
                                      fill="none"
                                      stroke="currentColor"
                                      viewBox="0 0 24 24"
                                    >
                                      <path
                                        strokeLinecap="round"
                                        strokeLinejoin="round"
                                        strokeWidth={2}
                                        d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"
                                      />
                                    </svg>
                                  ) : (
                                    <svg
                                      className="h-5 w-5"
                                      fill="none"
                                      stroke="currentColor"
                                      viewBox="0 0 24 24"
                                    >
                                      <path
                                        strokeLinecap="round"
                                        strokeLinejoin="round"
                                        strokeWidth={2}
                                        d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                                      />
                                      <path
                                        strokeLinecap="round"
                                        strokeLinejoin="round"
                                        strokeWidth={2}
                                        d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                                      />
                                    </svg>
                                  )}
                                </button>
                              </div>
                              {originalApiKeyValues[key.envVar] && (
                                <div className="flex items-center gap-1 mt-1">
                                  <svg
                                    className="w-3 h-3 text-green-500 dark:text-green-400"
                                    fill="none"
                                    stroke="currentColor"
                                    viewBox="0 0 24 24"
                                  >
                                    <path
                                      strokeLinecap="round"
                                      strokeLinejoin="round"
                                      strokeWidth={2}
                                      d="M5 13l4 4L19 7"
                                    />
                                  </svg>
                                  <span className="text-xs text-green-600 dark:text-green-400">
                                    API key configured
                                  </span>
                                </div>
                              )}
                            </div>
                          </div>
                        );
                      })}
                    </>
                  )}
                </div>
              </div>
            </div>

            {/* Provider Status */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Provider Status
                </h2>
              </div>
              <div className="p-4">
                <ProviderStatusSettings />
              </div>
            </div>

            {/* Container Settings */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Container Management
                </h2>
              </div>
              <div className="p-4">
                <ContainerSettings
                  teamSlugOrId={teamSlugOrId}
                  onDataChange={handleContainerSettingsChange}
                />
              </div>
            </div>

            {/* Notifications */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800 hidden">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Notifications
                </h2>
              </div>
              <div className="p-4 space-y-3">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Email Notifications
                    </p>
                    <p className="text-xs text-neutral-500 dark:text-neutral-400">
                      Receive updates about your workspace via email
                    </p>
                  </div>
                  <Switch
                    aria-label="Email Notifications"
                    size="sm"
                    isSelected
                    isDisabled
                  />
                </div>

                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Desktop Notifications
                    </p>
                    <p className="text-xs text-neutral-500 dark:text-neutral-400">
                      Get notified about important updates on desktop
                    </p>
                  </div>
                  <Switch
                    aria-label="Desktop Notifications"
                    size="sm"
                    isSelected={false}
                    isDisabled
                  />
                </div>

                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Weekly Digest
                    </p>
                    <p className="text-xs text-neutral-500 dark:text-neutral-400">
                      Summary of your workspace activity
                    </p>
                  </div>
                  <Switch
                    aria-label="Weekly Digest"
                    size="sm"
                    isSelected
                    isDisabled
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Footer Save bar */}
      <div
        ref={saveButtonRef}
        className="border-t border-neutral-200 dark:border-neutral-800 bg-white/80 dark:bg-neutral-900/80 backdrop-blur supports-[backdrop-filter]:bg-white/60 supports-[backdrop-filter]:dark:bg-neutral-900/60"
      >
        <div className="max-w-3xl mx-auto px-6 py-3 flex items-center justify-end gap-3">
          <button
            onClick={saveApiKeys}
            disabled={!hasChanges() || isSaving}
            className={`px-4 py-2 text-sm font-medium rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-neutral-900 transition-all ${
              !hasChanges() || isSaving
                ? "bg-neutral-200 dark:bg-neutral-800 text-neutral-400 dark:text-neutral-500 cursor-not-allowed opacity-50"
                : "bg-blue-600 dark:bg-blue-500 text-white hover:bg-blue-700 dark:hover:bg-blue-600"
            }`}
          >
            {isSaving ? "Saving..." : "Save Changes"}
          </button>
        </div>
      </div>
    </FloatingPane>
  );
}
