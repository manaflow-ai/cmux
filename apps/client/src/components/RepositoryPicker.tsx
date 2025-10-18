import { env } from "@/client-env";
import { GitHubIcon } from "@/components/icons/github";
import { GitLabIcon } from "@/components/icons/gitlab";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { api } from "@cmux/convex/api";
import { DEFAULT_MORPH_SNAPSHOT_ID, type MorphSnapshotId } from "@cmux/shared";
import { isElectron } from "@/lib/electron";
import {
  getApiIntegrationsGithubReposOptions,
  postApiMorphSetupInstanceMutation,
} from "@cmux/www-openapi-client/react-query";
import * as Popover from "@radix-ui/react-popover";
import {
  useQuery as useRQ,
  useMutation as useRQMutation,
} from "@tanstack/react-query";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { useMutation, useQuery } from "convex/react";
import { Check, ChevronDown, Loader2, Settings, X } from "lucide-react";
import {
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  updatePendingEnvironment,
  type PendingEnvironmentId,
} from "@/lib/pendingEnvironmentsStore";
import { RepositoryAdvancedOptions } from "./RepositoryAdvancedOptions";

function ConnectionIcon({ type }: { type?: string }) {
  if (type && type.includes("gitlab")) {
    return (
      <GitLabIcon className="h-4 w-4 text-neutral-600 dark:text-neutral-300" />
    );
  }
  return (
    <GitHubIcon className="h-4 w-4 text-neutral-700 dark:text-neutral-200" />
  );
}

function formatTimeAgo(input?: string | number): string {
  if (!input) return "";
  const ts = typeof input === "number" ? input : Date.parse(input);
  if (Number.isNaN(ts)) return "";
  const diff = Date.now() - ts;
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return "just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  const mo = Math.floor(day / 30);
  if (mo < 12) return `${mo}mo ago`;
  const yr = Math.floor(mo / 12);
  return `${yr}y ago`;
}

interface ConnectionContext {
  selectedLogin: string | null;
  installationId: number | null;
  hasConnections: boolean;
}

interface RepositoryConnectionsSectionProps {
  teamSlugOrId: string;
  selectedLogin: string | null;
  onSelectedLoginChange: (login: string | null) => void;
  onContextChange: (context: ConnectionContext) => void;
  onConnectionsInvalidated: () => void;
}

interface RepositoryListSectionProps {
  teamSlugOrId: string;
  installationId: number | null;
  selectedRepos: readonly string[];
  onToggleRepo: (repo: string) => void;
  hasConnections: boolean;
}

export interface RepositoryPickerProps {
  teamSlugOrId: string;
  instanceId?: string;
  initialSelectedRepos?: string[];
  initialSnapshotId?: MorphSnapshotId;
  initialConnectionLogin?: string | null;
  showHeader?: boolean;
  showContinueButton?: boolean;
  showManualConfigOption?: boolean;
  continueButtonText?: string;
  manualConfigButtonText?: string;
  headerTitle?: string;
  headerDescription?: string;
  className?: string;
  pendingEnvironmentId?: PendingEnvironmentId;
  onDraftCreated?: () => Promise<PendingEnvironmentId | undefined>;
}

export function RepositoryPicker({
  teamSlugOrId,
  instanceId,
  initialSelectedRepos = [],
  initialSnapshotId,
  initialConnectionLogin = null,
  showHeader = true,
  showContinueButton = true,
  showManualConfigOption = true,
  continueButtonText = "Continue",
  manualConfigButtonText = "Configure manually",
  headerTitle = "Select Repositories",
  headerDescription = "Choose repositories to include in your environment.",
  className = "",
  pendingEnvironmentId,
  onDraftCreated,
}: RepositoryPickerProps) {
  const router = useRouter();
  const navigate = useNavigate();
  const uniqueInitialRepos = useMemo(
    () => Array.from(new Set(initialSelectedRepos)),
    [initialSelectedRepos]
  );
  const initialSnapshot = initialSnapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID;
  const [selectedRepos, setSelectedRepos] = useState<string[]>(() => [
    ...uniqueInitialRepos,
  ]);
  const [selectedSnapshotId, setSelectedSnapshotId] = useState<MorphSnapshotId>(
    () => initialSnapshot
  );
  const [selectedConnectionLogin, setSelectedConnectionLogin] = useState<
    string | null
  >(() => initialConnectionLogin ?? null);
  const [connectionContext, setConnectionContext] = useState<ConnectionContext>(
    {
      selectedLogin: null,
      installationId: null,
      hasConnections: false,
    }
  );

  const pendingIdRef = useRef<PendingEnvironmentId | null>(
    pendingEnvironmentId ?? null
  );
  useEffect(() => {
    pendingIdRef.current = pendingEnvironmentId ?? null;
  }, [pendingEnvironmentId]);

  const ensureDraftId = useCallback(
    async (): Promise<PendingEnvironmentId | undefined> => {
      if (pendingIdRef.current) {
        return pendingIdRef.current;
      }
      if (!onDraftCreated) {
        return undefined;
      }
      const createdId = await onDraftCreated();
      if (createdId) {
        pendingIdRef.current = createdId;
      }
      return createdId;
    },
    [onDraftCreated]
  );

  const handleSelectedLoginChange = useCallback(
    (login: string | null) => {
      setSelectedConnectionLogin(login);
      if (!pendingIdRef.current && selectedRepos.length === 0) {
        return;
      }
      void (async () => {
        const draftId = pendingIdRef.current ?? (await ensureDraftId());
        if (!draftId) {
          return;
        }
        updatePendingEnvironment(teamSlugOrId, draftId, {
          step: "select",
          selectedRepos,
          snapshotId: selectedSnapshotId,
          instanceId: instanceId ?? undefined,
          connectionLogin: login === null ? null : login,
        });
      })();
    },
    [
      ensureDraftId,
      instanceId,
      selectedRepos,
      selectedSnapshotId,
      teamSlugOrId,
    ]
  );

  const setupInstanceMutation = useRQMutation(
    postApiMorphSetupInstanceMutation()
  );
  const setupManualInstanceMutation = useRQMutation(
    postApiMorphSetupInstanceMutation()
  );

  useEffect(() => {
    const nextSnapshot = initialSnapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID;
    setSelectedSnapshotId(nextSnapshot);
    if (!pendingIdRef.current) {
      return;
    }
    updatePendingEnvironment(teamSlugOrId, pendingIdRef.current, {
      snapshotId: nextSnapshot,
    });
  }, [initialSnapshotId, teamSlugOrId]);

  const handleConnectionsInvalidated = useCallback((): void => {
    const qc = router.options.context?.queryClient;
    if (qc) {
      qc.invalidateQueries();
    }
    window.focus?.();
  }, [router]);

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const data = event.data as unknown;
      if (
        data &&
        typeof data === "object" &&
        (data as { type?: string }).type === "cmux/github-install-complete"
      ) {
        handleConnectionsInvalidated();
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [handleConnectionsInvalidated]);

  const goToConfigure = useCallback(
    async (repos: string[], maybeInstanceId?: string): Promise<void> => {
      const effectiveInstanceId = maybeInstanceId ?? instanceId ?? undefined;
      const draftId = pendingIdRef.current ?? (await ensureDraftId());
      if (!draftId) {
        return;
      }
      await navigate({
        to: "/$teamSlugOrId/environments/new",
        params: { teamSlugOrId },
        search: (prev) => ({
          step: "configure",
          selectedRepos: repos,
          instanceId: effectiveInstanceId ?? prev.instanceId,
          connectionLogin:
            selectedConnectionLogin ?? prev.connectionLogin ?? undefined,
          repoSearch: prev.repoSearch,
          snapshotId: selectedSnapshotId,
          pendingId: draftId,
        }),
        replace: !instanceId && Boolean(maybeInstanceId),
      });
      updatePendingEnvironment(teamSlugOrId, draftId, {
        step: "configure",
        selectedRepos: repos,
        snapshotId: selectedSnapshotId,
        instanceId: effectiveInstanceId,
        connectionLogin:
          selectedConnectionLogin === null
            ? null
            : selectedConnectionLogin,
      });
    },
    [
      ensureDraftId,
      instanceId,
      navigate,
      selectedConnectionLogin,
      selectedSnapshotId,
      teamSlugOrId,
    ]
  );

  const handleContinue = useCallback(
    (repos: string[]): void => {
      const mutation =
        repos.length > 0 ? setupInstanceMutation : setupManualInstanceMutation;
      mutation.mutate(
        {
          body: {
            teamSlugOrId,
            instanceId: instanceId ?? undefined,
            selectedRepos: repos,
            snapshotId: selectedSnapshotId,
          },
        },
        {
          onSuccess: async (data) => {
            await goToConfigure(repos, data.instanceId);
            console.log("Cloned repos:", data.clonedRepos);
            console.log("Removed repos:", data.removedRepos);
          },
          onError: (error) => {
            console.error("Failed to setup instance:", error);
          },
        }
      );
    },
    [
      goToConfigure,
      instanceId,
      selectedSnapshotId,
      setupInstanceMutation,
      setupManualInstanceMutation,
      teamSlugOrId,
    ]
  );

  const updateSnapshotSelection = useCallback(
    (nextSnapshotId: MorphSnapshotId) => {
      setSelectedSnapshotId(nextSnapshotId);
      void (async () => {
        let draftId: PendingEnvironmentId | undefined =
          pendingIdRef.current ?? undefined;
        if (!draftId && selectedRepos.length > 0) {
          draftId = await ensureDraftId();
        }
        await navigate({
          to: "/$teamSlugOrId/environments/new",
          params: { teamSlugOrId },
          search: (prev) => ({
            step: prev.step ?? "select",
            selectedRepos: prev.selectedRepos ?? [],
            instanceId: prev.instanceId,
          connectionLogin:
            selectedConnectionLogin ?? prev.connectionLogin ?? undefined,
            repoSearch: prev.repoSearch,
            snapshotId: nextSnapshotId,
            pendingId: draftId ?? prev.pendingId,
          }),
          replace: true,
        });
        if (draftId) {
          updatePendingEnvironment(teamSlugOrId, draftId, {
            step: "select",
            selectedRepos,
            snapshotId: nextSnapshotId,
            instanceId: instanceId ?? undefined,
          });
        }
      })();
    },
    [
      ensureDraftId,
      instanceId,
      navigate,
      selectedConnectionLogin,
      selectedRepos,
      teamSlugOrId,
    ]
  );

  const syncSelectedRepos = useCallback(
    (nextSelected: string[]) => {
      if (nextSelected.length === 0 && !pendingIdRef.current) {
        return;
      }
      void (async () => {
        const draftId: PendingEnvironmentId | undefined =
          pendingIdRef.current ?? (await ensureDraftId());
        if (!draftId) {
          return;
        }
        updatePendingEnvironment(teamSlugOrId, draftId, {
          step: "select",
          selectedRepos: nextSelected,
          snapshotId: selectedSnapshotId,
          instanceId: instanceId ?? undefined,
          connectionLogin:
            selectedConnectionLogin === null
              ? null
              : selectedConnectionLogin,
        });
      })();
    },
    [
      ensureDraftId,
      instanceId,
      selectedConnectionLogin,
      selectedSnapshotId,
      teamSlugOrId,
    ]
  );

  const toggleRepo = useCallback(
    (repo: string) => {
      setSelectedRepos((prev) => {
        const next = prev.includes(repo)
          ? prev.filter((item) => item !== repo)
          : [...prev, repo];
        syncSelectedRepos(next);
        return next;
      });
    },
    [syncSelectedRepos]
  );

  const removeRepo = useCallback(
    (repo: string) => {
      setSelectedRepos((prev) => {
        const next = prev.filter((item) => item !== repo);
        syncSelectedRepos(next);
        return next;
      });
    },
    [syncSelectedRepos]
  );

  const setConnectionContextSafe = useCallback((ctx: ConnectionContext) => {
    setConnectionContext((prev) => {
      if (
        prev.selectedLogin === ctx.selectedLogin &&
        prev.installationId === ctx.installationId &&
        prev.hasConnections === ctx.hasConnections
      ) {
        return prev;
      }
      return ctx;
    });
  }, []);

  const isContinueLoading = setupInstanceMutation.isPending;
  const isManualLoading = setupManualInstanceMutation.isPending;

  return (
    <div className={className}>
      {showHeader && (
        <>
          <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
            {headerTitle}
          </h1>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            {headerDescription}
          </p>
        </>
      )}

      <div className="space-y-6 mt-6">
        <RepositoryConnectionsSection
          teamSlugOrId={teamSlugOrId}
          selectedLogin={selectedConnectionLogin ?? null}
          onSelectedLoginChange={handleSelectedLoginChange}
          onContextChange={setConnectionContextSafe}
          onConnectionsInvalidated={handleConnectionsInvalidated}
        />

        <RepositoryListSection
          teamSlugOrId={teamSlugOrId}
          installationId={connectionContext.installationId}
          selectedRepos={selectedRepos}
          onToggleRepo={toggleRepo}
          hasConnections={connectionContext.hasConnections}
        />

        {selectedRepos.length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {selectedRepos.map((fullName) => (
              <span
                key={fullName}
                className="inline-flex items-center gap-1 rounded-full border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 px-2 py-1 text-xs"
              >
                <button
                  type="button"
                  aria-label={`Remove ${fullName}`}
                  onClick={() => removeRepo(fullName)}
                  className="-ml-1 inline-flex h-4 w-4 items-center justify-center rounded-full hover:bg-neutral-100 dark:hover:bg-neutral-900"
                >
                  <X className="h-3 w-3" />
                </button>
                <GitHubIcon className="h-3 w-3 shrink-0 text-neutral-700 dark:text-neutral-300" />
                {fullName}
              </span>
            ))}
          </div>
        ) : null}

        <RepositoryAdvancedOptions
          selectedSnapshotId={selectedSnapshotId}
          onSnapshotChange={updateSnapshotSelection}
        />

        {showContinueButton && (
          <>
            <div className="flex items-center gap-3 pt-2">
              <button
                type="button"
                disabled={
                  selectedRepos.length === 0 ||
                  isContinueLoading ||
                  isManualLoading
                }
                onClick={() => handleContinue(selectedRepos)}
                className={`inline-flex items-center gap-2 rounded-md bg-neutral-900 text-white disabled:bg-neutral-300 dark:disabled:bg-neutral-700 disabled:cursor-not-allowed px-3 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200 transition-opacity ${
                  isManualLoading ? "opacity-50" : "opacity-100"
                }`}
              >
                {isContinueLoading && (
                  <Loader2 className="h-3 w-3 animate-spin" />
                )}
                {continueButtonText}
              </button>
              {showManualConfigOption && (
                <button
                  type="button"
                  disabled={isContinueLoading || isManualLoading}
                  onClick={() => handleContinue([])}
                  className={`inline-flex items-center gap-2 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:cursor-not-allowed transition-opacity ${
                    isContinueLoading ? "opacity-50" : "opacity-100"
                  }`}
                >
                  {isManualLoading && (
                    <Loader2 className="h-3 w-3 animate-spin" />
                  )}
                  {manualConfigButtonText}
                </button>
              )}
            </div>
            {showManualConfigOption && (
              <p className="text-xs text-neutral-500 dark:text-neutral-500">
                You can also manually configure an environment from a bare VM.
                We'll capture your changes as a reusable base snapshot.
              </p>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function RepositoryConnectionsSection({
  teamSlugOrId,
  selectedLogin,
  onSelectedLoginChange,
  onContextChange,
  onConnectionsInvalidated,
}: RepositoryConnectionsSectionProps) {
  const connections = useQuery(api.github.listProviderConnections, {
    teamSlugOrId,
  });
  const mintState = useMutation(api.github_app.mintInstallState);
  const [connectionDropdownOpen, setConnectionDropdownOpen] = useState(false);
  const [connectionSearch, setConnectionSearch] = useState("");

  const activeConnections = useMemo(
    () => (connections || []).filter((c) => c.isActive !== false),
    [connections]
  );

  const currentLogin = useMemo(() => {
    if (selectedLogin) return selectedLogin;
    if (activeConnections.length > 0) {
      return activeConnections[0]?.accountLogin ?? null;
    }
    return null;
  }, [selectedLogin, activeConnections]);

  useEffect(() => {
    if (!selectedLogin && currentLogin) {
      onSelectedLoginChange(currentLogin);
    }
  }, [currentLogin, onSelectedLoginChange, selectedLogin]);

  const filteredConnections = useMemo(() => {
    if (!connectionSearch.trim()) return activeConnections;
    const searchLower = connectionSearch.toLowerCase();
    return activeConnections.filter((c) => {
      const name = c.accountLogin || `installation-${c.installationId}`;
      return name.toLowerCase().includes(searchLower);
    });
  }, [activeConnections, connectionSearch]);

  const selectedInstallationId = useMemo(() => {
    const match = activeConnections.find(
      (c) => c.accountLogin === currentLogin
    );
    return (
      match?.installationId ?? activeConnections[0]?.installationId ?? null
    );
  }, [activeConnections, currentLogin]);

  const installNewUrl = env.NEXT_PUBLIC_GITHUB_APP_SLUG
    ? `https://github.com/apps/${env.NEXT_PUBLIC_GITHUB_APP_SLUG}/installations/new`
    : null;

  useEffect(() => {
    onContextChange({
      selectedLogin: currentLogin,
      installationId: selectedInstallationId,
      hasConnections: activeConnections.length > 0,
    });
  }, [
    activeConnections.length,
    currentLogin,
    onContextChange,
    selectedInstallationId,
  ]);

  const watchPopupClosed = useCallback(
    (win: Window | null, onClose: () => void) => {
      if (!win) return;
      const timer = window.setInterval(() => {
        try {
          if (win.closed) {
            window.clearInterval(timer);
            onClose();
          }
        } catch (_error) {
          void 0;
        }
      }, 600);
    },
    []
  );

  const openCenteredPopup = useCallback(
    (
      url: string,
      opts?: { name?: string; width?: number; height?: number },
      onClose?: () => void
    ): Window | null => {
      if (isElectron) {
        window.open(url, "_blank", "noopener,noreferrer");
        return null;
      }
      const name = opts?.name ?? "cmux-popup";
      const width = Math.floor(opts?.width ?? 980);
      const height = Math.floor(opts?.height ?? 780);
      const dualScreenLeft = window.screenLeft ?? window.screenX ?? 0;
      const dualScreenTop = window.screenTop ?? window.screenY ?? 0;
      const outerWidth = window.outerWidth || window.innerWidth || width;
      const outerHeight = window.outerHeight || window.innerHeight || height;
      const left = Math.max(0, dualScreenLeft + (outerWidth - width) / 2);
      const top = Math.max(0, dualScreenTop + (outerHeight - height) / 2);
      const features = [
        `width=${width}`,
        `height=${height}`,
        `left=${Math.floor(left)}`,
        `top=${Math.floor(top)}`,
        "resizable=yes",
        "scrollbars=yes",
        "toolbar=no",
        "location=no",
        "status=no",
        "menubar=no",
      ].join(",");

      const win = window.open("about:blank", name, features);
      if (win) {
        try {
          (win as Window & { opener: null | Window }).opener = null;
        } catch (_error) {
          void 0;
        }
        try {
          win.location.href = url;
        } catch (_error) {
          window.open(url, "_blank");
        }
        win.focus?.();
        if (onClose) watchPopupClosed(win, onClose);
        return win;
      } else {
        window.open(url, "_blank");
        return null;
      }
    },
    [watchPopupClosed]
  );

  const handlePopupClosedRefetch = useCallback(() => {
    onConnectionsInvalidated();
  }, [onConnectionsInvalidated]);

  const handleInstallApp = useCallback(async () => {
    if (!installNewUrl) return;
    try {
      const { state } = await mintState({ teamSlugOrId });
      const sep = installNewUrl.includes("?") ? "&" : "?";
      const url = `${installNewUrl}${sep}state=${encodeURIComponent(state)}`;
      openCenteredPopup(
        url,
        { name: "github-install" },
        handlePopupClosedRefetch
      );
    } catch (err) {
      console.error("Failed to start GitHub install:", err);
      alert("Failed to start installation. Please try again.");
    }
  }, [
    handlePopupClosedRefetch,
    installNewUrl,
    mintState,
    openCenteredPopup,
    teamSlugOrId,
  ]);

  return (
    <div className="space-y-2">
      <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
        Connection
      </label>
      <Popover.Root
        open={connectionDropdownOpen}
        onOpenChange={setConnectionDropdownOpen}
      >
        <Popover.Trigger asChild>
          <button className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 h-9 flex items-center justify-between text-sm text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900 transition-colors">
            <div className="flex items-center gap-2 min-w-0">
              {currentLogin ? (
                <>
                  <ConnectionIcon type="github" />
                  <span className="truncate">{currentLogin}</span>
                </>
              ) : (
                <span className="truncate text-neutral-500">
                  Select connection
                </span>
              )}
            </div>
            <ChevronDown className="w-4 h-4 text-neutral-500" />
          </button>
        </Popover.Trigger>
        <Popover.Portal>
          <Popover.Content
            className="w-[320px] rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 shadow-md outline-none z-[var(--z-popover)]"
            align="start"
            sideOffset={4}
          >
            <Command shouldFilter={false}>
              <CommandInput
                placeholder="Search connections..."
                value={connectionSearch}
                onValueChange={setConnectionSearch}
              />
              <CommandList>
                {connections === undefined ? (
                  <div className="px-3 py-2 text-sm text-neutral-500">
                    Loading...
                  </div>
                ) : activeConnections.length > 0 ? (
                  <>
                    {filteredConnections.length > 0 ? (
                      <CommandGroup>
                        {filteredConnections.map((c) => {
                          const name =
                            c.accountLogin ||
                            `installation-${c.installationId}`;
                          const cfgUrl =
                            c.accountLogin && c.accountType
                              ? c.accountType === "Organization"
                                ? `https://github.com/organizations/${c.accountLogin}/settings/installations/${c.installationId}`
                                : `https://github.com/settings/installations/${c.installationId}`
                              : null;
                          const isSelected = currentLogin === c.accountLogin;
                          return (
                            <CommandItem
                              key={`${c.accountLogin}:${c.installationId}`}
                              value={name}
                              onSelect={() => {
                                onSelectedLoginChange(c.accountLogin ?? null);
                                setConnectionDropdownOpen(false);
                              }}
                              className="flex items-center justify-between gap-2"
                            >
                              <div className="flex items-center gap-2 min-w-0 flex-1">
                                <ConnectionIcon type={c.type} />
                                <span className="truncate">{name}</span>
                                {isSelected && (
                                  <Check className="ml-auto h-4 w-4 text-neutral-600 dark:text-neutral-300" />
                                )}
                              </div>
                              {cfgUrl ? (
                                <Tooltip>
                                  <TooltipTrigger asChild>
                                    <button
                                      type="button"
                                      className="p-1 rounded hover:bg-neutral-100 dark:hover:bg-neutral-800 relative z-[var(--z-popover-hover)]"
                                      onClick={(e) => {
                                        e.stopPropagation();
                                        e.preventDefault();
                                        openCenteredPopup(
                                          cfgUrl,
                                          { name: "github-config" },
                                          handlePopupClosedRefetch
                                        );
                                      }}
                                    >
                                      <Settings className="w-3 h-3 text-neutral-600 dark:text-neutral-300" />
                                    </button>
                                  </TooltipTrigger>
                                  <TooltipContent className="z-[var(--z-tooltip)]">
                                    Add Repos
                                  </TooltipContent>
                                </Tooltip>
                              ) : null}
                            </CommandItem>
                          );
                        })}
                      </CommandGroup>
                    ) : connectionSearch.trim() ? (
                      <div className="px-3 py-2 text-sm text-neutral-500">
                        No connections match your search
                      </div>
                    ) : null}
                    {installNewUrl ? (
                      <>
                        <div className="h-px bg-neutral-200 dark:bg-neutral-800" />
                        <CommandGroup forceMount>
                          <CommandItem
                            value="add-github-account"
                            forceMount
                            onSelect={() => {
                              void handleInstallApp();
                              setConnectionDropdownOpen(false);
                            }}
                            className="flex items-center gap-2"
                          >
                            <GitHubIcon className="h-4 w-4 text-neutral-700 dark:text-neutral-200" />
                            <span>Install GitHub App</span>
                          </CommandItem>
                        </CommandGroup>
                      </>
                    ) : null}
                  </>
                ) : (
                  <>
                    <CommandEmpty>
                      <div className="px-3 py-2 text-sm text-neutral-500">
                        No connections yet
                      </div>
                    </CommandEmpty>
                    {installNewUrl ? (
                      <>
                        <div className="h-px bg-neutral-200 dark:bg-neutral-800" />
                        <CommandGroup forceMount>
                          <CommandItem
                            value="add-github-account"
                            forceMount
                            onSelect={() => {
                              void handleInstallApp();
                              setConnectionDropdownOpen(false);
                            }}
                            className="flex items-center gap-2"
                          >
                            <GitHubIcon className="h-4 w-4 text-neutral-700 dark:text-neutral-200" />
                            <span>Install GitHub App</span>
                          </CommandItem>
                        </CommandGroup>
                      </>
                    ) : null}
                  </>
                )}
              </CommandList>
            </Command>
          </Popover.Content>
        </Popover.Portal>
      </Popover.Root>

    </div>
  );
}

function RepositoryListSection({
  teamSlugOrId,
  installationId,
  selectedRepos,
  onToggleRepo,
  hasConnections,
}: RepositoryListSectionProps) {
  const [search, setSearch] = useState("");
  const debouncedSearch = useDebouncedValue(search, 300);
  const deferredSearch = useDeferredValue(search);

  const githubReposQuery = useRQ({
    ...getApiIntegrationsGithubReposOptions({
      query: {
        team: teamSlugOrId,
        installationId: installationId ?? undefined,
        search: debouncedSearch.trim() || undefined,
      },
    }),
    enabled: installationId != null,
  });

  const filteredRepos = useMemo(() => {
    const repos = githubReposQuery.data?.repos ?? [];
    const q = deferredSearch.trim().toLowerCase();
    const withTs = repos.map((r) => ({
      ...r,
      _ts: Date.parse(r.pushed_at ?? r.updated_at ?? "") || 0,
    }));
    let list = withTs.sort((a, b) => b._ts - a._ts);
    if (q) {
      list = list.filter(
        (r) =>
          r.full_name.toLowerCase().includes(q) ||
          r.name.toLowerCase().includes(q)
      );
    }
    return list;
  }, [deferredSearch, githubReposQuery.data]);

  const isSearchStale = search.trim() !== debouncedSearch.trim();
  const showReposLoading =
    !!installationId &&
    (githubReposQuery.isPending ||
      isSearchStale ||
      (githubReposQuery.isFetching && filteredRepos.length === 0));
  const showSpinner = isSearchStale || githubReposQuery.isFetching;
  const selectedSet = useMemo(() => new Set(selectedRepos), [selectedRepos]);

  if (!hasConnections) {
    return (
      <div className="rounded-md border border-dashed border-neutral-300 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-900 p-4 text-sm text-neutral-600 dark:text-neutral-300">
        Connect your Git provider above to browse repositories.
      </div>
    );
  }

  if (installationId == null) {
    return (
      <div className="rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 p-4 text-sm text-neutral-600 dark:text-neutral-300">
        Select an organization to see its repositories.
      </div>
    );
  }

  return (
    <div className="space-y-2 mt-4">
      <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
        Repositories
      </label>
      <div className="relative">
        <input
          type="text"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search recent repositories"
          aria-busy={showSpinner}
          className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 pr-8 h-9 text-sm text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
        />
        {showSpinner ? (
          <Loader2 className="absolute right-2 top-1/2 -translate-y-1/2 h-4 w-4 text-neutral-400 animate-spin" />
        ) : null}
      </div>

      <div className="mt-2 rounded-md border border-neutral-200 dark:border-neutral-800 overflow-hidden">
        {showReposLoading ? (
          <div className="divide-y divide-neutral-200 dark:divide-neutral-900">
            {[...Array(5)].map((_, index) => (
              <div
                key={index}
                className="px-3 h-9 flex items-center justify-between bg-white dark:bg-neutral-950"
              >
                <div className="flex items-center gap-2 min-w-0 flex-1">
                  <Skeleton className="h-4 w-4 rounded-sm" />
                  <Skeleton className="h-4 w-56 rounded" />
                </div>
                <div className="flex items-center gap-2">
                  <Skeleton className="h-3 w-16 rounded-full" />
                </div>
              </div>
            ))}
          </div>
        ) : filteredRepos.length > 0 ? (
          <div className="divide-y divide-neutral-200 dark:divide-neutral-900">
            {filteredRepos.map((repo) => {
              const isSelected = selectedSet.has(repo.full_name);
              const last = repo.pushed_at ?? repo.updated_at ?? null;
              const when = last ? formatTimeAgo(last) : "";
              return (
                <div
                  key={repo.full_name}
                  role="option"
                  aria-selected={isSelected}
                  onClick={() => onToggleRepo(repo.full_name)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      onToggleRepo(repo.full_name);
                    }
                  }}
                  tabIndex={0}
                  className="px-3 h-9 flex items-center justify-between bg-white dark:bg-neutral-950 cursor-default select-none outline-none"
                >
                  <div className="text-sm flex items-center gap-2 min-w-0 flex-1">
                    <div
                      className={`mr-1 h-4 w-4 rounded-sm border grid place-items-center shrink-0 ${
                        isSelected
                          ? "border-neutral-700 bg-neutral-800"
                          : "border-neutral-300 dark:border-neutral-700 bg-white dark:bg-neutral-950"
                      }`}
                    >
                      <Check
                        className={`w-3 h-3 text-white transition-opacity ${
                          isSelected ? "opacity-100" : "opacity-0"
                        }`}
                      />
                    </div>
                    <GitHubIcon className="h-4 w-4 shrink-0 text-neutral-700 dark:text-neutral-200" />
                    <span className="truncate">{repo.full_name}</span>
                  </div>
                  {when ? (
                    <span className="ml-3 text-[10px] text-neutral-500 dark:text-neutral-500">
                      {when}
                    </span>
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : (
          <div className="px-3 py-10 h-[180px] text-sm text-neutral-500 dark:text-neutral-400 bg-white dark:bg-neutral-950 flex flex-col items-center justify-center text-center gap-2">
            {search ? (
              <div>No recent repositories match your search.</div>
            ) : (
              <div>No recent repositories found for this connection.</div>
            )}
            <div>Use the connection menu above to refresh GitHub access.</div>
          </div>
        )}
      </div>
    </div>
  );
}
