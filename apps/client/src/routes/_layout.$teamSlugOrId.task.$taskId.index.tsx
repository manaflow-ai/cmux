import { TaskRunChatPane } from "@/components/TaskRunChatPane";
import { TaskRunTerminalPane } from "@/components/TaskRunTerminalPane";
import { FloatingPane } from "@/components/floating-pane";
import { TaskDetailHeader } from "@/components/task-detail-header";
import type { PersistentIframeStatus } from "@/components/persistent-iframe";
import { PersistentWebView } from "@/components/persistent-webview";
import { WorkspaceLoadingIndicator } from "@/components/workspace-loading-indicator";
import { ResizableGrid } from "@/components/ResizableGrid";
import { TaskRunGitDiffPanel } from "@/components/TaskRunGitDiffPanel";
import { RenderPanel } from "@/components/TaskPanelFactory";
import { loadPanelConfig, savePanelConfig, getAvailablePanels, PANEL_LABELS } from "@/lib/panel-config";
import type { PanelConfig, PanelType } from "@/lib/panel-config";
import {
  getTaskRunBrowserPersistKey,
  getTaskRunPersistKey,
} from "@/lib/persistent-webview-keys";
import {
  toMorphVncUrl,
  toMorphXtermBaseUrl,
  toProxyWorkspaceUrl,
} from "@/lib/toProxyWorkspaceUrl";
import {
  TASK_RUN_IFRAME_ALLOW,
  TASK_RUN_IFRAME_SANDBOX,
  preloadTaskRunIframes,
} from "../lib/preloadTaskRunIframes";
import {
  createTerminalTab,
  terminalTabsQueryKey,
  terminalTabsQueryOptions,
  type TerminalTabId,
} from "@/queries/terminals";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Plus, Code2, Globe2, TerminalSquare, GitCompare, MessageCircle } from "lucide-react";
import z from "zod";

type TaskRunListItem = (typeof api.taskRuns.getByTask._returnType)[number];
type IframeStatusEntry = {
  status: PersistentIframeStatus;
  url: string | null;
};

type PanelPosition = "topLeft" | "topRight" | "bottomLeft" | "bottomRight";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
});

export const Route = createFileRoute("/_layout/$teamSlugOrId/task/$taskId/")({
  component: TaskDetailPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => ({
      taskId: params.taskId,
    }),
  },
  validateSearch: (search: Record<string, unknown>) => {
    const runId = typedZid("taskRuns").optional().parse(search.runId);
    return {
      runId,
    };
  },
  loader: async (opts) => {
    const { queryClient } = opts.context;

    const [taskRuns] = await Promise.all([
      queryClient.ensureQueryData(
        convexQuery(api.taskRuns.getByTask, {
          teamSlugOrId: opts.params.teamSlugOrId,
          taskId: opts.params.taskId,
        }),
      ),
      queryClient.ensureQueryData(
        convexQuery(api.tasks.getById, {
          teamSlugOrId: opts.params.teamSlugOrId,
          id: opts.params.taskId,
        }),
      ),
      queryClient.ensureQueryData(
        convexQuery(api.crown.getCrownEvaluation, {
          teamSlugOrId: opts.params.teamSlugOrId,
          taskId: opts.params.taskId,
        }),
      ),
    ]);

    if (!taskRuns?.length) {
      return;
    }

    const taskRunIndex = buildTaskRunIndex(taskRuns);
    const searchParams = new URLSearchParams(opts.location.search);
    const runIdParam = searchParams.get("runId");
    const parsedRunId = runIdParam
      ? typedZid("taskRuns").safeParse(runIdParam)
      : null;
    const selectedRun = parsedRunId?.success
      ? taskRunIndex.get(parsedRunId.data) ?? taskRuns[0]
      : taskRuns[0];

    const rawWorkspaceUrl = selectedRun?.vscode?.workspaceUrl ?? null;
    if (!rawWorkspaceUrl) {
      return;
    }

    const baseUrl = toMorphXtermBaseUrl(rawWorkspaceUrl);
    if (!baseUrl) {
      return;
    }

    const tabsKey = terminalTabsQueryKey(baseUrl, rawWorkspaceUrl);
    let tabs = queryClient.getQueryData<TerminalTabId[]>(tabsKey);

    if (!tabs) {
      try {
        tabs = await queryClient.ensureQueryData(
          terminalTabsQueryOptions({
            baseUrl,
            contextKey: rawWorkspaceUrl,
            enabled: true,
          }),
        );
      } catch (error) {
        console.error("Failed to preload terminal tabs", error);
      }
    }

    if (!tabs?.length) {
      try {
        const created = await createTerminalTab({
          baseUrl,
          request: {
            cmd: "tmux",
            args: ["new-session", "-A", "cmux"],
          },
        });
        tabs = [created.id];
      } catch (error) {
        console.error("Failed to create default tmux terminal", error);
        return;
      }
    }

    if (tabs) {
      queryClient.setQueryData<TerminalTabId[]>(tabsKey, tabs);
    }
  },
});

function buildTaskRunIndex(
  runs: TaskRunListItem[],
): Map<TaskRunListItem["_id"], TaskRunListItem> {
  const index = new Map<TaskRunListItem["_id"], TaskRunListItem>();
  const stack = [...runs];

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) {
      continue;
    }
    index.set(current._id, current);
    if (current.children?.length) {
      stack.push(...current.children);
    }
  }

  return index;
}

interface EmptyPanelSlotProps {
  position: PanelPosition;
  availablePanels: PanelType[];
  onAddPanel: (position: PanelPosition, panelType: PanelType) => void;
}

function EmptyPanelSlot({ position, availablePanels, onAddPanel }: EmptyPanelSlotProps) {
  const [isOpen, setIsOpen] = useState(false);

  const getPanelIcon = (panelType: PanelType) => {
    switch (panelType) {
      case "chat":
        return <MessageCircle className="size-4" />;
      case "workspace":
        return <Code2 className="size-4" />;
      case "terminal":
        return <TerminalSquare className="size-4" />;
      case "browser":
        return <Globe2 className="size-4" />;
      case "gitDiff":
        return <GitCompare className="size-4" />;
    }
  };

  return (
    <div className="flex h-full flex-col overflow-hidden rounded-lg border border-dashed border-neutral-300 bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-900">
      <div className="flex h-full items-center justify-center p-4">
        {availablePanels.length > 0 ? (
          <div className="relative">
            <button
              type="button"
              onClick={() => setIsOpen(!isOpen)}
              className="flex items-center gap-2 rounded-lg border border-neutral-300 bg-white px-4 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-800 dark:text-neutral-200 dark:hover:bg-neutral-700 transition-colors"
            >
              <Plus className="size-4" />
              Add Panel
            </button>
            {isOpen && (
              <>
                <div
                  className="fixed inset-0 z-[var(--z-overlay)]"
                  onClick={() => setIsOpen(false)}
                />
                <div className="absolute left-0 top-full z-[var(--z-popover)] mt-2 w-48 rounded-lg border border-neutral-200 bg-white shadow-lg dark:border-neutral-700 dark:bg-neutral-800">
                  {availablePanels.map((panelType) => (
                    <button
                      key={panelType}
                      type="button"
                      onClick={() => {
                        onAddPanel(position, panelType);
                        setIsOpen(false);
                      }}
                      className="flex w-full items-center gap-3 px-4 py-2 text-left text-sm text-neutral-700 hover:bg-neutral-100 dark:text-neutral-200 dark:hover:bg-neutral-700 first:rounded-t-lg last:rounded-b-lg transition-colors"
                    >
                      <div className="flex size-5 items-center justify-center rounded-full bg-neutral-200 text-neutral-700 dark:bg-neutral-700 dark:text-neutral-200">
                        {getPanelIcon(panelType)}
                      </div>
                      {PANEL_LABELS[panelType]}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        ) : (
          <p className="text-sm text-neutral-500 dark:text-neutral-400">
            All panels are in use
          </p>
        )}
      </div>
    </div>
  );
}

function TaskDetailPage() {
  const { taskId, teamSlugOrId } = Route.useParams();
  const search = Route.useSearch();
  const { data: task } = useSuspenseQuery(
    convexQuery(api.tasks.getById, {
      teamSlugOrId,
      id: taskId,
    }),
  );
  const { data: taskRuns } = useSuspenseQuery(
    convexQuery(api.taskRuns.getByTask, {
      teamSlugOrId,
      taskId,
    }),
  );
  const { data: crownEvaluation } = useSuspenseQuery(
    convexQuery(api.crown.getCrownEvaluation, {
      teamSlugOrId,
      taskId,
    }),
  );

  const [panelConfig, setPanelConfig] = useState<PanelConfig>(() => loadPanelConfig());
  const [expandedPanel, setExpandedPanel] = useState<PanelPosition | null>(null);
  const [iframeStatusByKey, setIframeStatusByKey] = useState<Record<string, IframeStatusEntry>>({});
  const previousSelectedRunIdRef = useRef<string | null>(null);

  const handleToggleExpand = useCallback((position: PanelPosition) => {
    setExpandedPanel((current) => (current === position ? null : position));
  }, []);

  const handlePanelSwap = useCallback((fromPosition: PanelPosition, toPosition: PanelPosition) => {
    // Use startTransition to mark this as a non-urgent update
    // This helps React keep the UI stable during the swap
    setPanelConfig(prev => {
      const newConfig = { ...prev };
      const temp = newConfig[fromPosition];
      newConfig[fromPosition] = newConfig[toPosition];
      newConfig[toPosition] = temp;
      savePanelConfig(newConfig);
      return newConfig;
    });

    // Trigger resize events after React completes the swap
    // Multiple RAF calls ensure all layout recalculations are done
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        window.dispatchEvent(new Event('resize'));
        // Third RAF to ensure iframes have repositioned
        requestAnimationFrame(() => {
          window.dispatchEvent(new Event('resize'));
        });
      });
    });
  }, []);

  const handlePanelClose = useCallback((position: PanelPosition) => {
    setExpandedPanel((current) => (current === position ? null : current));
    setPanelConfig(prev => {
      const newConfig = { ...prev };
      newConfig[position] = null;
      savePanelConfig(newConfig);
      return newConfig;
    });
    // Trigger resize event to help iframes reposition correctly
    // Use requestAnimationFrame to ensure React has finished re-rendering
    requestAnimationFrame(() => {
      window.dispatchEvent(new Event('resize'));
      // Double RAF to ensure layout is complete
      requestAnimationFrame(() => {
        window.dispatchEvent(new Event('resize'));
      });
    });
  }, []);

  const handleAddPanel = useCallback((position: PanelPosition, panelType: PanelType) => {
    setPanelConfig(prev => {
      const newConfig = { ...prev };
      newConfig[position] = panelType;
      savePanelConfig(newConfig);
      return newConfig;
    });
    // Trigger resize event to help iframes reposition correctly
    // Use requestAnimationFrame to ensure React has finished re-rendering
    requestAnimationFrame(() => {
      window.dispatchEvent(new Event('resize'));
      // Double RAF to ensure layout is complete
      requestAnimationFrame(() => {
        window.dispatchEvent(new Event('resize'));
      });
    });
  }, []);

  const taskRunIndex = useMemo(
    () => (taskRuns ? buildTaskRunIndex(taskRuns) : new Map()),
    [taskRuns],
  );

  const selectedRun = useMemo(() => {
    if (!taskRuns?.length) {
      return null;
    }
    const runFromSearch = search.runId
      ? taskRunIndex.get(search.runId) ?? null
      : null;
    if (runFromSearch) {
      return runFromSearch;
    }
    return taskRuns[0];
  }, [search.runId, taskRunIndex, taskRuns]);

  const selectedRunId = selectedRun?._id ?? null;
  useEffect(() => {
    const previousRunId = previousSelectedRunIdRef.current;
    if (previousRunId === selectedRunId) {
      return;
    }
    previousSelectedRunIdRef.current = selectedRunId ?? null;
    setExpandedPanel(null);
  }, [selectedRunId]);
  const headerTaskRunId = selectedRunId ?? taskRuns?.[0]?._id ?? null;

  const rawWorkspaceUrl = selectedRun?.vscode?.workspaceUrl ?? null;
  const workspaceUrl = rawWorkspaceUrl ? toProxyWorkspaceUrl(rawWorkspaceUrl) : null;
  const workspacePersistKey = selectedRunId
    ? getTaskRunPersistKey(selectedRunId)
    : null;

  useEffect(() => {
    if (selectedRunId && workspaceUrl) {
      void preloadTaskRunIframes([
        {
          url: workspaceUrl,
          taskRunId: selectedRunId,
        },
      ]);
    }
  }, [selectedRunId, workspaceUrl]);

  const updateIframeStatus = useCallback(
    (persistKey: string | null, url: string | null, status: PersistentIframeStatus) => {
      if (!persistKey) {
        return;
      }
      setIframeStatusByKey((prev) => {
        const current = prev[persistKey];
        if (current && current.status === status && current.url === url) {
          return prev;
        }
        if (current && current.status === "loaded" && status === "loading" && current.url === url) {
          return prev;
        }
        return {
          ...prev,
          [persistKey]: {
            status,
            url,
          },
        };
      });
    },
    [],
  );

  const handleWorkspaceStatusChange = useCallback(
    (status: PersistentIframeStatus) => {
      updateIframeStatus(workspacePersistKey, workspaceUrl, status);
    },
    [updateIframeStatus, workspacePersistKey, workspaceUrl],
  );

  const onEditorLoad = useCallback(() => {
    if (selectedRunId) {
      console.log(`Workspace view loaded for task run ${selectedRunId}`);
    }
  }, [selectedRunId]);

  const onEditorError = useCallback((error: Error) => {
    if (selectedRunId) {
      console.error(`Failed to load workspace view for task run ${selectedRunId}:`, error);
    }
  }, [selectedRunId]);

  const isLocalWorkspace = selectedRun?.vscode?.provider === "other";

  const editorLoadingFallback = useMemo(
    () =>
      isLocalWorkspace
        ? null
        : <WorkspaceLoadingIndicator variant="vscode" status="loading" />,
    [isLocalWorkspace],
  );
  const editorErrorFallback = useMemo(
    () => <WorkspaceLoadingIndicator variant="vscode" status="error" />,
    [],
  );

  const rawBrowserUrl = selectedRun?.vscode?.url ?? selectedRun?.vscode?.workspaceUrl ?? null;
  const browserUrl = useMemo(() => {
    if (!rawBrowserUrl) {
      return null;
    }
    return toMorphVncUrl(rawBrowserUrl);
  }, [rawBrowserUrl]);
  const browserPersistKey = selectedRunId
    ? getTaskRunBrowserPersistKey(selectedRunId)
    : null;
  const hasBrowserView = Boolean(browserUrl);
  const isMorphProvider = selectedRun?.vscode?.provider === "morph";

  const handleBrowserStatusChange = useCallback(
    (status: PersistentIframeStatus) => {
      updateIframeStatus(browserPersistKey, browserUrl, status);
    },
    [updateIframeStatus, browserPersistKey, browserUrl],
  );

  const editorStatus = workspacePersistKey
    ? iframeStatusByKey[workspacePersistKey]?.status ?? "loading"
    : "loading";
  const browserStatus = browserPersistKey
    ? iframeStatusByKey[browserPersistKey]?.status ?? "loading"
    : "loading";
  const isEditorBusy = Boolean(selectedRun) && (!workspaceUrl || editorStatus !== "loaded");
  const isBrowserBusy = Boolean(selectedRun) && (!hasBrowserView || browserStatus !== "loaded");

  const workspacePlaceholder = useMemo(() => {
    if (!taskRuns?.length) {
      return {
        title: "Workspace becomes available once a run starts.",
        description: "Run the task in a cloud workspace to launch VS Code.",
      }
    }

    return null;
  }, [taskRuns?.length]);

  const browserPlaceholder = useMemo(() => {
    if (!selectedRun) {
      if (taskRuns?.length) {
        return {
          title: "Select a run to open the browser preview.",
          description: "Pick a run with a workspace to inspect its live preview.",
        }
      }
    }

    return {
      title: "Browser preview becomes available once a run starts.",
      description: "Start a cloud workspace run to expose a live browser session.",
    }
  }, [selectedRun, taskRuns?.length]);

  const availablePanels = useMemo(() => getAvailablePanels(panelConfig), [panelConfig]);

  const panelProps = useMemo(
    () => ({
      task: task ?? null,
      taskRuns: taskRuns ?? null,
      crownEvaluation,
      workspaceUrl,
      workspacePersistKey,
      selectedRun: selectedRun ?? null,
      editorStatus,
      setEditorStatus: handleWorkspaceStatusChange,
      onEditorLoad,
      onEditorError,
      editorLoadingFallback,
      editorErrorFallback,
      isEditorBusy,
      workspacePlaceholder,
      rawWorkspaceUrl,
      browserUrl,
      browserPersistKey,
      browserStatus,
      setBrowserStatus: handleBrowserStatusChange,
      browserPlaceholder,
      isMorphProvider,
      isBrowserBusy,
      TaskRunChatPane,
      PersistentWebView,
      WorkspaceLoadingIndicator,
      TaskRunTerminalPane,
      TaskRunGitDiffPanel,
      TASK_RUN_IFRAME_ALLOW,
      TASK_RUN_IFRAME_SANDBOX,
      onClose: handlePanelClose,
    }), [
    task,
    taskRuns,
    crownEvaluation,
    workspaceUrl,
    workspacePersistKey,
    selectedRun,
    editorStatus,
    handleWorkspaceStatusChange,
    onEditorLoad,
    onEditorError,
    editorLoadingFallback,
    editorErrorFallback,
    isEditorBusy,
    workspacePlaceholder,
    rawWorkspaceUrl,
    browserUrl,
    browserPersistKey,
    browserStatus,
    handleBrowserStatusChange,
    browserPlaceholder,
    isMorphProvider,
    isBrowserBusy,
    handlePanelClose,
  ],
  );

  return (
    <FloatingPane>
      <div className="flex h-full min-h-0 flex-col bg-neutral-50 dark:bg-black">
        <TaskDetailHeader
          task={task}
          taskRuns={taskRuns}
          selectedRun={selectedRun}
          taskRunId={headerTaskRunId}
          teamSlugOrId={teamSlugOrId}
        />
        <div className="relative flex flex-1 min-h-0 px-1 py-1">
          {expandedPanel ? (
            <div
              aria-hidden
              className="absolute inset-0 z-40 rounded-lg bg-neutral-900/20 backdrop-blur-sm"
              onClick={() => setExpandedPanel(null)}
            />
          ) : null}
          <ResizableGrid
            storageKey="taskDetailGrid"
            defaultLeftWidth={50}
            defaultTopHeight={50}
            topLeft={
              panelConfig.topLeft ? (
                <RenderPanel
                  key={panelConfig.topLeft}
                  {...panelProps}
                  type={panelConfig.topLeft}
                  position="topLeft"
                  onSwap={handlePanelSwap}
                  onToggleExpand={handleToggleExpand}
                  isExpanded={expandedPanel === "topLeft"}
                  isAnyPanelExpanded={expandedPanel !== null}
                />
              ) : (
                <EmptyPanelSlot position="topLeft" availablePanels={availablePanels} onAddPanel={handleAddPanel} />
              )
            }
            topRight={
              panelConfig.topRight ? (
                <RenderPanel
                  key={panelConfig.topRight}
                  {...panelProps}
                  type={panelConfig.topRight}
                  position="topRight"
                  onSwap={handlePanelSwap}
                  onToggleExpand={handleToggleExpand}
                  isExpanded={expandedPanel === "topRight"}
                  isAnyPanelExpanded={expandedPanel !== null}
                />
              ) : (
                <EmptyPanelSlot position="topRight" availablePanels={availablePanels} onAddPanel={handleAddPanel} />
              )
            }
            bottomLeft={
              panelConfig.bottomLeft ? (
                <RenderPanel
                  key={panelConfig.bottomLeft}
                  {...panelProps}
                  type={panelConfig.bottomLeft}
                  position="bottomLeft"
                  onSwap={handlePanelSwap}
                  onToggleExpand={handleToggleExpand}
                  isExpanded={expandedPanel === "bottomLeft"}
                  isAnyPanelExpanded={expandedPanel !== null}
                />
              ) : (
                <EmptyPanelSlot position="bottomLeft" availablePanels={availablePanels} onAddPanel={handleAddPanel} />
              )
            }
            bottomRight={
              panelConfig.bottomRight ? (
                <RenderPanel
                  key={panelConfig.bottomRight}
                  {...panelProps}
                  type={panelConfig.bottomRight}
                  position="bottomRight"
                  onSwap={handlePanelSwap}
                  onToggleExpand={handleToggleExpand}
                  isExpanded={expandedPanel === "bottomRight"}
                  isAnyPanelExpanded={expandedPanel !== null}
                />
              ) : (
                <EmptyPanelSlot position="bottomRight" availablePanels={availablePanels} onAddPanel={handleAddPanel} />
              )
            }
          />
        </div>
      </div>
    </FloatingPane>
  );
}
