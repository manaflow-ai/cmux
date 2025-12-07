import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { useLocalStorage } from "@mantine/hooks";
import { useQuery } from "convex/react";
import clsx from "clsx";
import { memo, useCallback, useMemo, useState } from "react";
import { TaskItem } from "./TaskItem";
import { PreviewItem } from "./PreviewItem";
import { ChevronRight } from "lucide-react";

type TaskCategoryKey =
  | "pinned"
  | "workspaces"
  | "ready_to_review"
  | "in_progress"
  | "merged";

const CATEGORY_ORDER: TaskCategoryKey[] = [
  "pinned",
  "workspaces",
  "ready_to_review",
  "in_progress",
  "merged",
];

const CATEGORY_META: Record<
  TaskCategoryKey,
  { title: string; emptyLabel: string }
> = {
  pinned: {
    title: "Pinned",
    emptyLabel: "No pinned items.",
  },
  workspaces: {
    title: "Workspaces",
    emptyLabel: "No workspace sessions yet.",
  },
  ready_to_review: {
    title: "Ready to review",
    emptyLabel: "Nothing is waiting for review.",
  },
  in_progress: {
    title: "In progress",
    emptyLabel: "No tasks are currently in progress.",
  },
  merged: {
    title: "Merged",
    emptyLabel: "No merged tasks yet.",
  },
};

const createEmptyCategoryBuckets = (): Record<
  TaskCategoryKey,
  Doc<"tasks">[]
> => ({
  pinned: [],
  workspaces: [],
  ready_to_review: [],
  in_progress: [],
  merged: [],
});

const getTaskCategory = (task: Doc<"tasks">): TaskCategoryKey => {
  if (task.isCloudWorkspace || task.isLocalWorkspace) {
    return "workspaces";
  }
  if (task.mergeStatus === "pr_merged") {
    return "merged";
  }
  if (task.crownEvaluationStatus === "succeeded") {
    return "ready_to_review";
  }
  return "in_progress";
};

const sortByRecentUpdate = (tasks: Doc<"tasks">[]): Doc<"tasks">[] => {
  if (tasks.length <= 1) {
    return tasks;
  }
  return [...tasks].sort(
    (a, b) =>
      (b.updatedAt ?? b.createdAt ?? 0) - (a.updatedAt ?? a.createdAt ?? 0)
  );
};

const categorizeTasks = (
  tasks: Doc<"tasks">[] | undefined
): Record<TaskCategoryKey, Doc<"tasks">[]> | null => {
  if (!tasks) {
    return null;
  }
  const buckets = createEmptyCategoryBuckets();
  for (const task of tasks) {
    const key = getTaskCategory(task);
    buckets[key].push(task);
  }
  for (const key of CATEGORY_ORDER) {
    buckets[key] = sortByRecentUpdate(buckets[key]);
  }
  return buckets;
};

const createCollapsedCategoryState = (
  defaultValue = false
): Record<TaskCategoryKey, boolean> => ({
  pinned: defaultValue,
  workspaces: defaultValue,
  ready_to_review: defaultValue,
  in_progress: defaultValue,
  merged: defaultValue,
});

// Preview run types
type PreviewRunWithConfig = Doc<"previewRuns"> & {
  configRepoFullName?: string;
  taskId?: Id<"tasks">;
};

// Preview run grouped by PR
type PreviewRunGroup = {
  key: string; // "repoFullName#prNumber"
  repoFullName: string;
  prNumber: number;
  prUrl: string;
  latestRun: PreviewRunWithConfig;
  olderRuns: PreviewRunWithConfig[];
};

type PreviewCategoryKey = "in_progress" | "completed";

const PREVIEW_CATEGORY_ORDER: PreviewCategoryKey[] = ["in_progress", "completed"];

const PREVIEW_CATEGORY_META: Record<
  PreviewCategoryKey,
  { title: string; emptyLabel: string }
> = {
  in_progress: {
    title: "In Progress",
    emptyLabel: "No previews are currently in progress.",
  },
  completed: {
    title: "Completed",
    emptyLabel: "No completed previews yet.",
  },
};

const createEmptyPreviewCategoryBuckets = (): Record<
  PreviewCategoryKey,
  PreviewRunGroup[]
> => ({
  in_progress: [],
  completed: [],
});

const getPreviewCategory = (run: PreviewRunWithConfig): PreviewCategoryKey | null => {
  if (run.status === "pending" || run.status === "running") {
    return "in_progress";
  }
  // Only "completed" and "skipped" should show as completed (green circles)
  if (run.status === "completed" || run.status === "skipped") {
    return "completed";
  }
  // "failed" runs are excluded from both categories
  return null;
};

// Group preview runs by PR, with the most recent run as the "latestRun"
const groupPreviewRunsByPr = (
  runs: PreviewRunWithConfig[]
): Map<string, PreviewRunGroup> => {
  const groups = new Map<string, PreviewRunGroup>();

  // Runs are already sorted by createdAt desc from the API
  for (const run of runs) {
    const key = `${run.repoFullName}#${run.prNumber}`;
    const existing = groups.get(key);

    if (!existing) {
      groups.set(key, {
        key,
        repoFullName: run.repoFullName,
        prNumber: run.prNumber,
        prUrl: run.prUrl,
        latestRun: run,
        olderRuns: [],
      });
    } else {
      existing.olderRuns.push(run);
    }
  }

  return groups;
};

const categorizePreviewRuns = (
  runs: PreviewRunWithConfig[] | undefined
): Record<PreviewCategoryKey, PreviewRunGroup[]> | null => {
  if (!runs) {
    return null;
  }

  // First group all runs by PR
  const groups = groupPreviewRunsByPr(runs);

  // Then categorize groups by the status of the latest run
  const buckets = createEmptyPreviewCategoryBuckets();
  for (const group of groups.values()) {
    const key = getPreviewCategory(group.latestRun);
    // Skip groups where the latest run doesn't belong to any category (e.g., failed runs)
    if (key !== null) {
      buckets[key].push(group);
    }
  }

  // Sort groups by the latest run's createdAt
  for (const key of PREVIEW_CATEGORY_ORDER) {
    buckets[key].sort((a, b) =>
      (b.latestRun.createdAt ?? 0) - (a.latestRun.createdAt ?? 0)
    );
  }

  return buckets;
};

const createCollapsedPreviewCategoryState = (
  defaultValue = false
): Record<PreviewCategoryKey, boolean> => ({
  in_progress: defaultValue,
  completed: defaultValue,
});

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
  const pinnedData = useQuery(api.tasks.getPinned, { teamSlugOrId });
  const previewRuns = useQuery(api.previewRuns.listByTeam, { teamSlugOrId });
  const [tab, setTab] = useState<"all" | "archived" | "previews">("all");

  const categorizedTasks = useMemo(() => {
    const categorized = categorizeTasks(allTasks);
    if (categorized && pinnedData) {
      // Filter pinned tasks out from other categories
      const pinnedTaskIds = new Set(pinnedData.map(t => t._id));

      for (const key of CATEGORY_ORDER) {
        if (key !== 'pinned') {
          categorized[key] = categorized[key].filter(t => !pinnedTaskIds.has(t._id));
        }
      }

      // Add pinned tasks to the pinned category (already sorted by the API)
      categorized.pinned = pinnedData;
    }
    return categorized;
  }, [allTasks, pinnedData]);
  const categoryBuckets = categorizedTasks ?? createEmptyCategoryBuckets();
  const collapsedStorageKey = useMemo(
    () => `dashboard-collapsed-categories-${teamSlugOrId}`,
    [teamSlugOrId]
  );
  const defaultCollapsedState = useMemo(
    () => createCollapsedCategoryState(),
    []
  );
  const [collapsedCategories, setCollapsedCategories] = useLocalStorage<
    Record<TaskCategoryKey, boolean>
  >({
    key: collapsedStorageKey,
    defaultValue: defaultCollapsedState,
    getInitialValueInEffect: true,
  });

  const toggleCategoryCollapse = useCallback((categoryKey: TaskCategoryKey) => {
    setCollapsedCategories((prev) => ({
      ...prev,
      [categoryKey]: !prev[categoryKey],
    }));
  }, [setCollapsedCategories]);

  // Preview runs categorization
  const categorizedPreviewRuns = useMemo(
    () => categorizePreviewRuns(previewRuns),
    [previewRuns]
  );
  const previewCategoryBuckets = categorizedPreviewRuns ?? createEmptyPreviewCategoryBuckets();

  const collapsedPreviewStorageKey = useMemo(
    () => `dashboard-collapsed-preview-categories-${teamSlugOrId}`,
    [teamSlugOrId]
  );
  const defaultCollapsedPreviewState = useMemo(
    () => createCollapsedPreviewCategoryState(),
    []
  );
  const [collapsedPreviewCategories, setCollapsedPreviewCategories] = useLocalStorage<
    Record<PreviewCategoryKey, boolean>
  >({
    key: collapsedPreviewStorageKey,
    defaultValue: defaultCollapsedPreviewState,
    getInitialValueInEffect: true,
  });

  const togglePreviewCategoryCollapse = useCallback((categoryKey: PreviewCategoryKey) => {
    setCollapsedPreviewCategories((prev) => ({
      ...prev,
      [categoryKey]: !prev[categoryKey],
    }));
  }, [setCollapsedPreviewCategories]);

  // State for expanded preview groups (PRs with older runs)
  const [expandedPreviewGroups, setExpandedPreviewGroups] = useState<Record<string, boolean>>({});

  const togglePreviewGroup = useCallback((groupKey: string) => {
    setExpandedPreviewGroups((prev) => ({
      ...prev,
      [groupKey]: !prev[groupKey],
    }));
  }, []);

  return (
    <div className="mt-6 w-full">
      <div className="mb-3 px-4">
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
              (tab === "previews"
                ? "text-neutral-900 dark:text-neutral-100"
                : "text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200")
            }
            onMouseDown={() => setTab("previews")}
            onClick={() => setTab("previews")}
          >
            Previews
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
      <div className="flex flex-col gap-1 w-full">
        {tab === "archived" ? (
          archivedTasks === undefined ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 pl-4 select-none">
              Loading...
            </div>
          ) : archivedTasks.length === 0 ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 pl-4 select-none">
              No archived tasks
            </div>
          ) : (
            archivedTasks.map((task) => (
              <TaskItem
                key={task._id}
                task={task}
                teamSlugOrId={teamSlugOrId}
              />
            ))
          )
        ) : tab === "previews" ? (
          previewRuns === undefined ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 pl-4 select-none">
              Loading...
            </div>
          ) : previewRuns.length === 0 ? (
            <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 pl-4 select-none">
              No preview runs
            </div>
          ) : (
            <div className="mt-1 w-full flex flex-col space-y-[-1px] transform -translate-y-px">
              {PREVIEW_CATEGORY_ORDER.map((categoryKey) => (
                <PreviewCategorySection
                  key={categoryKey}
                  categoryKey={categoryKey}
                  previewGroups={previewCategoryBuckets[categoryKey]}
                  teamSlugOrId={teamSlugOrId}
                  collapsed={Boolean(collapsedPreviewCategories[categoryKey])}
                  onToggle={togglePreviewCategoryCollapse}
                  expandedGroups={expandedPreviewGroups}
                  onToggleGroup={togglePreviewGroup}
                />
              ))}
            </div>
          )
        ) : allTasks === undefined ? (
          <div className="text-sm text-neutral-500 dark:text-neutral-400 py-2 pl-4 select-none">
            Loading...
          </div>
        ) : (
          <div className="mt-1 w-full flex flex-col space-y-[-1px] transform -translate-y-px">
            {CATEGORY_ORDER.map((categoryKey) => {
              // Don't render the pinned category if it's empty
              if (categoryKey === 'pinned' && categoryBuckets[categoryKey].length === 0) {
                return null;
              }
              return (
                <TaskCategorySection
                  key={categoryKey}
                  categoryKey={categoryKey}
                  tasks={categoryBuckets[categoryKey]}
                  teamSlugOrId={teamSlugOrId}
                  collapsed={Boolean(collapsedCategories[categoryKey])}
                  onToggle={toggleCategoryCollapse}
                />
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
});

function TaskCategorySection({
  categoryKey,
  tasks,
  teamSlugOrId,
  collapsed,
  onToggle,
}: {
  categoryKey: TaskCategoryKey;
  tasks: Doc<"tasks">[];
  teamSlugOrId: string;
  collapsed: boolean;
  onToggle: (key: TaskCategoryKey) => void;
}) {
  const meta = CATEGORY_META[categoryKey];
  const handleToggle = useCallback(
    () => onToggle(categoryKey),
    [categoryKey, onToggle]
  );
  const contentId = `task-category-${categoryKey}`;
  const toggleLabel = collapsed
    ? `Expand ${meta.title}`
    : `Collapse ${meta.title}`;
  return (
    <div className="w-full">
      <div
        className="sticky top-0 z-10 flex w-full border-y border-neutral-200 dark:border-neutral-900 bg-neutral-100 dark:bg-neutral-800 select-none"
        onDoubleClick={handleToggle}
      >
        <div className="flex w-full items-center pr-4">
          <button
            type="button"
            onClick={handleToggle}
            aria-label={toggleLabel}
            aria-expanded={!collapsed}
            aria-controls={contentId}
            className="flex h-9 w-9 items-center justify-center text-neutral-500 hover:text-black dark:text-neutral-400 dark:hover:text-neutral-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-300 dark:focus-visible:outline-neutral-700 transition-colors"
          >
            <ChevronRight
              className={clsx(
                "h-3 w-3 transition-transform duration-200",
                !collapsed && "rotate-90"
              )}
              aria-hidden="true"
            />
          </button>
          <div className="flex items-center gap-2 text-xs font-medium tracking-tight text-neutral-900 dark:text-neutral-100">
            <span>{meta.title}</span>
            <span className="text-xs text-neutral-500 dark:text-neutral-400">
              {tasks.length}
            </span>
          </div>
        </div>
      </div>
      {collapsed ? null : tasks.length > 0 ? (
        <div id={contentId} className="flex flex-col w-full">
          {tasks.map((task) => (
            <TaskItem key={task._id} task={task} teamSlugOrId={teamSlugOrId} />
          ))}
        </div>
      ) : (
        <div className="flex w-full items-center px-4 py-3">
          <p className="pl-5 text-xs text-neutral-500 dark:text-neutral-400 select-none">
            {meta.emptyLabel}
          </p>
        </div>
      )}
    </div>
  );
}

function PreviewCategorySection({
  categoryKey,
  previewGroups,
  teamSlugOrId,
  collapsed,
  onToggle,
  expandedGroups,
  onToggleGroup,
}: {
  categoryKey: PreviewCategoryKey;
  previewGroups: PreviewRunGroup[];
  teamSlugOrId: string;
  collapsed: boolean;
  onToggle: (key: PreviewCategoryKey) => void;
  expandedGroups: Record<string, boolean>;
  onToggleGroup: (groupKey: string) => void;
}) {
  const meta = PREVIEW_CATEGORY_META[categoryKey];
  const handleToggle = useCallback(
    () => onToggle(categoryKey),
    [categoryKey, onToggle]
  );
  const contentId = `preview-category-${categoryKey}`;
  const toggleLabel = collapsed
    ? `Expand ${meta.title}`
    : `Collapse ${meta.title}`;

  // Count total PRs (groups)
  const groupCount = previewGroups.length;

  return (
    <div className="w-full">
      <div
        className="sticky top-0 z-10 flex w-full border-y border-neutral-200 dark:border-neutral-900 bg-neutral-100 dark:bg-neutral-800 select-none"
        onDoubleClick={handleToggle}
      >
        <div className="flex w-full items-center pr-4">
          <button
            type="button"
            onClick={handleToggle}
            aria-label={toggleLabel}
            aria-expanded={!collapsed}
            aria-controls={contentId}
            className="flex h-9 w-9 items-center justify-center text-neutral-500 hover:text-black dark:text-neutral-400 dark:hover:text-neutral-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-300 dark:focus-visible:outline-neutral-700 transition-colors"
          >
            <ChevronRight
              className={clsx(
                "h-3 w-3 transition-transform duration-200",
                !collapsed && "rotate-90"
              )}
              aria-hidden="true"
            />
          </button>
          <div className="flex items-center gap-2 text-xs font-medium tracking-tight text-neutral-900 dark:text-neutral-100">
            <span>{meta.title}</span>
            <span className="text-xs text-neutral-500 dark:text-neutral-400">
              {groupCount}
            </span>
          </div>
        </div>
      </div>
      {collapsed ? null : groupCount > 0 ? (
        <div id={contentId} className="flex flex-col w-full">
          {previewGroups.map((group) => (
            <PreviewGroupItem
              key={group.key}
              group={group}
              teamSlugOrId={teamSlugOrId}
              isExpanded={expandedGroups[group.key] ?? false}
              onToggle={() => onToggleGroup(group.key)}
            />
          ))}
        </div>
      ) : (
        <div className="flex w-full items-center px-4 py-3">
          <p className="pl-5 text-xs text-neutral-500 dark:text-neutral-400 select-none">
            {meta.emptyLabel}
          </p>
        </div>
      )}
    </div>
  );
}

// Component for displaying a preview group (PR) with expandable older runs
function PreviewGroupItem({
  group,
  teamSlugOrId,
  isExpanded,
  onToggle,
}: {
  group: PreviewRunGroup;
  teamSlugOrId: string;
  isExpanded: boolean;
  onToggle: () => void;
}) {
  const hasOlderRuns = group.olderRuns.length > 0;

  return (
    <div className="w-full">
      {/* Latest run - always visible */}
      <div className="relative">
        <PreviewItem
          previewRun={group.latestRun}
          teamSlugOrId={teamSlugOrId}
        />
        {/* Expand/collapse button for older runs */}
        {hasOlderRuns && (
          <button
            type="button"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onToggle();
            }}
            className="absolute left-1 top-1/2 -translate-y-1/2 flex items-center justify-center w-5 h-5 rounded hover:bg-neutral-200/60 dark:hover:bg-neutral-700/60 transition-colors"
            aria-label={isExpanded ? "Collapse previous runs" : `Show ${group.olderRuns.length} previous run${group.olderRuns.length === 1 ? "" : "s"}`}
            aria-expanded={isExpanded}
          >
            <ChevronRight
              className={clsx(
                "h-3 w-3 text-neutral-400 dark:text-neutral-500 transition-transform duration-200",
                isExpanded && "rotate-90"
              )}
              aria-hidden="true"
            />
          </button>
        )}
      </div>

      {/* Older runs - collapsible */}
      {hasOlderRuns && isExpanded && (
        <div className="relative pl-6 border-l-2 border-neutral-200 dark:border-neutral-700 ml-3">
          <div className="absolute -left-[7px] top-0 text-[9px] text-neutral-400 dark:text-neutral-500 bg-white dark:bg-neutral-900 px-0.5 select-none">
            {group.olderRuns.length} older
          </div>
          {group.olderRuns.map((run) => (
            <div key={run._id} className="opacity-60 hover:opacity-100 transition-opacity">
              <PreviewItem
                previewRun={run}
                teamSlugOrId={teamSlugOrId}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
