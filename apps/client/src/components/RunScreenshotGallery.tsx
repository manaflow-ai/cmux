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
}

interface RunScreenshotSet {
  _id: Id<"taskRunScreenshotSets">;
  taskId: Id<"tasks">;
  runId: Id<"taskRuns">;
  status: ScreenshotStatus;
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

const STATUS_LABELS: Record<ScreenshotStatus, string> = {
  completed: "Completed",
  failed: "Failed",
  skipped: "Skipped",
};

const STATUS_STYLES: Record<ScreenshotStatus, string> = {
  completed:
    "bg-emerald-100/70 text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed: "bg-rose-100/70 text-rose-700 dark:bg-rose-950/60 dark:text-rose-300",
  skipped:
    "bg-neutral-200/70 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-300",
};

const getImageKey = (
  setId: Id<"taskRunScreenshotSets">,
  image: ScreenshotImage,
  indexInSet: number,
) => `${setId}:${image.storageId}:${indexInSet}`;

export function RunScreenshotGallery(props: RunScreenshotGalleryProps) {
  const { screenshotSets, highlightedSetId } = props;
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

  if (sortedScreenshotSets.length === 0) {
    return null;
  }

  return (
    <section className="border-b border-neutral-200 bg-neutral-50/60 dark:border-neutral-800 dark:bg-neutral-950/40">
      <div className="px-3.5 pt-3 pb-2 flex items-center justify-between gap-3">
        <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
          Screenshots
        </h2>
        <span className="text-xs text-neutral-600 dark:text-neutral-400">
          {sortedScreenshotSets.length}{" "}
          {sortedScreenshotSets.length === 1 ? "capture" : "captures"}
        </span>
      </div>
      <div className="px-3.5 pb-4 space-y-4">
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
                      {currentEntry.image.fileName ?? "Screenshot"}
                    </Dialog.Title>
                    <Dialog.Description className="text-xs text-neutral-600 dark:text-neutral-400">
                      Image {currentEntry.indexInSet + 1} of {currentEntry.set.images.length}
                      <span className="px-1 text-neutral-400 dark:text-neutral-600">•</span>
                      {formatDistanceToNow(new Date(currentEntry.set.capturedAt), {
                        addSuffix: true,
                      })}
                    </Dialog.Description>
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
        {/* Render the most recent (latest) set prominently */}
        {(() => {
          const latestSet = sortedScreenshotSets[sortedScreenshotSets.length - 1];
          const isLatestHighlighted =
            !highlightedSetId || highlightedSetId === latestSet._id;
          return (
            <ScreenshotSetCard
              set={latestSet}
              isHighlighted={isLatestHighlighted}
              globalIndexByKey={globalIndexByKey}
              activeImageKey={activeImageKey}
              setActiveImageKey={setActiveImageKey}
            />
          );
        })()}

        {/* Older sets in a collapsible section */}
        {sortedScreenshotSets.length > 1 && (
          <OlderScreenshotSets
            sets={sortedScreenshotSets.slice(0, -1).reverse()}
            globalIndexByKey={globalIndexByKey}
            activeImageKey={activeImageKey}
            setActiveImageKey={setActiveImageKey}
            highlightedSetId={highlightedSetId}
          />
        )}
      </div>
    </section>
  );
}

interface ScreenshotSetCardProps {
  set: RunScreenshotSet;
  isHighlighted: boolean;
  globalIndexByKey: Map<string, number>;
  activeImageKey: string | null;
  setActiveImageKey: (key: string | null) => void;
  compact?: boolean;
}

function ScreenshotSetCard({
  set,
  isHighlighted,
  globalIndexByKey,
  activeImageKey,
  setActiveImageKey,
  compact = false,
}: ScreenshotSetCardProps) {
  const capturedAtDate = new Date(set.capturedAt);
  const relativeCapturedAt = formatDistanceToNow(capturedAtDate, {
    addSuffix: true,
  });
  const shortCommit = set.commitSha?.slice(0, 12);

  return (
    <article
      className={cn(
        "rounded-xl border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950/70 p-3 transition-shadow",
        isHighlighted &&
          "border-emerald-400/70 dark:border-emerald-400/60 shadow-[0_0_0_1px_rgba(16,185,129,0.25)]"
      )}
    >
      <div className="flex flex-wrap items-center gap-2">
        <span
          className={cn(
            "px-2 py-0.5 text-xs font-medium rounded-full",
            STATUS_STYLES[set.status]
          )}
        >
          {STATUS_LABELS[set.status]}
        </span>
        {isHighlighted && (
          <span className="px-2 py-0.5 text-xs font-medium rounded-full bg-emerald-100/80 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-300">
            Latest
          </span>
        )}
        <span
          className="text-xs text-neutral-600 dark:text-neutral-400"
          title={capturedAtDate.toLocaleString()}
        >
          {relativeCapturedAt}
        </span>
        {shortCommit && (
          <span className="text-xs font-mono text-neutral-600 dark:text-neutral-400">
            {shortCommit.toLowerCase()}
          </span>
        )}
        {set.images.length > 0 && (
          <span className="text-xs text-neutral-500 dark:text-neutral-500">
            {set.images.length} {set.images.length === 1 ? "image" : "images"}
          </span>
        )}
      </div>
      {set.error && (
        <p className="mt-2 text-xs text-rose-600 dark:text-rose-400">
          {set.error}
        </p>
      )}
      {set.images.length > 0 ? (
        <div
          className={cn(
            "mt-3 flex gap-3 overflow-x-auto pb-1",
            compact && "gap-2"
          )}
        >
          {set.images.map((image, indexInSet) => {
            const displayName = image.fileName ?? "Screenshot";
            const stableKey = getImageKey(set._id, image, indexInSet);
            if (!image.url) {
              return (
                <div
                  key={stableKey}
                  className={cn(
                    "flex items-center justify-center rounded-lg border border-dashed border-neutral-300 bg-neutral-100 text-xs text-neutral-500 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400",
                    compact ? "h-32 min-w-[140px]" : "h-48 min-w-[200px]"
                  )}
                >
                  URL expired
                </div>
              );
            }
            const flatIndex = globalIndexByKey.get(stableKey) ?? null;
            const humanIndex = flatIndex !== null ? flatIndex + 1 : null;
            const isActive = activeImageKey === stableKey;

            return (
              <button
                key={stableKey}
                type="button"
                onClick={() => setActiveImageKey(stableKey)}
                className={cn(
                  "group relative flex flex-col overflow-hidden rounded-lg border border-neutral-200 bg-neutral-50 text-left transition-colors hover:border-neutral-400 dark:border-neutral-700 dark:bg-neutral-900/70 dark:hover:border-neutral-500",
                  compact ? "w-[160px]" : "w-[220px]",
                  isActive &&
                    "border-emerald-400/70 shadow-[0_0_0_1px_rgba(16,185,129,0.25)] dark:border-emerald-400/60"
                )}
                aria-label={`Open ${displayName} in slideshow`}
              >
                <img
                  src={image.url}
                  alt={displayName}
                  className={cn(
                    "object-contain bg-neutral-100 dark:bg-neutral-950",
                    compact ? "h-32 w-[160px]" : "h-48 w-[220px]"
                  )}
                  loading="lazy"
                />
                <div className="absolute top-2 right-2 text-neutral-600 opacity-0 transition group-hover:opacity-100 dark:text-neutral-300">
                  <Maximize2 className="h-3.5 w-3.5" />
                </div>
                <div className="border-t border-neutral-200 px-2 py-1 text-xs text-neutral-600 dark:border-neutral-700 dark:text-neutral-300 truncate">
                  {humanIndex !== null ? `${humanIndex}. ` : ""}
                  {displayName}
                </div>
              </button>
            );
          })}
        </div>
      ) : (
        <p className="mt-2 text-xs text-neutral-500 dark:text-neutral-400">
          {set.status === "failed"
            ? "Screenshot capture failed before any images were saved."
            : "No screenshots were captured for this attempt."}
        </p>
      )}
    </article>
  );
}

interface OlderScreenshotSetsProps {
  sets: RunScreenshotSet[];
  globalIndexByKey: Map<string, number>;
  activeImageKey: string | null;
  setActiveImageKey: (key: string | null) => void;
  highlightedSetId?: Id<"taskRunScreenshotSets"> | null;
}

function OlderScreenshotSets({
  sets,
  globalIndexByKey,
  activeImageKey,
  setActiveImageKey,
  highlightedSetId,
}: OlderScreenshotSetsProps) {
  const [isExpanded, setIsExpanded] = useState(false);

  if (sets.length === 0) return null;

  const totalImages = sets.reduce((acc, set) => acc + set.images.length, 0);

  return (
    <div className="rounded-xl border border-neutral-200 dark:border-neutral-800 bg-neutral-50/50 dark:bg-neutral-900/30 overflow-hidden">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center justify-between gap-3 px-3 py-2.5 text-left hover:bg-neutral-100/60 dark:hover:bg-neutral-800/40 transition-colors"
      >
        <div className="flex items-center gap-2">
          <ChevronDown
            className={cn(
              "w-4 h-4 text-neutral-500 transition-transform",
              isExpanded && "rotate-180"
            )}
          />
          <span className="text-sm font-medium text-neutral-700 dark:text-neutral-300">
            {sets.length} older {sets.length === 1 ? "capture" : "captures"}
          </span>
          {totalImages > 0 && (
            <span className="text-xs text-neutral-500 dark:text-neutral-500">
              ({totalImages} {totalImages === 1 ? "image" : "images"})
            </span>
          )}
        </div>
        <span className="text-xs text-neutral-500 dark:text-neutral-500">
          {isExpanded ? "Hide" : "Show"}
        </span>
      </button>

      {isExpanded && (
        <div className="px-3 pb-3 space-y-3 border-t border-neutral-200 dark:border-neutral-800">
          <div className="pt-3" />
          {sets.map((set) => (
            <ScreenshotSetCard
              key={set._id}
              set={set}
              isHighlighted={highlightedSetId === set._id}
              globalIndexByKey={globalIndexByKey}
              activeImageKey={activeImageKey}
              setActiveImageKey={setActiveImageKey}
              compact
            />
          ))}
        </div>
      )}
    </div>
  );
}
