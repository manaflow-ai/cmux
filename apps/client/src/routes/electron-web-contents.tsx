import type { FormEvent } from "react";
import { useCallback, useEffect, useMemo, useState } from "react";

import { PersistentWebView } from "@/components/persistent-webview";
import { isElectron } from "@/lib/electron";
import { cn } from "@/lib/utils";
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/electron-web-contents")({
  component: ElectronWebContentsPage,
});

function ElectronWebContentsPage() {
  return (
    <div className="h-dvh overflow-y-auto">
      <div className="mx-auto flex w-full max-w-5xl flex-col gap-10 px-6 py-8">
        <LayoutPlayground />
        <MiniBrowser />
      </div>
    </div>
  );
}

function LayoutPlayground() {
  const [url, setUrl] = useState("https://example.com/");
  const [width, setWidth] = useState(720);
  const [height, setHeight] = useState(420);
  const [offsetTop, setOffsetTop] = useState(32);
  const [offsetLeft, setOffsetLeft] = useState(48);
  const [borderRadius, setBorderRadius] = useState(16);

  const isElectronRuntime = isElectron;

  return (
    <section className="space-y-6">
      <div className="space-y-3">
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-neutral-50">
          Layout Playground
        </h2>
        <p className="text-sm text-neutral-600 dark:text-neutral-300">
          Adjust the container dimensions and observe how the Electron
          WebContentsView tracks the surrounding layout. Try this inside the
          Electron app for the live embedded page.
        </p>
        {!isElectronRuntime ? (
          <p className="rounded-md border border-neutral-300 bg-neutral-100 px-3 py-2 text-sm text-neutral-700 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-200">
            Launch the cmux Electron app to see the embedded site instead of the
            placeholder.
          </p>
        ) : null}
      </div>

      <div className="rounded-lg border border-neutral-200 bg-white p-5 shadow-sm dark:border-neutral-800 dark:bg-neutral-950">
        <div className="space-y-4">
          <label className="flex flex-col gap-2 text-sm text-neutral-700 dark:text-neutral-300">
            <span>URL</span>
            <input
              type="text"
              value={url}
              onChange={(event) => setUrl(event.target.value)}
              className="w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-sm focus:border-neutral-500 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
              placeholder="https://example.com/"
              spellCheck={false}
            />
          </label>

          <div className="grid gap-4 md:grid-cols-2">
            <SliderRow
              label="Width"
              value={width}
              onChange={setWidth}
              min={480}
              max={1100}
              step={10}
              suffix="px"
            />
            <SliderRow
              label="Height"
              value={height}
              onChange={setHeight}
              min={240}
              max={900}
              step={10}
              suffix="px"
            />
            <SliderRow
              label="Top Offset"
              value={offsetTop}
              onChange={setOffsetTop}
              min={0}
              max={200}
              step={4}
              suffix="px"
            />
            <SliderRow
              label="Left Offset"
              value={offsetLeft}
              onChange={setOffsetLeft}
              min={0}
              max={200}
              step={4}
              suffix="px"
            />
            <SliderRow
              label="Corner Radius"
              value={borderRadius}
              onChange={setBorderRadius}
              min={0}
              max={48}
              step={1}
              suffix="px"
            />
          </div>
        </div>

        <div className="mt-6 overflow-auto rounded-md border border-dashed border-neutral-300 bg-neutral-50 p-6 dark:border-neutral-800 dark:bg-neutral-950">
          <div
            className="flex justify-start"
            style={{ paddingTop: offsetTop, paddingLeft: offsetLeft }}
          >
            <div
              className="relative overflow-hidden border border-neutral-300 shadow-sm dark:border-neutral-700"
              style={{ width, height, borderRadius }}
            >
              <PersistentWebView
                persistKey="layout-playground"
                src={url}
                className="h-full w-full"
                backgroundColor="#ffffff"
                borderRadius={borderRadius}
                retainOnUnmount
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

interface SliderRowProps {
  label: string;
  value: number;
  onChange: (nextValue: number) => void;
  min: number;
  max: number;
  step?: number;
  suffix?: string;
}

function SliderRow({
  label,
  value,
  onChange,
  min,
  max,
  step = 1,
  suffix,
}: SliderRowProps) {
  return (
    <label className="flex flex-col gap-2 text-sm text-neutral-700 dark:text-neutral-300">
      <span className="flex items-center justify-between">
        <span>{label}</span>
        <span className="font-mono text-xs text-neutral-500 dark:text-neutral-400">
          {value}
          {suffix}
        </span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
        className="w-full accent-neutral-600"
      />
    </label>
  );
}

interface BrowserTab {
  id: string;
  url: string;
  title: string;
}

const DEFAULT_TAB_URLS: string[] = [
  "https://example.com/",
  "https://news.ycombinator.com/",
  "https://www.wikipedia.org/",
];

function normalizeAddressInput(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "https://duckduckgo.com/";
  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+-.]*:/.test(trimmed);
  if (hasScheme) return trimmed;
  if (trimmed.includes(" ")) {
    return `https://duckduckgo.com/?q=${encodeURIComponent(trimmed)}`;
  }
  return `https://${trimmed}`;
}

function deriveTabTitle(url: string): string {
  try {
    const parsed = new URL(url);
    if (parsed.hostname) return parsed.hostname.replace(/^www\./, "");
  } catch {
    // ignore invalid URLs
  }
  return url;
}

function createTab(url: string): BrowserTab {
  const normalized = normalizeAddressInput(url);
  const id =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random()}`;
  return {
    id,
    url: normalized,
    title: deriveTabTitle(normalized),
  };
}

function MiniBrowser() {
  const initialTabs = useMemo(() => {
    const base = DEFAULT_TAB_URLS.map((url) => createTab(url));
    return base.length > 0 ? base : [createTab("https://example.com/")];
  }, []);

  const [tabs, setTabs] = useState<BrowserTab[]>(initialTabs);
  const [activeId, setActiveId] = useState<string>(
    initialTabs[0]?.id ?? createTab("https://example.com/").id
  );
  const activeTab = useMemo(
    () => tabs.find((tab) => tab.id === activeId) ?? tabs[0] ?? null,
    [tabs, activeId]
  );
  const [addressBarValue, setAddressBarValue] = useState(activeTab?.url ?? "");

  useEffect(() => {
    if (!activeTab) return;
    setAddressBarValue(activeTab.url);
  }, [activeTab]);

  useEffect(() => {
    if (tabs.length === 0) {
      const replacement = createTab("https://example.com/");
      setTabs([replacement]);
      setActiveId(replacement.id);
      return;
    }
    if (!tabs.some((tab) => tab.id === activeId)) {
      setActiveId(tabs[0].id);
    }
  }, [tabs, activeId]);

  const handleNavigate = useCallback(
    (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      if (!activeTab) return;
      const nextUrl = normalizeAddressInput(addressBarValue);
      setTabs((prev) =>
        prev.map((tab) =>
          tab.id === activeTab.id
            ? {
                ...tab,
                url: nextUrl,
                title: deriveTabTitle(nextUrl),
              }
            : tab
        )
      );
    },
    [activeTab, addressBarValue]
  );

  const handleAddTab = useCallback(() => {
    const newTab = createTab("https://duckduckgo.com/");
    setTabs((prev) => [...prev, newTab]);
    setActiveId(newTab.id);
  }, []);
  const closeTab = useCallback(
    (tabId: string) => {
      setTabs((prev) => {
        if (prev.length === 1) return prev;
        const index = prev.findIndex((tab) => tab.id === tabId);
        if (index === -1) return prev;
        const next = [...prev.slice(0, index), ...prev.slice(index + 1)];
        if (activeId === tabId) {
          const fallbackIndex = index > 0 ? index - 1 : 0;
          const nextActive = next[fallbackIndex]?.id ?? next[0]?.id;
          if (nextActive) {
            setActiveId(nextActive);
          }
        }
        return next;
      });
    },
    [activeId]
  );

  if (!isElectron) {
    return (
      <section className="space-y-3">
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-neutral-50">
          Mini Browser
        </h2>
        <p className="text-sm text-neutral-600 dark:text-neutral-300">
          Launch the Electron desktop app to try the tabbed mini browser demo.
        </p>
      </section>
    );
  }

  return (
    <section className="space-y-4">
      <div className="space-y-2">
        <h2 className="text-xl font-semibold text-neutral-900 dark:text-neutral-50">
          Mini Browser
        </h2>
        <p className="text-sm text-neutral-600 dark:text-neutral-300">
          Each tab owns a dedicated WebContentsView. Background tabs stay hidden
          but keep their state alive.
        </p>
      </div>

      <div className="rounded-lg border border-neutral-200 bg-white shadow-sm dark:border-neutral-800 dark:bg-neutral-950">
        <div className="border-b border-neutral-200 bg-neutral-50 px-3 py-2 dark:border-neutral-800 dark:bg-neutral-900">
          <div className="flex items-center gap-2 overflow-x-auto pb-1">
            {tabs.map((tab) => {
              const isActive = tab.id === activeId;
              return (
                <button
                  key={tab.id}
                  type="button"
                  onClick={() => setActiveId(tab.id)}
                  className={cn(
                    "group flex items-center gap-2 rounded-md px-3 py-1.5 text-sm transition",
                    isActive
                      ? "bg-neutral-900 text-neutral-100 dark:bg-neutral-200 dark:text-neutral-900"
                      : "bg-neutral-200/70 text-neutral-700 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-700"
                  )}
                >
                  <span className="max-w-[160px] truncate">{tab.title}</span>
                  {tabs.length > 1 ? (
                    <span
                      role="button"
                      aria-label="Close tab"
                      className="rounded px-1 text-xs opacity-60 transition group-hover:opacity-100"
                      onClick={(event) => {
                        event.stopPropagation();
                        closeTab(tab.id);
                      }}
                    >
                      ×
                    </span>
                  ) : null}
                </button>
              );
            })}
            <button
              type="button"
              onClick={handleAddTab}
              className="flex h-7 w-7 items-center justify-center rounded-md border border-dashed border-neutral-300 text-lg font-semibold text-neutral-600 transition hover:bg-neutral-100 active:bg-neutral-200 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-800"
            >
              +
            </button>
          </div>
        </div>

        <form
          onSubmit={handleNavigate}
          className="flex items-center gap-3 border-b border-neutral-200 px-3 py-2 dark:border-neutral-800"
        >
          <input
            type="text"
            value={addressBarValue}
            onChange={(event) => setAddressBarValue(event.target.value)}
            placeholder="Enter URL or search"
            className="flex-1 rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-sm focus:border-neutral-500 focus:outline-none dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100"
            spellCheck={false}
          />
          <button
            type="submit"
            className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-neutral-800 active:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Go
          </button>
        </form>

        <div className="relative h-[520px] overflow-hidden rounded-b-lg border-t border-neutral-200 bg-neutral-100 dark:border-neutral-800 dark:bg-neutral-900">
          {tabs.map((tab) => {
            const isActive = tab.id === activeId;
            return (
              <PersistentWebView
                key={tab.id}
                persistKey={tab.id}
                src={tab.url}
                suspended={!isActive}
                retainOnUnmount
                className={cn(
                  "absolute inset-0 h-full w-full transition-opacity duration-200",
                  isActive ? "opacity-100" : "opacity-0"
                )}
                style={{ pointerEvents: isActive ? "auto" : "none" }}
                backgroundColor="#ffffff"
                borderRadius={12}
              />
            );
          })}
        </div>
      </div>
    </section>
  );
}
