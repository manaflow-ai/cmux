import path, { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
if (!globalThis.__dirname) {
  globalThis.__dirname = dirname(fileURLToPath(import.meta.url));
}

import { is } from "@electron-toolkit/utils";
import {
  app,
  BrowserWindow,
  dialog,
  nativeImage,
  net,
  session,
  shell,
  type BrowserWindowConstructorOptions,
} from "electron";
import { startEmbeddedServer } from "./embedded-server";
import { autoUpdater } from "electron-updater";
import type { Logger } from "builder-util-runtime";
import {
  createRemoteJWKSet,
  decodeJwt,
  jwtVerify,
  type JWTPayload,
} from "jose";
import { promises as fs } from "node:fs";

import util from "node:util";
import { env } from "./electron-main-env";

// Use a cookieable HTTPS origin intercepted locally instead of a custom scheme.
const PARTITION = "persist:cmux";
const APP_HOST = "cmux.local";

let rendererLoaded = false;
let pendingProtocolUrl: string | null = null;
let mainWindow: BrowserWindow | null = null;
let updaterInitialized = false;

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
  } catch {
    // ignore mirror failures
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

// Write critical errors to a file to aid debugging packaged crashes
async function writeFatalLog(...args: unknown[]) {
  try {
    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    const base = app.getPath("userData");
    const file = path.join(base, `fatal-${ts}.log`);
    const msg = formatArgs(args);
    await fs.writeFile(file, msg + "\n", { encoding: "utf8" });
  } catch {
    // ignore
  }
}

process.on("uncaughtException", (err) => {
  try {
    console.error("[MAIN] uncaughtException", err);
  } catch {
    // ignore
  }
  void writeFatalLog("uncaughtException", err);
});
process.on("unhandledRejection", (reason) => {
  try {
    console.error("[MAIN] unhandledRejection", reason);
  } catch {
    // ignore
  }
  void writeFatalLog("unhandledRejection", reason);
});

function setupAutoUpdates() {
  if (updaterInitialized) return; // guard against re-init on macOS activate
  updaterInitialized = true;

  if (!app.isPackaged) {
    mainLog("[updater] Skipping auto-updates in development");
    return;
  }

  try {
    const loggerProxy: Logger = {
      info: (...args: unknown[]) => mainLog("[updater]", ...args),
      warn: (...args: unknown[]) => mainWarn("[updater]", ...args),
      error: (...args: unknown[]) => mainError("[updater]", ...args),
      debug: (...args: unknown[]) => mainLog("[updater:debug]", ...args),
    };
    autoUpdater.logger = loggerProxy;

    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.allowPrerelease = process.env.CMUX_UPDATER_ALLOW_PRERELEASE === "true";

    // Allow explicit provider override via env for flexible hosting
    const channel = process.env.CMUX_UPDATER_CHANNEL || undefined; // e.g. "latest", "beta"
    const genericUrl = process.env.CMUX_UPDATER_URL || undefined; // e.g. https://updates.example.com/cmux
    const ghOwner = process.env.CMUX_UPDATER_GH_OWNER || undefined;
    const ghRepo = process.env.CMUX_UPDATER_GH_REPO || undefined;
    const ghHost = process.env.CMUX_UPDATER_GH_HOST || undefined; // optional enterprise host

    if (genericUrl) {
      mainLog("[updater] Using generic provider", { url: genericUrl, channel });
      autoUpdater.setFeedURL({ provider: "generic", url: genericUrl, channel });
    } else if (ghOwner && ghRepo) {
      mainLog("[updater] Using GitHub provider", { owner: ghOwner, repo: ghRepo, host: ghHost, channel });
      autoUpdater.setFeedURL({ provider: "github", owner: ghOwner, repo: ghRepo, host: ghHost, channel });
    } else {
      // Fallback: rely on electron-builder generated app-update.yml in resources
      mainLog("[updater] Using embedded app-update.yml (no explicit provider override)");
    }
  } catch (e) {
    mainWarn("[updater] Failed to initialize autoUpdater", e);
    return;
  }

  autoUpdater.on("checking-for-update", () => mainLog("[updater] Checking for update…"));
  autoUpdater.on("update-available", (info) => mainLog("[updater] Update available", info?.version));
  autoUpdater.on("update-not-available", () => mainLog("[updater] No updates available"));
  autoUpdater.on("error", (err) => mainWarn("[updater] Error", err));
  autoUpdater.on("download-progress", (p) =>
    mainLog(
      "[updater] Download progress",
      `${p.percent?.toFixed?.(1) ?? 0}% (${p.transferred}/${p.total})`
    )
  );
  autoUpdater.on("update-downloaded", async () => {
    try {
      const res = await dialog.showMessageBox(mainWindow ?? undefined, {
        type: "info",
        buttons: ["Restart Now", "Later"],
        defaultId: 0,
        cancelId: 1,
        message: "An update is ready to install.",
        detail: "Restart cmux to apply the latest version.",
      });
      if (res.response === 0) {
        mainLog("[updater] User accepted update; quitting and installing");
        autoUpdater.quitAndInstall();
      } else {
        mainLog("[updater] User deferred update installation");
      }
    } catch (e) {
      mainWarn("[updater] Failed to prompt for installing update", e);
      autoUpdater.quitAndInstall();
    }
  });

  // Initial check and periodic re-checks
  autoUpdater
    .checkForUpdatesAndNotify()
    .catch((e) => mainWarn("[updater] checkForUpdatesAndNotify failed", e));
  setInterval(() => {
    autoUpdater
      .checkForUpdates()
      .catch((e) => mainWarn("[updater] Periodic checkForUpdates failed", e));
  }, 30 * 60 * 1000); // every 30 minutes
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
      preload: join(__dirname, "../preload/index.cjs"),
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

  mainWindow.on("ready-to-show", () => {
    mainLog("Window ready-to-show");
    mainWindow?.show();
  });

  // Socket bridge not required; renderer connects directly

  // Enable cross-platform auto-updates when packaged
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
  });

  mainWindow.webContents.on("did-navigate", (_e, url) => {
    mainLog("did-navigate", { url });
  });

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url);
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

app.on("open-url", (_event, url) => {
  handleOrQueueProtocolUrl(url);
});

app.whenReady().then(async () => {
  // Ensure macOS menu and About panel use "cmux" instead of package.json name
  if (process.platform === "darwin") {
    try {
      app.setName("cmux");
      app.setAboutPanelOptions({ applicationName: "cmux" });
    } catch {
      // ignore if not supported
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

  const ses = session.fromPartition(PARTITION);
  // Intercept HTTPS for our private host and serve local files; pass-through others.
  ses.protocol.handle("https", async (req) => {
    mainLog("Protocol handler invoked", { url: req.url });
    const u = new URL(req.url);
    if (u.hostname !== APP_HOST) return net.fetch(req);
    const pathname = u.pathname === "/" ? "/index.html" : u.pathname;
    const fsPath = path.normalize(
      path.join(baseDir, decodeURIComponent(pathname))
    );
    const rel = path.relative(baseDir, fsPath);
    if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) {
      mainWarn("Blocked path outside baseDir", { fsPath, baseDir });
      return new Response("Not found", { status: 404 });
    }
    mainLog("Serving local file", { fsPath });
    return net.fetch(pathToFileURL(fsPath).toString());
  });

  // Create the initial window.
  if (BrowserWindow.getAllWindows().length === 0) createWindow();

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
  } catch {
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
  }
}
