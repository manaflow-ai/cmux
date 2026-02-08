import { exec } from "node:child_process";
import { promises as fs, watch, type FSWatcher } from "node:fs";
import * as path from "node:path";
import { promisify } from "node:util";
import { log } from "./logger";
import { detectGitRepoPath } from "./crown/git";

const execAsync = promisify(exec);

const MAX_FILE_CONTENT_BYTES = 256 * 1024; // 256KB
const MAX_GIT_SHOW_BYTES = 256 * 1024; // 256KB
const MAX_PATCH_BYTES = 512 * 1024; // 512KB
const MAX_GIT_DIFF_BYTES = 1 * 1024 * 1024; // 1MB

function extractExecStdout(error: unknown): string {
  if (!error || typeof error !== "object") {
    return "";
  }
  const stdout = (error as { stdout?: unknown }).stdout;
  if (typeof stdout === "string") {
    return stdout;
  }
  if (stdout instanceof Buffer) {
    return stdout.toString("utf-8");
  }
  return "";
}

async function readFileLimited(
  filePath: string,
  maxBytes: number
): Promise<string> {
  try {
    const handle = await fs.open(filePath, "r");
    try {
      const stats = await handle.stat();
      const toRead = Math.min(stats.size, maxBytes);
      if (toRead <= 0) {
        return "";
      }
      const buffer = Buffer.alloc(toRead);
      const { bytesRead } = await handle.read(buffer, 0, toRead, 0);
      return buffer.slice(0, bytesRead).toString("utf-8");
    } finally {
      await handle.close();
    }
  } catch {
    return "";
  }
}

interface FileChange {
  type: "added" | "modified" | "deleted";
  path: string;
  timestamp: number;
}

interface FileWatcherOptions {
  watchPath: string;
  taskRunId?: string;
  onFileChange: (changes: FileChange[]) => void;
  debounceMs?: number;
  gitIgnore?: boolean;
}

export class FileWatcher {
  private watcher: FSWatcher | null = null;
  private watchPath: string;
  private gitRepoPath: string | null = null;
  private taskRunId?: string;
  private onFileChange: (changes: FileChange[]) => void;
  private debounceMs: number;
  private gitIgnore: boolean;
  private pendingChanges: Map<string, FileChange> = new Map();
  private debounceTimer: NodeJS.Timeout | null = null;
  private lastGitStatus: Map<string, string> = new Map();
  private gitIgnorePatterns: string[] = [];

  constructor(options: FileWatcherOptions) {
    this.watchPath = options.watchPath;
    this.taskRunId = options.taskRunId;
    this.onFileChange = options.onFileChange;
    this.debounceMs = options.debounceMs || 1000; // Default 1 second debounce
    this.gitIgnore = options.gitIgnore ?? true;
  }


  async start(): Promise<void> {
    this.gitRepoPath = await detectGitRepoPath();

    // Load gitignore patterns if enabled
    if (this.gitIgnore) {
      await this.loadGitIgnorePatterns();
    }

    // Get initial git status
    await this.updateGitStatus();

    // Start watching; use recursive only on platforms that support it (macOS/Windows)
    const supportsRecursive =
      process.platform === "darwin" || process.platform === "win32";
    this.watcher = watch(
      this.watchPath,
      supportsRecursive ? { recursive: true } : undefined,
      this.handleFileChange.bind(this)
    );
  }

  stop(): void {
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
    }

    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
  }

  private async loadGitIgnorePatterns(): Promise<void> {
    const searchPath = this.gitRepoPath || this.watchPath;

    try {
      const gitIgnorePath = path.join(searchPath, ".gitignore");
      const gitIgnoreContent = await fs.readFile(gitIgnorePath, "utf-8");

      this.gitIgnorePatterns = gitIgnoreContent
        .split("\n")
        .filter((line) => line.trim() && !line.startsWith("#"))
        .map((pattern) => pattern.trim());

      // Always ignore .git directory
      this.gitIgnorePatterns.push(".git");
    } catch (error) {
      // No gitignore file, just ignore .git
      this.gitIgnorePatterns = [".git"];
    }
  }

  private shouldIgnore(filePath: string): boolean {
    if (!this.gitIgnore) return false;

    const relativePath = path.relative(this.watchPath, filePath);

    // Check against gitignore patterns (simplified check)
    for (const pattern of this.gitIgnorePatterns) {
      if (relativePath.includes(pattern)) {
        return true;
      }
    }

    // Ignore common build/temp directories
    const ignoreDirs = [
      "node_modules",
      ".git",
      "dist",
      "build",
      ".next",
      ".cache",
    ];
    for (const dir of ignoreDirs) {
      if (relativePath.includes(dir)) {
        return true;
      }
    }

    return false;
  }

  private async updateGitStatus(): Promise<void> {
    if (!this.gitRepoPath) {
      throw new Error("gitRepoPath cannot be found");
    }

    try {
      const { stdout } = await execAsync("git status --porcelain", {
        cwd: this.gitRepoPath,
      });

      this.lastGitStatus.clear();

      const lines = stdout.split("\n").filter((line) => line.trim());
      for (const line of lines) {
        const status = line.substring(0, 2).trim();
        const filePath = line.substring(3).trim();
        if (filePath) {
          this.lastGitStatus.set(filePath, status);
        }
      }
    } catch (error) {
      log("WARN", `[FileWatcher] Failed to update git status:`, error);
    }
  }

  private async handleFileChange(
    _eventType: string,
    filename: string | null
  ): Promise<void> {
    if (!filename) return;

    const fullPath = path.join(this.watchPath, filename);

    // Ignore if should be ignored
    if (this.shouldIgnore(fullPath)) {
      return;
    }

    // Determine change type
    let changeType: FileChange["type"] = "modified";

    try {
      const stats = await fs.stat(fullPath);
      if (!stats.isFile()) return; // Ignore directories

      // Check if file is new (relative to git repo if available, else watchPath)
      const basePath = this.gitRepoPath || this.watchPath;
      const relativePath = path.relative(basePath, fullPath);
      const gitStatus = this.lastGitStatus.get(relativePath);

      if (gitStatus === "??" || gitStatus?.startsWith("A")) {
        changeType = "added";
      }
    } catch (error) {
      // File doesn't exist, it was deleted
      changeType = "deleted";
    }

    // Add to pending changes
    const change: FileChange = {
      type: changeType,
      path: fullPath,
      timestamp: Date.now(),
    };

    this.pendingChanges.set(fullPath, change);

    // Reset debounce timer
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }

    // Set new debounce timer
    this.debounceTimer = setTimeout(() => {
      this.flushPendingChanges();
    }, this.debounceMs);
  }

  private async flushPendingChanges(): Promise<void> {
    if (this.pendingChanges.size === 0) return;

    const changes = Array.from(this.pendingChanges.values());
    this.pendingChanges.clear();

    // Update git status after changes
    await this.updateGitStatus();

    // Emit changes
    this.onFileChange(changes);
  }
}

/**
 * Compute git diff for specific files
 */
export async function computeGitDiff(
  worktreePath: string,
  files?: string[]
): Promise<string> {
  const gitRepoPath = await detectGitRepoPath();
  if (!gitRepoPath) {
    throw new Error("gitRepoPath cannot not be found");
  }

  try {
    let command = "git diff HEAD";

    // Add specific files if provided
    if (files && files.length > 0) {
      const relativePaths = files.map((f) => path.relative(gitRepoPath, f));
      command += ` -- ${relativePaths.join(" ")}`;
    }

    const { stdout } = await execAsync(command, {
      cwd: gitRepoPath,
      maxBuffer: MAX_GIT_DIFF_BYTES,
    });

    return stdout;
  } catch (error) {
    const fallback = extractExecStdout(error);
    if (fallback) {
      log(
        "WARN",
        "[FileWatcher] Git diff output truncated due to size limit"
      );
      return fallback;
    }
    log("ERROR", `[FileWatcher] Failed to compute git diff:`, error);
    return "";
  }
}

/**
 * Get file content with proper line-by-line diff
 */
export async function getFileWithDiff(
  filePath: string,
  worktreePath: string
): Promise<{ oldContent: string; newContent: string; patch: string }> {
  const gitRepoPath = await detectGitRepoPath();
  if (!gitRepoPath) {
    throw new Error("gitRepoPath cannot be found");
  }

  try {
    const relativePath = path.relative(gitRepoPath, filePath);

    // Get current content
    const newContent = await readFileLimited(filePath, MAX_FILE_CONTENT_BYTES);

    // Get old content from git
    let oldContent = "";
    try {
      const { stdout } = await execAsync(`git show HEAD:"${relativePath}"`, {
        cwd: gitRepoPath,
        maxBuffer: MAX_GIT_SHOW_BYTES,
      });
      oldContent = stdout;
    } catch (error) {
      oldContent = extractExecStdout(error);
    }

    // Get patch
    let patch = "";
    try {
      const { stdout } = await execAsync(`git diff HEAD -- "${relativePath}"`, {
        cwd: gitRepoPath,
        maxBuffer: MAX_PATCH_BYTES,
      });
      patch = stdout;
    } catch (error) {
      patch = extractExecStdout(error);
    }

    return { oldContent, newContent, patch };
  } catch (error) {
    log(
      "ERROR",
      `[FileWatcher] Failed to get file diff for ${filePath}:`,
      error
    );
    return { oldContent: "", newContent: "", patch: "" };
  }
}
