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

    try {
      const watcher = chokidar.watch(workspacePath, {
        ignored: [
          // Ignore all node_modules completely
          /node_modules/,
          // Ignore git internals
          /\.git\/objects/,
          /\.git\/logs/,
          /\.git\/refs/,
          /\.git\/hooks/,
          /\.git\/info/,
          /\.git\/index/,
          // Ignore build outputs
          /dist\//,
          /build\//,
          /\.next\//,
          /out\//,
          // Ignore cache directories
          /\.cache\//,
          /\.turbo\//,
          /\.parcel-cache\//,
          // Ignore temporary files
          /\.swp$/,
          /\.tmp$/,
          /~$/,
          // Ignore OS files
          /\.DS_Store$/,
          /Thumbs\.db$/,
          // Ignore IDE files
          /\.idea\//,
          /\.vscode\//,
          // Ignore lock files and logs
          /\.lock$/,
          /\.log$/,
        ],
        persistent: true,
        ignoreInitial: true,
        // Reduce depth to avoid deep traversal
        depth: 5,
        // Use polling as fallback if native watching fails
        usePolling: false,
        // Increase stability
        awaitWriteFinish: {
          stabilityThreshold: 500,
          pollInterval: 100,
        },
        // Prevent following symlinks to avoid loops
        followSymlinks: false,
        // Disable atomic writes handling
        atomic: false,
      });

      // Add error handling for the watcher
      watcher.on("error", (error) => {
        serverLogger.error("File watcher error:", error);
        // Don't crash, just log the error
      });

      watcher.on("ready", () => {
        serverLogger.info(`File watcher ready for ${workspacePath}`);
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
    } catch (error) {
      serverLogger.error("Failed to create file watcher:", error);
      // Don't throw - just log and continue without watching
    }
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
