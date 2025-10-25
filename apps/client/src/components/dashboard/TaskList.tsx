import { api } from "@cmux/convex/api";
import { useQuery } from "convex/react";
import { memo, useMemo, useState } from "react";
import { TaskItem } from "./TaskItem";
import { PinnedTaskRunItem } from "./PinnedTaskRunItem";

export const TaskList = memo(function TaskList({
  teamSlugOrId,
}: {
  teamSlugOrId: string;
}) {
  const allTasks = useQuery(api.tasks.get, { teamSlugOrId });
  const archivedTasks = useQuery(api.tasks.get, {
    teamSlugOrId,
    archived: true,
  });
  const pinnedRuns = useQuery(api.taskRuns.getPinned, { teamSlugOrId });
  const [tab, setTab] = useState<"all" | "archived">("all");
  const isArchivedTab = tab === "archived";
  const tasksQuery = isArchivedTab ? archivedTasks : allTasks;
  const tasksLoading = tasksQuery === undefined;

  const visibleTasks = useMemo(() => {
    if (isArchivedTab) {
      return archivedTasks ?? [];
    }
    if (allTasks === undefined) {
      return [];
    }
    return allTasks.filter((task) => !task.isPinned);
  }, [isArchivedTab, archivedTasks, allTasks]);

  const pinnedItems = useMemo(() => {
    if (tab !== "all" || allTasks === undefined) {
      return undefined;
    }
    const pinnedTaskEntries = allTasks.filter((task) => task.isPinned);
    const runEntries = (pinnedRuns ?? []).map((entry) => entry);
    const items = [
      ...pinnedTaskEntries.map((task) => ({
        kind: "task" as const,
        pinnedAt: task.pinnedAt ?? task.updatedAt ?? task.createdAt ?? 0,
        task,
      })),
      ...runEntries.map((entry) => ({
        kind: "run" as const,
        pinnedAt:
          entry.run.pinnedAt ??
          entry.run.updatedAt ??
          entry.run.createdAt ??
          0,
        task: entry.task,
        run: entry.run,
      })),
    ];
    return items.sort((a, b) => b.pinnedAt - a.pinnedAt);
  }, [tab, allTasks, pinnedRuns]);

  const hasPinnedItems = (pinnedItems?.length ?? 0) > 0;
  const pinnedRunsPending = tab === "all" && pinnedRuns === undefined;

  const showOnlyPinnedMessage =
    !tasksLoading && visibleTasks.length === 0 && hasPinnedItems;
  const showEmptyMessage =
    !tasksLoading &&
    visibleTasks.length === 0 &&
    !hasPinnedItems &&
    !pinnedRunsPending;

  const emptyMessage =
    tab === "all" ? "No active tasks" : "No archived tasks";

  return (
    <div className="mt-6">
      <div className="mb-3">
        <div className="flex items-end gap-2.5 select-none">
          <button
            className={
              "text-sm font-medium transition-colors " +
              (tab === "all"
                ? "text-neutral-900 dark:text-neutral-100"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200")
            }
            onMouseDown={() => setTab("all")}
            onClick={() => setTab("all")}
          >
            Tasks
          </button>
          <button
            className={
              "text-sm font-medium transition-colors " +
              (tab === "archived"
                ? "text-neutral-900 dark:text-neutral-100"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200")
            }
            onMouseDown={() => setTab("archived")}
            onClick={() => setTab("archived")}
          >
            Archived
          </button>
        </div>
      </div>
      <div className="flex flex-col gap-1">
        {tab === "all" &&
        pinnedItems !== undefined &&
        pinnedItems.length > 0 ? (
          <div className="flex flex-col gap-1">
            <div className="px-1 text-xs font-semibold uppercase tracking-wide text-neutral-500 dark:text-neutral-400 select-none">
              Pinned
            </div>
            {pinnedItems.map((item) =>
              item.kind === "task" ? (
                <TaskItem
                  key={`pinned-task-${item.task._id}`}
                  task={item.task}
                  teamSlugOrId={teamSlugOrId}
                />
              ) : (
                <PinnedTaskRunItem
                  key={`pinned-run-${item.run._id}`}
                  teamSlugOrId={teamSlugOrId}
                  task={item.task}
                  run={item.run}
                />
              )
            )}
            {visibleTasks.length > 0 ? (
              <div className="mt-2 mb-1 h-px bg-neutral-200 dark:bg-neutral-700" />
            ) : null}
          </div>
        ) : null}
        {tasksLoading ? (
          <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 select-none">
            Loading...
          </div>
        ) : visibleTasks.length === 0 ? (
          showOnlyPinnedMessage ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 select-none">
              Pinned items are shown above
            </div>
          ) : showEmptyMessage ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 select-none">
              {emptyMessage}
            </div>
          ) : null
        ) : (
          visibleTasks.map((task) => (
            <TaskItem
              key={task._id}
              task={task}
              teamSlugOrId={teamSlugOrId}
            />
          ))
        )}
        {!tasksLoading &&
        tab === "all" &&
        visibleTasks.length === 0 &&
        !showOnlyPinnedMessage &&
        !showEmptyMessage ? (
          <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 select-none">
            Checking for pinned runs...
          </div>
        ) : null}
      </div>
    </div>
  );
});
