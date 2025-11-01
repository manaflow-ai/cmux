import { GitHubIcon } from "@/components/icons/github";
import { useTheme } from "@/components/theme/use-theme";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
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
import type { CreateLocalWorkspaceResponse } from "@cmux/shared";
import { deriveRepoBaseName, generateWorkspaceName } from "@cmux/shared";
import * as Dialog from "@radix-ui/react-dialog";
import { useUser, type Team } from "@stackframe/react";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { Command, useCommandState } from "cmdk";
import { useMutation, useQuery } from "convex/react";
import {
  Bug,
  ClipboardCopy,
  FolderPlus,
  GitPullRequest,
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

interface CommandBarProps {
  teamSlugOrId: string;
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

export function CommandBar({ teamSlugOrId }: CommandBarProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [openedWithShift, setOpenedWithShift] = useState(false);
  const [activePage, setActivePage] = useState<
    "root" | "teams" | "local-workspaces"
  >("root");
  const [isCreatingLocalWorkspace, setIsCreatingLocalWorkspace] =
    useState(false);
  const [commandValue, setCommandValue] = useState<string | undefined>(
    undefined
  );
  const openRef = useRef<boolean>(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const commandListRef = useRef<HTMLDivElement | null>(null);
  const previousSearchRef = useRef(search);
  const skipNextCloseRef = useRef(false);
  // Used only in non-Electron fallback
  const prevFocusedElRef = useRef<HTMLElement | null>(null);
  const navigate = useNavigate();
  const router = useRouter();
  const { setTheme } = useTheme();
  const { addTaskToExpand } = useExpandTasks();
  const { socket } = useSocket();
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

  const closeCommand = useCallback(() => {
    skipNextCloseRef.current = false;
    setOpen(false);
    setSearch("");
    setOpenedWithShift(false);
    setActivePage("root");
    setCommandValue(undefined);
  }, [setOpen, setSearch, setOpenedWithShift, setActivePage, setCommandValue]);

  const handleEscape = useCallback(() => {
    skipNextCloseRef.current = false;
    if (search.length > 0) {
      skipNextCloseRef.current = true;
      setSearch("");
      return;
    }
    if (activePage !== "root") {
      skipNextCloseRef.current = true;
      setActivePage("root");
      return;
    }
    closeCommand();
  }, [activePage, closeCommand, search, setActivePage, setSearch]);

  const stackUser = useUser({ or: "return-null" });
  const stackTeams = stackUser?.useTeams() ?? EMPTY_TEAM_LIST;
  const selectedTeamId = stackUser?.selectedTeam?.id ?? null;
  const teamMemberships = useQuery(api.teams.listTeamMemberships, {});
  const reposByOrg = useQuery(api.github.getReposByOrg, { teamSlugOrId });

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
        keywords: compactStrings([label, slug, team.id, teamSlugOrIdTarget]),
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
          item.teamSlugOrId,
          item.id,
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
  const nextWorkspaceSequence = useQuery(api.localWorkspaces.nextSequence, {
    teamSlugOrId,
  });
  const predictedWorkspaceSequence = nextWorkspaceSequence?.sequence ?? null;
  const reserveLocalWorkspace = useMutation(api.localWorkspaces.reserve);
  const failTaskRun = useMutation(api.taskRuns.fail);

  useEffect(() => {
    openRef.current = open;
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
      closeCommand();
      void createLocalWorkspace(projectFullName);
    },
    [closeCommand, createLocalWorkspace]
  );

  useEffect(() => {
    // In Electron, prefer global shortcut from main via cmux event.
    if (isElectron) {
      const off = window.cmux.on("shortcut:cmd-k", () => {
        // Only handle Cmd+K (no shift/ctrl variations)
        setOpenedWithShift(false);
        setActivePage("root");
        if (openRef.current) {
          // About to CLOSE via toggle: normalize state like Esc path
          setSearch("");
          setOpenedWithShift(false);
        }
        setOpen((cur) => !cur);
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
        setActivePage("root");
        if (openRef.current) {
          setOpenedWithShift(false);
          setSearch("");
        } else {
          setOpenedWithShift(false);
          // Capture the currently focused element before opening (web only)
          prevFocusedElRef.current =
            document.activeElement as HTMLElement | null;
        }
        setOpen((cur) => !cur);
      }
    };
    document.addEventListener("keydown", down);
    return () => document.removeEventListener("keydown", down);
  }, []);

  // Track and restore focus across open/close, including iframes/webviews.
  useEffect(() => {
    // Inform Electron main about palette open state to gate focus capture
    if (isElectron && window.cmux?.ui?.setCommandPaletteOpen) {
      void window.cmux.ui.setCommandPaletteOpen(open);
    }

    if (!open) {
      if (isElectron && window.cmux?.ui?.restoreLastFocus) {
        // Ask main to restore using stored info for this window
        void window.cmux.ui.restoreLastFocus();
      } else {
        // Web-only fallback: restore previously focused element in same doc
        const el = prevFocusedElRef.current;
        if (el) {
          const id = window.setTimeout(() => {
            try {
              el.focus({ preventScroll: true });
              if ((el as HTMLIFrameElement).tagName === "IFRAME") {
                try {
                  (el as HTMLIFrameElement).contentWindow?.focus?.();
                } catch {
                  // ignore
                }
              }
            } catch {
              // ignore
            }
          }, 0);
          return () => window.clearTimeout(id);
        }
      }
    }
    return undefined;
  }, [open]);

  useEffect(() => {
    if (!open || !openedWithShift) return;
    setCommandValue("new-task");
  }, [open, openedWithShift]);

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
                to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                params: {
                  teamSlugOrId,
                  taskId,
                  runId,
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
      if (value === "teams:switch") {
        setActivePage("teams");
        setSearch("");
        return;
      } else if (value === "new-task") {
        navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId },
        });
      } else if (value === "local-workspaces") {
        setActivePage("local-workspaces");
        setSearch("");
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
          return;
        }
      } else if (value === "theme-light") {
        setTheme("light");
      } else if (value === "theme-dark") {
        setTheme("dark");
      } else if (value === "theme-system") {
        setTheme("system");
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
              to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
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
      navigate,
      teamSlugOrId,
      setTheme,
      allTasks,
      stackUser,
      stackTeams,
      closeCommand,
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
            <FolderPlus className="h-4 w-4 text-neutral-500" />
            <span className="text-sm">New Local Workspace</span>
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
              String(task._id),
              `task ${index + 1}`,
            ]);
            const baseSearch = buildSearchText(title, keywords, [
              `${index + 1}`,
              `task:${task._id}`,
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
                  `task:${task._id}:vs`,
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
                  `task:${task._id}:gitdiff`,
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
      const predictedWorkspaceName =
        predictedWorkspaceSequence !== null
          ? generateWorkspaceName({
              repoName: option.repoBaseName,
              sequence: predictedWorkspaceSequence,
            })
          : null;
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
              {predictedWorkspaceName ? (
                <span className="truncate text-xs text-neutral-500 dark:text-neutral-400">
                  {predictedWorkspaceName}
                </span>
              ) : null}
            </div>
          </>
        ),
      };
    });
  }, [
    handleLocalWorkspaceSelect,
    isCreatingLocalWorkspace,
    localWorkspaceOptions,
    predictedWorkspaceSequence,
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

  useEffect(() => {
    pruneRootHistory(new Set(rootCommandEntries.map((entry) => entry.value)));
  }, [rootCommandEntries, pruneRootHistory]);

  useEffect(() => {
    pruneLocalWorkspaceHistory(
      new Set(localWorkspaceEntries.map((entry) => entry.value))
    );
  }, [localWorkspaceEntries, pruneLocalWorkspaceHistory]);

  const filteredRootEntries = useMemo(
    () => filterCommandItems(search, rootCommandEntries),
    [rootCommandEntries, search]
  );

  const filteredLocalWorkspaceEntries = useMemo(
    () => filterCommandItems(search, localWorkspaceEntries),
    [localWorkspaceEntries, search]
  );
  const filteredTeamEntries = useMemo(
    () => filterCommandItems(search, teamCommandEntries),
    [search, teamCommandEntries]
  );

  const hasSearchQuery = search.trim().length > 0;

  const rootSuggestedEntries = useMemo(
    () => selectSuggestedItems(rootSuggestionHistory, filteredRootEntries, 5),
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

  const scrollCommandItemIntoView = useCallback((value: string | undefined) => {
    if (!value) return;
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
      target?.scrollIntoView({ block: "nearest", behavior: "instant" });
    };
    if (typeof window.requestAnimationFrame === "function") {
      window.requestAnimationFrame(run);
    } else {
      run();
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    let availableValues: string[] = [];
    if (activePage === "root") {
      availableValues = rootVisibleValues;
    } else if (activePage === "local-workspaces") {
      availableValues = localWorkspaceVisibleValues;
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
    commandValue,
    localWorkspaceVisibleValues,
    open,
    rootVisibleValues,
    scrollCommandItemIntoView,
    search,
    teamVisibleValues,
  ]);

  if (!open) return null;

  return (
    <>
      <div
        className="fixed inset-0 z-[var(--z-commandbar)]"
        onClick={closeCommand}
      />
      <Command.Dialog
        open={open}
        value={commandValue}
        shouldFilter={false}
        onOpenChange={(nextOpen) => {
          if (!nextOpen) {
            if (skipNextCloseRef.current) {
              skipNextCloseRef.current = false;
              return;
            }
            closeCommand();
          } else {
            setActivePage("root");
            setOpen(true);
          }
        }}
        onValueChange={(value) => {
          setCommandValue(value || undefined);
        }}
        label="Command Menu"
        title="Command Menu"
        loop
        className="fixed inset-0 z-[var(--z-commandbar)] flex items-start justify-center pt-[20vh] pointer-events-none"
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
        <Dialog.Title className="sr-only">Command Menu</Dialog.Title>

        <div className="w-full max-w-2xl bg-white dark:bg-neutral-900 rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700 overflow-hidden pointer-events-auto">
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
            className="max-h-[400px] overflow-y-auto px-1 pb-2 flex flex-col gap-2 pt-1"
          >
            <Command.Empty className="py-6 text-center text-sm text-neutral-500 dark:text-neutral-400">
              {activePage === "teams"
                ? "No matching teams."
                : activePage === "local-workspaces"
                  ? isLocalWorkspaceLoading
                    ? "Loading repositories…"
                    : "No matching repositories."
                  : "No results found."}
            </Command.Empty>

            {activePage === "root" ? (
              <>
                {rootSuggestionsToRender.length > 0 ? (
                  <Command.Group>
                    {rootSuggestionsToRender.map((entry) =>
                      renderCommandItem(entry, recordRootUsage)
                    )}
                  </Command.Group>
                ) : null}
                {rootCommandsToRender.length > 0 ? (
                  <Command.Group>
                    {rootCommandsToRender.map((entry) =>
                      renderCommandItem(entry, recordRootUsage)
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
                          renderCommandItem(entry, recordLocalWorkspaceUsage)
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
                        {localWorkspaceCommandsToRender.map((entry) =>
                          renderCommandItem(entry, recordLocalWorkspaceUsage)
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
        </div>
      </Command.Dialog>
    </>
  );
}
