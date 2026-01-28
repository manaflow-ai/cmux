import {
  type SyntheticEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { formatDistanceToNow } from "date-fns";
import * as Dialog from "@radix-ui/react-dialog";
import {
  ChevronLeft,
  ChevronRight,
  Images,
  Maximize2,
  Play,
  RotateCcw,
  X,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { cn } from "@/lib/utils";
import type { Id } from "@cmux/convex/dataModel";

type ScreenshotStatus = "completed" | "failed" | "skipped";

interface ScreenshotMediaBase {
  storageId: Id<"_storage">;
  mimeType: string;
  fileName?: string | null;
  commitSha?: string | null;
  description?: string | null;
  url?: string | null;
}

type ScreenshotImage = ScreenshotMediaBase;

type ScreenshotVideo = ScreenshotMediaBase;

interface RunScreenshotSet {
  _id: Id<"taskRunScreenshotSets">;
  taskId: Id<"tasks">;
  runId: Id<"taskRuns">;
  status: ScreenshotStatus;
  hasUiChanges?: boolean | null;
  commitSha?: string | null;
  capturedAt: number;
  error?: string | null;
  images: ScreenshotImage[];
  videos?: ScreenshotVideo[];
}

interface RunScreenshotGalleryProps {
  screenshotSets: RunScreenshotSet[];
  highlightedSetId?: Id<"taskRunScreenshotSets"> | null;
}

const MIN_ZOOM = 0.2;
const MAX_ZOOM = 40;

const NO_UI_CHANGES_ERROR_SNIPPETS = [
  "Claude collector reported success but returned no files",
  "returned no files in the git diff",
  "no ui changes",
  "no files to capture",
  "No UI changes detected",
];

function detectEmptyReason(set: RunScreenshotSet): {
  reason: "no-ui-changes" | "failed" | "skipped" | "empty";
  message: string;
} {
  // Check explicit hasUiChanges flag
  if (set.hasUiChanges === false) {
    return {
      reason: "no-ui-changes",
      message: "No UI changes detected in this diff. Screenshot capture was skipped since there were no visual changes to verify.",
    };
  }

  // Check for error messages indicating no UI changes
  if (set.error) {
    const normalizedError = set.error.toLowerCase();
    const isNoUiChangesError = NO_UI_CHANGES_ERROR_SNIPPETS.some((snippet) =>
      normalizedError.includes(snippet.toLowerCase())
    );
    if (isNoUiChangesError) {
      return {
        reason: "no-ui-changes",
        message: "No UI changes detected in this diff. Screenshot capture was skipped since there were no visual changes to verify.",
      };
    }
  }

  // Check status
  if (set.status === "failed") {
    return {
      reason: "failed",
      message: set.error
        ? `Screenshot capture failed: ${set.error}`
        : "Screenshot capture failed before any media could be saved.",
    };
  }

  if (set.status === "skipped") {
    return {
      reason: "skipped",
      message: "Screenshot capture was skipped for this run.",
    };
  }

  return {
    reason: "empty",
    message: "No screenshots or videos were captured for this run.",
  };
}

type MediaKind = "image" | "video";

type GalleryItem = {
  set: RunScreenshotSet;
  media: ScreenshotMediaBase;
  kind: MediaKind;
  indexInSet: number;
  key: string;
};

type GalleryEntry = GalleryItem & {
  globalIndex: number;
};

const getMediaKey = (
  setId: Id<"taskRunScreenshotSets">,
  kind: MediaKind,
  media: ScreenshotMediaBase,
  indexInSet: number,
) => `${setId}:${kind}:${media.storageId}:${indexInSet}`;

export function RunScreenshotGallery(props: RunScreenshotGalleryProps) {
  const { screenshotSets } = props;
  // Only show the latest screenshot set
  const latestScreenshotSet = useMemo(() => {
    if (screenshotSets.length === 0) return null;
    return [...screenshotSets].sort((a, b) => {
      if (a.capturedAt === b.capturedAt) {
        return a._id.localeCompare(b._id);
      }
      return a.capturedAt - b.capturedAt;
    })[screenshotSets.length - 1];
  }, [screenshotSets]);

  const mediaItems = useMemo<GalleryItem[]>(() => {
    if (!latestScreenshotSet) return [];
    const entries: GalleryItem[] = [];
    latestScreenshotSet.images.forEach((image, indexInSet) => {
      entries.push({
        set: latestScreenshotSet,
        media: image,
        kind: "image",
        indexInSet,
        key: getMediaKey(latestScreenshotSet._id, "image", image, indexInSet),
      });
    });
    // Filter out animated preview images (GIF/APNG) - they are only used for GitHub comment embedding, not gallery display
    const displayableVideos = latestScreenshotSet.videos?.filter(
      (video) => video.mimeType !== "image/apng" && video.mimeType !== "image/gif"
    );
    displayableVideos?.forEach((video, indexInSet) => {
      entries.push({
        set: latestScreenshotSet,
        media: video,
        kind: "video",
        indexInSet,
        key: getMediaKey(latestScreenshotSet._id, "video", video, indexInSet),
      });
    });
    return entries;
  }, [latestScreenshotSet]);

  const flattenedMedia = useMemo<GalleryEntry[]>(() => {
    const entries: GalleryEntry[] = [];
    mediaItems.forEach((entry) => {
      if (!entry.media.url) {
        return;
      }
      entries.push({
        ...entry,
        globalIndex: entries.length,
      });
    });
    return entries;
  }, [mediaItems]);

  const globalIndexByKey = useMemo(() => {
    const indexMap = new Map<string, number>();
    flattenedMedia.forEach((entry) => {
      indexMap.set(entry.key, entry.globalIndex);
    });
    return indexMap;
  }, [flattenedMedia]);

  const [activeMediaKey, setActiveMediaKey] = useState<string | null>(null);
  const [zoom, setZoom] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [isPanning, setIsPanning] = useState(false);
  const [baseImageScale, setBaseImageScale] = useState(1);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const panPointerIdRef = useRef<number | null>(null);
  const lastPanPositionRef = useRef<{ x: number; y: number } | null>(null);
  const defaultZoomRef = useRef(1);
  const defaultOffsetRef = useRef<{ x: number; y: number }>({ x: 0, y: 0 });

  const clampZoom = useCallback((value: number) => {
    return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));
  }, []);

  const setZoomWithFocus = useCallback(
    (
      resolver: (prevZoom: number) => number,
      focusPoint: { x: number; y: number } = { x: 0, y: 0 },
    ) => {
      setZoom((prevZoom) => {
        const safePrevZoom = prevZoom || 1;
        const nextZoom = clampZoom(resolver(safePrevZoom));
        if (nextZoom === safePrevZoom) {
          return nextZoom;
        }
        setOffset((prevOffset) => ({
          x:
            focusPoint.x -
            (nextZoom * (focusPoint.x - prevOffset.x)) / safePrevZoom,
          y:
            focusPoint.y -
            (nextZoom * (focusPoint.y - prevOffset.y)) / safePrevZoom,
        }));
        return nextZoom;
      });
    },
    [clampZoom],
  );

  const resetZoomState = useCallback(
    (options?: { zoom?: number; offset?: { x: number; y: number } }) => {
      const targetZoom = clampZoom(options?.zoom ?? defaultZoomRef.current);
      setZoom(targetZoom);
      setOffset(options?.offset ?? defaultOffsetRef.current);
      setIsPanning(false);
      panPointerIdRef.current = null;
      lastPanPositionRef.current = null;
    },
    [clampZoom],
  );

  const handleImageLoad = (event: SyntheticEvent<HTMLImageElement>) => {
    const { naturalWidth, naturalHeight } = event.currentTarget;
    const viewportRect = viewportRef.current?.getBoundingClientRect();
    if (!viewportRect || naturalWidth <= 0 || naturalHeight <= 0) {
      setBaseImageScale(1);
      defaultZoomRef.current = 1;
      defaultOffsetRef.current = { x: 0, y: 0 };
      resetZoomState({ zoom: 1, offset: { x: 0, y: 0 } });
      return;
    }

    const viewportWidth = viewportRect.width;
    const viewportHeight = viewportRect.height;
    const baseScale = Math.min(
      viewportWidth / naturalWidth,
      viewportHeight / naturalHeight,
    );
    const normalizedBaseScale = Math.min(1, baseScale);
    setBaseImageScale(normalizedBaseScale);
    const baseWidth = naturalWidth * baseScale;
    const baseHeight = naturalHeight * baseScale;

    const fitHeightZoom = viewportHeight / baseHeight;
    const fitWidthZoom = viewportWidth / baseWidth;
    const desiredZoom = Math.min(1, fitHeightZoom, fitWidthZoom);
    const clampedZoom = clampZoom(desiredZoom);

    const scaledHeight = baseHeight * clampedZoom;
    const offsetY = -((viewportHeight - scaledHeight) / 2);
    const initialOffset = { x: 0, y: offsetY };

    defaultZoomRef.current = clampedZoom;
    defaultOffsetRef.current = initialOffset;
    resetZoomState({ zoom: clampedZoom, offset: initialOffset });
  };

  const activeMediaIndex =
    activeMediaKey !== null ? globalIndexByKey.get(activeMediaKey) ?? null : null;
  const currentEntry =
    activeMediaIndex !== null &&
      activeMediaIndex >= 0 &&
      activeMediaIndex < flattenedMedia.length
      ? flattenedMedia[activeMediaIndex]
      : null;

  const activeOverallIndex =
    currentEntry?.globalIndex !== undefined
      ? currentEntry.globalIndex + 1
      : null;

  useEffect(() => {
    if (activeMediaKey === null) {
      return;
    }
    if (flattenedMedia.length === 0 || !globalIndexByKey.has(activeMediaKey)) {
      setActiveMediaKey(null);
    }
  }, [activeMediaKey, flattenedMedia.length, globalIndexByKey]);

  useEffect(() => {
    defaultZoomRef.current = 1;
    defaultOffsetRef.current = { x: 0, y: 0 };
    setBaseImageScale(1);
    resetZoomState({ zoom: 1, offset: { x: 0, y: 0 } });
  }, [currentEntry?.key, resetZoomState]);

  const closeSlideshow = useCallback(() => {
    setActiveMediaKey(null);
  }, []);

  const goNext = useCallback(() => {
    if (activeMediaIndex === null) {
      return;
    }
    const len = flattenedMedia.length;
    if (len <= 1) {
      return;
    }
    const nextIndex = (activeMediaIndex + 1) % len;
    setActiveMediaKey(flattenedMedia[nextIndex]?.key ?? null);
  }, [activeMediaIndex, flattenedMedia]);

  const goPrev = useCallback(() => {
    if (activeMediaIndex === null) {
      return;
    }
    const len = flattenedMedia.length;
    if (len <= 1) {
      return;
    }
    const prevIndex = (activeMediaIndex - 1 + len) % len;
    setActiveMediaKey(flattenedMedia[prevIndex]?.key ?? null);
  }, [activeMediaIndex, flattenedMedia]);

  const isSlideshowOpen = Boolean(currentEntry);
  const hasMultipleMedia = flattenedMedia.length > 1;
  const showNavButtons = hasMultipleMedia;
  const isImageActive = currentEntry?.kind === "image";
  const effectiveScale = Math.max(0, zoom * baseImageScale);
  const zoomPercent = Math.round(effectiveScale * 100);
  const canZoomIn = isImageActive && zoom < MAX_ZOOM - 0.001;
  const canZoomOut = isImageActive && zoom > MIN_ZOOM + 0.001;
  const canResetZoom =
    isImageActive && (zoom !== 1 || offset.x !== 0 || offset.y !== 0);

  const handleWheel = useCallback(
    (event: React.WheelEvent<HTMLDivElement>) => {
      if (!currentEntry || !viewportRef.current || currentEntry.kind !== "image") {
        return;
      }
      event.preventDefault();
      const rect = viewportRef.current.getBoundingClientRect();
      const pointerX = event.clientX - (rect.left + rect.width / 2);
      const pointerY = event.clientY - (rect.top + rect.height / 2);
      const { deltaMode, deltaY } = event;
      let pixelDelta = deltaY;
      if (deltaMode === 1) {
        pixelDelta *= 16;
      } else if (deltaMode === 2) {
        pixelDelta *= rect.height;
      }
      if (pixelDelta === 0) {
        return;
      }
      const sensitivity = event.ctrlKey ? 0.0016 : 0.0009;
      const factor = Math.exp(-pixelDelta * sensitivity);
      setZoomWithFocus((prevZoom) => prevZoom * factor, {
        x: pointerX,
        y: pointerY,
      });
    },
    [currentEntry, setZoomWithFocus],
  );

  const startPanning = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (!currentEntry || currentEntry.kind !== "image" || event.button !== 0) {
        return;
      }
      event.preventDefault();
      setIsPanning(true);
      panPointerIdRef.current = event.pointerId;
      lastPanPositionRef.current = {
        x: event.clientX,
        y: event.clientY,
      };
      event.currentTarget.setPointerCapture(event.pointerId);
    },
    [currentEntry],
  );

  const handlePointerMove = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (
        !isPanning ||
        panPointerIdRef.current !== event.pointerId ||
        !lastPanPositionRef.current
      ) {
        return;
      }
      event.preventDefault();
      const deltaX = event.clientX - lastPanPositionRef.current.x;
      const deltaY = event.clientY - lastPanPositionRef.current.y;
      lastPanPositionRef.current = {
        x: event.clientX,
        y: event.clientY,
      };
      setOffset((prev) => ({
        x: prev.x + deltaX,
        y: prev.y + deltaY,
      }));
    },
    [isPanning],
  );

  const stopPanning = useCallback(
    (event?: React.PointerEvent<HTMLDivElement>) => {
      if (panPointerIdRef.current !== null && event) {
        try {
          event.currentTarget.releasePointerCapture(
            panPointerIdRef.current,
          );
        } catch {
          // Ignore release errors if pointer capture is no longer active
        }
      }
      panPointerIdRef.current = null;
      lastPanPositionRef.current = null;
      setIsPanning(false);
    },
    [],
  );

  const handlePointerUp = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (panPointerIdRef.current !== event.pointerId) {
        return;
      }
      event.preventDefault();
      stopPanning(event);
    },
    [stopPanning],
  );

  const handlePointerLeave = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (!isPanning) {
        return;
      }
      stopPanning(event);
    },
    [isPanning, stopPanning],
  );

  const handlePointerCancel = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (panPointerIdRef.current !== event.pointerId) {
        return;
      }
      stopPanning(event);
    },
    [stopPanning],
  );

  const handleZoomIn = useCallback(() => {
    setZoomWithFocus((prevZoom) => prevZoom * 1.2);
  }, [setZoomWithFocus]);

  const handleZoomOut = useCallback(() => {
    setZoomWithFocus((prevZoom) => prevZoom / 1.2);
  }, [setZoomWithFocus]);

  useEffect(() => {
    if (!isSlideshowOpen) {
      return;
    }
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "ArrowRight") {
        event.preventDefault();
        goNext();
      } else if (event.key === "ArrowLeft") {
        event.preventDefault();
        goPrev();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [goNext, goPrev, isSlideshowOpen]);

  const openFirstMedia = useCallback(() => {
    if (flattenedMedia.length > 0 && flattenedMedia[0]) {
      setActiveMediaKey(flattenedMedia[0].key);
    }
  }, [flattenedMedia]);

  if (!latestScreenshotSet) {
    return null;
  }

  const imageCount = latestScreenshotSet.images.length;
  const videoCount = latestScreenshotSet.videos?.filter((v) => v.mimeType !== "image/apng" && v.mimeType !== "image/gif").length ?? 0;
  const totalMediaCount = imageCount + videoCount;

  const emptyReason = totalMediaCount === 0 ? detectEmptyReason(latestScreenshotSet) : null;

  return (
    <section>
      <div className="px-2 py-1.5 flex items-center gap-2">
        {totalMediaCount > 0 ? (
          <button
            type="button"
            onClick={openFirstMedia}
            className="flex items-center gap-1.5 px-2 py-0.5 rounded text-[13px] font-medium text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors"
            title="View previews"
          >
            <Images className="w-3.5 h-3.5" />
            <span>Previews</span>
          </button>
        ) : (
          <div className="flex items-center gap-1.5 px-2 py-0.5 text-[13px] font-medium text-neutral-600 dark:text-neutral-400">
            <Images className="w-3.5 h-3.5" />
            <span>Previews</span>
          </div>
        )}
        <span className="text-[11px] text-neutral-500 dark:text-neutral-500">
          {imageCount > 0 && `${imageCount} ${imageCount === 1 ? "screenshot" : "screenshots"}`}
          {imageCount > 0 && videoCount > 0 && " and "}
          {videoCount > 0 && `${videoCount} ${videoCount === 1 ? "video" : "videos"}`}
          {totalMediaCount === 0 && "0 items"}
        </span>
      </div>
      <div className="px-3 pb-3">
        {currentEntry ? (
          <Dialog.Root
            open={isSlideshowOpen}
            onOpenChange={(open) => !open && closeSlideshow()}
          >
            <Dialog.Portal>
              <Dialog.Overlay className="fixed inset-0 bg-neutral-950/60 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=open]:fade-in data-[state=closed]:fade-out z-[var(--z-floating-high-overlay)]" />
              <Dialog.Content className="fixed left-1/2 top-1/2 z-[var(--z-floating-high)] flex max-h-[calc(100vh-4rem)] w-[min(2600px,calc(100vw-4rem))] -translate-x-1/2 -translate-y-1/2 flex-col gap-4 rounded-3xl border border-neutral-200 bg-white/95 p-4 shadow-2xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-950/95 sm:max-h-[calc(100vh-6rem)] sm:w-[min(2600px,calc(100vw-6rem))] sm:p-6">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="space-y-1">
                    <Dialog.Title className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
                      {activeOverallIndex !== null ? `${activeOverallIndex}. ` : ""}
                      {currentEntry.media.fileName ??
                        (currentEntry.kind === "video" ? "Video" : "Screenshot")}
                    </Dialog.Title>
                    <Dialog.Description className="text-xs text-neutral-600 dark:text-neutral-400">
                      {currentEntry.kind === "video" ? "Video" : "Image"}{" "}
                      {currentEntry.indexInSet + 1} of{" "}
                      {currentEntry.kind === "video"
                        ? currentEntry.set.videos?.filter((v) => v.mimeType !== "image/apng" && v.mimeType !== "image/gif").length ?? 0
                        : currentEntry.set.images.length}
                      <span className="px-1 text-neutral-400 dark:text-neutral-600">•</span>
                      {formatDistanceToNow(new Date(currentEntry.set.capturedAt), {
                        addSuffix: true,
                      })}
                    </Dialog.Description>
                  </div>
                  <div className="flex items-center gap-2">
                    {isImageActive ? (
                      <div className="flex items-center gap-1 rounded-full border border-neutral-200 bg-white/90 px-2 py-1 text-xs font-medium text-neutral-600 shadow-sm dark:border-neutral-700 dark:bg-neutral-900/70 dark:text-neutral-200">
                        <button
                          type="button"
                          onClick={handleZoomOut}
                          disabled={!canZoomOut}
                          className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:hover:bg-neutral-800/80"
                          aria-label="Zoom out"
                        >
                          <ZoomOut className="h-3.5 w-3.5" />
                        </button>
                        <span className="min-w-[3rem] text-center tabular-nums">
                          {zoomPercent}%
                        </span>
                        <button
                          type="button"
                          onClick={handleZoomIn}
                          disabled={!canZoomIn}
                          className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:hover:bg-neutral-800/80"
                          aria-label="Zoom in"
                        >
                          <ZoomIn className="h-3.5 w-3.5" />
                        </button>
                        <button
                          type="button"
                          onClick={() => resetZoomState()}
                          disabled={!canResetZoom}
                          className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:hover:bg-neutral-800/80"
                          aria-label="Reset zoom"
                        >
                          <RotateCcw className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    ) : (
                      <span className="rounded-full border border-neutral-200 bg-white/90 px-2 py-1 text-xs font-medium text-neutral-600 shadow-sm dark:border-neutral-700 dark:bg-neutral-900/70 dark:text-neutral-200">
                        Video
                      </span>
                    )}
                    <Dialog.Close asChild>
                      <button
                        type="button"
                        onClick={closeSlideshow}
                        className="rounded-full p-1.5 text-neutral-600 transition hover:bg-neutral-100 hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:text-neutral-300 dark:hover:bg-neutral-800/80 dark:hover:text-neutral-100"
                        aria-label="Close slideshow"
                      >
                        <X className="h-4 w-4" />
                      </button>
                    </Dialog.Close>
                  </div>
                </div>
                <div className="flex flex-1 items-center gap-4">
                  {showNavButtons ? (
                    <button
                      type="button"
                      onClick={goPrev}
                      className="rounded-full border border-neutral-200 bg-white p-2 text-neutral-600 transition hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-100"
                      aria-label="Previous screenshot"
                    >
                      <ChevronLeft className="h-5 w-5" />
                    </button>
                  ) : null}
                  <div
                    ref={viewportRef}
                    className={cn(
                      "relative flex h-[70vh] max-h-[calc(100vh-10rem)] min-h-[360px] w-full flex-1 items-center justify-center overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900",
                      isImageActive
                        ? zoom > 1
                          ? isPanning
                            ? "cursor-grabbing"
                            : "cursor-grab"
                          : "cursor-zoom-in"
                        : "cursor-default",
                    )}
                    onWheel={handleWheel}
                    onPointerDown={startPanning}
                    onPointerMove={handlePointerMove}
                    onPointerUp={handlePointerUp}
                    onPointerLeave={handlePointerLeave}
                    onPointerCancel={handlePointerCancel}
                    onDoubleClick={() => resetZoomState()}
                    style={{ touchAction: "none" }}
                  >
                    {currentEntry.kind === "image" ? (
                      <img
                        src={currentEntry.media.url ?? undefined}
                        alt={currentEntry.media.fileName ?? "Screenshot"}
                        className="select-none h-full w-full object-contain"
                        draggable={false}
                        onLoad={handleImageLoad}
                        style={{
                          transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${zoom})`,
                          transition: isPanning ? "none" : "transform 120ms ease-out",
                        }}
                      />
                    ) : (
                      <video
                        src={currentEntry.media.url ?? undefined}
                        className="h-full w-full object-contain"
                        controls
                        preload="metadata"
                        playsInline
                      />
                    )}
                  </div>
                  {showNavButtons ? (
                    <button
                      type="button"
                      onClick={goNext}
                      className="rounded-full border border-neutral-200 bg-white p-2 text-neutral-600 transition hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-100"
                      aria-label="Next screenshot"
                    >
                      <ChevronRight className="h-5 w-5" />
                    </button>
                  ) : null}
                </div>
                {hasMultipleMedia ? (
                  <div className="space-y-2">
                    <div className="flex items-center justify-between text-xs font-medium text-neutral-500 dark:text-neutral-400">
                      <span className="sr-only">All captures</span>
                      <span className="tabular-nums text-neutral-600 dark:text-neutral-300">
                        {activeOverallIndex ?? "–"} / {flattenedMedia.length}
                      </span>
                    </div>
                    <div className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1">
                      {flattenedMedia.map((entry) => {
                        const isActiveThumb = entry.key === currentEntry?.key;
                        const label = entry.globalIndex + 1;
                        const displayName =
                          entry.media.fileName ??
                          (entry.kind === "video" ? "Video" : "Screenshot");
                        return (
                          <button
                            key={entry.key}
                            type="button"
                            onClick={() => setActiveMediaKey(entry.key)}
                            className={cn(
                              "group relative flex h-24 w-40 flex-shrink-0 items-center justify-center overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-50 p-1 transition hover:border-neutral-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/70 dark:focus-visible:ring-neutral-500/70 dark:border-neutral-700 dark:bg-neutral-900/70 dark:hover:border-neutral-500",
                            )}
                            aria-label={`View ${displayName}`}
                            aria-current={isActiveThumb ? "true" : undefined}
                            title={displayName}
                          >
                            {entry.kind === "image" ? (
                              <img
                                src={entry.media.url ?? undefined}
                                alt={displayName}
                                className="h-full w-full object-contain"
                                loading="lazy"
                                decoding="async"
                              />
                            ) : (
                              <video
                                src={entry.media.url ?? undefined}
                                className="h-full w-full object-contain"
                                muted
                                preload="metadata"
                                playsInline
                              />
                            )}
                            <span className="pointer-events-none absolute bottom-1 left-1 rounded-full bg-neutral-950/80 px-1 text-[10px] font-semibold text-white shadow-sm dark:bg-neutral-900/90">
                              {label}
                            </span>
                          </button>
                        );
                      })}
                    </div>
                  </div>
                ) : null}
              </Dialog.Content>
            </Dialog.Portal>
          </Dialog.Root>
        ) : null}
        {totalMediaCount > 0 ? (
          <div className="flex gap-2 overflow-x-auto pb-1">
            {mediaItems.map((entry) => {
              const displayLabel =
                entry.media.description ??
                entry.media.fileName ??
                (entry.kind === "video" ? "Video" : "Screenshot");
              const stableKey = entry.key;
              if (!entry.media.url) {
                return (
                  <div
                    key={stableKey}
                    className="flex h-48 w-80 flex-shrink-0 items-center justify-center rounded-lg border border-neutral-200 bg-neutral-100 text-sm text-neutral-500 dark:border-neutral-700 dark:bg-neutral-800/50 dark:text-neutral-400"
                  >
                    URL expired
                  </div>
                );
              }
              const flatIndex = globalIndexByKey.get(stableKey) ?? null;
              const humanIndex = flatIndex !== null ? flatIndex + 1 : null;

              return (
                <button
                  key={stableKey}
                  type="button"
                  onClick={() => setActiveMediaKey(stableKey)}
                  className="group relative flex flex-shrink-0 flex-col text-left"
                  aria-label={`Open ${displayLabel} in slideshow`}
                  title={displayLabel}
                >
                  <div className="relative overflow-hidden rounded-lg border border-neutral-200 dark:border-neutral-700">
                    {entry.kind === "image" ? (
                      <img
                        src={entry.media.url}
                        alt={displayLabel}
                        className="h-48 w-80 object-cover"
                        loading="lazy"
                      />
                    ) : (
                      <video
                        src={entry.media.url}
                        className="h-48 w-80 object-cover"
                        muted
                        preload="metadata"
                        playsInline
                      />
                    )}
                    <div className="absolute top-1.5 right-1.5 rounded bg-neutral-900/70 p-1 text-white opacity-0 transition-opacity group-hover:opacity-100">
                      {entry.kind === "video" ? (
                        <Play className="h-3.5 w-3.5" />
                      ) : (
                        <Maximize2 className="h-3.5 w-3.5" />
                      )}
                    </div>
                  </div>
                  <span className="mt-2 text-xs text-neutral-500 dark:text-neutral-400 line-clamp-3 w-80">
                    {humanIndex !== null ? `${humanIndex}. ` : ""}
                    {displayLabel}
                  </span>
                </button>
              );
            })}
          </div>
        ) : emptyReason ? (
          <p className="text-xs text-neutral-500 dark:text-neutral-400 py-1">
            {emptyReason.message}
          </p>
        ) : null}
      </div>
    </section>
  );
}
