import { GitHubIcon } from "@/components/icons/github";
import { PersistentWebView } from "@/components/persistent-webview";
import { ScriptTextareaField } from "@/components/ScriptTextareaField";
import { SCRIPT_COPY } from "@/components/scriptCopy";
import { ResizableColumns } from "@/components/ResizableColumns";
import { parseEnvBlock } from "@/lib/parseEnvBlock";
import {
  TASK_RUN_IFRAME_ALLOW,
  TASK_RUN_IFRAME_SANDBOX,
} from "@/lib/preloadTaskRunIframes";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
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
import { ArrowLeft, Loader2, Minus, Plus, Settings, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import TextareaAutosize from "react-textarea-autosize";

export type EnvVar = { name: string; value: string; isSecret: boolean };

type ViewMode = 'vscode' | 'browser';

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

export function EnvironmentConfiguration({
  selectedRepos,
  teamSlugOrId,
  instanceId,
  vscodeUrl,
  isProvisioning,
  mode = "new",
  sourceEnvironmentId,
  initialEnvName = "",
  initialMaintenanceScript = "",
  initialDevScript = "",
  initialExposedPorts = "",
  initialEnvVars,
}: {
  selectedRepos: string[];
  teamSlugOrId: string;
  instanceId?: string;
  vscodeUrl?: string;
  isProvisioning: boolean;
  mode?: "new" | "snapshot";
  sourceEnvironmentId?: Id<"environments">;
  initialEnvName?: string;
  initialMaintenanceScript?: string;
  initialDevScript?: string;
  initialExposedPorts?: string;
  initialEnvVars?: EnvVar[];
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
  };
  const [vscodeIframeLoaded, setVscodeIframeLoaded] = useState(false);
  const [vscodeIframeError, setVscodeIframeError] = useState<string | null>(null);
  const [browserIframeLoaded, setBrowserIframeLoaded] = useState(false);
  const [browserIframeError, setBrowserIframeError] = useState<string | null>(null);
  const [envName, setEnvName] = useState(() => initialEnvName);
  const [envVars, setEnvVars] = useState<EnvVar[]>(() =>
    ensureInitialEnvVars(initialEnvVars)
  );
  const [maintenanceScript, setMaintenanceScript] = useState(
    () => initialMaintenanceScript
  );
  const [devScript, setDevScript] = useState(() => initialDevScript);
  const [exposedPorts, setExposedPorts] = useState(() => initialExposedPorts);
  const [portsError, setPortsError] = useState<string | null>(null);
  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(
    null
  );
  const lastSubmittedEnvContent = useRef<string | null>(null);
  const [localInstanceId, setLocalInstanceId] = useState<string | undefined>(
    () => instanceId
  );
  const [localVscodeUrl, setLocalVscodeUrl] = useState<string | undefined>(
    () => vscodeUrl
  );
  const [viewMode, setViewMode] = useState<ViewMode>('vscode');
  const derivedBrowserUrl = useMemo(() => {
    if (!localInstanceId) return undefined;
    const hostId = localInstanceId.replace(/_/g, "-");
    const firstPort = exposedPorts
      .split(",")
      .map((p) => Number.parseInt(p.trim(), 10))
      .filter((n) => Number.isFinite(n) && n > 0)[0];
    if (!firstPort) return undefined;
    return `https://port-${firstPort}-${hostId}.http.cloud.morph.so/`;
  }, [localInstanceId, exposedPorts]);

  const iframePersistKey = useMemo(() => {
    if (localInstanceId) return `env-config:${localInstanceId}:${viewMode}`;
    if (localVscodeUrl) return `env-config:${localVscodeUrl}:${viewMode}`;
    return `env-config:${viewMode}`;
  }, [localInstanceId, localVscodeUrl, viewMode]);

  useEffect(() => {
    setLocalInstanceId(instanceId);
  }, [instanceId]);

  useEffect(() => {
    setLocalVscodeUrl(vscodeUrl);
  }, [vscodeUrl]);

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

  // Reset iframe loading states when URLs change
  useEffect(() => {
    setVscodeIframeLoaded(false);
    setVscodeIframeError(null);
  }, [localVscodeUrl]);

  useEffect(() => {
    setBrowserIframeLoaded(false);
    setBrowserIframeError(null);
  }, [derivedBrowserUrl]);

  const handleVscodeIframeLoad = useCallback(() => {
    setVscodeIframeError(null);
    setVscodeIframeLoaded(true);
  }, []);

  const handleVscodeIframeError = useCallback((error: Error) => {
    console.error("Failed to load VS Code workspace iframe", error);
    setVscodeIframeError(
      "We couldn't load VS Code. Try reloading or restarting the environment."
    );
  }, []);

  const handleBrowserIframeLoad = useCallback(() => {
    setBrowserIframeError(null);
    setBrowserIframeLoaded(true);
  }, []);

  const handleBrowserIframeError = useCallback((error: Error) => {
    console.error("Failed to load browser preview iframe", error);
    setBrowserIframeError(
      "We couldn't load the browser preview. Try reloading or check if the dev server is running."
    );
  }, []);



  const showVscodeIframeOverlay = !vscodeIframeLoaded || vscodeIframeError !== null;
  const showBrowserIframeOverlay = !browserIframeLoaded || browserIframeError !== null;

  // no-op placeholder removed; using onSnapshot instead

  useEffect(() => {
    lastSubmittedEnvContent.current = null;
  }, [localInstanceId]);

  useEffect(() => {
    if (!localInstanceId) {
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
          path: { id: localInstanceId },
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
  }, [envVars, localInstanceId, teamSlugOrId, applySandboxEnv]);

  const onSnapshot = async (): Promise<void> => {
    if (!localInstanceId) {
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
            morphInstanceId: localInstanceId,
            label: envName.trim(),
            activate: true,
            maintenanceScript: requestMaintenanceScript,
            devScript: requestDevScript,
          },
        },
        {
          onSuccess: async () => {
            await navigate({
              to: "/$teamSlugOrId/environments/$environmentId",
              params: {
                teamSlugOrId,
                environmentId: sourceEnvironmentId,
              },
              search: () => ({
                step: undefined,
                selectedRepos: undefined,
                connectionLogin: undefined,
                repoSearch: undefined,
                instanceId: undefined,
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
            morphInstanceId: localInstanceId,
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
            await navigate({
              to: "/$teamSlugOrId/environments",
              params: { teamSlugOrId },
              search: {
                step: undefined,
                selectedRepos: undefined,
                connectionLogin: undefined,
                repoSearch: undefined,
                instanceId: undefined,
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

  const leftPane = (
    <div className="h-full p-6 overflow-y-auto">
      <div className="flex items-center gap-4 mb-4">
        {mode === "new" ? (
          <button
            onClick={async () => {
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
            onChange={(e) => setEnvName(e.target.value)}
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
                    setEnvVars((prev) => {
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
              <div
                className="grid gap-3 text-xs text-neutral-500 dark:text-neutral-500 items-center pb-1"
                style={{
                  gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.4fr) 44px",
                }}
              >
                <span>Key</span>
                <span>Value</span>
                <span className="w-[44px]" />
              </div>

              <div className="space-y-2">
                {envVars.map((row, idx) => (
                  <div
                    key={idx}
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
                        setEnvVars((prev) => {
                          const next = [...prev];
                          next[idx] = { ...next[idx]!, name: v };
                          return next;
                        });
                      }}
                      placeholder="EXAMPLE_NAME"
                      className="w-full min-w-0 self-start rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                    />
                    <TextareaAutosize
                      value={row.value}
                      onChange={(e) => {
                        const v = e.target.value;
                        setEnvVars((prev) => {
                          const next = [...prev];
                          next[idx] = { ...next[idx]!, value: v };
                          return next;
                        });
                      }}
                      placeholder="I9JU23NF394R6HH"
                      minRows={1}
                      maxRows={10}
                      className="w-full min-w-0 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
                    />
                    <div className="self-start flex items-center justify-end w-[44px]">
                      <button
                        type="button"
                        onClick={() => {
                          setEnvVars((prev) => {
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
                ))}
              </div>

              <div className="pt-2">
                <button
                  type="button"
                  onClick={() =>
                    setEnvVars((prev) => [
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
                onChange={(next) => setMaintenanceScript(next)}
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
                onChange={(next) => setDevScript(next)}
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
                  onChange={(e) => setExposedPorts(e.target.value)}
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
      {!isProvisioning && (localVscodeUrl || derivedBrowserUrl) && (
        <div className="flex border-b border-neutral-200 dark:border-neutral-800">
          <button
            onClick={() => setViewMode('vscode')}
            className={clsx(
              "flex-1 px-4 py-2 text-sm font-medium border-b-2 transition-colors",
              viewMode === 'vscode'
                ? "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100"
                : "border-transparent text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200"
            )}
          >
            VS Code
          </button>
          <button
            onClick={() => setViewMode('browser')}
            className={clsx(
              "flex-1 px-4 py-2 text-sm font-medium border-b-2 transition-colors",
              viewMode === 'browser'
                ? "border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100"
                : "border-transparent text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200"
            )}
            disabled={!derivedBrowserUrl}
          >
            Browser
          </button>
        </div>
      )}
      {isProvisioning ? (
        <div className="flex items-center justify-center h-full">
          <div className="text-center max-w-md px-6">
            <div className="w-16 h-16 mx-auto mb-4 rounded-lg bg-neutral-200 dark:bg-neutral-800 flex items-center justify-center">
              <Settings className="w-8 h-8 text-neutral-500 dark:text-neutral-400" />
            </div>
            <h3 className="text-lg font-medium text-neutral-900 dark:text-neutral-100 mb-2">
              Launching Environment
            </h3>
            <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-4">
              {mode === "snapshot"
                ? "Creating instance from snapshot. Once ready, VS Code will appear here so you can test your changes."
                : "Your development environment is launching. Once ready, VS Code will appear here so you can configure and test your setup."}
            </p>
          </div>
        </div>
      ) : viewMode === 'vscode' && localVscodeUrl ? (
        <div className="relative h-full">
          <div
            aria-hidden={!showVscodeIframeOverlay}
            className={clsx(
              "absolute inset-0 z-[var(--z-low)] flex items-center justify-center backdrop-blur-sm transition-opacity duration-300",
              "bg-white/60 dark:bg-neutral-950/60",
              showVscodeIframeOverlay
                ? "opacity-100 pointer-events-auto"
                : "opacity-0 pointer-events-none"
            )}
          >
            {vscodeIframeError ? (
              <div className="text-center max-w-sm px-6">
                <X className="w-8 h-8 mx-auto mb-3 text-red-500" />
                <p className="text-sm text-neutral-700 dark:text-neutral-300">
                  {vscodeIframeError}
                </p>
              </div>
            ) : (
              <div className="text-center">
                <Loader2 className="w-6 h-6 mx-auto mb-3 animate-spin text-neutral-500 dark:text-neutral-400" />
                <p className="text-sm text-neutral-700 dark:text-neutral-300">
                  Loading VS Code...
                </p>
              </div>
            )}
          </div>
          <PersistentWebView
            persistKey={iframePersistKey}
            src={localVscodeUrl}
            className="absolute inset-0"
            iframeClassName="w-full h-full border-0"
            allow={TASK_RUN_IFRAME_ALLOW}
            sandbox={TASK_RUN_IFRAME_SANDBOX}
            retainOnUnmount
            onLoad={handleVscodeIframeLoad}
            onError={handleVscodeIframeError}
          />
        </div>
      ) : viewMode === 'browser' && derivedBrowserUrl ? (
        <div className="relative h-full">
          <div
            aria-hidden={!showBrowserIframeOverlay}
            className={clsx(
              "absolute inset-0 z-[var(--z-low)] flex items-center justify-center backdrop-blur-sm transition-opacity duration-300",
              "bg-white/60 dark:bg-neutral-950/60",
              showBrowserIframeOverlay
                ? "opacity-100 pointer-events-auto"
                : "opacity-0 pointer-events-none"
            )}
          >
            {browserIframeError ? (
              <div className="text-center max-w-sm px-6">
                <X className="w-8 h-8 mx-auto mb-3 text-red-500" />
                <p className="text-sm text-neutral-700 dark:text-neutral-300">
                  {browserIframeError}
                </p>
              </div>
            ) : (
              <div className="text-center">
                <Loader2 className="w-6 h-6 mx-auto mb-3 animate-spin text-neutral-500 dark:text-neutral-400" />
                <p className="text-sm text-neutral-700 dark:text-neutral-300">
                  Loading browser preview...
                </p>
              </div>
            )}
          </div>
          <PersistentWebView
            persistKey={iframePersistKey}
            src={derivedBrowserUrl}
            className="absolute inset-0"
            iframeClassName="w-full h-full border-0"
            allow={TASK_RUN_IFRAME_ALLOW}
            sandbox={TASK_RUN_IFRAME_SANDBOX}
            retainOnUnmount
            onLoad={handleBrowserIframeLoad}
            onError={handleBrowserIframeError}
          />
        </div>
      ) : (
        <div className="flex items-center justify-center h-full">
          <div className="text-center">
            <X className="w-8 h-8 mx-auto mb-4 text-red-500" />
            <p className="text-sm text-neutral-600 dark:text-neutral-400">
              {viewMode === 'vscode'
                ? "Waiting for VS Code environment URL..."
                : "Waiting for browser preview URL..."}
            </p>
            {viewMode === 'browser' && !derivedBrowserUrl && (
              <p className="text-xs text-neutral-500 dark:text-neutral-500 mt-2">
                Make sure to configure exposed ports in the dev script section.
              </p>
            )}
          </div>
        </div>
      )}
    </div>
  );

  return (
    <ResizableColumns
      storageKey="envConfigWidth"
      defaultLeftWidth={360}
      minLeft={220}
      maxLeft={700}
      left={leftPane}
      right={rightPane}
    />
  );
}
