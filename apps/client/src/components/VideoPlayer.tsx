import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { formatDistanceToNow } from "date-fns";
import * as Dialog from "@radix-ui/react-dialog";
import {
  Maximize2,
  Minimize2,
  Pause,
  Play,
  SkipBack,
  SkipForward,
  Volume2,
  VolumeX,
  X,
  List,
} from "lucide-react";
import { cn } from "@/lib/utils";
import type { Id } from "@cmux/convex/dataModel";

// Types for video recordings
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
  status: "recording" | "processing" | "completed" | "failed";
  error?: string;
  commitSha?: string;
  recordingStartedAt: number;
  recordingCompletedAt?: number;
}

interface VideoPlayerProps {
  recording: VideoRecording;
  className?: string;
  style?: CSSProperties;
  autoPlay?: boolean;
  onClose?: () => void;
}

// Speed options for playback
const SPEED_OPTIONS = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;
type PlaybackSpeed = (typeof SPEED_OPTIONS)[number];

// Format milliseconds to MM:SS or HH:MM:SS
function formatTime(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}:${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
  }
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

// Get icon for checkpoint type
function getCheckpointIcon(type?: VideoCheckpoint["type"]): string {
  switch (type) {
    case "commit":
      return "📝";
    case "command":
      return "⚡";
    case "file_change":
      return "📄";
    case "error":
      return "❌";
    case "milestone":
      return "🎯";
    case "manual":
      return "📌";
    default:
      return "📍";
  }
}

// Get color for checkpoint type
function getCheckpointColor(type?: VideoCheckpoint["type"]): string {
  switch (type) {
    case "commit":
      return "bg-emerald-500";
    case "command":
      return "bg-blue-500";
    case "file_change":
      return "bg-amber-500";
    case "error":
      return "bg-red-500";
    case "milestone":
      return "bg-purple-500";
    case "manual":
      return "bg-neutral-500";
    default:
      return "bg-neutral-400";
  }
}

export function VideoPlayer({
  recording,
  className,
  style,
  autoPlay = false,
  onClose,
}: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const progressRef = useRef<HTMLDivElement>(null);

  // Playback state
  const [isPlaying, setIsPlaying] = useState(autoPlay);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(recording.durationMs ?? 0);
  const [_volume, _setVolume] = useState(1);
  const [isMuted, setIsMuted] = useState(false);
  const [playbackSpeed, setPlaybackSpeed] = useState<PlaybackSpeed>(1);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [showChapters, setShowChapters] = useState(true);
  const [hoveredChapter, setHoveredChapter] = useState<VideoCheckpoint | null>(null);

  // Current chapter based on playback position
  const currentChapter = useMemo(() => {
    if (!recording.checkpoints.length) return null;
    // Find the last checkpoint that is at or before the current time
    const sorted = [...recording.checkpoints].sort((a, b) => b.timestampMs - a.timestampMs);
    return sorted.find((cp) => cp.timestampMs <= currentTime) ?? null;
  }, [recording.checkpoints, currentTime]);

  // Handle video time update
  const handleTimeUpdate = useCallback(() => {
    if (videoRef.current) {
      setCurrentTime(videoRef.current.currentTime * 1000);
    }
  }, []);

  // Handle video loaded metadata
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current) {
      setDuration(videoRef.current.duration * 1000);
    }
  }, []);

  // Handle play/pause
  const togglePlayPause = useCallback(() => {
    if (videoRef.current) {
      if (isPlaying) {
        videoRef.current.pause();
      } else {
        videoRef.current.play();
      }
      setIsPlaying(!isPlaying);
    }
  }, [isPlaying]);

  // Handle seeking via progress bar
  const handleProgressClick = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    if (!progressRef.current || !videoRef.current) return;

    const rect = progressRef.current.getBoundingClientRect();
    const clickX = e.clientX - rect.left;
    const percentage = clickX / rect.width;
    const newTime = percentage * duration;

    videoRef.current.currentTime = newTime / 1000;
    setCurrentTime(newTime);
  }, [duration]);

  // Handle seeking to chapter
  const seekToChapter = useCallback((checkpoint: VideoCheckpoint) => {
    if (videoRef.current) {
      videoRef.current.currentTime = checkpoint.timestampMs / 1000;
      setCurrentTime(checkpoint.timestampMs);
      if (!isPlaying) {
        videoRef.current.play();
        setIsPlaying(true);
      }
    }
  }, [isPlaying]);

  // Skip forward/backward
  const skipForward = useCallback(() => {
    if (videoRef.current) {
      videoRef.current.currentTime = Math.min(
        videoRef.current.currentTime + 10,
        duration / 1000
      );
    }
  }, [duration]);

  const skipBackward = useCallback(() => {
    if (videoRef.current) {
      videoRef.current.currentTime = Math.max(videoRef.current.currentTime - 10, 0);
    }
  }, []);

  // Go to next/previous chapter
  const goToNextChapter = useCallback(() => {
    if (!recording.checkpoints.length) return;
    const sorted = [...recording.checkpoints].sort((a, b) => a.timestampMs - b.timestampMs);
    const next = sorted.find((cp) => cp.timestampMs > currentTime);
    if (next) {
      seekToChapter(next);
    }
  }, [recording.checkpoints, currentTime, seekToChapter]);

  const goToPreviousChapter = useCallback(() => {
    if (!recording.checkpoints.length) return;
    const sorted = [...recording.checkpoints].sort((a, b) => b.timestampMs - a.timestampMs);
    // Find a chapter that's at least 2 seconds before current time (so clicking prev twice goes back)
    const prev = sorted.find((cp) => cp.timestampMs < currentTime - 2000);
    if (prev) {
      seekToChapter(prev);
    } else {
      // Go to beginning
      if (videoRef.current) {
        videoRef.current.currentTime = 0;
        setCurrentTime(0);
      }
    }
  }, [recording.checkpoints, currentTime, seekToChapter]);

  // Handle volume change
  const toggleMute = useCallback(() => {
    if (videoRef.current) {
      videoRef.current.muted = !isMuted;
      setIsMuted(!isMuted);
    }
  }, [isMuted]);

  // Handle playback speed change
  const cyclePlaybackSpeed = useCallback(() => {
    const currentIndex = SPEED_OPTIONS.indexOf(playbackSpeed);
    const nextIndex = (currentIndex + 1) % SPEED_OPTIONS.length;
    const newSpeed = SPEED_OPTIONS[nextIndex];
    setPlaybackSpeed(newSpeed);
    if (videoRef.current) {
      videoRef.current.playbackRate = newSpeed;
    }
  }, [playbackSpeed]);

  // Handle fullscreen
  const toggleFullscreen = useCallback(() => {
    if (!document.fullscreenElement) {
      videoRef.current?.parentElement?.requestFullscreen();
      setIsFullscreen(true);
    } else {
      document.exitFullscreen();
      setIsFullscreen(false);
    }
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't handle if focused on input
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return;
      }

      switch (e.key) {
        case " ":
        case "k":
          e.preventDefault();
          togglePlayPause();
          break;
        case "ArrowLeft":
          e.preventDefault();
          if (e.shiftKey) {
            goToPreviousChapter();
          } else {
            skipBackward();
          }
          break;
        case "ArrowRight":
          e.preventDefault();
          if (e.shiftKey) {
            goToNextChapter();
          } else {
            skipForward();
          }
          break;
        case "m":
          e.preventDefault();
          toggleMute();
          break;
        case "f":
          e.preventDefault();
          toggleFullscreen();
          break;
        case "<":
        case ",":
          e.preventDefault();
          // Decrease speed
          {
            const currentIndex = SPEED_OPTIONS.indexOf(playbackSpeed);
            if (currentIndex > 0) {
              const newSpeed = SPEED_OPTIONS[currentIndex - 1];
              setPlaybackSpeed(newSpeed);
              if (videoRef.current) {
                videoRef.current.playbackRate = newSpeed;
              }
            }
          }
          break;
        case ">":
        case ".":
          e.preventDefault();
          // Increase speed
          {
            const currentIndex = SPEED_OPTIONS.indexOf(playbackSpeed);
            if (currentIndex < SPEED_OPTIONS.length - 1) {
              const newSpeed = SPEED_OPTIONS[currentIndex + 1];
              setPlaybackSpeed(newSpeed);
              if (videoRef.current) {
                videoRef.current.playbackRate = newSpeed;
              }
            }
          }
          break;
        case "c":
          e.preventDefault();
          setShowChapters(!showChapters);
          break;
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [
    togglePlayPause,
    skipBackward,
    skipForward,
    goToPreviousChapter,
    goToNextChapter,
    toggleMute,
    toggleFullscreen,
    playbackSpeed,
    showChapters,
  ]);

  // Handle video end
  const handleEnded = useCallback(() => {
    setIsPlaying(false);
  }, []);

  // Sync video playing state
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const handlePlay = () => setIsPlaying(true);
    const handlePause = () => setIsPlaying(false);

    video.addEventListener("play", handlePlay);
    video.addEventListener("pause", handlePause);

    return () => {
      video.removeEventListener("play", handlePlay);
      video.removeEventListener("pause", handlePause);
    };
  }, []);

  if (!recording.videoUrl) {
    return (
      <div className={cn("flex items-center justify-center bg-neutral-900 text-neutral-400", className)} style={style}>
        <p>Video not available</p>
      </div>
    );
  }

  const progress = duration > 0 ? (currentTime / duration) * 100 : 0;

  return (
    <div className={cn("relative flex bg-neutral-950", className)} style={style}>
      {/* Main video area */}
      <div className={cn("relative flex-1 flex flex-col", showChapters && recording.checkpoints.length > 0 && "mr-64")}>
        {/* Video container */}
        <div className="relative flex-1 bg-black flex items-center justify-center">
          <video
            ref={videoRef}
            src={recording.videoUrl}
            className="max-h-full max-w-full"
            onTimeUpdate={handleTimeUpdate}
            onLoadedMetadata={handleLoadedMetadata}
            onEnded={handleEnded}
            autoPlay={autoPlay}
            playsInline
          />

          {/* Play/Pause overlay on click */}
          <button
            type="button"
            className="absolute inset-0 cursor-pointer"
            onClick={togglePlayPause}
            aria-label={isPlaying ? "Pause" : "Play"}
          />

          {/* Current chapter overlay */}
          {currentChapter && (
            <div className="absolute top-4 left-4 px-3 py-1.5 bg-neutral-950/80 rounded-lg text-sm text-white backdrop-blur-sm">
              <span className="mr-2">{getCheckpointIcon(currentChapter.type)}</span>
              {currentChapter.label}
            </div>
          )}
        </div>

        {/* Controls */}
        <div className="bg-neutral-900/95 px-4 py-3 backdrop-blur-sm">
          {/* Progress bar with chapter markers */}
          <div
            ref={progressRef}
            className="relative h-2 bg-neutral-700 rounded-full cursor-pointer group mb-3"
            onClick={handleProgressClick}
          >
            {/* Played progress */}
            <div
              className="absolute h-full bg-emerald-500 rounded-full transition-all"
              style={{ width: `${progress}%` }}
            />

            {/* Chapter markers */}
            {recording.checkpoints.map((checkpoint, idx) => {
              const position = duration > 0 ? (checkpoint.timestampMs / duration) * 100 : 0;
              return (
                <button
                  key={idx}
                  type="button"
                  className={cn(
                    "absolute top-1/2 -translate-y-1/2 w-3 h-3 rounded-full border-2 border-white shadow-md transition-transform hover:scale-125",
                    getCheckpointColor(checkpoint.type),
                    hoveredChapter === checkpoint && "scale-125"
                  )}
                  style={{ left: `${position}%`, marginLeft: "-6px" }}
                  onClick={(e) => {
                    e.stopPropagation();
                    seekToChapter(checkpoint);
                  }}
                  onMouseEnter={() => setHoveredChapter(checkpoint)}
                  onMouseLeave={() => setHoveredChapter(null)}
                  aria-label={`Jump to: ${checkpoint.label}`}
                />
              );
            })}

            {/* Hover preview */}
            {hoveredChapter && (
              <div
                className="absolute bottom-full mb-2 px-2 py-1 bg-neutral-800 text-white text-xs rounded whitespace-nowrap"
                style={{
                  left: `${duration > 0 ? (hoveredChapter.timestampMs / duration) * 100 : 0}%`,
                  transform: "translateX(-50%)",
                }}
              >
                {formatTime(hoveredChapter.timestampMs)} - {hoveredChapter.label}
              </div>
            )}
          </div>

          {/* Control buttons */}
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              {/* Previous chapter */}
              <button
                type="button"
                onClick={goToPreviousChapter}
                className="p-2 text-neutral-400 hover:text-white transition-colors"
                aria-label="Previous chapter"
                title="Previous chapter (Shift+Left)"
              >
                <SkipBack className="h-4 w-4" />
              </button>

              {/* Play/Pause */}
              <button
                type="button"
                onClick={togglePlayPause}
                className="p-2 text-white hover:text-emerald-400 transition-colors"
                aria-label={isPlaying ? "Pause" : "Play"}
                title={isPlaying ? "Pause (Space)" : "Play (Space)"}
              >
                {isPlaying ? (
                  <Pause className="h-5 w-5" />
                ) : (
                  <Play className="h-5 w-5" />
                )}
              </button>

              {/* Next chapter */}
              <button
                type="button"
                onClick={goToNextChapter}
                className="p-2 text-neutral-400 hover:text-white transition-colors"
                aria-label="Next chapter"
                title="Next chapter (Shift+Right)"
              >
                <SkipForward className="h-4 w-4" />
              </button>

              {/* Volume */}
              <button
                type="button"
                onClick={toggleMute}
                className="p-2 text-neutral-400 hover:text-white transition-colors"
                aria-label={isMuted ? "Unmute" : "Mute"}
                title="Toggle mute (M)"
              >
                {isMuted ? (
                  <VolumeX className="h-4 w-4" />
                ) : (
                  <Volume2 className="h-4 w-4" />
                )}
              </button>

              {/* Time display */}
              <span className="text-sm text-neutral-300 font-mono ml-2">
                {formatTime(currentTime)} / {formatTime(duration)}
              </span>
            </div>

            <div className="flex items-center gap-2">
              {/* Playback speed */}
              <button
                type="button"
                onClick={cyclePlaybackSpeed}
                className="px-2 py-1 text-sm text-neutral-400 hover:text-white transition-colors font-mono"
                title="Playback speed (< >)"
              >
                {playbackSpeed}x
              </button>

              {/* Toggle chapters */}
              {recording.checkpoints.length > 0 && (
                <button
                  type="button"
                  onClick={() => setShowChapters(!showChapters)}
                  className={cn(
                    "p-2 transition-colors",
                    showChapters ? "text-emerald-400" : "text-neutral-400 hover:text-white"
                  )}
                  aria-label={showChapters ? "Hide chapters" : "Show chapters"}
                  title="Toggle chapters (C)"
                >
                  <List className="h-4 w-4" />
                </button>
              )}

              {/* Fullscreen */}
              <button
                type="button"
                onClick={toggleFullscreen}
                className="p-2 text-neutral-400 hover:text-white transition-colors"
                aria-label={isFullscreen ? "Exit fullscreen" : "Fullscreen"}
                title="Toggle fullscreen (F)"
              >
                {isFullscreen ? (
                  <Minimize2 className="h-4 w-4" />
                ) : (
                  <Maximize2 className="h-4 w-4" />
                )}
              </button>

              {/* Close button */}
              {onClose && (
                <button
                  type="button"
                  onClick={onClose}
                  className="p-2 text-neutral-400 hover:text-white transition-colors"
                  aria-label="Close"
                >
                  <X className="h-4 w-4" />
                </button>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Chapters sidebar */}
      {showChapters && recording.checkpoints.length > 0 && (
        <div className="absolute right-0 top-0 bottom-0 w-64 bg-neutral-900/95 border-l border-neutral-800 overflow-y-auto backdrop-blur-sm">
          <div className="p-3 border-b border-neutral-800">
            <h3 className="text-sm font-medium text-white">Chapters</h3>
            <p className="text-xs text-neutral-400 mt-1">
              {recording.checkpoints.length} checkpoint{recording.checkpoints.length !== 1 ? "s" : ""}
            </p>
          </div>
          <div className="p-2">
            {[...recording.checkpoints]
              .sort((a, b) => a.timestampMs - b.timestampMs)
              .map((checkpoint, idx) => {
                const isActive = currentChapter === checkpoint;
                const isPast = checkpoint.timestampMs <= currentTime;
                return (
                  <button
                    key={idx}
                    type="button"
                    onClick={() => seekToChapter(checkpoint)}
                    className={cn(
                      "w-full text-left p-2 rounded-lg transition-colors mb-1",
                      isActive
                        ? "bg-emerald-500/20 text-emerald-300"
                        : isPast
                          ? "text-neutral-400 hover:bg-neutral-800"
                          : "text-neutral-300 hover:bg-neutral-800"
                    )}
                  >
                    <div className="flex items-start gap-2">
                      <span className="text-sm flex-shrink-0">
                        {getCheckpointIcon(checkpoint.type)}
                      </span>
                      <div className="flex-1 min-w-0">
                        <div className="text-sm font-medium truncate">
                          {checkpoint.label}
                        </div>
                        <div className="text-xs text-neutral-500 font-mono">
                          {formatTime(checkpoint.timestampMs)}
                        </div>
                        {checkpoint.description && (
                          <div className="text-xs text-neutral-400 mt-1 line-clamp-2">
                            {checkpoint.description}
                          </div>
                        )}
                      </div>
                    </div>
                  </button>
                );
              })}
          </div>
        </div>
      )}
    </div>
  );
}

// Video player in a modal dialog
interface VideoPlayerDialogProps {
  recording: VideoRecording;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function VideoPlayerDialog({
  recording,
  open,
  onOpenChange,
}: VideoPlayerDialogProps) {
  const recordedAt = new Date(recording.recordingStartedAt);
  const relativeTime = formatDistanceToNow(recordedAt, { addSuffix: true });

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-neutral-950/80 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=open]:fade-in data-[state=closed]:fade-out z-[var(--z-floating-high-overlay)]" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[var(--z-floating-high)] flex max-h-[calc(100vh-4rem)] w-[min(1600px,calc(100vw-4rem))] -translate-x-1/2 -translate-y-1/2 flex-col rounded-2xl border border-neutral-800 bg-neutral-950 shadow-2xl focus:outline-none overflow-hidden">
          <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-800">
            <div>
              <Dialog.Title className="text-base font-semibold text-white">
                Session Recording
              </Dialog.Title>
              <Dialog.Description className="text-xs text-neutral-400 mt-0.5">
                Recorded {relativeTime}
                {recording.commitSha && (
                  <>
                    <span className="px-1 text-neutral-600">•</span>
                    <span className="font-mono">{recording.commitSha.slice(0, 8)}</span>
                  </>
                )}
                {recording.durationMs && (
                  <>
                    <span className="px-1 text-neutral-600">•</span>
                    {formatTime(recording.durationMs)}
                  </>
                )}
              </Dialog.Description>
            </div>
            <Dialog.Close asChild>
              <button
                type="button"
                className="p-2 text-neutral-400 hover:text-white transition-colors rounded-lg hover:bg-neutral-800"
                aria-label="Close"
              >
                <X className="h-4 w-4" />
              </button>
            </Dialog.Close>
          </div>
          <VideoPlayer
            recording={recording}
            className="flex-1 min-h-[400px]"
            onClose={() => onOpenChange(false)}
          />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export default VideoPlayer;
