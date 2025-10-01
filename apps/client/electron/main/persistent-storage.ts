import { app } from "electron";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

type StorageRecord = Record<string, string>;

const STORAGE_FILE_NAME = "cmux-storage.json";

let cache: StorageRecord | null = null;
let storageFilePath: string | null = null;

function resolveStorageFilePath(): string {
  if (storageFilePath) return storageFilePath;
  const userData = app.getPath("userData");
  const filePath = join(userData, STORAGE_FILE_NAME);
  const dirPath = dirname(filePath);
  if (!existsSync(dirPath)) {
    mkdirSync(dirPath, { recursive: true });
  }
  storageFilePath = filePath;
  return storageFilePath;
}

function loadFromDisk(): StorageRecord {
  if (cache) return cache;

  try {
    const filePath = resolveStorageFilePath();
    if (!existsSync(filePath)) {
      cache = {};
      return cache;
    }

    const raw = readFileSync(filePath, { encoding: "utf8" });
    if (!raw) {
      cache = {};
      return cache;
    }

    const parsed = JSON.parse(raw) as unknown;
    if (parsed && typeof parsed === "object") {
      cache = Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>).filter(
          ([, value]) => typeof value === "string"
        )
      );
      return cache;
    }
  } catch (error) {
    console.error("Failed to load persistent storage", error);
  }

  cache = {};
  return cache;
}

function persist(): void {
  if (!cache) return;
  try {
    const filePath = resolveStorageFilePath();
    writeFileSync(filePath, JSON.stringify(cache, null, 2), {
      encoding: "utf8",
    });
  } catch (error) {
    console.error("Failed to persist storage", error);
  }
}

export function getPersistentItem(key: string): string | null {
  const store = loadFromDisk();
  return Object.prototype.hasOwnProperty.call(store, key) ? store[key]! : null;
}

export function setPersistentItem(key: string, value: string): void {
  const store = loadFromDisk();
  store[key] = value;
  persist();
}

export function removePersistentItem(key: string): void {
  const store = loadFromDisk();
  if (Object.prototype.hasOwnProperty.call(store, key)) {
    delete store[key];
    persist();
  }
}
