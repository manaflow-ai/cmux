import { is } from "@electron-toolkit/utils";
import { app, BrowserWindow, ipcMain, shell } from "electron";
import { autoUpdater } from "electron-updater";
import { join } from "node:path";
import type { AutoUpdateEvent } from "../../src/types/preload";

function createWindow(): void {
  const mainWindow = new BrowserWindow({
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
    },
  });

  mainWindow.on("ready-to-show", () => {
    mainWindow.show();
  });

  mainWindow.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url);
    return { action: "deny" };
  });

  if (is.dev && process.env["ELECTRON_RENDERER_URL"]) {
    mainWindow.loadURL(process.env["ELECTRON_RENDERER_URL"]);
  } else {
    mainWindow.loadFile(join(__dirname, "../renderer/index.html"));
  }

  // Set up auto updates only in packaged apps
  if (!is.dev) {
    setupAutoUpdates(mainWindow);
  }
}

app.whenReady().then(() => {
  createWindow();

  app.on("activate", function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

function setupAutoUpdates(win: BrowserWindow): void {
  // Allow overriding feed URL via env for generic providers
  const feedUrl =
    process.env.CMUX_ELECTRON_UPDATE_URL || process.env.ELECTRON_UPDATE_URL;
  if (feedUrl) {
    try {
      // Generic provider expects hosting of artifacts + latest.yml
      autoUpdater.setFeedURL({ provider: "generic", url: feedUrl });
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error("Failed to set feed URL:", err);
    }
  }

  autoUpdater.autoDownload = true;
  autoUpdater.allowDowngrade = false;

  const send = (payload: AutoUpdateEvent) => {
    try {
      win.webContents.send("cmux:auto-update", payload);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error("Failed to send auto-update payload:", err);
    }
  };

  autoUpdater.on("checking-for-update", () => {
    send({ status: "checking" });
  });

  autoUpdater.on("update-available", (info) => {
    const rn =
      (info as unknown as { releaseNotes?: string | null })?.releaseNotes ??
      null;
    send({
      status: "available",
      info: { version: info?.version ?? null, releaseNotes: rn },
    });
  });

  autoUpdater.on("update-not-available", (info) => {
    const safe = info as unknown as {
      version?: string | null;
      releaseNotes?: string | null;
    };
    send({
      status: "not-available",
      info: {
        version: safe?.version ?? null,
        releaseNotes: safe?.releaseNotes ?? null,
      },
    });
  });

  autoUpdater.on("error", (error) => {
    // Some error objects are not serializable; stringify safely
    const message =
      error instanceof Error
        ? `${error.name}: ${error.message}`
        : String(error);
    send({ status: "error", message });
  });

  autoUpdater.on("download-progress", (progress) => {
    send({
      status: "download-progress",
      progress: {
        percent: progress.percent,
        transferred: progress.transferred,
        total: progress.total,
        bytesPerSecond: progress.bytesPerSecond,
      },
    });
  });

  autoUpdater.on("update-downloaded", (info) => {
    const rn =
      (info as unknown as { releaseNotes?: string | null })?.releaseNotes ??
      null;
    send({
      status: "downloaded",
      info: { version: info?.version ?? null, releaseNotes: rn },
    });
  });

  ipcMain.handle("cmux:install-update", async () => {
    try {
      autoUpdater.quitAndInstall();
    } catch (err) {
      const message =
        err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      send({ status: "error", message });
    }
  });

  ipcMain.handle("cmux:check-for-updates", async () => {
    try {
      await autoUpdater.checkForUpdates();
    } catch (err) {
      const message =
        err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      send({ status: "error", message });
    }
  });

  // Trigger initial check
  autoUpdater.checkForUpdates().catch((err) => {
    const message =
      err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    send({ status: "error", message });
  });
}
