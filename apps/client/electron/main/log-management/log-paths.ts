import { mkdirSync } from "node:fs";
import { join } from "node:path";
import os from "node:os";
import { app } from "electron";

export function getUserDataDirSafe(): string {
  try {
    return app.getPath("userData");
  } catch {
    return join(os.tmpdir(), "cmux-user-data");
  }
}

export function getLogDirectoryPath(): string {
  return join(getUserDataDirSafe(), "logs");
}

export function ensureLogDirectory(): string {
  const dir = getLogDirectoryPath();
  try {
    mkdirSync(dir, { recursive: true });
  } catch {
    // ignore failures creating the directory
  }
  return dir;
}

export function resolveLogFilePath(name: string): string {
  return join(ensureLogDirectory(), name);
}
