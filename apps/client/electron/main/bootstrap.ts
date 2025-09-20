/*
  Bootstrap entry that installs crash/error handlers before loading the main
  Electron process code. This ensures errors thrown during module evaluation
  (which happen before the main module body runs) are captured and written to a
  log file in production builds.
*/

import { createHash } from "node:crypto";
import { appendFileSync } from "node:fs";
import { app } from "electron";

import { clearLogDirectory } from "./log-management/clear-log-directory";
import { resolveLogFilePath } from "./log-management/log-paths";

function timestamp(): string {
  return new Date().toISOString();
}

function logFilePath(name: string): string {
  return resolveLogFilePath(name);
}

function writeEmergencyLog(prefix: string, body: unknown): void {
  try {
    // Deterministic but unique(ish) filename per boot error burst
    const rand = createHash("sha1").update(String(process.hrtime.bigint())).digest("hex").slice(0, 8);
    const file = logFilePath(`${prefix}-${rand}.log`);
    const line = `[${timestamp()}] ${typeof body === "string" ? body : safeFormat(body)}\n`;
    appendFileSync(file, line, { encoding: "utf8" });
  } catch {
    // last‑ditch: swallow
  }
}

function safeFormat(v: unknown): string {
  try {
    if (v instanceof Error) return `${v.name}: ${v.message}\n${v.stack ?? ""}`;
    return JSON.stringify(v, null, 2);
  } catch {
    try {
      return String(v);
    } catch {
      return "<unserializable>";
    }
  }
}

clearLogDirectory();

// Install process‑level handlers as early as possible
// 1) Mirror console to main.log even before app.whenReady()
(() => {
  try {
    const file = logFilePath("main.log");
    const orig = {
      log: console.log.bind(console),
      warn: console.warn.bind(console),
      error: console.error.bind(console),
    } as const;
    const write = (level: "LOG" | "WARN" | "ERROR", args: unknown[]) => {
      try {
        const body = args.map((a) => safeFormat(a)).join(" ");
        appendFileSync(file, `[${timestamp()}] [MAIN] [${level}] ${body}\n`, {
          encoding: "utf8",
        });
      } catch {
        // ignore
      }
    };
    console.log = (...args: unknown[]) => {
      try {
        orig.log(...args);
      } finally {
        write("LOG", args);
      }
    };
    console.warn = (...args: unknown[]) => {
      try {
        orig.warn(...args);
      } finally {
        write("WARN", args);
      }
    };
    console.error = (...args: unknown[]) => {
      try {
        orig.error(...args);
      } finally {
        write("ERROR", args);
      }
    };
  } catch {
    // ignore
  }
})();

// 2) Fatal error capture
process.prependListener("uncaughtException", (err) => {
  writeEmergencyLog("fatal-uncaughtException", err);
});

process.prependListener("unhandledRejection", (reason) => {
  writeEmergencyLog("fatal-unhandledRejection", reason);
});

process.prependListener("warning", (warning) => {
  try {
    const file = logFilePath("main.log");
    appendFileSync(
      file,
      `[${timestamp()}] [MAIN] [WARN] Node warning: ${safeFormat(warning)}\n`,
      { encoding: "utf8" }
    );
  } catch {
    // ignore
  }
});

// Capture renderer/child crashes at the app level
try {
  app.on("child-process-gone", (_event, details) => {
    writeEmergencyLog("fatal-child-process-gone", details);
  });
  app.on("render-process-gone", (_event, _webContents, details) => {
    writeEmergencyLog("fatal-render-process-gone", details);
  });
} catch {
  // ignore if not supported
}

// Now load the real main process code; errors here will be caught by our
// handlers above and written to logs.
(async () => {
  try {
    await import("./index");
  } catch (e) {
    writeEmergencyLog("fatal-bootstrap-import", e);
    // Make sure the app terminates so the user isn't left hanging with no UI.
    try {
      app.exit(1);
    } catch {
      process.exit(1);
    }
  }
})();
