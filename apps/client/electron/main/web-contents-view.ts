import {
  BrowserWindow,
  WebContentsView,
  ipcMain,
  shell,
  type Rectangle,
  type Session,
  type WebContents,
} from "electron";
import { Buffer } from "node:buffer";
import { STATUS_CODES } from "node:http";
import type {
  ElectronDevToolsMode,
  ElectronWebContentsEvent,
  ElectronWebContentsState,
  ElectronWebContentsSnapshot,
} from "../../src/types/electron-webcontents";
import type { WebContentsLayoutActualState } from "../../src/types/webcontents-debug";
import { applyChromeCamouflage, type Logger } from "./chrome-camouflage";
import { registerContextMenuForTarget } from "./context-menu";
import {
  configurePreviewProxyForView,
  getPreviewPartitionForPersistKey,
  isTaskRunPreviewPersistKey,
} from "./task-run-preview-proxy";
import { normalizeBrowserUrl } from "@cmux/shared";

interface RegisterOptions {
  logger: Logger;
  maxSuspendedEntries?: number;
  onPreviewWebContentsChange?: (payload: {
    webContentsId: number;
    present: boolean;
  }) => void;
}

interface CreateOptions {
  url: string;
  requestUrl?: string;
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
  previewProxyCleanup?: () => void;
  previewPartition?: string | null;
  isPreview: boolean;
}

const viewEntries = new Map<number, Entry>();
const entriesByWebContentsId = new Map<number, Entry>();
let nextViewId = 1;
const windowCleanupRegistered = new Set<number>();
const suspendedQueue: number[] = [];
const suspendedByKey = new Map<string, Entry>();
let suspendedCount = 0;
let maxSuspendedEntries = 25;
let previewWebContentsChangeHandler:
  | ((payload: { webContentsId: number; present: boolean }) => void)
  | null = null;

const validDevToolsModes: ReadonlySet<ElectronDevToolsMode> = new Set([
  "bottom",
  "right",
  "undocked",
  "detach",
]);

function eventChannelFor(id: number): string {
  return `cmux:webcontents:event:${id}`;
}

function notifyPreviewWebContentsPresence(
  entry: Entry,
  present: boolean
): void {
  if (!entry.isPreview || !previewWebContentsChangeHandler) {
    return;
  }
  try {
    previewWebContentsChangeHandler({
      webContentsId: entry.view.webContents.id,
      present,
    });
  } catch (error) {
    console.warn("Failed to notify preview WebContents change", error);
  }
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

interface ErrorDisplay {
  title: string;
  description: string;
  badgeLabel: string;
  details: Array<{ label: string; value: string }>;
}

interface NavigationMatch {
  test: RegExp;
  title: string;
  description: string;
}

const NAVIGATION_ERROR_MAPPINGS: NavigationMatch[] = [
  {
    test: /ERR_NAME_NOT_RESOLVED/i,
    title: "Domain not found",
    description:
      "The domain name couldn't be resolved. Verify the hostname or update your DNS settings.",
  },
  {
    test: /ERR_CONNECTION_REFUSED/i,
    title: "Connection refused",
    description:
      "The server refused the connection. Make sure the service is running and accepting connections.",
  },
  {
    test: /ERR_CONNECTION_TIMED_OUT/i,
    title: "Connection timed out",
    description:
      "The server took too long to respond. Check the server status or network connectivity.",
  },
  {
    test: /ERR_INTERNET_DISCONNECTED/i,
    title: "No internet connection",
    description:
      "We couldn't reach the internet. Check your network connection and try again.",
  },
  {
    test: /ERR_SSL_PROTOCOL_ERROR|ERR_CERT/i,
    title: "Secure connection failed",
    description:
      "The secure connection could not be established. Verify the TLS certificate or try HTTP.",
  },
  {
    test: /ERR_ADDRESS_UNREACHABLE|ERR_CONNECTION_RESET/i,
    title: "Host unreachable",
    description:
      "We couldn't reach the host. Confirm the service address and network routes.",
  },
];

function describeNavigationError(
  code: number,
  description: string,
  url: string
): ErrorDisplay {
  const match = NAVIGATION_ERROR_MAPPINGS.find(({ test }) =>
    test.test(description)
  );

  const title = match?.title ?? "Failed to load page";
  const desc =
    match?.description ??
    "Something went wrong while loading this page. Try refreshing or check the network logs.";

  const badgeLabel = `Code ${code}`;

  const details: Array<{ label: string; value: string }> = [
    { label: "Error", value: description || `Code ${code}` },
    { label: "URL", value: url },
  ];

  return {
    title,
    description: desc,
    badgeLabel,
    details,
  };
}

function describeHttpError(
  statusCode: number,
  statusText: string | undefined,
  url: string
): ErrorDisplay {
  let title = "Request failed";
  let description =
    "The server responded with an error. Try refreshing the page or checking the service logs.";

  if (statusCode === 404) {
    title = "Page not found";
    description =
      "We couldn't find that page. Double-check the URL or make sure the route is available.";
  } else if (statusCode === 401 || statusCode === 403) {
    title = "Access denied";
    description =
      "This page requires authentication or additional permissions. Sign in or update the request headers.";
  } else if (statusCode >= 500) {
    title = "Server error";
    description =
      "The server encountered an error while handling the request. Check the service logs or try again.";
  } else if (statusCode >= 400) {
    title = "Request blocked";
    description =
      "The server rejected the request. Review the request payload or try again.";
  }

  const statusDetail = statusText
    ? `HTTP ${statusCode} · ${statusText}`
    : `HTTP ${statusCode}`;

  return {
    title,
    description,
    badgeLabel: statusDetail,
    details: [
      { label: "Status", value: statusDetail },
      { label: "URL", value: url },
    ],
  };
}

function buildErrorHtml(errorDisplay: ErrorDisplay): string {
  const detailsHtml = errorDisplay.details
    .map(
      ({ label, value }) => `
        <div>
          <dt class="font-medium uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
            ${escapeHtml(label)}
          </dt>
          <dd class="mt-0.5 break-words text-neutral-600 dark:text-neutral-300">
            ${escapeHtml(value)}
          </dd>
        </div>
      `
    )
    .join("");

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(errorDisplay.title)}</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: white;
      color: #171717;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 1.5rem;
    }
    @media (prefers-color-scheme: dark) {
      body {
        background: #0a0a0a;
        color: #fafafa;
      }
    }
    .container {
      width: 100%;
      max-width: 24rem;
      padding: 1.5rem;
      background: white;
      border: 1px solid #e5e5e5;
      border-radius: 0.5rem;
      box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1);
    }
    @media (prefers-color-scheme: dark) {
      .container {
        background: #171717;
        border-color: #262626;
      }
    }
    .badge {
      display: inline-flex;
      align-items: center;
      padding: 0.125rem 0.625rem;
      margin-bottom: 0.75rem;
      font-size: 0.75rem;
      font-weight: 500;
      border-radius: 9999px;
      background: #e5e5e5;
      color: #404040;
    }
    @media (prefers-color-scheme: dark) {
      .badge {
        background: #262626;
        color: #d4d4d4;
      }
    }
    h1 {
      font-size: 1.125rem;
      font-weight: 600;
      line-height: 1.75rem;
      color: #171717;
    }
    @media (prefers-color-scheme: dark) {
      h1 {
        color: #fafafa;
      }
    }
    .description {
      margin-top: 0.5rem;
      font-size: 0.875rem;
      line-height: 1.5;
      color: #525252;
    }
    @media (prefers-color-scheme: dark) {
      .description {
        color: #d4d4d4;
      }
    }
    dl {
      margin-top: 1rem;
      font-size: 0.75rem;
      color: #737373;
    }
    @media (prefers-color-scheme: dark) {
      dl {
        color: #a3a3a3;
      }
    }
    dl > div {
      margin-top: 0.5rem;
    }
    dl > div:first-child {
      margin-top: 0;
    }
    dt {
      font-weight: 500;
      text-transform: uppercase;
      letter-spacing: 0.025em;
      color: #a3a3a3;
    }
    @media (prefers-color-scheme: dark) {
      dt {
        color: #737373;
      }
    }
    dd {
      margin-top: 0.125rem;
      word-break: break-all;
      color: #525252;
    }
    @media (prefers-color-scheme: dark) {
      dd {
        color: #d4d4d4;
      }
    }
  </style>
</head>
<body>
  <div class="container">
    ${errorDisplay.badgeLabel ? `<span class="badge">${escapeHtml(errorDisplay.badgeLabel)}</span>` : ""}
    <h1>${escapeHtml(errorDisplay.title)}</h1>
    <p class="description">${escapeHtml(errorDisplay.description)}</p>
    ${errorDisplay.details.length > 0 ? `<dl>${detailsHtml}</dl>` : ""}
  </div>
</body>
</html>`;
}

function buildErrorUrl(params: {
  type: "navigation" | "http";
  url: string;
  code?: number;
  description?: string;
  statusCode?: number;
  statusText?: string;
}): string {
  const errorDisplay: ErrorDisplay =
    params.type === "http"
      ? describeHttpError(
          params.statusCode ?? 0,
          params.statusText,
          params.url ?? ""
        )
      : describeNavigationError(
          params.code ?? 0,
          params.description ?? "",
          params.url ?? ""
        );

  const html = buildErrorHtml(errorDisplay);
  const base64Html = Buffer.from(html, "utf-8").toString("base64");
  return `data:text/html;base64,${base64Html}`;
}

function sendEventToOwner(
  entry: Entry,
  payload: ElectronWebContentsEvent,
  logger: Logger
) {
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
    return {
      id: entry.id,
      webContentsId: contents.id,
      url: contents.getURL(),
      title: contents.getTitle(),
      canGoBack: contents.navigationHistory.canGoBack(),
      canGoForward: contents.navigationHistory.canGoForward(),
      isLoading: contents.isLoading(),
      isDevToolsOpened: contents.isDevToolsOpened(),
    };
  } catch (error) {
    console.error("Failed to build state", error);
    return null;
  }
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
    httpStatusText: string
  ) => {
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
    isMainFrame: boolean
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

  entry.eventCleanup = cleanup;
  sendState(entry, logger, "initialized");
}

const registeredSessions = new WeakSet<Session>();

function ensureWebRequestListener(targetSession: Session, _logger: Logger) {
  if (registeredSessions.has(targetSession)) return;
  const listener = () => {
    // Error handling is done in onDidNavigate
  };
  targetSession.webRequest.onCompleted({ urls: ["*://*/*"] }, listener);
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
  logger: Logger
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
        }
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
  notifyPreviewWebContentsPresence(entry, false);
  entriesByWebContentsId.delete(entry.view.webContents.id);
  try {
    if (entry.previewProxyCleanup) {
      try {
        entry.previewProxyCleanup();
      } catch (error) {
        console.error("Failed to cleanup preview proxy", error);
      } finally {
        entry.previewProxyCleanup = undefined;
      }
    }
    removeFromSuspended(entry);
    for (const cleanup of entry.eventCleanup) {
      try {
        cleanup();
      } catch (error) {
        console.error("Failed to cleanup event listener", error);
        // ignore cleanup failures
      }
    }
    entry.eventCleanup = [];
    entry.ownerSender = null;
    const win = BrowserWindow.fromId(entry.ownerWindowId);
    if (win && !win.isDestroyed()) {
      try {
        win.contentView.removeChildView(entry.view);
      } catch (error) {
        console.error("Failed to remove view from window", error);
        // ignore removal failures
      }
    }
    try {
      destroyWebContents(entry.view.webContents);
    } catch (error) {
      console.error("Failed to destroy webContents", error);
    }
  } finally {
    viewEntries.delete(id);
  }
  return true;
}

function destroyConflictingEntries(
  persistKey: string,
  windowId: number,
  logger: Logger
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

function toBounds(bounds: Rectangle | undefined, zoomFactor = 1): Rectangle {
  const zoom =
    typeof zoomFactor === "number" &&
    Number.isFinite(zoomFactor) &&
    zoomFactor > 0
      ? zoomFactor
      : 1;
  if (!bounds) return { x: 0, y: 0, width: 0, height: 0 };
  return {
    x: Math.round((bounds.x ?? 0) * zoom),
    y: Math.round((bounds.y ?? 0) * zoom),
    width: Math.max(0, Math.round((bounds.width ?? 0) * zoom)),
    height: Math.max(0, Math.round((bounds.height ?? 0) * zoom)),
  };
}

function getSenderZoomFactor(sender: WebContents | null | undefined): number {
  if (!sender) return 1;
  try {
    const zoom = sender.getZoomFactor();
    if (typeof zoom === "number" && Number.isFinite(zoom) && zoom > 0) {
      return zoom;
    }
  } catch (error) {
    console.warn("Failed to read sender zoom factor", error);
  }
  return 1;
}

function evaluateVisibility(bounds: Rectangle, explicit?: boolean): boolean {
  if (typeof explicit === "boolean") return explicit;
  return bounds.width > 0 && bounds.height > 0;
}

function applyBackgroundColor(
  view: Electron.WebContentsView,
  color: string | undefined
) {
  if (!color) return;
  try {
    view.setBackgroundColor(color);
  } catch (error) {
    console.error("Failed to apply background color", error);
  }
}

function applyBorderRadius(
  view: Electron.WebContentsView,
  radius: number | undefined
) {
  if (typeof radius !== "number" || Number.isNaN(radius)) return;
  const safe = Math.max(0, Math.round(radius));
  try {
    view.setBorderRadius(safe);
  } catch (error) {
    console.error("Failed to apply border radius", error);
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
  onPreviewWebContentsChange,
}: RegisterOptions): void {
  setMaxSuspendedEntries(providedMax);
  previewWebContentsChangeHandler = onPreviewWebContentsChange ?? null;

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

        const zoomFactor = getSenderZoomFactor(sender);
        const bounds = toBounds(options.bounds, zoomFactor);
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
                error
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
                }
              );
            }

            if (options.backgroundColor !== undefined) {
              applyBackgroundColor(candidate.view, options.backgroundColor);
            }
            if (options.borderRadius !== undefined) {
              applyBorderRadius(candidate.view, options.borderRadius);
            }

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
            logger.warn(
              "Unable to reattach WebContentsView despite matching persistKey",
              {
                persistKey,
                candidateId: candidate.id,
                candidateOwnerWebContentsId: candidate.ownerWebContentsId,
                requestWebContentsId: sender.id,
                ownerDestroyed: candidate.ownerWebContentsDestroyed,
              }
            );
          }

          destroyConflictingEntries(persistKey, win.id, logger);
        }

        const previewPartition = getPreviewPartitionForPersistKey(persistKey);
        const view = previewPartition
          ? new WebContentsView({
              webPreferences: { partition: previewPartition },
            })
          : new WebContentsView();

        view.webContents.setWindowOpenHandler((details) => {
          const normalized = normalizeBrowserUrl(details.url ?? "");
          if (!normalized) {
            return { action: "deny" };
          }
          try {
            void shell.openExternal(normalized);
          } catch (error) {
            logger.warn("Failed to open external URL from WebContentsView", {
              url: normalized,
              error,
            });
          }
          return { action: "deny" };
        });

        const disposeContextMenu = registerContextMenuForTarget(view);

        applyChromeCamouflage(view, logger);

        applyBackgroundColor(view, options.backgroundColor);
        applyBorderRadius(view, options.borderRadius);

        try {
          win.contentView.addChildView(view);
        } catch (error) {
          logger.error("Failed to add WebContentsView to window", error);
          try {
            destroyWebContents(view.webContents);
          } catch (error) {
            console.error("Failed to destroy webContents", error);
          }
          throw error;
        }

        try {
          view.setBounds(bounds);
          view.setVisible(desiredVisibility);
        } catch (error) {
          logger.warn(
            "Failed to set initial bounds for WebContentsView",
            error
          );
        }

        const finalUrl = options.url ?? "about:blank";
        const proxySourceUrl = options.requestUrl ?? finalUrl;
        let previewProxyCleanup: (() => void) | undefined;
        if (
          isTaskRunPreviewPersistKey(persistKey) &&
          typeof proxySourceUrl === "string" &&
          proxySourceUrl.startsWith("http")
        ) {
          try {
            previewProxyCleanup = await configurePreviewProxyForView({
              webContents: view.webContents,
              initialUrl: proxySourceUrl,
              persistKey,
              logger,
            });
          } catch (error) {
            logger.warn("Failed to enable preview proxy", {
              persistKey,
              error,
            });
          }
        }
        void view.webContents.loadURL(finalUrl).catch((error) =>
          logger.warn("WebContentsView initial load failed", {
            url: finalUrl,
            error,
          })
        );

        const id = nextViewId++;
        const isPreview = isTaskRunPreviewPersistKey(persistKey);
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
          previewProxyCleanup,
          previewPartition,
          isPreview,
        };
        viewEntries.set(id, entry);
        setupEventForwarders(entry, logger);
        entry.eventCleanup.push(disposeContextMenu);
        sendState(entry, logger, "created");
        notifyPreviewWebContentsPresence(entry, true);

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
    }
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

      const zoomFactor = getSenderZoomFactor(event.sender);
      const bounds = toBounds(rawBounds, zoomFactor);
      try {
        entry.view.setBounds(bounds);
        entry.view.setVisible(evaluateVisibility(bounds, visible));
        return { ok: true };
      } catch (error) {
        entry.view.setVisible(false);
        return { ok: false, error: String(error) };
      }
    }
  );

  ipcMain.handle(
    "cmux:webcontents:load-url",
    (event, options: LoadUrlOptions) => {
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
        void entry.view.webContents.loadURL(url);
        return { ok: true };
      } catch (error) {
        logger.warn("Failed to load URL", { id, url, error });
        return { ok: false, error: String(error) };
      }
    }
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
        } catch (error) {
          console.error("Failed to remove view from window", error);
        }
      }

      try {
        entry.view.setVisible(false);
      } catch (error) {
        console.error("Failed to set visible", error);
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
    }
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
    }
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
      } catch (error) {
        console.error("Failed to get bounds, setting bounds = null", error);
        bounds = null;
      }
      try {
        visible = entry.view.getVisible();
      } catch (error) {
        console.error("Failed to get visible, setting visible = null", error);
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
    }
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
  id: number
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
  } catch (error) {
    console.error("Failed to get webContents layout snapshot", error);
    return null;
  }
}
