import { app, BrowserWindow, shell, ipcMain } from "electron";
import { autoUpdater } from "electron-updater";
import { join } from "node:path";
import __cjs_mod__ from "node:module";
const __filename = import.meta.filename;
const __dirname = import.meta.dirname;
const require2 = __cjs_mod__.createRequire(import.meta.url);
const is = {
  dev: !app.isPackaged
};
({
  isWindows: process.platform === "win32",
  isMacOS: process.platform === "darwin",
  isLinux: process.platform === "linux"
});
function createWindow() {
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
      nodeIntegration: false
    }
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
  if (!is.dev) {
    setupAutoUpdates(mainWindow);
  }
}
app.whenReady().then(() => {
  createWindow();
  app.on("activate", function() {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});
app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
function setupAutoUpdates(win) {
  const feedUrl = process.env.CMUX_ELECTRON_UPDATE_URL || process.env.ELECTRON_UPDATE_URL;
  if (feedUrl) {
    try {
      autoUpdater.setFeedURL({ provider: "generic", url: feedUrl });
    } catch (err) {
      console.error("Failed to set feed URL:", err);
    }
  }
  autoUpdater.autoDownload = true;
  autoUpdater.allowDowngrade = false;
  const send = (payload) => {
    try {
      win.webContents.send("cmux:auto-update", payload);
    } catch (err) {
      console.error("Failed to send auto-update payload:", err);
    }
  };
  autoUpdater.on("checking-for-update", () => {
    send({ status: "checking" });
  });
  autoUpdater.on("update-available", (info) => {
    const rn = info?.releaseNotes ?? null;
    send({
      status: "available",
      info: { version: info?.version ?? null, releaseNotes: rn }
    });
  });
  autoUpdater.on("update-not-available", (info) => {
    const safe = info;
    send({
      status: "not-available",
      info: {
        version: safe?.version ?? null,
        releaseNotes: safe?.releaseNotes ?? null
      }
    });
  });
  autoUpdater.on("error", (error) => {
    const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    send({ status: "error", message });
  });
  autoUpdater.on("download-progress", (progress) => {
    send({
      status: "download-progress",
      progress: {
        percent: progress.percent,
        transferred: progress.transferred,
        total: progress.total,
        bytesPerSecond: progress.bytesPerSecond
      }
    });
  });
  autoUpdater.on("update-downloaded", (info) => {
    const rn = info?.releaseNotes ?? null;
    send({
      status: "downloaded",
      info: { version: info?.version ?? null, releaseNotes: rn }
    });
  });
  ipcMain.handle("cmux:install-update", async () => {
    try {
      autoUpdater.quitAndInstall();
    } catch (err) {
      const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      send({ status: "error", message });
    }
  });
  ipcMain.handle("cmux:check-for-updates", async () => {
    try {
      await autoUpdater.checkForUpdates();
    } catch (err) {
      const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      send({ status: "error", message });
    }
  });
  autoUpdater.checkForUpdates().catch((err) => {
    const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    send({ status: "error", message });
  });
}
