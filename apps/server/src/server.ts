import { api } from "@cmux/convex/api";
import { exec, spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { promisify } from "node:util";
import { GitDiffManager } from "./gitDiff";

import { createProxyApp, setupWebSocketProxy } from "./proxyApp";
import { setupSocketHandlers } from "./socket-handlers";
import { createSocketIOTransport } from "./transports/socketio-transport";
import { getConvex } from "./utils/convexClient";
import { dockerLogger, serverLogger } from "./utils/fileLogger";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance";
import { VSCodeInstance } from "./vscode/VSCodeInstance";

const execAsync = promisify(exec);

export type GitRepoInfo = {
  path: string;
  isGitRepo: boolean;
  remoteName?: string;
  remoteUrl?: string;
  currentBranch?: string;
  defaultBranch?: string;
};

export async function startServer({
  port,
  publicPath,
  defaultRepo,
}: {
  port: number;
  publicPath: string;
  defaultRepo?: GitRepoInfo | null;
}) {
  // Set up global error handlers to prevent crashes
  process.on("unhandledRejection", (reason, promise) => {
    serverLogger.error("Unhandled Rejection at:", promise, "reason:", reason);
    // Don't exit the process - just log the error
  });

  process.on("uncaughtException", (error) => {
    serverLogger.error("Uncaught Exception:", error.message);
    // Don't exit for file system errors
    if (
      error &&
      typeof error === "object" &&
      "errno" in error &&
      "syscall" in error &&
      "path" in error
    ) {
      const fsError = error;
      if (fsError.errno === 0 || fsError.syscall === "TODO") {
        serverLogger.error(
          "File system watcher error - continuing without watching:",
          fsError.path
        );
        return;
      }
    }
    // For other critical errors, still exit
    process.exit(1);
  });

  // Check system limits and warn if too low
  try {
    const { stdout } = await execAsync("ulimit -n");
    const limit = parseInt(stdout.trim(), 10);
    if (limit < 8192) {
      serverLogger.warn(
        `System file descriptor limit is low: ${limit}. Consider increasing it with 'ulimit -n 8192' to avoid file watcher issues.`
      );
    }
  } catch (error) {
    serverLogger.warn("Could not check system file descriptor limit:", error);
  }

  // Git diff manager instance
  const gitDiffManager = new GitDiffManager();

  // Create Express proxy app
  const proxyApp = createProxyApp({ publicPath });

  // Create HTTP server with Express app
  const httpServer = createServer(proxyApp);

  setupWebSocketProxy(httpServer);

  // Create Socket.IO transport
  const rt = createSocketIOTransport(httpServer);

  // Set up all socket handlers
  setupSocketHandlers(rt, gitDiffManager, defaultRepo);

  async function isVSCodeInstalled() {
    const checkCommand = process.platform === "win32" ? "where code" : "command -v code";

    try {
      await execAsync(checkCommand);
      return true;
    } catch (_error) {
      serverLogger.info("VS Code CLI not found, skipping serve-web launch.");
      return false;
    }
  }

  async function isPortAvailable(checkPort: number) {
    return new Promise<boolean>((resolve) => {
      const tester = createNetServer();

      tester.once("error", (error) => {
        if (
          error &&
          typeof error === "object" &&
          "code" in error &&
          (error as NodeJS.ErrnoException).code === "EADDRINUSE"
        ) {
          serverLogger.warn(`Port ${checkPort} is already in use, skipping VS Code serve-web launch.`);
        } else {
          serverLogger.error(`Error while checking port ${checkPort}:`, error);
        }
        resolve(false);
      });

      tester.once("listening", () => {
        tester.close(() => resolve(true));
      });

      tester.listen(checkPort, "127.0.0.1");
    });
  }

  async function ensureVSCodeServeWeb() {
    const VSCODE_SERVE_PORT = 39384;

    const hasVSCode = await isVSCodeInstalled();
    if (!hasVSCode) {
      return;
    }

    const portAvailable = await isPortAvailable(VSCODE_SERVE_PORT);
    if (!portAvailable) {
      return;
    }

    try {
      const child = spawn(
        "code",
        [
          "serve-web",
          "--accept-server-license-terms",
          "--without-connection-token",
          "--port",
          String(VSCODE_SERVE_PORT),
        ],
        {
          detached: true,
          stdio: "ignore",
        }
      );

      child.on("error", (error) => {
        serverLogger.error("VS Code serve-web process error:", error);
      });

      child.unref();
      serverLogger.info(`Launched VS Code serve-web on port ${VSCODE_SERVE_PORT}.`);
    } catch (error) {
      serverLogger.error("Failed to launch VS Code serve-web:", error);
      return;
    }

    await warmUpVSCodeServeWeb(VSCODE_SERVE_PORT);
  }

  async function warmUpVSCodeServeWeb(portToWarm: number) {
    const warmupDeadline = Date.now() + 10_000;
    const endpoint = `http://127.0.0.1:${portToWarm}/`;

    while (Date.now() < warmupDeadline) {
      try {
        const response = await fetch(endpoint, { redirect: "manual" });
        if (response.status === 200) {
          serverLogger.info("VS Code serve-web warm-up succeeded.");
          return;
        }
      } catch (error) {
        serverLogger.debug?.("VS Code serve-web warm-up attempt failed:", error);
      }

      await new Promise<void>((resolve) => setTimeout(resolve, 500));
    }

    serverLogger.warn("VS Code serve-web did not respond with HTTP 200 during warm-up window.");
  }

  const server = httpServer.listen(port, async () => {
    serverLogger.info(`Terminal server listening on port ${port}`);
    serverLogger.info(`Visit http://localhost:${port} to see the app`);

    // Store default repo info if provided
    if (defaultRepo?.remoteName) {
      try {
        serverLogger.info(
          `Storing default repository: ${defaultRepo.remoteName}`
        );
        await getConvex().mutation(api.github.upsertRepo, {
          teamSlugOrId: "default",
          fullName: defaultRepo.remoteName,
          org: defaultRepo.remoteName.split("/")[0] || "",
          name: defaultRepo.remoteName.split("/")[1] || "",
          gitRemote: defaultRepo.remoteUrl || "",
          provider: "github", // Default to github, could be enhanced to detect provider
        });

        // Also emit to all connected clients
        const defaultRepoData = {
          repoFullName: defaultRepo.remoteName,
          branch: defaultRepo.currentBranch || defaultRepo.defaultBranch,
          localPath: defaultRepo.path,
        };
        serverLogger.info(`Emitting default-repo event:`, defaultRepoData);
        rt.emit("default-repo", defaultRepoData);

        serverLogger.info(
          `Successfully set default repository: ${defaultRepo.remoteName}`
        );
      } catch (error) {
        serverLogger.error("Error storing default repo:", error);
      }
    } else if (defaultRepo) {
      serverLogger.warn(
        `Default repo provided but no remote name found:`,
        defaultRepo
      );
    }

    await ensureVSCodeServeWeb();

    // Startup refresh moved to first authenticated socket connection
  });

  let isCleaningUp = false;
  let isCleanedUp = false;

  async function cleanup() {
    if (isCleaningUp || isCleanedUp) {
      serverLogger.info(
        "Cleanup already in progress or completed, skipping..."
      );
      return;
    }

    serverLogger.info("Closing HTTP server...");
    httpServer.close(() => {
      console.log("HTTP server closed");
    });

    isCleaningUp = true;
    serverLogger.info("Cleaning up terminals and server...");

    // Dispose of all file watchers
    serverLogger.info("Disposing file watchers...");
    gitDiffManager.dispose();

    // Stop Docker container state sync
    DockerVSCodeInstance.stopContainerStateSync();

    // Stop all VSCode instances using docker commands
    try {
      // Get all cmux containers
      const { stdout } = await execAsync(
        'docker ps -a --filter "name=cmux-" --format "{{.Names}}"'
      );
      const containerNames = stdout
        .trim()
        .split("\n")
        .filter((name) => name);

      if (containerNames.length > 0) {
        serverLogger.info(
          `Stopping ${containerNames.length} VSCode containers: ${containerNames.join(", ")}`
        );

        // Stop all containers in parallel with a single docker command
        exec(`docker stop ${containerNames.join(" ")}`, (error) => {
          if (error) {
            serverLogger.error("Error stopping containers:", error);
          } else {
            serverLogger.info("All containers stopped");
          }
        });

        // Don't wait for the command to finish
      } else {
        serverLogger.info("No VSCode containers found to stop");
      }
    } catch (error) {
      serverLogger.error(
        "Error stopping containers via docker command:",
        error
      );
    }

    VSCodeInstance.clearInstances();

    // Clean up git diff manager
    gitDiffManager.dispose();

    // Close the HTTP server
    serverLogger.info("Closing HTTP server...");
    await new Promise<void>((resolve) => {
      server.close(() => {
        serverLogger.info("HTTP server closed");
        resolve();
      });
    });

    isCleanedUp = true;
    serverLogger.info("Cleanup completed");

    // Close logger instances to ensure all data is flushed
    serverLogger.close();
    dockerLogger.close();
  }

  // Handle process termination signals
  process.on("SIGINT", async () => {
    serverLogger.info("Received SIGINT, shutting down gracefully...");
    await cleanup();
    process.exit(0);
  });

  process.on("SIGTERM", async () => {
    serverLogger.info("Received SIGTERM, shutting down gracefully...");
    await cleanup();
    process.exit(0);
  });

  // Hot reload support
  if (import.meta.hot) {
    import.meta.hot.dispose(cleanup);

    import.meta.hot.accept(() => {
      serverLogger.info("Hot reload triggered");
    });
  }

  return { cleanup };
}
