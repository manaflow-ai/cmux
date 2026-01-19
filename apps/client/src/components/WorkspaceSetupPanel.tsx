import { parseEnvBlock } from "@/lib/parseEnvBlock";
import { ensureInitialEnvVars, type EnvVar } from "@/types/environment";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import {
  getApiWorkspaceConfigsOptions,
  postApiWorkspaceConfigsMutation,
} from "@cmux/www-openapi-client/react-query";
import { useQuery, useMutation as useRQMutation } from "@tanstack/react-query";
import { AlertTriangle, ChevronDown, ChevronRight, Loader2, Eye, EyeOff, Minus, Plus } from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
} from "react";
import { toast } from "sonner";
import TextareaAutosize from "react-textarea-autosize";
import { Button } from "./ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "./ui/tooltip";

const MASKED_ENV_VALUE = "••••••••••••••••";

type WorkspaceSetupPanelProps = {
  teamSlugOrId: string;
  projectFullName: string | null;
};

export function WorkspaceSetupPanel({
  teamSlugOrId,
  projectFullName,
}: WorkspaceSetupPanelProps) {
  const configQuery = useQuery({
    ...getApiWorkspaceConfigsOptions({
      query: {
        teamSlugOrId,
        projectFullName: projectFullName || "",
      },
    }),
    enabled: Boolean(projectFullName),
  });

  const saveMutation = useRQMutation(postApiWorkspaceConfigsMutation());

  const [maintenanceScript, setMaintenanceScript] = useState("");
  const [envVars, setEnvVars] = useState<EnvVar[]>(() =>
    ensureInitialEnvVars(),
  );
  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(
    null,
  );

  const originalConfigRef = useRef<{ script: string; envContent: string }>({
    script: "",
    envContent: "",
  });

  const hasInitializedFromServerRef = useRef(false);

  const [isExpanded, setIsExpanded] = useState(() => {
    const saved = localStorage.getItem('workspace-setup-expanded');
    return saved === 'true';
  });

  useEffect(() => {
    if (!projectFullName) return;
    setMaintenanceScript("");
    setEnvVars(ensureInitialEnvVars());
    originalConfigRef.current = { script: "", envContent: "" };
    hasInitializedFromServerRef.current = false;
  }, [projectFullName]);

  const toggleExpanded = useCallback(() => {
    setIsExpanded((prev) => {
      const next = !prev;
      localStorage.setItem('workspace-setup-expanded', String(next));
      return next;
    });
  }, []);

  useEffect(() => {
    if (configQuery.isPending) return;
    if (configQuery.error) return;
    if (configQuery.data === undefined) return;
    const data = configQuery.data;
    const nextScript = (data?.maintenanceScript ?? "").toString();
    const envContent = data?.envVarsContent ?? "";
    const parsedEnvVars =
      envContent.trim().length > 0
        ? parseEnvBlock(envContent).map((row) => ({
          name: row.name,
          value: row.value,
          isSecret: true,
        }))
        : [];
    const normalizedEnvContent = formatEnvVarsContent(
      parsedEnvVars
        .filter(
          (row) => row.name.trim().length > 0 || row.value.trim().length > 0,
        )
        .map((row) => ({ name: row.name, value: row.value })),
    );

    setMaintenanceScript(nextScript);
    setEnvVars(ensureInitialEnvVars(parsedEnvVars));
    originalConfigRef.current = {
      script: nextScript.trim(),
      envContent: normalizedEnvContent,
    };

    if (!hasInitializedFromServerRef.current) {
      hasInitializedFromServerRef.current = true;
    }
  }, [configQuery.data, configQuery.isPending, configQuery.error]);

  const updateEnvVars = useCallback(
    (updater: (prev: EnvVar[]) => EnvVar[]) => {
      setEnvVars((prev) => {
        const updated = updater(prev);
        // Always ensure at least 1 row exists
        return updated.length === 0
          ? [
            {
              name: "",
              value: "",
              isSecret: true,
            },
          ]
          : updated;
      });
    },
    [],
  );

  const currentEnvContent = useMemo(() => {
    const filtered = envVars
      .filter(
        (row) => row.name.trim().length > 0 || row.value.trim().length > 0,
      )
      .map((row) => ({ name: row.name, value: row.value }));
    return formatEnvVarsContent(filtered);
  }, [envVars]);

  const normalizedScript = maintenanceScript.trim();
  const hasChanges =
    normalizedScript !== originalConfigRef.current.script ||
    currentEnvContent !== originalConfigRef.current.envContent;

  const isConfigured =
    originalConfigRef.current.script.length > 0 ||
    originalConfigRef.current.envContent.length > 0;
  const shouldShowSetupWarning = !configQuery.isPending && !isConfigured;

  const handleSave = useCallback(() => {
    if (!projectFullName) return;

    const scriptToSave = normalizedScript.length
      ? normalizedScript
      : undefined;

    saveMutation.mutate(
      {
        body: {
          teamSlugOrId,
          projectFullName,
          maintenanceScript: scriptToSave,
          envVarsContent: currentEnvContent,
        },
      },
      {
        onSuccess: () => {
          originalConfigRef.current = {
            script: normalizedScript,
            envContent: currentEnvContent,
          };
          toast.success("Workspace setup saved");
        },
        onError: (error) => {
          console.error("[WorkspaceSetupPanel] Failed to save setup", error);
          toast.error("Failed to save workspace setup");
        },
      },
    );
  }, [
    currentEnvContent,
    normalizedScript,
    projectFullName,
    saveMutation,
    teamSlugOrId,
  ]);

  const handleEnvPaste = useCallback(
    (event: ClipboardEvent<HTMLDivElement>) => {
      const target = event.target as HTMLElement;
      const inputType = target.getAttribute?.("data-env-input");
      const text = event.clipboardData?.getData("text") ?? "";

      // Always allow normal paste into value fields (values can contain =, :, URLs, etc.)
      if (inputType === "value") {
        return;
      }

      if (!text || !/\n|=/.test(text)) {
        return;
      }
      event.preventDefault();
      const entries = parseEnvBlock(text);
      if (entries.length === 0) {
        return;
      }
      updateEnvVars((prev) => {
        const map = new Map(
          prev
            .filter(
              (row) =>
                row.name.trim().length > 0 || row.value.trim().length > 0,
            )
            .map((row) => [row.name, row] as const),
        );
        for (const entry of entries) {
          if (!entry.name) continue;
          map.set(entry.name, {
            name: entry.name,
            value: entry.value,
            isSecret: true,
          });
        }
        return Array.from(map.values());
      });
    },
    [updateEnvVars],
  );

  if (configQuery.error) {
    throw configQuery.error;
  }

  if (!projectFullName) {
    return null;
  }

  return (
    <div className={`mt-2 rounded-2xl relative ${isExpanded ? "" : ""}`}>
      <div
        className={`absolute inset-0 rounded-2xl border pointer-events-none ${isExpanded
          ? "border-neutral-200 dark:border-neutral-700"
          : "border-transparent"
          }`}
        style={{
          clipPath: isExpanded
            ? 'inset(0 0 0 0)'
            : 'inset(0 0 100% 0)',
        }}
      />
      <button
        type="button"
        onClick={toggleExpanded}
        className="w-full flex items-start justify-between gap-2 text-left px-2 py-1.5"
      >
        <div className="inline-flex items-center gap-1.5 pt-1 font-medium text-xs text-neutral-600 hover:text-neutral-800 dark:text-neutral-400 dark:hover:text-neutral-200">
          {isExpanded ? (
            <ChevronDown className="w-4 h-4 transition-transform duration-300" />
          ) : (
            <ChevronRight className="w-4 h-4 transition-transform duration-300" />
          )}
          <span>
            Configure workspace for{" "}
            <span className="font-semibold">{projectFullName}</span>
          </span>
          {configQuery.isPending ? (
            <span className="inline-flex animate-in fade-in-0 duration-300">
              <Loader2
                className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400 animate-spin"
                aria-label="Loading configuration"
              />
            </span>
          ) : shouldShowSetupWarning ? (
            <Tooltip delayDuration={0}>
              <TooltipTrigger asChild>
                <span className="inline-flex animate-in fade-in-0 duration-300">
                  <AlertTriangle
                    className="w-3.5 h-3.5 text-orange-600 dark:text-orange-500"
                    aria-label="Workspace setup incomplete"
                  />
                </span>
              </TooltipTrigger>
              <TooltipContent sideOffset={6}>
                Configure maintenance scripts and environment variables for this workspace.
              </TooltipContent>
            </Tooltip>
          ) : null}
        </div>
      </button>

      <div
        className={`overflow-hidden ${isExpanded ? "max-h-[2000px]" : "max-h-0"}`}
      >
        <div
          style={{
            clipPath: isExpanded ? 'inset(0 0 0 0)' : 'inset(0 0 100% 0)',
            opacity: isExpanded ? 1 : 0,
          }}
        >
          <div className="pl-[30px] pr-2 pb-1">
            <p className="text-[11px] text-neutral-600 dark:text-neutral-400">
              Set up maintenance scripts and environment variables for{" "}
              <span className="font-semibold">{projectFullName}</span>.
            </p>

            {configQuery.isPending ? (
              <p className="mt-3 text-[11px] text-neutral-500 dark:text-neutral-400">
                Loading saved configuration…
              </p>
            ) : (
              <div className="mt-1.5 space-y-1">
                {/* Setup Script Section */}
                <div className="space-y-1 pt-1">
                  <div className="flex flex-col gap-0.5">
                    <p className="text-xs font-medium text-neutral-900 dark:text-neutral-100">
                      Setup script
                    </p>
                    <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                      Runs after cloning your repository so dependencies and
                      services are ready. Executed from your repository root directory.
                      The <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 font-mono">CMUX_SETUP_MODE</code> environment
                      variable is set to <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 font-mono">local</code> or <code className="px-1 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 font-mono">cloud</code>.
                    </p>
                  </div>

                  <TextareaAutosize
                    value={maintenanceScript}
                    onChange={(e) => setMaintenanceScript(e.target.value)}
                    placeholder={`# e.g.\npnpm install\nbun install\nuv sync`}
                    minRows={3}
                    maxRows={50}
                    className="w-full rounded-md border border-neutral-200 bg-white px-2 py-1.5 text-[11px] font-mono text-neutral-900 placeholder:text-neutral-400 focus:outline-none focus:border-neutral-400 resize-none dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:placeholder:text-neutral-600 dark:focus:border-neutral-600"
                  />
                </div>

                {/* Environment Variables Section */}
                <div className="space-y-1 pt-1" onPasteCapture={handleEnvPaste}>
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="flex flex-col gap-0.5">
                      <p className="text-xs font-medium text-neutral-900 dark:text-neutral-100">
                        Environment variables
                      </p>
                      <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                        Stored securely and injected when your setup script runs.
                        Paste directly from .env files.
                      </p>
                    </div>
                    <button
                      type="button"
                      className="inline-flex items-center gap-1 rounded-md border border-neutral-200 bg-white px-2 py-1 text-[11px] font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:hover:bg-neutral-800"
                      onClick={() => {
                        setActiveEnvValueIndex(null);
                        setAreEnvValuesHidden((previous) => !previous);
                      }}
                      aria-pressed={!areEnvValuesHidden}
                      aria-label={
                        areEnvValuesHidden
                          ? "Show environment variable values"
                          : "Hide environment variable values"
                      }
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

                  <div className="space-y-1.5">
                    <div
                      className="grid gap-2 text-[11px] font-medium text-neutral-600 dark:text-neutral-400 items-center"
                      style={{ gridTemplateColumns: "3fr 7fr 36px" }}
                    >
                      <span>Key</span>
                      <span>Value</span>
                      <span />
                    </div>

                    <div className="space-y-1.5">
                      {envVars.map((row, idx) => {
                        const rowKey = idx;
                        const isEditingValue = activeEnvValueIndex === idx;
                        const shouldMaskValue =
                          areEnvValuesHidden &&
                          row.value.trim().length > 0 &&
                          !isEditingValue;
                        return (
                          <div
                            key={rowKey}
                            className="grid gap-2 items-center"
                            style={{
                              gridTemplateColumns: "3fr 7fr 36px",
                            }}
                          >
                            <input
                              type="text"
                              value={row.name}
                              onChange={(event) => {
                                const value = event.target.value;
                                updateEnvVars((prev) => {
                                  const next = [...prev];
                                  const current = next[idx];
                                  if (current) {
                                    next[idx] = { ...current, name: value };
                                  }
                                  return next;
                                });
                              }}
                              placeholder="EXAMPLE_KEY"
                              data-env-input="key"
                              className="w-full rounded-md border border-neutral-200 bg-white px-2 py-1.5 text-[11px] font-mono text-neutral-900 placeholder:text-neutral-400 focus:outline-none focus:border-neutral-400 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:placeholder:text-neutral-600 dark:focus:border-neutral-600"
                            />
                            <input
                              type="text"
                              value={
                                shouldMaskValue ? MASKED_ENV_VALUE : row.value
                              }
                              onChange={
                                shouldMaskValue
                                  ? undefined
                                  : (event) => {
                                      const value = event.target.value;
                                      updateEnvVars((prev) => {
                                        const next = [...prev];
                                        const current = next[idx];
                                        if (current) {
                                          next[idx] = { ...current, value };
                                        }
                                        return next;
                                      });
                                    }
                              }
                              placeholder="secret-value"
                              readOnly={shouldMaskValue}
                              aria-readonly={shouldMaskValue || undefined}
                              onFocus={() => setActiveEnvValueIndex(idx)}
                              onBlur={() => {
                                setActiveEnvValueIndex((current) =>
                                  current === idx ? null : current,
                                );
                              }}
                              data-env-input="value"
                              className="w-full rounded-md border border-neutral-200 bg-white px-2 py-1.5 text-[11px] font-mono text-neutral-900 placeholder:text-neutral-400 focus:outline-none focus:border-neutral-400 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:placeholder:text-neutral-600 dark:focus:border-neutral-600 transition"
                            />
                            <button
                              type="button"
                              className="inline-flex h-6 w-6 items-center justify-center text-neutral-400 transition-colors hover:text-neutral-600 dark:text-neutral-500 dark:hover:text-neutral-300"
                              onClick={() => {
                                setActiveEnvValueIndex(null);
                                updateEnvVars((prev) =>
                                  prev.filter((_, i) => i !== idx),
                                );
                              }}
                              aria-label="Remove variable"
                            >
                              <Minus className="h-3.5 w-3.5" />
                            </button>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                </div>

                {/* Save Button - Full Width at Bottom */}
                <div className="flex items-start justify-between gap-2 pt-1 pb-1">
                  <button
                    type="button"
                    className="inline-flex items-center gap-1 text-[11px] text-neutral-500 transition-colors hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200"
                    onClick={() =>
                      updateEnvVars((prev) => [
                        ...prev,
                        {
                          name: "",
                          value: "",
                          isSecret: true,
                        },
                      ])
                    }
                  >
                    <Plus className="h-3.5 w-3.5" />
                    Add variable
                  </button>
                  <div className="flex items-center gap-2">
                    {hasChanges && !saveMutation.isPending ? (
                      <span className="text-[11px] text-amber-600 dark:text-amber-400">
                        Unsaved changes
                      </span>
                    ) : null}
                    <Button
                      size="sm"
                      variant="default"
                      className="!h-7 focus-visible:ring-offset-1 focus-visible:ring-offset-white dark:focus-visible:ring-offset-neutral-900"
                      onClick={handleSave}
                      disabled={!hasChanges || saveMutation.isPending}
                    >
                      {saveMutation.isPending ? "Saving…" : "Save setup"}
                    </Button>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div >
  );
}
