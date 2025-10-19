import {
  BrowserWindow,
  WebContentsView,
  ipcMain,
  type OnCompletedListener,
  type OnDidGetResponseDetailsListener,
  type Rectangle,
  type Session,
  type WebContents,
} from "electron";
import { createHash, randomUUID } from "node:crypto";
import { STATUS_CODES } from "node:http";
import { deriveMorphDetails, type ProxyConfig } from "./proxy-routing";
import type {
  ElectronDevToolsMode,
  ElectronWebContentsEvent,
  ElectronWebContentsState,
  ElectronWebContentsSnapshot,
} from "../../src/types/electron-webcontents";
import type { WebContentsLayoutActualState } from "../../src/types/webcontents-debug";
import { applyChromeCamouflage, type Logger } from "./chrome-camouflage";

interface RegisterOptions {
  logger: Logger;
  maxSuspendedEntries?: number;
  rendererBaseUrl: string;
}

interface CreateOptions {
  url: string;
  bounds?: Rectangle;
  backgroundColor?: string;
  borderRadius?: number;
  persistKey?: string;
}

interface SetBoundsOptions {
  id: number;
  bounds: Rectangle;
  visible?: boolean;
}

interface LoadUrlOptions {
  id: number;
  url: string;
}

interface UpdateStyleOptions {
  id: number;
  backgroundColor?: string;
  borderRadius?: number;
}

interface ReleaseOptions {
  id: number;
  persist?: boolean;
}

interface Entry {
  id: number;
  view: Electron.WebContentsView;
  ownerWindowId: number;
  ownerWebContentsId: number;
  ownerSender: WebContents | null;
  persistKey?: string;
  suspended: boolean;
  ownerWebContentsDestroyed: boolean;
  eventChannel: string;
  eventCleanup: Array<() => void>;
  proxyConfig: ProxyConfig | null;
  morphId: string | null;
  displayUrl: string | null;
  originalUrl: string | null;
}

const viewEntries = new Map<number, Entry>();
const entriesByWebContentsId = new Map<number, Entry>();
let nextViewId = 1;
const windowCleanupRegistered = new Set<number>();
const suspendedQueue: number[] = [];
const suspendedByKey = new Map<string, Entry>();
let suspendedCount = 0;
let maxSuspendedEntries = 25;
let rendererBaseUrl = "";

const validDevToolsModes: ReadonlySet<ElectronDevToolsMode> = new Set([
  "bottom",
  "right",
  "undocked",
  "detach",
]);

function eventChannelFor(id: number): string {
  return `cmux:webcontents:event:${id}`;
}

function buildErrorUrl(params: {
  type: "navigation" | "http";
  url: string;
  code?: number;
  description?: string;
  statusCode?: number;
  statusText?: string;
}): string {
  const url = new URL("/electron-error", rendererBaseUrl);
  url.searchParams.set("type", params.type);
  if (params.url) url.searchParams.set("url", params.url);
  if (params.type === "navigation") {
    if (params.code !== undefined)
      url.searchParams.set("code", String(params.code));
    if (params.description) url.searchParams.set("description", params.description);
  } else if (params.type === "http") {
    if (params.statusCode !== undefined)
      url.searchParams.set("statusCode", String(params.statusCode));
    if (params.statusText) url.searchParams.set("statusText", params.statusText);
  }
  return url.toString();
}

function sendEventToOwner(
  entry: Entry,
  payload: ElectronWebContentsEvent,
  logger: Logger,
) {
  logger.log("Forwarding WebContentsView event", {
    id: entry.id,
    payload,
  });
  const sender = entry.ownerSender;
  if (!sender || sender.isDestroyed()) {
    return;
  }
  try {
    sender.send(entry.eventChannel, payload);
  } catch (error) {
    logger.warn("Failed to forward WebContentsView event", {
      id: entry.id,
      error,
    });
  }
}

function buildState(entry: Entry): ElectronWebContentsState | null {
  const contents = entry.view.webContents;
  try {
    const actualUrl = contents.getURL();
    const displayUrl = entry.displayUrl ?? actualUrl;
    return {
      id: entry.id,
      webContentsId: contents.id,
      url: displayUrl,
      title: contents.getTitle(),
      canGoBack: contents.navigationHistory.canGoBack(),
      canGoForward: contents.navigationHistory.canGoForward(),
      isLoading: contents.isLoading(),
      isDevToolsOpened: contents.isDevToolsOpened(),
      morphId: entry.morphId,
    };
  } catch {
    return null;
  }
}

function resolvePartitionId(persistKey: string | undefined): string {
  if (persistKey && persistKey.trim().length > 0) {
    const hash = createHash("sha1").update(persistKey.trim()).digest("hex");
    return `persist:cmux-webview:${hash}`;
  }
  return `persist:cmux-webview:${randomUUID()}`;
}

function proxyConfigsEqual(a: ProxyConfig | null, b: ProxyConfig | null): boolean {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return (
    a.scheme === b.scheme &&
    a.host === b.host &&
    a.port === b.port &&
    a.bypassRules === b.bypassRules
  );
}

async function applyProxyToSession(
  targetSession: Session,
  proxy: ProxyConfig | null,
  logger: Logger,
  context: string,
): Promise<void> {
  try {
    if (!proxy) {
      await targetSession.setProxy({ mode: "direct" });
      targetSession.closeAllConnections();
      return;
    }

    const proxyRules = `${proxy.scheme}://${proxy.host}:${proxy.port}`;
    await targetSession.setProxy({
      mode: "fixed_servers",
      proxyRules,
      proxyBypassRules: proxy.bypassRules,
    });
    targetSession.closeAllConnections();
  } catch (error) {
    logger.warn("Failed to apply proxy configuration", {
      context,
      error,
    });
  }
}

async function updateEntryProxy(
  entry: Entry,
  targetUrl: string | null | undefined,
  logger: Logger,
  context: string,
): Promise<string | null> {
  const { proxyConfig, morphId, navigationUrl, displayUrl } = deriveMorphDetails(
    targetUrl,
  );
  if (!proxyConfigsEqual(entry.proxyConfig, proxyConfig)) {
    await applyProxyToSession(entry.view.webContents.session, proxyConfig, logger, context);
    entry.proxyConfig = proxyConfig;
  }
  entry.morphId = morphId;
  entry.originalUrl = targetUrl ?? null;
  entry.displayUrl = displayUrl ?? targetUrl ?? null;
  return navigationUrl ?? targetUrl ?? null;
}

function sendState(entry: Entry, logger: Logger, reason: string) {
  const state = buildState(entry);
  if (!state) return;
  const payload: ElectronWebContentsEvent = {
    type: "state",
    state,
    reason,
  };
  sendEventToOwner(entry, payload, logger);
}

function setupEventForwarders(entry: Entry, logger: Logger) {
  if (entry.eventCleanup.length > 0) return;
  const { webContents } = entry.view;
  const cleanup: Array<() => void> = [];
  entriesByWebContentsId.set(webContents.id, entry);
  cleanup.push(() => {
    entriesByWebContentsId.delete(webContents.id);
  });

  ensureWebRequestListener(webContents.session, logger);

  const onDidStartLoading = () => {
    sendState(entry, logger, "did-start-loading");
  };
  webContents.on("did-start-loading", onDidStartLoading);
  cleanup.push(() => {
    webContents.removeListener("did-start-loading", onDidStartLoading);
  });

  const onDidStopLoading = () => {
    sendState(entry, logger, "did-stop-loading");
  };
  webContents.on("did-stop-loading", onDidStopLoading);
  cleanup.push(() => {
    webContents.removeListener("did-stop-loading", onDidStopLoading);
  });

  const onDidNavigate = (
    _event: Electron.Event,
    url: string,
    httpResponseCode: number,
    httpStatusText: string,
  ) => {
    if (!entry.proxyConfig) {
      entry.displayUrl = url;
      entry.originalUrl = url;
    }
    // Check for HTTP errors (4xx, 5xx)
    if (httpResponseCode >= 400) {
      const statusText = httpStatusText || STATUS_CODES[httpResponseCode];
      const errorUrl = buildErrorUrl({
        type: "http",
        url,
        statusCode: httpResponseCode,
        statusText: statusText ?? undefined,
      });
      logger.log("Loading error page for HTTP error", {
        id: entry.id,
        statusCode: httpResponseCode,
        errorUrl,
      });
      void entry.view.webContents.loadURL(errorUrl);
      return;
    }
    sendState(entry, logger, "did-navigate");
  };
  webContents.on("did-navigate", onDidNavigate);
  cleanup.push(() => {
    webContents.removeListener("did-navigate", onDidNavigate);
  });

  const onDidNavigateInPage = () => {
    if (!entry.proxyConfig) {
      try {
        const current = entry.view.webContents.getURL();
        entry.displayUrl = current;
        entry.originalUrl = current;
      } catch {
        // ignore
      }
    }
    sendState(entry, logger, "did-navigate-in-page");
  };
  webContents.on("did-navigate-in-page", onDidNavigateInPage);
  cleanup.push(() => {
    webContents.removeListener("did-navigate-in-page", onDidNavigateInPage);
  });

  const onPageTitleUpdated = () => {
    sendState(entry, logger, "page-title-updated");
  };
  webContents.on("page-title-updated", onPageTitleUpdated);
  cleanup.push(() => {
    webContents.removeListener("page-title-updated", onPageTitleUpdated);
  });

  const onDevtoolsOpened = () => {
    sendState(entry, logger, "devtools-opened");
  };
  webContents.on("devtools-opened", onDevtoolsOpened);
  cleanup.push(() => {
    webContents.removeListener("devtools-opened", onDevtoolsOpened);
  });

  const onDevtoolsClosed = () => {
    sendState(entry, logger, "devtools-closed");
  };
  webContents.on("devtools-closed", onDevtoolsClosed);
  cleanup.push(() => {
    webContents.removeListener("devtools-closed", onDevtoolsClosed);
  });

  const onDidFailLoad = (
    _event: Electron.Event,
    errorCode: number,
    errorDescription: string,
    validatedURL: string,
    isMainFrame: boolean,
  ) => {
    if (isMainFrame) {
      const errorUrl = buildErrorUrl({
        type: "navigation",
        url: validatedURL,
        code: errorCode,
        description: errorDescription,
      });
      logger.log("Loading error page for navigation failure", {
        id: entry.id,
        errorCode,
        errorUrl,
      });
      void entry.view.webContents.loadURL(errorUrl);
      return;
    }
    sendState(entry, logger, "did-fail-load");
  };
  webContents.on("did-fail-load", onDidFailLoad);
  cleanup.push(() => {
    webContents.removeListener("did-fail-load", onDidFailLoad);
  });

  const onDidGetResponseDetails: OnDidGetResponseDetailsListener = (
    _event,
    _status,
    newURL,
    _originalURL,
    httpResponseCode,
    _requestMethod,
    _referrer,
    _responseHeaders,
    resourceType,
  ) => {
    logger.log("did-get-response-details", {
      id: entry.id,
      url: newURL,
      httpResponseCode,
      resourceType,
    });
    // Error handling is done in onDidNavigate
  };
  webContents.on("did-get-response-details", onDidGetResponseDetails);
  cleanup.push(() => {
    webContents.removeListener(
      "did-get-response-details",
      onDidGetResponseDetails,
    );
  });

  entry.eventCleanup = cleanup;
  sendState(entry, logger, "initialized");
}

const registeredSessions = new WeakSet<Session>();

function ensureWebRequestListener(targetSession: Session, _logger: Logger) {
  if (registeredSessions.has(targetSession)) return;
  const listener: OnCompletedListener = () => {
    // Error handling is done in onDidNavigate
  };
  targetSession.webRequest.onCompleted(
    { urls: ["*://*/*"] },
    listener as OnCompletedListener,
  );
  registeredSessions.add(targetSession);
}

function setMaxSuspendedEntries(limit: number | undefined): number {
  if (
    typeof limit !== "number" ||
    Number.isNaN(limit) ||
    !Number.isFinite(limit) ||
    limit < 0
  ) {
    maxSuspendedEntries = 25;
    return maxSuspendedEntries;
  }
  maxSuspendedEntries = Math.floor(limit);
  return maxSuspendedEntries;
}

function cleanupViewsForWindow(windowId: number) {
  for (const [id, entry] of Array.from(viewEntries.entries())) {
    if (entry.ownerWindowId === windowId) {
      destroyView(id);
    }
  }
}

function removeFromSuspended(entry: Entry) {
  if (entry.persistKey) {
    const current = suspendedByKey.get(entry.persistKey);
    if (current?.id === entry.id) {
      suspendedByKey.delete(entry.persistKey);
    }
  }
  const index = suspendedQueue.indexOf(entry.id);
  if (index !== -1) {
    suspendedQueue.splice(index, 1);
  }
  if (entry.suspended) {
    entry.suspended = false;
    if (suspendedCount > 0) {
      suspendedCount -= 1;
    }
  }
}

function markSuspended(entry: Entry) {
  if (entry.suspended) return;
  entry.suspended = true;
  suspendedCount += 1;
  if (entry.persistKey) {
    suspendedByKey.set(entry.persistKey, entry);
  }
  suspendedQueue.push(entry.id);
}

function evictExcessSuspended(logger: Logger) {
  while (suspendedCount > maxSuspendedEntries) {
    const nextId = suspendedQueue.shift();
    if (typeof nextId !== "number") {
      break;
    }
    const entry = viewEntries.get(nextId);
    if (!entry || !entry.suspended) {
      continue;
    }
    logger.warn("Evicting suspended WebContentsView due to limit", {
      persistKey: entry.persistKey,
      webContentsId: entry.view.webContents.id,
    });
    destroyView(entry.id);
  }
}

function suspendEntriesForDestroyedOwner(
  windowId: number,
  webContentsId: number,
  logger: Logger,
) {
  logger.log("Renderer destroyed; evaluating owned WebContentsViews", {
    windowId,
    webContentsId,
  });
  let suspendedAny = false;
  for (const entry of Array.from(viewEntries.values())) {
    if (
      entry.ownerWindowId !== windowId ||
      entry.ownerWebContentsId !== webContentsId
    ) {
      continue;
    }

    if (!entry.persistKey) {
      logger.log(
        "Renderer destroyed; dropping non-persistent WebContentsView",
        {
          id: entry.id,
          webContentsId: entry.view.webContents.id,
        },
      );
      destroyView(entry.id);
      suspendedAny = true;
      continue;
    }

    logger.log("Renderer destroyed; suspending persistent WebContentsView", {
      id: entry.id,
      persistKey: entry.persistKey,
      alreadySuspended: entry.suspended,
    });
    entry.ownerWebContentsDestroyed = true;
    entry.ownerSender = null;

    if (!entry.suspended) {
      const win = BrowserWindow.fromId(entry.ownerWindowId);
      if (win && !win.isDestroyed()) {
        try {
          win.contentView.removeChildView(entry.view);
        } catch {
          // ignore removal failures
        }
      }
      try {
        entry.view.setVisible(false);
      } catch {
        // ignore visibility toggles on unsupported platforms
      }
      markSuspended(entry);
      suspendedAny = true;
    }
  }

  if (suspendedAny) {
    logger.log("Suspended WebContentsViews after renderer destroyed", {
      windowId,
      webContentsId,
      suspendedCount,
    });
    evictExcessSuspended(logger);
  }
}

function destroyView(id: number): boolean {
  const entry = viewEntries.get(id);
  if (!entry) return false;
  entriesByWebContentsId.delete(entry.view.webContents.id);
  try {
    removeFromSuspended(entry);
    for (const cleanup of entry.eventCleanup) {
      try {
        cleanup();
      } catch {
        // ignore cleanup failures
      }
    }
    entry.eventCleanup = [];
    entry.ownerSender = null;
    const win = BrowserWindow.fromId(entry.ownerWindowId);
    if (win && !win.isDestroyed()) {
      try {
        win.contentView.removeChildView(entry.view);
      } catch {
        // ignore removal failures
      }
    }
    try {
      destroyWebContents(entry.view.webContents);
    } catch {
      // ignore destroy failures
    }
  } finally {
    viewEntries.delete(id);
  }
  return true;
}

function destroyConflictingEntries(
  persistKey: string,
  windowId: number,
  logger: Logger,
): void {
  for (const entry of Array.from(viewEntries.values())) {
    if (entry.persistKey !== persistKey) {
      continue;
    }
    if (entry.ownerWindowId !== windowId) {
      continue;
    }

    logger.warn("Destroying stale WebContentsView with duplicate persistKey", {
      id: entry.id,
      persistKey,
      ownerWindowId: entry.ownerWindowId,
      ownerWebContentsId: entry.ownerWebContentsId,
      suspended: entry.suspended,
    });
    destroyView(entry.id);
  }
}

function toBounds(bounds: Rectangle | undefined): Rectangle {
  if (!bounds) return { x: 0, y: 0, width: 0, height: 0 };
  return {
    x: Math.round(bounds.x ?? 0),
    y: Math.round(bounds.y ?? 0),
    width: Math.max(0, Math.round(bounds.width ?? 0)),
    height: Math.max(0, Math.round(bounds.height ?? 0)),
  };
}

function evaluateVisibility(bounds: Rectangle, explicit?: boolean): boolean {
  if (typeof explicit === "boolean") return explicit;
  return bounds.width > 0 && bounds.height > 0;
}

function applyBackgroundColor(
  view: Electron.WebContentsView,
  color: string | undefined,
) {
  if (!color) return;
  try {
    view.setBackgroundColor(color);
  } catch {
    // ignore invalid colors
  }
}

function applyBorderRadius(
  view: Electron.WebContentsView,
  radius: number | undefined,
) {
  if (typeof radius !== "number" || Number.isNaN(radius)) return;
  const safe = Math.max(0, Math.round(radius));
  try {
    view.setBorderRadius(safe);
  } catch {
    // ignore unsupported platforms
  }
}

function destroyWebContents(contents: WebContents) {
  const destroyable = contents as WebContents & {
    destroy?: () => void;
    close?: () => void;
  };
  if (typeof destroyable.destroy === "function") {
    destroyable.destroy();
  } else if (typeof destroyable.close === "function") {
    destroyable.close();
  }
}

export function registerWebContentsViewHandlers({
  logger,
  maxSuspendedEntries: providedMax,
  rendererBaseUrl: providedBaseUrl,
}: RegisterOptions): void {
  setMaxSuspendedEntries(providedMax);
  rendererBaseUrl = providedBaseUrl;

  ipcMain.handle(
    "cmux:webcontents:create",
    async (event, rawOptions: CreateOptions) => {
      try {
        const sender = event.sender;
        const win = BrowserWindow.fromWebContents(sender);
        if (!win) {
          logger.warn("webcontents-view:create with no owning window");
          throw new Error("No owning window for web contents view");
        }

        const options = rawOptions ?? { url: "about:blank" };
        const persistKey =
          typeof options.persistKey === "string" &&
          options.persistKey.trim().length > 0
            ? options.persistKey.trim()
            : undefined;

        const bounds = toBounds(options.bounds);
        const desiredVisibility = evaluateVisibility(bounds);

        if (persistKey) {
          const candidate = suspendedByKey.get(persistKey);
          const sameWindow = candidate?.ownerWindowId === win.id;
          const sameSender = candidate?.ownerWebContentsId === sender.id;
          const canAdopt = candidate?.ownerWebContentsDestroyed === true;
          if (candidate && sameWindow && (sameSender || canAdopt)) {
            removeFromSuspended(candidate);
            try {
              win.contentView.addChildView(candidate.view);
            } catch (error) {
              logger.error(
                "Failed to reattach suspended WebContentsView",
                error,
              );
              destroyView(candidate.id);
              throw error;
            }

            applyChromeCamouflage(candidate.view, logger);

            try {
              candidate.view.setBounds(bounds);
              candidate.view.setVisible(desiredVisibility);
            } catch (error) {
              logger.warn(
                "Failed to update bounds for restored WebContentsView",
                {
                  error,
                  id: candidate.id,
                },
              );
            }

            if (options.backgroundColor !== undefined) {
              applyBackgroundColor(candidate.view, options.backgroundColor);
            }
            if (options.borderRadius !== undefined) {
              applyBorderRadius(candidate.view, options.borderRadius);
            }

            const restoredUrl =
              options.url ?? candidate.originalUrl ?? candidate.view.webContents.getURL();
            await updateEntryProxy(candidate, restoredUrl, logger, "reattach");

            candidate.ownerWindowId = win.id;
            candidate.ownerWebContentsId = sender.id;
            candidate.ownerWebContentsDestroyed = false;
            candidate.ownerSender = sender;
            if (!candidate.eventChannel) {
              candidate.eventChannel = eventChannelFor(candidate.id);
            }
            if (candidate.eventCleanup.length === 0) {
              setupEventForwarders(candidate, logger);
            }
            sendState(candidate, logger, "reattached");

            logger.log("Reattached WebContentsView", {
              id: candidate.id,
              persistKey,
              windowId: win.id,
              senderId: sender.id,
            });

            if (!windowCleanupRegistered.has(win.id)) {
              windowCleanupRegistered.add(win.id);
              win.once("closed", () => {
                cleanupViewsForWindow(win.id);
                windowCleanupRegistered.delete(win.id);
              });
            }

            const senderId = sender.id;
            sender.once("destroyed", () => {
              suspendEntriesForDestroyedOwner(win.id, senderId, logger);
            });

            return {
              id: candidate.id,
              webContentsId: candidate.view.webContents.id,
              restored: true,
            };
          }

          if (candidate && sameWindow && !(sameSender || canAdopt)) {
            logger.warn("Unable to reattach WebContentsView despite matching persistKey", {
              persistKey,
              candidateId: candidate.id,
              candidateOwnerWebContentsId: candidate.ownerWebContentsId,
              requestWebContentsId: sender.id,
              ownerDestroyed: candidate.ownerWebContentsDestroyed,
            });
          }

          destroyConflictingEntries(persistKey, win.id, logger);
        }

        const partitionId = resolvePartitionId(persistKey);
        const view = new WebContentsView({
          webPreferences: {
            partition: partitionId,
          },
        });

        applyChromeCamouflage(view, logger);

        applyBackgroundColor(view, options.backgroundColor);
        applyBorderRadius(view, options.borderRadius);

        try {
          win.contentView.addChildView(view);
        } catch (error) {
          logger.error("Failed to add WebContentsView to window", error);
          try {
            destroyWebContents(view.webContents);
          } catch {
            // ignore
          }
          throw error;
        }

        try {
          view.setBounds(bounds);
          view.setVisible(desiredVisibility);
        } catch (error) {
          logger.warn(
            "Failed to set initial bounds for WebContentsView",
            error,
          );
        }

        const finalUrl = options.url ?? "about:blank";

        const id = nextViewId++;
        const entry: Entry = {
          id,
          view,
          ownerWindowId: win.id,
          ownerWebContentsId: sender.id,
          ownerSender: sender,
          persistKey,
          suspended: false,
          ownerWebContentsDestroyed: false,
          eventChannel: eventChannelFor(id),
          eventCleanup: [],
          proxyConfig: null,
          morphId: null,
          displayUrl: null,
          originalUrl: null,
        };
        viewEntries.set(id, entry);
        const navigationTarget =
          (await updateEntryProxy(entry, finalUrl, logger, "create")) ?? finalUrl;
        void view.webContents.loadURL(navigationTarget).catch((error) =>
          logger.warn("WebContentsView initial load failed", {
            url: navigationTarget,
            error,
          }),
        );
        setupEventForwarders(entry, logger);
        sendState(entry, logger, "created");

        if (!windowCleanupRegistered.has(win.id)) {
          windowCleanupRegistered.add(win.id);
          win.once("closed", () => {
            cleanupViewsForWindow(win.id);
            windowCleanupRegistered.delete(win.id);
          });
        }

        const senderId = sender.id;
        sender.once("destroyed", () => {
          suspendEntriesForDestroyedOwner(win.id, senderId, logger);
        });

        logger.log("Created WebContentsView", {
          id,
          windowId: win.id,
          senderId: sender.id,
          url: finalUrl,
          persistKey,
        });

        return { id, webContentsId: view.webContents.id, restored: false };
      } catch (error) {
        logger.error("webcontents-view:create failed", error);
        throw error;
      }
    },
  );

  ipcMain.handle(
    "cmux:webcontents:set-bounds",
    (event, payload: SetBoundsOptions) => {
      const { id, bounds: rawBounds, visible } = payload ?? {};
      if (typeof id !== "number") return { ok: false };

      const entry = viewEntries.get(id);
      if (!entry) return { ok: false };
      if (event.sender.id !== entry.ownerWebContentsId) {
        return { ok: false };
      }
      entry.ownerSender = event.sender;

      const bounds = toBounds(rawBounds);
      try {
        entry.view.setBounds(bounds);
        entry.view.setVisible(evaluateVisibility(bounds, visible));
        return { ok: true };
      } catch (error) {
        entry.view.setVisible(false);
        return { ok: false, error: String(error) };
      }
    },
  );

  ipcMain.handle(
    "cmux:webcontents:load-url",
    async (event, options: LoadUrlOptions) => {
      const { id, url } = options ?? {};
      if (
        typeof id !== "number" ||
        typeof url !== "string" ||
        url.length === 0
      ) {
        return { ok: false };
      }
      const entry = viewEntries.get(id);
      if (!entry) return { ok: false };
      if (event.sender.id !== entry.ownerWebContentsId) {
        return { ok: false };
      }
      entry.ownerSender = event.sender;
      try {
        const navigationTarget =
          (await updateEntryProxy(entry, url, logger, "load-url")) ?? url;
        void entry.view.webContents.loadURL(navigationTarget);
        return { ok: true };
      } catch (error) {
        logger.warn("Failed to load URL", { id, url, error });
        return { ok: false, error: String(error) };
      }
    },
  );

  ipcMain.handle("cmux:webcontents:go-back", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    try {
      if (!entry.view.webContents.navigationHistory.canGoBack()) {
        return { ok: false };
      }
      entry.view.webContents.navigationHistory.goBack();
      sendState(entry, logger, "go-back-command");
      return { ok: true };
    } catch (error) {
      logger.warn("Failed to go back", { id, error });
      return { ok: false, error: String(error) };
    }
  });

  ipcMain.handle("cmux:webcontents:go-forward", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    try {
      if (!entry.view.webContents.navigationHistory.canGoForward()) {
        return { ok: false };
      }
      entry.view.webContents.navigationHistory.goForward();
      sendState(entry, logger, "go-forward-command");
      return { ok: true };
    } catch (error) {
      logger.warn("Failed to go forward", { id, error });
      return { ok: false, error: String(error) };
    }
  });

  ipcMain.handle("cmux:webcontents:reload", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    try {
      entry.view.webContents.reload();
      sendState(entry, logger, "reload-command");
      return { ok: true };
    } catch (error) {
      logger.warn("Failed to reload WebContentsView", { id, error });
      return { ok: false, error: String(error) };
    }
  });

  ipcMain.handle(
    "cmux:webcontents:release",
    (event, options: ReleaseOptions) => {
      const { id, persist } = options ?? {};
      if (typeof id !== "number") return { ok: false };
      const entry = viewEntries.get(id);
      if (!entry) return { ok: false };
      if (event.sender.id !== entry.ownerWebContentsId) {
        return { ok: false };
      }
      entry.ownerSender = event.sender;

      const shouldPersist =
        Boolean(persist) && typeof entry.persistKey === "string";
      if (!shouldPersist) {
        const ok = destroyView(id);
        logger.log("Destroyed WebContentsView", {
          id,
          persistKey: entry.persistKey,
          reason: "release-without-persist",
        });
        return { ok, suspended: false };
      }

      if (entry.suspended) {
        logger.log("Release skipped; already suspended", {
          id,
          persistKey: entry.persistKey,
        });
        return { ok: true, suspended: true };
      }

      const win = BrowserWindow.fromId(entry.ownerWindowId);
      if (win && !win.isDestroyed()) {
        try {
          win.contentView.removeChildView(entry.view);
        } catch {
          // ignore
        }
      }

      try {
        entry.view.setVisible(false);
      } catch {
        // ignore
      }

      entry.ownerWebContentsDestroyed = false;
      markSuspended(entry);

      logger.log("Suspended WebContentsView", {
        id,
        persistKey: entry.persistKey,
        suspendedCount,
      });

      evictExcessSuspended(logger);

      return { ok: true, suspended: true };
    },
  );

  ipcMain.handle("cmux:webcontents:destroy", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    const ok = destroyView(id);
    logger.log("Destroyed WebContentsView", {
      id,
      persistKey: entry.persistKey,
      reason: "explicit-destroy",
    });
    return { ok };
  });

  ipcMain.handle(
    "cmux:webcontents:update-style",
    (event, options: UpdateStyleOptions) => {
      const { id, backgroundColor, borderRadius } = options ?? {};
      if (typeof id !== "number") return { ok: false };
      const entry = viewEntries.get(id);
      if (!entry) return { ok: false };
      if (event.sender.id !== entry.ownerWebContentsId) {
        return { ok: false };
      }
      entry.ownerSender = event.sender;
      applyBackgroundColor(entry.view, backgroundColor);
      applyBorderRadius(entry.view, borderRadius);
      return { ok: true };
    },
  );

  ipcMain.handle("cmux:webcontents:get-state", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    const state = buildState(entry);
    if (!state) return { ok: false };
    return { ok: true, state };
  });

  ipcMain.handle("cmux:webcontents:get-all-states", (event) => {
    const sender = event.sender;
    const senderWindow = BrowserWindow.fromWebContents(sender);
    const senderWindowId = senderWindow?.id ?? null;

    const states: ElectronWebContentsSnapshot[] = [];

    for (const entry of viewEntries.values()) {
      const sameSender = entry.ownerWebContentsId === sender.id;
      const suspendedForSender =
        entry.ownerWebContentsDestroyed &&
        senderWindowId === entry.ownerWindowId;
      if (!sameSender && !suspendedForSender) {
        continue;
      }

      if (sameSender) {
        entry.ownerSender = sender;
      }

      let bounds: ElectronWebContentsSnapshot["bounds"] = null;
      let visible: ElectronWebContentsSnapshot["visible"] = null;
      try {
        bounds = toBounds(entry.view.getBounds());
      } catch {
        bounds = null;
      }
      try {
        visible = entry.view.getVisible();
      } catch {
        visible = null;
      }

      const state = buildState(entry);

      states.push({
        id: entry.id,
        ownerWindowId: entry.ownerWindowId,
        ownerWebContentsId: entry.ownerWebContentsId,
        persistKey: entry.persistKey,
        suspended: entry.suspended,
        ownerWebContentsDestroyed: entry.ownerWebContentsDestroyed,
        bounds,
        visible,
        state: state ?? null,
      });
    }

    return { ok: true, states };
  });

  ipcMain.handle(
    "cmux:webcontents:open-devtools",
    (event, options: { id: number; mode?: ElectronDevToolsMode }) => {
      const { id, mode } = options ?? {};
      if (typeof id !== "number") return { ok: false };
      const entry = viewEntries.get(id);
      if (!entry) return { ok: false };
      if (event.sender.id !== entry.ownerWebContentsId) {
        return { ok: false };
      }
      entry.ownerSender = event.sender;
      const requestedMode: ElectronDevToolsMode =
        typeof mode === "string" &&
        validDevToolsModes.has(mode as ElectronDevToolsMode)
          ? (mode as ElectronDevToolsMode)
          : "bottom";
      try {
        entry.view.webContents.openDevTools({
          mode: requestedMode,
          activate: true,
        });
        sendState(entry, logger, "open-devtools-command");
        return { ok: true };
      } catch (error) {
        logger.warn("Failed to open DevTools for WebContentsView", {
          id,
          error,
        });
        return { ok: false, error: String(error) };
      }
    },
  );

  ipcMain.handle("cmux:webcontents:close-devtools", (event, id: number) => {
    if (typeof id !== "number") return { ok: false };
    const entry = viewEntries.get(id);
    if (!entry) return { ok: false };
    if (event.sender.id !== entry.ownerWebContentsId) {
      return { ok: false };
    }
    entry.ownerSender = event.sender;
    try {
      entry.view.webContents.closeDevTools();
      sendState(entry, logger, "close-devtools-command");
      return { ok: true };
    } catch (error) {
      logger.warn("Failed to close DevTools for WebContentsView", {
        id,
        error,
      });
      return { ok: false, error: String(error) };
    }
  });
}

export function getWebContentsLayoutSnapshot(
  id: number,
): WebContentsLayoutActualState | null {
  const entry = viewEntries.get(id);
  if (!entry) return null;

  try {
    const rawBounds = entry.view.getBounds();
    const normalized = toBounds(rawBounds);
    const bounds = {
      x: normalized.x,
      y: normalized.y,
      width: normalized.width,
      height: normalized.height,
    };

    return {
      bounds,
      ownerWindowId: entry.ownerWindowId,
      ownerWebContentsId: entry.ownerWebContentsId,
      suspended: entry.suspended,
      destroyed: entry.view.webContents.isDestroyed(),
      visible: evaluateVisibility(normalized),
    };
  } catch {
    return null;
  }
}
