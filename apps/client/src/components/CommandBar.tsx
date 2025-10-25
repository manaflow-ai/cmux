import { useTheme } from "@/components/theme/use-theme";
import { isElectron } from "@/lib/electron";
import { copyAllElectronLogs } from "@/lib/electron-logs/electron-logs";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { stackClientApp } from "@/lib/stack";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import * as Dialog from "@radix-ui/react-dialog";
import { useUser, type Team } from "@stackframe/react";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { Command, useCommandState } from "cmdk";
import { useQuery } from "convex/react";
import {
  Bug,
  GitPullRequest,
  LogOut,
  Home,
  Monitor,
  Moon,
  Plus,
  RefreshCw,
  Server,
  Settings,
  Sun,
  Users,
  PanelLeftClose,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { ElectronLogsCommandItems } from "./command-bar/ElectronLogsCommandItems";

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

type TeamCommandItem = {
  id: string;
  label: string;
  slug?: string;
  teamSlugOrId: string;
  isCurrent: boolean;
  keywords: string[];
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
  const [activePage, setActivePage] = useState<"root" | "teams">("root");
  const openRef = useRef<boolean>(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  // Used only in non-Electron fallback
  const prevFocusedElRef = useRef<HTMLElement | null>(null);
  const navigate = useNavigate();
  const router = useRouter();
  const { setTheme } = useTheme();
  const preloadTeamDashboard = useCallback(
    async (targetTeamSlugOrId: string | undefined) => {
      if (!targetTeamSlugOrId) return;
      console.log("Preloading team dashboard for", targetTeamSlugOrId);
      await router.preloadRoute({
        to: "/$teamSlugOrId/dashboard",
        params: { teamSlugOrId: targetTeamSlugOrId },
      });
    },
    [router],
  );

  const closeCommand = useCallback(() => {
    setOpen(false);
    setSearch("");
    setOpenedWithShift(false);
    setActivePage("root");
  }, [setOpen, setSearch, setOpenedWithShift, setActivePage]);

  const stackUser = useUser({ or: "return-null" });
  const stackTeams = stackUser?.useTeams() ?? EMPTY_TEAM_LIST;
  const selectedTeamId = stackUser?.selectedTeam?.id ?? null;
  const teamMemberships = useQuery(api.teams.listTeamMemberships, {});

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

  const isTeamsLoading = Boolean(stackUser) && teamMemberships === undefined;
  const teamPageEmptyMessage = stackUser
    ? "No teams available yet."
    : "Sign in to view teams.";

  const allTasks = useQuery(api.tasks.getTasksWithTaskRuns, { teamSlugOrId });

  useEffect(() => {
    openRef.current = open;
  }, [open]);

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
    [router, teamSlugOrId, allTasks, preloadTeamDashboard],
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
                  `Update available${versionLabel}. Downloading in the background.`,
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
        window.dispatchEvent(new StorageEvent("storage", {
          key: "sidebarHidden",
          newValue: String(!currentHidden),
          oldValue: String(currentHidden),
          storageArea: localStorage,
          url: window.location.href,
        }));
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
    ],
  );

  if (!open) return null;

  return (
    <>
      <div
        className="fixed inset-0 z-[var(--z-commandbar)]"
        onClick={closeCommand}
      />
      <Command.Dialog
        open={open}
        onOpenChange={(nextOpen) => {
          if (!nextOpen) {
            closeCommand();
          } else {
            setActivePage("root");
            setOpen(true);
          }
        }}
        label="Command Menu"
        title="Command Menu"
        loop
        className="fixed inset-0 z-[var(--z-commandbar)] flex items-start justify-center pt-[20vh] pointer-events-none"
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.preventDefault();
            closeCommand();
          } else if (
            e.key === "Backspace" &&
            activePage === "teams" &&
            search.length === 0 &&
            inputRef.current &&
            e.target === inputRef.current
          ) {
            e.preventDefault();
            setActivePage("root");
          }
        }}
        defaultValue={openedWithShift ? "new-task" : undefined}
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
          <Command.List className="max-h-[400px] overflow-y-auto px-1 pb-2 flex flex-col gap-2">
            <Command.Empty className="py-6 text-center text-sm text-neutral-500 dark:text-neutral-400">
              {activePage === "teams"
                ? "No matching teams."
                : "No results found."}
            </Command.Empty>

            {activePage === "root" ? (
              <>
                <Command.Group>
                  <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                    Actions
                  </div>
                  <Command.Item
                    value="new-task"
                    onSelect={() => handleSelect("new-task")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Plus className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">New Task</span>
                  </Command.Item>
                  <Command.Item
                    value="pull-requests"
                    onSelect={() => handleSelect("pull-requests")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <GitPullRequest className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">Pull Requests</span>
                  </Command.Item>
                </Command.Group>

                {isDevEnvironment ? (
                  <Command.Group>
                    <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                      Developer
                    </div>
                    <Command.Item
                      value="dev:webcontents"
                      keywords={["debug", "electron", "webcontents"]}
                      onSelect={() => handleSelect("dev:webcontents")}
                      className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                    >
                      <Bug className="h-4 w-4 text-neutral-500" />
                      <span className="text-sm">Debug WebContents</span>
                    </Command.Item>
                  </Command.Group>
                ) : null}

                <Command.Group>
                  <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                    Navigation
                  </div>
                  <Command.Item
                    value="home"
                    onSelect={() => handleSelect("home")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Home className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">Home</span>
                  </Command.Item>
                  <Command.Item
                    value="environments"
                    onSelect={() => handleSelect("environments")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Server className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">Environments</span>
                  </Command.Item>
                  <Command.Item
                    value="settings"
                    onSelect={() => handleSelect("settings")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Settings className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">Settings</span>
                  </Command.Item>
                </Command.Group>

                <Command.Group>
                  <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                    Teams
                  </div>
                  <Command.Item
                    value="teams:switch"
                    onSelect={() => handleSelect("teams:switch")}
                    keywords={["team", "teams", "switch"]}
                    className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Users className="h-4 w-4 text-neutral-500" />
                    <span className="flex-1 truncate text-sm">Switch team</span>
                  </Command.Item>
                </Command.Group>

                <Command.Group>
                  <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                    View
                  </div>
                  <Command.Item
                    value="sidebar-toggle"
                    keywords={["sidebar", "toggle", "hide", "show", "panel"]}
                    onSelect={() => handleSelect("sidebar-toggle")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <PanelLeftClose className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">Toggle Sidebar</span>
                  </Command.Item>
                </Command.Group>

                <Command.Group>
                  <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                    Theme
                  </div>
                  <Command.Item
                    value="theme-light"
                    onSelect={() => handleSelect("theme-light")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer                 hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Sun className="h-4 w-4 text-amber-500" />
                    <span className="text-sm">Light Mode</span>
                  </Command.Item>
                  <Command.Item
                    value="theme-dark"
                    onSelect={() => handleSelect("theme-dark")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer                 hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Moon className="h-4 w-4 text-blue-500" />
                    <span className="text-sm">Dark Mode</span>
                  </Command.Item>
                  <Command.Item
                    value="theme-system"
                    onSelect={() => handleSelect("theme-system")}
                    className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer                 hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                  >
                    <Monitor className="h-4 w-4 text-neutral-500" />
                    <span className="text-sm">System Theme</span>
                  </Command.Item>
                </Command.Group>

                {stackUser ? (
                  <Command.Group>
                    <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                      Account
                    </div>
                    <Command.Item
                      value="sign-out"
                      onSelect={() => handleSelect("sign-out")}
                      className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                    >
                      <LogOut className="h-4 w-4 text-neutral-500" />
                      <span className="text-sm">Sign out</span>
                    </Command.Item>
                  </Command.Group>
                ) : null}

                {allTasks && allTasks.length > 0 && (
                  <Command.Group>
                    <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                      Tasks
                    </div>
                    {allTasks.slice(0, 9).flatMap((task, index) => {
                      const run = task.selectedTaskRun;
                      const items = [
                        <Command.Item
                          key={task._id}
                          value={`${index + 1}:task:${task._id}`}
                          onSelect={() => handleSelect(`task:${task._id}`)}
                          data-value={`task:${task._id}`}
                          className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer                     hover:bg-neutral-100 dark:hover:bg-neutral-800
                    data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                    data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100
                    group"
                        >
                          <span
                            className="flex h-5 w-5 items-center justify-center rounded text-xs font-semibold
                    bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300
                    group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600"
                          >
                            {index + 1}
                          </span>
                          <span className="flex-1 truncate text-sm">
                            {task.pullRequestTitle || task.text}
                          </span>
                          {task.isCompleted ? (
                            <span className="text-xs px-2 py-0.5 rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400">
                              completed
                            </span>
                          ) : (
                            <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400">
                              in progress
                            </span>
                          )}
                        </Command.Item>,
                      ];

                      if (run) {
                        items.push(
                          <Command.Item
                            key={`${task._id}-vs-${run._id}`}
                            value={`${index + 1} vs:task:${task._id}`}
                            onSelect={() => handleSelect(`task:${task._id}:vs`)}
                            data-value={`task:${task._id}:vs`}
                            className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer                     hover:bg-neutral-100 dark:hover:bg-neutral-800
                    data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                    data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100
                    group"
                          >
                            <span
                              className="flex h-5 w-8 items-center justify-center rounded text-xs font-semibold
                    bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300
                    group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600"
                            >
                              {index + 1} VS
                            </span>
                            <span className="flex-1 truncate text-sm">
                              {task.pullRequestTitle || task.text}
                            </span>
                            {task.isCompleted ? (
                              <span className="text-xs px-2 py-0.5 rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400">
                                completed
                              </span>
                            ) : (
                              <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400">
                                in progress
                              </span>
                            )}
                          </Command.Item>,
                        );

                        items.push(
                          <Command.Item
                            key={`${task._id}-gitdiff-${run._id}`}
                            value={`${index + 1} git diff:task:${task._id}`}
                            onSelect={() =>
                              handleSelect(`task:${task._id}:gitdiff`)
                            }
                            data-value={`task:${task._id}:gitdiff`}
                            className="flex items-center gap-3 px-3 py-2.5 mx-1 rounded-md cursor-pointer                     hover:bg-neutral-100 dark:hover:bg-neutral-800
                    data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                    data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100
                    group"
                          >
                            <span
                              className="flex h-5 px-2 items-center justify-center rounded text-xs font-semibold
                    bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300
                    group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600"
                            >
                              {index + 1} git diff
                            </span>
                            <span className="flex-1 truncate text-sm">
                              {task.pullRequestTitle || task.text}
                            </span>
                            {task.isCompleted ? (
                              <span className="text-xs px-2 py-0.5 rounded-full bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400">
                                completed
                              </span>
                            ) : (
                              <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400">
                                in progress
                              </span>
                            )}
                          </Command.Item>,
                        );
                      }

                      return items;
                    })}
                  </Command.Group>
                )}

                {isElectron ? (
                  <>
                    <Command.Group>
                      <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
                        Desktop
                      </div>
                      <Command.Item
                        value="updates:check"
                        onSelect={() => handleSelect("updates:check")}
                        className="flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer
                hover:bg-neutral-100 dark:hover:bg-neutral-800
                data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800
                data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100"
                      >
                        <RefreshCw className="h-4 w-4 text-neutral-500" />
                        <span className="text-sm">Check for Updates</span>
                      </Command.Item>
                    </Command.Group>

                    <ElectronLogsCommandItems onSelect={handleSelect} />
                  </>
                ) : null}
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
                  ) : teamCommandItems.length > 0 ? (
                    teamCommandItems.map((item) => (
                      <Command.Item
                        key={item.id}
                        value={`team:${item.id}:${item.teamSlugOrId}`}
                        data-value={`team:${item.id}:${item.teamSlugOrId}`}
                        keywords={item.keywords}
                        onSelect={() =>
                          handleSelect(`team:${item.id}:${item.teamSlugOrId}`)
                        }
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
