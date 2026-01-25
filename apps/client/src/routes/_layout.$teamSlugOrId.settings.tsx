import { env } from "@/client-env";
import { ContainerSettings } from "@/components/ContainerSettings";
import { EditorSettingsSection } from "@/components/EditorSettingsSection";
import { FloatingPane } from "@/components/floating-pane";
import { ProviderStatusSettings } from "@/components/provider-status-settings";
import { useTheme } from "@/components/theme/use-theme";
import { TitleBar } from "@/components/TitleBar";
import { useOnboardingOptional } from "@/contexts/onboarding";
import { ChevronDown, HelpCircle } from "lucide-react";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { AGENT_CONFIGS, type AgentConfig } from "@cmux/shared/agentConfig";
import { API_KEY_MODELS_BY_ENV } from "@cmux/shared/model-usage";
import { convexQuery } from "@convex-dev/react-query";
import { Switch } from "@heroui/react";
import { useUser } from "@stackframe/react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useConvex } from "convex/react";
import { useCallback, useEffect, useRef, useState } from "react";
import { isElectron } from "@/lib/electron";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
import { toast } from "sonner";
import { z } from "zod";

const GitHubUserSchema = z.object({
  login: z.string(),
});

export const Route = createFileRoute("/_layout/$teamSlugOrId/settings")({
  component: SettingsComponent,
});

interface ProviderInfo {
  url?: string;
  helpText?: string;
}

type HeatmapColors = {
  line: { start: string; end: string };
  token: { start: string; end: string };
};

const createDefaultHeatmapColors = (): HeatmapColors => ({
  line: { start: "#fefce8", end: "#f8e1c9" },
  token: { start: "#fde047", end: "#ffa270" },
});

const areHeatmapColorsEqual = (a: HeatmapColors, b: HeatmapColors): boolean =>
  a.line.start === b.line.start &&
  a.line.end === b.line.end &&
  a.token.start === b.token.start &&
  a.token.end === b.token.end;

const PROVIDER_INFO: Record<string, ProviderInfo> = {
  CLAUDE_CODE_OAUTH_TOKEN: {
    helpText:
      "Run `claude setup-token` in your terminal and paste the output here. Preferred over API key.",
  },
  ANTHROPIC_API_KEY: {
    url: "https://console.anthropic.com/settings/keys",
  },
  OPENAI_API_KEY: {
    url: "https://platform.openai.com/api-keys",
  },
  CODEX_AUTH_JSON: {
    helpText:
      "Paste the contents of ~/.codex/auth.json here. This allows Codex to use your OpenAI authentication.",
  },
  OPENROUTER_API_KEY: {
    url: "https://openrouter.ai/keys",
  },
  GEMINI_API_KEY: {
    url: "https://console.cloud.google.com/apis/credentials",
  },
  MODEL_STUDIO_API_KEY: {
    url: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key",
  },
  AMP_API_KEY: {
    url: "https://ampcode.com/settings",
  },
  CURSOR_API_KEY: {
    url: "https://cursor.com/dashboard?tab=integrations",
  },
  XAI_API_KEY: {
    url: "https://console.x.ai/",
  },
};

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
    </svg>
  );
}

function ConnectedAccountsSection({ teamSlugOrId }: { teamSlugOrId: string }) {
  const user = useUser({ or: "return-null" });
  const [isConnecting, setIsConnecting] = useState(false);

  const { data: githubAccount, isLoading: isCheckingConnection } = useQuery({
    queryKey: ["github-connection", user?.id],
    queryFn: async () => {
      if (!user) return { connected: false, username: null };
      const account = await user.getConnectedAccount("github");
      if (!account) return { connected: false, username: null };
      try {
        const token = await account.getAccessToken();
        if (!token.accessToken) return { connected: true, username: null };
        const response = await fetch("https://api.github.com/user", {
          headers: { Authorization: `Bearer ${token.accessToken}` },
        });
        if (!response.ok) return { connected: true, username: null };
        const parsed = GitHubUserSchema.safeParse(await response.json());
        if (!parsed.success) return { connected: true, username: null };
        return { connected: true, username: parsed.data.login };
      } catch (err) {
        console.error("Failed to fetch GitHub username:", err);
        return { connected: true, username: null };
      }
    },
    enabled: !!user,
  });

  const githubConnected = isCheckingConnection ? null : (githubAccount?.connected ?? false);
  const githubUsername = githubAccount?.username ?? null;

  const handleConnectGitHub = useCallback(async () => {
    if (!user) return;
    setIsConnecting(true);
    try {
      if (isElectron) {
        // In Electron, open OAuth flow in system browser
        // The www endpoint will handle OAuth and return via deep link
        const oauthUrl = `${WWW_ORIGIN}/handler/connect-github?team=${encodeURIComponent(teamSlugOrId)}`;
        window.open(oauthUrl, "_blank", "noopener,noreferrer");
        return;
      }

      // In web, use Stack Auth's redirect (page navigates away)
      await user.getConnectedAccount("github", { or: "redirect" });
    } catch (error) {
      console.error("Failed to connect GitHub:", error);
    } finally {
      setIsConnecting(false);
    }
  }, [user, teamSlugOrId]);

  if (!user) return null;

  return (
    <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
      <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
        <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
          Connected Accounts
        </h2>
        <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
          Connect accounts to enable additional features like private repo access
        </p>
      </div>
      <div className="p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 bg-neutral-100 dark:bg-neutral-800 rounded-lg flex items-center justify-center">
              <GitHubIcon className="w-4.5 h-4.5 text-neutral-700 dark:text-neutral-300" />
            </div>
            <div>
              <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                GitHub
              </p>
              {githubConnected === null ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">Checking...</p>
              ) : githubConnected ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  Connected{githubUsername ? ` as @${githubUsername}` : ""}
                </p>
              ) : (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  Required for cloning private repos
                </p>
              )}
            </div>
          </div>
          {githubConnected === false && (
            <button
              onClick={handleConnectGitHub}
              disabled={isConnecting}
              className="px-3 py-1.5 text-xs font-medium text-white bg-neutral-900 dark:bg-neutral-100 dark:text-neutral-900 rounded-md hover:bg-neutral-800 dark:hover:bg-neutral-200 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {isConnecting ? "Connecting..." : "Connect"}
            </button>
          )}
          {githubConnected === true && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-400">
              Connected
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

function OnboardingTourSection({ teamSlugOrId }: { teamSlugOrId: string }) {
  const onboarding = useOnboardingOptional();
  const navigate = useNavigate();

  const handleStartTour = useCallback(async () => {
    if (!onboarding) return;
    onboarding.resetOnboarding();
    try {
      await navigate({
        to: "/$teamSlugOrId/dashboard",
        params: { teamSlugOrId },
      });
    } catch (error) {
      console.error("Failed to navigate to dashboard for onboarding:", error);
      return;
    }
    // Small delay to ensure reset completes before starting
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 100);
    });
    onboarding.startOnboarding();
  }, [navigate, onboarding, teamSlugOrId]);

  return (
    <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
      <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
        <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
          Getting Started
        </h2>
      </div>
      <div className="p-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="w-9 h-9 bg-blue-100 dark:bg-blue-900/30 rounded-lg flex items-center justify-center flex-shrink-0">
              <HelpCircle className="w-4.5 h-4.5 text-blue-600 dark:text-blue-400" />
            </div>
            <div>
              <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                Product Tour
              </p>
              <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                Take a guided tour of cmux to learn about its features and how to get the most out of it.
              </p>
            </div>
          </div>
          <button
            onClick={handleStartTour}
            className="px-3 py-1.5 text-xs font-medium text-white bg-blue-500 hover:bg-blue-600 rounded-md transition-colors flex-shrink-0"
          >
            Start Tour
          </button>
        </div>
      </div>
    </div>
  );
}

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

  // Heatmap settings state
  const [heatmapModel, setHeatmapModel] =
    useState<string>("anthropic-opus-4-5");
  const [originalHeatmapModel, setOriginalHeatmapModel] =
    useState<string>("anthropic-opus-4-5");
  const [heatmapThreshold, setHeatmapThreshold] = useState<number>(0);
  const [originalHeatmapThreshold, setOriginalHeatmapThreshold] =
    useState<number>(0);
  const [heatmapTooltipLanguage, setHeatmapTooltipLanguage] =
    useState<string>("en");
  const [originalHeatmapTooltipLanguage, setOriginalHeatmapTooltipLanguage] =
    useState<string>("en");
  const [heatmapColors, setHeatmapColors] = useState<HeatmapColors>(
    createDefaultHeatmapColors
  );
  const [originalHeatmapColors, setOriginalHeatmapColors] =
    useState<HeatmapColors>(createDefaultHeatmapColors);

  // Heatmap model options from model-config.ts
  const HEATMAP_MODEL_OPTIONS = [
    { value: "anthropic-opus-4-5", label: "Claude Opus 4.5" },
    { value: "anthropic", label: "Claude Opus 4.1" },
    { value: "cmux-heatmap-2", label: "cmux-heatmap-2" },
    { value: "cmux-heatmap-1", label: "cmux-heatmap-1" },
  ];

  // Tooltip language options
  const TOOLTIP_LANGUAGE_OPTIONS = [
    { value: "en", label: "English" },
    { value: "zh-Hant", label: "繁體中文" },
    { value: "zh-Hans", label: "简体中文" },
    { value: "ja", label: "日本語" },
    { value: "ko", label: "한국어" },
    { value: "es", label: "Español" },
    { value: "fr", label: "Français" },
    { value: "de", label: "Deutsch" },
    { value: "pt", label: "Português" },
    { value: "ru", label: "Русский" },
    { value: "vi", label: "Tiếng Việt" },
    { value: "th", label: "ไทย" },
    { value: "id", label: "Bahasa Indonesia" },
  ];

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

  // Initialize worktree path and heatmap settings when data loads
  useEffect(() => {
    if (workspaceSettings === undefined) {
      return;
    }

    const nextWorktreePath = workspaceSettings?.worktreePath ?? "";
    setWorktreePath((prev) =>
      prev === nextWorktreePath ? prev : nextWorktreePath
    );
    setOriginalWorktreePath((prev) =>
      prev === nextWorktreePath ? prev : nextWorktreePath
    );

    const nextAutoPrEnabled = workspaceSettings?.autoPrEnabled ?? false;
    setAutoPrEnabled((prev) =>
      prev === nextAutoPrEnabled ? prev : nextAutoPrEnabled
    );
    setOriginalAutoPrEnabled((prev) =>
      prev === nextAutoPrEnabled ? prev : nextAutoPrEnabled
    );

    if (workspaceSettings?.heatmapModel) {
      const nextModel = workspaceSettings.heatmapModel;
      setHeatmapModel((prev) => (prev === nextModel ? prev : nextModel));
      setOriginalHeatmapModel((prev) =>
        prev === nextModel ? prev : nextModel
      );
    }
    if (workspaceSettings?.heatmapThreshold !== undefined) {
      const nextThreshold = workspaceSettings.heatmapThreshold;
      setHeatmapThreshold((prev) =>
        prev === nextThreshold ? prev : nextThreshold
      );
      setOriginalHeatmapThreshold((prev) =>
        prev === nextThreshold ? prev : nextThreshold
      );
    }
    if (workspaceSettings?.heatmapTooltipLanguage) {
      const nextLanguage = workspaceSettings.heatmapTooltipLanguage;
      setHeatmapTooltipLanguage((prev) =>
        prev === nextLanguage ? prev : nextLanguage
      );
      setOriginalHeatmapTooltipLanguage((prev) =>
        prev === nextLanguage ? prev : nextLanguage
      );
    }
    if (workspaceSettings?.heatmapColors) {
      const nextColors = workspaceSettings.heatmapColors;
      setHeatmapColors((prev) =>
        areHeatmapColorsEqual(prev, nextColors) ? prev : nextColors
      );
      setOriginalHeatmapColors((prev) =>
        areHeatmapColorsEqual(prev, nextColors) ? prev : nextColors
      );
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

    // Heatmap settings changes
    const heatmapModelChanged = heatmapModel !== originalHeatmapModel;
    const heatmapThresholdChanged = heatmapThreshold !== originalHeatmapThreshold;
    const heatmapTooltipLanguageChanged = heatmapTooltipLanguage !== originalHeatmapTooltipLanguage;
    const heatmapColorsChanged =
      JSON.stringify(heatmapColors) !== JSON.stringify(originalHeatmapColors);

    return (
      worktreePathChanged ||
      autoPrChanged ||
      apiKeysChanged ||
      containerSettingsChanged ||
      heatmapModelChanged ||
      heatmapThresholdChanged ||
      heatmapTooltipLanguageChanged ||
      heatmapColorsChanged
    );
  };

  const saveApiKeys = async () => {
    setIsSaving(true);

    try {
      let savedCount = 0;
      let deletedCount = 0;

      // Save worktree path / auto PR / heatmap settings if changed
      const workspaceSettingsChanged =
        worktreePath !== originalWorktreePath ||
        autoPrEnabled !== originalAutoPrEnabled ||
        heatmapModel !== originalHeatmapModel ||
        heatmapThreshold !== originalHeatmapThreshold ||
        heatmapTooltipLanguage !== originalHeatmapTooltipLanguage ||
        JSON.stringify(heatmapColors) !== JSON.stringify(originalHeatmapColors);

      if (workspaceSettingsChanged) {
        await convex.mutation(api.workspaceSettings.update, {
          teamSlugOrId,
          worktreePath: worktreePath || undefined,
          autoPrEnabled,
          heatmapModel,
          heatmapThreshold,
          heatmapTooltipLanguage,
          heatmapColors,
        });
        setOriginalWorktreePath(worktreePath);
        setOriginalAutoPrEnabled(autoPrEnabled);
        setOriginalHeatmapModel(heatmapModel);
        setOriginalHeatmapThreshold(heatmapThreshold);
        setOriginalHeatmapTooltipLanguage(heatmapTooltipLanguage);
        setOriginalHeatmapColors(heatmapColors);
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
                    className={`w-full px-3 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 ${teamNameError
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
                            {`https://cmux.dev/${(teamSlug || "your-team").replace(/^\/+/, "")}/dashboard`}
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
                    Set the slug used in links, e.g. /your-team/dashboard.
                    Lowercase letters, numbers, and hyphens. 3–48 characters.
                  </p>
                  <div
                    className={`inline-flex items-center w-full rounded-lg bg-white dark:bg-neutral-900 border ${teamSlugError
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

            {/* Connected Accounts */}
            <ConnectedAccountsSection teamSlugOrId={teamSlugOrId} />

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

            {/* Onboarding Tour */}
            <OnboardingTourSection teamSlugOrId={teamSlugOrId} />

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
                      Auto-create pull request with the best diff
                    </label>
                    <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                      After all agents finish, automatically create a pull request with the
                      winning agent's solution.
                    </p>
                  </div>
                  <Switch
                    aria-label="Auto-create pull request with the best diff"
                    size="sm"
                    color="primary"
                    isSelected={autoPrEnabled}
                    onValueChange={setAutoPrEnabled}
                  />
                </div>
              </div>
            </div>

            {/* Heatmap Review Settings */}
            <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
              <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
                <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                  Diff Heatmap Review
                </h2>
              </div>
              <div className="p-4 space-y-6">
                {/* Model Selector */}
                <div>
                  <label
                    htmlFor="heatmapModel"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    Review Model
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Select the AI model used to analyze diffs and highlight areas that need attention.
                  </p>
                  <div className="relative">
                    <select
                      id="heatmapModel"
                      value={heatmapModel}
                      onChange={(e) => setHeatmapModel(e.target.value)}
                      className="w-full appearance-none px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 text-sm"
                    >
                      {HEATMAP_MODEL_OPTIONS.map((option) => (
                        <option key={option.value} value={option.value}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                    <ChevronDown
                      className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-500 dark:text-neutral-400"
                      aria-hidden
                    />
                  </div>
                </div>

                {/* Tooltip Language Selector */}
                <div>
                  <label
                    htmlFor="heatmapTooltipLanguage"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    Tooltip Language
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Language for the review comments shown in heatmap tooltips.
                  </p>
                  <div className="relative">
                    <select
                      id="heatmapTooltipLanguage"
                      value={heatmapTooltipLanguage}
                      onChange={(e) => setHeatmapTooltipLanguage(e.target.value)}
                      className="w-full appearance-none px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 text-sm"
                    >
                      {TOOLTIP_LANGUAGE_OPTIONS.map((option) => (
                        <option key={option.value} value={option.value}>
                          {option.label}
                        </option>
                      ))}
                    </select>
                    <ChevronDown
                      className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-500 dark:text-neutral-400"
                      aria-hidden
                    />
                  </div>
                </div>

                {/* Threshold Slider */}
                <div>
                  <label
                    htmlFor="heatmapThreshold"
                    className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2"
                  >
                    Visibility Threshold: {Math.round(heatmapThreshold * 100)}%
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Only show highlights for lines with a review score above this threshold.
                  </p>
                  <input
                    type="range"
                    id="heatmapThreshold"
                    min="0"
                    max="1"
                    step="0.05"
                    value={heatmapThreshold}
                    onChange={(e) => setHeatmapThreshold(Number.parseFloat(e.target.value))}
                    className="w-full h-2 bg-neutral-200 dark:bg-neutral-700 rounded-lg appearance-none cursor-pointer accent-blue-600"
                  />
                </div>

                {/* Color Settings */}
                <div>
                  <label className="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                    Heatmap Colors
                  </label>
                  <p className="text-xs text-neutral-500 dark:text-neutral-400 mb-3">
                    Customize the gradient colors for line and token highlighting.
                  </p>
                  <div className="grid grid-cols-2 gap-4">
                    {/* Line Background Colors */}
                    <div className="space-y-2">
                      <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">Line Background</span>
                      <div className="flex items-center gap-2">
                        <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">Low</label>
                        <input
                          type="color"
                          value={heatmapColors.line.start}
                          onChange={(e) => setHeatmapColors((prev) => ({
                            ...prev,
                            line: { ...prev.line, start: e.target.value }
                          }))}
                          className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                        />
                        <span className="text-xs font-mono text-neutral-500">{heatmapColors.line.start}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">High</label>
                        <input
                          type="color"
                          value={heatmapColors.line.end}
                          onChange={(e) => setHeatmapColors((prev) => ({
                            ...prev,
                            line: { ...prev.line, end: e.target.value }
                          }))}
                          className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                        />
                        <span className="text-xs font-mono text-neutral-500">{heatmapColors.line.end}</span>
                      </div>
                    </div>
                    {/* Token Highlight Colors */}
                    <div className="space-y-2">
                      <span className="text-xs font-medium text-neutral-600 dark:text-neutral-400">Token Highlight</span>
                      <div className="flex items-center gap-2">
                        <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">Low</label>
                        <input
                          type="color"
                          value={heatmapColors.token.start}
                          onChange={(e) => setHeatmapColors((prev) => ({
                            ...prev,
                            token: { ...prev.token, start: e.target.value }
                          }))}
                          className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                        />
                        <span className="text-xs font-mono text-neutral-500">{heatmapColors.token.start}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <label className="text-xs text-neutral-500 dark:text-neutral-400 w-10">High</label>
                        <input
                          type="color"
                          value={heatmapColors.token.end}
                          onChange={(e) => setHeatmapColors((prev) => ({
                            ...prev,
                            token: { ...prev.token, end: e.target.value }
                          }))}
                          className="w-8 h-8 rounded border border-neutral-300 dark:border-neutral-600 cursor-pointer"
                        />
                        <span className="text-xs font-mono text-neutral-500">{heatmapColors.token.end}</span>
                      </div>
                    </div>
                  </div>
                  {/* Preview Gradient */}
                  <div className="mt-4">
                    <span className="text-xs text-neutral-500 dark:text-neutral-400">Preview</span>
                    <div
                      className="mt-1 h-4 rounded"
                      style={{
                        background: `linear-gradient(to right, ${heatmapColors.line.start}, ${heatmapColors.line.end})`
                      }}
                    />
                  </div>
                </div>
              </div>
            </div>

            {/* Worktree Path - hidden in web mode */}
            {!env.NEXT_PUBLIC_WEB_MODE && (
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
            )}

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
                      {apiKeys.map((key) => {
                        const providerInfo = PROVIDER_INFO[key.envVar];
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
                                  {providerInfo?.helpText && (
                                    <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">
                                      {providerInfo.helpText}
                                    </p>
                                  )}
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
                                              className={`font-medium min-w-0 ${expandedUsedList[key.envVar]
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
                              {key.envVar === "CODEX_AUTH_JSON" ? (
                                <div className="relative">
                                  {showKeys[key.envVar] ? (
                                    <textarea
                                      id={key.envVar}
                                      value={apiKeyValues[key.envVar] || ""}
                                      onChange={(e) =>
                                        handleApiKeyChange(
                                          key.envVar,
                                          e.target.value
                                        )
                                      }
                                      rows={4}
                                      className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs resize-y"
                                      placeholder='{"tokens": {"id_token": "...", "access_token": "...", "refresh_token": "...", "account_id": "..."}, "last_refresh": "..."}'
                                    />
                                  ) : (
                                    <div
                                      onClick={() => toggleShowKey(key.envVar)}
                                      className="w-full px-3 py-2 pr-10 border border-neutral-300 dark:border-neutral-700 rounded-lg bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs cursor-pointer h-[82px]"
                                    >
                                      {apiKeyValues[key.envVar] ? "••••••••••••••••••••••••••••••••" : <span className="text-neutral-400">{"Click to edit"}</span>}
                                    </div>
                                  )}
                                  <button
                                    type="button"
                                    onClick={() => toggleShowKey(key.envVar)}
                                    className="absolute top-2 right-2 p-1 text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
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
                              ) : (
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
                                      key.envVar === "CLAUDE_CODE_OAUTH_TOKEN"
                                        ? "sk-ant-oat01-..."
                                        : key.envVar === "ANTHROPIC_API_KEY"
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
                              )}
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

            {/* Provider Status - hidden in web mode */}
            {!env.NEXT_PUBLIC_WEB_MODE && (
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
            )}

            {/* Container Settings - hidden in web mode */}
            {!env.NEXT_PUBLIC_WEB_MODE && (
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
            )}

            {/* Editor Settings Sync - web mode only */}
            {env.NEXT_PUBLIC_WEB_MODE && (
              <EditorSettingsSection teamSlugOrId={teamSlugOrId} />
            )}

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
        className="sticky bottom-0 border-t border-neutral-200 dark:border-neutral-800 bg-white/80 dark:bg-neutral-900/80 backdrop-blur supports-[backdrop-filter]:bg-white/60 supports-[backdrop-filter]:dark:bg-neutral-900/60"
      >
        <div className="max-w-3xl mx-auto px-6 py-3 flex items-center justify-end gap-3">
          <button
            onClick={saveApiKeys}
            disabled={!hasChanges() || isSaving}
            className={`px-4 py-2 text-sm font-medium rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-neutral-900 transition-all ${!hasChanges() || isSaving
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
