import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import {
  ArchiveTaskSchema,
  GitFullDiffRequestSchema,
  GitHubCreateDraftPrSchema,
  GitHubFetchBranchesSchema,
  GitHubFetchReposSchema,
  GitHubMergeBranchSchema,
  GitHubSyncPrStateSchema,
  ListFilesRequestSchema,
  OpenInEditorSchema,
  SpawnFromCommentSchema,
  StartTaskSchema,
  type AvailableEditors,
  type FileInfo,
  isLoopbackHostname,
  type IframePreflightResult,
} from "@cmux/shared";
import {
  type PullRequestActionResult,
  type StoredPullRequestInfo,
} from "@cmux/shared/pull-request-state";
import fuzzysort from "fuzzysort";
import { minimatch } from "minimatch";
import { exec, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import z from "zod";
import { spawnAllAgents } from "./agentSpawner";
import { stopContainersForRuns } from "./archiveTask";
import { execWithEnv } from "./execWithEnv";
import { getGitDiff } from "./diffs/gitDiff";
import { GitDiffManager } from "./gitDiff";
import { getRustTime } from "./native/core";
import type { RealtimeServer } from "./realtime";
import { RepositoryManager } from "./repositoryManager";
import type { GitRepoInfo } from "./server";
import { getPRTitleFromTaskDescription } from "./utils/branchNameGenerator";
import { getConvex } from "./utils/convexClient";
import { ensureRunWorktreeAndBranch } from "./utils/ensureRunWorktree";
import { serverLogger } from "./utils/fileLogger";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken";
import { createDraftPr, fetchPrDetail } from "./utils/githubPr";
import { getOctokit } from "./utils/octokit";
import { checkAllProvidersStatus } from "./utils/providerStatus";
import { refreshGitHubData } from "./utils/refreshGitHubData";
import { runWithAuth, runWithAuthToken } from "./utils/requestContext";
import { getRunBranchStatus, syncRunWithBase } from "./utils/runSync";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance";
import { getProjectPaths } from "./workspace";
import {
  collectRepoFullNamesForRun,
  EMPTY_AGGREGATE,
  loadPullRequestDetail,
  persistPullRequestResults,
  splitRepoFullName,
  toPullRequestActionResult,
} from "./pullRequestState";

const execAsync = promisify(exec);

const GitSocketDiffRequestSchema = z.object({
  headRef: z.string(),
  baseRef: z.string().optional(),
  repoFullName: z.string().optional(),
  repoUrl: z.string().optional(),
  originPathOverride: z.string().optional(),
  includeContents: z.boolean().optional(),
  maxBytes: z.number().optional(),
  lastKnownBaseSha: z.string().optional(),
  lastKnownMergeCommitSha: z.string().optional(),
});

const TaskRunSyncStatusSchema = z.object({
  taskRunId: z.string(),
});

const TaskRunSyncSchema = z.object({
  taskRunId: z.string(),
});

const IframePreflightRequestSchema = z.object({
  url: z.string().url(),
});

export function setupSocketHandlers(
  rt: RealtimeServer,
  gitDiffManager: GitDiffManager,
  defaultRepo?: GitRepoInfo | null,
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

    // Rust N-API test endpoint
    socket.on("rust-get-time", async (callback) => {
      try {
        const time = await getRustTime();
        callback({ ok: true, time });
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        callback({ ok: false, error: msg });
      }
    });

    socket.on(
      "iframe-preflight",
      async (
        rawData: unknown,
        callback: (result: IframePreflightResult) => void,
      ) => {
        const respond = (result: IframePreflightResult) => {
          callback(result);
        };

        try {
          const { url } = IframePreflightRequestSchema.parse(rawData ?? {});
          const target = new URL(url);

          if (target.protocol !== "http:" && target.protocol !== "https:") {
            respond({
              ok: false,
              status: null,
              method: null,
              error: "Only HTTP(S) URLs are supported.",
            });
            return;
          }

          if (!isLoopbackHostname(target.hostname)) {
            respond({
              ok: false,
              status: null,
              method: null,
              error:
                "Only localhost URLs can be validated via the server preflight.",
            });
            return;
          }

          const fetchMethod = "GET";

          const response = await fetch(target, {
            method: fetchMethod,
            redirect: "manual",
          });
          await response.body?.cancel().catch(() => undefined);

          if (response.ok) {
            respond({
              ok: true,
              status: response.status,
              method: fetchMethod,
            });
            return;
          }

          respond({
            ok: false,
            status: response.status,
            method: fetchMethod,
            error: `Request failed with status ${response.status}.`,
          });
        } catch (error) {
          if (error instanceof z.ZodError) {
            respond({
              ok: false,
              status: null,
              method: null,
              error: "Invalid preflight request.",
            });
            return;
          }

          const message =
            error instanceof Error
              ? error.message
              : "Unknown error during preflight.";
          respond({
            ok: false,
            status: null,
            method: null,
            error: message,
          });
        }
      },
    );

    // Send default repo info to newly connected client if available
    if (defaultRepo?.remoteName) {
      const defaultRepoData = {
        repoFullName: defaultRepo.remoteName,
        branch: defaultRepo.currentBranch || defaultRepo.defaultBranch,
        localPath: defaultRepo.path,
      };
      serverLogger.info(
        `Sending default-repo to new client ${socket.id}:`,
        defaultRepoData,
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
            "No team provided on socket handshake; skipping initial GitHub refresh",
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
            "Starting Docker container state sync after authenticated connect",
          );
          DockerVSCodeInstance.startContainerStateSync();
        });
      }
    } else if (!initialToken) {
      serverLogger.info(
        "Skipping initial GitHub refresh: no auth token on connect",
      );
    }

    socket.on("git-diff", async (data, callback) => {
      try {
        const parsed = GitSocketDiffRequestSchema.parse(data);

        if (
          !parsed.repoFullName &&
          !parsed.repoUrl &&
          !parsed.originPathOverride
        ) {
          throw new Error(
            "repoFullName, repoUrl, or originPathOverride is required",
          );
        }

        const diffs = await getGitDiff({
          headRef: parsed.headRef,
          baseRef: parsed.baseRef,
          repoFullName: parsed.repoFullName,
          repoUrl: parsed.repoUrl,
          originPathOverride: parsed.originPathOverride,
          includeContents: parsed.includeContents ?? true,
          maxBytes: parsed.maxBytes,
          teamSlugOrId: safeTeam,
          lastKnownBaseSha: parsed.lastKnownBaseSha,
          lastKnownMergeCommitSha: parsed.lastKnownMergeCommitSha,
        });

        if (parsed.originPathOverride) {
          const workspacePath = parsed.originPathOverride;
          try {
            void gitDiffManager.watchWorkspace(workspacePath, () => {
              rt.emit("git-file-changed", {
                workspacePath,
                filePath: "",
              });
            });
          } catch (e) {
            serverLogger.warn(
              `Failed to start watcher for ${parsed.originPathOverride}: ${String(e)}`,
            );
          }
        }

        callback?.({ ok: true, diffs });
      } catch (error) {
        serverLogger.error("Error in git-diff:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
          diffs: [],
        });
      }
    });

    socket.on("task-run-sync-status", async (data, callback) => {
      try {
        const { taskRunId } = TaskRunSyncStatusSchema.parse(data ?? {});
        const status = await getRunBranchStatus({
          taskRunId: taskRunId as Id<"taskRuns">,
          teamSlugOrId: safeTeam,
        });
        callback?.({ ok: true, status });
      } catch (error) {
        serverLogger.error("Error in task-run-sync-status:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("task-run-sync", async (data, callback) => {
      try {
        const { taskRunId } = TaskRunSyncSchema.parse(data ?? {});
        const result = await syncRunWithBase({
          taskRunId: taskRunId as Id<"taskRuns">,
          teamSlugOrId: safeTeam,
        });
        callback?.(result);
      } catch (error) {
        serverLogger.error("Error in task-run-sync:", error);
        callback?.({
          ok: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

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
      const taskDataParseResult = StartTaskSchema.safeParse(data);
      if (!taskDataParseResult.success) {
        serverLogger.error(
          "Task data failed schema validation:",
          taskDataParseResult.error,
        );
        callback({
          taskId: data.taskId,
          error: "Task data failed schema validation",
        });
        return;
      }
      const taskData = taskDataParseResult.data;
      serverLogger.info("starting task!", taskData);
      const taskId = taskData.taskId;
      try {
        // For local mode, ensure Docker is running before attempting to spawn
        if (!taskData.isCloudMode) {
          try {
            const { checkDockerStatus } = await import(
              "@cmux/shared/providers/common/check-docker"
            );
            const docker = await checkDockerStatus();
            if (!docker.isRunning) {
              callback({
                taskId,
                error:
                  "Docker is not running. Please start Docker Desktop or switch to Cloud mode.",
              });
              return;
            }
          } catch (e) {
            serverLogger.warn(
              "Failed to verify Docker status before start-task",
              e,
            );
            callback({
              taskId,
              error:
                "Unable to verify Docker status. Ensure Docker is running or switch to Cloud mode.",
            });
            return;
          }
        }

        callback({
          taskId,
        });

        (async () => {
          try {
            // Generate PR title early from the task description
            let generatedTitle: string | null = null;
            try {
              generatedTitle = await getPRTitleFromTaskDescription(
                taskData.taskDescription,
                safeTeam,
              );
              // Persist to Convex immediately
              await getConvex().mutation(api.tasks.setPullRequestTitle, {
                teamSlugOrId: safeTeam,
                id: taskId,
                pullRequestTitle: generatedTitle,
              });
              serverLogger.info(
                `[Server] Saved early PR title: ${generatedTitle}`,
              );
            } catch (e) {
              serverLogger.error(
                `[Server] Failed generating/saving early PR title:`,
                e,
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
                environmentId: taskData.environmentId,
              },
              safeTeam,
            );

            // Check if at least one agent spawned successfully
            const successfulAgents = agentResults.filter(
              (result) => result.success,
            );
            if (successfulAgents.length === 0) {
              const errors = agentResults
                .filter((r) => !r.success)
                .map((r) => `${r.agentName}: ${r.error || "Unknown error"}`)
                .join("; ");
              serverLogger.error(
                `Failed to spawn any agents for task ${taskId}:`,
                errors,
              );
              rt.emit("task-failed", {
                taskId,
                error: errors || "Failed to spawn any agents",
              });
              return;
            }

            // Log results for debugging
            agentResults.forEach((result) => {
              if (result.success) {
                serverLogger.info(
                  `Successfully spawned ${result.agentName} with terminal ${result.terminalId}`,
                );
                if (result.vscodeUrl) {
                  serverLogger.info(
                    `VSCode URL for ${result.agentName}: ${result.vscodeUrl}`,
                  );
                }
              } else {
                serverLogger.error(
                  `Failed to spawn ${result.agentName}: ${result.error}`,
                );
              }
            });

            // Return the first successful agent's info (you might want to modify this to return all)
            const primaryAgent = successfulAgents[0];

            // Emit task-started event with full data
            const taskStartedPayload = {
              taskId,
              worktreePath: primaryAgent.worktreePath,
              terminalId: primaryAgent.terminalId,
            };
            rt.emit("task-started", taskStartedPayload);

            // Emit VSCode URL if available
            if (primaryAgent.vscodeUrl) {
              rt.emit("vscode-spawned", {
                instanceId: primaryAgent.terminalId,
                url: primaryAgent.vscodeUrl.replace(
                  "/?folder=/root/workspace",
                  "",
                ),
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
                },
              );
            } catch (error) {
              serverLogger.warn(
                "Could not set up file watching for workspace:",
                error,
              );
              // Continue without file watching
            }

          } catch (error) {
            serverLogger.error("Error spawning agents for task:", error);
            rt.emit("task-failed", {
              taskId,
              error: error instanceof Error ? error.message : "Unknown error",
            });
          }
        })();
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
        const { taskRunId } = GitHubSyncPrStateSchema.parse(data);

        const run = await getConvex().query(api.taskRuns.get, {
          teamSlugOrId: safeTeam,
          id: taskRunId,
        });
        if (!run) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "Task run not found",
          });
          return;
        }

        const task = await getConvex().query(api.tasks.getById, {
          teamSlugOrId: safeTeam,
          id: run.taskId,
        });
        if (!task) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "Task not found",
          });
          return;
        }

        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "GitHub token is not configured",
          });
          return;
        }

        const repoFullNames = await collectRepoFullNamesForRun(
          run,
          task,
          safeTeam,
        );
        if (repoFullNames.length === 0) {
          callback({
            success: true,
            results: [],
            aggregate: EMPTY_AGGREGATE,
          });
          return;
        }

        const existingByRepo = new Map(
          (run.pullRequests ?? []).map(
            (record) => [record.repoFullName, record] as const,
          ),
        );

        const results = await Promise.all(
          repoFullNames.map(async (repoFullName) => {
            try {
              const split = splitRepoFullName(repoFullName);
              if (!split) {
                throw new Error(`Invalid repository name: ${repoFullName}`);
              }
              const { owner, repo } = split;
              const existingRecord = existingByRepo.get(repoFullName);

              const detail = await loadPullRequestDetail({
                token: githubToken,
                repoFullName,
                owner,
                repo,
                branchName: run.newBranch ?? "",
                number: existingRecord?.number,
              });

              if (!detail) {
                return {
                  repoFullName,
                  url: undefined,
                  number: undefined,
                  state: "none",
                  isDraft: undefined,
                } satisfies PullRequestActionResult;
              }

              return toPullRequestActionResult(repoFullName, detail);
            } catch (error) {
              const message =
                error instanceof Error ? error.message : String(error);
              return {
                repoFullName,
                url: undefined,
                number: undefined,
                state: "unknown",
                isDraft: undefined,
                error: message,
              } satisfies PullRequestActionResult;
            }
          }),
        );

        const persisted = await persistPullRequestResults({
          teamSlugOrId: safeTeam,
          run,
          task,
          repoFullNames,
          results,
        });

        const errors = results
          .filter((result) => result.error)
          .map((result) => `${result.repoFullName}: ${result.error}`);

        callback({
          success: errors.length === 0,
          results,
          aggregate: persisted.aggregate,
          error: errors.length > 0 ? errors.join("; ") : undefined,
        });
      } catch (error) {
        serverLogger.error("Error syncing PR state:", error);
        callback({
          success: false,
          results: [],
          aggregate: EMPTY_AGGREGATE,
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

          const existingRecords = run.pullRequests ?? [];
          const updatedRecords: StoredPullRequestInfo[] =
            existingRecords.length > 0
              ? existingRecords.map((record) =>
                record.repoFullName === repoFullName
                  ? {
                    ...record,
                    state: "merged",
                    isDraft: false,
                  }
                  : record,
              )
              : [
                {
                  repoFullName,
                  url:
                    run.pullRequestUrl && run.pullRequestUrl !== "pending"
                      ? run.pullRequestUrl
                      : undefined,
                  number: run.pullRequestNumber ?? undefined,
                  state: "merged",
                  isDraft: false,
                },
              ];

          await getConvex().mutation(api.taskRuns.updatePullRequestState, {
            teamSlugOrId: safeTeam,
            id: run._id,
            state: "merged",
            isDraft: false,
            pullRequests: updatedRecords,
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
              `Error opening ${editor}: process exited with code ${code}`,
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
          environmentId,
        } = ListFilesRequestSchema.parse(data);
        const repoManager = RepositoryManager.getInstance();

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
          baseDir: string,
        ): Promise<FileInfo[]> {
          const files: FileInfo[] = [];

          try {
            const entries = await fs.readdir(dir, { withFileTypes: true });

            for (const entry of entries) {
              const fullPath = path.join(dir, entry.name);
              const relativePath = path.relative(baseDir, fullPath);

              const shouldIgnore = ignoredPatterns.some(
                (ignorePattern) =>
                  minimatch(relativePath, ignorePattern) ||
                  minimatch(fullPath, ignorePattern),
              );

              if (shouldIgnore) continue;

              if (entry.isDirectory() && !pattern) {
                files.push({
                  path: fullPath,
                  name: entry.name,
                  isDirectory: true,
                  relativePath,
                });
              }

              if (entry.isDirectory()) {
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

        const listFilesForRepo = async ({
          targetRepoUrl,
          repoFullName,
          branchOverride,
        }: {
          targetRepoUrl: string;
          repoFullName?: string;
          branchOverride?: string;
        }): Promise<FileInfo[]> => {
          const projectPaths = await getProjectPaths(targetRepoUrl, safeTeam);

          await fs.mkdir(projectPaths.projectPath, { recursive: true });
          await fs.mkdir(projectPaths.worktreesPath, { recursive: true });

          await repoManager.ensureRepository(
            targetRepoUrl,
            projectPaths.originPath,
          );

          const baseBranch =
            branchOverride ||
            (await repoManager.getDefaultBranch(projectPaths.originPath));

          await repoManager.ensureRepository(
            targetRepoUrl,
            projectPaths.originPath,
            baseBranch,
          );

          const worktreeInfo = {
            ...projectPaths,
            worktreePath: `${projectPaths.worktreesPath}/${baseBranch}`,
            branch: baseBranch,
          } as const;

          try {
            await fs.access(worktreeInfo.originPath);
          } catch {
            serverLogger.error(
              "Origin directory does not exist:",
              worktreeInfo.originPath,
            );
            return [];
          }

          let fileList = await walkDir(
            worktreeInfo.originPath,
            worktreeInfo.originPath,
          );

          if (pattern) {
            const filePaths = fileList.map((f) => f.relativePath);
            const results = fuzzysort.go(pattern, filePaths, {
              threshold: -10000,
              limit: 1000,
            });
            const fileMap = new Map(fileList.map((f) => [f.relativePath, f]));

            fileList = results
              .map((result) => fileMap.get(result.target)!)
              .filter(Boolean);
          } else {
            fileList.sort((a, b) => {
              if (a.isDirectory && !b.isDirectory) return -1;
              if (!a.isDirectory && b.isDirectory) return 1;
              return a.relativePath.localeCompare(b.relativePath);
            });
          }

          if (repoFullName) {
            return fileList.map((file) => ({
              ...file,
              repoFullName,
              relativePath: `${repoFullName}/${file.relativePath}`,
            }));
          }

          return fileList;
        };

        if (environmentId) {
          const environment = await getConvex().query(api.environments.get, {
            teamSlugOrId: safeTeam,
            id: environmentId,
          });

          if (!environment) {
            socket.emit("list-files-response", {
              files: [],
              error: "Environment not found",
            });
            return;
          }

          const repoFullNames = (environment.selectedRepos || [])
            .map((repo) => repo?.trim())
            .filter((repo): repo is string => Boolean(repo));

          if (repoFullNames.length === 0) {
            socket.emit("list-files-response", {
              files: [],
              error: "This environment has no repositories configured",
            });
            return;
          }

          const aggregatedFiles: FileInfo[] = [];

          for (const repoFullName of repoFullNames) {
            try {
              const files = await listFilesForRepo({
                targetRepoUrl: `https://github.com/${repoFullName}.git`,
                repoFullName,
              });
              aggregatedFiles.push(...files);
            } catch (error) {
              serverLogger.error(
                `Failed to list files for environment repo ${repoFullName}:`,
                error,
              );
            }
          }

          socket.emit("list-files-response", { files: aggregatedFiles });
          return;
        }

        if (repoUrl) {
          const fileList = await listFilesForRepo({
            targetRepoUrl: repoUrl,
            branchOverride: branch,
          });
          socket.emit("list-files-response", { files: fileList });
          return;
        }

        socket.emit("list-files-response", {
          files: [],
          error: "Repository information missing",
        });
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
            (r) => r.stdout,
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
        const hasRepos = await getConvex().query(api.github.hasReposForTeam, {
          teamSlugOrId,
        });

        if (hasRepos) {
          // If we have repos, return them and refresh in the background
          const reposByOrg = await getConvex().query(api.github.getReposByOrg, {
            teamSlugOrId,
          });
          callback({ success: true, repos: reposByOrg });

          // Refresh in the background to add any new repos
          runWithAuthToken(initialToken, () =>
            refreshGitHubData({ teamSlugOrId }).catch((error) => {
              serverLogger.error("Background refresh failed:", error);
            }),
          );
          return;
        }

        // If no repos exist, do a full fetch
        await runWithAuthToken(initialToken, () =>
          refreshGitHubData({ teamSlugOrId }),
        );
        const reposByOrg = await getConvex().query(api.github.getReposByOrg, {
          teamSlugOrId,
        });
        callback({ success: true, repos: reposByOrg });
      } catch (error) {
        serverLogger.error("Error fetching repos:", error);
        callback({
          success: false,
          error: `Failed to fetch GitHub repos: ${error instanceof Error ? error.message : String(error)
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
          safeTeam,
        );

        // Check if at least one agent spawned successfully
        const successfulAgents = agentResults.filter(
          (result) => result.success,
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
        const { repo } = GitHubFetchBranchesSchema.parse(data);

        const { listRemoteBranches } = await import("./native/git.js");
        const branches = await listRemoteBranches({ repoFullName: repo });
        const defaultBranch = branches.find((branch) => branch.isDefault)?.name;

        callback({
          success: true,
          branches,
          defaultBranch,
        });
        return;
      } catch (error) {
        serverLogger.error("Error fetching branches:", error);
        callback({
          success: false,
          branches: [],
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    // Create a draft PR for a crowned run: commits, pushes, then creates a draft PR
    socket.on("github-create-draft-pr", async (data, callback) => {
      try {
        const { taskRunId } = GitHubCreateDraftPrSchema.parse(data);

        const run = await getConvex().query(api.taskRuns.get, {
          teamSlugOrId: safeTeam,
          id: taskRunId,
        });
        if (!run) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "Task run not found",
          });
          return;
        }

        const task = await getConvex().query(api.tasks.getById, {
          teamSlugOrId: safeTeam,
          id: run.taskId,
        });
        if (!task) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "Task not found",
          });
          return;
        }

        const branchName = run.newBranch?.trim();
        if (!branchName) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "Missing branch name for run",
          });
          return;
        }

        const githubToken = await getGitHubTokenFromKeychain();
        if (!githubToken) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "GitHub token is not configured",
          });
          return;
        }

        const repoFullNames = await collectRepoFullNamesForRun(
          run,
          task,
          safeTeam,
        );
        if (repoFullNames.length === 0) {
          callback({
            success: false,
            results: [],
            aggregate: EMPTY_AGGREGATE,
            error: "No repositories configured for this run",
          });
          return;
        }

        const baseBranch = task.baseBranch?.trim() || "main";
        const title = task.pullRequestTitle || task.text || "cmux changes";
        const truncatedTitle =
          title.length > 72 ? `${title.slice(0, 69)}...` : title;
        const body =
          task.text ||
          `## Summary

${title}`;

        const existingByRepo = new Map(
          (run.pullRequests ?? []).map(
            (record) => [record.repoFullName, record] as const,
          ),
        );

        const results = await Promise.all(
          repoFullNames.map(async (repoFullName) => {
            try {
              const split = splitRepoFullName(repoFullName);
              if (!split) {
                throw new Error(`Invalid repository name: ${repoFullName}`);
              }
              const { owner, repo } = split;
              const existingRecord = existingByRepo.get(repoFullName);
              const existingNumber = existingRecord?.number;

              let detail = await loadPullRequestDetail({
                token: githubToken,
                repoFullName,
                owner,
                repo,
                branchName,
                number: existingNumber,
              });

              if (!detail) {
                const created = await createDraftPr(
                  githubToken,
                  owner,
                  repo,
                  truncatedTitle,
                  branchName,
                  baseBranch,
                  body,
                );
                detail =
                  (await fetchPrDetail(
                    githubToken,
                    owner,
                    repo,
                    created.number,
                  ).catch(() => null)) ??
                  ({
                    ...created,
                    merged_at: null,
                  } as Awaited<ReturnType<typeof fetchPrDetail>>);
              }

              return toPullRequestActionResult(repoFullName, detail);
            } catch (error) {
              const message =
                error instanceof Error ? error.message : String(error);
              return {
                repoFullName,
                url: undefined,
                number: undefined,
                state: "none",
                isDraft: undefined,
                error: message,
              } satisfies PullRequestActionResult;
            }
          }),
        );

        const persisted = await persistPullRequestResults({
          teamSlugOrId: safeTeam,
          run,
          task,
          repoFullNames,
          results,
        });

        const errors = results
          .filter((result) => result.error)
          .map((result) => `${result.repoFullName}: ${result.error}`);

        callback({
          success: errors.length === 0,
          results,
          aggregate: persisted.aggregate,
          error: errors.length > 0 ? errors.join("; ") : undefined,
        });
      } catch (error) {
        serverLogger.error("Error creating draft PR:", error);
        callback({
          success: false,
          results: [],
          aggregate: EMPTY_AGGREGATE,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });


    socket.on("check-provider-status", async (callback) => {
      try {
        const status = await checkAllProvidersStatus({
          teamSlugOrId: safeTeam,
        });
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
            `Archived task ${taskId}: ${successful} containers stopped, ${failed} failed`,
          );
        } else {
          serverLogger.info(
            `Successfully archived task ${taskId}: all ${successful} containers stopped`,
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
