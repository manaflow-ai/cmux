import { env } from "@/client-env";
import { GitHubIcon } from "@/components/icons/github";
import { NewTaskDialog } from "@/components/task/NewTaskDialog";
import { useTheme } from "@/components/theme/use-theme";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { useOnboardingOptional } from "@/contexts/onboarding/onboarding-context";
import { useSocket } from "@/contexts/socket/use-socket";
import { isElectron } from "@/lib/electron";
import { copyAllElectronLogs } from "@/lib/electron-logs/electron-logs";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { stackClientApp } from "@/lib/stack";
import { preloadTaskRunIframes } from "@/lib/preloadTaskRunIframes";
import {
  rewriteLocalWorkspaceUrlIfNeeded,
  toProxyWorkspaceUrl,
} from "@/lib/toProxyWorkspaceUrl";
import { useLocalVSCodeServeWebQuery } from "@/queries/local-vscode-serve-web";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type {
  CreateLocalWorkspaceResponse,
  CreateCloudWorkspaceResponse,
} from "@cmux/shared";
import { deriveRepoBaseName } from "@cmux/shared";
import { useUser, type Team } from "@stackframe/react";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { useVirtualizer, type Virtualizer } from "@tanstack/react-virtual";
import { Command, useCommandState } from "cmdk";
import { useMutation, useQuery } from "convex/react";
import {
  Bug,
  ClipboardCopy,
  Cloud,
  GitPullRequest,
  GraduationCap,
  Home,
  LogOut,
  Monitor,
  Moon,
  PanelLeftClose,
  Plus,
  RefreshCw,
  ScrollText,
  Server,
  Settings,
  Sun,
  Users,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { toast } from "sonner";
import {
  buildSearchText,
  filterCommandItems,
} from "./command-bar/commandSearch";
import {
  buildScopeKey,
  selectSuggestedItems,
  useSuggestionHistory,
} from "./command-bar/useSuggestionHistory";
import clsx from "clsx";

interface CommandBarProps {
  teamSlugOrId: string;
  stateResetDelayMs?: number;
}

const environmentSearchDefaults = {
  step: undefined,
  selectedRepos: undefined,
  connectionLogin: undefined,
  repoSearch: undefined,
  instanceId: undefined,
  snapshotId: undefined,
} as const;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const extractString = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
};

const compactStrings = (values: ReadonlyArray<unknown>): string[] => {
  const out: string[] = [];
  for (const value of values) {
    const str = extractString(value);
    if (str) out.push(str);
  }
  return out;
};

const EMPTY_TEAM_LIST: Team[] = [];

const isDevEnvironment = import.meta.env.DEV;

const baseCommandItemClassName =
  "flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer hover:bg-neutral-100 dark:hover:bg-neutral-800 data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800 data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100";
const taskCommandItemClassName =
  "flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer hover:bg-neutral-100 dark:hover:bg-neutral-800 data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800 data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100 group";
const placeholderClassName =
  "flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md text-sm text-neutral-500 dark:text-neutral-400";

const COMMAND_LIST_VIRTUALIZATION_THRESHOLD = 40;
const COMMAND_LIST_ESTIMATED_ROW_HEIGHT = 44;
const COMMAND_LIST_VIRTUALIZED_FALLBACK_COUNT = 20;
const COMMAND_PANEL_MAX_HEIGHT_PX = 475; // Keep in sync with container max-h class
const COMMAND_LIST_VERTICAL_MARGIN_PX = 12; // pt-1 (4px) + pb-2 (8px)
const COMMAND_LIST_SCROLL_PADDING_TOP_PX = 4;
const COMMAND_LIST_SCROLL_PADDING_BOTTOM_PX =
  COMMAND_LIST_SCROLL_PADDING_TOP_PX;
const adjustContainerScrollForChild = (
  container: HTMLElement,
  target: HTMLElement
): boolean => {
  const containerRect = container.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();

  const offsetAbove =
    targetRect.top - (containerRect.top + COMMAND_LIST_SCROLL_PADDING_TOP_PX);
  if (offsetAbove < 0) {
    container.scrollTop += offsetAbove;
    return true;
  }

  const offsetBelow =
    targetRect.bottom -
    (containerRect.bottom - COMMAND_LIST_SCROLL_PADDING_BOTTOM_PX);
  if (offsetBelow > 0) {
    container.scrollTop += offsetBelow;
    return true;
  }

  return false;
};

type TeamCommandItem = {
  id: string;
  label: string;
  slug?: string;
  teamSlugOrId: string;
  isCurrent: boolean;
  keywords: string[];
};

type LocalWorkspaceOption = {
  fullName: string;
  repoBaseName: string;
  keywords: string[];
};

type CloudWorkspaceOption =
  | {
      type: "environment";
      environmentId: Id<"environments">;
      name: string;
      keywords: string[];
    }
  | {
      type: "repo";
      fullName: string;
      repoBaseName: string;
      keywords: string[];
    };

type CommandListEntry = {
  value: string;
  label: string;
  keywords?: string[];
  searchText: string;
  renderContent: () => ReactNode;
  execute: () => Promise<void> | void;
  disabled?: boolean;
  className?: string;
  dataValue?: string;
  trackUsage?: boolean;
};

type FocusSnapshot = {
  element: HTMLElement;
  selection?: {
    start: number;
    end: number;
    direction?: "forward" | "backward" | "none";
  };
  contentEditableRange?: {
    startPath: number[];
    startOffset: number;
    endPath: number[];
    endOffset: number;
  };
};

function VirtualizedCommandItems({
  entries,
  virtualizer,
  renderEntry,
  fallbackCount = COMMAND_LIST_VIRTUALIZED_FALLBACK_COUNT,
}: {
  entries: CommandListEntry[];
  virtualizer: Virtualizer<HTMLDivElement, HTMLDivElement>;
  renderEntry: (entry: CommandListEntry) => ReactNode;
  fallbackCount?: number;
}) {
  if (entries.length === 0) {
    return null;
  }

  const virtualizationEnabled = virtualizer.options.enabled !== false;
  const virtualItems = virtualizationEnabled
    ? virtualizer.getVirtualItems()
    : [];

  if (!virtualizationEnabled) {
    return <>{entries.map((entry) => renderEntry(entry))}</>;
  }

  if (virtualItems.length === 0) {
    const fallbackEntries = entries.slice(0, fallbackCount);
    return <>{fallbackEntries.map((entry) => renderEntry(entry))}</>;
  }

  return (
    <div
      style={{
        height: virtualizer.getTotalSize(),
        position: "relative",
      }}
    >
      {virtualItems.map((virtualItem) => {
        const entry = entries[virtualItem.index]!;
        return (
          <div
            key={entry.value}
            data-index={virtualItem.index}
            ref={virtualizer.measureElement}
            style={{
              position: "absolute",
              top: 0,
              left: 0,
              width: "100%",
              transform: `translateY(${virtualItem.start}px)`,
            }}
          >
            {renderEntry(entry)}
          </div>
        );
      })}
    </div>
  );
}

function CommandHighlightListener({
  onHighlight,
}: {
  onHighlight: (value: string) => void;
}) {
  const value = useCommandState((state) => state.value);
  const previousValueRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (!value) {
      previousValueRef.current = undefined;
      return;
    }

    if (previousValueRef.current === value) {
      return;
    }

    previousValueRef.current = value;
    onHighlight(value);
  }, [value, onHighlight]);

  return null;
}

export function CommandBar({
  teamSlugOrId,
  stateResetDelayMs = 30_000,
}: CommandBarProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [openedWithShift, setOpenedWithShift] = useState(false);
  const clearCommandInput = useCallback(() => {
    setSearch("");
  }, [setSearch]);
  const [activePage, setActivePage] = useState<
    "root" | "teams" | "local-workspaces" | "cloud-workspaces"
  >("root");
  const [isCreatingLocalWorkspace, setIsCreatingLocalWorkspace] =
    useState(false);
  const [isCreatingCloudWorkspace, setIsCreatingCloudWorkspace] =
    useState(false);
  const [isNewTaskDialogOpen, setIsNewTaskDialogOpen] = useState(false);
  const [commandValue, setCommandValue] = useState<string | undefined>(
    undefined
  );
  const [commandListMaxHeight, setCommandListMaxHeight] = useState(
    COMMAND_PANEL_MAX_HEIGHT_PX
  );
  const openRef = useRef<boolean>(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const commandContainerRef = useRef<HTMLDivElement | null>(null);
  const commandListRef = useRef<HTMLDivElement | null>(null);
  const previousSearchRef = useRef(search);
  const skipNextCloseRef = useRef(false);
  const stateResetTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(
    null
  );
  // Used only in non-Electron fallback
  const prevFocusSnapshotRef = useRef<FocusSnapshot | null>(null);
  const navigate = useNavigate();
  const router = useRouter();
  const { setTheme, theme } = useTheme();
  const { addTaskToExpand } = useExpandTasks();
  const { socket } = useSocket();
  const onboarding = useOnboardingOptional();
  const localServeWeb = useLocalVSCodeServeWebQuery();
  const preloadTeamDashboard = useCallback(
    async (targetTeamSlugOrId: string | undefined) => {
      if (!targetTeamSlugOrId) return;
      await router.preloadRoute({
        to: "/$teamSlugOrId/dashboard",
        params: { teamSlugOrId: targetTeamSlugOrId },
      });
    },
    [router]
  );
  const updateCommandListMaxHeight = useCallback(() => {
    const inputHeight = inputRef.current?.offsetHeight ?? 0;
    const availableHeight =
      COMMAND_PANEL_MAX_HEIGHT_PX -
      inputHeight -
      COMMAND_LIST_VERTICAL_MARGIN_PX;
    setCommandListMaxHeight((current) => {
      const next = Math.max(0, availableHeight);
      return Math.abs(next - current) < 0.5 ? current : next;
    });
  }, []);

  const captureFocusBeforeOpen = useCallback(() => {
    if (typeof document === "undefined") return;
    const active = document.activeElement;
    if (!(active instanceof HTMLElement)) {
      prevFocusSnapshotRef.current = null;
      return;
    }

    const snapshot: FocusSnapshot = { element: active };
    if (
      active instanceof HTMLInputElement ||
      active instanceof HTMLTextAreaElement
    ) {
      try {
        const { selectionStart, selectionEnd, selectionDirection } = active;
        if (
          typeof selectionStart === "number" &&
          typeof selectionEnd === "number"
        ) {
          snapshot.selection = {
            start: selectionStart,
            end: selectionEnd,
            direction: selectionDirection ?? "none",
          };
        }
      } catch {
        // Ignore selection capture failures (e.g. unsupported input type)
      }
    }

    if (active.isContentEditable) {
      try {
        const selection = window.getSelection();
        if (selection && selection.rangeCount > 0) {
          const range = selection.getRangeAt(0);
          if (
            active.contains(range.startContainer) &&
            active.contains(range.endContainer)
          ) {
            const startPath = buildNodePath(active, range.startContainer);
            const endPath = buildNodePath(active, range.endContainer);
            if (startPath && endPath) {
              snapshot.contentEditableRange = {
                startPath,
                startOffset: range.startOffset,
                endPath,
                endOffset: range.endOffset,
              };
            }
          }
        }
      } catch {
        // ignore contenteditable selection capture failures
      }
    }

    prevFocusSnapshotRef.current = snapshot;
  }, []);

  const clearPendingStateReset = useCallback(() => {
    if (stateResetTimeoutRef.current !== null) {
      clearTimeout(stateResetTimeoutRef.current);
      stateResetTimeoutRef.current = null;
    }
  }, []);

  const resetCommandState = useCallback(() => {
    clearCommandInput();
    setActivePage("root");
    setCommandValue(undefined);
  }, [clearCommandInput]);

  const scheduleCommandStateReset = useCallback(() => {
    if (stateResetDelayMs <= 0) {
      clearPendingStateReset();
      resetCommandState();
      return;
    }

    clearPendingStateReset();
    stateResetTimeoutRef.current = setTimeout(() => {
      stateResetTimeoutRef.current = null;
      if (openRef.current) {
        return;
      }
      resetCommandState();
    }, stateResetDelayMs);
  }, [clearPendingStateReset, resetCommandState, stateResetDelayMs]);

  const closeCommand = useCallback(() => {
    const activeElement = document.activeElement;
    if (
      activeElement instanceof HTMLElement &&
      commandContainerRef.current?.contains(activeElement)
    ) {
      activeElement.blur();
    }
    skipNextCloseRef.current = false;
    setOpen(false);
    setOpenedWithShift(false);
    scheduleCommandStateReset();
  }, [commandContainerRef, scheduleCommandStateReset, setOpen, setOpenedWithShift]);

  const handleEscape = useCallback(() => {
    skipNextCloseRef.current = false;
    if (search.length > 0) {
      skipNextCloseRef.current = true;
      clearCommandInput();
      return;
    }
    if (activePage !== "root") {
      skipNextCloseRef.current = true;
      setActivePage("root");
      return;
    }
    closeCommand();
  }, [activePage, clearCommandInput, closeCommand, search, setActivePage]);

  useEffect(() => {
    if (!open) return;
    clearPendingStateReset();
  }, [open, clearPendingStateReset]);

  useEffect(() => {
    return () => {
      clearPendingStateReset();
    };
  }, [clearPendingStateReset]);
  useLayoutEffect(() => {
    if (!open || typeof window === "undefined") {
      return;
    }
    updateCommandListMaxHeight();
    const handleResize = () => {
      updateCommandListMaxHeight();
    };
    window.addEventListener("resize", handleResize);
    let resizeObserver: ResizeObserver | null = null;
    if (typeof ResizeObserver !== "undefined") {
      const inputElement = inputRef.current;
      if (inputElement) {
        resizeObserver = new ResizeObserver(() => {
          updateCommandListMaxHeight();
        });
        resizeObserver.observe(inputElement);
      }
    }
    return () => {
      window.removeEventListener("resize", handleResize);
      resizeObserver?.disconnect();
    };
  }, [open, updateCommandListMaxHeight]);

  const stackUser = useUser({ or: "return-null" });
  const stackTeams = stackUser?.useTeams() ?? EMPTY_TEAM_LIST;
  const selectedTeamId = stackUser?.selectedTeam?.id ?? null;
  const teamMemberships = useQuery(api.teams.listTeamMemberships, {});
  const reposByOrg = useQuery(api.github.getReposByOrg, { teamSlugOrId });
  const environments = useQuery(api.environments.list, { teamSlugOrId });

  const localWorkspaceOptions = useMemo<LocalWorkspaceOption[]>(() => {
    const repoGroups = reposByOrg ?? {};
    const uniqueRepos = new Map<string, Doc<"repos">>();

    for (const repos of Object.values(repoGroups)) {
      for (const repo of repos ?? []) {
        const existing = uniqueRepos.get(repo.fullName);
        if (!existing) {
          uniqueRepos.set(repo.fullName, repo);
          continue;
        }
        const existingActivity =
          existing.lastPushedAt ?? Number.NEGATIVE_INFINITY;
        const candidateActivity = repo.lastPushedAt ?? Number.NEGATIVE_INFINITY;
        if (candidateActivity > existingActivity) {
          uniqueRepos.set(repo.fullName, repo);
        }
      }
    }

    return Array.from(uniqueRepos.values())
      .sort((a, b) => {
        const aPushedAt = a.lastPushedAt ?? Number.NEGATIVE_INFINITY;
        const bPushedAt = b.lastPushedAt ?? Number.NEGATIVE_INFINITY;
        if (aPushedAt !== bPushedAt) {
          return bPushedAt - aPushedAt;
        }
        return a.fullName.localeCompare(b.fullName);
      })
      .map((repo) => {
        const repoBaseName =
          deriveRepoBaseName({
            projectFullName: repo.fullName,
            repoUrl: repo.gitRemote,
          }) ?? repo.name;
        const [owner, name] = repo.fullName.split("/");
        return {
          fullName: repo.fullName,
          repoBaseName,
          keywords: compactStrings([
            repo.fullName,
            repo.name,
            repo.org,
            repo.ownerLogin,
            owner,
            name,
          ]),
        };
      });
  }, [reposByOrg]);

  const isLocalWorkspaceLoading = reposByOrg === undefined;

  const cloudWorkspaceOptions = useMemo<CloudWorkspaceOption[]>(() => {
    const options: CloudWorkspaceOption[] = [];

    // Add environment-based cloud workspaces
    if (environments) {
      const envOptions: CloudWorkspaceOption[] = environments
        .sort((a, b) => {
          // Sort by creation time, most recent first
          return b.createdAt - a.createdAt;
        })
        .map((env) => ({
          type: "environment",
          environmentId: env._id,
          name: env.name,
          keywords: compactStrings([
            env.name,
            env.description,
            env.morphSnapshotId,
            ...(env.selectedRepos ?? []),
          ]),
        }));
      options.push(...envOptions);
    }

    // Add repo-based cloud workspaces
    const repoOptions: CloudWorkspaceOption[] = localWorkspaceOptions.map(
      (repo) => ({
        type: "repo",
        fullName: repo.fullName,
        repoBaseName: repo.repoBaseName,
        keywords: repo.keywords,
      })
    );
    options.push(...repoOptions);

    return options;
  }, [environments, localWorkspaceOptions]);

  const isCloudWorkspaceLoading =
    environments === undefined || reposByOrg === undefined;

  const getClientSlug = useCallback((meta: unknown): string | undefined => {
    if (!isRecord(meta)) return undefined;
    return extractString(meta["slug"]);
  }, []);

  const teamCommandItems = useMemo(() => {
    const memberships = teamMemberships ?? [];
    const items: TeamCommandItem[] = [];

    for (const team of stackTeams) {
      const membership = memberships.find((entry) => entry.teamId === team.id);

      let membershipTeamSlug: string | undefined;
      let membershipTeamDisplayName: string | undefined;
      let membershipTeamName: string | undefined;

      if (membership && isRecord(membership.team)) {
        const teamRecord = membership.team;
        membershipTeamSlug = extractString(teamRecord["slug"]);
        membershipTeamDisplayName = extractString(teamRecord["displayName"]);
        membershipTeamName = extractString(teamRecord["name"]);
      }

      const slugFromMetadata =
        getClientSlug(team.clientMetadata) ||
        getClientSlug(team.clientReadOnlyMetadata);

      const slug = membershipTeamSlug || slugFromMetadata;
      const label =
        membershipTeamDisplayName ||
        membershipTeamName ||
        extractString(team.displayName) ||
        team.id;

      const teamSlugOrIdTarget = slug ?? team.id;

      items.push({
        id: team.id,
        label,
        slug,
        teamSlugOrId: teamSlugOrIdTarget,
        isCurrent: selectedTeamId === team.id,
        keywords: compactStrings([label, slug]),
      });
    }

    items.sort((a, b) => {
      if (a.isCurrent && !b.isCurrent) return -1;
      if (!a.isCurrent && b.isCurrent) return 1;
      return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
    });

    return items;
  }, [stackTeams, teamMemberships, selectedTeamId, getClientSlug]);

  const teamCommandEntries = useMemo(
    () =>
      teamCommandItems.map((item) => ({
        value: `team:${item.id}:${item.teamSlugOrId}`,
        searchText: buildSearchText(item.label, item.keywords, [
          item.slug,
          item.isCurrent ? "current" : undefined,
        ]),
        item,
      })),
    [teamCommandItems]
  );

  const isTeamsLoading = Boolean(stackUser) && teamMemberships === undefined;
  const teamPageEmptyMessage = stackUser
    ? "No teams available yet."
    : "Sign in to view teams.";

  const allTasks = useQuery(api.tasks.getTasksWithTaskRuns, { teamSlugOrId });
  const reserveLocalWorkspace = useMutation(api.localWorkspaces.reserve);
  const createTask = useMutation(api.tasks.create);
  const failTaskRun = useMutation(api.taskRuns.fail);

  useEffect(() => {
    openRef.current = open;
  }, [open]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    if (open) {
      document.body.dataset.cmuxCommandPaletteOpen = "true";
    } else {
      delete document.body.dataset.cmuxCommandPaletteOpen;
    }
    return () => {
      delete document.body.dataset.cmuxCommandPaletteOpen;
    };
  }, [open]);

  const createLocalWorkspace = useCallback(
    async (projectFullName: string) => {
      if (isCreatingLocalWorkspace) {
        return;
      }
      if (!socket) {
        console.warn(
          "Socket is not connected yet. Please try again momentarily."
        );
        return;
      }

      setIsCreatingLocalWorkspace(true);
      let reservedTaskId: Id<"tasks"> | null = null;
      let reservedTaskRunId: Id<"taskRuns"> | null = null;

      try {
        const repoUrl = `https://github.com/${projectFullName}.git`;
        const reservation = await reserveLocalWorkspace({
          teamSlugOrId,
          projectFullName,
          repoUrl,
        });
        if (!reservation) {
          throw new Error("Unable to reserve workspace name");
        }

        reservedTaskId = reservation.taskId;
        reservedTaskRunId = reservation.taskRunId;

        addTaskToExpand(reservation.taskId);

        await new Promise<void>((resolve) => {
          socket.emit(
            "create-local-workspace",
            {
              teamSlugOrId,
              projectFullName,
              repoUrl,
              taskId: reservation.taskId,
              taskRunId: reservation.taskRunId,
              workspaceName: reservation.workspaceName,
              descriptor: reservation.descriptor,
            },
            async (response: CreateLocalWorkspaceResponse) => {
              try {
                if (!response?.success) {
                  const message =
                    response?.error ??
                    `Unable to create workspace for ${projectFullName}`;
                  if (reservedTaskRunId) {
                    await failTaskRun({
                      teamSlugOrId,
                      id: reservedTaskRunId,
                      errorMessage: message,
                    }).catch(() => undefined);
                  }
                  console.error(message);
                  return;
                }

                const effectiveTaskId = response.taskId ?? reservedTaskId;
                const effectiveTaskRunId =
                  response.taskRunId ?? reservedTaskRunId;
                const effectiveWorkspaceName =
                  response.workspaceName ??
                  reservation.workspaceName ??
                  projectFullName;

                console.log(
                  response.pending
                    ? `${effectiveWorkspaceName} is provisioning…`
                    : `${effectiveWorkspaceName} is ready`
                );

                const normalizedWorkspaceUrl = response.workspaceUrl
                  ? rewriteLocalWorkspaceUrlIfNeeded(
                      response.workspaceUrl,
                      localServeWeb.data?.baseUrl
                    )
                  : null;

                if (response.workspaceUrl && effectiveTaskRunId) {
                  const proxiedUrl = toProxyWorkspaceUrl(
                    response.workspaceUrl,
                    localServeWeb.data?.baseUrl
                  );
                  if (proxiedUrl) {
                    void preloadTaskRunIframes([
                      { url: proxiedUrl, taskRunId: effectiveTaskRunId },
                    ]).catch(() => undefined);
                  }
                }

                if (effectiveTaskId && effectiveTaskRunId) {
                  void router
                    .preloadRoute({
                      to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                      params: {
                        teamSlugOrId,
                        taskId: effectiveTaskId,
                        runId: effectiveTaskRunId,
                      },
                    })
                    .catch(() => undefined);
                  void navigate({
                    to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                    params: {
                      teamSlugOrId,
                      taskId: effectiveTaskId,
                      runId: effectiveTaskRunId,
                    },
                  });
                } else if (normalizedWorkspaceUrl) {
                  window.location.assign(normalizedWorkspaceUrl);
                }
              } catch (callbackError) {
                const message =
                  callbackError instanceof Error
                    ? callbackError.message
                    : String(callbackError ?? "Unknown");
                console.error("Failed to create workspace", message);
              } finally {
                resolve();
              }
            }
          );
        });
      } catch (error) {
        const message =
          error instanceof Error ? error.message : String(error ?? "Unknown");
        if (reservedTaskRunId) {
          await failTaskRun({
            teamSlugOrId,
            id: reservedTaskRunId,
            errorMessage: message,
          }).catch(() => undefined);
        }
        console.error("Failed to create workspace", message);
      } finally {
        setIsCreatingLocalWorkspace(false);
      }
    },
    [
      addTaskToExpand,
      failTaskRun,
      isCreatingLocalWorkspace,
      localServeWeb.data?.baseUrl,
      navigate,
      reserveLocalWorkspace,
      router,
      socket,
      teamSlugOrId,
    ]
  );

  const handleLocalWorkspaceSelect = useCallback(
    (projectFullName: string) => {
      clearCommandInput();
      closeCommand();
      void createLocalWorkspace(projectFullName);
    },
    [clearCommandInput, closeCommand, createLocalWorkspace]
  );

  const createCloudWorkspaceFromEnvironment = useCallback(
    async (environmentId: Id<"environments">) => {
      if (isCreatingCloudWorkspace) {
        return;
      }
      if (!socket) {
        console.warn(
          "Socket is not connected yet. Please try again momentarily."
        );
        return;
      }

      setIsCreatingCloudWorkspace(true);

      try {
        // Find environment name for the task text
        const environment = environments?.find(
          (env) => env._id === environmentId
        );
        const environmentName = environment?.name ?? "Unknown Environment";

        // Create task in Convex without task description (it's just a workspace)
        const { taskId } = await createTask({
          teamSlugOrId,
          text: environmentName,
          projectFullName: undefined, // No repo for cloud environment workspaces
          baseBranch: undefined, // No branch for environments
          environmentId,
          isCloudWorkspace: true,
        });

        // Hint the sidebar to auto-expand this task once it appears
        addTaskToExpand(taskId);

        await new Promise<void>((resolve) => {
          socket.emit(
            "create-cloud-workspace",
            {
              teamSlugOrId,
              environmentId,
              taskId,
              theme,
            },
            async (response: CreateCloudWorkspaceResponse) => {
              try {
                if (response.success) {
                  toast.success("Cloud workspace created successfully");
                } else {
                  toast.error(
                    response.error || "Failed to create cloud workspace"
                  );
                }
              } catch (callbackError) {
                const message =
                  callbackError instanceof Error
                    ? callbackError.message
                    : String(callbackError ?? "Unknown");
                console.error("Failed to create cloud workspace", message);
              } finally {
                resolve();
              }
            }
          );
        });

        console.log("Cloud workspace created:", taskId);
      } catch (error) {
        console.error("Error creating cloud workspace:", error);
        toast.error("Failed to create cloud workspace");
      } finally {
        setIsCreatingCloudWorkspace(false);
      }
    },
    [
      addTaskToExpand,
      createTask,
      environments,
      isCreatingCloudWorkspace,
      socket,
      teamSlugOrId,
      theme,
    ]
  );

  const createCloudWorkspaceFromRepo = useCallback(
    async (projectFullName: string) => {
      if (isCreatingCloudWorkspace) {
        return;
      }
      if (!socket) {
        console.warn(
          "Socket is not connected yet. Please try again momentarily."
        );
        return;
      }

      setIsCreatingCloudWorkspace(true);

      try {
        const repoUrl = `https://github.com/${projectFullName}.git`;

        // Create task in Convex for repo-based cloud workspace
        const { taskId } = await createTask({
          teamSlugOrId,
          text: projectFullName,
          projectFullName,
          baseBranch: undefined,
          environmentId: undefined, // No environment for repo-based cloud workspaces
          isCloudWorkspace: true,
        });

        // Hint the sidebar to auto-expand this task once it appears
        addTaskToExpand(taskId);

        await new Promise<void>((resolve) => {
          socket.emit(
            "create-cloud-workspace",
            {
              teamSlugOrId,
              projectFullName,
              repoUrl,
              taskId,
              theme,
            },
            async (response: CreateCloudWorkspaceResponse) => {
              try {
                if (response.success) {
                  toast.success("Cloud workspace created successfully");
                } else {
                  toast.error(
                    response.error || "Failed to create cloud workspace"
                  );
                }
              } catch (callbackError) {
                const message =
                  callbackError instanceof Error
                    ? callbackError.message
                    : String(callbackError ?? "Unknown");
                console.error("Failed to create cloud workspace", message);
              } finally {
                resolve();
              }
            }
          );
        });

        console.log("Cloud workspace created:", taskId);
      } catch (error) {
        console.error("Error creating cloud workspace:", error);
        toast.error("Failed to create cloud workspace");
      } finally {
        setIsCreatingCloudWorkspace(false);
      }
    },
    [
      addTaskToExpand,
      createTask,
      isCreatingCloudWorkspace,
      socket,
      teamSlugOrId,
      theme,
    ]
  );

  const handleCloudWorkspaceSelect = useCallback(
    (option: CloudWorkspaceOption) => {
      clearCommandInput();
      closeCommand();
      if (option.type === "environment") {
        void createCloudWorkspaceFromEnvironment(option.environmentId);
      } else {
        void createCloudWorkspaceFromRepo(option.fullName);
      }
    },
    [
      clearCommandInput,
      closeCommand,
      createCloudWorkspaceFromEnvironment,
      createCloudWorkspaceFromRepo,
    ]
  );

  useEffect(() => {
    // In Electron, prefer global shortcut from main via cmux event.
    if (isElectron) {
      const off = window.cmux.on("shortcut:cmd-k", () => {
        // Only handle Cmd+K (no shift/ctrl variations)
        if (openRef.current) {
          closeCommand();
          return;
        }
        setOpenedWithShift(false);
        captureFocusBeforeOpen();
        setOpen(true);
      });
      return () => {
        // Unsubscribe if available
        if (typeof off === "function") off();
      };
    }

    // Web/non-Electron fallback: local keydown listener for Cmd+K
    const down = (e: KeyboardEvent) => {
      // Only trigger on EXACT Cmd+K (no Shift/Alt/Ctrl)
      if (
        e.key.toLowerCase() === "k" &&
        e.metaKey &&
        !e.shiftKey &&
        !e.altKey &&
        !e.ctrlKey
      ) {
        e.preventDefault();
        if (openRef.current) {
          closeCommand();
          return;
        }
        setOpenedWithShift(false);
        captureFocusBeforeOpen();
        setOpen(true);
      }
    };
    document.addEventListener("keydown", down);
    return () => document.removeEventListener("keydown", down);
  }, [captureFocusBeforeOpen, closeCommand]);

  // Listen for custom event to open command bar with a specific page
  useEffect(() => {
    type CommandBarPage = "root" | "teams" | "local-workspaces" | "cloud-workspaces";
    const validPages: CommandBarPage[] = ["root", "teams", "local-workspaces", "cloud-workspaces"];

    const handleOpenWithPage = (e: Event) => {
      const customEvent = e as CustomEvent<{ page: string }>;
      const page = customEvent.detail?.page;
      if (page && validPages.includes(page as CommandBarPage)) {
        captureFocusBeforeOpen();
        setActivePage(page as CommandBarPage);
        setOpen(true);
      }
    };
    window.addEventListener("cmux:open-command-bar", handleOpenWithPage);
    return () => {
      window.removeEventListener("cmux:open-command-bar", handleOpenWithPage);
    };
  }, [captureFocusBeforeOpen, setActivePage]);

  // Track and restore focus across open/close, including iframes/webviews.
  useEffect(() => {
    // Inform Electron main about palette open state to gate focus capture
    if (isElectron && window.cmux?.ui?.setCommandPaletteOpen) {
      void window.cmux.ui.setCommandPaletteOpen(open);
    }

    if (!open) {
      const snapshot = prevFocusSnapshotRef.current;
      if (
        isElectron &&
        !snapshot?.contentEditableRange &&
        window.cmux?.ui?.restoreLastFocus
      ) {
        prevFocusSnapshotRef.current = null;
        void window.cmux.ui.restoreLastFocus();
      } else if (snapshot) {
        const { element, selection, contentEditableRange } = snapshot;
        const id = window.setTimeout(() => {
          try {
            element.focus({ preventScroll: true });
            if (
              selection &&
              (element instanceof HTMLInputElement ||
                element instanceof HTMLTextAreaElement) &&
              typeof element.setSelectionRange === "function"
            ) {
              try {
                element.setSelectionRange(
                  selection.start,
                  selection.end,
                  selection.direction
                );
              } catch (error) {
                console.error("Failed to restore selection", error);
              }
            } else if (contentEditableRange && element.isContentEditable) {
              try {
                const selectionObj = window.getSelection();
                if (selectionObj) {
                  const startNode = resolveNodePath(
                    element,
                    contentEditableRange.startPath
                  );
                  const endNode = resolveNodePath(
                    element,
                    contentEditableRange.endPath
                  );
                  if (startNode && endNode) {
                    const newRange = document.createRange();
                    const clampOffset = (node: Node, offset: number) => {
                      if (
                        node.nodeType === Node.TEXT_NODE &&
                        typeof node.textContent === "string"
                      ) {
                        return Math.min(
                          Math.max(offset, 0),
                          node.textContent.length
                        );
                      }
                      if (node.childNodes.length > 0) {
                        return Math.min(
                          Math.max(offset, 0),
                          node.childNodes.length
                        );
                      }
                      return Math.max(offset, 0);
                    };
                    newRange.setStart(
                      startNode,
                      clampOffset(startNode, contentEditableRange.startOffset)
                    );
                    newRange.setEnd(
                      endNode,
                      clampOffset(endNode, contentEditableRange.endOffset)
                    );
                    selectionObj.removeAllRanges();
                    selectionObj.addRange(newRange);
                  }
                }
              } catch (error) {
                console.error("Failed to restore contenteditable range", error);
              }
            } else if (element.tagName === "IFRAME") {
              try {
                (element as HTMLIFrameElement).contentWindow?.focus?.();
              } catch {
                // ignore iframe focus errors
              }
            }
            if (prevFocusSnapshotRef.current === snapshot) {
              prevFocusSnapshotRef.current = null;
            }
          } catch (error) {
            console.error("Failed to restore focus", error);
          }
        }, 0);
        return () => {
          window.clearTimeout(id);
          if (prevFocusSnapshotRef.current === snapshot) {
            prevFocusSnapshotRef.current = null;
          }
        };
      }
    }
    return undefined;
  }, [open]);

  useEffect(() => {
    if (!open || !openedWithShift) return;
    setCommandValue("new-task");
  }, [open, openedWithShift]);

  useEffect(() => {
    if (!open) return;
    if (typeof window === "undefined") return;
    const id = window.setTimeout(() => {
      inputRef.current?.focus({ preventScroll: true });
    }, 0);
    return () => window.clearTimeout(id);
  }, [open]);

  const handleHighlight = useCallback(
    async (value: string) => {
      if (value === "logs:view") {
        try {
          await router.preloadRoute({
            to: "/$teamSlugOrId/logs",
            params: { teamSlugOrId },
          });
        } catch {
          // ignore preload errors
        }
      } else if (value === "home") {
        try {
          await router.preloadRoute({
            to: "/$teamSlugOrId/dashboard",
            params: { teamSlugOrId },
          });
        } catch {
          // ignore preload errors
        }
      } else if (value === "environments") {
        try {
          await router.preloadRoute({
            to: "/$teamSlugOrId/environments",
            params: { teamSlugOrId },
            search: { ...environmentSearchDefaults },
          });
        } catch {
          // ignore preload errors
        }
      } else if (value === "settings") {
        try {
          await router.preloadRoute({
            to: "/$teamSlugOrId/settings",
            params: { teamSlugOrId },
          });
        } catch {
          // ignore preload errors
        }
      } else if (value === "dev:webcontents") {
        try {
          await router.preloadRoute({
            to: "/debug-webcontents",
          });
        } catch {
          // ignore preload errors
        }
      } else if (value?.startsWith("team:")) {
        const [teamIdPart, slugPart] = value.slice(5).split(":");
        const targetTeamSlugOrId = slugPart || teamIdPart;
        await preloadTeamDashboard(targetTeamSlugOrId);
      } else if (value?.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0] as Id<"tasks">;
        const action = parts[1];
        const task = allTasks?.find((t) => t._id === taskId);
        const runId = task?.selectedTaskRun?._id;

        try {
          if (!action) {
            // Preload main task route
            await router.preloadRoute({
              to: "/$teamSlugOrId/task/$taskId",
              params: { teamSlugOrId, taskId },
              search: { runId: undefined },
            });
          } else if (action === "vs") {
            if (runId) {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId/run/$runId",
                params: {
                  teamSlugOrId,
                  taskId,
                  runId,
                  taskRunId: runId,
                },
              });
            } else {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId",
                params: { teamSlugOrId, taskId },
                search: { runId: undefined },
              });
            }
          } else if (action === "gitdiff") {
            if (runId) {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
                params: { teamSlugOrId, taskId, runId },
              });
            } else {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId",
                params: { teamSlugOrId, taskId },
                search: { runId: undefined },
              });
            }
          }
        } catch {
          // Silently fail preloading
        }
      }
    },
    [router, teamSlugOrId, allTasks, preloadTeamDashboard]
  );

  const handleSelect = useCallback(
    async (value: string) => {
      clearCommandInput();
      if (value === "teams:switch") {
        setActivePage("teams");
        return;
      } else if (value === "new-task") {
        setIsNewTaskDialogOpen(true);
      } else if (value === "local-workspaces") {
        setActivePage("local-workspaces");
        return;
      } else if (value === "cloud-workspaces") {
        setActivePage("cloud-workspaces");
        return;
      } else if (value === "pull-requests") {
        navigate({
          to: "/$teamSlugOrId/prs",
          params: { teamSlugOrId },
        });
      } else if (value === "logs:view") {
        navigate({ to: "/$teamSlugOrId/logs", params: { teamSlugOrId } });
      } else if (value === "logs:copy") {
        try {
          const ok = await copyAllElectronLogs();
          if (ok) {
            toast.success("Copied logs to clipboard");
          } else {
            toast.error("Unable to copy logs");
          }
        } catch {
          toast.error("Unable to copy logs");
        }
      } else if (value === "updates:check") {
        if (!isElectron) {
          toast.error("Update checks are only available in the desktop app.");
        } else {
          try {
            const cmux =
              typeof window === "undefined" ? undefined : window.cmux;
            if (!cmux?.autoUpdate?.check) {
              toast.error("Update checks are currently unavailable.");
            } else {
              const result = await cmux.autoUpdate.check();

              if (!result?.ok) {
                if (result?.reason === "not-packaged") {
                  toast.info("Updates are only available in packaged builds.");
                } else {
                  toast.error("Failed to check for updates.");
                }
              } else if (result.updateAvailable) {
                const versionLabel = result.version
                  ? ` (${result.version})`
                  : "";
                toast.success(
                  `Update available${versionLabel}. Downloading in the background.`
                );
              } else {
                toast.info("You're up to date.");
              }
            }
          } catch (error) {
            console.error("Update check failed", error);
            toast.error("Failed to check for updates.");
          }
        }
      } else if (value === "sign-out") {
        closeCommand();
        try {
          if (stackUser) {
            await stackUser.signOut({
              redirectUrl: stackClientApp.urls.afterSignOut,
            });
          } else {
            await stackClientApp.redirectToSignOut({ replace: true });
          }
        } catch (error) {
          console.error("Sign out failed", error);
          toast.error("Unable to sign out");
        }
        return;
      } else if (value === "theme-light") {
        setTheme("light");
      } else if (value === "theme-dark") {
        setTheme("dark");
      } else if (value === "theme-system") {
        setTheme("system");
      } else if (value === "onboarding:start") {
        if (onboarding) {
          onboarding.resetOnboarding();
          try {
            await navigate({
              to: "/$teamSlugOrId/dashboard",
              params: { teamSlugOrId },
            });
          } catch (error) {
            console.error(
              "Failed to navigate to dashboard for onboarding:",
              error
            );
            return;
          }
          await new Promise<void>((resolve) => {
            setTimeout(resolve, 100);
          });
          onboarding.startOnboarding();
        }
      } else if (value === "sidebar-toggle") {
        const currentHidden = localStorage.getItem("sidebarHidden") === "true";
        localStorage.setItem("sidebarHidden", String(!currentHidden));
        window.dispatchEvent(
          new StorageEvent("storage", {
            key: "sidebarHidden",
            newValue: String(!currentHidden),
            oldValue: String(currentHidden),
            storageArea: localStorage,
            url: window.location.href,
          })
        );
      } else if (value === "home") {
        navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId },
        });
      } else if (value === "environments") {
        navigate({
          to: "/$teamSlugOrId/environments",
          params: { teamSlugOrId },
          search: { ...environmentSearchDefaults },
        });
      } else if (value === "settings") {
        navigate({
          to: "/$teamSlugOrId/settings",
          params: { teamSlugOrId },
        });
      } else if (value === "dev:webcontents") {
        navigate({ to: "/debug-webcontents" });
      } else if (value.startsWith("team:")) {
        const [teamId, slugPart] = value.slice(5).split(":");
        const targetTeamSlugOrId = slugPart || teamId;
        if (!teamId || !targetTeamSlugOrId) {
          toast.error("Unable to switch teams right now.");
          return;
        }

        try {
          const targetTeam =
            stackTeams.find((team) => team.id === teamId) ?? null;
          if (
            stackUser &&
            targetTeam &&
            stackUser.selectedTeam?.id !== teamId
          ) {
            navigate({
              to: "/$teamSlugOrId/dashboard",
              params: { teamSlugOrId: targetTeamSlugOrId },
            });
          }
        } catch (error) {
          console.error("Failed to set selected team", error);
          toast.error("Unable to select that team");
          return;
        }

        setLastTeamSlugOrId(targetTeamSlugOrId);
        navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId: targetTeamSlugOrId },
        });
      } else if (value.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0] as Id<"tasks">;
        const action = parts[1];
        const task = allTasks?.find((t) => t._id === taskId);
        const runId = task?.selectedTaskRun?._id;

        if (!action) {
          navigate({
            to: "/$teamSlugOrId/task/$taskId",
            params: { teamSlugOrId, taskId },
            search: { runId: undefined },
          });
        } else if (action === "vs") {
          if (runId) {
            navigate({
              to: "/$teamSlugOrId/task/$taskId/run/$runId",
              params: {
                teamSlugOrId,
                taskId,
                runId,
                taskRunId: runId,
              },
            });
          } else {
            navigate({
              to: "/$teamSlugOrId/task/$taskId",
              params: { teamSlugOrId, taskId },
              search: { runId: undefined },
            });
          }
        } else if (action === "gitdiff") {
          if (runId) {
            navigate({
              to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
              params: {
                teamSlugOrId,
                taskId,
                runId,
              },
            });
          } else {
            navigate({
              to: "/$teamSlugOrId/task/$taskId",
              params: { teamSlugOrId, taskId },
              search: { runId: undefined },
            });
          }
        }
      }
      closeCommand();
    },
    [
      clearCommandInput,
      navigate,
      teamSlugOrId,
      setTheme,
      allTasks,
      stackUser,
      stackTeams,
      closeCommand,
      onboarding,
    ]
  );

  const rootCommandEntries = useMemo<CommandListEntry[]>(() => {
    const baseEntries: CommandListEntry[] = [
      {
        value: "new-task",
        label: "New Task",
        keywords: ["task", "create", "new"],
        searchText: buildSearchText(
          "New Task",
          ["task", "create"],
          ["new-task"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("new-task"),
        renderContent: () => (
          <>
            <Plus className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">New Task</span>
          </>
        ),
      },
      ...(!env.NEXT_PUBLIC_WEB_MODE
        ? [
            {
              value: "local-workspaces",
              label: "New Local Workspace",
              keywords: ["workspace", "local", "repo"],
              searchText: buildSearchText(
                "New Local Workspace",
                ["workspace", "local"],
                ["local-workspaces"]
              ),
              className: baseCommandItemClassName,
              execute: () => handleSelect("local-workspaces"),
              renderContent: () => (
                <>
                  <Monitor className="h-4 w-4 text-neutral-500" />
                  <span className="text-sm">New Local Workspace</span>
                </>
              ),
            },
          ]
        : []),
      {
        value: "cloud-workspaces",
        label: "New Cloud Workspace",
        keywords: ["workspace", "cloud", "environment", "env"],
        searchText: buildSearchText(
          "New Cloud Workspace",
          ["workspace", "cloud", "environment"],
          ["cloud-workspaces"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("cloud-workspaces"),
        renderContent: () => (
          <>
            <Cloud className="h-4.5 w-4.5 text-neutral-500" />
            <span className="text-sm">New Cloud Workspace</span>
          </>
        ),
      },
      {
        value: "pull-requests",
        label: "Pull Requests",
        keywords: ["pull request", "prs", "pr"],
        searchText: buildSearchText(
          "Pull Requests",
          ["pull request", "prs"],
          ["pull-requests"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("pull-requests"),
        renderContent: () => (
          <>
            <GitPullRequest className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Pull Requests</span>
          </>
        ),
      },
      ...(isDevEnvironment
        ? [
            {
              value: "dev:webcontents",
              label: "Debug WebContents",
              keywords: ["debug", "devtools", "electron"],
              searchText: buildSearchText(
                "Debug WebContents",
                ["debug", "electron"],
                ["dev:webcontents"]
              ),
              className: baseCommandItemClassName,
              execute: () => handleSelect("dev:webcontents"),
              renderContent: () => (
                <>
                  <Bug className="h-4 w-4 text-neutral-500" />
                  <span className="text-sm">Debug WebContents</span>
                </>
              ),
            },
          ]
        : []),
      {
        value: "home",
        label: "Home",
        keywords: ["dashboard", "home"],
        searchText: buildSearchText("Home", ["dashboard"], ["home"]),
        className: baseCommandItemClassName,
        execute: () => handleSelect("home"),
        renderContent: () => (
          <>
            <Home className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Home</span>
          </>
        ),
      },
      {
        value: "environments",
        label: "Environments",
        keywords: ["environment", "env", "servers"],
        searchText: buildSearchText(
          "Environments",
          ["environment"],
          ["environments"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("environments"),
        renderContent: () => (
          <>
            <Server className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Environments</span>
          </>
        ),
      },
      {
        value: "settings",
        label: "Settings",
        keywords: ["preferences", "config"],
        searchText: buildSearchText("Settings", ["preferences"], ["settings"]),
        className: baseCommandItemClassName,
        execute: () => handleSelect("settings"),
        renderContent: () => (
          <>
            <Settings className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Settings</span>
          </>
        ),
      },
      {
        value: "teams:switch",
        label: "Switch team",
        keywords: ["team", "switch", "change"],
        searchText: buildSearchText(
          "Switch team",
          ["team", "switch"],
          ["teams:switch"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("teams:switch"),
        renderContent: () => (
          <>
            <Users className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Switch team</span>
          </>
        ),
      },
      {
        value: "sidebar-toggle",
        label: "Toggle Sidebar",
        keywords: ["sidebar", "hide", "show", "panel"],
        searchText: buildSearchText(
          "Toggle Sidebar",
          ["sidebar", "toggle"],
          ["sidebar-toggle"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("sidebar-toggle"),
        renderContent: () => (
          <>
            <PanelLeftClose className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Toggle Sidebar</span>
          </>
        ),
      },
      {
        value: "theme-light",
        label: "Light Mode",
        keywords: ["theme", "light"],
        searchText: buildSearchText(
          "Light Mode",
          ["theme", "light"],
          ["theme-light"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("theme-light"),
        renderContent: () => (
          <>
            <Sun className="h-4 w-4 text-amber-500" />
            <span className="text-sm">Light Mode</span>
          </>
        ),
      },
      {
        value: "theme-dark",
        label: "Dark Mode",
        keywords: ["theme", "dark"],
        searchText: buildSearchText(
          "Dark Mode",
          ["theme", "dark"],
          ["theme-dark"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("theme-dark"),
        renderContent: () => (
          <>
            <Moon className="h-4 w-4 text-blue-500" />
            <span className="text-sm">Dark Mode</span>
          </>
        ),
      },
      {
        value: "theme-system",
        label: "System Theme",
        keywords: ["theme", "system", "auto"],
        searchText: buildSearchText(
          "System Theme",
          ["theme", "system"],
          ["theme-system"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("theme-system"),
        renderContent: () => (
          <>
            <Monitor className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">System Theme</span>
          </>
        ),
      },
      {
        value: "onboarding:start",
        label: "Start Onboarding Tour",
        keywords: ["onboarding", "tour", "tutorial", "guide", "help", "intro"],
        searchText: buildSearchText(
          "Start Onboarding Tour",
          ["onboarding", "tour", "tutorial", "guide"],
          ["onboarding:start"]
        ),
        className: baseCommandItemClassName,
        execute: () => handleSelect("onboarding:start"),
        renderContent: () => (
          <>
            <GraduationCap className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">Start Onboarding Tour</span>
          </>
        ),
      },
      ...(stackUser
        ? [
            {
              value: "sign-out",
              label: "Sign out",
              keywords: ["logout", "sign out", "account"],
              searchText: buildSearchText(
                "Sign out",
                ["logout", "account"],
                ["sign-out"]
              ),
              className: baseCommandItemClassName,
              execute: () => handleSelect("sign-out"),
              renderContent: () => (
                <>
                  <LogOut className="h-4 w-4 text-neutral-500" />
                  <span className="text-sm">Sign out</span>
                </>
              ),
            },
          ]
        : []),
    ];

    const taskEntries =
      allTasks && allTasks.length > 0
        ? allTasks.slice(0, 9).flatMap<CommandListEntry>((task, index) => {
            const title =
              task.pullRequestTitle || task.text || `Task ${index + 1}`;
            const keywords = compactStrings([
              title,
              task.text,
              task.pullRequestTitle,
              `task ${index + 1}`,
            ]);
            const baseSearch = buildSearchText(title, keywords, [
              `${index + 1}`,
            ]);
            const statusLabel = task.isCompleted ? "completed" : "in progress";
            const statusClassName = task.isCompleted
              ? "text-xs px-2 py-0.5 rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400"
              : "text-xs px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400";
            const run = task.selectedTaskRun;

            const entriesForTask: CommandListEntry[] = [
              {
                value: `${index + 1}:task:${task._id}`,
                label: title,
                keywords,
                searchText: baseSearch,
                className: taskCommandItemClassName,
                execute: () => handleSelect(`task:${task._id}`),
                renderContent: () => (
                  <>
                    <span className="flex h-5 w-5 items-center justify-center rounded text-xs font-semibold bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300 group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600">
                      {index + 1}
                    </span>
                    <span className="flex-1 truncate text-sm">{title}</span>
                    <span className={statusClassName}>{statusLabel}</span>
                  </>
                ),
              },
            ];

            if (run) {
              const vsKeywords = [...keywords, "vs", "vscode"];
              entriesForTask.push({
                value: `${index + 1} vs:task:${task._id}`,
                label: `${title} (VS)`,
                keywords: vsKeywords,
                searchText: buildSearchText(`${title} VS`, vsKeywords, [
                  `${index + 1} vs`,
                  `${index + 1}vs`,
                  `${index + 1}v`,
                ]),
                className: taskCommandItemClassName,
                execute: () => handleSelect(`task:${task._id}:vs`),
                renderContent: () => (
                  <>
                    <span className="flex h-5 w-8 items-center justify-center rounded text-xs font-semibold bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300 group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600">
                      {index + 1} VS
                    </span>
                    <span className="flex-1 truncate text-sm">{title}</span>
                    <span className={statusClassName}>{statusLabel}</span>
                  </>
                ),
              });

              const diffKeywords = [...keywords, "git", "diff"];
              entriesForTask.push({
                value: `${index + 1} git diff:task:${task._id}`,
                label: `${title} (git diff)`,
                keywords: diffKeywords,
                searchText: buildSearchText(`${title} git diff`, diffKeywords, [
                  `${index + 1} git diff`,
                  `${index + 1}gitdiff`,
                  `${index + 1}gd`,
                ]),
                className: taskCommandItemClassName,
                execute: () => handleSelect(`task:${task._id}:gitdiff`),
                renderContent: () => (
                  <>
                    <span className="flex h-5 px-2 items-center justify-center rounded text-xs font-semibold bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300 group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600">
                      {index + 1} git diff
                    </span>
                    <span className="flex-1 truncate text-sm">{title}</span>
                    <span className={statusClassName}>{statusLabel}</span>
                  </>
                ),
              });
            }

            return entriesForTask;
          })
        : [];

    const electronEntries = isElectron
      ? [
          {
            value: "updates:check",
            label: "Check for Updates",
            keywords: ["update", "version", "desktop"],
            searchText: buildSearchText(
              "Check for Updates",
              ["update", "desktop"],
              ["updates:check"]
            ),
            className: baseCommandItemClassName,
            execute: () => handleSelect("updates:check"),
            renderContent: () => (
              <>
                <RefreshCw className="h-4 w-4 text-neutral-500" />
                <span className="text-sm">Check for Updates</span>
              </>
            ),
          },
          {
            value: "logs:view",
            label: "Logs: View",
            keywords: ["logs", "view", "desktop"],
            searchText: buildSearchText(
              "Logs View",
              ["logs", "view"],
              ["logs:view"]
            ),
            className: baseCommandItemClassName,
            execute: () => handleSelect("logs:view"),
            renderContent: () => (
              <>
                <ScrollText className="h-4 w-4 text-blue-500" />
                <span className="text-sm">Logs: View</span>
              </>
            ),
          },
          {
            value: "logs:copy",
            label: "Logs: Copy all",
            keywords: ["logs", "copy"],
            searchText: buildSearchText(
              "Logs Copy",
              ["logs", "copy"],
              ["logs:copy"]
            ),
            className: baseCommandItemClassName,
            execute: () => handleSelect("logs:copy"),
            renderContent: () => (
              <>
                <ClipboardCopy className="h-4 w-4 text-violet-500" />
                <span className="text-sm">Logs: Copy all</span>
              </>
            ),
          },
        ]
      : [];

    return [...baseEntries, ...taskEntries, ...electronEntries];
  }, [allTasks, handleSelect, stackUser]);

  const localWorkspaceEntries = useMemo<CommandListEntry[]>(() => {
    return localWorkspaceOptions.map((option) => {
      const value = `local-workspace:${option.fullName}`;
      return {
        value,
        label: option.fullName,
        keywords: option.keywords,
        searchText: buildSearchText(option.fullName, option.keywords, [
          option.repoBaseName,
        ]),
        className: baseCommandItemClassName,
        disabled: isCreatingLocalWorkspace,
        execute: () => handleLocalWorkspaceSelect(option.fullName),
        renderContent: () => (
          <>
            <GitHubIcon className="h-4 w-4 text-neutral-500" />
            <div className="flex min-w-0 flex-1 flex-col">
              <span className="truncate text-sm">{option.fullName}</span>
            </div>
          </>
        ),
      };
    });
  }, [
    handleLocalWorkspaceSelect,
    isCreatingLocalWorkspace,
    localWorkspaceOptions,
  ]);

  const cloudWorkspaceEntries = useMemo<CommandListEntry[]>(() => {
    return cloudWorkspaceOptions.map((option) => {
      if (option.type === "environment") {
        const value = `cloud-workspace-env:${option.environmentId}`;
        return {
          value,
          label: option.name,
          keywords: option.keywords,
          searchText: buildSearchText(option.name, option.keywords),
          className: baseCommandItemClassName,
          disabled: isCreatingCloudWorkspace,
          execute: () => handleCloudWorkspaceSelect(option),
          renderContent: () => (
            <>
              <Server className="h-4 w-4 text-neutral-500" />
              <div className="flex min-w-0 flex-1 flex-col">
                <span className="truncate text-sm">{option.name}</span>
              </div>
            </>
          ),
        };
      } else {
        const value = `cloud-workspace-repo:${option.fullName}`;
        return {
          value,
          label: option.fullName,
          keywords: option.keywords,
          searchText: buildSearchText(option.fullName, option.keywords, [
            option.repoBaseName,
          ]),
          className: baseCommandItemClassName,
          disabled: isCreatingCloudWorkspace,
          execute: () => handleCloudWorkspaceSelect(option),
          renderContent: () => (
            <>
              <GitHubIcon className="h-4 w-4 text-neutral-500" />
              <div className="flex min-w-0 flex-1 flex-col">
                <span className="truncate text-sm">{option.fullName}</span>
              </div>
            </>
          ),
        };
      }
    });
  }, [
    cloudWorkspaceOptions,
    handleCloudWorkspaceSelect,
    isCreatingCloudWorkspace,
  ]);

  const {
    history: rootSuggestionHistory,
    record: recordRootUsage,
    prune: pruneRootHistory,
  } = useSuggestionHistory(buildScopeKey("root"));
  const {
    history: localWorkspaceSuggestionHistory,
    record: recordLocalWorkspaceUsage,
    prune: pruneLocalWorkspaceHistory,
  } = useSuggestionHistory(buildScopeKey("local-workspaces", teamSlugOrId));
  const {
    history: cloudWorkspaceSuggestionHistory,
    record: recordCloudWorkspaceUsage,
    prune: pruneCloudWorkspaceHistory,
  } = useSuggestionHistory(buildScopeKey("cloud-workspaces", teamSlugOrId));

  useEffect(() => {
    pruneRootHistory(new Set(rootCommandEntries.map((entry) => entry.value)));
  }, [rootCommandEntries, pruneRootHistory]);

  useEffect(() => {
    pruneLocalWorkspaceHistory(
      new Set(localWorkspaceEntries.map((entry) => entry.value))
    );
  }, [localWorkspaceEntries, pruneLocalWorkspaceHistory]);

  useEffect(() => {
    pruneCloudWorkspaceHistory(
      new Set(cloudWorkspaceEntries.map((entry) => entry.value))
    );
  }, [cloudWorkspaceEntries, pruneCloudWorkspaceHistory]);

  const filteredRootEntries = useMemo(
    () => filterCommandItems(search, rootCommandEntries),
    [rootCommandEntries, search]
  );

  const filteredLocalWorkspaceEntries = useMemo(
    () => filterCommandItems(search, localWorkspaceEntries),
    [localWorkspaceEntries, search]
  );
  const filteredCloudWorkspaceEntries = useMemo(
    () => filterCommandItems(search, cloudWorkspaceEntries),
    [cloudWorkspaceEntries, search]
  );
  const filteredTeamEntries = useMemo(
    () => filterCommandItems(search, teamCommandEntries),
    [search, teamCommandEntries]
  );

  const hasSearchQuery = search.trim().length > 0;

  const rootSuggestedEntries = useMemo(
    () =>
      selectSuggestedItems(rootSuggestionHistory, filteredRootEntries, 5).filter(
        (entry) => entry.value !== "onboarding:start"
      ),
    [filteredRootEntries, rootSuggestionHistory]
  );
  const rootSuggestedValueSet = useMemo(
    () => new Set(rootSuggestedEntries.map((entry) => entry.value)),
    [rootSuggestedEntries]
  );
  const rootRemainingEntries = useMemo(
    () =>
      filteredRootEntries.filter(
        (entry) => !rootSuggestedValueSet.has(entry.value)
      ),
    [filteredRootEntries, rootSuggestedValueSet]
  );

  const localWorkspaceSuggestedEntries = useMemo(
    () =>
      selectSuggestedItems(
        localWorkspaceSuggestionHistory,
        filteredLocalWorkspaceEntries,
        5
      ),
    [filteredLocalWorkspaceEntries, localWorkspaceSuggestionHistory]
  );
  const localWorkspaceSuggestedValueSet = useMemo(
    () => new Set(localWorkspaceSuggestedEntries.map((entry) => entry.value)),
    [localWorkspaceSuggestedEntries]
  );
  const localWorkspaceRemainingEntries = useMemo(
    () =>
      filteredLocalWorkspaceEntries.filter(
        (entry) => !localWorkspaceSuggestedValueSet.has(entry.value)
      ),
    [filteredLocalWorkspaceEntries, localWorkspaceSuggestedValueSet]
  );

  const rootSuggestionsToRender = useMemo(
    () => (!hasSearchQuery ? rootSuggestedEntries : []),
    [hasSearchQuery, rootSuggestedEntries]
  );
  const rootCommandsToRender = useMemo(
    () =>
      hasSearchQuery || rootSuggestionsToRender.length === 0
        ? filteredRootEntries
        : rootRemainingEntries,
    [
      filteredRootEntries,
      hasSearchQuery,
      rootRemainingEntries,
      rootSuggestionsToRender.length,
    ]
  );
  const rootVisibleValues = useMemo(
    () =>
      [...rootSuggestionsToRender, ...rootCommandsToRender].map(
        (entry) => entry.value
      ),
    [rootCommandsToRender, rootSuggestionsToRender]
  );
  const localWorkspaceSuggestionsToRender = useMemo(
    () => (!hasSearchQuery ? localWorkspaceSuggestedEntries : []),
    [hasSearchQuery, localWorkspaceSuggestedEntries]
  );
  const localWorkspaceCommandsToRender = useMemo(
    () =>
      hasSearchQuery || localWorkspaceSuggestionsToRender.length === 0
        ? filteredLocalWorkspaceEntries
        : localWorkspaceRemainingEntries,
    [
      filteredLocalWorkspaceEntries,
      hasSearchQuery,
      localWorkspaceRemainingEntries,
      localWorkspaceSuggestionsToRender.length,
    ]
  );
  const localWorkspaceVisibleValues = useMemo(
    () =>
      [
        ...localWorkspaceSuggestionsToRender,
        ...localWorkspaceCommandsToRender,
      ].map((entry) => entry.value),
    [localWorkspaceCommandsToRender, localWorkspaceSuggestionsToRender]
  );

  const cloudWorkspaceSuggestedEntries = useMemo(
    () =>
      selectSuggestedItems(
        cloudWorkspaceSuggestionHistory,
        filteredCloudWorkspaceEntries,
        5
      ),
    [filteredCloudWorkspaceEntries, cloudWorkspaceSuggestionHistory]
  );
  const cloudWorkspaceSuggestedValueSet = useMemo(
    () => new Set(cloudWorkspaceSuggestedEntries.map((entry) => entry.value)),
    [cloudWorkspaceSuggestedEntries]
  );
  const cloudWorkspaceRemainingEntries = useMemo(
    () =>
      filteredCloudWorkspaceEntries.filter(
        (entry) => !cloudWorkspaceSuggestedValueSet.has(entry.value)
      ),
    [filteredCloudWorkspaceEntries, cloudWorkspaceSuggestedValueSet]
  );

  const cloudWorkspaceSuggestionsToRender = useMemo(
    () => (!hasSearchQuery ? cloudWorkspaceSuggestedEntries : []),
    [hasSearchQuery, cloudWorkspaceSuggestedEntries]
  );
  const cloudWorkspaceCommandsToRender = useMemo(
    () =>
      hasSearchQuery || cloudWorkspaceSuggestionsToRender.length === 0
        ? filteredCloudWorkspaceEntries
        : cloudWorkspaceRemainingEntries,
    [
      filteredCloudWorkspaceEntries,
      hasSearchQuery,
      cloudWorkspaceRemainingEntries,
      cloudWorkspaceSuggestionsToRender.length,
    ]
  );
  const cloudWorkspaceVisibleValues = useMemo(
    () =>
      [
        ...cloudWorkspaceSuggestionsToRender,
        ...cloudWorkspaceCommandsToRender,
      ].map((entry) => entry.value),
    [cloudWorkspaceCommandsToRender, cloudWorkspaceSuggestionsToRender]
  );

  const shouldVirtualizeRoot =
    rootCommandsToRender.length > COMMAND_LIST_VIRTUALIZATION_THRESHOLD;
  const shouldVirtualizeLocal =
    localWorkspaceCommandsToRender.length >
    COMMAND_LIST_VIRTUALIZATION_THRESHOLD;
  const shouldVirtualizeCloud =
    cloudWorkspaceCommandsToRender.length >
    COMMAND_LIST_VIRTUALIZATION_THRESHOLD;

  const rootVirtualizer = useVirtualizer<HTMLDivElement, HTMLDivElement>({
    count: rootCommandsToRender.length,
    getScrollElement: () => commandListRef.current,
    estimateSize: () => COMMAND_LIST_ESTIMATED_ROW_HEIGHT,
    overscan: 24,
    initialRect: { width: 720, height: 400 },
    enabled: shouldVirtualizeRoot && activePage === "root" && open,
  });

  const localWorkspaceVirtualizer = useVirtualizer<
    HTMLDivElement,
    HTMLDivElement
  >({
    count: localWorkspaceCommandsToRender.length,
    getScrollElement: () => commandListRef.current,
    estimateSize: () => COMMAND_LIST_ESTIMATED_ROW_HEIGHT,
    overscan: 24,
    initialRect: { width: 720, height: 400 },
    enabled: shouldVirtualizeLocal && activePage === "local-workspaces" && open,
  });

  const cloudWorkspaceVirtualizer = useVirtualizer<
    HTMLDivElement,
    HTMLDivElement
  >({
    count: cloudWorkspaceCommandsToRender.length,
    getScrollElement: () => commandListRef.current,
    estimateSize: () => COMMAND_LIST_ESTIMATED_ROW_HEIGHT,
    overscan: 24,
    initialRect: { width: 720, height: 400 },
    enabled: shouldVirtualizeCloud && activePage === "cloud-workspaces" && open,
  });

  const rootCommandIndexMap = useMemo(() => {
    const map = new Map<string, number>();
    rootCommandsToRender.forEach((entry, index) => {
      map.set(entry.value, index);
    });
    return map;
  }, [rootCommandsToRender]);

  const localWorkspaceCommandIndexMap = useMemo(() => {
    const map = new Map<string, number>();
    localWorkspaceCommandsToRender.forEach((entry, index) => {
      map.set(entry.value, index);
    });
    return map;
  }, [localWorkspaceCommandsToRender]);

  const cloudWorkspaceCommandIndexMap = useMemo(() => {
    const map = new Map<string, number>();
    cloudWorkspaceCommandsToRender.forEach((entry, index) => {
      map.set(entry.value, index);
    });
    return map;
  }, [cloudWorkspaceCommandsToRender]);

  const teamVisibleValues = useMemo(() => {
    if (!filteredTeamEntries.length) return [];
    return filteredTeamEntries.map((entry) => entry.value);
  }, [filteredTeamEntries]);

  const renderCommandItem = useCallback(
    (entry: CommandListEntry, recordUsage: (value: string) => void) => (
      <Command.Item
        key={entry.value}
        value={entry.value}
        data-value={entry.dataValue ?? entry.value}
        keywords={entry.keywords}
        disabled={entry.disabled}
        className={entry.className ?? baseCommandItemClassName}
        onSelect={async () => {
          try {
            await entry.execute();
            if (entry.trackUsage !== false) {
              recordUsage(entry.value);
            }
          } catch (error) {
            console.error("Failed to execute command", error);
          }
        }}
      >
        {entry.renderContent()}
      </Command.Item>
    ),
    []
  );

  const renderRootCommandEntry = useCallback(
    (entry: CommandListEntry) => renderCommandItem(entry, recordRootUsage),
    [recordRootUsage, renderCommandItem]
  );

  const renderLocalWorkspaceCommandEntry = useCallback(
    (entry: CommandListEntry) =>
      renderCommandItem(entry, recordLocalWorkspaceUsage),
    [recordLocalWorkspaceUsage, renderCommandItem]
  );

  const renderCloudWorkspaceCommandEntry = useCallback(
    (entry: CommandListEntry) =>
      renderCommandItem(entry, recordCloudWorkspaceUsage),
    [recordCloudWorkspaceUsage, renderCommandItem]
  );

  const scrollCommandItemIntoView = useCallback(
    (value: string | undefined) => {
      if (!value) return;

      if (activePage === "root" && shouldVirtualizeRoot) {
        const index = rootCommandIndexMap.get(value);
        if (index !== undefined) {
          try {
            rootVirtualizer.scrollToIndex(index, {
              align: "auto",
              behavior: "auto",
            });
            return;
          } catch {
            // ignore and fall back to DOM-based scrolling
          }
        }
      } else if (activePage === "local-workspaces" && shouldVirtualizeLocal) {
        const index = localWorkspaceCommandIndexMap.get(value);
        if (index !== undefined) {
          try {
            localWorkspaceVirtualizer.scrollToIndex(index, {
              align: "auto",
              behavior: "auto",
            });
            return;
          } catch {
            // ignore and fall back to DOM-based scrolling
          }
        }
      } else if (activePage === "cloud-workspaces" && shouldVirtualizeCloud) {
        const index = cloudWorkspaceCommandIndexMap.get(value);
        if (index !== undefined) {
          try {
            cloudWorkspaceVirtualizer.scrollToIndex(index, {
              align: "auto",
              behavior: "auto",
            });
            return;
          } catch {
            // ignore and fall back to DOM-based scrolling
          }
        }
      }

      if (typeof window === "undefined") return;
      const listEl = commandListRef.current;
      if (!listEl) return;
      const escapeValue =
        typeof window.CSS !== "undefined" &&
        typeof window.CSS.escape === "function"
          ? window.CSS.escape(value)
          : value.replace(/["\\]/g, "\\$&");
      const selector = `[data-value="${escapeValue}"]`;
      const run = () => {
        const target = listEl.querySelector<HTMLElement>(selector);
        if (!target) return;
        const scrolled = adjustContainerScrollForChild(listEl, target);
        if (!scrolled) {
          target.scrollIntoView({
            block: "nearest",
            inline: "nearest",
            behavior: "auto",
          });
        }
      };
      setTimeout(run, 0);
    },
    [
      activePage,
      cloudWorkspaceCommandIndexMap,
      cloudWorkspaceVirtualizer,
      localWorkspaceCommandIndexMap,
      localWorkspaceVirtualizer,
      rootCommandIndexMap,
      rootVirtualizer,
      shouldVirtualizeCloud,
      shouldVirtualizeLocal,
      shouldVirtualizeRoot,
    ]
  );

  useLayoutEffect(() => {
    if (!open) return;
    scrollCommandItemIntoView(commandValue);
  }, [commandValue, open, scrollCommandItemIntoView]);

  useEffect(() => {
    if (!open) return;
    let availableValues: string[] = [];
    if (activePage === "root") {
      availableValues = rootVisibleValues;
    } else if (activePage === "local-workspaces") {
      availableValues = localWorkspaceVisibleValues;
    } else if (activePage === "cloud-workspaces") {
      availableValues = cloudWorkspaceVisibleValues;
    } else if (activePage === "teams") {
      availableValues = teamVisibleValues;
    }

    if (availableValues.length === 0) {
      setCommandValue(undefined);
      return;
    }

    if (!commandValue || !availableValues.includes(commandValue)) {
      setCommandValue(availableValues[0]);
    }
  }, [
    activePage,
    cloudWorkspaceVisibleValues,
    commandValue,
    localWorkspaceVisibleValues,
    open,
    rootVisibleValues,
    teamVisibleValues,
  ]);

  useEffect(() => {
    if (!open) {
      previousSearchRef.current = search;
      return;
    }

    if (previousSearchRef.current === search) {
      return;
    }

    previousSearchRef.current = search;

    let availableValues: string[] = [];
    if (activePage === "root") {
      availableValues = rootVisibleValues;
    } else if (activePage === "local-workspaces") {
      availableValues = localWorkspaceVisibleValues;
    } else if (activePage === "cloud-workspaces") {
      availableValues = cloudWorkspaceVisibleValues;
    } else if (activePage === "teams") {
      availableValues = teamVisibleValues;
    }

    if (availableValues.length === 0) {
      setCommandValue(undefined);
      return;
    }

    const firstValue = availableValues[0];
    if (commandValue !== firstValue) {
      setCommandValue(firstValue);
    }
    scrollCommandItemIntoView(firstValue);
  }, [
    activePage,
    cloudWorkspaceVisibleValues,
    commandValue,
    localWorkspaceVisibleValues,
    open,
    rootVisibleValues,
    scrollCommandItemIntoView,
    search,
    teamVisibleValues,
  ]);

  return (
    <>
      <div
        className={clsx(
          "fixed inset-0 z-(--z-commandbar)",
          open
            ? "opacity-100 pointer-events-auto"
            : "opacity-0 pointer-events-none"
        )}
        aria-hidden={!open}
        onClick={closeCommand}
      />
      <div
        className={clsx(
          "fixed inset-x-0 top-57.5 z-(--z-commandbar) flex items-start justify-center pointer-events-none",
          open ? "opacity-100" : "opacity-0"
        )}
        aria-hidden={!open}
      >
        <div
          className={`w-full max-w-2xl h-auto max-h-118.75 bg-white dark:bg-neutral-900 rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700 overflow-hidden flex flex-col ${
            open
              ? "opacity-100 pointer-events-auto"
              : "opacity-0 pointer-events-none"
          }`}
          ref={commandContainerRef}
          aria-hidden={!open}
        >
          <Command
            value={commandValue}
            shouldFilter={false}
            onValueChange={(value) => {
              setCommandValue(value || undefined);
            }}
            label="Command Menu"
            className="flex h-full flex-col"
            onKeyDownCapture={(e) => {
              if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                handleEscape();
              } else if (
                e.key === "Backspace" &&
                activePage !== "root" &&
                search.length === 0 &&
                inputRef.current &&
                e.target === inputRef.current
              ) {
                e.preventDefault();
                setActivePage("root");
              }
            }}
          >
            <h2 className="sr-only">Command Menu</h2>
            <Command.Input
              value={search}
              onValueChange={setSearch}
              placeholder="Type a command or search..."
              ref={inputRef}
              className="w-full px-4 py-3 text-sm bg-transparent border-b border-neutral-200 dark:border-neutral-700 outline-none placeholder:text-neutral-500 dark:placeholder:text-neutral-400"
            />
            <CommandHighlightListener onHighlight={handleHighlight} />
            <Command.List
              ref={commandListRef}
              style={{
                maxHeight: commandListMaxHeight,
                scrollPaddingTop: `${COMMAND_LIST_SCROLL_PADDING_TOP_PX}px`,
                scrollPaddingBottom: `${COMMAND_LIST_SCROLL_PADDING_BOTTOM_PX}px`,
                scrollPaddingBlockStart: `${COMMAND_LIST_SCROLL_PADDING_TOP_PX}px`,
                scrollPaddingBlockEnd: `${COMMAND_LIST_SCROLL_PADDING_BOTTOM_PX}px`,
              }}
              className="flex-1 min-h-0 overflow-y-auto px-1 pt-1 pb-2 flex flex-col gap-2"
            >
              <Command.Empty className="py-6 text-center text-sm text-neutral-500 dark:text-neutral-400">
                {activePage === "teams"
                  ? "No matching teams."
                  : activePage === "local-workspaces"
                    ? isLocalWorkspaceLoading
                      ? "Loading repositories…"
                      : "No matching repositories."
                    : activePage === "cloud-workspaces"
                      ? isCloudWorkspaceLoading
                        ? "Loading workspaces…"
                        : "No matching workspaces."
                      : "No results found."}
              </Command.Empty>

              {activePage === "root" ? (
                <>
                  {rootSuggestionsToRender.length > 0 ? (
                    <Command.Group>
                      {rootSuggestionsToRender.map((entry) =>
                        renderRootCommandEntry(entry)
                      )}
                    </Command.Group>
                  ) : null}
                  {rootCommandsToRender.length > 0 ? (
                    <Command.Group>
                      {shouldVirtualizeRoot ? (
                        <VirtualizedCommandItems
                          entries={rootCommandsToRender}
                          virtualizer={rootVirtualizer}
                          renderEntry={renderRootCommandEntry}
                        />
                      ) : (
                        rootCommandsToRender.map((entry) =>
                          renderRootCommandEntry(entry)
                        )
                      )}
                    </Command.Group>
                  ) : null}
                </>
              ) : null}

              {activePage === "local-workspaces" ? (
                <>
                  {isLocalWorkspaceLoading ? (
                    <div className={placeholderClassName}>
                      Loading repositories…
                    </div>
                  ) : (
                    <>
                      {localWorkspaceSuggestionsToRender.length > 0 ? (
                        <Command.Group>
                          {localWorkspaceSuggestionsToRender.map((entry) =>
                            renderLocalWorkspaceCommandEntry(entry)
                          )}
                        </Command.Group>
                      ) : null}
                      {localWorkspaceSuggestionsToRender.length > 0 &&
                      localWorkspaceCommandsToRender.length > 0 ? (
                        <div className="px-2">
                          <hr className="border-neutral-200 dark:border-neutral-800" />
                        </div>
                      ) : null}
                      {localWorkspaceCommandsToRender.length > 0 ? (
                        <Command.Group>
                          {shouldVirtualizeLocal ? (
                            <VirtualizedCommandItems
                              entries={localWorkspaceCommandsToRender}
                              virtualizer={localWorkspaceVirtualizer}
                              renderEntry={renderLocalWorkspaceCommandEntry}
                            />
                          ) : (
                            localWorkspaceCommandsToRender.map((entry) =>
                              renderLocalWorkspaceCommandEntry(entry)
                            )
                          )}
                        </Command.Group>
                      ) : null}
                    </>
                  )}
                </>
              ) : null}

              {activePage === "cloud-workspaces" ? (
                <>
                  {isCloudWorkspaceLoading ? (
                    <div className={placeholderClassName}>
                      Loading workspaces…
                    </div>
                  ) : (
                    <>
                      {cloudWorkspaceSuggestionsToRender.length > 0 ? (
                        <Command.Group>
                          {cloudWorkspaceSuggestionsToRender.map((entry) =>
                            renderCloudWorkspaceCommandEntry(entry)
                          )}
                        </Command.Group>
                      ) : null}
                      {cloudWorkspaceSuggestionsToRender.length > 0 &&
                      cloudWorkspaceCommandsToRender.length > 0 ? (
                        <div className="px-2">
                          <hr className="border-neutral-200 dark:border-neutral-800" />
                        </div>
                      ) : null}
                      {cloudWorkspaceCommandsToRender.length > 0 ? (
                        <Command.Group>
                          {shouldVirtualizeCloud ? (
                            <VirtualizedCommandItems
                              entries={cloudWorkspaceCommandsToRender}
                              virtualizer={cloudWorkspaceVirtualizer}
                              renderEntry={renderCloudWorkspaceCommandEntry}
                            />
                          ) : (
                            cloudWorkspaceCommandsToRender.map((entry) =>
                              renderCloudWorkspaceCommandEntry(entry)
                            )
                          )}
                        </Command.Group>
                      ) : null}
                    </>
                  )}
                </>
              ) : null}

              {activePage === "teams" ? (
                <>
                  <Command.Group>
                    <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                      Teams
                    </div>
                    {isTeamsLoading ? (
                      <Command.Item
                        value="teams:loading"
                        disabled
                        className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-default text-sm text-neutral-500 dark:text-neutral-400"
                      >
                        Loading teams…
                      </Command.Item>
                    ) : teamCommandEntries.length > 0 ? (
                      filteredTeamEntries.map(({ value, item }) => (
                        <Command.Item
                          key={value}
                          value={value}
                          data-value={value}
                          keywords={item.keywords}
                          onSelect={() => handleSelect(value)}
                          className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                        >
                          <Users className="h-4 w-4 text-neutral-500" />
                          <span className="flex-1 truncate text-sm">
                            {item.label}
                          </span>
                          {item.isCurrent ? (
                            <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400">
                              current
                            </span>
                          ) : null}
                        </Command.Item>
                      ))
                    ) : (
                      <Command.Item
                        value="teams:none"
                        disabled
                        className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-default text-sm text-neutral-500 dark:text-neutral-400"
                      >
                        {teamPageEmptyMessage}
                      </Command.Item>
                    )}
                  </Command.Group>
                </>
              ) : null}
            </Command.List>
          </Command>
        </div>
      </div>
      <NewTaskDialog
        open={isNewTaskDialogOpen}
        onOpenChange={setIsNewTaskDialogOpen}
        teamSlugOrId={teamSlugOrId}
      />
    </>
  );
}
const buildNodePath = (
  root: HTMLElement,
  target: Node | null
): number[] | null => {
  if (!target) return null;
  const path: number[] = [];
  let current: Node | null = target;
  while (current && current !== root && current.parentNode) {
    const parent = current.parentNode as Node | null;
    if (!parent) return null;
    const index = Array.prototype.indexOf.call(parent.childNodes, current);
    if (index === -1) return null;
    path.unshift(index);
    current = parent;
  }
  return current === root ? path : null;
};

const resolveNodePath = (root: HTMLElement, path: number[]): Node | null => {
  let current: Node | null = root;
  for (const index of path) {
    if (!current || !current.childNodes[index]) {
      return null;
    }
    current = current.childNodes[index];
  }
  return current;
};
