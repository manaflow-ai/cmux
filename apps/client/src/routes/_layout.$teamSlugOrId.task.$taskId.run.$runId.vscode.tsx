import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "convex/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import z from "zod";
import type { PersistentIframeStatus } from "@/components/persistent-iframe";
import { PersistentWebView } from "@/components/persistent-webview";
import { getTaskRunPersistKey } from "@/lib/persistent-webview-keys";
import { WorkspaceLoadingIndicator } from "@/components/workspace-loading-indicator";
import { getWorkspaceUrl } from "@/lib/workspace-url";
import {
  preloadTaskRunIframes,
  TASK_RUN_IFRAME_ALLOW,
  TASK_RUN_IFRAME_SANDBOX,
} from "../lib/preloadTaskRunIframes";
import { shouldUseServerIframePreflight } from "@/hooks/useIframePreflight";
import {
  localVSCodeServeWebQueryOptions,
  useLocalVSCodeServeWebQuery,
} from "@/queries/local-vscode-serve-web";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { ResumeWorkspaceOverlay } from "@/components/resume-workspace-overlay";
import { useElectronWindowFocus } from "@/hooks/useElectronWindowFocus";
import { useWebviewActions } from "@/hooks/useWebviewActions";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/vscode"
)({
  component: VSCodeComponent,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: async (opts) => {
    convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.get,
      args: { teamSlugOrId: opts.params.teamSlugOrId, id: opts.params.runId },
    });

    void (async () => {
      const [result, localServeWeb] = await Promise.all([
        opts.context.queryClient.ensureQueryData(
          convexQuery(api.taskRuns.get, {
            teamSlugOrId: opts.params.teamSlugOrId,
            id: opts.params.runId,
          })
        ),
        opts.context.queryClient.ensureQueryData(
          localVSCodeServeWebQueryOptions()
        ),
      ]);
      if (result) {
        const workspaceUrl = getWorkspaceUrl(
          result.vscode?.workspaceUrl,
          result.vscode?.provider,
          localServeWeb.baseUrl
        );
        await preloadTaskRunIframes([
          {
            url: workspaceUrl ?? "",
            taskRunId: opts.params.runId,
          },
        ]);
      }
    })();
  },
});

function VSCodeComponent() {
  const { runId: taskRunId, teamSlugOrId } = Route.useParams();
  const localServeWeb = useLocalVSCodeServeWebQuery();
  const taskRun = useQuery(api.taskRuns.get, {
    teamSlugOrId,
    id: taskRunId,
  });

  // Extract stable values from taskRun to avoid re-renders when unrelated fields change
  const rawWorkspaceUrl = taskRun?.vscode?.workspaceUrl;
  const vsCodeProvider = taskRun?.vscode?.provider;
  const localServeWebBaseUrl = localServeWeb.data?.baseUrl;

  // Memoize the workspace URL to prevent unnecessary recalculations
  const workspaceUrl = useMemo(
    () => getWorkspaceUrl(rawWorkspaceUrl, vsCodeProvider, localServeWebBaseUrl),
    [rawWorkspaceUrl, vsCodeProvider, localServeWebBaseUrl]
  );

  const disablePreflight = useMemo(
    () => (rawWorkspaceUrl ? shouldUseServerIframePreflight(rawWorkspaceUrl) : false),
    [rawWorkspaceUrl]
  );

  const persistKey = getTaskRunPersistKey(taskRunId);
  const hasWorkspace = workspaceUrl !== null;
  const isLocalWorkspace = vsCodeProvider === "other";
  const webviewActions = useWebviewActions({ persistKey });

  // Track iframe status - use state for rendering but with stable callback
  const [iframeStatus, setIframeStatus] =
    useState<PersistentIframeStatus>("loading");
  const prevWorkspaceUrlRef = useRef<string | null>(null);

  // Only reset to loading when the URL actually changes to a different value
  // This prevents flickering when the URL reference changes but the value is the same
  useEffect(() => {
    if (workspaceUrl !== prevWorkspaceUrlRef.current) {
      // Only reset to loading if we're transitioning to a new URL
      // Don't reset if we're already loaded with the same URL
      if (workspaceUrl !== null && prevWorkspaceUrlRef.current !== null) {
        setIframeStatus("loading");
      }
      prevWorkspaceUrlRef.current = workspaceUrl;
    }
  }, [workspaceUrl]);

  // Stable callback for status changes - setIframeStatus is already stable
  const handleStatusChange = useCallback(
    (status: PersistentIframeStatus) => {
      setIframeStatus(status);
    },
    []
  );

  const onLoad = useCallback(() => {
    console.log(`Workspace view loaded for task run ${taskRunId}`);
    void webviewActions.focus();
  }, [taskRunId, webviewActions]);

  const onError = useCallback(
    (error: Error) => {
      console.error(
        `Failed to load workspace view for task run ${taskRunId}:`,
        error
      );
    },
    [taskRunId]
  );

  const loadingFallback = useMemo(
    () =>
      isLocalWorkspace ? null : (
        <WorkspaceLoadingIndicator variant="vscode" status="loading" />
      ),
    [isLocalWorkspace]
  );
  const errorFallback = useMemo(
    () => <WorkspaceLoadingIndicator variant="vscode" status="error" />,
    []
  );

  const isEditorBusy = !hasWorkspace || iframeStatus !== "loaded";

  const focusWebviewIfReady = useCallback(() => {
    if (!workspaceUrl) return;
    if (iframeStatus !== "loaded") return;
    void webviewActions.focus();
  }, [iframeStatus, webviewActions, workspaceUrl]);

  useEffect(() => {
    focusWebviewIfReady();
  }, [focusWebviewIfReady]);

  const handleElectronWindowFocus = useCallback(() => {
    void (async () => {
      const alreadyFocused = await webviewActions.isFocused();
      if (alreadyFocused) {
        return;
      }
      focusWebviewIfReady();
    })();
  }, [focusWebviewIfReady, webviewActions]);

  useElectronWindowFocus(handleElectronWindowFocus);

  return (
    <div className="flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        <div
          className="flex flex-row grow min-h-0 relative"
          aria-busy={isEditorBusy}
        >
          {workspaceUrl ? (
            <PersistentWebView
              persistKey={persistKey}
              src={workspaceUrl}
              className="grow flex"
              iframeClassName="select-none"
              sandbox={TASK_RUN_IFRAME_SANDBOX}
              allow={TASK_RUN_IFRAME_ALLOW}
              retainOnUnmount
              suspended={!hasWorkspace}
              preflight={!disablePreflight}
              onLoad={onLoad}
              onError={onError}
              fallback={loadingFallback}
              fallbackClassName="bg-neutral-50 dark:bg-black"
              errorFallback={errorFallback}
              errorFallbackClassName="bg-neutral-50/95 dark:bg-black/95"
              onStatusChange={handleStatusChange}
              loadTimeoutMs={60_000}
            />
          ) : (
            <div className="grow" />
          )}
          {!hasWorkspace && !isLocalWorkspace ? (
            <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
              <WorkspaceLoadingIndicator variant="vscode" status="loading" />
            </div>
          ) : null}
          {taskRun ? (
            <ResumeWorkspaceOverlay
              taskRun={taskRun}
              teamSlugOrId={teamSlugOrId}
            />
          ) : null}
        </div>
      </div>
    </div>
  );
}
