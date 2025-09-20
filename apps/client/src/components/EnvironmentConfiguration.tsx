import { GitHubIcon } from "@/components/icons/github";
import { ResizableColumns } from "@/components/ResizableColumns";
import { parseEnvBlock } from "@/lib/parseEnvBlock";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import {
  postApiEnvironmentsMutation,
  postApiSandboxesByIdEnvMutation,
} from "@cmux/www-openapi-client/react-query";
import { Accordion, AccordionItem } from "@heroui/react";
import { useMutation as useRQMutation } from "@tanstack/react-query";
import { useNavigate, useSearch } from "@tanstack/react-router";
import clsx from "clsx";
import { ArrowLeft, Loader2, Minus, Plus, Settings, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import TextareaAutosize from "react-textarea-autosize";

export type EnvVar = { name: string; value: string; isSecret: boolean };

export function EnvironmentConfiguration({
  selectedRepos,
  teamSlugOrId,
  instanceId,
  vscodeUrl,
  isProvisioning,
}: {
  selectedRepos: string[];
  teamSlugOrId: string;
  instanceId?: string;
  vscodeUrl?: string;
  isProvisioning: boolean;
}) {
  const navigate = useNavigate();
  const search = useSearch({ from: "/_layout/$teamSlugOrId/environments/new" });
  const [iframeLoaded, setIframeLoaded] = useState(false);
  const [envName, setEnvName] = useState("");
  const [envVars, setEnvVars] = useState<EnvVar[]>([
    { name: "", value: "", isSecret: true },
  ]);
  const [maintenanceScript, setMaintenanceScript] = useState("");
  const [devScript, setDevScript] = useState("");
  const [exposedPorts, setExposedPorts] = useState("3000, 8080");
  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(
    null
  );
  const lastSubmittedEnvContent = useRef<string | null>(null);
  const createEnvironmentMutation = useRQMutation(
    postApiEnvironmentsMutation()
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

  // Reset iframe loading state when URL changes
  useEffect(() => {
    setIframeLoaded(false);
  }, [vscodeUrl]);

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
  }, [envVars, instanceId, teamSlugOrId, applySandboxEnv]);

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

    const ports = exposedPorts
      .split(",")
      .map((p) => parseInt(p.trim(), 10))
      .filter((n) => Number.isFinite(n) && n > 0);

    createEnvironmentMutation.mutate(
      {
        body: {
          teamSlugOrId,
          name: envName.trim(),
          morphInstanceId: instanceId,
          envVarsContent,
          selectedRepos,
          maintenanceScript: maintenanceScript.trim() || undefined,
          devScript: devScript.trim() || undefined,
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
  };

  const leftPane = (
    <div className="h-full p-6 overflow-y-auto">
      <div className="flex items-center gap-4 mb-4">
        <button
          onClick={async () => {
            await navigate({
              to: "/$teamSlugOrId/environments/new",
              params: { teamSlugOrId },
              search: (prev) => ({
                ...prev,
                step: "select",
                selectedRepos:
                  selectedRepos.length > 0 ? selectedRepos : undefined,
                instanceId: search.instanceId,
                connectionLogin: prev.connectionLogin,
                repoSearch: prev.repoSearch,
              }),
            });
          }}
          className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100"
        >
          <ArrowLeft className="w-4 h-4" />
          Back to repository selection
        </button>
      </div>

      <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
        Configure Environment
      </h1>
      <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
        Set up your environment name and variables.
      </p>

      <div className="mt-6 space-y-4">
        <div className="space-y-2">
          <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
            Environment name
          </label>
          <input
            type="text"
            value={envName}
            onChange={(e) => setEnvName(e.target.value)}
            placeholder="e.g. project-name"
            className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
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
            <div className="space-y-2 pb-4">
              <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                Script that runs after git pull in case new dependencies were
                added.
              </p>
              <TextareaAutosize
                value={maintenanceScript}
                onChange={(e) => setMaintenanceScript(e.target.value)}
                placeholder={`# e.g.
bun install
npm install
uv sync
pip install -r requirements.txt
etc.`}
                minRows={3}
                maxRows={15}
                className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
              />
            </div>
          </AccordionItem>

          <AccordionItem
            key="dev-script"
            aria-label="Dev script"
            title="Dev script"
          >
            <div className="space-y-4 pb-4">
              <div className="space-y-2">
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  Script that starts the development server.
                </p>
                <TextareaAutosize
                  value={devScript}
                  onChange={(e) => setDevScript(e.target.value)}
                  placeholder={`# e.g.
npm run dev
bun dev
python manage.py runserver
rails server
cargo run
etc.`}
                  minRows={3}
                  maxRows={15}
                  className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-none"
                />
              </div>

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
              </div>
            </div>
          </AccordionItem>
        </Accordion>

        <div className="pt-2">
          <button
            type="button"
            onClick={onSnapshot}
            disabled={isProvisioning || createEnvironmentMutation.isPending}
            className="inline-flex items-center rounded-md bg-neutral-900 text-white disabled:bg-neutral-300 dark:disabled:bg-neutral-700 disabled:cursor-not-allowed px-4 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            {isProvisioning || createEnvironmentMutation.isPending ? (
              <>
                <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                {isProvisioning ? "Launching..." : "Creating environment..."}
              </>
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
        <div className="flex items-center justify-center h-full">
          <div className="text-center max-w-md px-6">
            <div className="w-16 h-16 mx-auto mb-4 rounded-lg bg-neutral-200 dark:bg-neutral-800 flex items-center justify-center">
              <Settings className="w-8 h-8 text-neutral-500 dark:text-neutral-400" />
            </div>
            <h3 className="text-lg font-medium text-neutral-900 dark:text-neutral-100 mb-2">
              Launching Environment
            </h3>
            <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-4">
              Your development environment is launching. Once ready, VS Code
              will appear here so you can configure and test your setup.
            </p>
          </div>
        </div>
      ) : vscodeUrl ? (
        <div className="relative h-full">
          <div
            aria-hidden={iframeLoaded}
            className={clsx(
              "absolute inset-0 z-[var(--z-low)] flex items-center justify-center backdrop-blur-sm transition-opacity duration-300",
              "bg-white/60 dark:bg-neutral-950/60",
              iframeLoaded
                ? "opacity-0 pointer-events-none"
                : "opacity-100 pointer-events-auto"
            )}
          >
            <div className="text-center">
              <Loader2 className="w-6 h-6 mx-auto mb-3 animate-spin text-neutral-500 dark:text-neutral-400" />
              <p className="text-sm text-neutral-700 dark:text-neutral-300">
                Loading VS Code...
              </p>
            </div>
          </div>
          <iframe
            src={vscodeUrl}
            className="w-full h-full border-0"
            title="VSCode Environment"
            allow="clipboard-read; clipboard-write"
            onLoad={() => setIframeLoaded(true)}
          />
        </div>
      ) : (
        <div className="flex items-center justify-center h-full">
          <div className="text-center">
            <X className="w-8 h-8 mx-auto mb-4 text-red-500" />
            <p className="text-sm text-neutral-600 dark:text-neutral-400">
              Waiting for environment URL...
            </p>
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
