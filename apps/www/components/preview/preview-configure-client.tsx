"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type DragEvent as ReactDragEvent,
  type MouseEvent as ReactMouseEvent,
  type ChangeEvent,
} from "react";
import {
  Loader2,
  ArrowLeft,
  Eye,
  EyeOff,
  Minus,
  Plus,
  Code2,
  Monitor,
  GripVertical,
  Maximize2,
  Minimize2,
} from "lucide-react";
import Link from "next/link";
import { Accordion, AccordionItem } from "@heroui/react";
import { formatEnvVarsContent } from "@cmux/shared/utils/format-env-vars-content";
import clsx from "clsx";

const MASKED_ENV_VALUE = "••••••••••••••••";

type SandboxInstance = {
  instanceId: string;
  vscodeUrl: string;
  workerUrl: string;
  vncUrl?: string;
  provider: string;
};

type PreviewConfigureClientProps = {
  teamSlugOrId: string;
  repo: string;
  installationId: string | null;
};

type EnvVar = { name: string; value: string; isSecret: boolean };

type PanelPosition = "topLeft" | "bottomLeft";
type PanelType = "workspace" | "browser";
type PreviewMode = "split" | "vscode" | "browser";

function normalizeVncUrl(url: string): string | null {
  try {
    const target = new URL(url);
    target.searchParams.set("autoconnect", "1");
    target.searchParams.set("resize", "scale");
    return target.toString();
  } catch {
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}autoconnect=1&resize=scale`;
  }
}

function resolveMorphHostId(
  instanceId?: string,
  workspaceUrl?: string
): string | null {
  if (instanceId && instanceId.trim().length > 0) {
    return instanceId.trim().toLowerCase().replace(/_/g, "-");
  }

  if (!workspaceUrl) {
    return null;
  }

  try {
    const url = new URL(workspaceUrl);
    const directMatch = url.hostname.match(
      /^port-\d+-(morphvm-[^.]+)\.http\.cloud\.morph\.so$/i
    );
    if (directMatch && directMatch[1]) {
      return directMatch[1].toLowerCase();
    }

    const proxyMatch = url.hostname.match(
      /^cmux-([^-]+)-[a-z0-9-]+-\d+\.cmux\.(?:app|dev|sh|local|localhost)$/i
    );
    if (proxyMatch && proxyMatch[1]) {
      return `morphvm-${proxyMatch[1].toLowerCase()}`;
    }
  } catch {
    return null;
  }

  return null;
}

function deriveVncUrl(
  instanceId?: string,
  workspaceUrl?: string
): string | null {
  const morphHostId = resolveMorphHostId(instanceId, workspaceUrl);
  if (!morphHostId) {
    return null;
  }

  const hostname = `port-39380-${morphHostId}.http.cloud.morph.so`;
  const baseUrl = `https://${hostname}/vnc.html`;
  return normalizeVncUrl(baseUrl);
}

const PANEL_DRAG_START_EVENT = "cmux:panel-drag-start";
const PANEL_DRAG_END_EVENT = "cmux:panel-drag-end";
const PANEL_DRAGGING_CLASS = "cmux-panel-dragging";
const PANEL_DRAGGING_STYLE_ID = "cmux-panel-dragging-style";
const PANEL_DRAGGING_STYLE_CONTENT = `
  body.${PANEL_DRAGGING_CLASS} iframe,
  body.${PANEL_DRAGGING_CLASS} [data-iframe-key],
  body.${PANEL_DRAGGING_CLASS} [data-persistent-iframe-overlay] {
    pointer-events: none !important;
  }
`;

declare global {
  interface Window {
    __previewPanelDragPointerHandlers?: {
      start: EventListener;
      end: EventListener;
      nativeEnd: EventListener;
      visibilityChange: EventListener;
      windowBlur: EventListener;
    };
    __previewActivePanelDragCount?: number;
  }
}

const ensureInitialEnvVars = (initial?: EnvVar[]): EnvVar[] => {
  const base = (initial ?? []).map((item) => ({
    name: item.name,
    value: item.value,
    isSecret: item.isSecret ?? true,
  }));
  if (base.length === 0) {
    return [{ name: "", value: "", isSecret: true }];
  }
  const last = base[base.length - 1];
  if (!last || last.name.trim().length > 0 || last.value.trim().length > 0) {
    base.push({ name: "", value: "", isSecret: true });
  }
  return base;
};

function parseEnvBlock(text: string): Array<{ name: string; value: string }> {
  const normalized = text.replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const results: Array<{ name: string; value: string }> = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#") || trimmed.startsWith("//")) continue;

    const cleanLine = trimmed.replace(/^export\s+/, "").replace(/^set\s+/, "");
    const eqIdx = cleanLine.indexOf("=");

    if (eqIdx === -1) continue;

    const key = cleanLine.slice(0, eqIdx).trim();
    let value = cleanLine.slice(eqIdx + 1).trim();

    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }

    if (key && !/\s/.test(key)) {
      results.push({ name: key, value });
    }
  }

  return results;
}

const SCRIPT_COPY = {
  maintenance: {
    description: "Script that runs after git pull in case new dependencies were added.",
    subtitle: "We execute this from /root/workspace, where your repositories are cloned. For example, cd my-repo && npm install installs dependencies inside /root/workspace/my-repo.",
    placeholder: `# e.g.
bun install
npm install
uv sync
pip install -r requirements.txt
etc.`,
  },
  dev: {
    description: "Script that starts the development server.",
    subtitle: "Runs from /root/workspace as well, so reference repos with relative paths—e.g. cd web && npm run dev.",
    placeholder: `# e.g.
npm run dev
bun dev
python manage.py runserver
rails server
cargo run
etc.`,
  },
};

// Persistent iframe manager for Next.js
type PersistentIframeOptions = {
  allow?: string;
  sandbox?: string;
};

type MountOptions = {
  backgroundColor?: string;
};

class SimplePersistentIframeManager {
  private iframes = new Map<
    string,
    { iframe: HTMLIFrameElement; wrapper: HTMLDivElement; allow?: string; sandbox?: string }
  >();
  private container: HTMLDivElement | null = null;

  constructor() {
    if (typeof document !== "undefined") {
      this.initContainer();
    }
  }

  private initContainer() {
    this.container = document.createElement("div");
    this.container.id = "persistent-iframe-container";
    this.container.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 0;
      height: 0;
      pointer-events: none;
      z-index: 9999;
    `;
    document.body.appendChild(this.container);
  }

  setVisibility(key: string, visible: boolean) {
    const entry = this.iframes.get(key);
    if (!entry) {
      return;
    }
    entry.wrapper.style.visibility = visible ? "visible" : "hidden";
    entry.wrapper.style.pointerEvents = visible ? "auto" : "none";
  }

  getOrCreateIframe(
    key: string,
    url: string,
    options?: PersistentIframeOptions
  ): HTMLIFrameElement {
    const existing = this.iframes.get(key);
    if (existing) {
      if (options?.allow && existing.allow !== options.allow) {
        existing.iframe.allow = options.allow;
        existing.allow = options.allow;
      }
      if (options?.sandbox && existing.sandbox !== options.sandbox) {
        existing.iframe.setAttribute("sandbox", options.sandbox);
        existing.sandbox = options.sandbox;
      }
      if (existing.iframe.src !== url) {
        existing.iframe.src = url;
      }
      return existing.iframe;
    }

    const wrapper = document.createElement("div");
    wrapper.style.cssText = `
      position: fixed;
      visibility: hidden;
      pointer-events: none;
      transform: translate(-100vw, -100vh);
      width: 0;
      height: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: transparent;
    `;
    wrapper.setAttribute("data-iframe-key", key);

    const iframe = document.createElement("iframe");
    iframe.style.cssText = `
      width: 100%;
      height: 100%;
      border: 0;
      display: block;
      background: transparent;
    `;
    iframe.style.transform = "none";
    iframe.src = url;
    if (options?.allow) {
      iframe.allow = options.allow;
    } else {
      iframe.allow = "clipboard-read; clipboard-write; cross-origin-isolated; fullscreen";
    }
    if (options?.sandbox) {
      iframe.setAttribute("sandbox", options.sandbox);
    } else {
      iframe.setAttribute(
        "sandbox",
        "allow-same-origin allow-scripts allow-forms allow-downloads allow-modals allow-popups"
      );
    }

    wrapper.appendChild(iframe);
    this.container?.appendChild(wrapper);
    this.iframes.set(key, {
      iframe,
      wrapper,
      allow: options?.allow,
      sandbox: options?.sandbox,
    });

    return iframe;
  }

  mountIframe(
    key: string,
    targetElement: HTMLElement,
    options?: MountOptions
  ): () => void {
    const entry = this.iframes.get(key);
    if (!entry) return () => {};

    entry.wrapper.style.background = options?.backgroundColor ?? "transparent";

    const syncPosition = () => {
      const rect = targetElement.getBoundingClientRect();
      entry.wrapper.style.transform = `translate(${rect.left}px, ${rect.top}px)`;
      entry.wrapper.style.width = `${rect.width}px`;
      entry.wrapper.style.height = `${rect.height}px`;
    };

    entry.wrapper.style.visibility = "visible";
    entry.wrapper.style.pointerEvents = "auto";
    entry.iframe.style.transform = "none";
    syncPosition();

    const observer = new ResizeObserver(syncPosition);
    observer.observe(targetElement);
    window.addEventListener("resize", syncPosition);
    window.addEventListener("scroll", syncPosition, true);

    return () => {
      entry.wrapper.style.visibility = "hidden";
      entry.wrapper.style.pointerEvents = "none";
      observer.disconnect();
      window.removeEventListener("resize", syncPosition);
      window.removeEventListener("scroll", syncPosition, true);
    };
  }
}

const iframeManager = typeof window !== "undefined" ? new SimplePersistentIframeManager() : null;

const ensurePanelDragPointerEventHandling = () => {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return;
  }

  const existingHandlers = window.__previewPanelDragPointerHandlers;
  if (existingHandlers) {
    window.removeEventListener(PANEL_DRAG_START_EVENT, existingHandlers.start);
    window.removeEventListener(PANEL_DRAG_END_EVENT, existingHandlers.end);
    window.removeEventListener("dragend", existingHandlers.nativeEnd);
    document.removeEventListener("visibilitychange", existingHandlers.visibilityChange);
    window.removeEventListener("blur", existingHandlers.windowBlur);
  }

  const ensureStyleElement = () => {
    let styleElement = document.getElementById(PANEL_DRAGGING_STYLE_ID) as HTMLStyleElement | null;
    if (!styleElement) {
      styleElement = document.createElement("style");
      styleElement.id = PANEL_DRAGGING_STYLE_ID;
      document.head.appendChild(styleElement);
    }
    if (styleElement.textContent !== PANEL_DRAGGING_STYLE_CONTENT) {
      styleElement.textContent = PANEL_DRAGGING_STYLE_CONTENT;
    }
  };

  const handleDragStart: EventListener = () => {
    if (!document.body) return;
    ensureStyleElement();
    const current = window.__previewActivePanelDragCount ?? 0;
    if (current === 0) {
      document.body.classList.add(PANEL_DRAGGING_CLASS);
    }
    window.__previewActivePanelDragCount = current + 1;
  };

  const handleDragEnd: EventListener = () => {
    if (!document.body) return;
    const current = window.__previewActivePanelDragCount ?? 0;
    if (current <= 1) {
      document.body.classList.remove(PANEL_DRAGGING_CLASS);
      window.__previewActivePanelDragCount = 0;
      return;
    }
    window.__previewActivePanelDragCount = current - 1;
  };

  const handleVisibilityChange: EventListener = () => {
    if (document.visibilityState === "visible") {
      return;
    }
    handleDragEnd(new Event("visibilitychange"));
  };

  const handleWindowBlur: EventListener = () => {
    handleDragEnd(new Event("blur"));
  };

  ensureStyleElement();

  window.addEventListener(PANEL_DRAG_START_EVENT, handleDragStart);
  window.addEventListener(PANEL_DRAG_END_EVENT, handleDragEnd);
  window.addEventListener("dragend", handleDragEnd);
  document.addEventListener("visibilitychange", handleVisibilityChange);
  window.addEventListener("blur", handleWindowBlur);

  window.__previewPanelDragPointerHandlers = {
    start: handleDragStart,
    end: handleDragEnd,
    nativeEnd: handleDragEnd,
    visibilityChange: handleVisibilityChange,
    windowBlur: handleWindowBlur,
  };
};

const dispatchPanelDragEvent = (event: string) => {
  if (typeof window === "undefined") {
    return;
  }
  window.dispatchEvent(new Event(event));
};

type PreviewPanelProps = {
  position: PanelPosition;
  iframeKey: string;
  icon: ReactNode;
  title: string;
  placeholder?: {
    title: string;
    description?: string;
  } | null;
  onSwap: (from: PanelPosition, to: PanelPosition) => void;
  onToggleExpand: (position: PanelPosition) => void;
  isExpanded: boolean;
  isAnyExpanded: boolean;
};

function PreviewPanel({
  position,
  iframeKey,
  icon,
  title,
  placeholder,
  onSwap,
  onToggleExpand,
  isExpanded,
  isAnyExpanded,
}: PreviewPanelProps) {
  const [isDragOver, setIsDragOver] = useState(false);
  const [isDraggingSelf, setIsDraggingSelf] = useState(false);
  const [isPanelDragActive, setIsPanelDragActive] = useState(false);

  useEffect(() => {
    ensurePanelDragPointerEventHandling();
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const handleStart = () => {
      setIsPanelDragActive(true);
    };
    const handleEnd = () => {
      setIsPanelDragActive(false);
      setIsDragOver(false);
    };

    window.addEventListener(PANEL_DRAG_START_EVENT, handleStart);
    window.addEventListener(PANEL_DRAG_END_EVENT, handleEnd);

    return () => {
      window.removeEventListener(PANEL_DRAG_START_EVENT, handleStart);
      window.removeEventListener(PANEL_DRAG_END_EVENT, handleEnd);
    };
  }, []);

  const handleDragStart = useCallback((event: ReactDragEvent<HTMLDivElement>) => {
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", position);
    setIsDraggingSelf(true);
    dispatchPanelDragEvent(PANEL_DRAG_START_EVENT);
  }, [position]);

  const handleDragEnd = useCallback(() => {
    setIsDraggingSelf(false);
    setIsDragOver(false);
    dispatchPanelDragEvent(PANEL_DRAG_END_EVENT);
  }, []);

  const handleDragEnter = useCallback((event: ReactDragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setIsDragOver(true);
  }, []);

  const handleDragOver = useCallback((event: ReactDragEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
  }, []);

  const handleDragLeave = useCallback((event: ReactDragEvent<HTMLDivElement>) => {
    const nextTarget = event.relatedTarget as Node | null;
    if (nextTarget && event.currentTarget.contains(nextTarget)) {
      return;
    }
    setIsDragOver(false);
  }, []);

  const handleDrop = useCallback((event: ReactDragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setIsDragOver(false);
    const fromPosition = event.dataTransfer.getData("text/plain") as PanelPosition;
    if (fromPosition && fromPosition !== position) {
      onSwap(fromPosition, position);
    }
    dispatchPanelDragEvent(PANEL_DRAG_END_EVENT);
  }, [onSwap, position]);

  const isInactive = isAnyExpanded && !isExpanded;

  const panelClassName = clsx(
    "flex h-full flex-col rounded-lg border bg-white shadow-sm transition-all duration-150 dark:bg-neutral-950",
    isDragOver
      ? "border-blue-500 dark:border-blue-400 ring-2 ring-blue-500/30 dark:ring-blue-400/30"
      : "border-neutral-200 dark:border-neutral-800",
    isExpanded
      ? "absolute inset-0 z-[var(--z-maximized)] pointer-events-auto shadow-2xl overflow-visible dark:ring-blue-400/20"
      : "relative pointer-events-auto overflow-hidden",
    isInactive ? "pointer-events-none opacity-40" : undefined,
  );

  const panelStyle = isInactive ? ({ visibility: "hidden" } as const) : undefined;

  const showDropOverlay = isPanelDragActive && !isDraggingSelf && !isExpanded;

  const ExpandIcon = isExpanded ? Minimize2 : Maximize2;
  const expandLabel = isExpanded ? "Exit expanded view" : "Expand panel";

  return (
    <div
      className={panelClassName}
      style={panelStyle}
      data-panel-position={position}
      aria-hidden={isInactive ? true : undefined}
      onDragEnter={handleDragEnter}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {showDropOverlay ? (
        <div
          aria-hidden
          className={clsx(
            "pointer-events-auto absolute inset-0 z-10 rounded-lg",
            isDragOver ? "bg-blue-500/10 dark:bg-blue-400/15" : "bg-transparent"
          )}
          onDragEnter={(event) => {
            handleDragEnter(event);
            event.stopPropagation();
          }}
          onDragOver={(event) => {
            handleDragOver(event);
            event.stopPropagation();
          }}
          onDragLeave={(event) => {
            handleDragLeave(event);
            event.stopPropagation();
          }}
          onDrop={(event) => {
            handleDrop(event);
            event.stopPropagation();
          }}
        />
      ) : null}
      <div
        className={clsx(
          "flex items-center gap-1.5 border-b border-neutral-200 px-2 py-1 dark:border-neutral-800",
          isExpanded && "relative z-[100000000] pointer-events-auto"
        )}
        onDoubleClick={(event) => {
          event.stopPropagation();
          onToggleExpand(position);
        }}
      >
        <div
          draggable
          onDragStart={handleDragStart}
          onDragEnd={handleDragEnd}
          className={clsx(
            "flex flex-1 items-center gap-1.5 cursor-move group transition-opacity",
            isDraggingSelf && "opacity-60"
          )}
        >
          <GripVertical className="size-3.5 text-neutral-400 transition-colors group-hover:text-neutral-600 dark:text-neutral-500 dark:group-hover:text-neutral-300" />
          <span className="sr-only">Drag to reorder panels</span>
          <div className="flex size-5 items-center justify-center rounded-full text-neutral-700 dark:text-neutral-200">
            {icon}
          </div>
          <h2 className="text-xs font-medium text-neutral-800 dark:text-neutral-100">
            {title}
          </h2>
        </div>
        <button
          type="button"
          onClick={() => onToggleExpand(position)}
          className="flex size-5 items-center justify-center rounded text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-700 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-200"
          title={expandLabel}
          aria-pressed={isExpanded}
          onDoubleClick={(event) => {
            event.stopPropagation();
          }}
        >
          <ExpandIcon className="size-3.5" />
        </button>
      </div>
      <div className="relative flex-1">
        {placeholder ? (
          <div
            className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400"
            aria-hidden={false}
          >
            <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
              {placeholder.title}
            </div>
            {placeholder.description ? (
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                {placeholder.description}
              </p>
            ) : null}
          </div>
        ) : null}
        <div
          className={clsx(
            "absolute inset-0",
            placeholder ? "opacity-0" : "opacity-100"
          )}
          data-iframe-target={iframeKey}
        />
      </div>
    </div>
  );
}

export function PreviewConfigureClient({
  teamSlugOrId,
  repo,
  installationId: _installationId,
}: PreviewConfigureClientProps) {
  const [instance, setInstance] = useState<SandboxInstance | null>(null);
  const [isProvisioning, setIsProvisioning] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const [envVars, setEnvVars] = useState<EnvVar[]>(() => ensureInitialEnvVars());
  const [maintenanceScript, setMaintenanceScript] = useState("");
  const [devScript, setDevScript] = useState("");

  const [areEnvValuesHidden, setAreEnvValuesHidden] = useState(true);
  const [activeEnvValueIndex, setActiveEnvValueIndex] = useState<number | null>(null);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(null);

  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    if (typeof document === "undefined") {
      return;
    }
    const previousOverflow = document.body.style.overflow;
    const previousOverscroll = document.body.style.overscrollBehavior;
    document.body.style.overflow = "hidden";
    document.body.style.overscrollBehavior = "none";
    return () => {
      document.body.style.overflow = previousOverflow;
      document.body.style.overscrollBehavior = previousOverscroll;
    };
  }, []);

  // Panel state - vertical split
  const [panelLayout, setPanelLayout] = useState<Record<PanelPosition, PanelType>>({
    topLeft: "workspace",
    bottomLeft: "browser",
  });
  const [expandedPanelInSplit, setExpandedPanelInSplit] = useState<PanelPosition | null>(null);
  const [previewMode, setPreviewMode] = useState<PreviewMode>(() => {
    if (typeof window === "undefined") {
      return "split";
    }
    const stored = window.localStorage.getItem("env-preview-mode");
    if (stored === "split" || stored === "vscode" || stored === "browser") {
      return stored;
    }
    return "split";
  });
  const persistentIframeManager = useMemo(() => iframeManager, []);
  const [splitRatio, setSplitRatio] = useState(() => {
    if (typeof window === "undefined") {
      return 0.5;
    }
    const stored = window.localStorage.getItem("env-preview-split");
    const parsed = stored ? Number.parseFloat(stored) : 0.5;
    if (Number.isNaN(parsed)) {
      return 0.5;
    }
    return Math.min(Math.max(parsed, 0.2), 0.8);
  });
  const splitDragRafRef = useRef<number | null>(null);

  const splitContainerRef = useRef<HTMLDivElement>(null);
  const keyInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const lastSubmittedEnvContent = useRef<string | null>(null);

  const vscodePersistKey = instance?.instanceId ? `preview-${instance.instanceId}:vscode` : "vscode";
  const browserPersistKey = instance?.instanceId ? `preview-${instance.instanceId}:browser` : "browser";

  const workspacePosition = useMemo<PanelPosition | null>(() => {
    const entry = Object.entries(panelLayout).find(([, value]) => value === "workspace");
    return (entry?.[0] as PanelPosition | undefined) ?? null;
  }, [panelLayout]);

  const browserPosition = useMemo<PanelPosition | null>(() => {
    const entry = Object.entries(panelLayout).find(([, value]) => value === "browser");
    return (entry?.[0] as PanelPosition | undefined) ?? null;
  }, [panelLayout]);

  const expandedPanelPosition = useMemo<PanelPosition | null>(() => {
    if (previewMode === "split") {
      return null;
    }
    if (previewMode === "vscode") {
      return workspacePosition;
    }
    if (previewMode === "browser") {
      return browserPosition;
    }
    return null;
  }, [browserPosition, previewMode, workspacePosition]);

  const resolvedVncUrl = useMemo(() => {
    if (instance?.vncUrl) {
      return normalizeVncUrl(instance.vncUrl) ?? instance.vncUrl;
    }
    return deriveVncUrl(instance?.instanceId, instance?.vscodeUrl);
  }, [instance?.instanceId, instance?.vncUrl, instance?.vscodeUrl]);

  const isBrowserAvailable = Boolean(resolvedVncUrl);

  const workspacePlaceholder = useMemo(
    () =>
      instance?.vscodeUrl
        ? null
        : {
            title: instance?.instanceId
              ? "Waiting for VS Code"
              : "VS Code workspace not ready",
            description: instance?.instanceId
              ? "The editor opens automatically once the environment finishes booting."
              : "Provisioning the workspace. We'll open VS Code as soon as it's ready.",
          },
    [instance?.instanceId, instance?.vscodeUrl]
  );

  const browserPlaceholder = useMemo(
    () =>
      resolvedVncUrl
        ? null
        : {
            title: instance?.instanceId
              ? "Waiting for browser"
              : "Browser preview unavailable",
            description: instance?.instanceId
              ? "We'll embed the browser session as soon as the environment exposes it."
              : "Launch the workspace so the browser agent can stream the preview here.",
          },
    [instance?.instanceId, resolvedVncUrl]
  );

  const provisionVM = useCallback(async () => {
    setIsProvisioning(true);
    setErrorMessage(null);

    try {
      const response = await fetch("/api/sandboxes/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId,
          repoUrl: `https://github.com/${repo}`,
          branch: "main",
          ttlSeconds: 3600,
        }),
      });

      if (!response.ok) {
        throw new Error(await response.text());
      }

      const data = (await response.json()) as SandboxInstance;
      const normalizedFromResponse =
        data.vncUrl && data.vncUrl.trim().length > 0
          ? normalizeVncUrl(data.vncUrl) ?? data.vncUrl
          : null;
      const derived = normalizedFromResponse ?? deriveVncUrl(data.instanceId, data.vscodeUrl);

      setInstance({
        ...data,
        vncUrl: derived ?? undefined,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to provision workspace";
      setErrorMessage(message);
    } finally {
      setIsProvisioning(false);
    }
  }, [repo, teamSlugOrId]);

  useEffect(() => {
    if (!instance && !isProvisioning && !errorMessage) {
      void provisionVM();
    }
  }, [instance, isProvisioning, errorMessage, provisionVM]);

  useEffect(() => {
    if (pendingFocusIndex !== null) {
      const el = keyInputRefs.current[pendingFocusIndex];
      if (el) {
        setTimeout(() => {
          el.focus();
          try {
            el.scrollIntoView({ block: "nearest" });
          } catch (_e) {
            void 0;
          }
        }, 0);
        setPendingFocusIndex(null);
      }
    }
  }, [pendingFocusIndex, envVars]);

  // Auto-apply env vars to sandbox
  useEffect(() => {
    if (!instance?.instanceId) {
      return;
    }

    const envVarsContent = formatEnvVarsContent(
      envVars
        .filter((r) => r.name.trim().length > 0)
        .map((r) => ({ name: r.name, value: r.value }))
    );

    if (envVarsContent.length === 0 && lastSubmittedEnvContent.current === null) {
      return;
    }

    if (envVarsContent === lastSubmittedEnvContent.current) {
      return;
    }

    const timeoutId = window.setTimeout(async () => {
      try {
        await fetch(`/api/sandboxes/${instance.instanceId}/env`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ teamSlugOrId, envVarsContent }),
        });
        lastSubmittedEnvContent.current = envVarsContent;
      } catch (error) {
        console.error("Failed to apply sandbox environment vars", error);
      }
    }, 400);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [envVars, instance?.instanceId, teamSlugOrId]);

  const updateEnvVars = useCallback((updater: (prev: EnvVar[]) => EnvVar[]) => {
    setEnvVars((prev) => updater(prev));
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem("env-preview-mode", previewMode);
  }, [previewMode]);

  useEffect(() => {
    if (previewMode === "browser" && !resolvedVncUrl) {
      setPreviewMode("vscode");
    }
  }, [previewMode, resolvedVncUrl]);


  // Persist split ratio to localStorage
  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem("env-preview-split", String(splitRatio));
  }, [splitRatio]);

  const clampSplitRatio = useCallback(
    (value: number) => Math.min(Math.max(value, 0.2), 0.8),
    []
  );

  const handlePanelSwap = useCallback((fromPosition: PanelPosition, toPosition: PanelPosition) => {
    if (fromPosition === toPosition) {
      return;
    }
    setPanelLayout((prev) => {
      if (prev[fromPosition] === prev[toPosition]) {
        return prev;
      }
      return {
        ...prev,
        [fromPosition]: prev[toPosition],
        [toPosition]: prev[fromPosition],
      };
    });
  }, []);

  const handlePanelToggleExpand = useCallback((position: PanelPosition) => {
    setExpandedPanelInSplit((prev) => (prev === position ? null : position));
  }, []);

  const disableIframePointerEvents = useCallback(() => {
    if (typeof document === "undefined") {
      return;
    }
    const iframes = document.querySelectorAll("iframe");
    for (const node of Array.from(iframes)) {
      if (!(node instanceof HTMLIFrameElement)) {
        continue;
      }
      const current = node.style.pointerEvents;
      node.dataset.prevPointerEvents = current ? current : "__unset__";
      node.style.pointerEvents = "none";
    }
  }, []);

  const restoreIframePointerEvents = useCallback(() => {
    if (typeof document === "undefined") {
      return;
    }
    const iframes = document.querySelectorAll("iframe");
    for (const node of Array.from(iframes)) {
      if (!(node instanceof HTMLIFrameElement)) {
        continue;
      }
      const prev = node.dataset.prevPointerEvents;
      if (prev !== undefined) {
        if (prev === "__unset__") {
          node.style.removeProperty("pointer-events");
        } else {
          node.style.pointerEvents = prev;
        }
        delete node.dataset.prevPointerEvents;
      } else {
        node.style.removeProperty("pointer-events");
      }
    }
  }, []);

  const updateSplitFromEvent = useCallback(
    (event: MouseEvent) => {
      const container = splitContainerRef.current;
      if (!container) return;
      const rect = container.getBoundingClientRect();
      if (rect.height <= 0) return;
      const offset = (event.clientY - rect.top) / rect.height;
      setSplitRatio(clampSplitRatio(offset));
    },
    [clampSplitRatio]
  );

  const handleSplitDragMove = useCallback(
    (event: MouseEvent) => {
      if (typeof window === "undefined") {
        return;
      }
      if (splitDragRafRef.current != null) {
        return;
      }
      splitDragRafRef.current = window.requestAnimationFrame(() => {
        splitDragRafRef.current = null;
        updateSplitFromEvent(event);
      });
    },
    [updateSplitFromEvent]
  );

  const stopSplitDragging = useCallback(() => {
    if (typeof window === "undefined" || typeof document === "undefined") {
      return;
    }
    if (splitDragRafRef.current != null) {
      cancelAnimationFrame(splitDragRafRef.current);
      splitDragRafRef.current = null;
    }
    document.body.style.cursor = "";
    document.body.classList.remove("select-none");
    restoreIframePointerEvents();
    window.removeEventListener("mousemove", handleSplitDragMove);
    window.removeEventListener("mouseup", stopSplitDragging);
  }, [handleSplitDragMove, restoreIframePointerEvents]);

  const handleSplitDragStart = useCallback(
    (e: ReactMouseEvent) => {
      if (previewMode !== "split") {
        return;
      }
      if (typeof window === "undefined" || typeof document === "undefined") {
        return;
      }
      e.preventDefault();
      document.body.style.cursor = "row-resize";
      document.body.classList.add("select-none");
      disableIframePointerEvents();
      window.addEventListener("mousemove", handleSplitDragMove);
      window.addEventListener("mouseup", stopSplitDragging);
    },
    [disableIframePointerEvents, handleSplitDragMove, previewMode, stopSplitDragging]
  );

  // Cleanup split dragging on unmount
  useEffect(() => {
    return () => {
      if (typeof window !== "undefined" && splitDragRafRef.current != null) {
        cancelAnimationFrame(splitDragRafRef.current);
        splitDragRafRef.current = null;
        window.removeEventListener("mousemove", handleSplitDragMove);
        window.removeEventListener("mouseup", stopSplitDragging);
      }
      if (typeof document !== "undefined") {
        document.body.style.cursor = "";
        document.body.classList.remove("select-none");
      }
      restoreIframePointerEvents();
    };
  }, [handleSplitDragMove, restoreIframePointerEvents, stopSplitDragging]);

  const handleSaveConfiguration = async () => {
    if (!instance?.instanceId) {
      console.error("Missing instanceId for configuration save");
      return;
    }

    const repoName = repo.split("/").pop() || "preview";
    const now = new Date();
    const dateTime = now.toISOString().replace(/[:.]/g, "-").slice(0, -5);
    const envName = `${repoName}-${dateTime}`;

    const envVarsContent = formatEnvVarsContent(
      envVars
        .filter((r) => r.name.trim().length > 0)
        .map((r) => ({ name: r.name, value: r.value }))
    );

    const normalizedMaintenanceScript = maintenanceScript.trim();
    const normalizedDevScript = devScript.trim();
    const requestMaintenanceScript =
      normalizedMaintenanceScript.length > 0 ? normalizedMaintenanceScript : undefined;
    const requestDevScript =
      normalizedDevScript.length > 0 ? normalizedDevScript : undefined;

    setIsSaving(true);
    setErrorMessage(null);

    try {
      const envResponse = await fetch("/api/environments", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId,
          name: envName,
          morphInstanceId: instance.instanceId,
          envVarsContent,
          selectedRepos: [repo],
          maintenanceScript: requestMaintenanceScript,
          devScript: requestDevScript,
          exposedPorts: undefined,
          description: undefined,
        }),
      });

      if (!envResponse.ok) {
        throw new Error(await envResponse.text());
      }

      const envData = await envResponse.json();
      const environmentId = envData.id;

      const previewResponse = await fetch("/api/preview/configs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          teamSlugOrId,
          repoFullName: repo,
          environmentId,
          repoInstallationId: _installationId ? Number(_installationId) : undefined,
          repoDefaultBranch: "main",
          status: "active",
        }),
      });

      if (!previewResponse.ok) {
        throw new Error(await previewResponse.text());
      }

      window.location.href = "/preview";
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to save configuration";
      setErrorMessage(message);
      console.error("Failed to save preview configuration:", error);
    } finally {
      setIsSaving(false);
    }
  };

  const renderPanel = (position: PanelPosition) => {
    const panelType = panelLayout[position];
    const isPanelExpanded =
      previewMode === "split"
        ? expandedPanelInSplit === position
        : expandedPanelPosition === position;
    const isAnyExpanded =
      previewMode === "split"
        ? expandedPanelInSplit !== null
        : expandedPanelPosition !== null;

    if (panelType === "workspace") {
      return (
        <PreviewPanel
          key={`preview-panel-${position}-workspace`}
          position={position}
          iframeKey={vscodePersistKey}
          icon={<Code2 className="size-3" />}
          title="Workspace"
          placeholder={workspacePlaceholder}
          onSwap={handlePanelSwap}
          onToggleExpand={handlePanelToggleExpand}
          isExpanded={Boolean(isPanelExpanded)}
          isAnyExpanded={Boolean(isAnyExpanded)}
        />
      );
    }

    return (
      <PreviewPanel
        key={`preview-panel-${position}-browser`}
        position={position}
        iframeKey={browserPersistKey}
        icon={<Monitor className="size-3" />}
        title="Browser"
        placeholder={browserPlaceholder}
        onSwap={handlePanelSwap}
        onToggleExpand={handlePanelToggleExpand}
        isExpanded={Boolean(isPanelExpanded)}
        isAnyExpanded={Boolean(isAnyExpanded)}
      />
    );
  };

  const renderSingleContent = () => {
    if (previewMode === "vscode") {
      return (
        <div className="relative h-full min-h-0">
          {workspacePlaceholder ? (
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
              <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
                {workspacePlaceholder.title}
              </div>
              {workspacePlaceholder.description ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  {workspacePlaceholder.description}
                </p>
              ) : null}
            </div>
          ) : null}
          <div
            className={clsx(
              "absolute inset-0",
              workspacePlaceholder ? "opacity-0" : "opacity-100"
            )}
            data-iframe-target={vscodePersistKey}
          />
        </div>
      );
    }

    if (previewMode === "browser") {
      return (
        <div className="relative h-full min-h-0">
          {browserPlaceholder ? (
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-4 text-center text-neutral-500 dark:text-neutral-400">
              <div className="text-sm font-medium text-neutral-600 dark:text-neutral-200">
                {browserPlaceholder.title}
              </div>
              {browserPlaceholder.description ? (
                <p className="text-xs text-neutral-500 dark:text-neutral-400">
                  {browserPlaceholder.description}
                </p>
              ) : null}
            </div>
          ) : null}
          <div
            className={clsx(
              "absolute inset-0",
              browserPlaceholder ? "opacity-0" : "opacity-100"
            )}
            data-iframe-target={browserPersistKey}
          />
        </div>
      );
    }

    return null;
  };

  const previewContent =
    previewMode === "split" ? (
      <div
        ref={splitContainerRef}
        className="grid h-full min-h-0"
        style={{
          gridTemplateRows:
            expandedPanelInSplit === "topLeft"
              ? "1fr 8px 0fr"
              : expandedPanelInSplit === "bottomLeft"
                ? "0fr 8px 1fr"
                : `minmax(160px, ${splitRatio}fr) 8px minmax(160px, ${1 - splitRatio}fr)`,
          gap: "0",
        }}
      >
        <div className="min-h-0 h-full">{renderPanel("topLeft")}</div>
        {!expandedPanelInSplit && (
          <div
            role="separator"
            aria-label="Resize preview panels"
            aria-orientation="horizontal"
            onMouseDown={handleSplitDragStart}
            className="group relative cursor-row-resize select-none bg-transparent transition-colors z-10"
            style={{
              height: "8px",
            }}
            title="Resize panels"
          >
            <div
              className="absolute left-0 right-0 h-px bg-transparent group-hover:bg-neutral-400 dark:group-hover:bg-neutral-600 group-active:bg-neutral-500 dark:group-active:bg-neutral-500 transition-colors"
              style={{ top: "50%", transform: "translateY(-50%)" }}
            />
          </div>
        )}
        {expandedPanelInSplit && <div className="h-0" />}
        <div className="min-h-0 h-full">{renderPanel("bottomLeft")}</div>
      </div>
    ) : (
      <div className="h-full min-h-0">{renderSingleContent()}</div>
    );

  const previewButtonClass = useCallback(
    (view: PreviewMode, disabled: boolean) =>
      clsx(
        "inline-flex h-7 w-7 items-center justify-center rounded focus:outline-none transition-colors",
        disabled
          ? "opacity-40 cursor-not-allowed text-neutral-500 dark:text-neutral-400"
          : previewMode === view
            ? "text-neutral-900 dark:text-white bg-neutral-100 dark:bg-neutral-800"
            : "text-neutral-500 dark:text-neutral-400 cursor-pointer hover:text-neutral-900 dark:hover:text-neutral-100 hover:bg-neutral-50 dark:hover:bg-neutral-900"
      ),
    [previewMode]
  );

  const handlePreviewModeChange = useCallback(
    (mode: PreviewMode) => {
      if (mode === "browser" && !isBrowserAvailable) {
        return;
      }
      setPreviewMode(mode);
    },
    [isBrowserAvailable]
  );

  // Mount iframes
  useLayoutEffect(() => {
    if (!instance || !persistentIframeManager) return;

    const cleanupFunctions: Array<() => void> = [];

    if (instance.vscodeUrl) {
      const vscodeUrl = new URL(instance.vscodeUrl);
      vscodeUrl.searchParams.set("folder", "/root/workspace");
      persistentIframeManager.getOrCreateIframe(vscodePersistKey, vscodeUrl.toString());
      const target = document.querySelector(
        `[data-iframe-target="${vscodePersistKey}"]`,
      ) as HTMLElement | null;
      if (target) {
        cleanupFunctions.push(persistentIframeManager.mountIframe(vscodePersistKey, target));
      }
    }

    if (resolvedVncUrl) {
      persistentIframeManager.getOrCreateIframe(browserPersistKey, resolvedVncUrl);
      const target = document.querySelector(
        `[data-iframe-target="${browserPersistKey}"]`,
      ) as HTMLElement | null;
      if (target) {
        cleanupFunctions.push(
          persistentIframeManager.mountIframe(browserPersistKey, target, {
            backgroundColor: "#000000",
          }),
        );
      }
    }

    return () => {
      cleanupFunctions.forEach((fn) => fn());
    };
  }, [
    browserPersistKey,
    instance,
    persistentIframeManager,
    resolvedVncUrl,
    vscodePersistKey,
  ]);

  useEffect(() => {
    if (!persistentIframeManager) {
      return;
    }

    const workspaceVisible = (() => {
      if (!instance?.vscodeUrl) {
        return false;
      }
      if (previewMode === "split") {
        if (expandedPanelInSplit === null) {
          return true;
        }
        return workspacePosition !== null && expandedPanelInSplit === workspacePosition;
      }
      return previewMode === "vscode";
    })();

    const browserVisible = (() => {
      if (!resolvedVncUrl) {
        return false;
      }
      if (previewMode === "split") {
        if (expandedPanelInSplit === null) {
          return true;
        }
        return browserPosition !== null && expandedPanelInSplit === browserPosition;
      }
      return previewMode === "browser";
    })();

    persistentIframeManager.setVisibility(vscodePersistKey, workspaceVisible);
    persistentIframeManager.setVisibility(browserPersistKey, browserVisible);
  }, [
    browserPersistKey,
    browserPosition,
    expandedPanelInSplit,
    persistentIframeManager,
    resolvedVncUrl,
    instance?.vscodeUrl,
    previewMode,
    vscodePersistKey,
    workspacePosition,
  ]);

  if (errorMessage && !instance) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-[#05050a] text-white">
        <div className="text-center max-w-md px-6">
          <h1 className="text-2xl font-bold text-red-400">Error</h1>
          <p className="mt-2 text-neutral-400">{errorMessage}</p>
          <button
            type="button"
            onClick={() => {
              setErrorMessage(null);
              void provisionVM();
            }}
            className="mt-4 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-black transition hover:bg-neutral-200"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  if (isProvisioning || !instance) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-[#05050a] text-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-12 w-12 animate-spin text-sky-400" />
          <h1 className="mt-4 text-2xl font-bold">Provisioning Workspace</h1>
          <p className="mt-2 text-neutral-400">
            Setting up your development environment for <span className="font-mono text-white">{repo}</span>
          </p>
          <p className="mt-1 text-xs text-neutral-500">This may take a minute...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-screen overflow-hidden bg-neutral-50 dark:bg-neutral-950">
      {/* Left: Configuration Form */}
      <div className="w-96 overflow-y-auto border-r border-neutral-200 dark:border-neutral-800 bg-white dark:bg-black p-6">
        <Link
          href="/preview/get-started"
          className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 mb-4"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to repository selection
        </Link>

        <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">
          Configure Environment
        </h1>
        <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
          Set up environment variables and scripts for your preview environment.
        </p>

        <div className="mt-6 space-y-4">
          <div>
            <div className="text-xs text-neutral-500 dark:text-neutral-500 mb-1">
              Repository
            </div>
            <div className="flex flex-wrap gap-2">
              <span className="inline-flex items-center gap-1 rounded-full border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 px-2 py-1 text-xs font-mono">
                {repo}
              </span>
            </div>
          </div>

          <Accordion
            selectionMode="multiple"
            className="px-0"
            defaultExpandedKeys={["env-vars", "install-dependencies", "maintenance-script", "dev-script"]}
            itemClasses={{
              trigger: "text-sm cursor-pointer py-3",
              content: "pt-0",
              title: "text-sm font-medium",
            }}
          >
            <AccordionItem key="env-vars" aria-label="Environment variables" title="Environment variables">
              <div
                className="pb-2"
                onPasteCapture={(e) => {
                  const text = e.clipboardData?.getData("text") ?? "";
                  if (text && (/\n/.test(text) || /(=|:)\s*\S/.test(text))) {
                    e.preventDefault();
                    const items = parseEnvBlock(text);
                    if (items.length > 0) {
                      updateEnvVars((prev) => {
                        const map = new Map(
                          prev
                            .filter((r) => r.name.trim().length > 0 || r.value.trim().length > 0)
                            .map((r) => [r.name, r] as const)
                        );
                        for (const it of items) {
                          if (!it.name) continue;
                          const existing = map.get(it.name);
                          if (existing) {
                            map.set(it.name, { ...existing, value: it.value });
                          } else {
                            map.set(it.name, { name: it.name, value: it.value, isSecret: true });
                          }
                        }
                        const next = Array.from(map.values());
                        next.push({ name: "", value: "", isSecret: true });
                        setPendingFocusIndex(next.length - 1);
                        return next;
                      });
                    }
                  }
                }}
              >
                <div className="flex items-center justify-between pb-1">
                  <div
                    className="grid gap-3 text-xs text-neutral-500 dark:text-neutral-500 items-center"
                    style={{ gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.4fr) 44px" }}
                  >
                    <span>Key</span>
                    <span>Value</span>
                    <span className="w-[44px]" />
                  </div>
                  <button
                    type="button"
                    onClick={() => {
                      setActiveEnvValueIndex(null);
                      setAreEnvValuesHidden((previous) => !previous);
                    }}
                    className="inline-flex items-center gap-1.5 rounded-md border border-neutral-200 dark:border-neutral-800 px-2 py-1 text-xs text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-900"
                  >
                    {areEnvValuesHidden ? (
                      <>
                        <EyeOff className="h-3 w-3" />
                        Reveal
                      </>
                    ) : (
                      <>
                        <Eye className="h-3 w-3" />
                        Hide
                      </>
                    )}
                  </button>
                </div>

                <div className="space-y-2">
                  {envVars.map((row, idx) => {
                    const rowKey = idx;
                    const isEditingValue = activeEnvValueIndex === idx;
                    const shouldMaskValue = areEnvValuesHidden && row.value.trim().length > 0 && !isEditingValue;
                    return (
                      <div
                        key={rowKey}
                        className="grid gap-3 items-center"
                        style={{ gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.4fr) 44px" }}
                      >
                        <input
                          type="text"
                          value={row.name}
                          ref={(el) => {
                            keyInputRefs.current[idx] = el;
                          }}
                          onChange={(e) => {
                            const v = e.target.value;
                            updateEnvVars((prev) => {
                              const next = [...prev];
                              const current = next[idx];
                              if (current) {
                                next[idx] = { ...current, name: v };
                              }
                              return next;
                            });
                          }}
                          placeholder="EXAMPLE_NAME"
                          className="w-full min-w-0 self-start rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700"
                        />
                        <textarea
                          value={shouldMaskValue ? MASKED_ENV_VALUE : row.value}
                          onChange={
                            shouldMaskValue
                              ? undefined
                  : (e: ChangeEvent<HTMLTextAreaElement>) => {
                                  const v = e.target.value;
                                  updateEnvVars((prev) => {
                                    const next = [...prev];
                                    const current = next[idx];
                                    if (current) {
                                      next[idx] = { ...current, value: v };
                                    }
                                    return next;
                                  });
                                }
                          }
                          onFocus={() => setActiveEnvValueIndex(idx)}
                          onBlur={() => setActiveEnvValueIndex((current) => (current === idx ? null : current))}
                          readOnly={shouldMaskValue}
                          placeholder="I9JU23NF394R6HH"
                          rows={1}
                          className="w-full min-w-0 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-y"
                        />
                        <div className="self-start flex items-center justify-end w-[44px]">
                          <button
                            type="button"
                            onClick={() => {
                              updateEnvVars((prev) => {
                                const next = prev.filter((_, i) => i !== idx);
                                return next.length > 0 ? next : [{ name: "", value: "", isSecret: true }];
                              });
                            }}
                            className="h-10 w-[44px] rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-700 dark:text-neutral-300 grid place-items-center hover:bg-neutral-50 dark:hover:bg-neutral-900"
                            aria-label="Remove variable"
                          >
                            <Minus className="w-4 h-4" />
                          </button>
                        </div>
                      </div>
                    );
                  })}
                </div>

                <div className="pt-2">
                  <button
                    type="button"
                    onClick={() =>
                      updateEnvVars((prev) => [...prev, { name: "", value: "", isSecret: true }])
                    }
                    className="inline-flex items-center gap-2 rounded-md border border-neutral-200 dark:border-neutral-800 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-900"
                  >
                    <Plus className="w-4 h-4" /> Add More
                  </button>
                </div>

                <p className="text-xs text-neutral-500 dark:text-neutral-500 pt-2">
                  Tip: Paste an .env above to populate the form. Values are encrypted at rest.
                </p>
              </div>
            </AccordionItem>

            <AccordionItem key="install-dependencies" aria-label="Install dependencies" title="Install dependencies">
              <div className="space-y-2 pb-4">
                <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                  Use the VS Code terminal to install any dependencies your codebase needs.
                </p>
                <p className="text-xs text-neutral-500 dark:text-neutral-500">
                  Examples: docker pull postgres, docker run redis, install system packages, etc.
                </p>
              </div>
            </AccordionItem>

            <AccordionItem key="maintenance-script" aria-label="Maintenance script" title="Maintenance script">
              <div className="pb-4 space-y-2">
                <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                  {SCRIPT_COPY.maintenance.description}
                </p>
                <p className="text-xs text-neutral-500 dark:text-neutral-500 mb-3">
                  {SCRIPT_COPY.maintenance.subtitle}
                </p>
                <textarea
                  value={maintenanceScript}
                  onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setMaintenanceScript(e.target.value)}
                  placeholder={SCRIPT_COPY.maintenance.placeholder}
                  rows={5}
                  className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-y"
                />
              </div>
            </AccordionItem>

            <AccordionItem key="dev-script" aria-label="Dev script" title="Dev script">
              <div className="space-y-2 pb-4">
                <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                  {SCRIPT_COPY.dev.description}
                </p>
                <p className="text-xs text-neutral-500 dark:text-neutral-500 mb-3">
                  {SCRIPT_COPY.dev.subtitle}
                </p>
                <textarea
                  value={devScript}
                  onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setDevScript(e.target.value)}
                  placeholder={SCRIPT_COPY.dev.placeholder}
                  rows={5}
                  className="w-full rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 text-xs font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-700 resize-y"
                />
              </div>
            </AccordionItem>

            <AccordionItem key="browser-vnc" aria-label="Browser setup" title="Browser setup">
              <div className="space-y-2 pb-4 text-xs text-neutral-600 dark:text-neutral-400">
                <p>
                  Prepare the embedded browser so the browser agent can capture screenshots, finish authentication flows, and verify previews before you save this environment.
                </p>
                <ul className="list-disc space-y-1 pl-5">
                  <li>Sign in to SaaS tools or dashboards that require persistent sessions.</li>
                  <li>Clear cookie banners, popups, or MFA prompts that could block automation.</li>
                  <li>Load staging URLs and confirm pages render without certificate or CSP warnings.</li>
                </ul>
              </div>
            </AccordionItem>
          </Accordion>

          {errorMessage && (
            <div className="rounded-md bg-red-50 dark:bg-red-950/20 border border-red-200 dark:border-red-900/50 p-3">
              <p className="text-sm text-red-600 dark:text-red-400">{errorMessage}</p>
            </div>
          )}

          <div className="pt-2">
            <button
              type="button"
              onClick={handleSaveConfiguration}
              disabled={isSaving}
              className="inline-flex w-full items-center justify-center rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 px-4 py-2 text-sm font-semibold hover:bg-neutral-800 dark:hover:bg-neutral-200 transition disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isSaving ? (
                <>
                  <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                  Saving Configuration...
                </>
              ) : (
                "Save Configuration"
              )}
            </button>
          </div>
        </div>
      </div>

      {/* Right: Preview Panels */}
      <div className="flex-1 flex flex-col bg-neutral-50 dark:bg-neutral-950 overflow-hidden">
        <div className="flex items-center justify-between border-b border-neutral-200 dark:border-neutral-800 px-4 py-2">
          <div className="text-xs font-semibold uppercase tracking-wide text-neutral-500 dark:text-neutral-500">
            Preview
          </div>
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              onClick={() => handlePreviewModeChange("split")}
              className={previewButtonClass("split", false)}
              aria-pressed={previewMode === "split"}
              aria-label="Split VS Code and browser"
              title="Split VS Code and browser"
            >
              <svg
                className="h-3.5 w-3.5"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <rect x="3" y="3" width="18" height="7" rx="1" />
                <rect x="3" y="14" width="18" height="7" rx="1" />
              </svg>
            </button>
            <button
              type="button"
              onClick={() => handlePreviewModeChange("vscode")}
              className={previewButtonClass("vscode", false)}
              aria-pressed={previewMode === "vscode"}
              aria-label="Focus VS Code workspace"
              title="Show VS Code workspace"
            >
              <Code2 className="h-3.5 w-3.5" />
            </button>
            <button
              type="button"
              onClick={() => handlePreviewModeChange("browser")}
              className={previewButtonClass("browser", !isBrowserAvailable)}
              aria-pressed={previewMode === "browser"}
              aria-label="Show browser preview"
              title="Show browser preview"
              disabled={!isBrowserAvailable}
            >
              <Monitor className="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
        <div className="flex-1 min-h-0 p-2 overflow-hidden">
          {previewContent}
        </div>
      </div>
    </div>
  );
}
