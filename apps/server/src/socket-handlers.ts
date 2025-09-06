import { api } from "@cmux/convex/api";
import {
  ArchiveTaskSchema,
  GitFullDiffRequestSchema,
  GitHubCreateDraftPrSchema,
  GitHubFetchBranchesSchema,
  GitHubFetchReposSchema,
  GitHubMergeBranchSchema,
  ListFilesRequestSchema,
  OpenInEditorSchema,
  SpawnFromCommentSchema,
  StartTaskSchema,
  type AvailableEditors,
  type FileInfo,
} from "@cmux/shared";
import fuzzysort from "fuzzysort";
import { minimatch } from "minimatch";
import { exec, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { spawnAllAgents } from "./agentSpawner.js";
import { stopContainersForRuns } from "./archiveTask.js";
import { execWithEnv } from "./execWithEnv.js";
import { GitDiffManager } from "./gitDiff.js";
import { RepositoryManager } from "./repositoryManager.js";
import { getPRTitleFromTaskDescription } from "./utils/branchNameGenerator.js";
import { getConvex } from "./utils/convexClient.js";
import { ensureRunWorktreeAndBranch } from "./utils/ensureRunWorktree.js";
import { serverLogger } from "./utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken.js";
import {
  createReadyPr,
  fetchPrByHead,
  fetchPrDetail,
  markPrReady,
  mergePr,
  parseRepoFromUrl,
  reopenPr,
} from "./utils/githubPr.js";
import { getOctokit } from "./utils/octokit.js";
import { checkAllProvidersStatus } from "./utils/providerStatus.js";
import {
  refreshBranchesForRepo,
  refreshGitHubData,
} from "./utils/refreshGitHubData.js";
import { runWithAuth, runWithAuthToken } from "./utils/requestContext.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";
import { getProjectPaths } from "./workspace.js";
import type { GitRepoInfo } from "./server.js";
import type { RealtimeServer } from "./realtime.js";

const execAsync = promisify(exec);

export function setupSocketHandlers(
  rt: RealtimeServer,
  gitDiffManager: GitDiffManager,
  defaultRepo?: GitRepoInfo | null
) {
  let hasRefreshedGithub = false;
  let dockerEventsStarted = false;

  rt.onConnection((socket) => {
    // Ensure every packet runs within the auth context associated with this socket
    const q = socket.handshake.query?.auth;
    const token = Array.isArray(q)
      ? q[0]
      : typeof q === "string"
        ? q
        : undefined;
    const qJson = socket.handshake.query?.auth_json;
    const tokenJson = Array.isArray(qJson)
      ? qJson[0]
      : typeof qJson === "string"
        ? qJson
        : undefined;

    // authenticate the token
    if (!token) {
      // disconnect the socket
      socket.disconnect();
      return;
    }

    socket.use((_, next) => {
      runWithAuth(token, tokenJson, () => next());
    });
    serverLogger.info("Client connected:", socket.id);

    // Send default repo info to newly connected client if available
    if (defaultRepo?.remoteName) {
      const defaultRepoData = {
        repoFullName: defaultRepo.remoteName,
        branch: defaultRepo.currentBranch || defaultRepo.defaultBranch,
        localPath: defaultRepo.path,
      };
      serverLogger.info(
        `Sending default-repo to new client ${socket.id}:`,
        defaultRepoData
      );
      socket.emit("default-repo", defaultRepoData);
    }

    // Kick off initial GitHub data refresh only after an authenticated connection
    const qAuth = socket.handshake.query?.auth;
    const qTeam = socket.handshake.query?.team;
    const qAuthJson = socket.handshake.query?.auth_json;
    const initialToken = Array.isArray(qAuth)
      ? qAuth[0]
      : typeof qAuth === "string"
        ? qAuth
        : undefined;
    const initialAuthJson = Array.isArray(qAuthJson)
      ? qAuthJson[0]
      : typeof qAuthJson === "string"
        ? qAuthJson
        : undefined;
    const initialTeam = Array.isArray(qTeam)
      ? qTeam[0]
      : typeof qTeam === "string"
        ? qTeam
        : undefined;
    const safeTeam = initialTeam || "default";
    if (!hasRefreshedGithub && initialToken) {
      hasRefreshedGithub = true;
      runWithAuth(initialToken, initialAuthJson, () => {
        if (!initialTeam) {
          serverLogger.warn(
            "No team provided on socket handshake; skipping initial GitHub refresh"
          );
          return;
        }
        refreshGitHubData({ teamSlugOrId: initialTeam }).catch((error) => {
          serverLogger.error("Background refresh failed:", error);
        });
      });
      // Start Docker container state sync after first authenticated connection
      if (!dockerEventsStarted) {
        dockerEventsStarted = true;
        runWithAuth(initialToken, initialAuthJson, () => {
          serverLogger.info(
            "Starting Docker container state sync after authenticated connect"
          );
          DockerVSCodeInstance.startContainerStateSync();
        });
      }
    } else if (!initialToken) {
      serverLogger.info(
        "Skipping initial GitHub refresh: no auth token on connect"
      );
    }

    void (async () => {
      const commandExists = async (cmd: string) => {
        try {
          await execAsync(`command -v ${cmd}`);
          return true;
        } catch {
          return false;
        }
      };

      const appExists = async (app: string) => {
        if (process.platform !== "darwin") return false;
        try {
          await execAsync(`open -Ra "${app}"`);
          return true;
        } catch {
          return false;
        }
      };

      const [
        vscodeExists,
        cursorExists,
        windsurfExists,
        itermExists,
        terminalExists,
        ghosttyCommand,
        ghosttyApp,
        alacrittyExists,
        xcodeExists,
      ] = await Promise.all([
        commandExists("code"),
        commandExists("cursor"),
        commandExists("windsurf"),
        appExists("iTerm"),
        appExists("Terminal"),
        commandExists("ghostty"),
        appExists("Ghostty"),
        commandExists("alacritty"),
        appExists("Xcode"),
      ]);

      const availability: AvailableEditors = {
        vscode: vscodeExists,
        cursor: cursorExists,
        windsurf: windsurfExists,
        finder: process.platform === "darwin",
        iterm: itermExists,
        terminal: terminalExists,
        ghostty: ghosttyCommand || ghosttyApp,
        alacritty: alacrittyExists,
        xcode: xcodeExists,
      };

      socket.emit("available-editors", availability);
    })();

    socket.on("start-task", async (data, callback) => {
      const taskData = StartTaskSchema.parse(data);
      serverLogger.info("starting task!", taskData);
      const taskId = taskData.taskId;
      try {
        // Generate PR title early from the task description
        let generatedTitle: string | null = null;
        try {
          generatedTitle = await getPRTitleFromTaskDescription(
            taskData.taskDescription,
            safeTeam
          );
          // Persist to Convex immediately
          await getConvex().mutation(api.tasks.setPullRequestTitle, {
            teamSlugOrId: safeTeam,
            id: taskId,
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
        const agentResults = await spawnAllAgents(
          taskId,
          {
            repoUrl: taskData.repoUrl,
            branch: taskData.branch,
            taskDescription: taskData.taskDescription,
            prTitle: generatedTitle ?? undefined,
            selectedAgents: taskData.selectedAgents,
            isCloudMode: taskData.isCloudMode,
            images: taskData.images,
            theme: taskData.theme,
          },
          safeTeam
        );

        // Check if at least one agent spawned successfully
        const successfulAgents = agentResults.filter(
          (result) => result.success
        );
        if (successfulAgents.length === 0) {
          const errors = agentResults
            .filter((r) => !r.success)
            .map((r) => `${r.agentName}: ${r.error || "Unknown error"}`)
            .join("; ");
          callback({
            taskId,
            error: errors || "Failed to spawn any agents",
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
          rt.emit("vscode-spawned", {
            instanceId: primaryAgent.terminalId,
            url: primaryAgent.vscodeUrl.replace("/?folder=/root/workspace", ""),
            workspaceUrl: primaryAgent.vscodeUrl,
            provider: taskData.isCloudMode ? "morph" : "docker",
          });
        }

        // Set up file watching for git changes (optional - don't fail if it doesn't work)
        try {
          void gitDiffManager.watchWorkspace(
            primaryAgent.worktreePath,
            (changedPath) => {
              rt.emit("git-file-changed", {
                workspacePath: primaryAgent.worktreePath,
                filePath: changedPath,
              });
            }
          );
        } catch (error) {
          serverLogger.warn(
            "Could not set up file watching for workspace:",
            error
          );
          // Continue without file watching
        }

        callback({
          taskId,
          worktreePath: primaryAgent.worktreePath,
          terminalId: primaryAgent.terminalId,
        });
      } catch (error) {
        serverLogger.error("Error in start-task:", error);
        callback({
          taskId,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Sync PR state (non-destructive): query GitHub and update Convex
    socket.on("github-sync-pr-state", async (data, callback) => {
      try {
        const { taskRunId } = GitHubCreateDraftPrSchema.parse(data);

        // Load run and task (no worktree setup to keep it light)
        const run = await getConvex().query(api.taskRuns.get, {
          teamSlugOrId: safeTeam,
          id: taskRunId,
        });
        if (!run) {
          callback({ success: false, error: "Task run not found" });
          return;
        }
        const task = await getConvex().query(api.tasks.getById, {
          teamSlugOrId: safeTeam,
          id: run.taskId,
        });
        if (!task) {
          callback({ success: false, error: "Task not found" });
          return;
        }

        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          callback({ success: false, error: "GitHub token is not configured" });
          return;
        }

        const repoFullName = task.projectFullName || "";
        let [owner, repo] = repoFullName.split("/");
        const branchName = run.newBranch || "";

        // Determine PR via URL number when available
        let prNumber: number | null = null;
        if (run.pullRequestNumber) {
          prNumber = run.pullRequestNumber;
        } else if (run.pullRequestUrl) {
          const parsed = parseRepoFromUrl(run.pullRequestUrl);
          if (parsed.owner && parsed.repo) {
            owner = owner || parsed.owner;
            repo = repo || parsed.repo;
          }
          if (parsed.number) prNumber = parsed.number;
        }

        let prBasic: {
          number: number;
          html_url: string;
          state: string;
          draft?: boolean;
        } | null = null;
        if (owner && repo && prNumber) {
          const detail = await fetchPrDetail(
            githubToken,
            owner,
            repo,
            prNumber
          );
          prBasic = {
            number: detail.number,
            html_url: detail.html_url,
            state: detail.state,
            draft: detail.draft,
          };
        } else if (owner && repo && branchName) {
          // Find PR by head branch
          prBasic = await fetchPrByHead(
            githubToken,
            owner,
            repo,
            owner,
            branchName
          );
        }

        if (!prBasic) {
          await getConvex().mutation(api.taskRuns.updatePullRequestState, {
            teamSlugOrId: safeTeam,
            id: run._id,
            state: "none",
            isDraft: undefined,
            number: undefined,
            url: undefined,
          });
          // Update task merge status to none
          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: "none",
          });
          callback({ success: true, state: "none" });
          return;
        }

        // Fetch detailed PR to detect merged
        const prDetail = await fetchPrDetail(
          githubToken,
          owner,
          repo,
          prBasic.number
        );
        const isMerged = !!prDetail.merged_at;
        const isDraft = prDetail.draft ?? prBasic.draft ?? false;

        const state: "open" | "closed" | "merged" | "draft" | "unknown" =
          isMerged
            ? "merged"
            : isDraft
              ? "draft"
              : prBasic.state === "open"
                ? "open"
                : prBasic.state === "closed"
                  ? "closed"
                  : "unknown";

        await getConvex().mutation(api.taskRuns.updatePullRequestState, {
          teamSlugOrId: safeTeam,
          id: run._id,
          state,
          isDraft,
          number: prBasic.number,
          url: prBasic.html_url,
        });

        // Update task merge status based on PR state
        let taskMergeStatus:
          | "none"
          | "pr_draft"
          | "pr_open"
          | "pr_merged"
          | "pr_closed" = "none";
        switch (state) {
          case "draft":
            taskMergeStatus = "pr_draft";
            break;
          case "open":
            taskMergeStatus = "pr_open";
            break;
          case "merged":
            taskMergeStatus = "pr_merged";
            break;
          case "closed":
            taskMergeStatus = "pr_closed";
            break;
        }
        if (taskMergeStatus !== "none") {
          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: taskMergeStatus,
          });
        }

        callback({
          success: true,
          url: prBasic.html_url,
          number: prBasic.number,
          state,
          isDraft,
        });
      } catch (error) {
        serverLogger.error("Error syncing PR state:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Merge PR for a run
    socket.on("github-merge-pr", async (data, callback) => {
      try {
        const { taskRunId, method } = data;

        const run = await getConvex().query(api.taskRuns.get, {
          teamSlugOrId: safeTeam,
          id: taskRunId,
        });
        if (!run) {
          return callback({ success: false, error: "Task run not found" });
        }
        const task = await getConvex().query(api.tasks.getById, {
          teamSlugOrId: safeTeam,
          id: run.taskId,
        });
        if (!task) {
          return callback({ success: false, error: "Task not found" });
        }
        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          return callback({
            success: false,
            error: "GitHub token is not configured",
          });
        }
        let [owner, repo] = (task.projectFullName || "").split("/");
        let prNumber: number | null = run.pullRequestNumber || null;
        if ((!owner || !repo || !prNumber) && run.pullRequestUrl) {
          const parsed = parseRepoFromUrl(run.pullRequestUrl);
          owner = owner || parsed.owner || owner;
          repo = repo || parsed.repo || repo;
          prNumber = prNumber || parsed.number || null;
        }
        if (!owner || !repo) {
          return callback({ success: false, error: "Unknown repo for task" });
        }
        // If PR number still unknown, try to locate via branch
        if (!prNumber && run.newBranch) {
          const found = await fetchPrByHead(
            githubToken,
            owner,
            repo,
            owner,
            run.newBranch
          );
          if (found) {
            prNumber = found.number;
          }
        }

        if (!prNumber) {
          return callback({
            success: false,
            error: "Pull request not found for this run",
          });
        }

        // Ensure PR is open and not draft
        const detail = await fetchPrDetail(githubToken, owner, repo, prNumber);
        if (detail.draft) {
          // Try to mark ready
          try {
            await markPrReady(githubToken, owner, repo, prNumber);
            serverLogger.info(
              `[MergePR] Successfully marked PR #${prNumber} as ready for review`
            );
          } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : String(e);

            // Check if it's a 404 error
            if (msg.includes("not found") || msg.includes("404")) {
              return callback({
                success: false,
                error: `Pull request #${prNumber} not found. It may have been deleted.`,
              });
            }

            return callback({
              success: false,
              error: `PR is draft and could not be made ready: ${msg}`,
            });
          }
        }
        if (detail.state === "closed") {
          // Try to reopen
          try {
            await reopenPr(githubToken, owner, repo, prNumber);
          } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : String(e);
            return callback({
              success: false,
              error: `PR is closed and could not be reopened: ${msg}`,
            });
          }
        }

        // Optional: commit title/message
        const title = task.pullRequestTitle || task.text || `cmux changes`;
        const truncatedTitle =
          title.length > 72 ? `${title.slice(0, 69)}...` : title;
        const commitMessage = `Merged by cmux for task ${String(task._id)}.`;

        // Merge
        try {
          const res = await mergePr(
            githubToken,
            owner,
            repo,
            prNumber,
            method,
            truncatedTitle,
            commitMessage
          );
          // Update Convex: merged
          await getConvex().mutation(api.taskRuns.updatePullRequestState, {
            teamSlugOrId: safeTeam,
            id: run._id,
            state: "merged",
            isDraft: false,
            number: prNumber,
            url: detail.html_url,
          });
          // Update task merge status to merged
          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: "pr_merged",
          });
          callback({
            success: true,
            merged: !!res.merged,
            state: "merged",
            url: detail.html_url,
          });
        } catch (e: unknown) {
          const msg = e instanceof Error ? e.message : String(e);
          callback({ success: false, error: `Failed to merge PR: ${msg}` });
        }
      } catch (error) {
        serverLogger.error("Error merging PR:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Merge branch directly without PR
    socket.on("github-merge-branch", async (data, callback) => {
      try {
        const { taskRunId } = GitHubMergeBranchSchema.parse(data);

        const { run, task, branchName, baseBranch } =
          await ensureRunWorktreeAndBranch(taskRunId, safeTeam);

        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          return callback({
            success: false,
            error: "GitHub token is not configured",
          });
        }

        const repoFullName = task.projectFullName || "";
        const [owner, repo] = repoFullName.split("/");
        if (!owner || !repo) {
          return callback({ success: false, error: "Unknown repo for task" });
        }

        try {
          const octokit = getOctokit(githubToken);
          const { data: mergeRes } = await octokit.rest.repos.merge({
            owner,
            repo,
            base: baseBranch,
            head: branchName,
          });

          await getConvex().mutation(api.taskRuns.updatePullRequestState, {
            teamSlugOrId: safeTeam,
            id: run._id,
            state: "merged",
          });

          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: "pr_merged",
          });

          callback({ success: true, merged: true, commitSha: mergeRes.sha });
        } catch (e: unknown) {
          const msg = e instanceof Error ? e.message : String(e);
          callback({
            success: false,
            error: `Failed to merge branch: ${msg}`,
          });
        }
      } catch (error) {
        serverLogger.error("Error merging branch:", error);
        callback({
          success: false,
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

    // Continue with all other handlers...
    // (I'll include the rest of the handlers in the next message due to length)

    // Provide file contents on demand to avoid large Convex docs
    socket.on("git-diff-file-contents", async (data, callback) => {
      try {
        const { taskRunId, filePath } = data;
        // Ensure the worktree exists for this run
        const ensured = await ensureRunWorktreeAndBranch(taskRunId, safeTeam);
        const worktreePath = ensured.worktreePath as string;
        let oldContent = "";
        let newContent = "";
        try {
          newContent = await fs.readFile(
            path.join(worktreePath, filePath),
            "utf-8"
          );
        } catch {
          newContent = "";
        }
        try {
          // Use git CLI to read baseRef version of the file. Prefer default branch (origin/<default>),
          // then upstream, and finally HEAD as a last resort.
          let baseRef = "HEAD";
          try {
            const repoMgr = RepositoryManager.getInstance();
            const defaultBranch = await repoMgr.getDefaultBranch(worktreePath);
            if (defaultBranch) baseRef = `origin/${defaultBranch}`;
          } catch {
            // ignore and try upstream next
          }
          if (baseRef === "HEAD") {
            try {
              const { stdout } = await execAsync(
                "git rev-parse --abbrev-ref --symbolic-full-name @{u}",
                { cwd: worktreePath }
              );
              if (stdout.trim()) baseRef = "@{upstream}";
            } catch {
              // stick with HEAD
            }
          }
          const { stdout } = await execAsync(
            `git show ${baseRef}:"${filePath.replace(/"/g, '\\"')}"`,
            {
              cwd: worktreePath,
              maxBuffer: 10 * 1024 * 1024,
            }
          );
          oldContent = stdout;
        } catch {
          oldContent = "";
        }
        callback?.({ ok: true, oldContent, newContent, isBinary: false });
      } catch (error) {
        serverLogger.error("Error in git-diff-file-contents:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Get diffs on demand to avoid storing in Convex
    socket.on("get-run-diffs", async (data, callback) => {
      try {
        const { taskRunId } = data;
        // Ensure the worktree exists and is on the correct branch
        const ensured = await ensureRunWorktreeAndBranch(taskRunId, safeTeam);
        const worktreePath = ensured.worktreePath as string;
        const { computeEntriesNodeGit } = await import(
          "./diffs/parseGitDiff.js"
        );
        const entries = await computeEntriesNodeGit({
          worktreePath,
          includeContents: true,
        });
        // Start watching this worktree to push reactive updates to this client group
        try {
          void gitDiffManager.watchWorkspace(worktreePath, () => {
            rt.emit("git-file-changed", {
              workspacePath: worktreePath,
              filePath: "",
            });
          });
        } catch (e) {
          serverLogger.warn(
            `Failed to start watcher for ${worktreePath}: ${String(e)}`
          );
        }
        callback?.({ ok: true, diffs: entries });
      } catch (error) {
        serverLogger.error("Error getting run diffs:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
          diffs: [],
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
          case "iterm":
            command = ["open", "-a", "iTerm", path];
            break;
          case "terminal":
            command = ["open", "-a", "Terminal", path];
            break;
          case "ghostty":
            command = ["open", "-a", "Ghostty", path];
            break;
          case "alacritty":
            command = ["alacritty", "--working-directory", path];
            break;
          case "xcode":
            command = ["open", "-a", "Xcode", path];
            break;
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
        const {
          repoPath: repoUrl,
          branch,
          pattern,
        } = ListFilesRequestSchema.parse(data);
        const repoManager = RepositoryManager.getInstance();

        // Resolve origin path without assuming any branch
        const projectPaths = await getProjectPaths(repoUrl, safeTeam);

        // Ensure directories exist
        await fs.mkdir(projectPaths.projectPath, { recursive: true });
        await fs.mkdir(projectPaths.worktreesPath, { recursive: true });

        // Ensure the repository is cloned/fetched with deduplication
        // Ensure repository exists (clone if needed) without assuming branch
        await repoManager.ensureRepository(repoUrl, projectPaths.originPath);

        // Determine the effective base branch
        const baseBranch =
          branch ||
          (await repoManager.getDefaultBranch(projectPaths.originPath));

        // Fetch that branch to make sure origin has it
        await repoManager.ensureRepository(
          repoUrl,
          projectPaths.originPath,
          baseBranch
        );

        // For clarity downstream, compute a proper worktreeInfo keyed by baseBranch
        const worktreeInfo = {
          ...projectPaths,
          worktreePath: projectPaths.worktreesPath + "/" + baseBranch,
          branch: baseBranch,
        } as const;

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

    socket.on("github-fetch-repos", async (data, callback) => {
      try {
        const { teamSlugOrId } = GitHubFetchReposSchema.parse(data);
        if (!initialToken) {
          callback({ success: false, repos: {}, error: "Not authenticated" });
          return;
        }
        // First, try to get existing repos from Convex
        const existingRepos = await getConvex().query(api.github.getAllRepos, {
          teamSlugOrId,
        });

        if (existingRepos.length > 0) {
          // If we have repos, return them and refresh in the background
          const reposByOrg = await getConvex().query(api.github.getReposByOrg, {
            teamSlugOrId,
          });
          callback({ success: true, repos: reposByOrg });

          // Refresh in the background to add any new repos
          runWithAuthToken(initialToken, () =>
            refreshGitHubData({ teamSlugOrId }).catch((error) => {
              serverLogger.error("Background refresh failed:", error);
            })
          );
          return;
        }

        // If no repos exist, do a full fetch
        await runWithAuthToken(initialToken, () =>
          refreshGitHubData({ teamSlugOrId })
        );
        const reposByOrg = await getConvex().query(api.github.getReposByOrg, {
          teamSlugOrId,
        });
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

    socket.on("spawn-from-comment", async (data, callback) => {
      try {
        const {
          url,
          page,
          pageTitle,
          nodeId,
          x,
          y,
          content,
          selectedAgents,
          commentId,
        } = SpawnFromCommentSchema.parse(data);
        console.log("spawn-from-comment data", data);

        // Format the prompt with comment metadata
        const formattedPrompt = `Fix the issue described in this comment:

Comment: "${content}"

Context:
- Page URL: ${url}${page}
- Page Title: ${pageTitle}
- Element XPath: ${nodeId}
- Position: ${x * 100}% x ${y * 100}% relative to element

Please address the issue mentioned in the comment above.`;

        // Create a new task in Convex
        const taskId = await getConvex().mutation(api.tasks.create, {
          teamSlugOrId: safeTeam,
          text: formattedPrompt,
          projectFullName: "manaflow-ai/cmux",
        });
        // Create a comment reply with link to the task
        try {
          await getConvex().mutation(api.comments.addReply, {
            teamSlugOrId: safeTeam,
            commentId: commentId,
            content: `[View run here](http://localhost:5173/${safeTeam}/task/${taskId})`,
          });
          serverLogger.info("Created comment reply with task link:", {
            commentId,
            taskId,
          });
        } catch (replyError) {
          serverLogger.error("Failed to create comment reply:", replyError);
          // Don't fail the whole operation if reply fails
        }

        serverLogger.info("Created task from comment:", { taskId, content });

        // Spawn agents with the formatted prompt
        const agentResults = await spawnAllAgents(
          taskId,
          {
            repoUrl: "https://github.com/manaflow-ai/cmux.git",
            branch: "main",
            taskDescription: formattedPrompt,
            isCloudMode: true,
            theme: "dark",
            // Use provided selectedAgents or default to claude/sonnet-4 and codex/gpt-5
            selectedAgents: selectedAgents || [
              "claude/sonnet-4",
              "codex/gpt-5",
            ],
          },
          safeTeam
        );

        // Check if at least one agent spawned successfully
        const successfulAgents = agentResults.filter(
          (result) => result.success
        );

        if (successfulAgents.length === 0) {
          const errors = agentResults
            .filter((r) => !r.success)
            .map((r) => `${r.agentName}: ${r.error || "Unknown error"}`)
            .join("; ");
          callback({
            success: false,
            error: errors || "Failed to spawn any agents",
          });
          return;
        }

        const primaryAgent = successfulAgents[0];

        // Emit VSCode URL if available
        if (primaryAgent.vscodeUrl) {
          rt.emit("vscode-spawned", {
            instanceId: primaryAgent.terminalId,
            url: primaryAgent.vscodeUrl.replace("/?folder=/root/workspace", ""),
            workspaceUrl: primaryAgent.vscodeUrl,
            provider: "morph", // Since isCloudMode is true
          });
        }

        callback({
          success: true,
          taskId,
          taskRunId: primaryAgent.taskRunId,
          worktreePath: primaryAgent.worktreePath,
          terminalId: primaryAgent.terminalId,
          vscodeUrl: primaryAgent.vscodeUrl,
        });
      } catch (error) {
        serverLogger.error("Error spawning from comment:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("github-fetch-branches", async (data, callback) => {
      try {
        const { teamSlugOrId, repo } = GitHubFetchBranchesSchema.parse(data);

        // Check if we already have branches for this repo
        const existingBranches = await getConvex().query(
          api.github.getBranches,
          {
            teamSlugOrId,
            repo,
          }
        );

        if (existingBranches.length > 0) {
          // Return existing branches and refresh in background
          callback({ success: true, branches: existingBranches });

          // Refresh in the background
          refreshBranchesForRepo(repo, teamSlugOrId).catch((error) => {
            serverLogger.error("Background branch refresh failed:", error);
          });
          return;
        }

        // If no branches exist, fetch them
        const branches = await refreshBranchesForRepo(repo, teamSlugOrId);
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

    // Create a draft PR for a crowned run: commits, pushes, then creates a draft PR
    socket.on("github-create-draft-pr", async (data, callback) => {
      try {
        const { taskRunId } = GitHubCreateDraftPrSchema.parse(data);

        // Ensure worktree exists and we are on the correct branch
        const { run, task, worktreePath, branchName, baseBranch } =
          await ensureRunWorktreeAndBranch(taskRunId, safeTeam);

        // Get GitHub token from keychain/Convex
        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          callback({ success: false, error: "GitHub token is not configured" });
          return;
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

        // 6) Create draft PR
        try {
          // Write body to a temp file to preserve Markdown formatting
          const tmpBodyPath = path.join(
            os.tmpdir(),
            `cmux_pr_body_${Date.now()}_${Math.random().toString(36).slice(2)}.md`
          );
          await fs.writeFile(tmpBodyPath, body, "utf8");

          const { stdout, stderr } = await execAsync(
            `gh pr create --draft --title ${JSON.stringify(
              truncatedTitle
            )} --body-file ${JSON.stringify(tmpBodyPath)} --head ${JSON.stringify(
              branchName
            )} --base ${JSON.stringify(baseBranch)}`,
            {
              cwd,
              env: { ...process.env, GH_TOKEN: githubToken },
              maxBuffer: 10 * 1024 * 1024,
            }
          );
          const out = (stdout || stderr || "").trim();
          const match = out.match(/https:\/\/github\.com\/[^\s]+/);
          prUrl = match ? match[0] : out;
          // Clean up temp file
          try {
            await fs.unlink(tmpBodyPath);
          } catch (e) {
            serverLogger.error("Error cleaning up temp file:", e);
          }
        } catch (e: unknown) {
          const err = e as {
            stdout?: string;
            stderr?: string;
            message?: string;
          };
          const msg =
            err?.message || err?.stderr || err?.stdout || "unknown error";
          serverLogger.error(`[DraftPR] Failed at 'Create draft PR': ${msg}`);
          callback({
            success: false,
            error: `Failed at 'Create draft PR': ${msg}`,
          });
          return;
        }

        if (prUrl) {
          await getConvex().mutation(api.taskRuns.updatePullRequestUrl, {
            teamSlugOrId: safeTeam,
            id: run._id,
            pullRequestUrl: prUrl,
            isDraft: true,
          });
          // Update task merge status to draft PR
          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: "pr_draft",
          });
        }

        callback({ success: true, url: prUrl });
      } catch (error) {
        serverLogger.error("Error creating draft PR:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Open PR: create a non-draft PR if missing, or mark draft PR as ready
    socket.on("github-open-pr", async (data, callback) => {
      try {
        const { taskRunId } = GitHubCreateDraftPrSchema.parse(data);

        const { run, task, worktreePath, branchName, baseBranch } =
          await ensureRunWorktreeAndBranch(taskRunId, safeTeam);

        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          callback({ success: false, error: "GitHub token is not configured" });
          return;
        }

        const title = task.pullRequestTitle || task.text || "cmux changes";
        const truncatedTitle =
          title.length > 72 ? `${title.slice(0, 69)}...` : title;
        const commitMessage = `${truncatedTitle}\n\nGenerated by cmux for task ${String(task._id)}.`;
        const body = task.text || `## Summary\n\n${title}`;

        const cwd = worktreePath;
        const repoFullNameOpen = task.projectFullName || ""; // e.g. owner/name
        const [owner, repo] = repoFullNameOpen.split("/");

        // Stage/commit/push branch, similar to draft flow, but tolerant to no-op
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
          serverLogger.warn(`[OpenPR] Commit step warning: ${msg}`);
        }

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
          serverLogger.warn(`[OpenPR] Push warning: ${msg}`);
        }

        // PR resolution via helpers
        serverLogger.info(`[OpenPR] Fetching PR by head branch...`, {
          owner,
          repo,
          branchName,
          tokenPrefix: githubToken ? githubToken.substring(0, 10) : "NO_TOKEN",
        });
        const initialBasic =
          owner && repo
            ? await fetchPrByHead(githubToken, owner, repo, owner, branchName)
            : null;
        serverLogger.info(`[OpenPR] fetchPrByHead result:`, {
          found: !!initialBasic,
          number: initialBasic?.number,
          draft: initialBasic?.draft,
          state: initialBasic?.state,
        });

        let finalUrl: string | undefined;
        let finalNumber: number | undefined;
        let finalState: string | undefined; // GitHub state string
        let finalIsDraft: boolean | undefined;

        if (!initialBasic) {
          if (!owner || !repo) {
            callback({ success: false, error: "Unknown repo for task" });
            return;
          }
          try {
            const created = await createReadyPr(
              githubToken,
              owner,
              repo,
              truncatedTitle,
              branchName,
              baseBranch,
              body
            );
            finalUrl = created.html_url;
            finalNumber = created.number;
            finalState = created.state;
            finalIsDraft = !!created.draft;
          } catch (e: unknown) {
            const msg = e instanceof Error ? e.message : String(e);
            if (!/already exists/i.test(msg)) {
              serverLogger.error(`[OpenPR] Failed creating PR via API: ${msg}`);
              callback({
                success: false,
                error: `Failed to create PR: ${msg}`,
              });
              return;
            }
          }
          const latest =
            owner && repo
              ? await fetchPrByHead(githubToken, owner, repo, owner, branchName)
              : null;
          if (latest) {
            finalUrl = latest.html_url;
            finalNumber = latest.number;
            finalState = latest.state;
            finalIsDraft = !!latest.draft;
          }
        } else if (initialBasic.draft) {
          try {
            serverLogger.info(
              `[OpenPR] Attempting to mark PR #${initialBasic.number} as ready...`,
              {
                owner: owner!,
                repo: repo!,
                number: initialBasic.number,
                tokenPrefix: githubToken
                  ? githubToken.substring(0, 10)
                  : "NO_TOKEN",
              }
            );
            await markPrReady(githubToken, owner!, repo!, initialBasic.number);
            serverLogger.info(
              `[OpenPR] Successfully marked PR #${initialBasic.number} as ready for review`
            );
          } catch (e: unknown) {
            const errorMessage = e instanceof Error ? e.message : String(e);
            serverLogger.error(
              `[OpenPR] Failed to mark PR #${initialBasic.number} as ready: ${errorMessage}`
            );

            // If the PR wasn't found or there's a permission issue, fail the operation
            if (
              errorMessage.includes("not found") ||
              errorMessage.includes("404")
            ) {
              callback({
                success: false,
                error: `Pull request #${initialBasic.number} not found. It may have been deleted or you may not have access.`,
              });
              return;
            } else if (
              errorMessage.includes("Permission denied") ||
              errorMessage.includes("403")
            ) {
              callback({
                success: false,
                error: `Permission denied. Please check that your GitHub token has the required permissions.`,
              });
              return;
            } else if (
              errorMessage.includes("Authentication failed") ||
              errorMessage.includes("401")
            ) {
              callback({
                success: false,
                error: `Authentication failed. Please check that your GitHub token is valid.`,
              });
              return;
            }

            // For other errors, log but continue (e.g., if PR is already ready)
            serverLogger.warn(
              `[OpenPR] Continuing despite error: ${errorMessage}`
            );
          }
          const latest = await fetchPrByHead(
            githubToken,
            owner!,
            repo!,
            owner!,
            branchName
          );
          if (latest) {
            finalUrl = latest.html_url;
            finalNumber = latest.number;
            finalState = latest.state;
            finalIsDraft = !!latest.draft;
          }
        } else {
          // Exists but not draft; if closed, attempt reopen
          if ((initialBasic.state || "").toUpperCase() === "CLOSED") {
            try {
              await reopenPr(githubToken, owner!, repo!, initialBasic.number);
            } catch (e: unknown) {
              const msg = e instanceof Error ? e.message : String(e);
              serverLogger.warn(`[OpenPR] Failed to reopen PR via API: ${msg}`);
            }
          }
          // Reflect latest state
          const latest = await fetchPrByHead(
            githubToken,
            owner!,
            repo!,
            owner!,
            branchName
          );
          if (latest) {
            finalUrl = latest.html_url;
            finalNumber = latest.number;
            finalState = latest.state;
            finalIsDraft = !!latest.draft;
          }
        }

        // Map gh state to our union (consider merged flag)
        const stateMap = (
          s?: string,
          isDraft?: boolean,
          merged?: boolean
        ): "open" | "draft" | "merged" | "closed" | "unknown" => {
          if (merged) return "merged";
          if (isDraft) return "draft";
          switch ((s || "").toUpperCase()) {
            case "OPEN":
              return "open";
            case "MERGED":
              return "merged";
            case "CLOSED":
              return "closed";
            default:
              return "unknown";
          }
        };

        // Determine merged via detail
        let merged = false;
        if (owner && repo && finalNumber) {
          try {
            const detail = await fetchPrDetail(
              githubToken,
              owner,
              repo,
              finalNumber
            );
            merged = !!detail.merged_at;
          } catch (e) {
            serverLogger.error("Error fetching PR detail:", e);
          }
        }

        await getConvex().mutation(api.taskRuns.updatePullRequestState, {
          teamSlugOrId: safeTeam,
          id: run._id,
          state: finalUrl
            ? stateMap(finalState, finalIsDraft, merged)
            : ("none" as const),
          isDraft: finalIsDraft,
          number: finalNumber,
          url: finalUrl,
        });

        // Update task merge status based on PR state
        const prState = finalUrl
          ? stateMap(finalState, finalIsDraft, merged)
          : "none";
        let taskMergeStatus:
          | "none"
          | "pr_draft"
          | "pr_open"
          | "pr_merged"
          | "pr_closed" = "none";
        switch (prState) {
          case "draft":
            taskMergeStatus = "pr_draft";
            break;
          case "open":
            taskMergeStatus = "pr_open";
            break;
          case "merged":
            taskMergeStatus = "pr_merged";
            break;
          case "closed":
            taskMergeStatus = "pr_closed";
            break;
        }
        if (taskMergeStatus !== "none") {
          await getConvex().mutation(api.tasks.updateMergeStatus, {
            teamSlugOrId: safeTeam,
            id: task._id,
            mergeStatus: taskMergeStatus,
          });
        }

        callback({
          success: true,
          url: finalUrl,
          state: finalUrl ? stateMap(finalState, finalIsDraft, merged) : "none",
        });
      } catch (error) {
        serverLogger.error("Error opening PR:", error);
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

    socket.on("archive-task", async (data, callback) => {
      try {
        const { taskId } = ArchiveTaskSchema.parse(data);

        // Stop/pause all containers via helper (handles querying + logging)
        const results = await stopContainersForRuns(taskId, safeTeam);

        // Log summary
        const successful = results.filter((r) => r.success).length;
        const failed = results.filter((r) => !r.success).length;

        if (failed > 0) {
          serverLogger.warn(
            `Archived task ${taskId}: ${successful} containers stopped, ${failed} failed`
          );
        } else {
          serverLogger.info(
            `Successfully archived task ${taskId}: all ${successful} containers stopped`
          );
        }

        callback({ success: true });
      } catch (error) {
        serverLogger.error("Error archiving task:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });
  });
}