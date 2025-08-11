import { api } from "@cmux/convex/api";
import {
  GitFullDiffRequestSchema,
  GitHubFetchBranchesSchema,
  ListFilesRequestSchema,
  OpenInEditorSchema,
  StartTaskSchema,
  type ClientToServerEvents,
  type FileInfo,
  type InterServerEvents,
  type ServerToClientEvents,
  type SocketData,
} from "@cmux/shared";
import * as fuzzysort from "fuzzysort";
import { minimatch } from "minimatch";
import { exec, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import { createServer } from "node:http";
import * as path from "node:path";
import { promisify } from "node:util";
import { Server } from "socket.io";
import { spawnAllAgents } from "./agentSpawner.js";
import { execWithEnv } from "./execWithEnv.js";
import { GitDiffManager } from "./gitDiff.js";
import { createProxyApp, setupWebSocketProxy } from "./proxyApp.js";
import { RepositoryManager } from "./repositoryManager.js";
import { convex } from "./utils/convexClient.js";
import { dockerLogger, serverLogger } from "./utils/fileLogger.js";
import { checkAllProvidersStatus } from "./utils/providerStatus.js";
import {
  refreshBranchesForRepo,
  refreshGitHubData,
} from "./utils/refreshGitHubData.js";
import { waitForConvex } from "./utils/waitForConvex.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { getWorktreePath } from "./workspace.js";
import { evaluateCrownWithClaudeCode } from "./crownEvaluator.js";
import type { Id } from "@cmux/convex/dataModel";

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
  // Git diff manager instance
  const gitDiffManager = new GitDiffManager();

  // Create Express proxy app
  const proxyApp = createProxyApp({ publicPath });

  // Create HTTP server with Express app
  const httpServer = createServer(proxyApp);

  const io = new Server<
    ClientToServerEvents,
    ServerToClientEvents,
    InterServerEvents,
    SocketData
  >(httpServer, {
    cors: {
      origin: "http://localhost:5173",
      methods: ["GET", "POST"],
    },
    maxHttpBufferSize: 50 * 1024 * 1024, // 50MB to handle multiple images
    pingTimeout: 120000, // 120 seconds - match worker settings
    pingInterval: 30000, // 30 seconds - match worker settings  
    allowEIO3: true, // Allow different Socket.IO versions
  });

  setupWebSocketProxy(httpServer);

  io.on("connection", (socket) => {
    serverLogger.info("Client connected:", socket.id);

    // Send default repo info to newly connected client if available
    if (defaultRepo?.remoteName) {
      const defaultRepoData = {
        repoFullName: defaultRepo.remoteName,
        branch:
          defaultRepo.currentBranch || defaultRepo.defaultBranch || "main",
        localPath: defaultRepo.path,
      };
      serverLogger.info(
        `Sending default-repo to new client ${socket.id}:`,
        defaultRepoData
      );
      socket.emit("default-repo", defaultRepoData);
    }

    socket.on("start-task", async (data, callback) => {
      try {
        serverLogger.info("got data", data);
        const taskData = StartTaskSchema.parse(data);
        serverLogger.info("starting task!", taskData);

        // Use the taskId provided by the client
        const taskId = taskData.taskId;

        // Spawn all agents in parallel (each will create its own taskRun)
        const agentResults = await spawnAllAgents(taskId, {
          repoUrl: taskData.repoUrl,
          branch: taskData.branch,
          taskDescription: taskData.taskDescription,
          selectedAgents: taskData.selectedAgents,
          isCloudMode: taskData.isCloudMode,
          images: taskData.images,
          theme: taskData.theme,
        });

        // Check if at least one agent spawned successfully
        const successfulAgents = agentResults.filter(
          (result) => result.success
        );
        if (successfulAgents.length === 0) {
          callback({
            taskId: "error",
            error: "Failed to spawn any agents",
          });
          return;
        }

        // Log results for debugging
        agentResults.forEach((result) => {
          if (result.success) {
            serverLogger.info(
              `Successfully spawned ${result.agentName} with terminal ${result.terminalId}`
            );
            if (result.vscodeUrl) {
              serverLogger.info(
                `VSCode URL for ${result.agentName}: ${result.vscodeUrl}`
              );
            }
          } else {
            serverLogger.error(
              `Failed to spawn ${result.agentName}: ${result.error}`
            );
          }
        });

        // Return the first successful agent's info (you might want to modify this to return all)
        const primaryAgent = successfulAgents[0];

        // Emit VSCode URL if available
        if (primaryAgent.vscodeUrl) {
          io.emit("vscode-spawned", {
            instanceId: primaryAgent.terminalId,
            url: primaryAgent.vscodeUrl.replace("/?folder=/root/workspace", ""),
            workspaceUrl: primaryAgent.vscodeUrl,
            provider: taskData.isCloudMode ? "morph" : "docker",
          });
        }

        // Set up file watching for git changes
        gitDiffManager.watchWorkspace(
          primaryAgent.worktreePath,
          (changedPath) => {
            io.emit("git-file-changed", {
              workspacePath: primaryAgent.worktreePath,
              filePath: changedPath,
            });
          }
        );

        callback({
          taskId,
          worktreePath: primaryAgent.worktreePath,
          terminalId: primaryAgent.terminalId,
        });
      } catch (error) {
        serverLogger.error("Error in start-task:", error);
        callback({
          taskId: "error",
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Keep old handlers for backwards compatibility but they're not used anymore
    socket.on("git-status", async () => {
      socket.emit("git-status-response", {
        files: [],
        error: "Not implemented - use git-full-diff instead",
      });
    });

    socket.on("git-diff", async () => {
      socket.emit("git-diff-response", {
        path: "",
        diff: [],
        error: "Not implemented - use git-full-diff instead",
      });
    });

    socket.on("git-full-diff", async (data) => {
      try {
        const { workspacePath } = GitFullDiffRequestSchema.parse(data);
        const diff = await gitDiffManager.getFullDiff(workspacePath);
        socket.emit("git-full-diff-response", { diff });
      } catch (error) {
        serverLogger.error("Error getting full git diff:", error);
        socket.emit("git-full-diff-response", {
          diff: "",
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("open-in-editor", async (data, callback) => {
      try {
        const { editor, path } = OpenInEditorSchema.parse(data);

        let command: string[];
        switch (editor) {
          case "vscode":
            command = ["code", path];
            break;
          case "cursor":
            command = ["cursor", path];
            break;
          case "windsurf":
            command = ["windsurf", path];
            break;
          case "finder": {
            if (process.platform !== "darwin") {
              throw new Error("Finder is only supported on macOS");
            }
            // Use macOS 'open' to open the folder in Finder
            command = ["open", path];
            break;
          }
          default:
            throw new Error(`Unknown editor: ${editor}`);
        }

        console.log("command", command);

        const childProcess = spawn(command[0], command.slice(1));

        childProcess.on("close", (code) => {
          if (code === 0) {
            serverLogger.info(`Successfully opened ${path} in ${editor}`);
            // Send success callback
            if (callback) {
              callback({ success: true });
            }
          } else {
            serverLogger.error(
              `Error opening ${editor}: process exited with code ${code}`
            );
            const error = `Failed to open ${editor}: process exited with code ${code}`;
            socket.emit("open-in-editor-error", { error });
            // Send error callback
            if (callback) {
              callback({ success: false, error });
            }
          }
        });

        childProcess.on("error", (error) => {
          serverLogger.error(`Error opening ${editor}:`, error);
          const errorMessage = `Failed to open ${editor}: ${error.message}`;
          socket.emit("open-in-editor-error", { error: errorMessage });
          // Send error callback
          if (callback) {
            callback({ success: false, error: errorMessage });
          }
        });
      } catch (error) {
        serverLogger.error("Error opening editor:", error);
        const errorMessage =
          error instanceof Error ? error.message : "Unknown error";
        socket.emit("open-in-editor-error", { error: errorMessage });
        // Send error callback
        if (callback) {
          callback({ success: false, error: errorMessage });
        }
      }
    });

    socket.on("list-files", async (data) => {
      try {
        const { repoUrl, branch, pattern } = ListFilesRequestSchema.parse(data);

        // Get the origin path for this repository
        const worktreeInfo = await getWorktreePath({ repoUrl, branch });

        // Ensure directories exist
        await fs.mkdir(worktreeInfo.projectPath, { recursive: true });

        const repoManager = RepositoryManager.getInstance();

        // Ensure the repository is cloned/fetched with deduplication
        await repoManager.ensureRepository(
          repoUrl,
          worktreeInfo.originPath,
          branch || "main"
        );

        // Check if the origin directory exists
        try {
          await fs.access(worktreeInfo.originPath);
        } catch {
          serverLogger.error(
            "Origin directory does not exist:",
            worktreeInfo.originPath
          );
          socket.emit("list-files-response", {
            files: [],
            error: "Repository directory not found",
          });
          return;
        }

        const ignoredPatterns = [
          "**/node_modules/**",
          "**/.git/**",
          "**/dist/**",
          "**/build/**",
          "**/.next/**",
          "**/coverage/**",
          "**/.turbo/**",
          "**/.vscode/**",
          "**/.idea/**",
          "**/tmp/**",
          "**/.DS_Store",
          "**/npm-debug.log*",
          "**/yarn-debug.log*",
          "**/yarn-error.log*",
        ];

        async function walkDir(
          dir: string,
          baseDir: string
        ): Promise<FileInfo[]> {
          const files: FileInfo[] = [];

          try {
            const entries = await fs.readdir(dir, { withFileTypes: true });

            for (const entry of entries) {
              const fullPath = path.join(dir, entry.name);
              const relativePath = path.relative(baseDir, fullPath);

              // Check if path should be ignored
              const shouldIgnore = ignoredPatterns.some(
                (pattern) =>
                  minimatch(relativePath, pattern) ||
                  minimatch(fullPath, pattern)
              );

              if (shouldIgnore) continue;

              // Skip pattern matching here - we'll do fuzzy matching later
              // For directories, we still need to recurse to get all files
              if (entry.isDirectory() && !pattern) {
                // Only add directory if no pattern (for browsing)
                files.push({
                  path: fullPath,
                  name: entry.name,
                  isDirectory: true,
                  relativePath,
                });
              }

              if (entry.isDirectory()) {
                // Recurse into subdirectory
                const subFiles = await walkDir(fullPath, baseDir);
                files.push(...subFiles);
              } else {
                files.push({
                  path: fullPath,
                  name: entry.name,
                  isDirectory: false,
                  relativePath,
                });
              }
            }
          } catch (error) {
            serverLogger.error(`Error reading directory ${dir}:`, error);
          }

          return files;
        }

        // List files from the origin directory
        let fileList = await walkDir(
          worktreeInfo.originPath,
          worktreeInfo.originPath
        );

        // Apply fuzzysort fuzzy matching if pattern is provided
        if (pattern) {
          // Prepare file paths for fuzzysort
          const filePaths = fileList.map((f) => f.relativePath);

          // Use fuzzysort to search and sort files
          const results = fuzzysort.go(pattern, filePaths, {
            threshold: -10000, // Show all results, even poor matches
            limit: 1000, // Limit results for performance
          });

          // Create a map for quick lookup
          const fileMap = new Map(fileList.map((f) => [f.relativePath, f]));

          // Rebuild fileList based on fuzzysort results
          fileList = results
            .map((result) => fileMap.get(result.target)!)
            .filter(Boolean);

          // Add any files that didn't match at the end (if we want to show all files)
          // Uncomment if you want to show non-matching files at the bottom
          // const matchedPaths = new Set(results.map(r => r.target));
          // const unmatchedFiles = fileList.filter(f => !matchedPaths.has(f.relativePath));
          // fileList = [...fileList, ...unmatchedFiles];
        } else {
          // Only sort by directory/name when there's no search query
          fileList.sort((a, b) => {
            if (a.isDirectory && !b.isDirectory) return -1;
            if (!a.isDirectory && b.isDirectory) return 1;
            return a.relativePath.localeCompare(b.relativePath);
          });
        }

        socket.emit("list-files-response", { files: fileList });
      } catch (error) {
        serverLogger.error("Error listing files:", error);
        socket.emit("list-files-response", {
          files: [],
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("github-test-auth", async (callback) => {
      try {
        // Run all commands in parallel
        const [authStatus, whoami, home, ghConfig] = await Promise.all([
          execWithEnv("gh auth status")
            .then((r) => r.stdout)
            .catch((e) => e.message),
          execWithEnv("whoami").then((r) => r.stdout),
          execWithEnv("echo $HOME").then((r) => r.stdout),
          execWithEnv('ls -la ~/.config/gh/ || echo "No gh config"').then(
            (r) => r.stdout
          ),
        ]);

        callback({
          authStatus,
          whoami,
          home,
          ghConfig,
          processEnv: {
            HOME: process.env.HOME,
            USER: process.env.USER,
            GH_TOKEN: process.env.GH_TOKEN ? "Set" : "Not set",
            GITHUB_TOKEN: process.env.GITHUB_TOKEN ? "Set" : "Not set",
          },
        });
      } catch (error) {
        callback({
          error: error instanceof Error ? error.message : String(error),
          processEnv: {
            HOME: process.env.HOME,
            USER: process.env.USER,
            GH_TOKEN: process.env.GH_TOKEN ? "Set" : "Not set",
            GITHUB_TOKEN: process.env.GITHUB_TOKEN ? "Set" : "Not set",
          },
        });
      }
    });

    socket.on("github-fetch-repos", async (callback) => {
      try {
        // First, try to get existing repos from Convex
        const existingRepos = await convex.query(api.github.getAllRepos, {});

        if (existingRepos.length > 0) {
          // If we have repos, return them and refresh in the background
          const reposByOrg = await convex.query(api.github.getReposByOrg, {});
          callback({ success: true, repos: reposByOrg });

          // Refresh in the background to add any new repos
          refreshGitHubData().catch((error) => {
            serverLogger.error("Background refresh failed:", error);
          });
          return;
        }

        // If no repos exist, do a full fetch
        await refreshGitHubData();
        const reposByOrg = await convex.query(api.github.getReposByOrg, {});
        callback({ success: true, repos: reposByOrg });
      } catch (error) {
        serverLogger.error("Error fetching repos:", error);
        callback({
          success: false,
          error: `Failed to fetch GitHub repos: ${
            error instanceof Error ? error.message : String(error)
          }`,
        });
      }
    });

    socket.on("github-fetch-branches", async (data, callback) => {
      try {
        const { repo } = GitHubFetchBranchesSchema.parse(data);

        // Check if we already have branches for this repo
        const existingBranches = await convex.query(api.github.getBranches, {
          repo,
        });

        if (existingBranches.length > 0) {
          // Return existing branches and refresh in background
          callback({ success: true, branches: existingBranches });

          // Refresh in the background
          refreshBranchesForRepo(repo).catch((error) => {
            serverLogger.error("Background branch refresh failed:", error);
          });
          return;
        }

        // If no branches exist, fetch them
        const branches = await refreshBranchesForRepo(repo);
        callback({ success: true, branches });
      } catch (error) {
        serverLogger.error("Error fetching branches:", error);
        callback({
          success: false,
          error: `Failed to fetch branches: ${
            error instanceof Error ? error.message : String(error)
          }`,
        });
      }
    });

    socket.on("check-provider-status", async (callback) => {
      try {
        const status = await checkAllProvidersStatus();
        callback({ success: true, ...status });
      } catch (error) {
        serverLogger.error("Error checking provider status:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("disconnect", () => {
      serverLogger.info("Client disconnected:", socket.id);
      // No need to kill terminals on disconnect since they're global
    });
  });

  const server = httpServer.listen(port, async () => {
    serverLogger.info(`Terminal server listening on port ${port}`);
    serverLogger.info(`Visit http://localhost:${port} to see the app`);

    // Start the Docker container state sync
    await waitForConvex();
    DockerVSCodeInstance.startContainerStateSync();

    // Crown evaluation is now triggered immediately after all tasks complete
    // in agentSpawner.ts handleTaskCompletion() function
    // No need for periodic checking

    // Store default repo info if provided
    if (defaultRepo?.remoteName) {
      try {
        serverLogger.info(
          `Storing default repository: ${defaultRepo.remoteName}`
        );
        await convex.mutation(api.github.upsertRepo, {
          fullName: defaultRepo.remoteName,
          org: defaultRepo.remoteName.split("/")[0] || "",
          name: defaultRepo.remoteName.split("/")[1] || "",
          gitRemote: defaultRepo.remoteUrl || "",
          provider: "github", // Default to github, could be enhanced to detect provider
        });

        // Also emit to all connected clients
        const defaultRepoData = {
          repoFullName: defaultRepo.remoteName,
          branch:
            defaultRepo.currentBranch || defaultRepo.defaultBranch || "main",
          localPath: defaultRepo.path,
        };
        serverLogger.info(`Emitting default-repo event:`, defaultRepoData);
        io.emit("default-repo", defaultRepoData);

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

    // Refresh GitHub data on server start
    refreshGitHubData().catch((error) => {
      serverLogger.error("Error refreshing GitHub data on startup:", error);
    });
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

    isCleaningUp = true;
    serverLogger.info("Cleaning up terminals and server...");

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

    // Clean up crown evaluation interval

    // Clean up git diff manager
    gitDiffManager.dispose();

    // Close socket.io
    serverLogger.info("Closing socket.io server...");
    await new Promise<void>((resolve) => {
      io.close(() => {
        serverLogger.info("Socket.io server closed");
        resolve();
      });
    });

    // Close HTTP server only if it's still listening
    serverLogger.info("Closing HTTP server...");
    await new Promise<void>((resolve) => {
      if (server.listening) {
        server.close((error) => {
          if (error) {
            serverLogger.error("Error closing HTTP server:", error);
          } else {
            serverLogger.info("HTTP server closed");
          }
          resolve();
        });
      } else {
        serverLogger.info("HTTP server already closed");
        resolve();
      }
    });

    isCleanedUp = true;
    serverLogger.info("Cleanup completed");

    // Close logger instances to ensure all data is flushed
    serverLogger.close();
    dockerLogger.close();
  }

  // Hot reload support
  if (import.meta.hot) {
    import.meta.hot.dispose(cleanup);

    import.meta.hot.accept(() => {
      serverLogger.info("Hot reload triggered");
    });
  }

  return { cleanup };
}
