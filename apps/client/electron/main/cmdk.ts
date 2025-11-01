import path from "node:path";
import { createWriteStream, existsSync, mkdirSync, type WriteStream } from "node:fs";
import {
  app,
  BrowserWindow,
  ipcMain,
  webContents,
  webFrameMain,
  Menu,
} from "electron";
import type { MenuItemConstructorOptions } from "electron";

type Logger = {
  log: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
};

let keyDebugStream: WriteStream | null = null;

function getTimestamp(): string {
  return new Date().toISOString();
}

function ensureKeyDebugFile(logger: Logger): void {
  try {
    if (keyDebugStream) return;
    // Prefer repo logs/ during dev; fallback to userData/logs
    const appPath = app.getAppPath();
    let outDir: string;
    try {
      const maybeRoot = path.resolve(appPath, "../..");
      const repoLogs = path.join(maybeRoot, "logs");
      if (!existsSync(repoLogs)) mkdirSync(repoLogs, { recursive: true });
      outDir = repoLogs;
    } catch {
      const ud = path.join(app.getPath("userData"), "logs");
      if (!existsSync(ud)) mkdirSync(ud, { recursive: true });
      outDir = ud;
    }
    const filePath = path.join(outDir, "cmdk-debug.log");
    keyDebugStream = createWriteStream(filePath, { flags: "a", encoding: "utf8" });
    logger.log("CmdK debug log path:", filePath);
  } catch (e) {
    logger.warn("Failed to initialize CmdK debug log file", e);
  }
}

export function keyDebug(event: string, data?: unknown): void {
  try {
    const line = JSON.stringify({ ts: getTimestamp(), event, data });
    keyDebugStream?.write(line + "\n");
  } catch {
    // ignore
  }
}

// Track whether the Command Palette (Cmd+K) is currently open in any renderer
let cmdkOpen = false;

// Track the last captured focus location per BrowserWindow (by renderer webContents id)
const lastFocusByWindow = new Map<
  number,
  { contentsId: number; frameRoutingId: number; frameProcessId: number }
>();

let browserWindowFocusListenerRegistered = false;

type QueuedWindowTask = () => Promise<void> | void;
const pendingWindowTasks = new Map<number, QueuedWindowTask[]>();
const windowsWithTaskListeners = new WeakSet<BrowserWindow>();

function describeWindowFocus(win: BrowserWindow): {
  windowId: number;
  isDestroyed: boolean;
  isFocused: boolean;
  focusedWindowId: number | null;
  hasFocus: boolean;
} {
  const focused = BrowserWindow.getFocusedWindow();
  return {
    windowId: win.id,
    isDestroyed: win.isDestroyed(),
    isFocused: win.isFocused(),
    focusedWindowId: focused?.id ?? null,
    hasFocus: hasWindowFocus(win),
  };
}

function hasWindowFocus(win: BrowserWindow): boolean {
  if (win.isDestroyed()) return false;
  const focused = BrowserWindow.getFocusedWindow();
  if (!focused) return false;
  return focused.id === win.id && win.isFocused();
}

async function drainQueuedWindowTasks(win: BrowserWindow): Promise<void> {
  if (!hasWindowFocus(win)) {
    keyDebug("deferred-window-task-drain.skip-no-focus", describeWindowFocus(win));
    return;
  }

  const queue = pendingWindowTasks.get(win.id);
  if (!queue || queue.length === 0) {
    return;
  }

  keyDebug("deferred-window-task-drain.begin", {
    ...describeWindowFocus(win),
    queueLength: queue.length,
  });

  while (queue.length > 0) {
    if (!hasWindowFocus(win)) {
      keyDebug("deferred-window-task-drain.pause", {
        ...describeWindowFocus(win),
        remaining: queue.length,
      });
      return;
    }
    const task = queue.shift();
    if (!task) {
      continue;
    }
    try {
      await task();
    } catch (err) {
      keyDebug("deferred-window-task-error", {
        windowId: win.id,
        err: err instanceof Error ? err.message : String(err),
      });
    }
    keyDebug("deferred-window-task-drain.task-complete", {
      ...describeWindowFocus(win),
      remaining: queue.length,
    });
  }

  if (queue.length === 0) {
    pendingWindowTasks.delete(win.id);
  }

  keyDebug("deferred-window-task-drain.end", describeWindowFocus(win));
}

function ensureWindowTaskListeners(win: BrowserWindow): void {
  if (windowsWithTaskListeners.has(win)) {
    return;
  }

  const handleFocus = () => {
    keyDebug("browser-window.focus", describeWindowFocus(win));
    void drainQueuedWindowTasks(win);
  };

  const handleBlur = () => {
    keyDebug("browser-window.blur", describeWindowFocus(win));
  };

  const handleClosed = () => {
    win.removeListener("focus", handleFocus);
    win.removeListener("blur", handleBlur);
    win.removeListener("closed", handleClosed);
    pendingWindowTasks.delete(win.id);
    windowsWithTaskListeners.delete(win);
  };

  win.on("focus", handleFocus);
  win.on("blur", handleBlur);
  win.on("closed", handleClosed);
  windowsWithTaskListeners.add(win);
}

function enqueueWindowTask(
  win: BrowserWindow,
  task: QueuedWindowTask,
  debugEvent: string,
  debugData: Record<string, unknown> = {},
): void {
  if (win.isDestroyed()) {
    return;
  }

  ensureWindowTaskListeners(win);
  const queue = pendingWindowTasks.get(win.id) ?? [];
  queue.push(task);
  pendingWindowTasks.set(win.id, queue);

  keyDebug(`${debugEvent}.deferred`, {
    ...describeWindowFocus(win),
    queueLength: queue.length,
    ...debugData,
  });

  // Attempt to drain soon in case the window already regained focus.
  queueMicrotask(() => {
    if (!win.isDestroyed()) {
      void drainQueuedWindowTasks(win);
    }
  });
}

export function initCmdK(opts: {
  getMainWindow: () => BrowserWindow | null;
  logger: Logger;
}): void {
  ensureKeyDebugFile(opts.logger);
  if (!browserWindowFocusListenerRegistered) {
    app.on("browser-window-focus", (_event, win) => {
      if (win) {
        keyDebug("app.browser-window-focus", describeWindowFocus(win));
        void drainQueuedWindowTasks(win);
      }
    });
    browserWindowFocusListenerRegistered = true;
  }

  // Attach to all webContents including webviews and subframes
  app.on("web-contents-created", (_event, contents) => {
    try {
      keyDebug("web-contents-created", {
        id: contents.id,
        type: contents.getType?.(),
        url: contents.getURL?.(),
      });
    } catch {
      // ignore debug log failures
    }

    try {
      contents.on("before-input-event", (e, input) => {
        keyDebug("before-input-event", {
          id: contents.id,
          type: contents.getType?.(),
          key: input.key,
          code: input.code,
          meta: input.meta,
          ctrl: input.control,
          alt: input.alt,
          shift: input.shift,
          typeInput: input.type,
        });
        if (input.type !== "keyDown") return;
        const isMac = process.platform === "darwin";
        // Only trigger on EXACT Cmd+K (mac) or Ctrl+K (others)
        const isCmdK = (() => {
          if (input.key.toLowerCase() !== "k") return false;
          if (input.alt || input.shift) return false;
          if (isMac) {
            // Require meta only; disallow ctrl on mac
            return Boolean(input.meta) && !input.control;
          }
          // Non-mac: require ctrl only; disallow meta
          return Boolean(input.control) && !input.meta;
        })();

        const isSidebarToggle = (() => {
          if (input.key.toLowerCase() !== "s") return false;
          if (!input.shift) return false;
          if (input.alt || input.meta) return false;
          // Require control to align with renderer shortcut (Ctrl+Shift+S)
          return Boolean(input.control);
        })();

        if (!isCmdK && !isSidebarToggle) return;

        // Prevent default to avoid in-app conflicts and ensure single toggle
        e.preventDefault();

        const getTargetWindow = (): BrowserWindow | null => {
          return (
            BrowserWindow.getFocusedWindow() ??
            opts.getMainWindow() ??
            BrowserWindow.getAllWindows()[0] ??
            null
          );
        };

        if (isSidebarToggle) {
          keyDebug("sidebar-toggle-detected", {
            sourceId: contents.id,
            type: contents.getType?.(),
          });
          const targetWin = getTargetWindow();
          if (targetWin && !targetWin.isDestroyed()) {
            try {
              targetWin.webContents.send("cmux:event:shortcut:sidebar-toggle");
              keyDebug("emit-sidebar-toggle", {
                to: targetWin.webContents.id,
                from: contents.id,
              });
            } catch (err) {
              opts.logger.warn("Failed to emit sidebar toggle shortcut", err);
              keyDebug("emit-sidebar-toggle-error", { err: String(err) });
            }
          }
          return;
        }

        keyDebug("cmdk-detected", {
          sourceId: contents.id,
          type: contents.getType?.(),
        });

        // If already open, just toggle; do not overwrite previous capture
        if (cmdkOpen) {
          keyDebug("skip-capture-already-open", { id: contents.id });
          const targetWin = getTargetWindow();
          if (targetWin && !targetWin.isDestroyed()) {
            try {
              targetWin.webContents.send("cmux:event:shortcut:cmd-k");
              keyDebug("emit-cmdk", {
                to: targetWin.webContents.id,
                from: contents.id,
              });
            } catch (err) {
              opts.logger.warn("Failed to emit Cmd+K (already open)", err);
              keyDebug("emit-cmdk-error", { err: String(err) });
            }
          }
          return;
        }

        // Capture the currently focused element BEFORE emitting toggle
        try {
          const frame = contents.focusedFrame ?? contents.mainFrame;
          frame
            .executeJavaScript(
              `(() => { try {
                const el = document.activeElement;
                // Store for restore + debugging
                window.__cmuxLastFocused = el;
                // @ts-ignore
                window.__cmuxLastFocusedTag = el?.tagName ?? null;
                return window.__cmuxLastFocusedTag || true;
              } catch { return false } })()`,
              true
            )
            .then((res) => {
              keyDebug("capture-last-focused", {
                id: contents.id,
                res,
                frameRoutingId: frame.routingId,
                frameProcessId: frame.processId,
                frameUrl: frame.url,
                frameOrigin: frame.origin,
              });
              const targetWin = getTargetWindow();
              if (targetWin && !targetWin.isDestroyed()) {
                try {
                  lastFocusByWindow.set(targetWin.webContents.id, {
                    contentsId: contents.id,
                    frameRoutingId: frame.routingId,
                    frameProcessId: frame.processId,
                  });
                  keyDebug("remember-last-focus", {
                    windowId: targetWin.webContents.id,
                    contentsId: contents.id,
                    frameRoutingId: frame.routingId,
                    frameProcessId: frame.processId,
                  });
                } catch {
                  // ignore
                }
                try {
                  targetWin.webContents.send("cmux:event:shortcut:cmd-k", {
                    sourceContentsId: contents.id,
                    sourceFrameRoutingId: frame.routingId,
                    sourceFrameProcessId: frame.processId,
                  });
                  keyDebug("emit-cmdk", {
                    to: targetWin.webContents.id,
                    from: contents.id,
                    frameRoutingId: frame.routingId,
                    frameProcessId: frame.processId,
                  });
                } catch (err) {
                  opts.logger.warn(
                    "Failed to emit Cmd+K from before-input-event",
                    err
                  );
                  keyDebug("emit-cmdk-error", { err: String(err) });
                }
              }
            })
            .catch((err) =>
              keyDebug("capture-last-focused-error", {
                id: contents.id,
                err: String(err),
              })
            );
        } catch {
          // ignore capture failures
        }
      });
    } catch {
      // ignore
    }
  });

  // IPC helpers
  ipcMain.handle("cmux:ui:focus-webcontents", (_evt, id: number) => {
    try {
      const wc = webContents.fromId(id);
      if (!wc || wc.isDestroyed()) {
        return { ok: false };
      }

      const owningWindow = BrowserWindow.fromWebContents(wc);
      if (!owningWindow || owningWindow.isDestroyed()) {
        return { ok: false };
      }

      const queueFocus = (attempt = 0): void => {
        enqueueWindowTask(
          owningWindow,
          async () => {
            if (!hasWindowFocus(owningWindow)) {
              keyDebug("focus-webcontents.deferred-waiting", {
                id,
                attempt,
                ...describeWindowFocus(owningWindow),
              });
              queueFocus(attempt + 1);
              return;
            }
            const target = webContents.fromId(id);
            if (!target || target.isDestroyed()) {
              keyDebug("focus-webcontents.deferred-missing", { id, attempt });
              return;
            }
            try {
              keyDebug("focus-webcontents.deferred-run", {
                id,
                attempt,
                ...describeWindowFocus(owningWindow),
              });
              target.focus();
              keyDebug("focus-webcontents.deferred-success", {
                id,
                attempt,
                ...describeWindowFocus(owningWindow),
              });
            } catch (error) {
              keyDebug("focus-webcontents.deferred-error", {
                id,
                attempt,
                err: error instanceof Error ? error.message : String(error),
              });
            }
          },
          "focus-webcontents",
          { id, attempt },
        );
      };

      // Skip refocusing if the owning window isn't the active window. This avoids
      // bringing CMUX back to the front while the user is interacting with another app.
      if (!hasWindowFocus(owningWindow)) {
        keyDebug("focus-webcontents.defer-immediate", {
          id,
          ...describeWindowFocus(owningWindow),
        });
        queueFocus();
        return { ok: false, queued: true };
      }

      wc.focus();
      keyDebug("focus-webcontents", {
        id,
        immediate: true,
        ...describeWindowFocus(owningWindow),
      });
      return { ok: true };
    } catch (err) {
      keyDebug("focus-webcontents-error", { id, err: String(err) });
      return { ok: false };
    }
  });

  ipcMain.handle(
    "cmux:ui:webcontents-restore-last-focus",
    async (_evt, id: number) => {
      try {
        const wc = webContents.fromId(id);
        if (!wc || wc.isDestroyed()) return { ok: false };
        const owningWindow = BrowserWindow.fromWebContents(wc);
        if (!owningWindow || owningWindow.isDestroyed()) return { ok: false };

        const performRestore = async (attempt: number): Promise<void> => {
          if (!hasWindowFocus(owningWindow)) {
            keyDebug("restore-last-focus.deferred-waiting", {
              id,
              attempt,
              ...describeWindowFocus(owningWindow),
            });
            queueRestore(attempt + 1);
            return;
          }
          const target = webContents.fromId(id);
          if (!target || target.isDestroyed()) {
            keyDebug("restore-last-focus.deferred-missing", { id, attempt });
            return;
          }
          try {
            target.focus();
          } catch {
            // ignore focus failures; we'll still attempt to restore element focus
          }
          keyDebug("restore-last-focus.begin", {
            id,
            deferred: true,
            attempt,
            ...describeWindowFocus(owningWindow),
          });
          const ok = await target.executeJavaScript(
            `(() => {
              try {
                const el = window.__cmuxLastFocused;
                if (el && typeof el.focus === 'function') {
                  el.focus();
                  if (el.tagName === 'IFRAME') {
                    try { el.contentWindow && el.contentWindow.focus && el.contentWindow.focus(); } catch {}
                  }
                  return true;
                }
                const a = document.activeElement;
                if (a && typeof a.focus === 'function') { a.focus(); return true; }
                if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
                return false;
              } catch { return false; }
            })()`,
            true,
          );
          keyDebug("restore-last-focus.result", {
            id,
            ok,
            deferred: true,
            attempt,
            ...describeWindowFocus(owningWindow),
          });
        };

        const queueRestore = (attempt = 0): void => {
          enqueueWindowTask(
            owningWindow,
            () => performRestore(attempt),
            "restore-last-focus",
            { id, attempt },
          );
        };

        if (!hasWindowFocus(owningWindow)) {
          keyDebug("restore-last-focus.defer-immediate", {
            id,
            ...describeWindowFocus(owningWindow),
          });
          queueRestore();
          return { ok: false, queued: true };
        }

        await wc.focus();
        keyDebug("restore-last-focus.begin", {
          id,
          deferred: false,
          ...describeWindowFocus(owningWindow),
        });
        const ok = await wc.executeJavaScript(
          `(() => {
            try {
              const el = window.__cmuxLastFocused;
              if (el && typeof el.focus === 'function') {
                el.focus();
                if (el.tagName === 'IFRAME') {
                  try { el.contentWindow && el.contentWindow.focus && el.contentWindow.focus(); } catch {}
                }
                return true;
              }
              const a = document.activeElement;
              if (a && typeof a.focus === 'function') { a.focus(); return true; }
              if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
            return false;
          } catch { return false; }
        })()`,
          true,
        );
        keyDebug("restore-last-focus.result", {
          id,
          ok,
          deferred: false,
          ...describeWindowFocus(owningWindow),
        });
        return { ok: Boolean(ok) };
      } catch (err) {
        keyDebug("restore-last-focus.error", { id, err: String(err) });
        return { ok: false };
      }
    }
  );

  ipcMain.handle(
    "cmux:ui:frame-restore-last-focus",
    async (
      _evt,
      info: { contentsId: number; frameRoutingId: number; frameProcessId: number }
    ) => {
      try {
        const wc = webContents.fromId(info.contentsId);
        if (!wc || wc.isDestroyed()) return { ok: false };
        const frame = webFrameMain.fromId(info.frameProcessId, info.frameRoutingId);
        if (!frame) {
          keyDebug("frame-restore-last-focus.no-frame", info);
          return { ok: false };
        }
        const owningWindow = BrowserWindow.fromWebContents(wc);
        if (!owningWindow || owningWindow.isDestroyed()) return { ok: false };

        const performRestore = async (attempt: number): Promise<void> => {
          if (!hasWindowFocus(owningWindow)) {
            keyDebug("frame-restore-last-focus.deferred-waiting", {
              ...info,
              attempt,
              ...describeWindowFocus(owningWindow),
            });
            queueRestore(attempt + 1);
            return;
          }
          const targetWc = webContents.fromId(info.contentsId);
          if (!targetWc || targetWc.isDestroyed()) {
            keyDebug("frame-restore-last-focus.deferred-missing", {
              ...info,
              attempt,
            });
            return;
          }
          const targetFrame = webFrameMain.fromId(
            info.frameProcessId,
            info.frameRoutingId,
          );
          if (!targetFrame) {
            keyDebug("frame-restore-last-focus.deferred-no-frame", {
              ...info,
              attempt,
            });
            return;
          }
          try {
            targetWc.focus();
          } catch {
            // ignore focus failures; we'll still attempt to restore element focus
          }
          if (!hasWindowFocus(owningWindow)) {
            queueRestore(attempt + 1);
            return;
          }
          keyDebug("frame-restore-last-focus.begin", {
            ...info,
            deferred: true,
            attempt,
            ...describeWindowFocus(owningWindow),
          });
          const ok = await targetFrame.executeJavaScript(
            `(() => {
              try {
                const el = window.__cmuxLastFocused;
                if (el && typeof el.focus === 'function') { el.focus(); return true; }
                const a = document.activeElement;
                if (a && typeof a.focus === 'function') { a.focus(); return true; }
                if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
                return false;
              } catch { return false; }
            })()`,
            true,
          );
          keyDebug("frame-restore-last-focus.result", {
            ...info,
            ok,
            deferred: true,
            attempt,
            ...describeWindowFocus(owningWindow),
          });
        };

        const queueRestore = (attempt = 0): void => {
          enqueueWindowTask(
            owningWindow,
            () => performRestore(attempt),
            "frame-restore-last-focus",
            { ...info, attempt },
          );
        };

        if (!hasWindowFocus(owningWindow)) {
          keyDebug("frame-restore-last-focus.defer-immediate", {
            ...info,
            ...describeWindowFocus(owningWindow),
          });
          queueRestore();
          return { ok: false, queued: true };
        }

        await wc.focus();
        keyDebug("frame-restore-last-focus.begin", {
          ...info,
          deferred: false,
          ...describeWindowFocus(owningWindow),
        });
        const ok = await frame.executeJavaScript(
          `(() => {
            try {
              const el = window.__cmuxLastFocused;
              if (el && typeof el.focus === 'function') { el.focus(); return true; }
              const a = document.activeElement;
              if (a && typeof a.focus === 'function') { a.focus(); return true; }
              if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
            return false;
          } catch { return false; }
        })()`,
          true,
        );
        keyDebug("frame-restore-last-focus.result", {
          ...info,
          ok,
          deferred: false,
          ...describeWindowFocus(owningWindow),
        });
        return { ok: Boolean(ok) };
      } catch (err) {
        keyDebug("frame-restore-last-focus.error", { ...info, err: String(err) });
        return { ok: false };
      }
    }
  );

  ipcMain.handle(
    "cmux:ui:show-edit-context-menu",
    (evt, position?: { x?: number; y?: number }) => {
      try {
        const senderWindow = BrowserWindow.fromWebContents(evt.sender);
        if (!senderWindow || senderWindow.isDestroyed()) {
          return { ok: false };
        }

        const template: MenuItemConstructorOptions[] = [
          { role: "undo" },
          { role: "redo" },
          { type: "separator" },
          { role: "cut" },
          { role: "copy" },
          { role: "paste" },
        ];

        if (process.platform === "darwin") {
          template.push({ role: "pasteAndMatchStyle" });
        }

        template.push({ role: "delete" });
        template.push({ type: "separator" });
        template.push({ role: "selectAll" });

        if (process.platform === "darwin") {
          template.push({ type: "separator" });
          template.push({
            label: "Speech",
            submenu: [{ role: "startSpeaking" }, { role: "stopSpeaking" }],
          });
        }

        const menu = Menu.buildFromTemplate(template);
        const popupX = typeof position?.x === "number" ? Math.round(position.x) : undefined;
        const popupY = typeof position?.y === "number" ? Math.round(position.y) : undefined;

        menu.popup({
          window: senderWindow,
          x: popupX,
          y: popupY,
          positioningItem: 0,
        });

        return { ok: true };
      } catch (error) {
        opts.logger.warn("Failed to show edit context menu", error);
        return { ok: false };
      }
    },
  );

  // Renderer reports when Command Palette opens/closes so we don't
  // overwrite previously captured focus while it's open.
  ipcMain.handle("cmux:ui:set-command-palette-open", (_evt, isOpen: boolean) => {
    try {
      cmdkOpen = Boolean(isOpen);
      keyDebug("cmdk-open-state", { open: cmdkOpen });
      return { ok: true };
    } catch (err) {
      keyDebug("cmdk-open-state-error", { err: String(err) });
      return { ok: false };
    }
  });

  // Simple restore using stored last focus info for this window
  ipcMain.handle("cmux:ui:restore-last-focus", async (evt) => {
    try {
      const windowWcId = evt.sender.id;
      const info = lastFocusByWindow.get(windowWcId);
      keyDebug("window-restore-last-focus.begin", { windowWcId, info });
      if (!info) return { ok: false };
      const wc = webContents.fromId(info.contentsId);
      if (!wc || wc.isDestroyed()) return { ok: false };
      const frame = webFrameMain.fromId(info.frameProcessId, info.frameRoutingId);
      if (!frame) return { ok: false };
      const owningWindow = BrowserWindow.fromWebContents(wc);
      if (!owningWindow || owningWindow.isDestroyed()) return { ok: false };

      const performRestore = async (attempt: number): Promise<void> => {
        if (!hasWindowFocus(owningWindow)) {
          keyDebug("window-restore-last-focus.deferred-waiting", {
            windowWcId,
            ...info,
            attempt,
            ...describeWindowFocus(owningWindow),
          });
          queueRestore(attempt + 1);
          return;
        }
        const targetWc = webContents.fromId(info.contentsId);
        if (!targetWc || targetWc.isDestroyed()) {
          keyDebug("window-restore-last-focus.deferred-missing", {
            windowWcId,
            ...info,
            attempt,
          });
          return;
        }
        const targetFrame = webFrameMain.fromId(
          info.frameProcessId,
          info.frameRoutingId,
        );
        if (!targetFrame) {
          keyDebug("window-restore-last-focus.deferred-no-frame", {
            windowWcId,
            ...info,
            attempt,
          });
          return;
        }
        try {
          targetWc.focus();
        } catch {
          // ignore focus failures; we'll still attempt to restore element focus
        }
        if (!hasWindowFocus(owningWindow)) {
          queueRestore(attempt + 1);
          return;
        }
        keyDebug("window-restore-last-focus.begin", {
          windowWcId,
          deferred: true,
          attempt,
          ...info,
          ...describeWindowFocus(owningWindow),
        });
        const ok = await targetFrame.executeJavaScript(
          `(() => {
            try {
              const el = window.__cmuxLastFocused;
              if (el && typeof el.focus === 'function') { el.focus(); return true; }
              const a = document.activeElement;
              if (a && typeof a.focus === 'function') { a.focus(); return true; }
              if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
              return false;
            } catch { return false; }
          })()`,
          true,
        );
        keyDebug("window-restore-last-focus.result", {
          windowWcId,
          ok,
          deferred: true,
          attempt,
          ...info,
          ...describeWindowFocus(owningWindow),
        });
      };

      const queueRestore = (attempt = 0): void => {
        enqueueWindowTask(
          owningWindow,
          () => performRestore(attempt),
          "window-restore-last-focus",
          { windowWcId, ...info, attempt },
        );
      };

      if (!hasWindowFocus(owningWindow)) {
        keyDebug("window-restore-last-focus.defer-immediate", {
          windowWcId,
          ...info,
          ...describeWindowFocus(owningWindow),
        });
        queueRestore();
        return { ok: false, queued: true };
      }

      await wc.focus();
      keyDebug("window-restore-last-focus.begin", {
        windowWcId,
        deferred: false,
        ...info,
        ...describeWindowFocus(owningWindow),
      });
      const ok = await frame.executeJavaScript(
        `(() => {
          try {
            const el = window.__cmuxLastFocused;
            if (el && typeof el.focus === 'function') { el.focus(); return true; }
            const a = document.activeElement;
            if (a && typeof a.focus === 'function') { a.focus(); return true; }
            if (document.body && typeof document.body.focus === 'function') { document.body.focus(); return true; }
            return false;
          } catch { return false; }
        })()`,
        true,
      );
      keyDebug("window-restore-last-focus.result", {
        windowWcId,
        ok,
        deferred: false,
        ...info,
        ...describeWindowFocus(owningWindow),
      });
      return { ok: Boolean(ok) };
    } catch (err) {
      keyDebug("window-restore-last-focus.error", { err: String(err) });
      return { ok: false };
    }
  });
}
