import { useState, useMemo } from "react";
import { formatDistanceToNow } from "date-fns";
import { Video, Play, Clock, FileVideo } from "lucide-react";
import { cn } from "@/lib/utils";
import { VideoPlayerDialog } from "./VideoPlayer";
import type { Id } from "@cmux/convex/dataModel";

// Types for video recordings (matching Convex schema)
type VideoRecordingStatus = "recording" | "processing" | "completed" | "failed";

interface VideoCheckpoint {
  timestampMs: number;
  label: string;
  description?: string;
  type?: "commit" | "command" | "file_change" | "error" | "milestone" | "manual";
}

interface VideoRecording {
  _id: Id<"taskRunVideoRecordings">;
  taskId: Id<"tasks">;
  runId: Id<"taskRuns">;
  videoUrl: string | null;
  mimeType: string;
  durationMs?: number;
  fileSizeBytes?: number;
  checkpoints: VideoCheckpoint[];
  status: VideoRecordingStatus;
  error?: string;
  commitSha?: string;
  recordingStartedAt: number;
  recordingCompletedAt?: number;
}

interface RunVideoGalleryProps {
  videoRecordings: VideoRecording[];
  highlightedRecordingId?: Id<"taskRunVideoRecordings"> | null;
}

const STATUS_LABELS: Record<VideoRecordingStatus, string> = {
  recording: "Recording",
  processing: "Processing",
  completed: "Completed",
  failed: "Failed",
};

const STATUS_STYLES: Record<VideoRecordingStatus, string> = {
  recording:
    "bg-blue-100/70 text-blue-700 dark:bg-blue-950/60 dark:text-blue-300",
  processing:
    "bg-amber-100/70 text-amber-700 dark:bg-amber-950/60 dark:text-amber-300",
  completed:
    "bg-emerald-100/70 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed:
    "bg-rose-100/70 text-rose-700 dark:bg-rose-950/60 dark:text-rose-300",
};

// Format duration in MM:SS or HH:MM:SS
function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}:${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
  }
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

// Format file size
function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function RunVideoGallery({
  videoRecordings,
  highlightedRecordingId,
}: RunVideoGalleryProps) {
  const [selectedRecording, setSelectedRecording] = useState<VideoRecording | null>(null);

  const sortedRecordings = useMemo(
    () =>
      [...videoRecordings].sort((a, b) => {
        if (a.recordingStartedAt === b.recordingStartedAt) {
          return a._id.localeCompare(b._id);
        }
        return b.recordingStartedAt - a.recordingStartedAt; // Most recent first
      }),
    [videoRecordings]
  );

  const effectiveHighlight =
    highlightedRecordingId ?? sortedRecordings[0]?._id ?? null;

  if (sortedRecordings.length === 0) {
    return null;
  }

  return (
    <section className="border-b border-neutral-200 bg-neutral-50/60 dark:border-neutral-800 dark:bg-neutral-950/40">
      <div className="px-3.5 pt-3 pb-2 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Video className="h-4 w-4 text-neutral-500 dark:text-neutral-400" />
          <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
            Session Recordings
          </h2>
        </div>
        <span className="text-xs text-neutral-600 dark:text-neutral-400">
          {sortedRecordings.length}{" "}
          {sortedRecordings.length === 1 ? "recording" : "recordings"}
        </span>
      </div>
      <div className="px-3.5 pb-4 space-y-3">
        {sortedRecordings.map((recording) => {
          const recordedAtDate = new Date(recording.recordingStartedAt);
          const relativeRecordedAt = formatDistanceToNow(recordedAtDate, {
            addSuffix: true,
          });
          const shortCommit = recording.commitSha?.slice(0, 12);
          const isHighlighted = effectiveHighlight === recording._id;
          const isPlayable = recording.status === "completed" && recording.videoUrl;

          return (
            <article
              key={recording._id}
              className={cn(
                "rounded-xl border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950/70 p-3 transition-shadow",
                isHighlighted &&
                  "border-emerald-400/70 dark:border-emerald-400/60 shadow-[0_0_0_1px_rgba(16,185,129,0.25)]"
              )}
            >
              <div className="flex flex-wrap items-center gap-2 mb-3">
                <span
                  className={cn(
                    "px-2 py-0.5 text-xs font-medium rounded-full",
                    STATUS_STYLES[recording.status]
                  )}
                >
                  {STATUS_LABELS[recording.status]}
                </span>
                {isHighlighted && (
                  <span className="px-2 py-0.5 text-xs font-medium rounded-full bg-emerald-100/80 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-300">
                    Latest
                  </span>
                )}
                <span
                  className="text-xs text-neutral-600 dark:text-neutral-400"
                  title={recordedAtDate.toLocaleString()}
                >
                  {relativeRecordedAt}
                </span>
                {shortCommit && (
                  <span className="text-xs font-mono text-neutral-600 dark:text-neutral-400">
                    {shortCommit.toLowerCase()}
                  </span>
                )}
              </div>

              {recording.error && (
                <p className="mb-3 text-xs text-rose-600 dark:text-rose-400">
                  {recording.error}
                </p>
              )}

              {isPlayable ? (
                <button
                  type="button"
                  onClick={() => setSelectedRecording(recording)}
                  className="group relative w-full aspect-video bg-neutral-100 dark:bg-neutral-900 rounded-lg overflow-hidden border border-neutral-200 dark:border-neutral-700 hover:border-emerald-400 dark:hover:border-emerald-500 transition-colors"
                >
                  {/* Video preview thumbnail (could be generated or first frame) */}
                  <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-800 to-neutral-900">
                    <FileVideo className="h-12 w-12 text-neutral-600" />
                  </div>

                  {/* Play button overlay */}
                  <div className="absolute inset-0 flex items-center justify-center bg-black/30 opacity-0 group-hover:opacity-100 transition-opacity">
                    <div className="w-16 h-16 rounded-full bg-emerald-500/90 flex items-center justify-center shadow-lg">
                      <Play className="h-8 w-8 text-white ml-1" />
                    </div>
                  </div>

                  {/* Duration badge */}
                  {recording.durationMs && (
                    <div className="absolute bottom-2 right-2 px-2 py-1 bg-black/80 text-white text-xs font-mono rounded flex items-center gap-1">
                      <Clock className="h-3 w-3" />
                      {formatDuration(recording.durationMs)}
                    </div>
                  )}

                  {/* Chapters count badge */}
                  {recording.checkpoints.length > 0 && (
                    <div className="absolute bottom-2 left-2 px-2 py-1 bg-black/80 text-white text-xs rounded">
                      {recording.checkpoints.length} chapter{recording.checkpoints.length !== 1 ? "s" : ""}
                    </div>
                  )}
                </button>
              ) : (
                <div className="w-full aspect-video bg-neutral-100 dark:bg-neutral-900 rounded-lg flex items-center justify-center border border-neutral-200 dark:border-neutral-700">
                  {recording.status === "recording" ? (
                    <div className="flex flex-col items-center gap-2 text-blue-500">
                      <div className="relative">
                        <div className="w-3 h-3 bg-red-500 rounded-full animate-pulse" />
                        <div className="absolute inset-0 w-3 h-3 bg-red-500 rounded-full animate-ping" />
                      </div>
                      <span className="text-sm">Recording in progress...</span>
                    </div>
                  ) : recording.status === "processing" ? (
                    <div className="flex flex-col items-center gap-2 text-amber-500">
                      <div className="h-5 w-5 animate-spin rounded-full border-2 border-amber-500 border-t-transparent" />
                      <span className="text-sm">Processing video...</span>
                    </div>
                  ) : (
                    <span className="text-sm text-neutral-500">
                      Video not available
                    </span>
                  )}
                </div>
              )}

              {/* Metadata row */}
              <div className="mt-2 flex items-center gap-3 text-xs text-neutral-500 dark:text-neutral-400">
                {recording.durationMs && (
                  <span className="flex items-center gap-1">
                    <Clock className="h-3 w-3" />
                    {formatDuration(recording.durationMs)}
                  </span>
                )}
                {recording.fileSizeBytes && (
                  <span>{formatFileSize(recording.fileSizeBytes)}</span>
                )}
                {recording.checkpoints.length > 0 && (
                  <span>
                    {recording.checkpoints.length} checkpoint{recording.checkpoints.length !== 1 ? "s" : ""}
                  </span>
                )}
              </div>
            </article>
          );
        })}
      </div>

      {/* Video player dialog */}
      {selectedRecording && (
        <VideoPlayerDialog
          recording={selectedRecording}
          open={!!selectedRecording}
          onOpenChange={(open) => {
            if (!open) setSelectedRecording(null);
          }}
        />
      )}
    </section>
  );
}

export default RunVideoGallery;
