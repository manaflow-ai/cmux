import path, { join } from "node:path";
import { pathToFileURL } from "node:url";

import { is } from "@electron-toolkit/utils";
import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  ipcMain,
  Menu,
  MenuItem,
  nativeImage,
  net,
  session,
  shell,
  webFrameMain,
  type BrowserWindowConstructorOptions,
  type MenuItemConstructorOptions,
  type Certificate,
} from "electron";
import { startEmbeddedServer } from "./embedded-server";
import { registerWebContentsViewHandlers } from "./web-contents-view";
import { registerGlobalContextMenu } from "./context-menu";
import electronUpdater, {
  type UpdateCheckResult,
  type UpdateInfo,
} from "electron-updater";
import semver from "semver";
import {
  createRemoteJWKSet,
  decodeJwt,
  jwtVerify,
  type JWTPayload,
} from "jose";
import { promises as fs } from "node:fs";
import { collectAllLogs } from "./log-management/collect-logs";
import { ensureLogDirectory } from "./log-management/log-paths";
import {
  appendLogWithRotation,
  type LogRotationOptions,
} from "./log-management/log-rotation";
const { autoUpdater } = electronUpdater;

import util from "node:util";
import { initCmdK, keyDebug } from "./cmdk";
import { env } from "./electron-main-env";
import {
  getPreviewProxyCertificateAuthorityInfo,
  getProxyCredentialsForWebContents,
  startPreviewProxy,
} from "./task-run-preview-proxy";
import { normalizeBrowserUrl } from "@cmux/shared";

// Use a cookieable HTTPS origin intercepted locally instead of a custom scheme.
const PARTITION = "persist:cmux";
const APP_HOST = "cmux.local";

function resolveMaxSuspendedWebContents(): number | undefined {
  const raw =
    process.env.CMUX_ELECTRON_MAX_SUSPENDED_WEBVIEWS ??
    process.env.CMUX_ELECTRON_MAX_SUSPENDED_WEB_CONTENTS;
  if (!raw) return undefined;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || Number.isNaN(parsed) || parsed < 0) {
    return undefined;
  }
  return parsed;
}

type AutoUpdateToastPayload = {
  version: string | null;
};

let queuedAutoUpdateToast: AutoUpdateToastPayload | null = null;

// Persistent log files
let logsDir: string | null = null;
let mainLogPath: string | null = null;
let rendererLogPath: string | null = null;

const LOG_ROTATION: LogRotationOptions = {
  maxBytes: 5 * 1024 * 1024,
  maxBackups: 3,
};

process.on("uncaughtException", (error) => {
  console.error("[ElectronMain] Uncaught exception", error);
});

process.on("unhandledRejection", (reason) => {
  console.error("[ElectronMain] Unhandled rejection", reason);
});

let rendererLoaded = false;
let pendingProtocolUrl: string | null = null;
let mainWindow: BrowserWindow | null = null;
let previewReloadMenuItem: MenuItem | null = null;
let previewBackMenuItem: MenuItem | null = null;
let previewForwardMenuItem: MenuItem | null = null;
let previewFocusAddressMenuItem: MenuItem | null = null;
let previewReloadMenuVisible = false;
let historyBackMenuItem: MenuItem | null = null;
let historyForwardMenuItem: MenuItem | null = null;
const previewWebContentsIds = new Set<number>();
const altGrActivePreviewContents = new Set<number>();

function getTimestamp(): string {
  return new Date().toISOString();
}

function ensureLogFiles(): void {
  if (logsDir && mainLogPath && rendererLogPath) return;
  const dir = ensureLogDirectory();
  logsDir = dir;
  mainLogPath = join(dir, "main.log");
  rendererLogPath = join(dir, "renderer.log");
}

function writeMainLogLine(level: "LOG" | "WARN" | "ERROR", line: string): void {
  if (!mainLogPath) ensureLogFiles();
  if (!mainLogPath) return;
  appendLogWithRotation(
    mainLogPath,
    `[${getTimestamp()}] [MAIN] [${level}] ${line}\n`,
    LOG_ROTATION
  );
}

function writeRendererLogLine(
  level: "info" | "warning" | "error" | "debug",
  line: string
): void {
  if (!rendererLogPath) ensureLogFiles();
  if (!rendererLogPath) return;
  appendLogWithRotation(
    rendererLogPath,
    `[${getTimestamp()}] [RENDERER] [${level.toUpperCase()}] ${line}\n`,
    LOG_ROTATION
  );
}

function getActiveBrowserWindow(): BrowserWindow | null {
  const target =
    BrowserWindow.getFocusedWindow() ??
    mainWindow ??
    BrowserWindow.getAllWindows()[0] ??
    null;
  if (!target || target.isDestroyed()) {
    return null;
  }
  return target;
}

function updateHistoryMenuState(target?: BrowserWindow | null): void {
  if (!historyBackMenuItem && !historyForwardMenuItem) return;
  const focusableTarget =
    target && !target.isDestroyed() && target.isFocused() ? target : null;
  const window = focusableTarget ?? getActiveBrowserWindow();
  const contents = window && !window.isDestroyed() ? window.webContents : null;
  const canGoBack = Boolean(contents?.canGoBack?.());
  const canGoForward = Boolean(contents?.canGoForward?.());
  if (historyBackMenuItem) {
    historyBackMenuItem.enabled = canGoBack;
  }
  if (historyForwardMenuItem) {
    historyForwardMenuItem.enabled = canGoForward;
  }
}

function navigateHistory(direction: "back" | "forward"): void {
  const target = getActiveBrowserWindow();
  if (!target) return;
  const contents = target.webContents;
  if (direction === "back") {
    if (contents.canGoBack()) {
      contents.goBack();
    }
  } else if (direction === "forward" && contents.canGoForward()) {
    contents.goForward();
  }
  updateHistoryMenuState(target);
}

function getPreviewNavigationAccelerator(key: string): string {
  if (process.platform === "darwin") {
    return `Command+Control+${key}`;
  }
  return `Control+Alt+${key}`;
}

function setupConsoleFileMirrors(): void {
  const orig = {
    log: console.log.bind(console),
    warn: console.warn.bind(console),
    error: console.error.bind(console),
  } as const;

  console.log = (...args: unknown[]) => {
    try {
      orig.log(...args);
    } finally {
      try {
        writeMainLogLine("LOG", formatArgs(args));
      } catch {
        // ignore
      }
    }
  };
  console.warn = (...args: unknown[]) => {
    try {
      orig.warn(...args);
    } finally {
      try {
        writeMainLogLine("WARN", formatArgs(args));
      } catch {
        // ignore
      }
    }
  };
  console.error = (...args: unknown[]) => {
    try {
      orig.error(...args);
    } finally {
      try {
        writeMainLogLine("ERROR", formatArgs(args));
      } catch {
        // ignore
      }
    }
  };
}

function setupPreviewProxyCertificateTrust(): void {
  const caInfo = getPreviewProxyCertificateAuthorityInfo();
  app.on(
    "certificate-error",
    (event, _webContents, _url, _error, certificate, callback) => {
      if (isPreviewProxyCertificate(certificate)) {
        event.preventDefault();
        callback(true);
        return;
      }
      callback(false);
    }
  );

  function isPreviewProxyCertificate(cert: Certificate | undefined): boolean {
    if (!cert) return false;
    if (cert.issuerName?.includes(caInfo.subject)) {
      return true;
    }
    const fingerprint = normalizeFingerprint(cert.fingerprint ?? "");
    return fingerprint === normalizeFingerprint(caInfo.fingerprint256);
  }
}

function normalizeFingerprint(input: string): string {
  return input.replace(/[^0-9A-Fa-f]/g, "").toUpperCase();
}

function resolveResourcePath(rel: string) {
  // Prod: packaged resources directory; Dev: look under client/assets
  if (app.isPackaged) return path.join(process.resourcesPath, rel);
  return path.join(app.getAppPath(), "assets", rel);
}

// Lightweight logger that prints to the main process stdout and mirrors
// into the renderer console (via preload listener) when available.
type LogLevel = "log" | "warn" | "error";
function emitToRenderer(level: LogLevel, message: string) {
  try {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send("main-log", { level, message });
    }
  } catch (error) {
    console.error("Failed to emit to renderer", error);
  }
}

function formatArgs(args: unknown[]): string {
  const ts = new Date().toISOString();
  const body = args
    .map((a) =>
      typeof a === "string" ? a : util.inspect(a, { depth: 3, colors: false })
    )
    .join(" ");
  return `[${ts}] ${body}`;
}

export function mainLog(...args: unknown[]) {
  const line = formatArgs(args);

  console.log("[MAIN]", line);
  emitToRenderer("log", `[MAIN] ${line}`);
}

export function mainWarn(...args: unknown[]) {
  const line = formatArgs(args);

  console.warn("[MAIN]", line);
  emitToRenderer("warn", `[MAIN] ${line}`);
}

export function mainError(...args: unknown[]) {
  const line = formatArgs(args);

  console.error("[MAIN]", line);
  emitToRenderer("error", `[MAIN] ${line}`);
}

function sendShortcutToFocusedWindow(
  eventName: string,
  payload?: unknown
): boolean {
  try {
    const target = getActiveBrowserWindow();
    if (!target) {
      return false;
    }
    target.webContents.send(`cmux:event:shortcut:${eventName}`, payload);
    return true;
  } catch (error) {
    mainWarn("Failed to dispatch shortcut event", { eventName, error });
    return false;
  }
}

function setPreviewReloadMenuVisibility(visible: boolean): void {
  previewReloadMenuVisible = visible;
  const applyVisibility = (item: MenuItem | null) => {
    if (item) {
      item.visible = visible;
    }
  };
  applyVisibility(previewReloadMenuItem);
  applyVisibility(previewBackMenuItem);
  applyVisibility(previewForwardMenuItem);
  applyVisibility(previewFocusAddressMenuItem);
}

ipcMain.on("cmux:get-current-webcontents-id", (event) => {
  event.returnValue = event.sender.id;
});

ipcMain.handle(
  "cmux:ui:set-preview-reload-visible",
  async (_event, visible: unknown) => {
    setPreviewReloadMenuVisibility(Boolean(visible));
    return { ok: true };
  }
);

function emitAutoUpdateToastIfPossible(): void {
  if (!queuedAutoUpdateToast) return;
  if (!mainWindow || mainWindow.isDestroyed() || !rendererLoaded) return;
  try {
    mainWindow.webContents.send(
      "cmux:event:auto-update:ready",
      queuedAutoUpdateToast
    );
    queuedAutoUpdateToast = null;
  } catch (error) {
    mainWarn("Failed to send auto-update toast to renderer", error);
  }
}

function queueAutoUpdateToast(payload: AutoUpdateToastPayload): void {
  queuedAutoUpdateToast = payload;
  emitAutoUpdateToastIfPossible();
}

function resolveSemverVersion(value: string | null | undefined): string | null {
  if (!value) return null;
  const valid = semver.valid(value);
  if (valid) return valid;
  const coerced = semver.coerce(value);
  return coerced ? coerced.version : null;
}

function isUpdateNewerThanCurrent(
  info: UpdateInfo | null | undefined
): boolean {
  if (!info) return false;

  const updateVersion = resolveSemverVersion(info.version);
  if (!updateVersion) return false;

  const currentVersion = resolveSemverVersion(app.getVersion());
  if (!currentVersion) {
    return info.version !== app.getVersion();
  }

  const updateParsed = semver.parse(updateVersion);
  const currentParsed = semver.parse(currentVersion);

  if (!updateParsed || !currentParsed) {
    return semver.gt(updateVersion, currentVersion);
  }

  const isNewer = semver.gt(updateParsed, currentParsed);
  if (!isNewer) return false;

  const currentHasPrerelease = currentParsed.prerelease.length > 0;
  const updateHasPrerelease = updateParsed.prerelease.length > 0;
  const sameCoreVersion =
    updateParsed.major === currentParsed.major &&
    updateParsed.minor === currentParsed.minor &&
    updateParsed.patch === currentParsed.patch;

  if (currentHasPrerelease && !updateHasPrerelease && sameCoreVersion) {
    return false;
  }

  return true;
}

function logUpdateCheckResult(
  context: string,
  result: UpdateCheckResult | null | undefined
): void {
  if (!result) {
    mainLog(`${context} completed`, { updateAvailable: false });
    return;
  }

  const info = result.updateInfo;
  const summary = {
    updateAvailable: isUpdateNewerThanCurrent(info),
    version: info?.version ?? null,
    releaseDate: info?.releaseDate ?? null,
    fileCount: info?.files?.length ?? 0,
    stagingPercentage:
      typeof info?.stagingPercentage === "number"
        ? info.stagingPercentage
        : null,
  };

  mainLog(`${context} completed`, summary);
}

function registerLogIpcHandlers(): void {
  ipcMain.handle("cmux:logs:read-all", async () => {
    try {
      return await collectAllLogs();
    } catch (error) {
      mainWarn("Failed to read logs for renderer", error);
      const err = error instanceof Error ? error : new Error(String(error));
      throw err;
    }
  });

  ipcMain.handle("cmux:logs:copy-all", async () => {
    try {
      const { combinedText } = await collectAllLogs();
      clipboard.writeText(combinedText);
      return { ok: true };
    } catch (error) {
      mainWarn("Failed to copy logs for renderer", error);
      const err = error instanceof Error ? error : new Error(String(error));
      throw err;
    }
  });
}

function registerAutoUpdateIpcHandlers(): void {
  ipcMain.handle("cmux:auto-update:check", async () => {
    if (!app.isPackaged) {
      mainLog(
        "Auto-update check requested while app is not packaged; ignoring request"
      );
      return { ok: false, reason: "not-packaged" as const };
    }

    try {
      mainLog("Renderer requested manual checkForUpdates");
      const result = await autoUpdater.checkForUpdates();
      logUpdateCheckResult("Renderer checkForUpdates", result);

      const updateInfo = result?.updateInfo;
      const version =
        updateInfo && typeof updateInfo.version === "string"
          ? updateInfo.version
          : null;

      return {
        ok: true as const,
        updateAvailable: isUpdateNewerThanCurrent(updateInfo),
        version,
      };
    } catch (error) {
      mainWarn("Renderer-initiated checkForUpdates failed", error);
      const err = error instanceof Error ? error : new Error(String(error));
      throw err;
    }
  });

  ipcMain.handle("cmux:auto-update:install", async () => {
    if (!app.isPackaged) {
      mainLog(
        "Auto-update install requested while app is not packaged; ignoring request"
      );
      return { ok: false, reason: "not-packaged" as const };
    }

    try {
      queuedAutoUpdateToast = null;
      autoUpdater.quitAndInstall();
      return { ok: true } as const;
    } catch (error) {
      mainWarn("Failed to trigger quitAndInstall", error);
      const err = error instanceof Error ? error : new Error(String(error));
      throw err;
    }
  });
}

// Write critical errors to a file to aid debugging packaged crashes
async function writeFatalLog(...args: unknown[]) {
  try {
    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    const base = app.getPath("userData");
    const file = path.join(base, `fatal-${ts}.log`);
    const msg = formatArgs(args);
    await fs.writeFile(file, msg + "\n", { encoding: "utf8" });
  } catch (error) {
    console.error("Failed to write fatal log", error);
    // ignore
  }
}

process.on("uncaughtException", (err) => {
  console.error("[MAIN] uncaughtException", err);
  void writeFatalLog("uncaughtException", err);
});
process.on("unhandledRejection", (reason) => {
  console.error("[MAIN] unhandledRejection", reason);
  void writeFatalLog("unhandledRejection", reason);
});

function setupAutoUpdates(): void {
  if (!app.isPackaged) {
    mainLog("Skipping auto-updates in development");
    return;
  }

  mainLog("Setting up auto-updates", {
    appVersion: app.getVersion(),
    platform: process.platform,
    arch: process.arch,
  });

  try {
    // Wire logs to our logger
    (autoUpdater as unknown as { logger: unknown }).logger = {
      info: (...args: unknown[]) => mainLog("[updater]", ...args),
      warn: (...args: unknown[]) => mainWarn("[updater]", ...args),
      error: (...args: unknown[]) => mainError("[updater]", ...args),
    } as unknown as typeof autoUpdater.logger;

    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.allowPrerelease = false;

    if (process.platform === "darwin") {
      const channel = "latest-universal";
      if (autoUpdater.channel !== channel) {
        autoUpdater.channel = channel;
        mainLog("Configured autoUpdater channel", {
          channel,
          arch: process.arch,
        });
      }
    }

    mainLog("Auto-updater configuration complete", {
      autoDownload: autoUpdater.autoDownload,
      autoInstallOnAppQuit: autoUpdater.autoInstallOnAppQuit,
      allowPrerelease: autoUpdater.allowPrerelease,
      channel: autoUpdater.channel ?? null,
    });
  } catch (e) {
    mainWarn("Failed to initialize autoUpdater", e);
    return;
  }

  autoUpdater.on("checking-for-update", () => mainLog("Checking for update…"));
  autoUpdater.on("update-available", (info) =>
    mainLog("Update available", info?.version)
  );
  autoUpdater.on("update-not-available", () => mainLog("No updates available"));
  autoUpdater.on("error", (err) => mainWarn("Updater error", err));
  autoUpdater.on("download-progress", (p) =>
    mainLog(
      "Update download progress",
      `${p.percent?.toFixed?.(1) ?? 0}% (${p.transferred}/${p.total})`
    )
  );
  autoUpdater.on("update-downloaded", (info: UpdateInfo) => {
    const version =
      info &&
      typeof info === "object" &&
      "version" in info &&
      typeof info.version === "string"
        ? info.version
        : null;

    if (!isUpdateNewerThanCurrent(info)) {
      mainLog(
        "Ignoring downloaded update that is not newer than current build",
        {
          version,
          currentVersion: app.getVersion(),
        }
      );
      return;
    }

    mainLog("Update downloaded; notifying renderer", { version });
    queueAutoUpdateToast({ version });
  });

  // Initial check and periodic re-checks
  mainLog("Starting initial auto-update check");
  autoUpdater
    .checkForUpdatesAndNotify()
    .then((result) =>
      logUpdateCheckResult("Initial checkForUpdatesAndNotify", result)
    )
    .catch((e) => mainWarn("checkForUpdatesAndNotify failed", e));
  const CHECK_INTERVAL_MS = 30 * 60 * 1000;
  setInterval(() => {
    mainLog("Starting scheduled auto-update check");
    autoUpdater
      .checkForUpdates()
      .then((result) =>
        logUpdateCheckResult("Scheduled checkForUpdates", result)
      )
      .catch((e) => mainWarn("Periodic checkForUpdates failed", e));
  }, CHECK_INTERVAL_MS); // 30 minutes
}

async function handleOrQueueProtocolUrl(url: string) {
  if (mainWindow && rendererLoaded) {
    mainLog("Handling protocol URL immediately", { url });
    await handleProtocolUrl(url);
  } else {
    mainLog("Queueing protocol URL until renderer ready", { url });
    pendingProtocolUrl = url;
  }
}

function createWindow(): void {
  const windowOptions: BrowserWindowConstructorOptions = {
    width: 1200,
    height: 800,
    show: false,
    autoHideMenuBar: true,
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 12, y: 10 },
    webPreferences: {
      preload: join(app.getAppPath(), "out/preload/index.cjs"),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false,
      webviewTag: true,
      partition: PARTITION,
    },
  };

  // Use only the icon from cmux-logos iconset.
  const iconPng = resolveResourcePath(
    "cmux-logos/cmux.iconset/icon_512x512.png"
  );
  if (process.platform !== "darwin") {
    windowOptions.icon = iconPng;
  }

  mainWindow = new BrowserWindow(windowOptions);

  // Capture renderer console output into renderer.log
  mainWindow.webContents.on(
    "console-message",
    ({ level, lineNumber, message, sourceId }) => {
      const src = sourceId
        ? `${sourceId}${lineNumber ? `:${lineNumber}` : ""}`
        : "";
      const msg = src ? `${message} (${src})` : message;
      writeRendererLogLine(level, msg);
    }
  );

  mainWindow.on("ready-to-show", () => {
    mainLog("Window ready-to-show");
    mainWindow?.show();
  });

  // Socket bridge not required; renderer connects directly

  // Initialize auto-updates
  setupAutoUpdates();

  // Once the renderer is loaded, process any queued deep-link
  mainWindow.webContents.on("did-finish-load", () => {
    mainLog("Renderer finished load");
    rendererLoaded = true;
    if (pendingProtocolUrl) {
      mainLog("Processing queued protocol URL", { url: pendingProtocolUrl });
      void handleProtocolUrl(pendingProtocolUrl);
      pendingProtocolUrl = null;
    }
    emitAutoUpdateToastIfPossible();
  });

  mainWindow.webContents.on(
    "did-fail-load",
    (
      _event,
      errorCode,
      errorDescription,
      validatedURL,
      isMainFrame,
      frameProcessId,
      frameRoutingId
    ) => {
      mainWarn("did-fail-load", {
        errorCode,
        errorDescription,
        validatedURL,
        isMainFrame,
        frameProcessId,
        frameRoutingId,
      });
    }
  );

  mainWindow.webContents.on(
    "did-frame-finish-load",
    (_event, isMainFrame, frameProcessId, frameRoutingId) => {
      let frameUrl: string | null = null;
      try {
        frameUrl =
          webFrameMain.fromId(frameProcessId, frameRoutingId)?.url ?? null;
      } catch (error) {
        frameUrl = `lookup-failed:${String(error)}`;
      }
      mainLog("did-frame-finish-load", {
        isMainFrame,
        frameProcessId,
        frameRoutingId,
        frameUrl,
      });
    }
  );

  mainWindow.webContents.on("did-navigate", (_e, url) => {
    mainLog("did-navigate", { url });
  });

  mainWindow.webContents.setWindowOpenHandler((details) => {
    const targetUrl = normalizeBrowserUrl(details.url);
    shell.openExternal(targetUrl);
    return { action: "deny" };
  });

  if (is.dev && process.env["ELECTRON_RENDERER_URL"]) {
    const url = process.env["ELECTRON_RENDERER_URL"]!;
    mainLog("Loading renderer (dev)", { url });
    mainWindow.loadURL(url);
  } else {
    // In production, serve the renderer over HTTPS on a private host which we
    // intercept and back with local files (supports cookies).
    mainLog("Loading renderer (prod)", { host: APP_HOST });
    mainWindow.loadURL(`https://${APP_HOST}/index.html`);
  }
}

app.on("browser-window-created", (_event, window) => {
  const updateForWindow = () => updateHistoryMenuState(window);
  window.webContents.on("did-navigate", updateForWindow);
  window.webContents.on("did-navigate-in-page", updateForWindow);
  window.on("focus", updateForWindow);
  window.on("closed", () => updateHistoryMenuState());
  updateHistoryMenuState(window);
});

app.on("browser-window-focus", (_event, window) => {
  updateHistoryMenuState(window);
});

app.on("login", (event, webContents, _request, authInfo, callback) => {
  if (!authInfo.isProxy) {
    return;
  }
  const creds = getProxyCredentialsForWebContents(webContents.id);
  if (!creds) {
    return;
  }
  event.preventDefault();
  callback(creds.username, creds.password);
});

app.on("open-url", (_event, url) => {
  handleOrQueueProtocolUrl(url);
});

app.whenReady().then(async () => {
  setupPreviewProxyCertificateTrust();
  ensureLogFiles();
  setupConsoleFileMirrors();
  const disposeContextMenu = registerGlobalContextMenu();
  app.once("will-quit", () => {
    try {
      disposeContextMenu();
    } catch (error) {
      console.error("Failed to dispose context menu", error);
    }
  });
  registerLogIpcHandlers();
  registerAutoUpdateIpcHandlers();
  initCmdK({
    getMainWindow: () => mainWindow,
    logger: {
      log: mainLog,
      warn: mainWarn,
    },
  });

  await startPreviewProxy({
    log: mainLog,
    warn: mainWarn,
    error: mainError,
  });

  // Register before-input-event handlers for preview browser shortcuts
  // These fire before web content sees them, so they work even in WebContentsViews
  app.on("web-contents-created", (_event, contents) => {
    contents.on("before-input-event", (e, input) => {
      if (!previewWebContentsIds.has(contents.id)) return;

      const isMac = process.platform === "darwin";
      if (!isMac) {
        const isAltGrKey =
          input.code === "AltRight" || input.key === "AltGraph";
        if (isAltGrKey) {
          if (input.type === "keyDown") {
            altGrActivePreviewContents.add(contents.id);
          } else if (input.type === "keyUp") {
            altGrActivePreviewContents.delete(contents.id);
          }
        }
      }

      if (input.type !== "keyDown") return;

      // Only handle preview shortcuts when preview is visible
      if (!previewReloadMenuVisible) return;

      const key = input.key.toLowerCase();
      const primaryModifierActive = isMac
        ? input.meta && !input.control && !input.alt && !input.shift
        : input.control && !input.meta && !input.alt && !input.shift;
      const isAltGrActive =
        !isMac && altGrActivePreviewContents.has(contents.id);
      const previewNavModifierActive = isMac
        ? input.meta && input.control && !input.alt && !input.shift
        : input.control &&
          input.alt &&
          !input.meta &&
          !input.shift &&
          !isAltGrActive;

      // cmd+l / ctrl+l: focus address bar
      if (primaryModifierActive && key === "l") {
        e.preventDefault();
        sendShortcutToFocusedWindow("preview-focus-address");
        return;
      }

      // cmd+ctrl+[: go back (mac) / ctrl+alt+[ (others)
      if (previewNavModifierActive && input.key === "[") {
        e.preventDefault();
        sendShortcutToFocusedWindow("preview-back");
        return;
      }

      // cmd+ctrl+]: go forward (mac) / ctrl+alt+] (others)
      if (previewNavModifierActive && input.key === "]") {
        e.preventDefault();
        sendShortcutToFocusedWindow("preview-forward");
        return;
      }

      // cmd+r / ctrl+r: reload
      if (primaryModifierActive && key === "r") {
        e.preventDefault();
        sendShortcutToFocusedWindow("preview-reload");
        return;
      }
    });
  });
  registerWebContentsViewHandlers({
    logger: {
      log: mainLog,
      warn: mainWarn,
      error: mainError,
    },
    maxSuspendedEntries: resolveMaxSuspendedWebContents(),
    onPreviewWebContentsChange: ({ webContentsId, present }) => {
      if (present) {
        previewWebContentsIds.add(webContentsId);
      } else {
        previewWebContentsIds.delete(webContentsId);
        altGrActivePreviewContents.delete(webContentsId);
      }
    },
  });

  // Ensure macOS menu and About panel use "cmux" instead of package.json name
  if (process.platform === "darwin") {
    try {
      app.setName("cmux");
      app.setAboutPanelOptions({ applicationName: "cmux" });
    } catch (error) {
      console.error("Failed to set app name and about panel options", error);
    }
  }

  // Start the embedded IPC server (registers cmux:register and cmux:rpc)
  try {
    mainLog("Starting embedded IPC server...");
    await startEmbeddedServer();
    mainLog("Embedded IPC server started successfully");
  } catch (error) {
    mainError("Failed to start embedded IPC server:", error);
    process.exit(1);
  }

  // Try to register the custom protocol handler with the OS. electron-builder
  // will add CFBundleURLTypes on macOS, but calling this is harmless and also
  // helps on Windows/Linux when packaged.
  try {
    const ok = app.setAsDefaultProtocolClient("cmux");
    mainLog("setAsDefaultProtocolClient(cmux)", {
      ok,
      packaged: app.isPackaged,
    });
  } catch (e) {
    mainWarn("setAsDefaultProtocolClient failed", e);
  }

  // When packaged, electron-vite outputs the renderer to out/renderer
  // which is bundled inside app.asar (referenced by app.getAppPath()).
  const baseDir = path.join(app.getAppPath(), "out", "renderer");

  // Set Dock icon from iconset on macOS.
  if (process.platform === "darwin") {
    const iconPng = resolveResourcePath(
      "cmux-logos/cmux.iconset/icon_512x512.png"
    );
    const img = nativeImage.createFromPath(iconPng);
    if (!img.isEmpty()) app.dock?.setIcon(img);
  }

  // session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
  //   callback({
  //     responseHeaders: {
  //       ...details.responseHeaders,
  //       // "Content-Security-Policy": ["script-src 'self' https://cmux.sh"],
  //       "Content-Security-Policy": ["*"],
  //     },
  //   });
  // });

  const ses = session.fromPartition(PARTITION);

  const handleCmuxProtocol = async (request: Request): Promise<Response> => {
    const electronReq = request as unknown as Electron.ProtocolRequest;
    const url = new URL(electronReq.url);

    if (url.hostname !== APP_HOST) {
      return net.fetch(request);
    }

    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const fsPath = path.normalize(
      path.join(baseDir, decodeURIComponent(pathname))
    );
    const rel = path.relative(baseDir, fsPath);
    if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) {
      mainWarn("Blocked path outside baseDir", { fsPath, baseDir });
      return new Response("Not found", { status: 404 });
    }

    const response = await net.fetch(pathToFileURL(fsPath).toString());
    response.headers.set(
      "Content-Security-Policy",
      "default-src * 'unsafe-inline' 'unsafe-eval' data: blob: ws: wss:; worker-src * blob:; child-src * blob:; frame-src *"
    );
    return response;
  };

  ses.protocol.handle("https", handleCmuxProtocol);
  ses.protocol.handle("http", handleCmuxProtocol);

  // Create the initial window.
  if (BrowserWindow.getAllWindows().length === 0) createWindow();

  // Application menu with Command Palette accelerator; keep Help items.
  try {
    const template: MenuItemConstructorOptions[] = [];
    if (process.platform === "darwin") {
      template.push({ role: "appMenu" });
    } else {
      template.push({ label: "File", submenu: [{ role: "quit" }] });
    }
    const viewMenu: MenuItemConstructorOptions = {
      label: "View",
      submenu: [
        {
          id: "cmux-preview-reload",
          visible: previewReloadMenuVisible,
          label: "Reload Preview",
          accelerator: "CommandOrControl+R",
          click: () => {
            const dispatched = sendShortcutToFocusedWindow("preview-reload");
            if (!dispatched) {
              mainWarn(
                "Reload Preview shortcut triggered with no active renderer"
              );
            }
          },
        },
        {
          id: "cmux-preview-back",
          visible: previewReloadMenuVisible,
          label: "Back",
          accelerator: getPreviewNavigationAccelerator("["),
          click: () => {
            sendShortcutToFocusedWindow("preview-back");
          },
        },
        {
          id: "cmux-preview-forward",
          visible: previewReloadMenuVisible,
          label: "Forward",
          accelerator: getPreviewNavigationAccelerator("]"),
          click: () => {
            sendShortcutToFocusedWindow("preview-forward");
          },
        },
        {
          id: "cmux-preview-focus-address",
          visible: previewReloadMenuVisible,
          label: "Focus Address Bar",
          accelerator: "CommandOrControl+L",
          click: () => {
            sendShortcutToFocusedWindow("preview-focus-address");
          },
        },
        {
          label: "Reload Application",
          click: () => {
            const target = getActiveBrowserWindow();
            target?.webContents.reload();
          },
        },
        { type: "separator" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
        { role: "toggleDevTools" },
      ],
    };
    const historyMenu: MenuItemConstructorOptions = {
      label: "History",
      submenu: [
        {
          id: "cmux-history-back",
          label: "Back",
          accelerator: "CommandOrControl+[",
          enabled: false,
          click: () => {
            navigateHistory("back");
          },
        },
        {
          id: "cmux-history-forward",
          label: "Forward",
          accelerator: "CommandOrControl+]",
          enabled: false,
          click: () => {
            navigateHistory("forward");
          },
        },
      ],
    };
    template.push(
      { role: "editMenu" },
      historyMenu,
      {
        label: "Commands",
        submenu: [
          {
            label: "Command Palette…",
            accelerator: "CommandOrControl+K",
            click: () => {
              try {
                const target = getActiveBrowserWindow();
                keyDebug("menu-accelerator-cmdk", {
                  to: target?.webContents.id,
                });
                if (target && !target.isDestroyed()) {
                  target.webContents.send("cmux:event:shortcut:cmd-k");
                }
              } catch (err) {
                mainWarn("Failed to emit Cmd+K from menu accelerator", err);
                keyDebug("menu-accelerator-cmdk-error", { err: String(err) });
              }
            },
          },
        ],
      },
      viewMenu,
      { role: "windowMenu" }
    );
    template.push({
      role: "help",
      submenu: [
        {
          label: "Check for Updates…",
          click: async () => {
            if (!app.isPackaged) {
              await dialog.showMessageBox({
                type: "info",
                message: "Updates are only available in packaged builds.",
              });
              return;
            }
            try {
              mainLog("Manual update check initiated");
              const result = await autoUpdater.checkForUpdates();
              if (!result?.updateInfo) {
                await dialog.showMessageBox({
                  type: "info",
                  message: "You’re up to date.",
                });
              }
            } catch (e) {
              mainWarn("Manual checkForUpdates failed", e);
              await dialog.showMessageBox({
                type: "error",
                message: "Failed to check for updates.",
              });
            }
          },
        },
        {
          label: "Open Logs Folder",
          click: async () => {
            if (!logsDir) ensureLogFiles();
            if (logsDir) await shell.openPath(logsDir);
          },
        },
      ],
    });
    const menu = Menu.buildFromTemplate(template);
    previewReloadMenuItem =
      menu.getMenuItemById("cmux-preview-reload") ?? null;
    previewBackMenuItem =
      menu.getMenuItemById("cmux-preview-back") ?? null;
    previewForwardMenuItem =
      menu.getMenuItemById("cmux-preview-forward") ?? null;
    previewFocusAddressMenuItem =
      menu.getMenuItemById("cmux-preview-focus-address") ?? null;
    historyBackMenuItem = menu.getMenuItemById("cmux-history-back") ?? null;
    historyForwardMenuItem =
      menu.getMenuItemById("cmux-history-forward") ?? null;
    setPreviewReloadMenuVisibility(previewReloadMenuVisible);
    updateHistoryMenuState();
    Menu.setApplicationMenu(menu);
  } catch (e) {
    mainWarn("Failed to set application menu", e);
  }

  app.on("activate", function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

// Simple in-memory cache of RemoteJWKSet by issuer
const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

function jwksForIssuer(issuer: string) {
  const base = issuer.endsWith("/") ? issuer : issuer + "/";
  // Stack Auth exposes JWKS at <issuer>/.well-known/jwks.json
  const url = new URL(".well-known/jwks.json", base);
  let jwks = jwksCache.get(url.toString());
  if (!jwks) {
    jwks = createRemoteJWKSet(url);
    jwksCache.set(url.toString(), jwks);
  }
  return jwks;
}

async function verifyJwtAndGetPayload(
  token: string
): Promise<JWTPayload | null> {
  try {
    const decoded = decodeJwt(token);
    const iss = decoded.iss;
    if (!iss) return null;
    const JWKS = jwksForIssuer(iss);
    const { payload } = await jwtVerify(token, JWKS, { issuer: iss });
    return payload;
  } catch (error) {
    console.error("Failed to verify JWT and get payload", error);
    return null;
  }
}

async function handleProtocolUrl(url: string): Promise<void> {
  if (!mainWindow) {
    // Should not happen due to queuing, but guard anyway
    mainWarn("handleProtocolUrl called with no window; queueing", { url });
    pendingProtocolUrl = url;
    return;
  }

  const urlObj = new URL(url);

  if (urlObj.hostname === "auth-callback") {
    const rawStackRefresh = urlObj.searchParams.get("stack_refresh");
    const rawStackAccess = urlObj.searchParams.get("stack_access");

    if (!rawStackRefresh || !rawStackAccess) {
      mainWarn("Aborting cookie set due to missing tokens");
      return;
    }

    // Check for the full URL parameter
    const stackRefresh = encodeURIComponent(rawStackRefresh);
    const stackAccess = encodeURIComponent(rawStackAccess);

    // Verify tokens with Stack JWKS and extract exp for cookie expiry.
    const [refreshPayload, accessPayload] = await Promise.all([
      verifyJwtAndGetPayload(stackRefresh),
      verifyJwtAndGetPayload(stackAccess),
    ]);

    if (refreshPayload?.exp === null || accessPayload?.exp === null) {
      mainWarn("Aborting cookie set due to invalid tokens");
      return;
    }

    // Determine a cookieable URL. Prefer our custom cmux:// origin when not
    // running against an http(s) dev server.
    const currentUrl = new URL(mainWindow.webContents.getURL());
    currentUrl.hash = "";
    const realUrl = currentUrl.toString() + "/";

    await Promise.all([
      mainWindow.webContents.session.cookies.remove(
        realUrl,
        `stack-refresh-${env.NEXT_PUBLIC_STACK_PROJECT_ID}`
      ),
      mainWindow.webContents.session.cookies.remove(realUrl, `stack-access`),
    ]);

    await Promise.all([
      mainWindow.webContents.session.cookies.set({
        url: realUrl,
        name: `stack-refresh-${env.NEXT_PUBLIC_STACK_PROJECT_ID}`,
        value: stackRefresh,
        expirationDate: refreshPayload?.exp,
        sameSite: "no_restriction",
        secure: true,
      }),
      mainWindow.webContents.session.cookies.set({
        url: realUrl,
        name: "stack-access",
        value: stackAccess,
        expirationDate: accessPayload?.exp,
        sameSite: "no_restriction",
        secure: true,
      }),
    ]);

    mainWindow.webContents.reload();
    return;
  }

  if (urlObj.hostname === "github-connect-complete") {
    try {
      mainLog("Deep link: github-connect-complete", {
        team: urlObj.searchParams.get("team"),
      });
      // Bring app to front and refresh to pick up new connections
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
      const team = urlObj.searchParams.get("team");
      try {
        mainWindow.webContents.send("cmux:event:github-connect-complete", {
          team,
        });
      } catch (emitErr) {
        mainWarn("Failed to emit github-connect-complete", emitErr);
      }
    } catch (e) {
      mainWarn("Failed to handle github-connect-complete", e);
    }
    return;
  }
}
