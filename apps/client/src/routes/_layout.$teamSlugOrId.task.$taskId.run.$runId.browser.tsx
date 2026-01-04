import { VncViewer, type VncConnectionStatus, type VncViewerHandle } from "@cmux/shared/components/vnc-viewer";
import { useVncRecordingSession } from "@cmux/shared/components/use-vnc-recording-session";
import { useAutoCheckpoints } from "@cmux/shared/components/use-auto-checkpoints";
import { WorkspaceLoadingIndicator } from "@/components/workspace-loading-indicator";
import { toMorphVncWebsocketUrl } from "@/lib/toProxyWorkspaceUrl";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { useCallback, useMemo, useRef, useState } from "react";
import z from "zod";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { useQuery } from "convex/react";
import { Video, Square, Circle } from "lucide-react";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/browser"
)({
  component: BrowserComponent,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => ({
      taskId: params.taskId,
      runId: params.runId,
    }),
  },
  loader: async (opts) => {
    convexQueryClient.convexClient.prewarmQuery({
      query: api.taskRuns.get,
      args: { teamSlugOrId: opts.params.teamSlugOrId, id: opts.params.runId },
    });
  },
});

function BrowserComponent() {
  const { runId: taskRunId, taskId, teamSlugOrId } = Route.useParams();
  const vncViewerRef = useRef<VncViewerHandle>(null);

  const taskRun = useQuery(api.taskRuns.get, {
    teamSlugOrId,
    id: taskRunId,
  });

  const vscodeInfo = taskRun?.vscode ?? null;
  const rawMorphUrl = vscodeInfo?.url ?? vscodeInfo?.workspaceUrl ?? null;
  const vncWebsocketUrl = useMemo(() => {
    if (!rawMorphUrl) {
      return null;
    }
    return toMorphVncWebsocketUrl(rawMorphUrl);
  }, [rawMorphUrl]);

  const hasBrowserView = Boolean(vncWebsocketUrl);
  const isMorphProvider = vscodeInfo?.provider === "morph";
  const showLoader = isMorphProvider && !hasBrowserView;

  const [vncStatus, setVncStatus] = useState<VncConnectionStatus>("disconnected");

  // Video recording session
  const recordingSession = useVncRecordingSession({
    teamSlugOrId,
    taskId,
    runId: taskRunId,
    onComplete: (completedRecordingId) => {
      console.log(`[Browser] Recording completed: ${completedRecordingId}`);
    },
    onError: (recordingError) => {
      console.error(`[Browser] Recording error:`, recordingError);
    },
  });

  // Auto-detect checkpoints from task run state changes
  useAutoCheckpoints({
    teamSlugOrId,
    runId: taskRunId,
    enabled: recordingSession.state.isRecording,
    onCheckpoint: recordingSession.addCheckpoint,
  });

  const handleStartRecording = useCallback(async () => {
    const canvas = vncViewerRef.current?.getCanvas();
    if (!canvas) {
      console.warn("[Browser] Cannot start recording: no canvas available");
      return;
    }
    await recordingSession.startSession(canvas);
  }, [recordingSession]);

  const handleStopRecording = useCallback(async () => {
    await recordingSession.stopSession();
  }, [recordingSession]);

  const overlayMessage = useMemo(() => {
    if (!isMorphProvider) {
      return "Browser preview is loading. Note that browser preview is only supported in cloud mode.";
    }
    if (!hasBrowserView) {
      return "Waiting for the workspace to expose a browser preview...";
    }
    return "Launching browser preview...";
  }, [hasBrowserView, isMorphProvider]);

  const onConnect = useCallback(() => {
    console.log(`Browser VNC connected for task run ${taskRunId}`);
  }, [taskRunId]);

  const onDisconnect = useCallback(
    (_rfb: unknown, detail: { clean: boolean }) => {
      console.log(
        `Browser VNC disconnected for task run ${taskRunId} (clean: ${detail.clean})`
      );
      // Stop recording if active when disconnecting
      if (recordingSession.state.isRecording) {
        recordingSession.stopSession().catch((stopErr: unknown) => {
          console.error("[Browser] Failed to stop recording on disconnect:", stopErr);
        });
      }
    },
    [taskRunId, recordingSession]
  );

  const loadingFallback = useMemo(
    () => <WorkspaceLoadingIndicator variant="browser" status="loading" />,
    []
  );
  const errorFallback = useMemo(
    () => <WorkspaceLoadingIndicator variant="browser" status="error" />,
    []
  );

  const isBrowserBusy = !hasBrowserView || vncStatus !== "connected";
  const canRecord = vncStatus === "connected" && !recordingSession.state.isUploading;

  // Format recording duration
  const formatDuration = (ms: number) => {
    const totalSeconds = Math.floor(ms / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${seconds.toString().padStart(2, "0")}`;
  };

  return (
    <div className="flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        <div
          className="flex flex-row grow min-h-0 relative"
          aria-busy={isBrowserBusy}
        >
          {vncWebsocketUrl ? (
            <VncViewer
              ref={vncViewerRef}
              url={vncWebsocketUrl}
              className="grow"
              background="#000000"
              scaleViewport
              autoConnect
              autoReconnect
              reconnectDelay={1000}
              maxReconnectDelay={30000}
              focusOnClick
              onConnect={onConnect}
              onDisconnect={onDisconnect}
              onStatusChange={setVncStatus}
              loadingFallback={loadingFallback}
              errorFallback={errorFallback}
            />
          ) : (
            <div className="grow" />
          )}

          {/* Recording controls overlay */}
          {canRecord && (
            <div className="absolute top-3 right-3 flex items-center gap-2">
              {recordingSession.state.isRecording ? (
                <>
                  {/* Recording indicator */}
                  <div className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-black/70 backdrop-blur-sm">
                    <Circle className="h-3 w-3 text-red-500 fill-red-500 animate-pulse" />
                    <span className="text-sm font-mono text-white">
                      {formatDuration(recordingSession.state.duration)}
                    </span>
                  </div>
                  {/* Stop button */}
                  <button
                    type="button"
                    onClick={handleStopRecording}
                    disabled={recordingSession.state.isUploading}
                    className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-red-600 hover:bg-red-700 text-white text-sm font-medium transition-colors disabled:opacity-50"
                  >
                    <Square className="h-3.5 w-3.5" />
                    {recordingSession.state.isUploading ? "Uploading..." : "Stop"}
                  </button>
                </>
              ) : (
                /* Start button */
                <button
                  type="button"
                  onClick={handleStartRecording}
                  className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-black/70 backdrop-blur-sm hover:bg-black/80 text-white text-sm font-medium transition-colors"
                >
                  <Video className="h-4 w-4" />
                  Record
                </button>
              )}
            </div>
          )}

          {/* Error message */}
          {recordingSession.state.error && (
            <div className="absolute bottom-3 right-3 px-3 py-2 rounded-lg bg-red-600/90 text-white text-sm max-w-xs">
              {recordingSession.state.error}
            </div>
          )}

          <div
            className={clsx(
              "absolute inset-0 flex items-center justify-center transition pointer-events-none",
              {
                "opacity-100": !hasBrowserView,
                "opacity-0": hasBrowserView,
              }
            )}
          >
            {showLoader ? (
              <WorkspaceLoadingIndicator variant="browser" status="loading" />
            ) : (
              <span className="text-sm text-neutral-500 dark:text-neutral-400 text-center px-4">
                {overlayMessage}
              </span>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
