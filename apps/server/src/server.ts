import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import {
  GitFullDiffRequestSchema,
  GitHubCreateDraftPrSchema,
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
import fuzzysort from "fuzzysort";
import { minimatch } from "minimatch";
import { exec, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import { createServer } from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { Server } from "socket.io";
import { spawnAllAgents } from "./agentSpawner.js";
import { execWithEnv } from "./execWithEnv.js";
import { GitDiffManager } from "./gitDiff.js";
import { createProxyApp, setupWebSocketProxy } from "./proxyApp.js";
import { refreshDiffsForTaskRun } from "./refreshDiffs.js";
import { RepositoryManager } from "./repositoryManager.js";
import { getPRTitleFromTaskDescription } from "./utils/branchNameGenerator.js";
import { convex } from "./utils/convexClient.js";
import { ensureRunWorktreeAndBranch } from "./utils/ensureRunWorktree.js";
import { dockerLogger, serverLogger } from "./utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken.js";
import { checkAllProvidersStatus } from "./utils/providerStatus.js";
import {
  refreshBranchesForRepo,
  refreshGitHubData,
} from "./utils/refreshGitHubData.js";
import { waitForConvex } from "./utils/waitForConvex.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { getWorktreePath } from "./workspace.js";

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

        // Generate PR title early from the task description
        let generatedTitle: string | null = null;
        try {
          generatedTitle = await getPRTitleFromTaskDescription(
            taskData.taskDescription
          );
          // Persist to Convex immediately
          await convex.mutation(api.tasks.setPullRequestTitle, {
            id: taskId as Id<"tasks">,
            pullRequestTitle: generatedTitle,
          });
          serverLogger.info(`[Server] Saved early PR title: ${generatedTitle}`);
        } catch (e) {
          serverLogger.error(
            `[Server] Failed generating/saving early PR title:`,
            e
          );
        }

        // Spawn all agents in parallel (each will create its own taskRun)
        const agentResults = await spawnAllAgents(taskId, {
          repoUrl: taskData.repoUrl,
          branch: taskData.branch,
          taskDescription: taskData.taskDescription,
          prTitle: generatedTitle ?? undefined,
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

    // Provide file contents on demand to avoid large Convex docs
    socket.on("git-diff-file-contents", async (data, callback) => {
      try {
        const { taskRunId, filePath } = data as {
          taskRunId: string;
          filePath: string;
        };
        const taskRun = await convex.query(api.taskRuns.get, {
          id: taskRunId as any,
        });
        if (!taskRun?.worktreePath) {
          callback?.({ ok: false, error: "Worktree not found" });
          return;
        }
        const worktreePath = taskRun.worktreePath as string;
        // Determine status from stored diff to handle deleted/added cases
        const diffs = await convex.query(api.gitDiffs.getByTaskRun, {
          taskRunId: taskRunId as any,
        });
        const fileDiff = diffs?.find((d: any) => d.filePath === filePath);
        const status = fileDiff?.status ?? "modified";
        let oldContent = "";
        let newContent = "";
        if (status === "deleted") {
          oldContent = "";
          newContent = "";
        } else {
          try {
            newContent = await fs.readFile(
              path.join(worktreePath, filePath),
              "utf-8"
            );
          } catch {
            newContent = "";
          }
          try {
            const { stdout } = await execAsync(`git show HEAD:"${filePath}"`, {
              cwd: worktreePath,
              maxBuffer: 5 * 1024 * 1024,
            });
            oldContent = stdout;
          } catch {
            oldContent = "";
          }
        }
        callback?.({
          ok: true,
          oldContent,
          newContent,
          isBinary: fileDiff?.isBinary ?? false,
        });
      } catch (error) {
        serverLogger.error("Error in git-diff-file-contents:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("refresh-diffs", async (data, callback) => {
      try {
        const { taskRunId } = data;
        serverLogger.info(
          `[Server] Refresh diffs requested for taskRun ${taskRunId}`
        );

        // Use the simplified approach that works directly with the filesystem
        const result = await refreshDiffsForTaskRun(taskRunId);
        callback(result);
      } catch (error) {
        serverLogger.error("Error refreshing diffs:", error);
        callback({
          success: false,
          message: error instanceof Error ? error.message : "Unknown error",
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

    // Create a PR for a crowned run: commits, pushes, then creates a PR (ready for review, not draft)
    socket.on("github-create-draft-pr", async (data, callback) => {
      try {
        const { taskRunId } = GitHubCreateDraftPrSchema.parse(data);

        // Ensure worktree exists and we are on the correct branch
        const { run, task, worktreePath, branchName, baseBranch } =
          await ensureRunWorktreeAndBranch(taskRunId as any);

        // Get GitHub token from keychain/Convex with fallback to system credentials
        const githubToken = await getGitHubTokenFromKeychain(convex);
        if (!githubToken) {
          // Try to get from gh CLI as fallback
          try {
            const { stdout: ghToken } = await execAsync('gh auth token 2>/dev/null');
            if (!ghToken.trim()) {
              callback({ success: false, error: "GitHub token is not configured. Please run 'gh auth login' or configure a token in settings." });
              return;
            }
          } catch {
            callback({ success: false, error: "GitHub token is not configured. Please run 'gh auth login' or configure a token in settings." });
            return;
          }
        }

        // Create PR title/body and commit message using stored task title when available
        const title = task.pullRequestTitle || task.text || "cmux changes";
        const truncatedTitle =
          title.length > 72 ? `${title.slice(0, 69)}...` : title;
        const commitMessage = `${truncatedTitle}\n\nGenerated by cmux for task ${String(task._id)}.`;
        const body = task.text || `## Summary\n\n${title}`;

        // Ensure on branch, commit, push, and create draft PR using local filesystem
        const cwd = worktreePath;
        let prUrl: string | undefined;

        // Check if PR already exists for this branch
        try {
          const { stdout: prListOutput } = await execAsync(
            `gh pr list --head ${branchName} --json number,url,state,isDraft --limit 1`,
            {
              cwd,
              env: { ...process.env, GH_TOKEN: githubToken || undefined },
            }
          );
          const existingPRs = JSON.parse(prListOutput || '[]');
          if (existingPRs.length > 0) {
            const existingPR = existingPRs[0];
            prUrl = existingPR.url;
            
            // If it's a draft PR, convert it to ready
            if (existingPR.isDraft) {
              try {
                await execAsync(
                  `gh pr ready ${existingPR.number}`,
                  {
                    cwd,
                    env: { ...process.env, GH_TOKEN: githubToken || undefined },
                  }
                );
                serverLogger.info(`[PR] Converted draft PR #${existingPR.number} to ready for review`);
              } catch (e) {
                serverLogger.warn(`[PR] Failed to convert draft PR to ready: ${e}`);
              }
            }
            
            // Update database with PR URL and draft status (now false since we converted it)
            if (prUrl) {
              await convex.mutation(api.taskRuns.updatePullRequestUrl, {
                id: run._id as any,
                pullRequestUrl: prUrl,
                isDraft: false, // No longer a draft
              });
            }
            
            // Check if PR is merged
            if (existingPR.state === "MERGED") {
              await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
                id: run._id as any,
                merged: true,
                mergeMethod: "unknown",
              });
            }
            
            serverLogger.info(`[PR] Found existing PR #${existingPR.number} for branch ${branchName}`);
            callback({ success: true, url: prUrl });
            return;
          }
        } catch (e) {
          // No existing PR found, continue to create new one
          serverLogger.info(`[DraftPR] No existing PR found for branch ${branchName}, will create new one`);
        }

        // 1) Fetch base (optional but helpful)
        try {
          await execAsync(`git fetch origin ${baseBranch}`, {
            cwd,
            env: { ...process.env },
            maxBuffer: 10 * 1024 * 1024,
          });
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          serverLogger.warn(
            `[DraftPR] Fetch base failed (continuing): ${err?.stderr || err?.message || "unknown"}`
          );
        }

        // 2) Ensure we are on branchName without discarding local changes
        try {
          const { stdout: cbOut } = await execAsync(
            `git rev-parse --abbrev-ref HEAD`,
            { cwd, env: { ...process.env } }
          );
          const currentBranch = cbOut.trim();
          if (currentBranch !== branchName) {
            // Try create from current HEAD; if exists, just switch
            try {
              await execAsync(`git checkout -b ${branchName}`, {
                cwd,
                env: { ...process.env },
              });
            } catch {
              await execAsync(`git checkout ${branchName}`, {
                cwd,
                env: { ...process.env },
              });
            }
          }
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[DraftPR] Failed at 'Ensure branch': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Ensure branch': ${msg}`,
          });
          return;
        }

        // 3) Stage and commit changes (no-op safe)
        try {
          await execAsync("git add -A", { cwd, env: { ...process.env } });
          await execAsync(
            `git commit -m ${JSON.stringify(commitMessage)} || echo 'No changes to commit'`,
            { cwd, env: { ...process.env }, shell: "/bin/bash" }
          );
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[DraftPR] Failed at 'Commit changes': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Commit changes': ${msg}`,
          });
          return;
        }

        // 4) If remote branch exists, pull --rebase to integrate updates
        try {
          const { stdout: lsOut } = await execAsync(
            `git ls-remote --heads origin ${branchName}`,
            { cwd, env: { ...process.env } }
          );
          if ((lsOut || "").trim().length > 0) {
            await execAsync(`git pull --rebase origin ${branchName}`, {
              cwd,
              env: { ...process.env },
              maxBuffer: 10 * 1024 * 1024,
            });
          }
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[DraftPR] Failed at 'Pull --rebase': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Pull --rebase': ${msg}`,
          });
          return;
        }

        // 5) Push branch (set upstream)
        try {
          await execAsync(`git push -u origin ${branchName}`, {
            cwd,
            env: { ...process.env },
            maxBuffer: 10 * 1024 * 1024,
          });
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[DraftPR] Failed at 'Push branch': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Push branch': ${msg}`,
          });
          return;
        }

        // 6) Create PR (ready for review, not draft)
        try {
          // Write body to a temp file to preserve Markdown formatting
          const tmpBodyPath = path.join(
            os.tmpdir(),
            `cmux_pr_body_${Date.now()}_${Math.random().toString(36).slice(2)}.md`
          );
          await fs.writeFile(tmpBodyPath, body, "utf8");

          const { stdout } = await execAsync(
            `gh pr create --title ${JSON.stringify(
              truncatedTitle
            )} --body-file ${JSON.stringify(tmpBodyPath)} --head ${JSON.stringify(
              branchName
            )} --base ${JSON.stringify(baseBranch)}`,
            {
              cwd,
              env: { ...process.env, GH_TOKEN: githubToken || undefined },
              maxBuffer: 10 * 1024 * 1024,
            }
          );
          const out = (stdout || "").trim();
          const match = out.match(/https:\/\/github\.com\/[^\s]+/);
          prUrl = match ? match[0] : out;
          // Clean up temp file
          try {
            await fs.unlink(tmpBodyPath);
          } catch {}
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[PR] Failed at 'Create PR': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Create PR': ${msg}`,
          });
          return;
        }

        if (prUrl) {
          await convex.mutation(api.taskRuns.updatePullRequestUrl, {
            id: run._id as any,
            pullRequestUrl: prUrl,
            isDraft: false, // Not a draft anymore
          });
          serverLogger.info(`[PR] Created PR: ${prUrl} for branch: ${branchName}`);
        }

        callback({ success: true, url: prUrl });
      } catch (error) {
        serverLogger.error("Error creating PR:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("github-merge-pr", async (data: { taskRunId: string; mergeMethod: "squash" | "rebase" | "merge" }, callback) => {
      try {
        // 1) Fetch the task run
        const run = await convex.query(api.taskRuns.getById, {
          id: data.taskRunId as any,
        });
        if (!run) {
          callback({ success: false, error: "Task run not found" });
          return;
        }

        // Check if already merged
        if (run.pullRequestMerged) {
          callback({ success: false, error: "Pull request already merged" });
          return;
        }

        // Check if PR exists
        if (!run.pullRequestUrl || run.pullRequestUrl === "pending") {
          callback({ success: false, error: "No pull request URL found" });
          return;
        }

        // Extract owner/repo and PR number from URL
        const prUrlMatch = run.pullRequestUrl.match(/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/);
        if (!prUrlMatch) {
          callback({ success: false, error: "Invalid pull request URL format" });
          return;
        }
        const [, owner, repo, prNumber] = prUrlMatch;

        // 2) Get GitHub token with fallback to system credentials
        let githubToken = await getGitHubTokenFromKeychain(convex);
        if (!githubToken) {
          // Try to get from gh CLI as fallback
          try {
            const { stdout: ghToken } = await execAsync('gh auth token 2>/dev/null');
            githubToken = ghToken.trim();
            if (!githubToken) {
              callback({ success: false, error: "GitHub token not configured. Please run 'gh auth login' or configure a token in settings." });
              return;
            }
          } catch {
            callback({ success: false, error: "GitHub token not configured. Please run 'gh auth login' or configure a token in settings." });
            return;
          }
        }

        // 3) Check PR status using gh CLI
        const cwd = run.worktreePath || process.cwd();
        try {
          const { stdout: prStatus } = await execAsync(
            `gh pr view ${prNumber} --json state,mergeable,mergeStateStatus --repo ${owner}/${repo}`,
            {
              cwd,
              env: { ...process.env, GH_TOKEN: githubToken },
            }
          );
          
          const prInfo = JSON.parse(prStatus);
          
          // Check if PR is already merged
          if (prInfo.state === "MERGED") {
            // Update the database to reflect this
            await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
              id: run._id as any,
              merged: true,
              mergeMethod: "unknown", // We don't know the method used
            });
            callback({ success: false, error: "Pull request is already merged" });
            return;
          }

          // Check if PR is closed
          if (prInfo.state === "CLOSED") {
            callback({ success: false, error: "Pull request is closed" });
            return;
          }

          // Check if PR is mergeable
          if (prInfo.mergeable === "CONFLICTING") {
            callback({ success: false, error: "Pull request has conflicts that must be resolved" });
            return;
          }

          if (prInfo.mergeStateStatus !== "CLEAN" && prInfo.mergeStateStatus !== "UNSTABLE") {
            callback({ success: false, error: `Pull request is not ready to merge: ${prInfo.mergeStateStatus}` });
            return;
          }
        } catch (error) {
          serverLogger.error("Error checking PR status:", error);
          callback({ success: false, error: "Failed to check pull request status" });
          return;
        }

        // 4) Merge the PR
        try {
          const mergeFlag = data.mergeMethod === "squash" ? "--squash" :
                           data.mergeMethod === "rebase" ? "--rebase" :
                           "--merge";

          const { stdout, stderr } = await execAsync(
            `gh pr merge ${prNumber} ${mergeFlag} --repo ${owner}/${repo}`,
            {
              cwd,
              env: { ...process.env, GH_TOKEN: githubToken },
            }
          );

          serverLogger.info(`[MergePR] Successfully merged PR #${prNumber} with method: ${data.mergeMethod}`);
          
          // 5) Update the database
          await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
            id: run._id as any,
            merged: true,
            mergeMethod: data.mergeMethod,
          });

          callback({ success: true, message: `Successfully merged PR #${prNumber}` });
        } catch (error: any) {
          const errorMessage = error?.stderr || error?.stdout || error?.message || "Unknown error";
          serverLogger.error(`[MergePR] Failed to merge PR #${prNumber}:`, errorMessage);
          
          // Check if it was actually merged (sometimes gh cli returns error even on success)
          try {
            const { stdout: checkStatus } = await execAsync(
              `gh pr view ${prNumber} --json state --repo ${owner}/${repo}`,
              {
                cwd,
                env: { ...process.env, GH_TOKEN: githubToken || undefined },
              }
            );
            const checkInfo = JSON.parse(checkStatus);
            if (checkInfo.state === "MERGED") {
              // It was actually merged
              await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
                id: run._id as any,
                merged: true,
                mergeMethod: data.mergeMethod,
              });
              callback({ success: true, message: `Successfully merged PR #${prNumber}` });
              return;
            }
          } catch {}
          
          callback({ success: false, error: `Failed to merge PR: ${errorMessage}` });
        }
      } catch (error) {
        serverLogger.error("Error merging PR:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Check PR status for a task run
    socket.on("check-pr-status", async (data: { taskRunId: string }, callback) => {
      try {
        // Get the task run
        const run = await convex.query(api.taskRuns.getById, {
          id: data.taskRunId as any,
        });
        if (!run) {
          callback({ success: false, error: "Task run not found" });
          return;
        }

        // If no PR URL, check if one exists
        if (!run.pullRequestUrl || run.pullRequestUrl === "pending") {
          // Check if PR exists for this branch
          if (!run.newBranch) {
            callback({ success: true, haspr: false });
            return;
          }

          // Get GitHub token
          let githubToken = await getGitHubTokenFromKeychain(convex);
          if (!githubToken) {
            try {
              const { stdout: ghToken } = await execAsync('gh auth token 2>/dev/null');
              githubToken = ghToken.trim();
            } catch {}
          }

          if (!githubToken) {
            callback({ success: false, error: "GitHub token not configured" });
            return;
          }

          const cwd = run.worktreePath || process.cwd();
          try {
            const { stdout: prListOutput } = await execAsync(
              `gh pr list --head ${run.newBranch} --json number,url,state,isDraft --limit 1`,
              {
                cwd,
                env: { ...process.env, GH_TOKEN: githubToken || undefined },
              }
            );
            const existingPRs = JSON.parse(prListOutput || '[]');
            if (existingPRs.length > 0) {
              const existingPR = existingPRs[0];
              
              // If it's a draft PR, convert it to ready
              if (existingPR.isDraft) {
                try {
                  await execAsync(
                    `gh pr ready ${existingPR.number}`,
                    {
                      cwd,
                      env: { ...process.env, GH_TOKEN: githubToken || undefined },
                    }
                  );
                  serverLogger.info(`[PR] Converted draft PR #${existingPR.number} to ready for review`);
                } catch (e) {
                  serverLogger.warn(`[PR] Failed to convert draft PR to ready: ${e}`);
                }
              }
              
              // Update database with PR info
              await convex.mutation(api.taskRuns.updatePullRequestUrl, {
                id: run._id as any,
                pullRequestUrl: existingPR.url,
                isDraft: false, // Should be ready now
              });
              
              // Check if merged
              if (existingPR.state === "MERGED") {
                await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
                  id: run._id as any,
                  merged: true,
                  mergeMethod: "unknown",
                });
                callback({ success: true, haspr: true, url: existingPR.url, merged: true });
              } else {
                callback({ success: true, haspr: true, url: existingPR.url, merged: false });
              }
              return;
            }
          } catch (e) {
            // No PR found
          }
          callback({ success: true, haspr: false });
          return;
        }

        // PR URL exists, check if it's merged
        const prUrlMatch = run.pullRequestUrl.match(/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/);
        if (!prUrlMatch) {
          callback({ success: true, haspr: true, url: run.pullRequestUrl, merged: run.pullRequestMerged || false });
          return;
        }
        const [, owner, repo, prNumber] = prUrlMatch;

        // Get GitHub token
        let githubToken = await getGitHubTokenFromKeychain(convex);
        if (!githubToken) {
          try {
            const { stdout: ghToken } = await execAsync('gh auth token 2>/dev/null');
            githubToken = ghToken.trim();
          } catch {}
        }

        if (githubToken) {
          const cwd = run.worktreePath || process.cwd();
          try {
            const { stdout: prStatus } = await execAsync(
              `gh pr view ${prNumber} --json state --repo ${owner}/${repo}`,
              {
                cwd,
                env: { ...process.env, GH_TOKEN: githubToken },
              }
            );
            const prInfo = JSON.parse(prStatus);
            if (prInfo.state === "MERGED" && !run.pullRequestMerged) {
              // Update database if newly merged
              await convex.mutation(api.taskRuns.updatePullRequestMergeStatus, {
                id: run._id as any,
                merged: true,
                mergeMethod: "unknown",
              });
              callback({ success: true, haspr: true, url: run.pullRequestUrl, merged: true });
              return;
            }
            callback({ success: true, haspr: true, url: run.pullRequestUrl, merged: prInfo.state === "MERGED" });
          } catch (e) {
            // Can't check status, return what we have in DB
            callback({ success: true, haspr: true, url: run.pullRequestUrl, merged: run.pullRequestMerged || false });
          }
        } else {
          // No token, return what we have in DB
          callback({ success: true, haspr: true, url: run.pullRequestUrl, merged: run.pullRequestMerged || false });
        }
      } catch (error) {
        serverLogger.error("Error checking PR status:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
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
