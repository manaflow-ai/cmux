import { exec } from "child_process";
import chokidar, { type FSWatcher } from "chokidar";
import { promisify } from "util";
import { serverLogger } from "./utils/fileLogger.js";

const execAsync = promisify(exec);

export class GitDiffManager {
  private watchers: Map<string, FSWatcher> = new Map();

  async getFullDiff(workspacePath: string): Promise<string> {
    try {
      // Run git diff with color to get all changes
      const { stdout, stderr } = await execAsync(
        "git diff --color=always origin/main",
        {
          cwd: workspacePath,
          maxBuffer: 10 * 1024 * 1024, // 10MB buffer for large diffs
          env: {
            ...process.env,
            FORCE_COLOR: "1",
            GIT_PAGER: "cat", // Disable pager
          },
        }
      );

      if (stderr) {
        serverLogger.error("Git diff stderr:", stderr);
      }

      return stdout || "";
    } catch (error) {
      serverLogger.error("Error getting git diff:", error);
      throw new Error("Failed to get git diff");
    }
  }

  watchWorkspace(
    workspacePath: string,
    onChange: (changedPath: string) => void
  ): void {
    if (this.watchers.has(workspacePath)) {
      return;
    }

    const watcher = chokidar.watch(workspacePath, {
      ignored: [
        "**/node_modules/**",
        "**/.git/objects/**",
        "**/.git/logs/**",
        "**/dist/**",
        "**/build/**",
      ],
      persistent: true,
      ignoreInitial: true,
      depth: 10,
    });

    watcher.on("change", (filePath) => {
      onChange(filePath);
    });

    watcher.on("add", (filePath) => {
      onChange(filePath);
    });

    watcher.on("unlink", (filePath) => {
      onChange(filePath);
    });

    this.watchers.set(workspacePath, watcher);
  }

  unwatchWorkspace(workspacePath: string): void {
    const watcher = this.watchers.get(workspacePath);
    if (watcher) {
      watcher.close();
      this.watchers.delete(workspacePath);
    }
  }

  dispose(): void {
    for (const watcher of this.watchers.values()) {
      watcher.close();
    }
    this.watchers.clear();
  }
}
