import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import type { Socket } from "@cmux/shared/socket";
import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import { workerExec } from "./workerExec";

const execFileAsync = promisify(execFile);

export type EditorId = "vscode" | "cursor" | "windsurf";

interface EditorDef {
  id: EditorId;
  labels: string[];
  cliCandidates: string[];
  extDirs: string[];
}

interface FilePayload {
  sourcePath: string;
  content: string;
  mtimeMs?: number;
}

export interface SnippetPayload {
  filename: string;
  content: string;
}

export interface EditorSettingsSelection {
  id: EditorId;
  userDir: string;
  settings?: FilePayload;
  keybindings?: FilePayload;
  snippets: SnippetPayload[];
  extensions?: string[];
}

const homeDir = os.homedir();

function isMac(): boolean {
  return process.platform === "darwin";
}

function isWindows(): boolean {
  return process.platform === "win32";
}

function candidateUserDir(appFolderName: string): string {
  if (isMac()) {
    return path.join(homeDir, "Library", "Application Support", appFolderName, "User");
  }
  if (isWindows()) {
    const appData = process.env.APPDATA || path.join(homeDir, "AppData", "Roaming");
    return path.join(appData, appFolderName, "User");
  }
  return path.join(homeDir, ".config", appFolderName, "User");
}

function macAppBin(appName: string, bin: string): string {
  return path.join("/Applications", `${appName}.app`, "Contents", "Resources", "app", "bin", bin);
}

const EDITORS: EditorDef[] = [
  {
    id: "vscode",
    labels: ["Code", "Code - Insiders", "VSCodium"],
    cliCandidates: [
      "code",
      "code-insiders",
      "codium",
      macAppBin("Visual Studio Code", "code"),
      macAppBin("Visual Studio Code - Insiders", "code-insiders"),
      macAppBin("VSCodium", "codium"),
    ],
    extDirs: [
      path.join(homeDir, ".vscode", "extensions"),
      path.join(homeDir, ".vscode-insiders", "extensions"),
      path.join(homeDir, ".vscodium", "extensions"),
    ],
  },
  {
    id: "cursor",
    labels: ["Cursor"],
    cliCandidates: [
      "cursor",
      macAppBin("Cursor", "cursor"),
    ],
    extDirs: [path.join(homeDir, ".cursor", "extensions")],
  },
  {
    id: "windsurf",
    labels: ["Windsurf"],
    cliCandidates: [
      "windsurf",
      macAppBin("Windsurf", "windsurf"),
    ],
    extDirs: [path.join(homeDir, ".windsurf", "extensions")],
  },
];

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

async function readFilePayload(target: string, includeMtime = false): Promise<FilePayload | undefined> {
  try {
    const content = await fs.readFile(target, "utf8");
    const payload: FilePayload = { sourcePath: target, content };
    if (includeMtime) {
      const stat = await fs.stat(target);
      payload.mtimeMs = stat.mtimeMs;
    }
    return payload;
  } catch {
    return undefined;
  }
}

async function listSnippetPayloads(dir: string): Promise<SnippetPayload[]> {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const jsonFiles = entries.filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".json"));
    const snippets: SnippetPayload[] = [];
    for (const file of jsonFiles) {
      const absPath = path.join(dir, file.name);
      try {
        const content = await fs.readFile(absPath, "utf8");
        snippets.push({ filename: file.name, content });
      } catch {
        // ignore individual snippet failures
      }
    }
    return snippets;
  } catch {
    return [];
  }
}

async function runCliListExtensions(cliCandidates: string[]): Promise<string[] | undefined> {
  for (const cli of cliCandidates) {
    if (!cli) continue;
    try {
      const { stdout } = await execFileAsync(cli, ["--list-extensions", "--show-versions"], {
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
      });
      const lines = stdout
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      if (lines.length > 0) {
        return lines;
      }
    } catch {
      // try next candidate
    }
  }
  return undefined;
}

async function listExtensionsFromDirs(dirs: string[]): Promise<string[] | undefined> {
  const names = new Set<string>();
  for (const dir of dirs) {
    if (!(await pathExists(dir))) continue;
    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.isDirectory()) {
          const name = entry.name.trim();
          if (name && !name.startsWith(".")) names.add(name);
        }
      }
    } catch {
      // ignore
    }
  }
  if (names.size === 0) return undefined;
  return Array.from(names).sort();
}

async function resolveEditorSelection(def: EditorDef): Promise<EditorSettingsSelection | null> {
  for (const label of def.labels) {
    const candidateDir = candidateUserDir(label);
    if (!(await pathExists(candidateDir))) continue;

    const settingsPath = path.join(candidateDir, "settings.json");
    const keybindingsPath = path.join(candidateDir, "keybindings.json");
    const snippetsDir = path.join(candidateDir, "snippets");

    const [settings, keybindings] = await Promise.all([
      readFilePayload(settingsPath, true),
      readFilePayload(keybindingsPath),
    ]);
    const snippets = await listSnippetPayloads(snippetsDir);

    let extensions = await runCliListExtensions(def.cliCandidates);
    if (!extensions) {
      extensions = await listExtensionsFromDirs(def.extDirs);
    }

    return {
      id: def.id,
      userDir: candidateDir,
      settings,
      keybindings,
      snippets,
      extensions,
    };
  }
  return null;
}

export interface EditorDetectionResult {
  selection: EditorSettingsSelection | null;
  all: EditorSettingsSelection[];
}

export async function detectPreferredEditorSettings(): Promise<EditorDetectionResult> {
  const results: EditorSettingsSelection[] = [];
  for (const def of EDITORS) {
    const selection = await resolveEditorSelection(def);
    if (selection) {
      results.push(selection);
    }
  }

  if (results.length === 0) {
    return { selection: null, all: [] };
  }

  let best = results[0];
  for (const candidate of results.slice(1)) {
    const bestMtime = best.settings?.mtimeMs ?? -Infinity;
    const candidateMtime = candidate.settings?.mtimeMs ?? -Infinity;
    if (candidateMtime > bestMtime) {
      best = candidate;
    }
  }

  return { selection: best, all: results };
}

interface Logger {
  info(message: string, metadata?: Record<string, unknown>): void;
  warn(message: string, metadata?: Record<string, unknown>): void;
  error(message: string, metadata?: Record<string, unknown>): void;
}

export async function syncEditorSettingsToWorker(options: {
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>;
  logger: Logger;
  selection: EditorSettingsSelection;
}): Promise<void> {
  const { workerSocket, logger, selection } = options;

  const USER_DIR_REF = "${USER_DIR}";
  const SNIPPETS_DIR_REF = "${SNIPPETS_DIR}";

  const lines: string[] = [
    "set -euo pipefail",
    'BASE_DIR="${HOME}/.openvscode-server/data"',
    'USER_DIR="${BASE_DIR}/User"',
    'mkdir -p "${USER_DIR}"',
  ];

  if (selection.settings) {
    const base64 = Buffer.from(selection.settings.content, "utf8").toString("base64");
    lines.push(`echo '${base64}' | base64 --decode > "${USER_DIR_REF}/settings.json"`);
  }

  if (selection.keybindings) {
    const base64 = Buffer.from(selection.keybindings.content, "utf8").toString("base64");
    lines.push(`echo '${base64}' | base64 --decode > "${USER_DIR_REF}/keybindings.json"`);
  }

  if (selection.snippets.length > 0) {
    lines.push('SNIPPETS_DIR="${USER_DIR}/snippets"');
    lines.push('rm -rf "${SNIPPETS_DIR}"');
    lines.push('mkdir -p "${SNIPPETS_DIR}"');
    for (const snippet of selection.snippets) {
      const base64 = Buffer.from(snippet.content, "utf8").toString("base64");
      const safeName = snippet.filename.replace(/"/g, '\\"');
      lines.push(`echo '${base64}' | base64 --decode > "${SNIPPETS_DIR_REF}/${safeName}"`);
    }
  }

  const script = lines.join("\n");

  try {
    await workerExec({
      workerSocket,
      command: "bash",
      args: ["-lc", script],
      cwd: "/root",
      env: {},
      timeout: 30_000,
    });
    logger.info("Synced editor settings", {
      editor: selection.id,
      userDir: selection.userDir,
      settingsPath: selection.settings?.sourcePath,
      keybindingsPath: selection.keybindings?.sourcePath,
      snippetCount: selection.snippets.length,
    });
  } catch (error) {
    logger.warn("Failed to sync editor settings", {
      editor: selection.id,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
