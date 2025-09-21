import clsx from "clsx";
import * as Popover from "@radix-ui/react-popover";
import { ArrowLeft, ArrowRight, ChevronDown, History as HistoryIcon } from "lucide-react";
import { useEffect, useState, type CSSProperties } from "react";
import { useRouter, useRouterState } from "@tanstack/react-router";
import type { HistoryLocation, RouterHistory } from "@tanstack/history";

const MAX_HISTORY_ENTRIES = 20;

type HistoryEntry = {
  key: string;
  label: string;
  historyIndex: number;
};

type HistoryState = {
  entries: HistoryEntry[];
  currentIndex: number;
};

type HistorySubscriberArgs = Parameters<Parameters<RouterHistory["subscribe"]>[0]>[0];
type HistorySubscriberAction = HistorySubscriberArgs["action"];

const decodeSegment = (value: string) => {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
};

const formatLocationLabel = (location: HistoryLocation) => {
  const path = location.pathname ? decodeSegment(location.pathname) : "/";
  const search = location.search ? decodeSegment(location.search) : "";
  const hash = location.hash ? decodeSegment(location.hash) : "";
  return `${path}${search}${hash}`;
};

type LocationState = {
  __TSR_key?: string;
  key?: string;
  __TSR_index?: number;
};

const createHistoryEntry = (location: HistoryLocation): HistoryEntry => {
  const state = (location.state ?? {}) as LocationState;
  const key = state.__TSR_key ?? state.key ?? location.href;
  const historyIndex = state.__TSR_index ?? 0;
  return {
    key,
    label: formatLocationLabel(location),
    historyIndex,
  };
};

const ensureLimit = (
  entries: HistoryEntry[],
  currentKey: string,
  trimFrom: "start" | "end",
): HistoryState => {
  if (entries.length <= MAX_HISTORY_ENTRIES) {
    const idx = entries.findIndex((item) => item.key === currentKey);
    return {
      entries,
      currentIndex:
        idx === -1
          ? entries.length > 0
            ? entries.length - 1
            : -1
          : idx,
    };
  }

  const overflow = entries.length - MAX_HISTORY_ENTRIES;
  let trimmed: HistoryEntry[];
  if (trimFrom === "start") {
    trimmed = entries.slice(overflow);
  } else {
    trimmed = entries.slice(0, entries.length - overflow);
  }

  const idx = trimmed.findIndex((item) => item.key === currentKey);
  return {
    entries: trimmed,
    currentIndex:
      idx === -1
        ? trimmed.length === 0
          ? -1
          : trimFrom === "start"
            ? trimmed.length - 1
            : 0
        : idx,
  };
};

const updateForReplace = (prev: HistoryState, entry: HistoryEntry): HistoryState => {
  if (prev.entries.length === 0) {
    return {
      entries: [entry],
      currentIndex: 0,
    };
  }

  const nextEntries = [...prev.entries];
  const indexToUpdate =
    prev.currentIndex >= 0 && prev.currentIndex < nextEntries.length
      ? prev.currentIndex
      : nextEntries.findIndex((item) => item.key === entry.key);

  if (indexToUpdate !== -1) {
    nextEntries[indexToUpdate] = entry;
    return {
      entries: nextEntries,
      currentIndex: indexToUpdate,
    };
  }

  const appended = [...nextEntries, entry];
  return ensureLimit(appended, entry.key, "start");
};

const updateHistoryState = (
  prev: HistoryState,
  entry: HistoryEntry,
  action: HistorySubscriberAction,
): HistoryState => {
  switch (action.type) {
    case "PUSH": {
      const baseEntries =
        prev.currentIndex >= 0 ? prev.entries.slice(0, prev.currentIndex + 1) : prev.entries.slice();
      const appended = [...baseEntries, entry];
      return ensureLimit(appended, entry.key, "start");
    }
    case "REPLACE": {
      return updateForReplace(prev, entry);
    }
    case "BACK": {
      const existingIndex = prev.entries.findIndex((item) => item.key === entry.key);
      if (existingIndex !== -1) {
        return {
          entries: prev.entries,
          currentIndex: existingIndex,
        };
      }

      const nextEntries = [entry, ...prev.entries];
      return ensureLimit(nextEntries, entry.key, "end");
    }
    case "FORWARD": {
      const existingIndex = prev.entries.findIndex((item) => item.key === entry.key);
      if (existingIndex !== -1) {
        return {
          entries: prev.entries,
          currentIndex: existingIndex,
        };
      }

      const nextEntries = [...prev.entries, entry];
      return ensureLimit(nextEntries, entry.key, "start");
    }
    case "GO": {
      if (action.index === 0) {
        return updateForReplace(prev, entry);
      }

      const direction = action.index < 0 ? "back" : "forward";
      const existingIndex = prev.entries.findIndex((item) => item.key === entry.key);
      if (existingIndex !== -1) {
        return {
          entries: prev.entries,
          currentIndex: existingIndex,
        };
      }

      if (direction === "back") {
        const nextEntries = [entry, ...prev.entries];
        return ensureLimit(nextEntries, entry.key, "end");
      }

      const nextEntries = [...prev.entries, entry];
      return ensureLimit(nextEntries, entry.key, "start");
    }
    default:
      return prev;
  }
};

export function SidebarHistoryControls() {
  const router = useRouter();
  const location = useRouterState({ select: (state) => state.location });
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [historyState, setHistoryState] = useState<HistoryState>(() => {
    const initialLocation = router.history.location;
    if (!initialLocation) {
      return { entries: [], currentIndex: -1 };
    }
    return { entries: [createHistoryEntry(initialLocation)], currentIndex: 0 };
  });

  useEffect(() => {
    const unsubscribe = router.history.subscribe(({ location: nextLocation, action }) => {
      setHistoryState((prev) => updateHistoryState(prev, createHistoryEntry(nextLocation), action));
    });

    return () => {
      unsubscribe();
    };
  }, [router]);

  useEffect(() => {
    // Ensure the current location is tracked even if no history events have fired yet
    setHistoryState((prev) => {
      const historyLocation = router.history.location;
      if (!historyLocation) return prev;
      const currentEntry = createHistoryEntry(historyLocation);
      const existingIndex = prev.entries.findIndex((item) => item.key === currentEntry.key);
      if (existingIndex !== -1) {
        const existingEntry = prev.entries[existingIndex];
        if (
          existingEntry.label === currentEntry.label &&
          existingEntry.historyIndex === currentEntry.historyIndex
        ) {
          if (prev.currentIndex === existingIndex) {
            return prev;
          }
          return {
            entries: prev.entries,
            currentIndex: existingIndex,
          };
        }
        const updatedEntries = [...prev.entries];
        updatedEntries[existingIndex] = currentEntry;
        return {
          entries: updatedEntries,
          currentIndex: existingIndex,
        };
      }
      if (prev.entries.length === 0) {
        return { entries: [currentEntry], currentIndex: 0 };
      }
      return prev;
    });
  }, [location, router]);

  if (!location || historyState.entries.length === 0) {
    return null;
  }

  const locationState = (location.state ?? {}) as LocationState;
  const currentHistoryIndex = locationState.__TSR_index ?? 0;
  const currentKey = locationState.__TSR_key ?? locationState.key ?? location.href;
  const canGoBack = router.history.canGoBack();
  const canGoForward = currentHistoryIndex < router.history.length - 1;
  const entriesForDisplay = [...historyState.entries].reverse();

  const handleBack = () => {
    if (canGoBack) {
      router.history.back();
    }
  };

  const handleForward = () => {
    if (canGoForward) {
      router.history.forward();
    }
  };

  const handleSelectEntry = (entry: HistoryEntry) => {
    const delta = entry.historyIndex - currentHistoryIndex;
    if (delta === 0) {
      setPopoverOpen(false);
      return;
    }
    router.history.go(delta);
    setPopoverOpen(false);
  };

  return (
    <div
      className="flex items-center gap-1"
      style={{ WebkitAppRegion: "no-drag" } as CSSProperties}
    >
      <button
        type="button"
        onClick={handleBack}
        disabled={!canGoBack}
        className={clsx(
          "w-7 h-7 flex items-center justify-center rounded-md border border-neutral-200 dark:border-neutral-800",
          "text-neutral-600 dark:text-neutral-300 transition-colors",
          "disabled:opacity-50 disabled:cursor-not-allowed",
          "hover:bg-neutral-100 dark:hover:bg-neutral-900"
        )}
        aria-label="Go back"
        title="Back"
      >
        <ArrowLeft className="w-4 h-4" aria-hidden="true" />
      </button>
      <button
        type="button"
        onClick={handleForward}
        disabled={!canGoForward}
        className={clsx(
          "w-7 h-7 flex items-center justify-center rounded-md border border-neutral-200 dark:border-neutral-800",
          "text-neutral-600 dark:text-neutral-300 transition-colors",
          "disabled:opacity-50 disabled:cursor-not-allowed",
          "hover:bg-neutral-100 dark:hover:bg-neutral-900"
        )}
        aria-label="Go forward"
        title="Forward"
      >
        <ArrowRight className="w-4 h-4" aria-hidden="true" />
      </button>
      <Popover.Root open={popoverOpen} onOpenChange={setPopoverOpen}>
        <Popover.Trigger asChild>
          <button
            type="button"
            className="flex items-center gap-1 px-2 h-7 rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-600 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-900 transition-colors"
            aria-label="Open navigation history"
          >
            <HistoryIcon className="w-4 h-4" aria-hidden="true" />
            <ChevronDown className="w-3 h-3" aria-hidden="true" />
          </button>
        </Popover.Trigger>
        <Popover.Portal>
          <Popover.Content
            side="bottom"
            align="start"
            sideOffset={6}
            className="z-[var(--z-popover)] w-64 max-h-72 overflow-y-auto rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 shadow-lg p-1"
          >
            <div className="flex flex-col gap-1">
              {entriesForDisplay.map((entry) => {
                const isActive = entry.key === currentKey;
                return (
                  <button
                    key={entry.key}
                    type="button"
                    onClick={() => handleSelectEntry(entry)}
                    className={clsx(
                      "text-left px-2 py-1.5 rounded-md text-xs font-medium transition-colors",
                      "text-neutral-700 dark:text-neutral-200",
                      "hover:bg-neutral-100 dark:hover:bg-neutral-800",
                      isActive && "bg-neutral-200 dark:bg-neutral-800"
                    )}
                    title={entry.label}
                  >
                    <div className="truncate">{entry.label}</div>
                  </button>
                );
              })}
            </div>
          </Popover.Content>
        </Popover.Portal>
      </Popover.Root>
    </div>
  );
}
