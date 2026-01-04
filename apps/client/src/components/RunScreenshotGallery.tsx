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
  Camera,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Maximize2,
  RotateCcw,
  X,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { cn } from "@/lib/utils";
import type { Id } from "@cmux/convex/dataModel";

type ScreenshotStatus = "completed" | "failed" | "skipped";

interface ScreenshotImage {
  storageId: Id<"_storage">;
  mimeType: string;
  fileName?: string | null;
  commitSha?: string | null;
  url?: string | null;
  description?: string | null;
}

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
}

interface RunScreenshotGalleryProps {
  screenshotSets: RunScreenshotSet[];
  highlightedSetId?: Id<"taskRunScreenshotSets"> | null;
}

const MIN_ZOOM = 0.2;
const MAX_ZOOM = 40;

const getImageKey = (
  setId: Id<"taskRunScreenshotSets">,
  image: ScreenshotImage,
  indexInSet: number,
) => `${setId}:${image.storageId}:${indexInSet}`;

export function RunScreenshotGallery(props: RunScreenshotGalleryProps) {
  const { screenshotSets, highlightedSetId: _highlightedSetId } = props;
  const sortedScreenshotSets = useMemo(
    () =>
      [...screenshotSets].sort((a, b) => {
        if (a.capturedAt === b.capturedAt) {
          return a._id.localeCompare(b._id);
        }
        return a.capturedAt - b.capturedAt;
      }),
    [screenshotSets],
  );

  const flattenedImages = useMemo(() => {
    const entries: Array<{
      set: RunScreenshotSet;
      image: ScreenshotImage;
      indexInSet: number;
      key: string;
      globalIndex: number;
    }> = [];
    sortedScreenshotSets.forEach((set) => {
      set.images.forEach((image, indexInSet) => {
        if (!image.url) {
          return;
        }
        entries.push({
          set,
          image,
          indexInSet,
          key: getImageKey(set._id, image, indexInSet),
          globalIndex: entries.length,
        });
      });
    });
    return entries;
  }, [sortedScreenshotSets]);

  const globalIndexByKey = useMemo(() => {
    const indexMap = new Map<string, number>();
    flattenedImages.forEach((entry) => {
      indexMap.set(entry.key, entry.globalIndex);
    });
    return indexMap;
  }, [flattenedImages]);

  const [activeImageKey, setActiveImageKey] = useState<string | null>(null);
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

  const activeImageIndex =
    activeImageKey !== null ? globalIndexByKey.get(activeImageKey) ?? null : null;
  const currentEntry =
    activeImageIndex !== null &&
      activeImageIndex >= 0 &&
      activeImageIndex < flattenedImages.length
      ? flattenedImages[activeImageIndex]
      : null;

  const activeOverallIndex =
    currentEntry?.globalIndex !== undefined
      ? currentEntry.globalIndex + 1
      : null;

  useEffect(() => {
    if (activeImageKey === null) {
      return;
    }
    if (flattenedImages.length === 0 || !globalIndexByKey.has(activeImageKey)) {
      setActiveImageKey(null);
    }
  }, [activeImageKey, flattenedImages.length, globalIndexByKey]);

  useEffect(() => {
    defaultZoomRef.current = 1;
    defaultOffsetRef.current = { x: 0, y: 0 };
    setBaseImageScale(1);
    resetZoomState({ zoom: 1, offset: { x: 0, y: 0 } });
  }, [currentEntry?.key, resetZoomState]);

  const closeSlideshow = useCallback(() => {
    setActiveImageKey(null);
  }, []);

  const goNext = useCallback(() => {
    if (activeImageIndex === null) {
      return;
    }
    const len = flattenedImages.length;
    if (len <= 1) {
      return;
    }
    const nextIndex = (activeImageIndex + 1) % len;
    setActiveImageKey(flattenedImages[nextIndex]?.key ?? null);
  }, [activeImageIndex, flattenedImages]);

  const goPrev = useCallback(() => {
    if (activeImageIndex === null) {
      return;
    }
    const len = flattenedImages.length;
    if (len <= 1) {
      return;
    }
    const prevIndex = (activeImageIndex - 1 + len) % len;
    setActiveImageKey(flattenedImages[prevIndex]?.key ?? null);
  }, [activeImageIndex, flattenedImages]);

  const isSlideshowOpen = Boolean(currentEntry);
  const hasMultipleImages = flattenedImages.length > 1;
  const showNavButtons = hasMultipleImages;
  const effectiveScale = Math.max(0, zoom * baseImageScale);
  const zoomPercent = Math.round(effectiveScale * 100);
  const canZoomIn = zoom < MAX_ZOOM - 0.001;
  const canZoomOut = zoom > MIN_ZOOM + 0.001;
  const canResetZoom = zoom !== 1 || offset.x !== 0 || offset.y !== 0;

  const handleWheel = useCallback(
    (event: React.WheelEvent<HTMLDivElement>) => {
      if (!currentEntry || !viewportRef.current) {
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
      if (!currentEntry || event.button !== 0) {
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

  const isEmpty = sortedScreenshotSets.length === 0;
  const [isExpanded, setIsExpanded] = useState(false);

  // Count total images across all sets
  const totalImages = useMemo(() => {
    return sortedScreenshotSets.reduce((acc, set) => acc + set.images.filter(img => img.url).length, 0);
  }, [sortedScreenshotSets]);

  // Check if any set has no UI changes
  const hasNoUiChanges = sortedScreenshotSets.some(set => set.hasUiChanges === false);
  const hasFailures = sortedScreenshotSets.some(set => set.status === "failed");

  // Generate summary text
  const summaryText = useMemo(() => {
    if (isEmpty) return "No screenshots";
    if (hasFailures && totalImages === 0) return "Screenshot capture failed";
    if (hasNoUiChanges && totalImages === 0) return "No UI changes detected";
    if (totalImages === 0) return "No screenshots captured";
    return `${totalImages} ${totalImages === 1 ? "screenshot" : "screenshots"}`;
  }, [isEmpty, hasFailures, hasNoUiChanges, totalImages]);

  // Don't render anything if empty
  if (isEmpty) {
    return null;
  }

  return (
    <section className="border-b border-neutral-200 dark:border-neutral-800">
      {/* Collapsible header row - matches WorkflowRunsSection style */}
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center gap-2 pl-3 pr-2.5 py-1.5 bg-neutral-50 dark:bg-neutral-900 hover:bg-neutral-100 dark:hover:bg-neutral-800/80 transition-colors text-left"
      >
        <div className="flex items-center justify-center" style={{ width: "20px" }}>
          {isExpanded ? (
            <ChevronDown className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400" />
          ) : (
            <ChevronRight className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400" />
          )}
        </div>
        <div className="flex items-center justify-center" style={{ width: "20px" }}>
          <Camera className="w-3 h-3 text-neutral-500 dark:text-neutral-400" />
        </div>
        <span className="text-xs text-neutral-700 dark:text-neutral-300">
          {summaryText}
        </span>
      </button>

      {/* Expanded content */}
      {isExpanded && (
        <div className="px-3.5 py-3 space-y-3 bg-white dark:bg-neutral-950">
          {currentEntry ? (
          <Dialog.Root
            open={isSlideshowOpen}
            onOpenChange={(open) => !open && closeSlideshow()}
          >
            <Dialog.Portal>
              <Dialog.Overlay className="fixed inset-0 bg-neutral-950/60 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=open]:fade-in data-[state=closed]:fade-out z-[var(--z-floating-high-overlay)]" />
              <Dialog.Content className="fixed left-1/2 top-1/2 z-[var(--z-floating-high)] flex max-h-[calc(100vh-4rem)] w-[min(2600px,calc(100vw-4rem))] -translate-x-1/2 -translate-y-1/2 flex-col gap-4 rounded-3xl border border-neutral-200 bg-white/95 p-4 shadow-2xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-950/95 sm:max-h-[calc(100vh-6rem)] sm:w-[min(2600px,calc(100vw-6rem))] sm:p-6">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="space-y-1 flex-1 min-w-0">
                    <Dialog.Title className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
                      {activeOverallIndex !== null ? `${activeOverallIndex}. ` : ""}
                      {currentEntry.image.fileName ?? "Screenshot"}
                    </Dialog.Title>
                    <Dialog.Description className="text-xs text-neutral-600 dark:text-neutral-400">
                      Image {currentEntry.indexInSet + 1} of {currentEntry.set.images.length}
                      <span className="px-1 text-neutral-400 dark:text-neutral-600">•</span>
                      {formatDistanceToNow(new Date(currentEntry.set.capturedAt), {
                        addSuffix: true,
                      })}
                    </Dialog.Description>
                    {currentEntry.image.description && (
                      <p className="text-sm text-neutral-700 dark:text-neutral-300 mt-2 max-w-2xl">
                        {currentEntry.image.description}
                      </p>
                    )}
                  </div>
                  <div className="flex items-center gap-2">
                    <div className="flex items-center gap-1 rounded-full border border-neutral-200 bg-white/90 px-2 py-1 text-xs font-medium text-neutral-600 shadow-sm dark:border-neutral-700 dark:bg-neutral-900/70 dark:text-neutral-200">
                      <button
                        type="button"
                        onClick={handleZoomOut}
                        disabled={!canZoomOut}
                        className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:hover:bg-neutral-800/80"
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
                        className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:hover:bg-neutral-800/80"
                        aria-label="Zoom in"
                      >
                        <ZoomIn className="h-3.5 w-3.5" />
                      </button>
                      <button
                        type="button"
                        onClick={() => resetZoomState()}
                        disabled={!canResetZoom}
                        className="rounded-full p-1 transition disabled:opacity-40 hover:bg-neutral-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:hover:bg-neutral-800/80"
                        aria-label="Reset zoom"
                      >
                        <RotateCcw className="h-3.5 w-3.5" />
                      </button>
                    </div>
                    <Dialog.Close asChild>
                      <button
                        type="button"
                        onClick={closeSlideshow}
                        className="rounded-full p-1.5 text-neutral-600 transition hover:bg-neutral-100 hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:text-neutral-300 dark:hover:bg-neutral-800/80 dark:hover:text-neutral-100"
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
                      className="rounded-full border border-neutral-200 bg-white p-2 text-neutral-600 transition hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-100"
                      aria-label="Previous screenshot"
                    >
                      <ChevronLeft className="h-5 w-5" />
                    </button>
                  ) : null}
                  <div
                    ref={viewportRef}
                    className={cn(
                      "relative flex h-[70vh] max-h-[calc(100vh-10rem)] min-h-[360px] w-full flex-1 items-center justify-center overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900",
                      zoom > 1
                        ? isPanning
                          ? "cursor-grabbing"
                          : "cursor-grab"
                        : "cursor-zoom-in",
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
                    <img
                      src={currentEntry.image.url ?? undefined}
                      alt={currentEntry.image.fileName ?? "Screenshot"}
                      className="select-none h-full w-full object-contain"
                      draggable={false}
                      onLoad={handleImageLoad}
                      style={{
                        transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${zoom})`,
                        transition: isPanning ? "none" : "transform 120ms ease-out",
                      }}
                    />
                  </div>
                  {showNavButtons ? (
                    <button
                      type="button"
                      onClick={goNext}
                      className="rounded-full border border-neutral-200 bg-white p-2 text-neutral-600 transition hover:text-neutral-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:border-neutral-700/80 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:text-neutral-100"
                      aria-label="Next screenshot"
                    >
                      <ChevronRight className="h-5 w-5" />
                    </button>
                  ) : null}
                </div>
                {hasMultipleImages ? (
                  <div className="space-y-2">
                    <div className="flex items-center justify-between text-xs font-medium text-neutral-500 dark:text-neutral-400">
                      <span className="sr-only">All screenshots</span>
                      <span className="tabular-nums text-neutral-600 dark:text-neutral-300">
                        {activeOverallIndex ?? "–"} / {flattenedImages.length}
                      </span>
                    </div>
                    <div className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1">
                      {flattenedImages.map((entry) => {
                        const isActiveThumb = entry.key === currentEntry?.key;
                        const label = entry.globalIndex + 1;
                        const displayName = entry.image.fileName ?? "Screenshot";
                        return (
                          <button
                            key={entry.key}
                            type="button"
                            onClick={() => setActiveImageKey(entry.key)}
                            className={cn(
                              "group relative flex h-24 w-40 flex-shrink-0 items-center justify-center overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-50 p-1 transition hover:border-neutral-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-400/70 dark:border-neutral-700 dark:bg-neutral-900/70 dark:hover:border-neutral-500",
                              isActiveThumb &&
                                "border-emerald-400/70 shadow-[0_0_0_1px_rgba(16,185,129,0.25)] dark:border-emerald-400/60",
                            )}
                            aria-label={`View ${displayName}`}
                            aria-current={isActiveThumb ? "true" : undefined}
                            title={displayName}
                          >
                            <img
                              src={entry.image.url ?? undefined}
                              alt={displayName}
                              className="h-full w-full object-contain"
                              loading="lazy"
                              decoding="async"
                            />
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
          {/* Simple horizontal scroll of all images */}
          {flattenedImages.length > 0 ? (
            <div className="flex gap-2 overflow-x-auto pb-1">
              {flattenedImages.map((entry) => {
                const displayName = entry.image.fileName ?? "Screenshot";
                const isActive = activeImageKey === entry.key;

                return (
                  <button
                    key={entry.key}
                    type="button"
                    onClick={() => setActiveImageKey(entry.key)}
                    className={cn(
                      "group relative flex-shrink-0 overflow-hidden rounded-lg border border-neutral-200 bg-neutral-100 transition-colors hover:border-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:hover:border-neutral-500",
                      isActive && "ring-2 ring-neutral-900 dark:ring-neutral-100"
                    )}
                    aria-label={`View ${displayName}`}
                  >
                    <img
                      src={entry.image.url ?? undefined}
                      alt={entry.image.description || displayName}
                      className="h-32 w-48 object-contain"
                      loading="lazy"
                    />
                    <div className="absolute inset-0 flex items-center justify-center bg-neutral-950/0 opacity-0 transition group-hover:bg-neutral-950/20 group-hover:opacity-100">
                      <Maximize2 className="h-4 w-4 text-white drop-shadow-md" />
                    </div>
                  </button>
                );
              })}
            </div>
          ) : (
            <p className="text-xs text-neutral-500 dark:text-neutral-400">
              {hasFailures
                ? "Screenshot capture failed."
                : "No screenshots available."}
            </p>
          )}
        </div>
      )}
    </section>
  );
}
