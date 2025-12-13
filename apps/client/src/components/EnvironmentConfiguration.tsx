import { GitHubIcon } from "@/components/icons/github";
import { PersistentWebView } from "@/components/persistent-webview";
import { WorkspaceLoadingIndicator } from "@/components/workspace-loading-indicator";
import { VncViewer } from "@cmux/shared/components/vnc-viewer";
import { ScriptTextareaField } from "@/components/ScriptTextareaField";
import { SCRIPT_COPY } from "@/components/scriptCopy";
import { ResizableColumns } from "@/components/ResizableColumns";
import { RenderPanel } from "@/components/TaskPanelFactory";
import { disableDragPointerEvents, restoreDragPointerEvents } from "@/lib/drag-pointer-events";
import { parseEnvBlock } from "@/lib/parseEnvBlock";
import type { PanelPosition, PanelType } from "@/lib/panel-config";
import {
  TASK_RUN_IFRAME_ALLOW,
  TASK_RUN_IFRAME_SANDBOX,
} from "@/lib/preloadTaskRunIframes";
import {
  ensureInitialEnvVars,
  type EnvVar,
  type EnvironmentConfigDraft,
} from "@/types/environment";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import type { MorphSnapshotId } from "@cmux/shared";
import { validateExposedPorts } from "@cmux/shared/utils/validate-exposed-ports";
import {
  postApiEnvironmentsMutation,
  postApiSandboxesByIdEnvMutation,
  postApiEnvironmentsByIdSnapshotsMutation,
} from "@cmux/www-openapi-client/react-query";
import { Accordion, AccordionItem } from "@heroui/react";
import { useMutation as useRQMutation } from "@tanstack/react-query";
import { useNavigate, useSearch } from "@tanstack/react-router";
import type { Id } from "@cmux/convex/dataModel";
import clsx from "clsx";
import {
  ArrowLeft,
  Code2,
  Eye,
  EyeOff,
  Loader2,
  Minus,
  Monitor,
  Plus,
  Settings,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import TextareaAutosize from "react-textarea-autosize";
import { toast } from "sonner";

const MASKED_ENV_VALUE = "••••••••••••••••";

type PreviewMode = "split" | "vscode" | "browser";
type EnvPanelPosition = Extract<PanelPosition, "topLeft" | "bottomLeft">;
type EnvPanelType = Extract<PanelType, "workspace" | "browser">;
const ENV_PANEL_POSITIONS: EnvPanelPosition[] = ["topLeft", "bottomLeft"];
const isEnvPanelPosition = (
  position: PanelPosition | null
): position is EnvPanelPosition =>
  position === "topLeft" || position === "bottomLeft";

export function EnvironmentConfiguration({
  selectedRepos,
  teamSlugOrId,
  instanceId,
  vscodeUrl,
  browserWebsocketUrl,
  isProvisioning,
  mode = "new",
  sourceEnvironmentId,
  initialEnvName = "",
  initialMaintenanceScript = "",
  initialDevScript = "",
  initialExposedPorts = "",
  initialEnvVars,
  onHeaderControlsChange,
  persistedState = null,
  onPersistStateChange,
  onBackToRepositorySelection,
  onEnvironmentSaved,
}: {
  selectedRepos: string[];
  teamSlugOrId: string;
  instanceId?: string;
  vscodeUrl?: string;
  browserWebsocketUrl?: string;
  isProvisioning: boolean;
  mode?: "new" | "snapshot";
  sourceEnvironmentId?: Id<"environments">;
  initialEnvName?: string;
  initialMaintenanceScript?: string;
  initialDevScript?: string;
  initialExposedPorts?: string;
  initialEnvVars?: EnvVar[];
  onHeaderControlsChange?: (controls: ReactNode | null) => void;
  persistedState?: EnvironmentConfigDraft | null;
  onPersistStateChange?: (partial: Partial<EnvironmentConfigDraft>) => void;
  onBackToRepositorySelection?: () => void;
  onEnvironmentSaved?: () => void;
}) {
  const navigate = useNavigate();
  const searchRoute:
    | "/_layout/$teamSlugOrId/environments/new"
    | "/_layout/$teamSlugOrId/environments/new-version" =
    mode === "snapshot"
      ? "/_layout/$teamSlugOrId/environments/new-version"
      : "/_layout/$teamSlugOrId/environments/new";
  const search = useSearch({ from: searchRoute }) as {
    step?: "select" | "configure";
    selectedRepos?: string[];
    connectionLogin?: string;
    repoSearch?: string;
    instanceId?: string;
    snapshotId?: MorphSnapshotId;
  };
  const [envName, setEnvName] = useState(
    () => persistedState?.envName ?? initialEnvName
  );
  const [envVars, setEnvVars] = useState<EnvVar[]>(() =>
    ensureInitialEnvVars(persistedState?.envVars ?? initialEnvVars)
  );
  const [maintenanceScript, setMaintenanceScript] = useState(
    () => persistedState?.maintenanceScript ?? initialMaintenanceScript
  );
  const [devScript, setDevScript] = useState(
    () => persistedState?.devScript ?? initialDevScript
  );
  const [exposedPorts, setExposedPorts] = useState(
    () => persistedState?.exposedPorts ?? initialExposedPorts
  );
  const persistConfig = useCallback(
    (partial: Partial<EnvironmentConfigDraft>) => {
      onPersistStateChange?.(partial);
    },
    [onPersistStateChange]
  );
  const updateEnvName = useCallback(
    (value: string) => {
      setEnvName(value);
      persistConfig({ envName: value });
    },
    [persistConfig]
  );
  const updateEnvVars = useCallback(
    (updater: (prev: EnvVar[]) => EnvVar[]) => {
      setEnvVars((prev) => {
        const next = updater(prev);
        persistConfig({ envVars: next });
        return next;
      });
    },
    [persistConfig]
  );
  const updateMaintenanceScript = useCallback(
    (value: string) => {
      setMaintenanceScript(value);
      persistConfig({ maintenanceScript: value });
    },
    [persistConfig]
  );
  const updateDevScript = useCallback(
    (value: string) => {
      setDevScript(value);
      persistConfig({ devScript: value });
    },
    [persistConfig]
  );
  const updateExposedPorts = useCallback(
    (value: string) => {
      setExposedPorts(value);
      persistConfig({ exposedPorts: value });
    },
    [persistConfig]
  );
  const [portsError, setPortsError] = useState<string | null>(null);
  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(
    null
  );
  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(null);
  const lastSubmittedEnvContent = useRef<string | null>(null);
  const [previewMode, setPreviewMode] = useState<PreviewMode>(() => {
    if (typeof window === "undefined") {
      return "split";
    }
    const stored = window.localStorage.getItem("env-preview-mode");
    if (stored === "split" || stored === "vscode" || stored === "browser") {
      return stored;
    }
    return "split";
  });
  const [splitRatio, setSplitRatio] = useState(() => {
    if (typeof window === "undefined") {
      return 0.5;
    }
    const stored = window.localStorage.getItem("env-preview-split");
    const parsed = stored ? Number.parseFloat(stored) : 0.5;
    if (Number.isNaN(parsed)) {
      return 0.5;
    }
    return Math.min(Math.max(parsed, 0.2), 0.8);
  });
  const splitContainerRef = useRef<HTMLDivElement | null>(null);
  const splitDragRafRef = useRef<number | null>(null);
  const [expandedPanelInSplit, setExpandedPanelInSplit] = useState<EnvPanelPosition | null>(null);
  const [panelLayout, setPanelLayout] = useState<
    Record<EnvPanelPosition, EnvPanelType>
  >({
    topLeft: "workspace",
    bottomLeft: "browser",
  });
  const workspacePosition = useMemo<EnvPanelPosition | null>(() => {
    return (
      ENV_PANEL_POSITIONS.find(
        (position) => panelLayout[position] === "workspace"
      ) ?? null
    );
  }, [panelLayout]);
  const browserPosition = useMemo<EnvPanelPosition | null>(() => {
    return (
      ENV_PANEL_POSITIONS.find(
        (position) => panelLayout[position] === "browser"
      ) ?? null
    );
  }, [panelLayout]);
  const expandedPanelPosition = useMemo<PanelPosition | null>(() => {
    if (previewMode === "split") {
      return null;
    }
    if (previewMode === "vscode") {
      return workspacePosition;
    }
    if (previewMode === "browser") {
      return browserPosition;
    }
    return null;
  }, [browserPosition, previewMode, workspacePosition]);
  const basePersistKey = useMemo(() => {
    if (instanceId) return `env-config:${instanceId}`;
    if (vscodeUrl) return `env-config:${vscodeUrl}`;
    if (browserWebsocketUrl) return `env-config:${browserWebsocketUrl}`;
    return "env-config";
  }, [browserWebsocketUrl, instanceId, vscodeUrl]);
  const vscodePersistKey = `${basePersistKey}:vscode`;

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem("env-preview-mode", previewMode);
  }, [previewMode]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem("env-preview-split", String(splitRatio));
  }, [splitRatio]);

  useEffect(() => {
    if (previewMode === "browser" && !browserWebsocketUrl) {
      setPreviewMode("vscode");
    }
  }, [browserWebsocketUrl, previewMode]);

  const handlePanelSwap = useCallback(
    (fromPosition: PanelPosition, toPosition: PanelPosition) => {
      if (
        !isEnvPanelPosition(fromPosition) ||
        !isEnvPanelPosition(toPosition) ||
        fromPosition === toPosition
      ) {
        return;
      }
      const fromKey = fromPosition;
      const toKey = toPosition;
      setPanelLayout((prev) => {
        if (prev[fromKey] === prev[toKey]) {
          return prev;
        }
        return {
          ...prev,
          [fromKey]: prev[toKey],
          [toKey]: prev[fromKey],
        };
      });
    },
    []
  );

  const handlePanelToggleExpand = useCallback(
    (position: PanelPosition) => {
      if (!isEnvPanelPosition(position)) {
        return;
      }
      setExpandedPanelInSplit((prev) => {
        if (prev === position) {
          return null;
        }
        return position;
      });
    },
    []
  );

  const clampSplitRatio = useCallback(
    (value: number) => Math.min(Math.max(value, 0.2), 0.8),
    []
  );


  const updateSplitFromEvent = useCallback(
    (event: MouseEvent) => {
      const container = splitContainerRef.current;
      if (!container) return;
      const rect = container.getBoundingClientRect();
      if (rect.height <= 0) return;
      const offset = (event.clientY - rect.top) / rect.height;
      setSplitRatio(clampSplitRatio(offset));
    },
    [clampSplitRatio]
  );

  const handleSplitDragMove = useCallback(
    (event: MouseEvent) => {
      if (typeof window === "undefined") {
        return;
      }
      if (splitDragRafRef.current != null) {
        return;
      }
      splitDragRafRef.current = window.requestAnimationFrame(() => {
        splitDragRafRef.current = null;
        updateSplitFromEvent(event);
      });
    },
    [updateSplitFromEvent]
  );

  const stopSplitDragging = useCallback(() => {
    if (typeof window === "undefined" || typeof document === "undefined") {
      return;
    }
    if (splitDragRafRef.current != null) {
      cancelAnimationFrame(splitDragRafRef.current);
      splitDragRafRef.current = null;
    }
    document.body.style.cursor = "";
    document.body.classList.remove("select-none");
    restoreDragPointerEvents();
    window.removeEventListener("mousemove", handleSplitDragMove);
    window.removeEventListener("mouseup", stopSplitDragging);
  }, [handleSplitDragMove]);

  const startSplitDragging = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      if (previewMode !== "split") {
        return;
      }
      if (typeof window === "undefined" || typeof document === "undefined") {
        return;
      }
      event.preventDefault();
      document.body.style.cursor = "row-resize";
      document.body.classList.add("select-none");
      disableDragPointerEvents();
      window.addEventListener("mousemove", handleSplitDragMove);
      window.addEventListener("mouseup", stopSplitDragging);
    },
    [handleSplitDragMove, previewMode, stopSplitDragging]
  );

  useEffect(() => {
    return () => {
      if (typeof window !== "undefined" && splitDragRafRef.current != null) {
        cancelAnimationFrame(splitDragRafRef.current);
        splitDragRafRef.current = null;
        window.removeEventListener("mousemove", handleSplitDragMove);
        window.removeEventListener("mouseup", stopSplitDragging);
      }
      if (typeof document !== "undefined") {
        document.body.style.cursor = "";
        document.body.classList.remove("select-none");
      }
      restoreDragPointerEvents();
    };
  }, [handleSplitDragMove, stopSplitDragging]);

  const createEnvironmentMutation = useRQMutation(
    postApiEnvironmentsMutation()
  );
  const createSnapshotMutation = useRQMutation(
    postApiEnvironmentsByIdSnapshotsMutation()
  );
  const applySandboxEnvMutation = useRQMutation(
    postApiSandboxesByIdEnvMutation()
  );
  const applySandboxEnv = applySandboxEnvMutation.mutate;

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

  // no-op placeholder removed; using onSnapshot instead

  useEffect(() => {
    lastSubmittedEnvContent.current = null;
  }, [instanceId]);

  useEffect(() => {
    if (!instanceId) {
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

    const timeoutId = window.setTimeout(() => {
      applySandboxEnv(
        {
          path: { id: instanceId },
          body: { teamSlugOrId, envVarsContent },
        },
        {
          onSuccess: () => {
            lastSubmittedEnvContent.current = envVarsContent;
          },
          onError: (error) => {
            console.error("Failed to apply sandbox environment vars", error);
          },
        }
      );
    }, 400);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [applySandboxEnv, envVars, instanceId, teamSlugOrId]);

  const onSnapshot = async (): Promise<void> => {
    if (!instanceId) {
      console.error("Missing instanceId for snapshot");
      return;
    }
    if (!envName.trim()) {
      console.error("Environment name is required");
      return;
    }

    const envVarsContent = formatEnvVarsContent(
      envVars
        .filter((r) => r.name.trim().length > 0)
        .map((r) => ({ name: r.name, value: r.value }))
    );

    const normalizedMaintenanceScript = maintenanceScript.trim();
    const normalizedDevScript = devScript.trim();
    const requestMaintenanceScript =
      normalizedMaintenanceScript.length > 0
        ? normalizedMaintenanceScript
        : undefined;
    const requestDevScript =
      normalizedDevScript.length > 0 ? normalizedDevScript : undefined;

    const parsedPorts = exposedPorts
      .split(",")
      .map((p) => Number.parseInt(p.trim(), 10))
      .filter((n) => Number.isFinite(n));

    const validation = validateExposedPorts(parsedPorts);
    if (validation.reserved.length > 0) {
      setPortsError(
        `Reserved ports cannot be exposed: ${validation.reserved.join(", ")}`
      );
      return;
    }
    if (validation.invalid.length > 0) {
      setPortsError("Ports must be positive integers.");
      return;
    }

    setPortsError(null);
    const ports = validation.sanitized;

    if (mode === "snapshot" && sourceEnvironmentId) {
      // Create a new snapshot version
      createSnapshotMutation.mutate(
        {
          path: { id: sourceEnvironmentId },
          body: {
            teamSlugOrId,
            morphInstanceId: instanceId,
            label: envName.trim(),
            activate: true,
            maintenanceScript: requestMaintenanceScript,
            devScript: requestDevScript,
          },
        },
        {
          onSuccess: async () => {
            toast.success("Snapshot version created");
            onEnvironmentSaved?.();
            await navigate({
              to: "/$teamSlugOrId/environments",
              params: {
                teamSlugOrId,
              },
              search: () => ({
                step: undefined,
                selectedRepos: undefined,
                connectionLogin: undefined,
                repoSearch: undefined,
                instanceId: undefined,
                snapshotId: undefined,
              }),
            });
          },
          onError: (err) => {
            console.error("Failed to create snapshot version:", err);
          },
        }
      );
    } else {
      // Create a new environment
      createEnvironmentMutation.mutate(
        {
          body: {
            teamSlugOrId,
            name: envName.trim(),
            morphInstanceId: instanceId,
            envVarsContent,
            selectedRepos,
            maintenanceScript: requestMaintenanceScript,
            devScript: requestDevScript,
            exposedPorts: ports.length > 0 ? ports : undefined,
            description: undefined,
          },
        },
        {
          onSuccess: async () => {
            toast.success("Environment saved");
            onEnvironmentSaved?.();
            await navigate({
              to: "/$teamSlugOrId/environments",
              params: { teamSlugOrId },
              search: {
                step: undefined,
                selectedRepos: undefined,
                connectionLogin: undefined,
                repoSearch: undefined,
                instanceId: undefined,
                snapshotId: undefined,
              },
            });
          },
          onError: (err) => {
            console.error("Failed to create environment:", err);
          },
        }
      );
    }
  };

  const isBrowserAvailable = Boolean(browserWebsocketUrl);
  const workspacePlaceholder = useMemo(
    () =>
      vscodeUrl
        ? null
        : {
            title: instanceId
              ? "Waiting for VS Code"
              : "VS Code workspace not ready",
            description: instanceId
              ? "The editor opens automatically once the environment finishes booting."
              : "Select a repository and launch an environment to open VS Code.",
          },
    [instanceId, vscodeUrl]
  );
  const browserPlaceholder = useMemo(
    () =>
      browserWebsocketUrl
        ? null
        : {
            title: instanceId
              ? "Waiting for browser"
              : "Browser preview unavailable",
            description: instanceId
              ? "We'll embed the browser session as soon as the environment exposes it."
              : "Launch an environment so the browser agent can handle screenshots and authentication flows.",
          },
    [browserWebsocketUrl, instanceId]
  );

  const renderEnvPanel = (position: EnvPanelPosition) => {
    const type = panelLayout[position];
    const isPanelExpanded = previewMode === "split" ? expandedPanelInSplit === position : expandedPanelPosition === position;
    const isAnyExpanded = previewMode === "split" ? expandedPanelInSplit !== null : expandedPanelPosition !== null;
    const commonPanelProps = {
      position,
      onSwap: handlePanelSwap,
      onToggleExpand: handlePanelToggleExpand,
      isExpanded: isPanelExpanded,
      isAnyPanelExpanded: isAnyExpanded,
    };

    if (type === "workspace") {
      return (
        <RenderPanel
          key={`env-panel-${position}-workspace`}
          type="workspace"
          {...commonPanelProps}
          workspaceUrl={vscodeUrl ?? null}
          workspacePersistKey={vscodePersistKey}
          PersistentWebView={PersistentWebView}
          WorkspaceLoadingIndicator={WorkspaceLoadingIndicator}
          TASK_RUN_IFRAME_ALLOW={TASK_RUN_IFRAME_ALLOW}
          TASK_RUN_IFRAME_SANDBOX={TASK_RUN_IFRAME_SANDBOX}
          workspacePlaceholder={workspacePlaceholder}
          editorLoadingFallback={
            <WorkspaceLoadingIndicator variant="vscode" status="loading" />
          }
          editorErrorFallback={
            <WorkspaceLoadingIndicator variant="vscode" status="error" />
          }
          selectedRun={null}
          rawWorkspaceUrl={null}
        />
      );
    }

    return (
      <RenderPanel
        key={`env-panel-${position}-browser`}
        type="browser"
        {...commonPanelProps}
        browserWebsocketUrl={browserWebsocketUrl ?? null}
        WorkspaceLoadingIndicator={WorkspaceLoadingIndicator}
        browserPlaceholder={browserPlaceholder}
        selectedRun={null}
        isMorphProvider={Boolean(instanceId)}
      />
    );
  };

  const renderSingleContent = () => {
    if (previewMode === "vscode") {
      return vscodeUrl ? (
        <PersistentWebView
          key={vscodePersistKey}
          persistKey={vscodePersistKey}
          src={vscodeUrl}
          className="flex h-full"
          iframeClassName="select-none"
          allow={TASK_RUN_IFRAME_ALLOW}
          sandbox={TASK_RUN_IFRAME_SANDBOX}
          preflight
          retainOnUnmount
          fallback={<WorkspaceLoadingIndicator variant="vscode" status="loading" />}
          fallbackClassName="bg-neutral-50 dark:bg-black"
          errorFallback={<WorkspaceLoadingIndicator variant="vscode" status="error" />}
          errorFallbackClassName="bg-neutral-50/95 dark:bg-black/95"
          loadTimeoutMs={60_000}
        />
      ) : workspacePlaceholder ? (
        <div className="flex h-full flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
          <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
            {workspacePlaceholder.title}
          </div>
          {workspacePlaceholder.description ? (
            <p className="text-xs text-neutral-500 dark:text-neutral-400">
              {workspacePlaceholder.description}
            </p>
          ) : null}
        </div>
      ) : null;
    }

    if (previewMode === "browser") {
      return browserWebsocketUrl ? (
        <VncViewer
          url={browserWebsocketUrl}
          className="h-full w-full"
          background="#000000"
          scaleViewport
          autoConnect
          autoReconnect
          reconnectDelay={1000}
          maxReconnectDelay={30000}
          focusOnClick
          loadingFallback={<WorkspaceLoadingIndicator variant="browser" status="loading" />}
          errorFallback={<WorkspaceLoadingIndicator variant="browser" status="error" />}
        />
      ) : browserPlaceholder ? (
        <div className="flex h-full flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
          <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
            {browserPlaceholder.title}
          </div>
          {browserPlaceholder.description ? (
            <p className="text-xs text-neutral-500 dark:text-neutral-400">
              {browserPlaceholder.description}
            </p>
          ) : null}
        </div>
      ) : null;
    }

    return null;
  };

  const previewContent =
    previewMode === "split" ? (
      <div
        ref={splitContainerRef}
        className="grid h-full min-h-0"
        style={{
          gridTemplateRows: expandedPanelInSplit === "topLeft"
            ? "1fr 8px 0fr"
            : expandedPanelInSplit === "bottomLeft"
              ? "0fr 8px 1fr"
              : `minmax(160px, ${splitRatio}fr) 8px minmax(160px, ${1 - splitRatio}fr)`,
          gap: "0",
        }}
      >
        <div className="min-h-0 h-full">{renderEnvPanel("topLeft")}</div>
        {!expandedPanelInSplit && (
          <div
            role="separator"
            aria-label="Resize preview panels"
            aria-orientation="horizontal"
            onMouseDown={startSplitDragging}
            className="group relative cursor-row-resize select-none bg-transparent transition-colors z-10"
            style={{
              height: "8px",
            }}
            title="Resize panels"
          >
            <div className="absolute left-0 right-0 h-px bg-transparent group-hover:bg-neutral-400 dark:group-hover:bg-neutral-600 group-active:bg-neutral-500 dark:group-active:bg-neutral-500 transition-colors" style={{ top: "50%", transform: "translateY(-50%)" }} />
          </div>
        )}
        {expandedPanelInSplit && <div className="h-0" />}
        <div className="min-h-0 h-full">{renderEnvPanel("bottomLeft")}</div>
      </div>
    ) : (
      <div className="h-full min-h-0">{renderSingleContent()}</div>
    );

  const previewButtonClass = useCallback(
    (view: PreviewMode, disabled: boolean) =>
      clsx(
        "inline-flex h-7 w-7 items-center justify-center rounded focus:outline-none transition-colors",
        disabled
          ? "opacity-40 cursor-not-allowed text-neutral-500 dark:text-neutral-400"
          : previewMode === view
            ? "text-neutral-900 dark:text-white bg-neutral-100 dark:bg-neutral-800"
            : "text-neutral-500 dark:text-neutral-400 cursor-pointer hover:text-neutral-900 dark:hover:text-neutral-100 hover:bg-neutral-50 dark:hover:bg-neutral-900"
      ),
    [previewMode]
  );

  const handlePreviewModeChange = useCallback(
    (mode: PreviewMode) => {
      if (mode === "browser" && !isBrowserAvailable) {
        return;
      }
      setPreviewMode(mode);
    },
    [isBrowserAvailable]
  );

  const headerControls = useMemo(() => {
    if (isProvisioning) {
      return null;
    }

    return (
      <div className="flex items-center gap-1.5">
        <button
          type="button"
          onClick={() => handlePreviewModeChange("split")}
          className={previewButtonClass("split", false)}
          aria-pressed={previewMode === "split"}
          aria-label="Split VS Code and browser"
          title="Split VS Code and browser"
        >
          <svg
            className="h-3.5 w-3.5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <rect x="3" y="3" width="18" height="7" rx="1" />
            <rect x="3" y="14" width="18" height="7" rx="1" />
          </svg>
        </button>
        <button
          type="button"
          onClick={() => handlePreviewModeChange("vscode")}
          className={previewButtonClass("vscode", false)}
          aria-pressed={previewMode === "vscode"}
          aria-label="Focus VS Code workspace"
          title="Show VS Code workspace"
        >
          <Code2 className="h-3.5 w-3.5" />
        </button>
        <button
          type="button"
          onClick={() => handlePreviewModeChange("browser")}
          className={previewButtonClass("browser", !isBrowserAvailable)}
          aria-pressed={previewMode === "browser"}
          aria-label="Show browser preview"
          title="Show browser preview"
          disabled={!isBrowserAvailable}
        >
          <Monitor className="h-3.5 w-3.5" />
        </button>
      </div>
    );
  }, [
    handlePreviewModeChange,
    isBrowserAvailable,
    isProvisioning,
    previewButtonClass,
    previewMode,
  ]);

  useEffect(() => {
    if (!onHeaderControlsChange) {
      return;
    }
    onHeaderControlsChange(headerControls ?? null);
  }, [headerControls, onHeaderControlsChange]);

  useEffect(() => {
    return () => {
      onHeaderControlsChange?.(null);
    };
  }, [onHeaderControlsChange]);

  const leftPane = (
    <div className="h-full p-6 overflow-y-auto">
      <div className="flex flex-wrap items-center gap-4 mb-4">
        {mode === "new" ? (
          <button
            onClick={async () => {
              onBackToRepositorySelection?.();
              await navigate({
                to: "/$teamSlugOrId/environments/new",
                params: { teamSlugOrId },
                search: {
                  step: "select",
                  selectedRepos:
                    selectedRepos.length > 0 ? selectedRepos : undefined,
                  instanceId: search.instanceId,
                  connectionLogin: search.connectionLogin,
                  repoSearch: search.repoSearch,
                  snapshotId: search.snapshotId,
                },
              });
            }}
            className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
          >
            <ArrowLeft className="w-4 h-4" />
            Back to repository selection
          </button>
        ) : sourceEnvironmentId ? (
          <button
            onClick={async () => {
              await navigate({
                to: "/$teamSlugOrId/environments/$environmentId",
                params: {
                  teamSlugOrId,
                  environmentId: sourceEnvironmentId,
                },
                search: {
                  step: search.step,
                  selectedRepos: search.selectedRepos,
                  connectionLogin: search.connectionLogin,
                  repoSearch: search.repoSearch,
                  instanceId: search.instanceId,
                  snapshotId: search.snapshotId,
                },
              });
            }}
            className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
          >
            <ArrowLeft className="w-4 h-4" />
            Back to environment
          </button>
        ) : null}
      </div>

      <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
        {mode === "snapshot"
          ? "Configure Snapshot Version"
          : "Configure Environment"}
      </h1>
      <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
        {mode === "snapshot"
          ? "Update configuration for the new snapshot version."
          : "Set up your environment name and variables."}
      </p>

      <div className="mt-6 space-y-4">
        <div className="space-y-2">
          <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
            {mode === "snapshot" ? "Snapshot label" : "Environment name"}
          </label>
          <input
            type="text"
            value={envName}
            onChange={(e) => updateEnvName(e.target.value)}
            readOnly={mode === "snapshot"}
            aria-readonly={mode === "snapshot"}
            placeholder={
              mode === "snapshot"
                ? "Auto-generated from environment"
                : "e.g. project-name"
            }
            className={clsx(
              "w-full rounded-md border border-neutral-200 dark:border-neutral-800 px-3 py-2 text-sm placeholder:text-neutral-400 focus:outline-none focus:ring-2",
              mode === "snapshot"
                ? "bg-neutral-100 text-neutral-600 cursor-not-allowed focus:ring-neutral-300/0 dark:bg-neutral-900 dark:text-neutral-400 dark:focus:ring-neutral-700/0"
                : "bg-white text-neutral-900 focus:ring-neutral-300 dark:bg-neutral-950 dark:text-neutral-100 dark:focus:ring-neutral-700"
            )}
          />
        </div>

        {selectedRepos.length > 0 ? (
          <div>
            <div className="text-xs text-neutral-500 dark:text-neutral-500 mb-1">
              Selected repositories
            </div>
            <div className="flex flex-wrap gap-2">
              {selectedRepos.map((fullName) => (
                <span
                  key={fullName}
                  className="inline-flex items-center gap-1 rounded-full border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 px-2 py-1 text-xs"
                >
                  <GitHubIcon className="h-3 w-3 shrink-0 text-neutral-700 dark:text-neutral-300" />
                  {fullName}
                </span>
              ))}
            </div>
          </div>
        ) : null}

        <Accordion
          selectionMode="multiple"
          className="px-0"
          defaultExpandedKeys={[
            "env-vars",
            "install-dependencies",
            "maintenance-script",
            "dev-script",
          ]}
          itemClasses={{
            trigger: "text-sm cursor-pointer py-3",
            content: "pt-0",
            title: "text-sm font-medium",
          }}
        >
          <AccordionItem
            key="env-vars"
            aria-label="Environment variables"
            title="Environment variables"
          >
            <div
              className="pb-2"
              onPasteCapture={(e) => {
                const text = e.clipboardData?.getData("text") ?? "";
                if (text && (/\n/.test(text) || /(=|:)\s*\S/.test(text))) {
                  e.preventDefault();
                  const items = parseEnvBlock(text);
                  if (items.length > 0) {
                    updateEnvVars((prev) => {
                      const map = new Map(
                        prev
                          .filter(
                            (r) =>
                              r.name.trim().length > 0 ||
                              r.value.trim().length > 0
                          )
                          .map((r) => [r.name, r] as const)
                      );
                      for (const it of items) {
                        if (!it.name) continue;
                        const existing = map.get(it.name);
                        if (existing) {
                          map.set(it.name, {
                            ...existing,
                            value: it.value,
                          });
                        } else {
                          map.set(it.name, {
                            name: it.name,
                            value: it.value,
                            isSecret: true,
                          });
                        }
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
              <div className="flex items-center justify-between pb-1">
                <div
                  className="grid gap-3 text-xs text-neutral-500 dark:text-neutral-500 items-center"
                  style={{
                    gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.4fr) 44px",
                  }}
                >
                  <span>Key</span>
                  <span>Value</span>
                  <span className="w-[44px]" />
                </div>
                <button
                  type="button"
                  onClick={() => {
                    setActiveEnvValueIndex(null);
                    setAreEnvValuesHidden((previous) => !previous);
                  }}
                  className="inline-flex items-center gap-1.5 rounded-md border border-neutral-200 dark:border-neutral-800 px-2 py-1 text-xs text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900"
                >
                  {areEnvValuesHidden ? (
                    <>
                      <EyeOff className="h-3 w-3" />
                      Reveal
                    </>
                  ) : (
                    <>
                      <Eye className="h-3 w-3" />
                      Hide
                    </>
                  )}
                </button>
              </div>

              <div className="space-y-2">
                {envVars.map((row, idx) => {
                  const rowKey = idx;
                  const isEditingValue = activeEnvValueIndex === idx;
                  const shouldMaskValue = areEnvValuesHidden && row.value.trim().length > 0 && !isEditingValue;
                  return (
                    <div
                      key={rowKey}
                      className="grid gap-3 items-center"
                      style={{
                        gridTemplateColumns:
                          "minmax(0, 1fr) minmax(0, 1.4fr) 44px",
                      }}
                    >
                      <input
                        type="text"
                        value={row.name}
                        ref={(el) => {
                          keyInputRefs.current[idx] = el;
                        }}
                        onChange={(e) => {
                          const v = e.target.value;
                          updateEnvVars((prev) => {
                            const next = [...prev];
                            const current = next[idx];
                            if (current) {
                              next[idx] = { ...current, name: v };
                            }
                            return next;
                          });
                        }}
                        placeholder="EXAMPLE_NAME"
                        className="w-full min-w-0 self-start rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                      />
                      <TextareaAutosize
                        value={shouldMaskValue ? MASKED_ENV_VALUE : row.value}
                        onChange={shouldMaskValue ? undefined : (e) => {
                          const v = e.target.value;
                          updateEnvVars((prev) => {
                            const next = [...prev];
                            const current = next[idx];
                            if (current) {
                              next[idx] = { ...current, value: v };
                            }
                            return next;
                          });
                        }}
                        onFocus={() => setActiveEnvValueIndex(idx)}
                        onBlur={() => setActiveEnvValueIndex((current) => current === idx ? null : current)}
                        readOnly={shouldMaskValue}
                        placeholder="I9JU23NF394R6HH"
                        minRows={1}
                        maxRows={10}
                        className="w-full min-w-0 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
                      />
                      <div className="self-start flex items-center justify-end w-[44px]">
                        <button
                          type="button"
                          onClick={() => {
                            updateEnvVars((prev) => {
                              const next = prev.filter((_, i) => i !== idx);
                              return next.length > 0
                                ? next
                                : [{ name: "", value: "", isSecret: true }];
                            });
                          }}
                          className="h-10 w-[44px] rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-700 dark:text-neutral-300 grid place-items-center hover:bg-neutral-50 dark:hover:bg-neutral-900"
                          aria-label="Remove variable"
                        >
                          <Minus className="w-4 h-4" />
                        </button>
                      </div>
                  </div>
                  );
                })}
              </div>

              <div className="pt-2">
                <button
                  type="button"
                  onClick={() =>
                    updateEnvVars((prev) => [
                      ...prev,
                      { name: "", value: "", isSecret: true },
                    ])
                  }
                  className="inline-flex items-center gap-2 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900"
                >
                  <Plus className="w-4 h-4" /> Add More
                </button>
              </div>

              <p className="text-xs text-neutral-500 dark:text-neutral-500 pt-2">
                Tip: Paste an .env above to populate the form. Values are
                encrypted at rest.
              </p>
            </div>
          </AccordionItem>

          <AccordionItem
            key="install-dependencies"
            aria-label="Install dependencies"
            title="Install dependencies"
          >
            <div className="space-y-2 pb-4">
              <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                Use the VS Code terminal to install any dependencies your
                codebase needs.
              </p>
              <p className="text-xs text-neutral-500 dark:text-neutral-500">
                Examples: docker pull postgres, docker run redis, install system
                packages, etc.
              </p>
            </div>
          </AccordionItem>

          <AccordionItem
            key="maintenance-script"
            aria-label="Maintenance script"
            title="Maintenance script"
          >
            <div className="pb-4">
              <ScriptTextareaField
                description={SCRIPT_COPY.maintenance.description}
                subtitle={SCRIPT_COPY.maintenance.subtitle}
                value={maintenanceScript}
                onChange={updateMaintenanceScript}
                placeholder={SCRIPT_COPY.maintenance.placeholder}
                descriptionClassName="mb-3"
                minHeightClassName="min-h-[114px]"
              />
            </div>
          </AccordionItem>

          <AccordionItem
            key="dev-script"
            aria-label="Dev script"
            title="Dev script"
          >
            <div className="space-y-4 pb-4">
              <ScriptTextareaField
                description={SCRIPT_COPY.dev.description}
                subtitle={SCRIPT_COPY.dev.subtitle}
                value={devScript}
                onChange={updateDevScript}
                placeholder={SCRIPT_COPY.dev.placeholder}
                minHeightClassName="min-h-[130px]"
              />

              <div className="space-y-2">
                <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
                  Exposed ports
                </label>
                <input
                  type="text"
                  value={exposedPorts}
                  onChange={(e) => updateExposedPorts(e.target.value)}
                  placeholder="3000, 8080, 5432"
                  className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                />
                <p className="text-xs text-neutral-500 dark:text-neutral-500">
                  Comma-separated list of ports that should be exposed from the
                  container for preview URLs.
                </p>
                {portsError && (
                  <p className="text-xs text-red-500">{portsError}</p>
                )}
              </div>
            </div>
          </AccordionItem>

          <AccordionItem
            key="browser-vnc"
            aria-label="Browser setup"
            title="Browser setup"
          >
            <div className="space-y-2 pb-4 text-xs text-neutral-600 dark:text-neutral-400">
              <p>
                Prepare the embedded browser so the browser agent can capture screenshots, finish authentication flows, and verify previews before you save this environment.
              </p>
              <ul className="list-disc space-y-1 pl-5">
                <li>Sign in to SaaS tools or dashboards that require persistent sessions.</li>
                <li>Clear cookie banners, popups, or MFA prompts that could block automation.</li>
                <li>Load staging URLs and confirm pages render without certificate or CSP warnings.</li>
              </ul>
              <p className="text-[11px] text-neutral-500 dark:text-neutral-500">
                Tip: the split-view toggle (first icon above the preview) keeps VS Code and the browser visible side-by-side while you configure things.
              </p>
            </div>
          </AccordionItem>
        </Accordion>

        <div className="pt-2">
          <button
            type="button"
            onClick={onSnapshot}
            disabled={
              isProvisioning ||
              createEnvironmentMutation.isPending ||
              createSnapshotMutation.isPending
            }
            className="inline-flex items-center rounded-md bg-neutral-900 text-white disabled:bg-neutral-300 dark:disabled:bg-neutral-700 disabled:cursor-not-allowed px-4 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            {isProvisioning ||
            createEnvironmentMutation.isPending ||
            createSnapshotMutation.isPending ? (
              <>
                <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                {mode === "snapshot"
                  ? "Creating snapshot..."
                  : "Creating environment..."}
              </>
            ) : mode === "snapshot" ? (
              "Create snapshot version"
            ) : (
              "Snapshot environment"
            )}
          </button>
        </div>
      </div>
    </div>
  );

  const rightPane = (
    <div className="h-full bg-neutral-50 dark:bg-neutral-950">
      {isProvisioning ? (
        <div className="flex h-full items-center justify-center">
          <div className="text-center max-w-md px-6">
            <div className="w-16 h-16 mx-auto mb-4 rounded-lg bg-neutral-200 dark:bg-neutral-800 flex items-center justify-center">
              <Settings className="w-8 h-8 text-neutral-500 dark:text-neutral-400" />
            </div>
            <h3 className="text-lg font-medium text-neutral-900 dark:text-neutral-100 mb-2">
              Launching Environment
            </h3>
            <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-4">
              {mode === "snapshot"
                ? "Creating instance from snapshot. Once ready, VS Code and the browser will appear here so you can test your changes."
                : "Your development environment is launching. Once ready, VS Code and the browser will appear here so you can configure and test your setup."}
            </p>
          </div>
        </div>
      ) : (
        <div className="flex h-full flex-col">
          <div className="flex-1 min-h-0">{previewContent}</div>
        </div>
      )}
    </div>
  );

  return (
    <ResizableColumns
      storageKey={null}
      defaultLeftWidth={360}
      minLeft={220}
      maxLeft={700}
      left={leftPane}
      right={rightPane}
    />
  );
}
