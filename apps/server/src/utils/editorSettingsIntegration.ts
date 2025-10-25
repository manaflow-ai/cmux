import { type AuthFile } from "@cmux/shared";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { serverLogger } from "./fileLogger";

const POSIX = path.posix;
const HOME_PLACEHOLDER = "$HOME";
const OPEN_VSCODE_BASE = POSIX.join(HOME_PLACEHOLDER, ".openvscode-server", "data");
const USER_DIR = POSIX.join(OPEN_VSCODE_BASE, "User");
const DEFAULT_PROFILE_DIR = POSIX.join(USER_DIR, "profiles", "default-profile");

export type EditorId = "vscode" | "cursor" | "windsurf";

interface EditorDef {
  id: EditorId;
  labels: string[];
}

interface SnippetExport {
  filename: string;
  content: string;
  mtimeMs: number | undefined;
}

interface EditorExport {
  id: EditorId;
  settingsContent?: string;
  keybindingsContent?: string;
  snippets: SnippetExport[];
  lastModifiedMs?: number;
  userDir: string;
}

export interface CollectEditorSettingsOptions {
  homeDir?: string;
  platform?: NodeJS.Platform;
}

interface CollectContext {
  homeDir: string;
  platform: NodeJS.Platform;
}

const EDITORS: EditorDef[] = [
  {
    id: "vscode",
    labels: ["Code", "Code - Insiders", "VSCodium"],
  },
  {
    id: "cursor",
    labels: ["Cursor"],
  },
  {
    id: "windsurf",
    labels: ["Windsurf"],
  },
];

function candidateUserDir(
  appFolderName: string,
  context: CollectContext
): string {
  const { homeDir, platform } = context;
  if (platform === "darwin") {
    return path.join(homeDir, "Library", "Application Support", appFolderName, "User");
  }
  if (platform === "win32") {
    const appData =
      process.env.APPDATA || path.join(homeDir, "AppData", "Roaming");
    return path.join(appData, appFolderName, "User");
  }
  return path.join(homeDir, ".config", appFolderName, "User");
}

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

async function readFileIfExists(target: string): Promise<{
  content: string;
  mtimeMs: number | undefined;
} | null> {
  try {
    const content = await fs.readFile(target, "utf8");
    const stat = await fs.stat(target);
    return { content, mtimeMs: stat.mtimeMs };
  } catch {
    return null;
  }
}

async function collectSnippetExports(snippetsDir: string): Promise<SnippetExport[]> {
  try {
    const entries = await fs.readdir(snippetsDir, { withFileTypes: true });
    const snippets: SnippetExport[] = [];
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.toLowerCase().endsWith(".json")) continue;
      const snippetPath = path.join(snippetsDir, entry.name);
      try {
        const content = await fs.readFile(snippetPath, "utf8");
        const stat = await fs.stat(snippetPath);
        snippets.push({
          filename: entry.name,
          content,
          mtimeMs: stat.mtimeMs,
        });
      } catch (error) {
        serverLogger.debug(
          `[EditorSettings] Failed to read snippet ${snippetPath}:`,
          error
        );
      }
    }
    return snippets;
  } catch {
    return [];
  }
}

function computeLastModified(
  parts: Array<number | undefined>
): number | undefined {
  const timestamps = parts.filter(
    (value): value is number => typeof value === "number" && !Number.isNaN(value)
  );
  if (timestamps.length === 0) return undefined;
  return Math.max(...timestamps);
}

async function collectEditorExport(
  def: EditorDef,
  context: CollectContext
): Promise<EditorExport | null> {
  let userDir: string | null = null;
  for (const label of def.labels) {
    const cand = candidateUserDir(label, context);
    if (await pathExists(cand)) {
      userDir = cand;
      break;
    }
  }

  if (!userDir) {
    return null;
  }

  const settingsPath = path.join(userDir, "settings.json");
  const keybindingsPath = path.join(userDir, "keybindings.json");
  const snippetsDir = path.join(userDir, "snippets");

  const settings = await readFileIfExists(settingsPath);
  const keybindings = await readFileIfExists(keybindingsPath);
  const snippets = await collectSnippetExports(snippetsDir);

  if (!settings && !keybindings && snippets.length === 0) {
    return null;
  }

  const lastModifiedMs = computeLastModified([
    settings?.mtimeMs,
    keybindings?.mtimeMs,
    ...snippets.map((snippet) => snippet.mtimeMs),
  ]);

  return {
    id: def.id,
    settingsContent: settings?.content,
    keybindingsContent: keybindings?.content,
    snippets,
    lastModifiedMs,
    userDir,
  };
}

function toAuthFile(destination: string, content: string): AuthFile {
  return {
    destinationPath: destination,
    contentBase64: Buffer.from(content, "utf8").toString("base64"),
    mode: "600",
  };
}

function selectPreferredEditor(exports: EditorExport[]): EditorExport | null {
  if (exports.length === 0) return null;
  const order: Record<EditorId, number> = { vscode: 0, cursor: 1, windsurf: 2 };

  return exports.reduce<EditorExport>((best, current) => {
    const bestTime = best.lastModifiedMs ?? -Infinity;
    const currentTime = current.lastModifiedMs ?? -Infinity;
    if (currentTime > bestTime) {
      return current;
    }
    if (currentTime === bestTime) {
      return order[current.id] < order[best.id] ? current : best;
    }
    return best;
  });
}

export async function collectPreferredEditorSettingsFiles(
  options: CollectEditorSettingsOptions = {}
): Promise<{ files: AuthFile[]; editorId?: EditorId }> {
  const context: CollectContext = {
    homeDir: options.homeDir ?? os.homedir(),
    platform: options.platform ?? process.platform,
  };

  const exports: EditorExport[] = [];
  for (const def of EDITORS) {
    try {
      const result = await collectEditorExport(def, context);
      if (result) {
        exports.push(result);
      }
    } catch (error) {
      serverLogger.debug(
        `[EditorSettings] Failed to collect settings for ${def.id}:`,
        error
      );
    }
  }

  if (exports.length === 0) {
    serverLogger.info("[EditorSettings] No editor settings detected on host");
    return { files: [], editorId: undefined };
  }

  const preferred = selectPreferredEditor(exports);
  if (!preferred) {
    serverLogger.info(
      "[EditorSettings] No preferred editor determined from collected settings"
    );
    return { files: [], editorId: undefined };
  }

  const files: AuthFile[] = [];

  if (preferred.settingsContent) {
    const destinations = [
      POSIX.join(USER_DIR, "settings.json"),
      POSIX.join(DEFAULT_PROFILE_DIR, "settings.json"),
    ];
    for (const destination of destinations) {
      files.push(toAuthFile(destination, preferred.settingsContent));
    }
  }

  if (preferred.keybindingsContent) {
    const destinations = [
      POSIX.join(USER_DIR, "keybindings.json"),
      POSIX.join(DEFAULT_PROFILE_DIR, "keybindings.json"),
    ];
    for (const destination of destinations) {
      files.push(toAuthFile(destination, preferred.keybindingsContent));
    }
  }

  for (const snippet of preferred.snippets) {
    files.push(
      toAuthFile(
        POSIX.join(USER_DIR, "snippets", snippet.filename),
        snippet.content
      )
    );
  }

  if (files.length > 0) {
    serverLogger.info(
      `[EditorSettings] Prepared ${files.length} file(s) from ${preferred.id} settings (${preferred.userDir})`
    );
  }

  return { files, editorId: preferred.id };
}
