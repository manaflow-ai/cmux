import { useTheme } from "@/components/theme/use-theme";
import { isElectron } from "@/lib/electron";
import { copyAllElectronLogs } from "@/lib/electron-logs/electron-logs";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import * as Dialog from "@radix-ui/react-dialog";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { Command } from "cmdk";
import { useQuery } from "convex/react";
import { GitPullRequest, Monitor, Moon, Plus, Sun } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { ElectronLogsCommandItems } from "./command-bar/ElectronLogsCommandItems";

interface CommandBarProps {
  teamSlugOrId: string;
}

export function CommandBar({ teamSlugOrId }: CommandBarProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [openedWithShift, setOpenedWithShift] = useState(false);
  const openRef = useRef<boolean>(false);
  // Used only in non-Electron fallback
  const prevFocusedElRef = useRef<HTMLElement | null>(null);
  const navigate = useNavigate();
  const router = useRouter();
  const { setTheme } = useTheme();

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
      } else if (value?.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0];
        const action = parts[1];
        const task = allTasks?.find(
          (t) => t._id === (taskId as Id<"tasks">)
        );
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
    [router, teamSlugOrId, allTasks]
  );

  const handleSelect = useCallback(
    async (value: string) => {
      if (value === "new-task") {
        navigate({
          to: "/$teamSlugOrId",
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
      } else if (value === "theme-light") {
        setTheme("light");
      } else if (value === "theme-dark") {
        setTheme("dark");
      } else if (value === "theme-system") {
        setTheme("system");
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
      setOpen(false);
      setSearch("");
      setOpenedWithShift(false);
    },
    [navigate, teamSlugOrId, setTheme, allTasks]
  );

  if (!open) return null;

  return (
    <>
      <div
        className="fixed inset-0 z-[var(--z-commandbar)]"
        onClick={() => {
          setOpen(false);
          setSearch("");
          setOpenedWithShift(false);
        }}
      />
      <Command.Dialog
        open={open}
        onOpenChange={setOpen}
        label="Command Menu"
        title="Command Menu"
        loop
        className="fixed inset-0 z-[var(--z-commandbar)] flex items-start justify-center pt-[20vh] pointer-events-none"
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            setOpen(false);
            setSearch("");
            setOpenedWithShift(false);
          }
        }}
        onValueChange={handleHighlight}
        defaultValue={openedWithShift ? "new-task" : undefined}
      >
        <Dialog.Title className="sr-only">Command Menu</Dialog.Title>

        <div className="w-full max-w-2xl bg-white dark:bg-neutral-900 rounded-xl shadow-2xl border border-neutral-200 dark:border-neutral-700 overflow-hidden pointer-events-auto">
          <Command.Input
            value={search}
            onValueChange={setSearch}
            placeholder="Type a command or search..."
            className="w-full px-4 py-3 text-sm bg-transparent border-b border-neutral-200 dark:border-neutral-700 outline-none placeholder:text-neutral-500 dark:placeholder:text-neutral-400"
          />
          <Command.List className="max-h-[400px] overflow-y-auto px-1 pb-2 flex flex-col gap-2">
            <Command.Empty className="py-6 text-center text-sm text-neutral-500 dark:text-neutral-400">
              No results found.
            </Command.Empty>

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
                      </Command.Item>
                    );

                    items.push(
                      <Command.Item
                        key={`${task._id}-gitdiff-${run._id}`}
                        value={`${index + 1} git diff:task:${task._id}`}
                        onSelect={() => handleSelect(`task:${task._id}:gitdiff`)}
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
                      </Command.Item>
                    );
                  }

                  return items;
                })}
              </Command.Group>
            )}

            {isElectron ? (
              <ElectronLogsCommandItems onSelect={handleSelect} />
            ) : null}
          </Command.List>
        </div>
      </Command.Dialog>
    </>
  );
}
