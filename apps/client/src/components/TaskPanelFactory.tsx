import React, { useState, useEffect, type ReactNode, useCallback } from "react";
import type { CSSProperties } from "react";
import {
  Code2,
  Globe2,
  TerminalSquare,
  GitCompare,
  GripVertical,
  X,
  Maximize2,
  Minimize2,
} from "lucide-react";
import clsx from "clsx";
import type { PanelType } from "@/lib/panel-config";
import { PANEL_LABELS } from "@/lib/panel-config";
import type { PersistentIframeStatus } from "@/components/persistent-iframe";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type { TaskRunWithChildren } from "@/types/task";
import type { TaskRunChatPaneProps } from "./TaskRunChatPane";
import type { PersistentWebViewProps } from "./persistent-webview";
import type { WorkspaceLoadingIndicatorProps } from "./workspace-loading-indicator";
import type { TaskRunTerminalPaneProps } from "./TaskRunTerminalPane";
import type { TaskRunGitDiffPanelProps } from "./TaskRunGitDiffPanel";

type PanelPosition = "topLeft" | "topRight" | "bottomLeft" | "bottomRight";

const PANEL_DRAG_START_EVENT = "cmux:panel-drag-start";
const PANEL_DRAG_END_EVENT = "cmux:panel-drag-end";

const dispatchPanelDragEvent = (event: string) => {
  if (typeof window === "undefined") {
    return;
  }
  window.dispatchEvent(new Event(event));
};


interface PanelFactoryProps {
  type: PanelType | null;
  position: PanelPosition;
  onSwap?: (fromPosition: PanelPosition, toPosition: PanelPosition) => void;
  onClose?: (position: PanelPosition) => void;
  onToggleExpand?: (position: PanelPosition) => void;
  isExpanded?: boolean;
  isAnyPanelExpanded?: boolean;
  // Chat panel props
  task?: Doc<"tasks"> | null;
  taskRuns?: TaskRunWithChildren[] | null;
  crownEvaluation?: {
    evaluatedAt?: number;
    winnerRunId?: Id<"taskRuns">;
    reason?: string;
  } | null;
  // Workspace panel props
  workspaceUrl?: string | null;
  workspacePersistKey?: string | null;
  selectedRun?: TaskRunWithChildren | null;
  editorStatus?: PersistentIframeStatus;
  setEditorStatus?: (status: PersistentIframeStatus) => void;
  onEditorLoad?: () => void;
  onEditorError?: (error: Error) => void;
  editorLoadingFallback?: ReactNode;
  editorErrorFallback?: ReactNode;
  isEditorBusy?: boolean;
  workspacePlaceholder?: {
    title: string;
    description?: string;
  } | null;
  // Terminal panel props
  rawWorkspaceUrl?: string | null;
  // Browser panel props
  browserUrl?: string | null;
  browserPersistKey?: string | null;
  browserStatus?: PersistentIframeStatus;
  setBrowserStatus?: (status: PersistentIframeStatus) => void;
  browserPlaceholder?: {
    title: string;
    description?: string;
  } | null;
  isMorphProvider?: boolean;
  isBrowserBusy?: boolean;
  // Additional components
  TaskRunChatPane?: React.ComponentType<TaskRunChatPaneProps>;
  PersistentWebView?: React.ComponentType<PersistentWebViewProps>;
  WorkspaceLoadingIndicator?: React.ComponentType<WorkspaceLoadingIndicatorProps>;
  TaskRunTerminalPane?: React.ComponentType<TaskRunTerminalPaneProps>;
  TaskRunGitDiffPanel?: React.ComponentType<TaskRunGitDiffPanelProps>;
  // Constants
  TASK_RUN_IFRAME_ALLOW?: string;
  TASK_RUN_IFRAME_SANDBOX?: string;
}

const RenderPanelComponent = (props: PanelFactoryProps): ReactNode => {
  const {
    type,
    position,
    onSwap,
    onClose,
    onToggleExpand,
    isExpanded = false,
    isAnyPanelExpanded = false,
  } = props;
  const [isDragOver, setIsDragOver] = useState(false);
  const [isDraggingSelf, setIsDraggingSelf] = useState(false);
  const [isPanelDragActive, setIsPanelDragActive] = useState(false);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const handleStart = () => {
      setIsPanelDragActive(true);
    };
    const handleEnd = () => {
      setIsPanelDragActive(false);
      setIsDragOver(false);
    };

    window.addEventListener(PANEL_DRAG_START_EVENT, handleStart);
    window.addEventListener(PANEL_DRAG_END_EVENT, handleEnd);

    return () => {
      window.removeEventListener(PANEL_DRAG_START_EVENT, handleStart);
      window.removeEventListener(PANEL_DRAG_END_EVENT, handleEnd);
    };
  }, []);

  // Control iframe wrapper visibility based on this panel's expansion state
  useEffect(() => {
    if (typeof document === "undefined" || !type) return;

    // Find the container div for this panel's content
    const container = document.querySelector(`[data-panel-position="${position}"]`);
    if (!container) return;

    // Find any iframe target within this panel
    const iframeTarget = container.querySelector('[data-iframe-target]') as HTMLElement;
    if (!iframeTarget) return;

    const iframeKey = iframeTarget.getAttribute('data-iframe-target');
    if (!iframeKey) return;

    // Find the corresponding iframe wrapper
    const wrapper = document.querySelector(`[data-iframe-key="${iframeKey}"]`) as HTMLElement;
    if (!wrapper) return;

    if (isAnyPanelExpanded && !isExpanded) {
      // Another panel is expanded - hide this iframe
      wrapper.style.visibility = "hidden";
      wrapper.style.pointerEvents = "none";
    } else {
      // This panel is expanded OR no panel is expanded - show iframe
      wrapper.style.visibility = "visible";
      wrapper.style.pointerEvents = "auto";
    }
  }, [type, position, isExpanded, isAnyPanelExpanded]);

  const handleDragStart = useCallback((e: React.DragEvent) => {
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", position);
    setIsDraggingSelf(true);

    // Disable pointer events on all iframes during drag
    const iframes = Array.from(document.querySelectorAll("iframe"));
    for (const el of iframes) {
      if (el instanceof HTMLIFrameElement) {
        const current = el.style.pointerEvents;
        el.dataset.prevPointerEvents = current ? current : "__unset__";
        el.style.pointerEvents = "none";
      }
    }

    dispatchPanelDragEvent(PANEL_DRAG_START_EVENT);
  }, [position]);

  const handleDragEnd = useCallback(() => {
    setIsDraggingSelf(false);
    setIsDragOver(false);

    // Restore pointer events on all iframes
    const iframes = Array.from(document.querySelectorAll("iframe"));
    for (const el of iframes) {
      if (el instanceof HTMLIFrameElement) {
        const prev = el.dataset.prevPointerEvents;
        if (prev !== undefined) {
          if (prev === "__unset__") {
            el.style.removeProperty("pointer-events");
          } else {
            el.style.pointerEvents = prev;
          }
          delete el.dataset.prevPointerEvents;
        } else {
          el.style.removeProperty("pointer-events");
        }
      }
    }

    dispatchPanelDragEvent(PANEL_DRAG_END_EVENT);
  }, []);

  const handleDragEnter = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(true);
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    const nextTarget = e.relatedTarget as Node | null;
    if (nextTarget && e.currentTarget.contains(nextTarget)) {
      return;
    }
    setIsDragOver(false);
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(false);
    const fromPosition = e.dataTransfer.getData("text/plain") as PanelPosition;
    if (fromPosition && fromPosition !== position && onSwap) {
      onSwap(fromPosition, position);
    }

    // Restore pointer events on all iframes after drop
    const iframes = Array.from(document.querySelectorAll("iframe"));
    for (const el of iframes) {
      if (el instanceof HTMLIFrameElement) {
        const prev = el.dataset.prevPointerEvents;
        if (prev !== undefined) {
          if (prev === "__unset__") {
            el.style.removeProperty("pointer-events");
          } else {
            el.style.pointerEvents = prev;
          }
          delete el.dataset.prevPointerEvents;
        } else {
          el.style.removeProperty("pointer-events");
        }
      }
    }

    dispatchPanelDragEvent(PANEL_DRAG_END_EVENT);
  }, [onSwap, position]);

  const showDropOverlay = isPanelDragActive && !isDraggingSelf && !isExpanded;

  const renderDropOverlay = () => {
    if (!showDropOverlay) {
      return null;
    }

    return (
      <div
        aria-hidden
        className={clsx(
          "pointer-events-auto absolute inset-0 z-10 rounded-lg",
          isDragOver ? "bg-blue-500/10 dark:bg-blue-400/15" : "bg-transparent"
        )}
        onDragEnter={(event) => {
          handleDragEnter(event);
          event.stopPropagation();
        }}
        onDragOver={(event) => {
          handleDragOver(event);
          event.stopPropagation();
        }}
        onDragLeave={(event) => {
          handleDragLeave(event);
          event.stopPropagation();
        }}
        onDrop={(event) => {
          handleDrop(event);
          event.stopPropagation();
        }}
      />
    );
  };

  const panelClassName = clsx(
    "flex h-full flex-col rounded-lg border bg-white shadow-sm transition-all duration-150 dark:bg-neutral-950",
    isDragOver
      ? "border-blue-500 dark:border-blue-400 ring-2 ring-blue-500/30 dark:ring-blue-400/30"
      : "border-neutral-200 dark:border-neutral-800",
    isExpanded
      ? "absolute inset-0 z-[999999] pointer-events-auto shadow-2xl ring-2 ring-blue-500/20 overflow-visible dark:ring-blue-400/20"
      : "relative pointer-events-auto overflow-hidden",
    isAnyPanelExpanded && !isExpanded ? "pointer-events-none opacity-40" : undefined,
  );

  const panelStyle: CSSProperties | undefined =
    isAnyPanelExpanded && !isExpanded ? { visibility: "hidden" } : undefined;

  const renderExpandButton = () => {
    if (!onToggleExpand) {
      return null;
    }
    const Icon = isExpanded ? Minimize2 : Maximize2;
    const label = isExpanded ? "Exit expanded view" : "Expand panel";
    return (
      <button
        type="button"
        onClick={() => onToggleExpand(position)}
        className="flex size-5 items-center justify-center rounded text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-700 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-200"
        title={label}
        aria-pressed={isExpanded}
        onDoubleClick={(event) => {
          event.stopPropagation();
        }}
      >
        <Icon className="size-3.5" />
      </button>
    );
  };

  const panelWrapper = (icon: ReactNode, title: string, content: ReactNode) => (
    <div
      className={panelClassName}
      style={panelStyle}
      data-panel-position={position}
      aria-hidden={isAnyPanelExpanded && !isExpanded ? true : undefined}
      onDragEnter={handleDragEnter}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
      onDoubleClick={() => {
        if (onToggleExpand) {
          onToggleExpand(position);
        }
      }}
    >
      {renderDropOverlay()}
      <div
        className={clsx(
          "flex items-center gap-1.5 border-b border-neutral-200 px-2 py-1 dark:border-neutral-800",
          isExpanded && "relative z-[100000000] pointer-events-auto"
        )}
        onDoubleClick={(event) => {
          event.stopPropagation();
          if (onToggleExpand) {
            onToggleExpand(position);
          }
        }}
      >
        <div
          draggable
          onDragStart={handleDragStart}
          onDragEnd={handleDragEnd}
          className={clsx(
            "flex flex-1 items-center gap-1.5 cursor-move group transition-opacity",
            isDraggingSelf && "opacity-60"
          )}
        >
          <GripVertical className="size-3.5 text-neutral-400 transition-colors group-hover:text-neutral-600 dark:text-neutral-500 dark:group-hover:text-neutral-300" />
          <div className="flex size-5 items-center justify-center rounded-full text-neutral-700 dark:text-neutral-200">
            {icon}
          </div>
          <h2 className="text-xs font-medium text-neutral-800 dark:text-neutral-100">
            {title}
          </h2>
        </div>
        {renderExpandButton()}
        {onClose && (
          <button
            type="button"
            onClick={() => onClose(position)}
            className="flex size-5 items-center justify-center rounded text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-700 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-200"
            title="Close panel"
            onDoubleClick={(event) => {
              event.stopPropagation();
            }}
          >
            <X className="size-3.5" />
          </button>
        )}
      </div>
      {content}
    </div>
  );

  switch (type) {
    case "chat": {
      const { task, taskRuns, crownEvaluation, TaskRunChatPane } = props;
      if (!TaskRunChatPane) return null;
      return (
        <div
          className={panelClassName}
          style={panelStyle}
          data-panel-position={position}
          aria-hidden={isAnyPanelExpanded && !isExpanded ? true : undefined}
          onDragEnter={handleDragEnter}
          onDragOver={handleDragOver}
          onDragLeave={handleDragLeave}
          onDrop={handleDrop}
          onDoubleClick={() => {
            if (onToggleExpand) {
              onToggleExpand(position);
            }
          }}
        >
          {renderDropOverlay()}
          <TaskRunChatPane
            key={task?._id}
            task={task}
            taskRuns={taskRuns}
            crownEvaluation={crownEvaluation}
            hideHeader={false}
            onDragStart={handleDragStart}
            onDragEnd={handleDragEnd}
            onClose={onClose ? () => onClose(position) : undefined}
            onToggleExpand={onToggleExpand ? () => onToggleExpand(position) : undefined}
            isExpanded={isExpanded}
            position={position}
          />
        </div>
      );
    }

    case "workspace": {
      const {
        workspaceUrl,
        workspacePersistKey,
        selectedRun,
        setEditorStatus,
        onEditorLoad,
        onEditorError,
        editorLoadingFallback,
        editorErrorFallback,
        isEditorBusy,
        workspacePlaceholder,
        PersistentWebView,
        WorkspaceLoadingIndicator,
        TASK_RUN_IFRAME_ALLOW,
        TASK_RUN_IFRAME_SANDBOX,
      } = props;

      if (!PersistentWebView || !WorkspaceLoadingIndicator) return null;
      const shouldShowWorkspaceLoader = Boolean(selectedRun) && !workspaceUrl;

      return panelWrapper(
        <Code2 className="size-3" aria-hidden />,
        PANEL_LABELS.workspace,
        <div className={clsx("relative flex-1", isExpanded && "h-full")} aria-busy={isEditorBusy}>
          {workspaceUrl && workspacePersistKey ? (
            <PersistentWebView
              key={workspacePersistKey}
              persistKey={workspacePersistKey}
              src={workspaceUrl}
              className="flex h-full"
              iframeClassName="select-none"
              allow={TASK_RUN_IFRAME_ALLOW}
              sandbox={TASK_RUN_IFRAME_SANDBOX}
              retainOnUnmount
              suspended={!selectedRun}
              onLoad={onEditorLoad}
              onError={onEditorError}
              fallback={editorLoadingFallback}
              fallbackClassName="bg-neutral-50 dark:bg-black"
              errorFallback={editorErrorFallback}
              errorFallbackClassName="bg-neutral-50/95 dark:bg-black/95"
              onStatusChange={setEditorStatus}
              loadTimeoutMs={60_000}
              isExpanded={isExpanded}
              isAnyPanelExpanded={isAnyPanelExpanded}
            />
          ) : shouldShowWorkspaceLoader ? (
            <div className="flex h-full items-center justify-center">
              <WorkspaceLoadingIndicator variant="vscode" status="loading" />
            </div>
          ) : workspacePlaceholder ? (
            <div className="flex h-full flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
              <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
                {workspacePlaceholder.title}
              </div>
              {workspacePlaceholder.description ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  {workspacePlaceholder.description}
                </p>
              ) : null}
            </div>
          ) : null}
        </div>
      );
    }

    case "terminal": {
      const { rawWorkspaceUrl, TaskRunTerminalPane } = props;
      if (!TaskRunTerminalPane) return null;

      return panelWrapper(
        <TerminalSquare className="size-3" aria-hidden />,
        PANEL_LABELS.terminal,
        <div className="flex-1 bg-black">
          <TaskRunTerminalPane
            key={rawWorkspaceUrl ?? "no-workspace"}
            workspaceUrl={rawWorkspaceUrl ?? null}
          />
        </div>
      );
    }

    case "browser": {
      const {
        browserUrl,
        browserPersistKey,
        setBrowserStatus,
        browserPlaceholder,
        selectedRun,
        isMorphProvider,
        isBrowserBusy,
        PersistentWebView,
        WorkspaceLoadingIndicator,
        TASK_RUN_IFRAME_ALLOW,
        TASK_RUN_IFRAME_SANDBOX,
      } = props;

      if (!PersistentWebView || !WorkspaceLoadingIndicator) return null;
      const shouldShowBrowserLoader = Boolean(selectedRun) && isMorphProvider && (!browserUrl || !browserPersistKey);

      return panelWrapper(
        <Globe2 className="size-3" aria-hidden />,
        PANEL_LABELS.browser,
        <div className={clsx("relative flex-1", isExpanded && "h-full")} aria-busy={isBrowserBusy}>
          {browserUrl && browserPersistKey ? (
            <PersistentWebView
              key={browserPersistKey}
              persistKey={browserPersistKey}
              src={browserUrl}
              className="flex h-full"
              iframeClassName="select-none"
              allow={TASK_RUN_IFRAME_ALLOW}
              sandbox={TASK_RUN_IFRAME_SANDBOX}
              retainOnUnmount
              onStatusChange={setBrowserStatus}
              fallback={
                <WorkspaceLoadingIndicator variant="browser" status="loading" />
              }
              fallbackClassName="bg-neutral-50 dark:bg-black"
              errorFallback={
                <WorkspaceLoadingIndicator variant="browser" status="error" />
              }
              errorFallbackClassName="bg-neutral-50/95 dark:bg-black/95"
              loadTimeoutMs={45_000}
              isExpanded={isExpanded}
              isAnyPanelExpanded={isAnyPanelExpanded}
            />
          ) : shouldShowBrowserLoader ? (
            <div className="flex h-full items-center justify-center">
              <WorkspaceLoadingIndicator variant="browser" status="loading" />
            </div>
          ) : browserPlaceholder ? (
            <div className="flex h-full flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
              <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
                {browserPlaceholder.title}
              </div>
              {browserPlaceholder.description ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  {browserPlaceholder.description}
                </p>
              ) : null}
            </div>
          ) : null}
        </div>
      );
    }

    case "gitDiff": {
      const { task, selectedRun, TaskRunGitDiffPanel } = props;
      if (!TaskRunGitDiffPanel) return null;

      return panelWrapper(
        <GitCompare className="size-3" aria-hidden />,
        PANEL_LABELS.gitDiff,
        <div className="flex-1 overflow-auto">
          <TaskRunGitDiffPanel key={selectedRun?._id} task={task} selectedRun={selectedRun} />
        </div>
      );
    }

    case null:
      return null;

    default:
      return null;
  }
};

// Memoize to prevent unnecessary re-renders during drag operations
// Only re-render when critical props actually change
export const RenderPanel = React.memo(RenderPanelComponent, (prevProps, nextProps) => {
  // Always re-render if type or position changes
  if (prevProps.type !== nextProps.type || prevProps.position !== nextProps.position) {
    return false;
  }

  // For iframe-based panels (workspace/browser), check persist keys
  if (prevProps.type === "workspace" || prevProps.type === "browser") {
    if (prevProps.workspacePersistKey !== nextProps.workspacePersistKey ||
      prevProps.browserPersistKey !== nextProps.browserPersistKey ||
      prevProps.workspaceUrl !== nextProps.workspaceUrl ||
      prevProps.workspacePlaceholder?.title !== nextProps.workspacePlaceholder?.title ||
      prevProps.workspacePlaceholder?.description !== nextProps.workspacePlaceholder?.description ||
      prevProps.browserUrl !== nextProps.browserUrl ||
      prevProps.browserPlaceholder?.title !== nextProps.browserPlaceholder?.title ||
      prevProps.browserPlaceholder?.description !== nextProps.browserPlaceholder?.description ||
      prevProps.selectedRun?._id !== nextProps.selectedRun?._id) {
      return false;
    }
  }

  // For terminal panel, check workspace URL
  if (prevProps.type === "terminal") {
    if (prevProps.rawWorkspaceUrl !== nextProps.rawWorkspaceUrl) {
      return false;
    }
  }

  // For chat panel, check task and run changes
  if (prevProps.type === "chat") {
    if (prevProps.task?._id !== nextProps.task?._id ||
      prevProps.taskRuns !== nextProps.taskRuns ||
      prevProps.crownEvaluation !== nextProps.crownEvaluation) {
      return false;
    }
  }

  // For gitDiff panel, check task and selectedRun changes
  if (prevProps.type === "gitDiff") {
    if (prevProps.task?._id !== nextProps.task?._id ||
      prevProps.selectedRun?._id !== nextProps.selectedRun?._id) {
      return false;
    }
  }

  // Check if callbacks changed (using reference equality)
  if (prevProps.onSwap !== nextProps.onSwap || prevProps.onClose !== nextProps.onClose) {
    return false;
  }

  if (prevProps.onToggleExpand !== nextProps.onToggleExpand) {
    return false;
  }

  if (prevProps.isExpanded !== nextProps.isExpanded ||
    prevProps.isAnyPanelExpanded !== nextProps.isAnyPanelExpanded) {
    return false;
  }

  // If we got here, props are effectively the same - skip re-render
  return true;
});
