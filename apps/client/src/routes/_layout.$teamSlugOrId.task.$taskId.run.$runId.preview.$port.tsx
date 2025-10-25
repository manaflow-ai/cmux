import { ElectronPreviewBrowser } from "@/components/electron-preview-browser";
import { getTaskRunPreviewPersistKey } from "@/lib/persistent-webview-keys";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useMemo, useState, useEffect, useRef } from "react";
import z from "zod";
import { TaskRunTerminalSession } from "@/components/task-run-terminal-session";
import { toMorphXtermBaseUrl } from "@/lib/toProxyWorkspaceUrl";
import {
  buildTmuxAttachRequest,
  createTerminalTab,
  terminalTabsQueryKey,
  terminalTabsQueryOptions,
  type TerminalTabId,
} from "@/queries/terminals";
import { useSuspenseQuery } from "@tanstack/react-query";
import { convexQuery } from "@convex-dev/react-query";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
  port: z.string(),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/preview/$port",
)({
  component: PreviewPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
        port: params.port,
      };
    },
  },
  loader: async (opts) => {
    const { params, context } = opts;
    const { teamSlugOrId, runId } = params;
    const { queryClient } = context;

    const taskRun = await queryClient.ensureQueryData(
      convexQuery(api.taskRuns.get, {
        teamSlugOrId,
        id: runId,
      })
    );

    const vscodeInfo = taskRun?.vscode;
    const rawMorphUrl = vscodeInfo?.url ?? vscodeInfo?.workspaceUrl ?? null;
    const isMorphProvider = vscodeInfo?.provider === "morph";

    if (!isMorphProvider || !rawMorphUrl) {
      return;
    }

    const baseUrl = toMorphXtermBaseUrl(rawMorphUrl);
    const tabsQueryKey = terminalTabsQueryKey(baseUrl, runId);

    const tabs = await queryClient.ensureQueryData(
      terminalTabsQueryOptions({
        baseUrl,
        contextKey: runId,
      })
    );

    if (tabs.length > 0) {
      return;
    }

    // Create terminal in background without blocking
    (async () => {
      try {
        // Attach to cmux session
        const created = await createTerminalTab({
          baseUrl,
          request: buildTmuxAttachRequest("cmux"),
        });

        queryClient.setQueryData<TerminalTabId[]>(tabsQueryKey, (current) => {
          if (!current || current.length === 0) {
            return [created.id];
          }
          if (current.includes(created.id)) {
            return current;
          }
          return [...current, created.id];
        });
      } catch (error) {
        console.error("Failed to auto-create tmux terminal", error);
      }
    })();
  },
});

function PreviewPage() {
  const { taskId, teamSlugOrId, runId, port } = Route.useParams();

  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });

  // Get the specific run
  const selectedRun = useMemo(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  // Find the service URL for the requested port
  const previewUrl = useMemo(() => {
    if (!selectedRun?.networking) return null;
    const portNum = parseInt(port, 10);
    const service = selectedRun.networking.find(
      (s) => s.port === portNum && s.status === "running",
    );
    return service?.url;
  }, [selectedRun, port]);

  const persistKey = useMemo(() => {
    return getTaskRunPreviewPersistKey(runId, port);
  }, [runId, port]);

  // Terminal setup
  const vscodeInfo = selectedRun?.vscode;
  const rawMorphUrl = vscodeInfo?.url ?? vscodeInfo?.workspaceUrl ?? null;
  const isMorphProvider = vscodeInfo?.provider === "morph";
  const baseUrl = useMemo(() => {
    if (!isMorphProvider || !rawMorphUrl) return null;
    return toMorphXtermBaseUrl(rawMorphUrl);
  }, [isMorphProvider, rawMorphUrl]);

  const terminalTabsQuery = useSuspenseQuery(
    terminalTabsQueryOptions({
      baseUrl,
      contextKey: runId,
      enabled: Boolean(baseUrl),
    })
  );

  const activeTerminalId = terminalTabsQuery.data?.[0] ?? null;

  // Terminal state - default open if preview URL is not available
  const [isTerminalVisible, setIsTerminalVisible] = useState(() => !previewUrl);

  // Update terminal visibility when preview URL changes
  useEffect(() => {
    if (!previewUrl) {
      setIsTerminalVisible(true);
    }
  }, [previewUrl]);

  const [terminalWidth, setTerminalWidth] = useState(400);
  const isResizingRef = useRef(false);
  const containerRef = useRef<HTMLDivElement>(null);

  const toggleTerminal = () => {
    setIsTerminalVisible((prev) => !prev);
  };

  const handleResizeStart = (e: React.MouseEvent) => {
    e.preventDefault();
    isResizingRef.current = true;
  };

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!isResizingRef.current || !containerRef.current) return;
      const rect = containerRef.current.getBoundingClientRect();
      const newWidth = rect.right - e.clientX;
      const minWidth = 300;
      const maxWidth = rect.width - 400;
      setTerminalWidth(Math.max(minWidth, Math.min(newWidth, maxWidth)));
    };

    const handleMouseUp = () => {
      isResizingRef.current = false;
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, []);

  const paneBorderRadius = 6;

  return (
    <div
      ref={containerRef}
      className="flex h-full flex-col bg-white dark:bg-neutral-950"
    >
      {previewUrl ? (
        <>
          <ElectronPreviewBrowser
            persistKey={persistKey}
            src={previewUrl}
            borderRadius={paneBorderRadius}
            terminalVisible={isTerminalVisible}
            onToggleTerminal={toggleTerminal}
            renderBelowAddressBar={() => (
              isTerminalVisible && baseUrl && activeTerminalId ? (
                <div
                  className="border-l border-neutral-200 dark:border-neutral-800 flex bg-white dark:bg-neutral-950 flex-shrink-0 relative"
                  style={{ width: `${terminalWidth}px` }}
                >
                  {/* Resize handle */}
                  <div
                    className="w-1 h-full absolute left-0 top-0 bg-neutral-200 dark:bg-neutral-800 hover:bg-neutral-300 dark:hover:bg-neutral-700 cursor-ew-resize z-10"
                    onMouseDown={handleResizeStart}
                  />
                  <div className="flex-1 min-h-0 pl-1">
                    <TaskRunTerminalSession
                      baseUrl={baseUrl}
                      terminalId={activeTerminalId}
                      isActive={true}
                    />
                  </div>
                </div>
              ) : null
            )}
          />
        </>
      ) : (
        <div className="flex h-full items-center justify-center">
          <div className="text-center">
            <p className="mb-2 text-sm text-neutral-500 dark:text-neutral-400">
              {selectedRun
                ? `Port ${port} is not available for this run`
                : "Loading..."}
            </p>
            {selectedRun?.networking && selectedRun.networking.length > 0 && (
              <div className="mt-4">
                <p className="mb-2 text-xs text-neutral-400 dark:text-neutral-500">
                  Available ports:
                </p>
                <div className="flex justify-center gap-2">
                  {selectedRun.networking
                    .filter((s) => s.status === "running")
                    .map((service) => (
                      <span
                        key={service.port}
                        className="rounded px-2 py-1 text-xs bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-200"
                      >
                        {service.port}
                      </span>
                    ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
