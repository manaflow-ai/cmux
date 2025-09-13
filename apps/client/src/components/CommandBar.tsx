import { useTheme } from "@/components/theme/use-theme";
import { api } from "@cmux/convex/api";
import * as Dialog from "@radix-ui/react-dialog";

import { useNavigate, useRouter } from "@tanstack/react-router";
import { Command } from "cmdk";
import { useMutation, useQuery } from "convex/react";
import { Monitor, Moon, Sun } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { isElectron } from "@/lib/electron";
import { toast } from "sonner";

interface CommandBarProps {
  teamSlugOrId: string;
}

export function CommandBar({ teamSlugOrId }: CommandBarProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [openedWithShift, setOpenedWithShift] = useState(false);
  const navigate = useNavigate();
  const router = useRouter();
  const { setTheme } = useTheme();

  const allTasks = useQuery(api.tasks.get, { teamSlugOrId });
  const createRun = useMutation(api.taskRuns.create);

  useEffect(() => {
    // In Electron, prefer global shortcut from main via cmux event.
    if (isElectron) {
      const off = window.cmux?.on?.("shortcut:cmd-k", () => {
        // Only handle Cmd+K (no shift/ctrl variations)
        setOpenedWithShift(false);
        setOpen((open) => !open);
      });
      return () => {
        // Unsubscribe if available
        if (typeof off === "function") off();
      };
    }

    // Web/non-Electron fallback: local keydown listener for Cmd+K
    const down = (e: KeyboardEvent) => {
      if (e.key === "k" && e.metaKey) {
        e.preventDefault();
        setOpenedWithShift(e.shiftKey);
        setOpen((open) => !open);
      }
    };
    document.addEventListener("keydown", down);
    return () => document.removeEventListener("keydown", down);
  }, []);

  const handleHighlight = useCallback(
    async (value: string) => {
      if (value?.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0];
        const action = parts[1];

        try {
          if (!action) {
            // Preload main task route
            await router.preloadRoute({
              to: "/$teamSlugOrId/task/$taskId",
              // @ts-expect-error - taskId from string
              params: { teamSlugOrId, taskId },
            });
          } else if (action === "vs") {
            // Preload VS Code route (will need a runId when actually navigating)
            await router.preloadRoute({
              to: "/$teamSlugOrId/task/$taskId",
              // @ts-expect-error - taskId from string
              params: { teamSlugOrId, taskId },
            });
          } else if (action === "gitdiff") {
            // Preload git diff route (will need a runId when actually navigating)
            await router.preloadRoute({
              to: "/$teamSlugOrId/task/$taskId",
              // @ts-expect-error - taskId from string
              params: { teamSlugOrId, taskId },
            });
          }
        } catch {
          // Silently fail preloading
        }
      }
    },
    [router, teamSlugOrId]
  );

  const handleSelect = useCallback(
    async (value: string) => {
      if (value === "new-task") {
        navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId },
        });
      } else if (value === "theme-light") {
        setTheme("light");
      } else if (value === "theme-dark") {
        setTheme("dark");
      } else if (value === "theme-system") {
        setTheme("system");
      } else if (value.startsWith("task:")) {
        const parts = value.slice(5).split(":");
        const taskId = parts[0];
        const action = parts[1];

        if (action === "vs" || action === "gitdiff") {
          try {
            // Create a new run for VS Code or git diff
            const runId = await createRun({
              teamSlugOrId,
              // @ts-expect-error - taskId from string
              taskId,
              prompt: action === "vs" ? "Opening VS Code" : "Viewing git diff",
            });

            if (runId) {
              if (action === "vs") {
                navigate({
                  to: "/$teamSlugOrId/task/$taskId/run/$runId/vscode",
                  // @ts-expect-error - taskId and runId extracted from string
                  params: { teamSlugOrId, taskId, runId },
                });
              } else {
                navigate({
                  to: "/$teamSlugOrId/task/$taskId/run/$runId/diff",
                  // @ts-expect-error - taskId and runId extracted from string
                  params: { teamSlugOrId, taskId, runId },
                });
              }
            }
          } catch (_error) {
            toast.error("Failed to create run");
            navigate({
              to: "/$teamSlugOrId/task/$taskId",
              // @ts-expect-error - taskId extracted from string
              params: { teamSlugOrId, taskId },
              search: { runId: undefined },
            });
          }
        } else {
          navigate({
            to: "/$teamSlugOrId/task/$taskId",
            // @ts-expect-error - taskId extracted from string
            params: { teamSlugOrId, taskId },
            search: { runId: undefined },
          });
        }
      }
      setOpen(false);
      setSearch("");
      setOpenedWithShift(false);
    },
    [navigate, teamSlugOrId, setTheme, createRun]
  );

  if (!open) return null;

  return (
    <>
      <div
        className="fixed inset-0 z-50"
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
        className="fixed inset-0 z-50 flex items-start justify-center pt-[20vh] pointer-events-none"
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
                <span className="text-sm">New Task</span>
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
                {allTasks.slice(0, 9).flatMap((task, index) => [
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
                  <Command.Item
                    key={`${task._id}-vs`}
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
                  <Command.Item
                    key={`${task._id}-gitdiff`}
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
                  </Command.Item>,
                ])}
              </Command.Group>
            )}
          </Command.List>
        </div>
      </Command.Dialog>
    </>
  );
}
