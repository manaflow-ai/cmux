import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

export interface LocalVSCodeData {
  settings?: unknown;
  keybindings?: unknown;
  snippets?: Record<string, unknown>;
  extensions?: string[];
}

function safeReadJson(filePath: string): unknown | undefined {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    if (!content.trim()) return undefined;
    return JSON.parse(content);
  } catch {
    return undefined;
  }
}

function collectSnippets(dir: string): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith(".json")) continue;
      const full = path.join(dir, entry.name);
      const parsed = safeReadJson(full);
      if (parsed !== undefined) {
        result[entry.name] = parsed;
      }
    }
  } catch {
    // ignore missing snippets directory
  }
  return result;
}

function listExtensionsFromCli(): string[] | null {
  try {
    const res = spawnSync("code", ["--list-extensions"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (res.status === 0 && res.stdout) {
      return res.stdout
        .split(/\r?\n/)
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
    }
  } catch {
    // CLI not available
  }
  return null;
}

function listExtensionsFromDir(dir: string): string[] {
  const out = new Set<string>();
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      // Folders typically look like publisher.name-version
      const name = entry.name;
      const hyphen = name.lastIndexOf("-");
      const base = hyphen > 0 ? name.slice(0, hyphen) : name;
      if (base.includes(".")) out.add(base);
    }
  } catch {
    // ignore if not present
  }
  return [...out];
}

function resolveUserDir(): string | null {
  const home = process.env.HOME || process.env.USERPROFILE;
  if (!home) return null;
  // macOS
  const mac = path.join(home, "Library", "Application Support", "Code", "User");
  if (fs.existsSync(mac)) return mac;
  // Linux
  const linux = path.join(home, ".config", "Code", "User");
  if (fs.existsSync(linux)) return linux;
  // Windows (APPDATA)
  const appData = process.env.APPDATA;
  if (appData) {
    const win = path.join(appData, "Code", "User");
    if (fs.existsSync(win)) return win;
  }
  return null;
}

function resolveExtensionsDir(): string[] {
  const dirs: string[] = [];
  const home = process.env.HOME || process.env.USERPROFILE || "";
  if (home) {
    // Common locations
    dirs.push(path.join(home, ".vscode", "extensions"));
    const appData = process.env.APPDATA;
    if (appData) dirs.push(path.join(appData, "Code", "extensions"));
  }
  return dirs;
}

export function readLocalVSCodeData(): LocalVSCodeData | null {
  const userDir = resolveUserDir();
  if (!userDir) return null;

  const settings = safeReadJson(path.join(userDir, "settings.json"));
  const keybindings = safeReadJson(path.join(userDir, "keybindings.json"));
  const snippets = collectSnippets(path.join(userDir, "snippets"));

  // Prefer CLI for extensions
  let extensions: string[] | null = listExtensionsFromCli();
  if (!extensions || extensions.length === 0) {
    // Fallback to directories
    const candidates = resolveExtensionsDir();
    const collected = new Set<string>();
    for (const dir of candidates) {
      for (const ext of listExtensionsFromDir(dir)) collected.add(ext);
    }
    extensions = [...collected];
  }

  return {
    settings,
    keybindings,
    snippets,
    extensions: extensions && extensions.length > 0 ? extensions : undefined,
  };
}

