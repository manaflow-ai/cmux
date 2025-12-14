"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  Loader2,
  ArrowLeft,
  ArrowRight,
  Eye,
  EyeOff,
  Minus,
  Plus,
  Copy,
  ChevronDown,
  Check,
} from "lucide-react";
import Link from "next/link";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import { DEFAULT_PREVIEW_CONFIGURE_SNAPSHOT_ID } from "@cmux/shared";
import clsx from "clsx";
import {
  FrameworkPresetSelect,
  getFrameworkPresetConfig,
  type FrameworkPreset,
} from "./framework-preset-select";
import type { PackageManager } from "@/lib/github/framework-detection";
import {
  VncViewer,
  type VncConnectionStatus,
} from "@cmux/shared/components/vnc-viewer";

const MASKED_ENV_VALUE = "••••••••••••••••";

export type { FrameworkPreset };

type SandboxInstance = {
  instanceId: string;
  vscodeUrl: string;
  workerUrl: string;
  vncUrl?: string;
  provider: string;
};

type EnvVar = { name: string; value: string; isSecret: boolean };

// All configuration steps in order (shown in workspace config sidebar)
const ALL_CONFIG_STEPS = [
  "scripts", // maintenance + dev scripts
  "env-vars", // environment variables
  "run-scripts", // run scripts in terminal
  "browser-setup", // browser configuration
] as const;

type ConfigStep = (typeof ALL_CONFIG_STEPS)[number];

// Phase tracking for the layout transition
type LayoutPhase = "initial-setup" | "transitioning" | "workspace-config";

type PreviewTeamOption = {
  id: string;
  slug: string | null;
  slugOrId: string;
  displayName: string;
  name: string | null;
};

type PreviewConfigureClientProps = {
  initialTeamSlugOrId: string;
  teams: PreviewTeamOption[];
  repo: string;
  installationId: string | null;
  initialEnvVarsContent?: string | null;
  initialMaintenanceScript?: string | null;
  initialDevScript?: string | null;
  startAtConfigureEnvironment?: boolean;
};

function normalizeVncUrl(url: string): string | null {
  try {
    const target = new URL(url);
    target.searchParams.set("autoconnect", "1");
    target.searchParams.set("resize", "scale");
    return target.toString();
  } catch {
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}autoconnect=1&resize=scale`;
  }
}

function resolveMorphHostId(
  instanceId?: string,
  workspaceUrl?: string
): string | null {
  if (instanceId && instanceId.trim().length > 0) {
    return instanceId.trim().toLowerCase().replace(/_/g, "-");
  }

  if (!workspaceUrl) {
    return null;
  }

  try {
    const url = new URL(workspaceUrl);
    const directMatch = url.hostname.match(
      /^port-\d+-(morphvm-[^.]+)\.http\.cloud\.morph\.so$/i
    );
    if (directMatch && directMatch[1]) {
      return directMatch[1].toLowerCase();
    }

    const proxyMatch = url.hostname.match(
      /^cmux-([^-]+)-[a-z0-9-]+-\d+\.cmux\.(?:app|dev|sh|local|localhost)$/i
    );
    if (proxyMatch && proxyMatch[1]) {
      return `morphvm-${proxyMatch[1].toLowerCase()}`;
    }
  } catch {
    return null;
  }

  return null;
}

function deriveVncUrl(
  instanceId?: string,
  workspaceUrl?: string
): string | null {
  const morphHostId = resolveMorphHostId(instanceId, workspaceUrl);
  if (!morphHostId) {
    return null;
  }

  const hostname = `port-39380-${morphHostId}.http.cloud.morph.so`;
  const baseUrl = `https://${hostname}/vnc.html`;
  return normalizeVncUrl(baseUrl);
}

function convertVncUrlToWebsocket(vncUrl: string): string | null {
  try {
    const url = new URL(vncUrl);
    if (url.protocol === "ws:" || url.protocol === "wss:") {
      if (!url.pathname.includes("websockify")) {
        url.pathname = "/websockify";
      }
      return url.toString();
    }
    const wsProtocol = url.protocol === "https:" ? "wss:" : "ws:";
    return `${wsProtocol}//${url.host}/websockify`;
  } catch {
    return null;
  }
}

function deriveVncWebsocketUrl(
  instanceId?: string,
  workspaceUrl?: string
): string | null {
  const morphHostId = resolveMorphHostId(instanceId, workspaceUrl);
  if (!morphHostId) {
    return null;
  }

  const hostname = `port-39380-${morphHostId}.http.cloud.morph.so`;
  return `wss://${hostname}/websockify`;
}

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

// Persistent iframe manager for Next.js
type PersistentIframeOptions = {
  allow?: string;
  sandbox?: string;
};

type MountOptions = {
  backgroundColor?: string;
};

class SimplePersistentIframeManager {
  private iframes = new Map<
    string,
    {
      iframe: HTMLIFrameElement;
      wrapper: HTMLDivElement;
      allow?: string;
      sandbox?: string;
    }
  >();
  private container: HTMLDivElement | null = null;

  constructor() {
    if (typeof document !== "undefined") {
      this.initContainer();
    }
  }

  private initContainer() {
    this.container = document.createElement("div");
    this.container.id = "persistent-iframe-container";
    this.container.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 0;
      height: 0;
      pointer-events: none;
      z-index: 9999;
    `;
    document.body.appendChild(this.container);
  }

  setVisibility(key: string, visible: boolean) {
    const entry = this.iframes.get(key);
    if (!entry) {
      return;
    }
    entry.wrapper.style.visibility = visible ? "visible" : "hidden";
    entry.wrapper.style.pointerEvents = visible ? "auto" : "none";
  }

  getOrCreateIframe(
    key: string,
    url: string,
    options?: PersistentIframeOptions
  ): HTMLIFrameElement {
    const existing = this.iframes.get(key);
    if (existing) {
      if (options?.allow && existing.allow !== options.allow) {
        existing.iframe.allow = options.allow;
        existing.allow = options.allow;
      }
      if (options?.sandbox && existing.sandbox !== options.sandbox) {
        existing.iframe.setAttribute("sandbox", options.sandbox);
        existing.sandbox = options.sandbox;
      }
      if (existing.iframe.src !== url) {
        existing.iframe.src = url;
      }
      return existing.iframe;
    }

    const wrapper = document.createElement("div");
    wrapper.style.cssText = `
      position: fixed;
      visibility: hidden;
      pointer-events: none;
      transform: translate(-100vw, -100vh);
      width: 0;
      height: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: transparent;
    `;
    wrapper.setAttribute("data-iframe-key", key);

    const iframe = document.createElement("iframe");
    iframe.style.cssText = `
      width: 100%;
      height: 100%;
      border: 0;
      display: block;
      background: transparent;
    `;
    iframe.style.transform = "none";
    iframe.src = url;
    if (options?.allow) {
      iframe.allow = options.allow;
    } else {
      iframe.allow =
        "clipboard-read; clipboard-write; cross-origin-isolated; fullscreen";
    }
    if (options?.sandbox) {
      iframe.setAttribute("sandbox", options.sandbox);
    } else {
      iframe.setAttribute(
        "sandbox",
        "allow-same-origin allow-scripts allow-forms allow-downloads allow-modals allow-popups"
      );
    }

    wrapper.appendChild(iframe);
    this.container?.appendChild(wrapper);
    this.iframes.set(key, {
      iframe,
      wrapper,
      allow: options?.allow,
      sandbox: options?.sandbox,
    });

    return iframe;
  }

  mountIframe(
    key: string,
    targetElement: HTMLElement,
    options?: MountOptions
  ): () => void {
    const entry = this.iframes.get(key);
    if (!entry) return () => {};

    entry.wrapper.style.background = options?.backgroundColor ?? "transparent";

    const syncPosition = () => {
      const rect = targetElement.getBoundingClientRect();
      entry.wrapper.style.transform = `translate(${rect.left}px, ${rect.top}px)`;
      entry.wrapper.style.width = `${rect.width}px`;
      entry.wrapper.style.height = `${rect.height}px`;
    };

    entry.wrapper.style.visibility = "visible";
    entry.wrapper.style.pointerEvents = "auto";
    entry.iframe.style.transform = "none";
    syncPosition();

    const observer = new ResizeObserver(syncPosition);
    observer.observe(targetElement);
    window.addEventListener("resize", syncPosition);
    window.addEventListener("scroll", syncPosition, true);

    return () => {
      entry.wrapper.style.visibility = "hidden";
      entry.wrapper.style.pointerEvents = "none";
      observer.disconnect();
      window.removeEventListener("resize", syncPosition);
      window.removeEventListener("scroll", syncPosition, true);
    };
  }
}

const iframeManager =
  typeof window !== "undefined" ? new SimplePersistentIframeManager() : null;

function StepBadge({ step, done }: { step: number; done: boolean }) {
  return (
    <span
      className={clsx(
        "flex h-5 w-5 items-center justify-center rounded-full border text-[11px]",
        done
          ? "border-emerald-500 bg-emerald-50 text-emerald-700 dark:border-emerald-400/70 dark:bg-emerald-900/40 dark:text-emerald-100"
          : "border-neutral-300 text-neutral-600 dark:border-neutral-700 dark:text-neutral-400"
      )}
    >
      {done ? <Check className="h-3 w-3" /> : step}
    </span>
  );
}

export function PreviewConfigureClient({
  initialTeamSlugOrId,
  teams,
  repo,
  installationId: _installationId,
  initialEnvVarsContent,
  initialMaintenanceScript,
  initialDevScript,
  startAtConfigureEnvironment = false,
}: PreviewConfigureClientProps) {
  const initialEnvPrefilled = useMemo(
    () =>
      Boolean(initialEnvVarsContent && initialEnvVarsContent.trim().length > 0),
    [initialEnvVarsContent]
  );
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
  const initialHasEnvValues = useMemo(
    () =>
      initialEnvPrefilled ||
      initialEnvVars.some(
        (r) => r.name.trim().length > 0 || r.value.trim().length > 0
      ),
    [initialEnvPrefilled, initialEnvVars]
  );

  // Framework detection state - starts with defaults, updated via background fetch
  const [detectedPackageManager, setDetectedPackageManager] = useState<PackageManager>("npm");
  const [isDetectingFramework, setIsDetectingFramework] = useState(true);

  const initialEnvComplete = initialHasEnvValues;

  const [instance, setInstance] = useState<SandboxInstance | null>(null);
  const [isProvisioning, setIsProvisioning] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const selectedTeamSlugOrId = useMemo(
    () => initialTeamSlugOrId || teams[0]?.slugOrId || "",
    [initialTeamSlugOrId, teams]
  );

  // Layout phase for animation - always start with initial-setup to avoid hydration mismatch
  const [layoutPhase, setLayoutPhase] = useState<LayoutPhase>("initial-setup");

  // Sync layoutPhase with URL after hydration (runs once on mount)
  useEffect(() => {
    const url = new URL(window.location.href);
    const stepParam = url.searchParams.get("step");
    if (stepParam === "workspace") {
      setLayoutPhase("workspace-config");
    }
  }, []);
  // Current config step (starts at run-scripts when entering workspace config)
  const [currentConfigStep, setCurrentConfigStep] =
    useState<ConfigStep>("run-scripts");
  // Track which steps have been completed (scripts and env-vars are pre-completed from initial setup)
  const [completedSteps, setCompletedSteps] = useState<Set<ConfigStep>>(
    () => new Set(["scripts", "env-vars"] as ConfigStep[])
  );

  const [envVars, setEnvVars] = useState<EnvVar[]>(initialEnvVars);
  const [hasTouchedEnvVars, setHasTouchedEnvVars] = useState(false);
  const [frameworkPreset, setFrameworkPreset] = useState<FrameworkPreset>("other");
  const [maintenanceScript, setMaintenanceScript] = useState("");
  const [devScript, setDevScript] = useState("");
  const [hasUserEditedScripts, setHasUserEditedScripts] = useState(false);
  const [hasCompletedSetup, setHasCompletedSetup] = useState(false);
  const [isWaitingForWorkspace, setIsWaitingForWorkspace] = useState(false);
  const [envNone, setEnvNone] = useState(false);
  const [commandsCopied, setCommandsCopied] = useState(false);
  const [, setIsEnvSectionOpen] = useState(() => !initialEnvComplete);
  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(
    null
  );
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(
    null
  );

  const [isSaving, setIsSaving] = useState(false);
  const [screenshotAgentContext, setScreenshotAgentContext] = useState("");

  useEffect(() => {
    if (initialHasEnvValues) {
      setIsEnvSectionOpen(false);
    }
  }, [initialHasEnvValues]);

  // Fetch framework detection in background on mount
  // Using refs to avoid re-running when user edits scripts
  const hasUserEditedScriptsRef = useRef(false);
  useEffect(() => {
    hasUserEditedScriptsRef.current = hasUserEditedScripts;
  }, [hasUserEditedScripts]);

  // Use refs for initial scripts to avoid stale closures
  const initialMaintenanceScriptRef = useRef(initialMaintenanceScript);
  const initialDevScriptRef = useRef(initialDevScript);

  useEffect(() => {
    const detectFramework = async () => {
      try {
        const response = await fetch(
          `/api/integrations/github/framework-detection?repo=${encodeURIComponent(repo)}`
        );
        if (!response.ok) {
          console.error("Framework detection failed:", response.statusText);
          return;
        }
        const data = await response.json() as {
          framework: FrameworkPreset;
          packageManager: PackageManager;
          maintenanceScript: string;
          devScript: string;
        };

        setDetectedPackageManager(data.packageManager);

        // Only update UI state if user hasn't edited scripts yet
        if (!hasUserEditedScriptsRef.current) {
          setFrameworkPreset(data.framework);
          // Use initial scripts if provided, otherwise use detected scripts
          if (initialMaintenanceScriptRef.current == null) {
            setMaintenanceScript(data.maintenanceScript);
          } else {
            setMaintenanceScript(initialMaintenanceScriptRef.current);
          }
          if (initialDevScriptRef.current == null) {
            setDevScript(data.devScript);
          } else {
            setDevScript(initialDevScriptRef.current);
          }
        }
      } catch (error) {
        console.error("Failed to detect framework:", error);
      } finally {
        setIsDetectingFramework(false);
      }
    };

    void detectFramework();
  }, [repo]);

  const persistentIframeManager = iframeManager;

  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const lastSubmittedEnvContent = useRef<string | null>(null);
  const copyResetTimeoutRef = useRef<number | null>(null);
  const envSectionCollapsedOnEnterRef = useRef(false);

  useEffect(() => {
    return () => {
      if (copyResetTimeoutRef.current !== null) {
        window.clearTimeout(copyResetTimeoutRef.current);
      }
    };
  }, []);

  // Handle browser back/forward navigation
  useEffect(() => {
    const handlePopState = () => {
      const url = new URL(window.location.href);
      const stepParam = url.searchParams.get("step");
      if (stepParam === "workspace") {
        setLayoutPhase("workspace-config");
      } else {
        setLayoutPhase("initial-setup");
      }
    };

    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  const vscodePersistKey = instance?.instanceId
    ? `preview-${instance.instanceId}:vscode`
    : "vscode";

  const selectedTeam = useMemo(
    () =>
      teams.find((team) => team.slugOrId === selectedTeamSlugOrId) ??
      teams[0] ??
      null,
    [selectedTeamSlugOrId, teams]
  );

  const resolvedTeamSlugOrId =
    selectedTeam?.slugOrId ?? initialTeamSlugOrId ?? teams[0]?.slugOrId ?? "";
  const selectedTeamSlugOrIdRef = useRef(resolvedTeamSlugOrId);

  useEffect(() => {
    selectedTeamSlugOrIdRef.current = resolvedTeamSlugOrId;
  }, [resolvedTeamSlugOrId]);

  // WebSocket URL for direct VNC connection via noVNC/RFB
  // Prefer server-provided vncUrl (converted to websocket), fall back to derived
  const resolvedVncWebsocketUrl = useMemo(() => {
    if (instance?.vncUrl) {
      // Convert iframe URL (https://host/vnc.html) to websocket URL (wss://host/websockify)
      return convertVncUrlToWebsocket(instance.vncUrl);
    }
    return deriveVncWebsocketUrl(instance?.instanceId, instance?.vscodeUrl);
  }, [instance?.vncUrl, instance?.instanceId, instance?.vscodeUrl]);

  // VNC connection status for the browser panel (may be used for UI indicators in the future)
  const [_vncStatus, setVncStatus] =
    useState<VncConnectionStatus>("disconnected");

  const workspacePlaceholder = useMemo(
    () =>
      instance?.vscodeUrl
        ? null
        : {
            title: instance?.instanceId
              ? "Waiting for VS Code"
              : "VS Code workspace not ready",
            description: instance?.instanceId
              ? "The editor opens automatically once the environment finishes booting."
              : "Provisioning the workspace. We'll open VS Code as soon as it's ready.",
          },
    [instance?.instanceId, instance?.vscodeUrl]
  );

  const isWorkspaceReady = Boolean(instance?.vscodeUrl);

  const hasEnvValues = useMemo(
    () =>
      (!hasTouchedEnvVars && initialEnvPrefilled) ||
      envVars.some(
        (r) => r.name.trim().length > 0 || r.value.trim().length > 0
      ),
    [envVars, hasTouchedEnvVars, initialEnvPrefilled]
  );
  const envDone = envNone || hasEnvValues;

  // Collapse env section when entering configure step if it's already satisfied
  useEffect(() => {
    if (
      !hasCompletedSetup ||
      !envDone ||
      envSectionCollapsedOnEnterRef.current
    ) {
      return;
    }
    setIsEnvSectionOpen(false);
    envSectionCollapsedOnEnterRef.current = true;
  }, [envDone, hasCompletedSetup]);

  useEffect(() => {
    if (
      (startAtConfigureEnvironment || isWaitingForWorkspace) &&
      isWorkspaceReady &&
      !hasCompletedSetup
    ) {
      setHasCompletedSetup(true);
      setIsWaitingForWorkspace(false);
    }
  }, [
    hasCompletedSetup,
    isWaitingForWorkspace,
    isWorkspaceReady,
    startAtConfigureEnvironment,
  ]);

  const browserPlaceholder = useMemo(
    () =>
      resolvedVncWebsocketUrl
        ? null
        : {
            title: instance?.instanceId
              ? "Waiting for browser"
              : "Browser preview unavailable",
            description: instance?.instanceId
              ? "We'll embed the browser session as soon as the environment exposes it."
              : "Launch the workspace so the browser agent can stream the preview here.",
          },
    [instance?.instanceId, resolvedVncWebsocketUrl]
  );

  const provisionVM = useCallback(async () => {
    if (!resolvedTeamSlugOrId) {
      setErrorMessage("Select a team to start provisioning.");
      return;
    }

    setIsProvisioning(true);
    setErrorMessage(null);

    try {
      const response = await fetch("/api/sandboxes/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: resolvedTeamSlugOrId,
          repoUrl: `https://github.com/${repo}`,
          branch: "main",
          ttlSeconds: 3600,
          snapshotId: DEFAULT_PREVIEW_CONFIGURE_SNAPSHOT_ID,
        }),
      });

      if (!response.ok) {
        throw new Error(await response.text());
      }

      const data = (await response.json()) as SandboxInstance;
      const normalizedFromResponse =
        data.vncUrl && data.vncUrl.trim().length > 0
          ? (normalizeVncUrl(data.vncUrl) ?? data.vncUrl)
          : null;
      const derived =
        normalizedFromResponse ?? deriveVncUrl(data.instanceId, data.vscodeUrl);

      if (selectedTeamSlugOrIdRef.current !== resolvedTeamSlugOrId) {
        return;
      }

      setInstance({
        ...data,
        vncUrl: derived ?? undefined,
      });
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to provision workspace";
      if (selectedTeamSlugOrIdRef.current === resolvedTeamSlugOrId) {
        setErrorMessage(message);
      }
      console.error("Failed to provision workspace:", error);
    } finally {
      setIsProvisioning(false);
    }
  }, [repo, resolvedTeamSlugOrId]);

  useEffect(() => {
    if (!resolvedTeamSlugOrId) {
      return;
    }
    if (!instance && !isProvisioning && !errorMessage) {
      void provisionVM();
    }
  }, [
    instance,
    isProvisioning,
    errorMessage,
    provisionVM,
    resolvedTeamSlugOrId,
  ]);

  useEffect(() => {
    if (pendingFocusIndex !== null) {
      const el = keyInputRefs.current[pendingFocusIndex];
      if (el) {
        setTimeout(() => {
          el.focus();
          try {
            el.scrollIntoView({ block: "nearest" });
          } catch (_e) {
            void 0;
          }
        }, 0);
        setPendingFocusIndex(null);
      }
    }
  }, [pendingFocusIndex, envVars]);

  // Auto-apply env vars to sandbox
  useEffect(() => {
    if (!instance?.instanceId || !resolvedTeamSlugOrId) {
      return;
    }

    const envVarsContent = formatEnvVarsContent(
      envVars
        .filter((r) => r.name.trim().length > 0)
        .map((r) => ({ name: r.name, value: r.value }))
    );

    if (
      envVarsContent.length === 0 &&
      lastSubmittedEnvContent.current === null
    ) {
      return;
    }

    if (envVarsContent === lastSubmittedEnvContent.current) {
      return;
    }

    const timeoutId = window.setTimeout(async () => {
      try {
        await fetch(`/api/sandboxes/${instance.instanceId}/env`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            teamSlugOrId: resolvedTeamSlugOrId,
            envVarsContent,
          }),
        });
        lastSubmittedEnvContent.current = envVarsContent;
      } catch (error) {
        console.error("Failed to apply sandbox environment vars", error);
      }
    }, 400);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [envVars, instance?.instanceId, resolvedTeamSlugOrId]);

  const updateEnvVars = useCallback((updater: (prev: EnvVar[]) => EnvVar[]) => {
    setHasTouchedEnvVars(true);
    setEnvVars((prev) => updater(prev));
  }, []);

  const handleFrameworkPresetChange = useCallback(
    (preset: FrameworkPreset) => {
      setFrameworkPreset(preset);
      // Only auto-fill if user hasn't manually edited the scripts
      if (!hasUserEditedScripts) {
        const presetConfig = getFrameworkPresetConfig(
          preset,
          detectedPackageManager
        );
        setMaintenanceScript(presetConfig.maintenanceScript);
        setDevScript(presetConfig.devScript);
      }
    },
    [hasUserEditedScripts, detectedPackageManager]
  );

  const handleMaintenanceScriptChange = useCallback((value: string) => {
    setMaintenanceScript(value);
    setHasUserEditedScripts(true);
  }, []);

  const handleDevScriptChange = useCallback((value: string) => {
    setDevScript(value);
    setHasUserEditedScripts(true);
  }, []);

  const handleCopyCommands = useCallback(async () => {
    const combined = [maintenanceScript.trim(), devScript.trim()]
      .filter(Boolean)
      .join(" && ");
    if (!combined) {
      return;
    }

    try {
      await navigator.clipboard.writeText(combined);
      setCommandsCopied(true);
      if (copyResetTimeoutRef.current !== null) {
        window.clearTimeout(copyResetTimeoutRef.current);
      }
      copyResetTimeoutRef.current = window.setTimeout(() => {
        setCommandsCopied(false);
      }, 2000);
    } catch (error) {
      console.error("Failed to copy commands:", error);
    }
  }, [devScript, maintenanceScript]);

  const handleSaveConfiguration = async () => {
    if (!resolvedTeamSlugOrId) {
      setErrorMessage("Select a team before saving.");
      return;
    }

    if (!instance?.instanceId) {
      console.error("Missing instanceId for configuration save");
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

    const normalizedMaintenanceScript = maintenanceScript.trim();
    const normalizedDevScript = devScript.trim();
    const normalizedScreenshotAgentContext = screenshotAgentContext.trim();
    const requestMaintenanceScript =
      normalizedMaintenanceScript.length > 0
        ? normalizedMaintenanceScript
        : undefined;
    const requestDevScript =
      normalizedDevScript.length > 0 ? normalizedDevScript : undefined;
    const requestScreenshotAgentContext =
      normalizedScreenshotAgentContext.length > 0
        ? normalizedScreenshotAgentContext
        : undefined;

    setIsSaving(true);
    setErrorMessage(null);

    try {
      const envResponse = await fetch("/api/environments", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId: resolvedTeamSlugOrId,
          name: envName,
          morphInstanceId: instance.instanceId,
          envVarsContent,
          selectedRepos: [repo],
          maintenanceScript: requestMaintenanceScript,
          devScript: requestDevScript,
          exposedPorts: undefined,
          description: undefined,
          screenshotAgentContext: requestScreenshotAgentContext,
        }),
      });

      if (!envResponse.ok) {
        throw new Error(await envResponse.text());
      }

      const envData = await envResponse.json();
      const environmentId = envData.id;

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

      window.location.href = "/preview";
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to save configuration";
      setErrorMessage(message);
      console.error("Failed to save preview configuration:", error);
    } finally {
      setIsSaving(false);
    }
  };

  // Handle transitioning from initial setup to workspace configuration
  const handleStartWorkspaceConfig = useCallback(() => {
    setLayoutPhase("transitioning");
    // Add search param to track that we're in workspace config phase
    const url = new URL(window.location.href);
    url.searchParams.set("step", "workspace");
    window.history.pushState({}, "", url.toString());
    // After animation completes, set to workspace-config
    setTimeout(() => {
      setLayoutPhase("workspace-config");
    }, 650); // Match CSS transition duration (600ms + buffer)
  }, []);

  // Handle going back to initial setup from workspace config
  const handleBackToInitialSetup = useCallback(() => {
    // Remove the step param from URL
    const url = new URL(window.location.href);
    url.searchParams.delete("step");
    window.history.pushState({}, "", url.toString());
    // Transition back to initial setup
    setLayoutPhase("initial-setup");
    setCurrentConfigStep("run-scripts");
  }, []);

  // Handle next step within workspace configuration
  const handleNextConfigStep = useCallback(() => {
    const currentIndex = ALL_CONFIG_STEPS.indexOf(currentConfigStep);

    // Mark current step as completed
    setCompletedSteps((prev) => new Set([...prev, currentConfigStep]));

    // Move to next step if not at end
    if (currentIndex < ALL_CONFIG_STEPS.length - 1) {
      setCurrentConfigStep(ALL_CONFIG_STEPS[currentIndex + 1]);
    }
  }, [currentConfigStep]);

  // Helper to check if a step is visible (completed or current)
  const isStepVisible = useCallback(
    (step: ConfigStep) => {
      return completedSteps.has(step) || step === currentConfigStep;
    },
    [completedSteps, currentConfigStep]
  );

  // Helper to check if a step is the current one
  const isCurrentStep = useCallback(
    (step: ConfigStep) => {
      return step === currentConfigStep;
    },
    [currentConfigStep]
  );

  // Helper to check if a step is completed (for collapsing)
  const isStepCompleted = useCallback(
    (step: ConfigStep) => {
      return completedSteps.has(step);
    },
    [completedSteps]
  );

  // Navigate to a specific step (for going back to completed steps)
  const handleGoToStep = useCallback((step: ConfigStep) => {
    // Remove from completed set when going back to a step
    setCompletedSteps((prev) => {
      const next = new Set(prev);
      next.delete(step);
      return next;
    });
    setCurrentConfigStep(step);
  }, []);

  // Pre-create VS Code iframe during setup so it's ready when user clicks Next
  // Using useLayoutEffect so iframe is created before the mount effect runs
  // Note: Browser VNC is now handled by VncViewer component, not iframe
  useLayoutEffect(() => {
    if (!instance || !persistentIframeManager) return;

    // Pre-create VS Code iframe during setup
    if (instance.vscodeUrl) {
      const vscodeUrl = new URL(instance.vscodeUrl);
      vscodeUrl.searchParams.set("folder", "/root/workspace");
      persistentIframeManager.getOrCreateIframe(
        vscodePersistKey,
        vscodeUrl.toString()
      );
    }
  }, [instance, persistentIframeManager, vscodePersistKey]);

  // Mount VS Code iframe to its target when visible
  // Note: Browser VNC is now handled by VncViewer component, not iframe
  useLayoutEffect(() => {
    if (!instance || !persistentIframeManager) return;
    // Only mount when in workspace-config layout
    if (layoutPhase === "initial-setup") return;

    const cleanupFunctions: Array<() => void> = [];

    // Show VSCode for steps before browser-setup
    const showVscode = currentConfigStep !== "browser-setup";
    if (instance.vscodeUrl && showVscode) {
      const target = document.querySelector(
        `[data-iframe-target="${vscodePersistKey}"]`
      ) as HTMLElement | null;
      if (target) {
        cleanupFunctions.push(
          persistentIframeManager.mountIframe(vscodePersistKey, target)
        );
      }
    }

    return () => {
      cleanupFunctions.forEach((fn) => fn());
    };
  }, [
    instance,
    persistentIframeManager,
    currentConfigStep,
    layoutPhase,
    vscodePersistKey,
  ]);

  // Control VS Code iframe visibility based on current step and layout phase
  // Note: Browser VNC visibility is now handled by VncViewer component
  useEffect(() => {
    if (!persistentIframeManager) {
      return;
    }

    // Only show iframes when in workspace-config layout
    const inWorkspaceConfig = layoutPhase === "workspace-config";
    // Show VSCode for steps before browser-setup
    const showVscode = currentConfigStep !== "browser-setup";
    const workspaceVisible =
      inWorkspaceConfig && showVscode && Boolean(instance?.vscodeUrl);

    persistentIframeManager.setVisibility(vscodePersistKey, workspaceVisible);
  }, [
    currentConfigStep,
    layoutPhase,
    persistentIframeManager,
    instance?.vscodeUrl,
    vscodePersistKey,
  ]);

  if (errorMessage && !instance) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-[#05050a] text-white">
        <div className="text-center max-w-md px-6">
          <h1 className="text-2xl font-bold text-red-400">Error</h1>
          <p className="mt-2 text-neutral-400">{errorMessage}</p>
          <button
            type="button"
            onClick={() => {
              setErrorMessage(null);
              void provisionVM();
            }}
            className="mt-4 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-black transition hover:bg-neutral-200"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  const renderPreviewPanel = () => {
    // Show browser only for browser-setup step, VSCode for others
    const showBrowser = currentConfigStep === "browser-setup";
    const placeholder = showBrowser ? browserPlaceholder : workspacePlaceholder;

    // Loading fallback for VNC viewer
    const vncLoadingFallback = (
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center">
        <div className="h-8 w-8 animate-spin rounded-full border-2 border-neutral-400 border-t-transparent" />
        <span className="text-sm text-neutral-400">
          Connecting to browser preview...
        </span>
      </div>
    );

    // Error fallback for VNC viewer
    const vncErrorFallback = (
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center">
        <span className="text-sm text-red-400">
          Failed to connect to browser preview
        </span>
      </div>
    );

    return (
      <div className="h-full flex flex-col overflow-hidden relative">
        {/* Placeholder for VS Code or browser when not available */}
        {placeholder ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
            <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
              {placeholder.title}
            </div>
            {placeholder.description ? (
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                {placeholder.description}
              </p>
            ) : null}
          </div>
        ) : null}

        {/* VS Code iframe (shown for non-browser-setup steps) */}
        {!showBrowser && (
          <div
            className={clsx(
              "absolute inset-0",
              placeholder ? "opacity-0" : "opacity-100"
            )}
            data-iframe-target={vscodePersistKey}
          />
        )}

        {/* VNC Viewer for browser preview (shown for browser-setup step) */}
        {showBrowser && resolvedVncWebsocketUrl && (
          <VncViewer
            url={resolvedVncWebsocketUrl}
            className={clsx(
              "absolute inset-0",
              browserPlaceholder ? "opacity-0" : "opacity-100"
            )}
            background="#000000"
            scaleViewport
            autoConnect
            autoReconnect
            reconnectDelay={1000}
            maxReconnectDelay={30000}
            focusOnClick
            onStatusChange={setVncStatus}
            loadingFallback={vncLoadingFallback}
            errorFallback={vncErrorFallback}
          />
        )}
      </div>
    );
  };

  // Shared render function for scripts section
  const renderScriptsSection = (options?: {
    compact?: boolean;
    defaultOpen?: boolean;
    showStepBadge?: boolean;
    stepNumber?: number;
    isDone?: boolean;
  }) => {
    const {
      compact = false,
      defaultOpen = true,
      showStepBadge = false,
      stepNumber = 1,
      isDone = false,
    } = options ?? {};
    const iconSize = compact ? "h-3.5 w-3.5" : "h-4 w-4";
    const titleSize = compact ? "text-[13px]" : "text-base";
    const contentPadding = compact ? "mt-3 pl-5" : "mt-4 pl-6";

    return (
      <details className="group" open={defaultOpen}>
        <summary
          className={clsx(
            "flex items-center gap-2 cursor-pointer font-semibold text-neutral-900 dark:text-neutral-100 list-none",
            titleSize
          )}
        >
          <ChevronDown
            className={clsx(
              iconSize,
              "text-neutral-400 transition-transform -rotate-90 group-open:rotate-0"
            )}
          />
          {showStepBadge && <StepBadge step={stepNumber} done={isDone} />}
          Maintenance and Dev Scripts
        </summary>
        <div className={clsx(contentPadding, "space-y-4")}>
          <div>
            <label className="block text-xs text-neutral-500 dark:text-neutral-400 mb-1.5">
              Maintenance Script
            </label>
            <textarea
              value={maintenanceScript ?? ""}
              onChange={(e) => handleMaintenanceScriptChange(e.target.value)}
              placeholder="npm install, bun install, pip install -r requirements.txt"
              rows={2}
              className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
            />
            <p className="text-xs text-neutral-400 mt-1">
              Runs after git pull to install dependencies
            </p>
          </div>
          <div>
            <label className="block text-xs text-neutral-500 dark:text-neutral-400 mb-1.5">
              Dev Script
            </label>
            <textarea
              value={devScript ?? ""}
              onChange={(e) => handleDevScriptChange(e.target.value)}
              placeholder="npm run dev, bun dev, python manage.py runserver"
              rows={2}
              className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
            />
            <p className="text-xs text-neutral-400 mt-1">
              Starts the development server
            </p>
          </div>
        </div>
      </details>
    );
  };

  // Shared render function for environment variables section
  const renderEnvVarsSection = (options?: {
    compact?: boolean;
    defaultOpen?: boolean;
    showStepBadge?: boolean;
    stepNumber?: number;
    isDone?: boolean;
  }) => {
    const {
      compact = false,
      defaultOpen = true,
      showStepBadge = false,
      stepNumber = 2,
      isDone = false,
    } = options ?? {};
    const iconSize = compact ? "h-3.5 w-3.5" : "h-4 w-4";
    const titleSize = compact ? "text-[13px]" : "text-base";
    const contentPadding = compact ? "mt-3 pl-5" : "mt-4 pl-6";

    return (
      <details
        className="group"
        open={defaultOpen}
        onToggle={(e) => setIsEnvSectionOpen(e.currentTarget.open)}
      >
        <summary
          className={clsx(
            "flex items-center gap-2 cursor-pointer font-semibold text-neutral-900 dark:text-neutral-100 list-none",
            titleSize
          )}
        >
          <ChevronDown
            className={clsx(
              iconSize,
              "text-neutral-400 transition-transform -rotate-90 group-open:rotate-0"
            )}
          />
          {showStepBadge && <StepBadge step={stepNumber} done={isDone} />}
          <span>Environment Variables</span>
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
                <EyeOff className={iconSize} />
              ) : (
                <Eye className={iconSize} />
              )}
            </button>
          </div>
        </summary>
        <div
          className={clsx(contentPadding, "space-y-2")}
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
        <p
          className={clsx(
            "text-xs text-neutral-400 mt-4",
            compact ? "pl-5" : "pl-6"
          )}
        >
          Tip: Paste a .env file to auto-fill
        </p>
      </details>
    );
  };

  // Render the initial setup content (framework, scripts, env vars - all shown at once)
  const renderInitialSetupContent = () => {
    return (
      <div className="space-y-6">
        {/* Framework Preset */}
        <FrameworkPresetSelect
          value={frameworkPreset}
          onValueChange={handleFrameworkPresetChange}
          isLoading={isDetectingFramework}
        />

        {/* Maintenance and Dev Scripts - Always expanded on initial setup */}
        {renderScriptsSection({ defaultOpen: true })}

        {/* Environment Variables - Always expanded on initial setup */}
        {renderEnvVarsSection({ defaultOpen: true })}
      </div>
    );
  };

  // Render all config steps in sidebar (completed ones collapsed, current one expanded, future ones hidden)
  const renderWorkspaceStepContent = () => {
    return (
      <div className="space-y-4">
        {/* Step 1: Scripts (completed from initial setup - collapsed) */}
        {isStepVisible("scripts") && (
          <div>
            {renderScriptsSection({
              compact: true,
              defaultOpen: !isStepCompleted("scripts"),
              showStepBadge: true,
              stepNumber: 1,
              isDone: isStepCompleted("scripts"),
            })}
          </div>
        )}

        {/* Step 2: Environment Variables (completed from initial setup - collapsed) */}
        {isStepVisible("env-vars") && (
          <div>
            {renderEnvVarsSection({
              compact: true,
              defaultOpen: !isStepCompleted("env-vars"),
              showStepBadge: true,
              stepNumber: 2,
              isDone: isStepCompleted("env-vars"),
            })}
          </div>
        )}

        {/* Step 3: Run Scripts */}
        {isStepVisible("run-scripts") && (
          <div>
            <details className="group" open={isCurrentStep("run-scripts")}>
              <summary
                className={clsx(
                  "flex items-center gap-2 list-none",
                  isSaving ? "cursor-not-allowed opacity-60" : "cursor-pointer"
                )}
                onClick={(e) => {
                  if (isSaving) return;
                  if (
                    isStepCompleted("run-scripts") &&
                    !isCurrentStep("run-scripts")
                  ) {
                    e.preventDefault();
                    handleGoToStep("run-scripts");
                  }
                }}
              >
                <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
                <StepBadge
                  step={3}
                  done={
                    isStepCompleted("run-scripts") &&
                    !isCurrentStep("run-scripts")
                  }
                />
                <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                  Run scripts in VS Code terminal
                </span>
              </summary>
              <div className="mt-3 ml-6 space-y-3">
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Setup VS Code development environment. Open terminal (
                  <kbd className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-[10px] font-sans">
                    Ctrl+Shift+`
                  </kbd>{" "}
                  or{" "}
                  <kbd className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-[10px] font-sans">
                    Cmd+J
                  </kbd>
                  ) and paste:
                </p>
                <div className="rounded-md border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900 overflow-hidden">
                  <div className="flex items-center justify-between px-3 py-1.5 border-b border-neutral-200 dark:border-neutral-800 bg-neutral-100 dark:bg-neutral-800/50">
                    <span className="text-[10px] uppercase tracking-wide text-neutral-500">
                      Commands
                    </span>
                    {(maintenanceScript.trim() || devScript.trim()) && (
                      <button
                        type="button"
                        onClick={handleCopyCommands}
                        className={clsx(
                          "p-0.5",
                          commandsCopied
                            ? "text-emerald-500"
                            : "text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300"
                        )}
                      >
                        {commandsCopied ? (
                          <Check className="h-3 w-3" />
                        ) : (
                          <Copy className="h-3 w-3" />
                        )}
                      </button>
                    )}
                  </div>
                  <pre className="px-3 py-2 text-[11px] font-mono text-neutral-900 dark:text-neutral-100 overflow-x-auto whitespace-pre-wrap break-all select-all">
                    {maintenanceScript.trim() || devScript.trim() ? (
                      [maintenanceScript.trim(), devScript.trim()]
                        .filter(Boolean)
                        .join(" && ")
                    ) : (
                      <span className="text-neutral-400 italic">
                        No scripts configured
                      </span>
                    )}
                  </pre>
                </div>
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Proceed once dev script is running.
                </p>
              </div>
            </details>
            {/* Continue button outside chevron */}
            {isCurrentStep("run-scripts") && (
              <button
                type="button"
                onClick={handleNextConfigStep}
                className="w-full mt-4 inline-flex items-center justify-center gap-2 rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-4 py-2 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition cursor-pointer"
              >
                Continue
                <ArrowRight className="w-4 h-4" />
              </button>
            )}
          </div>
        )}

        {/* Step 4: Browser Setup */}
        {isStepVisible("browser-setup") && (
          <div>
            <details className="group" open={isCurrentStep("browser-setup")}>
              <summary
                className={clsx(
                  "flex items-center gap-2 list-none",
                  isSaving ? "cursor-not-allowed opacity-60" : "cursor-pointer"
                )}
                onClick={(e) => {
                  if (isSaving) return;
                  if (
                    isStepCompleted("browser-setup") &&
                    !isCurrentStep("browser-setup")
                  ) {
                    e.preventDefault();
                    handleGoToStep("browser-setup");
                  }
                }}
              >
                <ChevronDown className="h-3.5 w-3.5 text-neutral-400 transition-transform -rotate-90 group-open:rotate-0" />
                <StepBadge
                  step={4}
                  done={
                    isStepCompleted("browser-setup") &&
                    !isCurrentStep("browser-setup")
                  }
                />
                <span className="text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
                  Configure browser
                </span>
              </summary>
              <div className="mt-3 ml-6 space-y-3">
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Use the browser on the right to set up authentication:
                </p>
                <ul className="space-y-2 text-[11px] text-neutral-600 dark:text-neutral-400">
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      1
                    </span>
                    <span>Sign in to any dashboards or SaaS tools</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      2
                    </span>
                    <span>Dismiss cookie banners, popups, or MFA prompts</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="flex h-4 w-4 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-500 dark:text-neutral-400 flex-shrink-0 mt-0.5">
                      3
                    </span>
                    <span>
                      Navigate to your dev server URL (e.g., localhost:3000)
                    </span>
                  </li>
                </ul>
                <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                  Proceed once browser is set up properly.
                </p>

                {/* Additional context for screenshot agent */}
                <div className="mt-4 pt-4 border-t border-neutral-200 dark:border-neutral-800">
                  <label className="block text-xs font-medium text-neutral-700 dark:text-neutral-300 mb-1.5">
                    Additional Notes{" "}
                    <span className="font-normal text-neutral-400">(optional)</span>
                  </label>
                  <textarea
                    value={screenshotAgentContext}
                    onChange={(e) => setScreenshotAgentContext(e.target.value)}
                    placeholder={`e.g., Test credentials: user@example.com / password123
Navigate to /dashboard after login
The loading spinner appears for ~2 seconds`}
                    rows={4}
                    className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none min-h-[110px]"
                  />
                  <p className="text-[10px] text-neutral-400 mt-1 leading-snug">
                    <span className="block">
                      Give clear instructions for the screenshot bot.
                    </span>
                    <span className="block">
                      Include backup creds, auth steps, and pages to capture.
                    </span>
                  </p>
                </div>
              </div>
            </details>
            {/* Save button outside chevron */}
            {isCurrentStep("browser-setup") && (
              <button
                type="button"
                onClick={handleSaveConfiguration}
                disabled={isSaving}
                className="w-full mt-4 inline-flex items-center justify-center rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-4 py-2 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition disabled:opacity-50 disabled:cursor-not-allowed"
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
            )}
          </div>
        )}
      </div>
    );
  };

  // Initial setup panel (full page, shows framework, scripts, env vars)
  const renderInitialSetupPanel = () => (
    <div className="min-h-dvh bg-white dark:bg-black font-sans">
      <div className="max-w-2xl mx-auto px-6 py-10">
        {/* Back to preview.new link */}
        <div className="mb-3">
          <Link
            href="/preview"
            className="inline-flex items-center gap-1.5 text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
          >
            <ArrowLeft className="h-3 w-3" />
            Go to preview.new
          </Link>
        </div>

        {/* Header */}
        <div className="mb-8">
          <h1 className="text-2xl font-semibold text-neutral-900 dark:text-neutral-100 mb-1">
            Configure workspace
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
          </div>
        </div>

        {/* Content */}
        {renderInitialSetupContent()}

        {/* Error Message */}
        {errorMessage && (
          <div className="rounded-md bg-red-50 dark:bg-red-950/20 border border-red-200 dark:border-red-900/50 p-3 mt-6">
            <p className="text-sm text-red-600 dark:text-red-400">
              {errorMessage}
            </p>
          </div>
        )}

        {/* Footer Button */}
        <div className="mt-8 pt-6 border-t border-neutral-200 dark:border-neutral-800">
          <button
            type="button"
            onClick={handleStartWorkspaceConfig}
            className={clsx(
              "w-full inline-flex items-center justify-center gap-2 rounded-md px-5 py-2.5 text-sm font-semibold transition",
              "bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 hover:bg-neutral-800 dark:hover:bg-neutral-200 cursor-pointer",
              !isWorkspaceReady && "opacity-80"
            )}
          >
            Continue
            <ArrowRight className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );

  // Workspace config panel (sidebar, shows steps one at a time)
  const renderWorkspaceConfigPanel = () => (
    <div className="w-[420px] h-full flex flex-col overflow-hidden border-r border-neutral-200 dark:border-neutral-800 bg-white dark:bg-black">
      <div className="flex-shrink-0 px-5 pt-4 pb-2">
        <button
          type="button"
          onClick={handleBackToInitialSetup}
          disabled={isSaving}
          className={clsx(
            "inline-flex items-center gap-1 text-[11px] text-neutral-500 dark:text-neutral-400 mb-3",
            isSaving
              ? "opacity-50 cursor-not-allowed"
              : "hover:text-neutral-900 dark:hover:text-neutral-100"
          )}
        >
          <ArrowLeft className="h-3 w-3" />
          Back to project setup
        </button>
        <h1 className="text-base font-semibold text-neutral-900 dark:text-neutral-100 tracking-tight">
          Configure workspace
        </h1>
        <div className="flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 pt-1">
          <svg
            className="h-4 w-4 shrink-0"
            viewBox="0 0 24 24"
            fill="currentColor"
          >
            <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
          </svg>
          <span className="font-sans text-xs">{repo}</span>
        </div>
        <p className="text-[11px] text-neutral-500 dark:text-neutral-400 leading-relaxed pt-3">
          Your workspace root at{" "}
          <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-700 dark:text-neutral-300">
            /root/workspace
          </code>{" "}
          maps directly to your repo root.
        </p>
      </div>

      <div className="flex-1 overflow-y-auto px-5 pb-5">
        {renderWorkspaceStepContent()}

        {errorMessage && (
          <div className="rounded-md bg-red-50 dark:bg-red-950/20 border border-red-200 dark:border-red-900/50 p-3 mt-4">
            <p className="text-sm text-red-600 dark:text-red-400">
              {errorMessage}
            </p>
          </div>
        )}
      </div>
    </div>
  );

  // Initial setup layout (full page)
  if (layoutPhase === "initial-setup") {
    return renderInitialSetupPanel();
  }

  // Show loading state if VSCode isn't ready (for both transitioning and workspace-config)
  if (!isWorkspaceReady) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-white dark:bg-black font-sans">
        <div className="text-center px-6">
          <Loader2 className="mx-auto h-8 w-8 animate-spin text-neutral-400" />
          <h1 className="mt-4 text-lg font-medium text-neutral-900 dark:text-neutral-100">
            Starting your VS Code workspace...
          </h1>
          <p className="mt-2 text-sm text-neutral-500 dark:text-neutral-400">
            We&apos;ll show the configuration once your environment is ready.
          </p>
        </div>
      </div>
    );
  }

  // Transitioning layout - animate the final sidebar from center position
  if (layoutPhase === "transitioning") {
    return (
      <div className="flex h-screen overflow-hidden bg-neutral-50 dark:bg-neutral-950 font-sans text-[15px] leading-6">
        {/* Sidebar content animating from center */}
        <div className="preview-setup-transitioning h-full flex flex-col overflow-hidden border-r border-neutral-200 dark:border-neutral-800 bg-white dark:bg-black">
          <div className="flex-shrink-0 px-5 pt-4 pb-2">
            <button
              type="button"
              onClick={handleBackToInitialSetup}
              disabled={isSaving}
              className={clsx(
                "inline-flex items-center gap-1 text-[11px] text-neutral-500 dark:text-neutral-400 mb-3",
                isSaving
                  ? "opacity-50 cursor-not-allowed"
                  : "hover:text-neutral-900 dark:hover:text-neutral-100"
              )}
            >
              <ArrowLeft className="h-3 w-3" />
              Back to project setup
            </button>
            <h1 className="text-base font-semibold text-neutral-900 dark:text-neutral-100 tracking-tight">
              Configure workspace
            </h1>
            <div className="flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 pt-1">
              <svg
                className="h-4 w-4 shrink-0"
                viewBox="0 0 24 24"
                fill="currentColor"
              >
                <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
              </svg>
              <span className="font-sans text-xs">{repo}</span>
            </div>
            <p className="text-[11px] text-neutral-500 dark:text-neutral-400 leading-relaxed pt-3">
              Your workspace root at{" "}
              <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-[10px] text-neutral-700 dark:text-neutral-300">
                /root/workspace
              </code>{" "}
              maps directly to your repo root.
            </p>
          </div>

          <div className="flex-1 overflow-y-auto px-5 pb-5">
            {renderWorkspaceStepContent()}
          </div>
        </div>

        {/* Preview panel fading in */}
        <div className="preview-panel-entering flex-1 flex flex-col bg-neutral-950 overflow-hidden">
          {renderPreviewPanel()}
        </div>
      </div>
    );
  }

  // Workspace config layout (split with sidebar + preview)
  return (
    <div className="flex h-screen overflow-hidden bg-neutral-50 dark:bg-neutral-950 font-sans text-[15px] leading-6">
      {/* Left: Configuration Form */}
      {renderWorkspaceConfigPanel()}

      {/* Right: Preview Panel */}
      <div className="flex-1 flex flex-col bg-neutral-950 overflow-hidden">
        {renderPreviewPanel()}
      </div>
    </div>
  );
}
