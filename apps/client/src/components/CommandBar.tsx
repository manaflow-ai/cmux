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
  type LucideIcon,
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

type TeamCommandItem = {
  id: string;
  label: string;
  slug?: string;
  teamSlugOrId: string;
  isCurrent: boolean;
  keywords: string[];
};

type CommandAccessoryConfig = {
  text: string;
  className?: string;
};

type CommandItemConfig = {
  key: string;
  value: string;
  executeValue?: string;
  dataValue?: string;
  label: string;
  labelClassName?: string;
  icon?: LucideIcon;
  iconClassName?: string;
  keywords?: string[];
  disabled?: boolean;
  interactive?: boolean;
  className?: string;
  leadingAccessory?: CommandAccessoryConfig;
  trailingAccessory?: CommandAccessoryConfig;
};

type CommandGroupConfig = {
  id: string;
  label: string;
  items: CommandItemConfig[];
};

const COMMAND_PAGE_IDS = {
  root: "root",
  teams: "teams",
} as const;

type CommandPageId = (typeof COMMAND_PAGE_IDS)[keyof typeof COMMAND_PAGE_IDS];

type CommandPageConfig = {
  id: CommandPageId;
  emptyMessage: string;
  groups: CommandGroupConfig[];
};

const DEFAULT_COMMAND_PAGE_ID: CommandPageId = COMMAND_PAGE_IDS.root;

const combineClasses = (...classes: Array<string | undefined>) =>
  classes.filter(Boolean).join(" ");

const commandGroupHeadingClass =
  "px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400";

const interactiveItemBaseClass =
  "flex items-center px-3 py-2.5 mx-1 rounded-md cursor-pointer hover:bg-neutral-100 dark:hover:bg-neutral-800 data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800 data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100";

const nonInteractiveItemBaseClass =
  "flex items-center px-3 py-2.5 mx-1 rounded-md cursor-default";

const leadingAccessoryBaseClass =
  "flex items-center justify-center rounded text-xs font-semibold bg-neutral-200 dark:bg-neutral-700 text-neutral-600 dark:text-neutral-300 group-data-[selected=true]:bg-neutral-300 dark:group-data-[selected=true]:bg-neutral-600";

const trailingAccessoryBaseClass = "text-xs px-2 py-0.5 rounded-full";

const completedTaskStatusClass =
  "bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400";
const inProgressTaskStatusClass =
  "bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400";
const currentTeamBadgeClass =
  "bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400";

const defaultItemSpacingClass = "gap-2";
const teamItemSpacingClass = "gap-3";
const taskItemSpacingClass = "gap-3 group";
const passiveItemSpacingClass = "gap-3";

const defaultIconClass = "h-4 w-4 text-neutral-500";
const defaultLabelClass = "text-sm";
const truncatedLabelClass = "flex-1 truncate text-sm";

function renderCommandItem(
  item: CommandItemConfig,
  onSelect: (value: string) => void,
) {
  const Icon = item.icon;
  const baseClassName =
    item.interactive === false ? nonInteractiveItemBaseClass : interactiveItemBaseClass;
  const className = combineClasses(baseClassName, item.className);
  const labelClassName = item.labelClassName ?? defaultLabelClass;
  const onSelectHandler =
    item.interactive === false
      ? undefined
      : () => onSelect(item.executeValue ?? item.value);

  return (
    <Command.Item
      key={item.key}
      value={item.value}
      data-value={item.dataValue}
      keywords={item.keywords}
      disabled={item.disabled}
      onSelect={onSelectHandler}
      className={className}
    >
      {item.leadingAccessory ? (
        <span
          className={combineClasses(
            leadingAccessoryBaseClass,
            item.leadingAccessory.className,
          )}
        >
          {item.leadingAccessory.text}
        </span>
      ) : null}
      {Icon ? (
        <Icon className={item.iconClassName ?? defaultIconClass} />
      ) : null}
      <span className={labelClassName}>{item.label}</span>
      {item.trailingAccessory ? (
        <span
          className={combineClasses(
            trailingAccessoryBaseClass,
            item.trailingAccessory.className,
          )}
        >
          {item.trailingAccessory.text}
        </span>
      ) : null}
    </Command.Item>
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

export function CommandBar({ teamSlugOrId }: CommandBarProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [openedWithShift, setOpenedWithShift] = useState(false);
  const [activePage, setActivePage] = useState<CommandPageId>(
    DEFAULT_COMMAND_PAGE_ID,
  );
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
    setActivePage(COMMAND_PAGE_IDS.root);
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
        setActivePage(COMMAND_PAGE_IDS.root);
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
        setActivePage(COMMAND_PAGE_IDS.root);
        setOpenedWithShift(false);
        if (openRef.current) {
          setSearch("");
        } else {
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
      } else if (value?.startsWith("team:")) {
        const [teamIdPart, slugPart] = value.slice(5).split(":");
        const targetTeamSlugOrId = slugPart || teamIdPart;
        await preloadTeamDashboard(targetTeamSlugOrId);
      } else if (value?.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0];
        const action = parts[1];
        const task = allTasks?.find((t) => t._id === (taskId as Id<"tasks">));
        const runId = task?.selectedTaskRun?._id;

        try {
          if (!action) {
            // Preload main task route
            await router.preloadRoute({
              to: "/$teamSlugOrId/task/$taskId",
              // @ts-expect-error - taskId from string
              params: { teamSlugOrId, taskId },
              search: { runId: undefined },
            });
          } else if (action === "vs") {
            if (runId) {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                // @ts-expect-error - provided from runtime lookup
                params: { teamSlugOrId, taskId, runId },
              });
            } else {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId",
                // @ts-expect-error - taskId from string
                params: { teamSlugOrId, taskId },
                search: { runId: undefined },
              });
            }
          } else if (action === "gitdiff") {
            if (runId) {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
                // @ts-expect-error - provided from runtime lookup
                params: { teamSlugOrId, taskId, runId },
              });
            } else {
              await router.preloadRoute({
                to: "/$teamSlugOrId/task/$taskId",
                // @ts-expect-error - taskId from string
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
        setActivePage(COMMAND_PAGE_IDS.teams);
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
              params: { teamSlugOrId, taskId, runId },
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
              params: { teamSlugOrId, taskId, runId },
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

  const rootCommandGroups = useMemo<CommandGroupConfig[]>(() => {
    const groups: CommandGroupConfig[] = [
      {
        id: "actions",
        label: "Actions",
        items: [
          {
            key: "new-task",
            value: "new-task",
            label: "New Task",
            icon: Plus,
            className: defaultItemSpacingClass,
          },
          {
            key: "pull-requests",
            value: "pull-requests",
            label: "Pull Requests",
            icon: GitPullRequest,
            className: defaultItemSpacingClass,
          },
        ],
      },
      {
        id: "navigation",
        label: "Navigation",
        items: [
          {
            key: "home",
            value: "home",
            label: "Home",
            icon: Home,
            className: defaultItemSpacingClass,
          },
          {
            key: "environments",
            value: "environments",
            label: "Environments",
            icon: Server,
            className: defaultItemSpacingClass,
          },
          {
            key: "settings",
            value: "settings",
            label: "Settings",
            icon: Settings,
            className: defaultItemSpacingClass,
          },
        ],
      },
      {
        id: "teams",
        label: "Teams",
        items: [
          {
            key: "teams-switch",
            value: "teams:switch",
            label: "Switch team",
            icon: Users,
            className: teamItemSpacingClass,
            labelClassName: truncatedLabelClass,
            keywords: ["team", "teams", "switch"],
          },
        ],
      },
      {
        id: "theme",
        label: "Theme",
        items: [
          {
            key: "theme-light",
            value: "theme-light",
            label: "Light Mode",
            icon: Sun,
            iconClassName: "h-4 w-4 text-amber-500",
            className: defaultItemSpacingClass,
          },
          {
            key: "theme-dark",
            value: "theme-dark",
            label: "Dark Mode",
            icon: Moon,
            iconClassName: "h-4 w-4 text-blue-500",
            className: defaultItemSpacingClass,
          },
          {
            key: "theme-system",
            value: "theme-system",
            label: "System Theme",
            icon: Monitor,
            className: defaultItemSpacingClass,
          },
        ],
      },
    ];

    if (stackUser) {
      groups.push({
        id: "account",
        label: "Account",
        items: [
          {
            key: "sign-out",
            value: "sign-out",
            label: "Sign out",
            icon: LogOut,
            className: defaultItemSpacingClass,
          },
        ],
      });
    }

    const tasks = (allTasks ?? []).slice(0, 9);
    if (tasks.length > 0) {
      const taskItems = tasks.flatMap((task, index): CommandItemConfig[] => {
        const position = index + 1;
        const label = task.pullRequestTitle || task.text;
        const statusText = task.isCompleted ? "completed" : "in progress";
        const statusClass = task.isCompleted
          ? completedTaskStatusClass
          : inProgressTaskStatusClass;
        const baseKeywords = [`${position}`, `${task._id}`];

        const itemsForTask: CommandItemConfig[] = [
          {
            key: `task-${task._id}`,
            value: `task:${task._id}`,
            label,
            className: taskItemSpacingClass,
            labelClassName: truncatedLabelClass,
            keywords: baseKeywords,
            leadingAccessory: {
              text: `${position}`,
              className: "h-5 w-5",
            },
            trailingAccessory: {
              text: statusText,
              className: statusClass,
            },
          },
        ];

        const run = task.selectedTaskRun;
        if (run?._id) {
          const extendedKeywords = [...baseKeywords, "vs", "vscode"];
          itemsForTask.push({
            key: `task-${task._id}-vs`,
            value: `task:${task._id}:vs`,
            label,
            className: taskItemSpacingClass,
            labelClassName: truncatedLabelClass,
            keywords: extendedKeywords,
            leadingAccessory: {
              text: `${position} VS`,
              className: "h-5 w-8",
            },
            trailingAccessory: {
              text: statusText,
              className: statusClass,
            },
          });

          itemsForTask.push({
            key: `task-${task._id}-gitdiff`,
            value: `task:${task._id}:gitdiff`,
            label,
            className: taskItemSpacingClass,
            labelClassName: truncatedLabelClass,
            keywords: [...baseKeywords, "git", "diff"],
            leadingAccessory: {
              text: `${position} git diff`,
              className: "h-5 px-2",
            },
            trailingAccessory: {
              text: statusText,
              className: statusClass,
            },
          });
        }

        return itemsForTask;
      });

      groups.push({
        id: "tasks",
        label: "Tasks",
        items: taskItems,
      });
    }

    if (isElectron) {
      groups.push({
        id: "desktop",
        label: "Desktop",
        items: [
          {
            key: "updates:check",
            value: "updates:check",
            label: "Check for Updates",
            icon: RefreshCw,
            className: defaultItemSpacingClass,
          },
        ],
      });
    }

    return groups;
  }, [stackUser, allTasks]);

  const teamsCommandGroup = useMemo<CommandGroupConfig>(() => {
    if (isTeamsLoading) {
      return {
        id: "teams-loading",
        label: "Teams",
        items: [
          {
            key: "teams-loading",
            value: "teams:loading",
            label: "Loading teams…",
            className: combineClasses(
              passiveItemSpacingClass,
              "text-sm text-neutral-500 dark:text-neutral-400",
            ),
            interactive: false,
            disabled: true,
          },
        ],
      };
    }

    if (teamCommandItems.length > 0) {
      return {
        id: "teams-list",
        label: "Teams",
        items: teamCommandItems.map((item): CommandItemConfig => ({
          key: `team-${item.id}`,
          value: `team:${item.id}:${item.teamSlugOrId}`,
          label: item.label,
          icon: Users,
          className: teamItemSpacingClass,
          labelClassName: truncatedLabelClass,
          keywords: item.keywords,
          trailingAccessory: item.isCurrent
            ? { text: "current", className: currentTeamBadgeClass }
            : undefined,
        })),
      };
    }

    return {
      id: "teams-empty",
      label: "Teams",
      items: [
        {
          key: "teams-empty",
          value: "teams:none",
          label: teamPageEmptyMessage,
          className: combineClasses(
            passiveItemSpacingClass,
            "text-sm text-neutral-500 dark:text-neutral-400",
          ),
          interactive: false,
          disabled: true,
        },
      ],
    };
  }, [isTeamsLoading, teamCommandItems, teamPageEmptyMessage]);

  const commandPages = useMemo<Record<CommandPageId, CommandPageConfig>>(
    () => ({
      [COMMAND_PAGE_IDS.root]: {
        id: COMMAND_PAGE_IDS.root,
        emptyMessage: "No results found.",
        groups: rootCommandGroups,
      },
      [COMMAND_PAGE_IDS.teams]: {
        id: COMMAND_PAGE_IDS.teams,
        emptyMessage: teamPageEmptyMessage,
        groups: [teamsCommandGroup],
      },
    }),
    [rootCommandGroups, teamPageEmptyMessage, teamsCommandGroup],
  );

  const activePageConfig = commandPages[activePage];

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
            setActivePage(COMMAND_PAGE_IDS.root);
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
            activePage === COMMAND_PAGE_IDS.teams &&
            search.length === 0 &&
            inputRef.current &&
            e.target === inputRef.current
          ) {
            e.preventDefault();
            setActivePage(COMMAND_PAGE_IDS.root);
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
              {activePageConfig?.emptyMessage ?? "No results found."}
            </Command.Empty>

            {activePageConfig?.groups.map((group) => (
              <Command.Group key={group.id}>
                <div className={commandGroupHeadingClass}>{group.label}</div>
                {group.items.map((item) =>
                  renderCommandItem(item, handleSelect),
                )}
              </Command.Group>
            ))}

            {activePage === COMMAND_PAGE_IDS.root && isElectron ? (
              <ElectronLogsCommandItems onSelect={handleSelect} />
            ) : null}
          </Command.List>
        </div>
      </Command.Dialog>
    </>
  );
}
