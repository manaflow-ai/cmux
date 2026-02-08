import { api } from "@cmux/convex/api";
import { env } from "./utils/server-env";
import type { Id } from "@cmux/convex/dataModel";
import type { WorkspaceConfigResponse } from "@cmux/www-openapi-client";
import type { WorkerSyncFiles } from "@cmux/shared/worker-schemas";
import {
  ArchiveTaskSchema,
  GitFullDiffRequestSchema,
  GitHubCreateDraftPrSchema,
  GitHubFetchReposSchema,
  GitHubMergeBranchSchema,
  GitHubSyncPrStateSchema,
  ListFilesRequestSchema,
  OpenInEditorSchema,
  SpawnFromCommentSchema,
  StartTaskSchema,
  CreateLocalWorkspaceSchema,
  type CreateLocalWorkspaceResponse,
  CreateCloudWorkspaceSchema,
  type CreateCloudWorkspaceResponse,
  TriggerLocalCloudSyncSchema,
  type TriggerLocalCloudSyncResponse,
  type AvailableEditors,
  type FileInfo,
  isLoopbackHostname,
  LOCAL_VSCODE_PLACEHOLDER_ORIGIN,
  type IframePreflightResult,
} from "@cmux/shared";
import {
  type PullRequestActionResult,
  type StoredPullRequestInfo,
} from "@cmux/shared/pull-request-state";
import fuzzysort from "fuzzysort";
import { parse as parseDotenv } from "dotenv";
import { minimatch } from "minimatch";
import { exec, execFile, spawn } from "node:child_process";
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
import { localCloudSyncManager } from "./localCloudSync";
import {
  generateBranchNamesFromDescription,
  generatePRInfoAndBranchNames,
} from "./utils/branchNameGenerator";
import { getConvex } from "./utils/convexClient";
import { ensureRunWorktreeAndBranch } from "./utils/ensureRunWorktree";
import { serverLogger } from "./utils/fileLogger";
import { getGitHubOAuthToken } from "./utils/getGitHubToken";
import { createDraftPr, fetchPrDetail } from "./utils/githubPr";
import { getOctokit } from "./utils/octokit";
import {
  checkAllProvidersStatus,
  checkAllProvidersStatusWebMode,
} from "./utils/providerStatus";
import { refreshGitHubData } from "./utils/refreshGitHubData";
import { runWithAuth, runWithAuthToken } from "./utils/requestContext";
import { extractSandboxStartError } from "./utils/sandboxErrors";
import { getWwwClient } from "./utils/wwwClient";
import { getWwwOpenApiModule } from "./utils/wwwOpenApiModule";
import { CmuxVSCodeInstance } from "./vscode/CmuxVSCodeInstance";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance";
import { VSCodeInstance } from "./vscode/VSCodeInstance";
import {
  getVSCodeServeWebBaseUrl,
  getVSCodeServeWebPort,
  waitForVSCodeServeWebBaseUrl,
  getLastVSCodeDetectionResult,
  refreshVSCodeDetection,
} from "./vscode/serveWeb";
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
const execFileAsync = promisify(execFile);

interface ExecError extends Error {
  stderr?: string;
  stdout?: string;
}

const isWindows = process.platform === "win32";

const DOCKER_PULL_TIMEOUT_MS = 10 * 60 * 1000;
const DOCKER_PULL_PROGRESS_THROTTLE_MS = 2_000;

type DockerPullProgressEvent = {
  status?: string;
  progress?: string;
  id?: string;
  progressDetail?: {
    current?: number;
    total?: number;
  };
};

function isMutableDockerTag(imageName: string): boolean {
  const digestSeparatorIndex = imageName.indexOf("@");
  if (digestSeparatorIndex !== -1) {
    return false;
  }

  const lastSlashIndex = imageName.lastIndexOf("/");
  const lastColonIndex = imageName.lastIndexOf(":");

  // No colon means no explicit tag, which is implicitly :latest.
  if (lastColonIndex === -1) {
    return true;
  }

  // If the last colon appears before the last slash, it belongs to the registry port.
  if (lastColonIndex < lastSlashIndex) {
    return true;
  }

  const tag = imageName.slice(lastColonIndex + 1);
  return tag === "latest";
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / Math.pow(1024, exponent);
  return `${value.toFixed(value >= 10 ? 1 : 2)}${units[exponent]}`;
}

function collectWorktreePaths(nodes: unknown): string[] {
  const paths = new Set<string>();

  const walk = (entries: unknown): void => {
    if (!Array.isArray(entries)) return;
    for (const entry of entries) {
      if (typeof entry !== "object" || entry === null) continue;
      const worktreePath = Reflect.get(Object(entry), "worktreePath");
      if (typeof worktreePath === "string" && worktreePath.trim().length > 0) {
        paths.add(worktreePath);
      }
      const children = Reflect.get(Object(entry), "children");
      walk(children);
    }
  };

  walk(nodes);
  return Array.from(paths);
}

function sanitizeShellPath(candidate: string | undefined | null): string | null {
  if (!candidate) {
    return null;
  }
  const trimmed = candidate.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function getUserLoginShell(): string {
  const override = sanitizeShellPath(process.env.CMUX_LOGIN_SHELL);
  if (override) {
    return override;
  }

  if (!isWindows) {
    try {
      const userShell = sanitizeShellPath(os.userInfo().shell);
      if (userShell) {
        return userShell;
      }
    } catch {
      // Ignore failures – we'll fall back to other sources.
    }

    const envShell = sanitizeShellPath(process.env.SHELL);
    if (envShell) {
      return envShell;
    }

    return "/bin/zsh";
  }

  const envShell = sanitizeShellPath(process.env.SHELL);
  if (envShell) {
    return envShell;
  }

  const comspec = sanitizeShellPath(process.env.COMSPEC);
  if (comspec) {
    return comspec;
  }

  return "cmd.exe";
}

function buildLoginShellArgs(
  shellPath: string,
  command: string
): string[] {
  if (isWindows) {
    const normalized = shellPath.toLowerCase();
    if (normalized.includes("powershell") || normalized.includes("pwsh")) {
      // PowerShell prefers -Command and does not distinguish login shells.
      return ["-Command", command];
    }

    if (normalized.endsWith("cmd.exe")) {
      return ["/d", "/c", command];
    }

    // Fall back to POSIX-style flags (e.g., Git Bash on Windows).
    return ["-l", "-c", command];
  }

  // Use interactive login shells so ~/.zshrc, ~/.bashrc, etc. run and populate
  // PATH the same way users expect in their terminals.
  return ["-l", "-i", "-c", command];
}

function isExecError(error: unknown): error is ExecError {
  return (
    typeof error === "object" &&
    error !== null &&
    ("stderr" in error || "stdout" in error)
  );
}

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

const IframePreflightRequestSchema = z.object({
  url: z.string().url(),
});

function buildServeWebWorkspaceUrl(
  baseUrl: string,
  folderPath: string
): string {
  const workspaceUrl = new URL(baseUrl);
  workspaceUrl.searchParams.set("folder", folderPath);
  return workspaceUrl.toString();
}

function buildPlaceholderWorkspaceUrl(folderPath: string): string {
  return buildServeWebWorkspaceUrl(LOCAL_VSCODE_PLACEHOLDER_ORIGIN, folderPath);
}

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
    let currentAuthToken = token;
    let currentAuthHeaderJson = tokenJson;

    // authenticate the token
    if (!token) {
      // disconnect the socket
      socket.disconnect();
      return;
    }

    socket.use((_, next) => {
      runWithAuth(currentAuthToken, currentAuthHeaderJson, () => next());
    });
    serverLogger.info("Client connected:", socket.id);

    socket.on("authenticate", (data, callback) => {
      const nextToken = data?.authToken;
      if (!nextToken) {
        callback?.({ ok: false, error: "Missing auth token" });
        return;
      }
      const nextAuthJson = data?.authJson;
      currentAuthToken = nextToken;
      currentAuthHeaderJson = nextAuthJson;
      runWithAuth(currentAuthToken, currentAuthHeaderJson, () => {
        callback?.({ ok: true });
      });
    });

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
        callback: (result: IframePreflightResult) => void
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
      }
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
      // Skip in web mode since Docker is not used
      if (!dockerEventsStarted && !env.NEXT_PUBLIC_WEB_MODE) {
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

    socket.on("git-diff", async (data, callback) => {
      try {
        const parsed = GitSocketDiffRequestSchema.parse(data);

        if (
          !parsed.repoFullName &&
          !parsed.repoUrl &&
          !parsed.originPathOverride
        ) {
          throw new Error(
            "repoFullName, repoUrl, or originPathOverride is required"
          );
        }

        const diffs = await runWithAuth(
          currentAuthToken,
          currentAuthHeaderJson,
          () =>
            getGitDiff({
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
            })
        );

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
              `Failed to start watcher for ${parsed.originPathOverride}: ${String(e)}`
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

    void (async () => {
      // In web mode, skip detecting local editors entirely
      if (env.NEXT_PUBLIC_WEB_MODE) {
        const emptyAvailability: AvailableEditors = {
          vscode: false,
          cursor: false,
          windsurf: false,
          finder: false,
          iterm: false,
          terminal: false,
          ghostty: false,
          alacritty: false,
          xcode: false,
        };
        socket.emit("available-editors", emptyAvailability);
        return;
      }

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
          taskDataParseResult.error
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
        // In web mode, local (Docker) tasks are not supported
        if (env.NEXT_PUBLIC_WEB_MODE && !taskData.isCloudMode) {
          callback({
            taskId,
            error: "Local mode is not available in the web version. Please use Cloud mode.",
          });
          return;
        }

        // For local mode, ensure Docker is running and image is available before attempting to spawn
        if (!taskData.isCloudMode) {
          const updateTaskRunStatusMessage = async (
            message: string | undefined
          ): Promise<void> => {
            if (!taskData.taskRunIds || taskData.taskRunIds.length === 0) {
              return;
            }
            try {
              await Promise.all(
                taskData.taskRunIds.map((taskRunId) =>
                  getConvex().mutation(api.taskRuns.updateVSCodeStatusMessage, {
                    teamSlugOrId: safeTeam,
                    id: taskRunId,
                    statusMessage: message,
                  })
                )
              );
            } catch (error) {
              console.error(
                "[start-task] Failed to update VSCode status message",
                error
              );
              serverLogger.warn(
                "[start-task] Failed to update VSCode status message",
                error
              );
            }
          };

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

            const imageName =
              docker.workerImage?.name ||
              process.env.WORKER_IMAGE_NAME ||
              "docker.io/manaflow/cmux:latest";
            const dockerClient = DockerVSCodeInstance.getDocker();
            const shouldForcePull = isMutableDockerTag(imageName);
            let imageAvailableAfterWait = false;

            if (docker.workerImage?.isPulling) {
              serverLogger.info(
                `Docker image "${imageName}" is currently being pulled, waiting for completion...`
              );
              rt.emit("docker-pull-progress", {
                imageName,
                status: "Waiting for existing pull",
                phase: "waiting",
              });
              await updateTaskRunStatusMessage(
                `Waiting for Docker image pull: ${imageName}`
              );

              const deadline = Date.now() + DOCKER_PULL_TIMEOUT_MS;
              let lastStatusUpdate = 0;
              while (Date.now() < deadline) {
                try {
                  await dockerClient.getImage(imageName).inspect();
                  imageAvailableAfterWait = true;
                  await updateTaskRunStatusMessage(undefined);
                  break;
                } catch (error) {
                  const now = Date.now();
                  if (now - lastStatusUpdate > DOCKER_PULL_PROGRESS_THROTTLE_MS) {
                    lastStatusUpdate = now;
                    await updateTaskRunStatusMessage(
                      `Waiting for Docker image pull: ${imageName}`
                    );
                  }
                  await sleep(2_000);
                }
              }

              if (Date.now() >= deadline) {
                await updateTaskRunStatusMessage(undefined);
                callback({
                  taskId,
                  error: `Timed out waiting for Docker image "${imageName}" to finish pulling.`,
                });
                return;
              }
            }

            if (!docker.workerImage?.isAvailable || shouldForcePull) {
              serverLogger.info(
                `Ensuring Docker image "${imageName}" is pulled before starting task`
              );
              rt.emit("docker-pull-progress", {
                imageName,
                status: "Starting pull",
                phase: "pulling",
              });
              await updateTaskRunStatusMessage(
                `Pulling Docker image: ${imageName}`
              );

              try {
                const stream = await dockerClient.pull(imageName);
                let lastProgressUpdate = 0;
                let lastStatus = "";
                let lastAggregatePercent = -1;
                let lastAggregateProgress = "";
                const layerStats = new Map<
                  string,
                  { current: number; total: number }
                >();

                await new Promise<void>((resolve, reject) => {
                  const timeoutId = setTimeout(() => {
                    reject(
                      new Error(
                        `Docker pull timed out after ${DOCKER_PULL_TIMEOUT_MS / 1000 / 60} minutes`
                      )
                    );
                  }, DOCKER_PULL_TIMEOUT_MS);

                  dockerClient.modem.followProgress(
                    stream,
                    (err: Error | null) => {
                      clearTimeout(timeoutId);
                      if (err) {
                        reject(err);
                      } else {
                        resolve();
                      }
                    },
                    (event: DockerPullProgressEvent) => {
                      if (!event.status) {
                        return;
                      }

                      const now = Date.now();
                      if (
                        event.id &&
                        typeof event.progressDetail?.current === "number" &&
                        typeof event.progressDetail?.total === "number" &&
                        event.progressDetail.total > 0
                      ) {
                        const previous = layerStats.get(event.id);
                        const current = Math.max(
                          previous?.current ?? 0,
                          event.progressDetail.current
                        );
                        layerStats.set(event.id, {
                          current,
                          total: event.progressDetail.total,
                        });
                      }

                      let aggregateCurrent = 0;
                      let aggregateTotal = 0;
                      for (const layer of layerStats.values()) {
                        aggregateTotal += layer.total;
                        aggregateCurrent += Math.min(layer.current, layer.total);
                      }

                      let percent =
                        aggregateTotal > 0
                          ? Math.round((aggregateCurrent / aggregateTotal) * 100)
                          : undefined;
                      if (percent !== undefined && percent >= 100) {
                        percent = 99;
                      }
                      const safePercent =
                        percent !== undefined
                          ? Math.max(percent, lastAggregatePercent)
                          : undefined;
                      const aggregateProgress =
                        aggregateTotal > 0
                          ? `${formatBytes(aggregateCurrent)}/${formatBytes(
                              aggregateTotal
                            )}`
                          : "";

                      const shouldEmit =
                        event.status !== lastStatus ||
                        (safePercent !== undefined &&
                          safePercent !== lastAggregatePercent) ||
                        aggregateProgress !== lastAggregateProgress ||
                        now - lastProgressUpdate > DOCKER_PULL_PROGRESS_THROTTLE_MS;

                      if (shouldEmit) {
                        lastStatus = event.status;
                        lastProgressUpdate = now;
                        if (safePercent !== undefined) {
                          lastAggregatePercent = safePercent;
                        }
                        if (aggregateProgress) {
                          lastAggregateProgress = aggregateProgress;
                        }
                        rt.emit("docker-pull-progress", {
                          imageName,
                          status: event.status,
                          progress: aggregateProgress || event.progress,
                          id: event.id,
                          current:
                            aggregateTotal > 0 ? aggregateCurrent : undefined,
                          total: aggregateTotal > 0 ? aggregateTotal : undefined,
                          percent: safePercent,
                          phase: "pulling",
                        });
                        void updateTaskRunStatusMessage(
                          `Pulling Docker image: ${event.status}${event.id ? ` (${event.id})` : ""}`
                        );
                      }
                    }
                  );
                });

                await updateTaskRunStatusMessage(undefined);
                rt.emit("docker-pull-progress", {
                  imageName,
                  status: "Pull complete",
                  percent: 100,
                  phase: "complete",
                });
                serverLogger.info(
                  `Successfully pulled Docker image: ${imageName}`
                );
              } catch (pullError) {
                console.error("Error auto-pulling Docker image:", pullError);
                serverLogger.error(
                  "Error auto-pulling Docker image:",
                  pullError
                );
                rt.emit("docker-pull-progress", {
                  imageName,
                  status: "Pull failed",
                  phase: "error",
                });
                await updateTaskRunStatusMessage(undefined);
                const errorMessage =
                  pullError instanceof Error
                    ? pullError.message
                    : "Unknown error";
                callback({
                  taskId,
                  error: `Failed to pull Docker image "${imageName}": ${errorMessage}`,
                });
                return;
              }
            } else if (imageAvailableAfterWait) {
              rt.emit("docker-pull-progress", {
                imageName,
                status: "Pull complete",
                percent: 100,
                phase: "complete",
              });
            }
          } catch (e) {
            console.error(
              "Failed to verify Docker status before start-task",
              e
            );
            serverLogger.warn(
              "Failed to verify Docker status before start-task",
              e
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
            // Determine number of agents to spawn
            const agentCount = taskData.selectedAgents?.length || 1;

            // Generate branch names INSTANTLY (~0ms) from task description
            // instead of waiting ~20s for AI-generated names
            const branchNames = generateBranchNamesFromDescription(
              taskData.taskDescription,
              agentCount
            );
            serverLogger.info(
              `[Server] Generated ${branchNames.length} deterministic branch names instantly`
            );

            // Fire-and-forget: generate AI PR title asynchronously
            // This doesn't block agent spawning
            void (async () => {
              try {
                const prInfo = await generatePRInfoAndBranchNames(
                  taskData.taskDescription,
                  agentCount,
                  safeTeam
                );
                await getConvex().mutation(api.tasks.setPullRequestTitle, {
                  teamSlugOrId: safeTeam,
                  id: taskId,
                  pullRequestTitle: prInfo.prTitle,
                });
                serverLogger.info(
                  `[Server] AI-generated PR title saved: "${prInfo.prTitle}"`
                );
              } catch (e) {
                serverLogger.error(
                  `[Server] Failed generating PR title (non-blocking):`,
                  e
                );
              }
            })();

            // Spawn all agents immediately with deterministic branch names
            // - If taskRunIds provided, uses pre-created runs (fast path)
            const agentResults = await spawnAllAgents(
              taskId,
              {
                repoUrl: taskData.repoUrl,
                branch: taskData.branch,
                taskDescription: taskData.taskDescription,
                branchNames,
                selectedAgents: taskData.selectedAgents,
                taskRunIds: taskData.taskRunIds,
                isCloudMode: taskData.isCloudMode,
                images: taskData.images,
                theme: taskData.theme,
                environmentId: taskData.environmentId,
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
              serverLogger.error(
                `Failed to spawn any agents for task ${taskId}:`,
                errors
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
                  ""
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
                }
              );
            } catch (error) {
              serverLogger.warn(
                "Could not set up file watching for workspace:",
                error
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

    socket.on(
      "get-local-vscode-serve-web-origin",
      (
        callback?: (response: { baseUrl: string | null; port: number | null }) => void
      ) => {
        if (!callback) {
          return;
        }
        // In web mode, local VSCode serve-web is not used
        if (env.NEXT_PUBLIC_WEB_MODE) {
          callback({ baseUrl: null, port: null });
          return;
        }
        try {
          callback({
            baseUrl: getVSCodeServeWebBaseUrl(),
            port: getVSCodeServeWebPort(),
          });
        } catch (error) {
          serverLogger.error(
            "Failed to handle get-local-vscode-serve-web-origin:",
            error
          );
          callback({
            baseUrl: null,
            port: null,
          });
        }
      }
    );

    // Handler to check VS Code availability and optionally refresh detection
    socket.on(
      "check-vscode-availability",
      async (
        data: { refresh?: boolean } | undefined,
        callback?: (response: {
          available: boolean;
          executablePath: string | null;
          variant: string | null;
          source: string | null;
          suggestions: string[];
          errors: string[];
        }) => void
      ) => {
        if (!callback) {
          return;
        }

        // In web mode, local VSCode is not used
        if (env.NEXT_PUBLIC_WEB_MODE) {
          callback({
            available: false,
            executablePath: null,
            variant: null,
            source: null,
            suggestions: ["Local workspaces are not available in the web version."],
            errors: [],
          });
          return;
        }

        try {
          let result = getLastVSCodeDetectionResult();

          // If refresh requested or no cached result, re-detect
          if (data?.refresh || !result) {
            result = await refreshVSCodeDetection(serverLogger);
          }

          if (result?.found && result.installation) {
            callback({
              available: true,
              executablePath: result.installation.executablePath,
              variant: result.installation.variant,
              source: result.installation.source,
              suggestions: [],
              errors: result.errors,
            });
          } else {
            callback({
              available: false,
              executablePath: null,
              variant: null,
              source: null,
              suggestions: result?.suggestions ?? [
                "Install VS Code from https://code.visualstudio.com/",
              ],
              errors: result?.errors ?? [],
            });
          }
        } catch (error) {
          serverLogger.error("Failed to check VS Code availability:", error);
          callback({
            available: false,
            executablePath: null,
            variant: null,
            source: null,
            suggestions: ["An error occurred while checking VS Code availability."],
            errors: [error instanceof Error ? error.message : "Unknown error"],
          });
        }
      }
    );

    socket.on(
      "create-local-workspace",
      async (
        rawData,
        callback: (response: CreateLocalWorkspaceResponse) => void
      ) => {
        // In web mode, local workspaces are not supported
        if (env.NEXT_PUBLIC_WEB_MODE) {
          callback({
            success: false,
            error: "Local workspaces are not available in the web version. Please use Cloud mode.",
          });
          return;
        }

        const parsed = CreateLocalWorkspaceSchema.safeParse(rawData);
        if (!parsed.success) {
          serverLogger.error(
            "Invalid create-local-workspace payload:",
            parsed.error
          );
          callback({
            success: false,
            error: "Invalid workspace request",
          });
          return;
        }

        const {
          teamSlugOrId: requestedTeamSlugOrId,
          projectFullName,
          repoUrl: explicitRepoUrl,
          branch: requestedBranch,
          baseBranch: requestedBaseBranch,
          taskId: providedTaskId,
          taskRunId: providedTaskRunId,
          workspaceName: providedWorkspaceName,
          descriptor: providedDescriptor,
          linkedFromCloudTaskRunId,
        } = parsed.data;
        const teamSlugOrId = requestedTeamSlugOrId || safeTeam;

        if (projectFullName && projectFullName.startsWith("env:")) {
          callback({
            success: false,
            error: "Local workspaces cannot be created from environments.",
          });
          return;
        }

        if (
          projectFullName &&
          !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(projectFullName)
        ) {
          callback({
            success: false,
            error: "Invalid repository name.",
          });
          return;
        }

        // Early check: verify VS Code serve-web is available before doing expensive operations
        const earlyServeWebCheck = getVSCodeServeWebBaseUrl();
        if (!earlyServeWebCheck) {
          // Give serve-web the full startup window to become ready (it might be starting up)
          // Using the default timeout (~15s) to avoid premature failures on slower machines
          const serveWebUrl = await waitForVSCodeServeWebBaseUrl();
          if (!serveWebUrl) {
            // Get detailed detection result for better error messaging
            const detectionResult = getLastVSCodeDetectionResult();
            const suggestions = detectionResult?.suggestions ?? [];

            serverLogger.warn(
              "[create-local-workspace] VS Code serve-web is not available. Local workspaces require VS Code CLI to be installed.",
              detectionResult
                ? {
                    searchedLocations: detectionResult.searchedLocations.length,
                    errors: detectionResult.errors,
                  }
                : {}
            );

            // Build user-friendly error message with suggestions
            let errorMessage =
              "VS Code is not available. Local workspaces require VS Code to be installed.";
            if (suggestions.length > 0) {
              errorMessage += "\n\nTo fix this:\n• " + suggestions.slice(0, 3).join("\n• ");
            }

            callback({
              success: false,
              error: errorMessage,
            });
            return;
          }
        }

        const repoUrl =
          explicitRepoUrl ??
          (projectFullName
            ? `https://github.com/${projectFullName}.git`
            : undefined);
        const branch = requestedBranch?.trim();
        const baseBranch = requestedBaseBranch?.trim();

        let workspaceConfig: WorkspaceConfigResponse | null = null;
        if (projectFullName) {
          try {
            const { getApiWorkspaceConfigs } =
              await getWwwOpenApiModule();
            const response = await getApiWorkspaceConfigs({
              client: getWwwClient(),
              query: {
                teamSlugOrId,
                projectFullName,
              },
            });
            workspaceConfig = response.data ?? null;
          } catch (error) {
            serverLogger.warn(
              "[create-local-workspace] Failed to load saved workspace config",
              {
                projectFullName,
                error,
              }
            );
          }
        }

        let taskId: Id<"tasks"> | null =
          providedTaskId !== undefined ? providedTaskId : null;
        let taskRunId: Id<"taskRuns"> | null =
          providedTaskRunId !== undefined ? providedTaskRunId : null;
        let workspaceName: string | null = providedWorkspaceName ?? null;
        let descriptor: string | null = providedDescriptor ?? null;
        let workspacePath: string | null = null;
        let cleanupWorkspace: (() => Promise<void>) | null = null;
        let responded = false;

        const convex = getConvex();

        try {
          if (!taskId || !taskRunId || !workspaceName) {
            const reservation = await convex.mutation(
              api.localWorkspaces.reserve,
              {
                teamSlugOrId,
                projectFullName: projectFullName ?? undefined,
                repoUrl,
                branch,
                linkedFromCloudTaskRunId,
              }
            );
            taskId = reservation.taskId;
            taskRunId = reservation.taskRunId;
            workspaceName = reservation.workspaceName;
            descriptor = reservation.descriptor;
          }

          if (!workspaceName || !taskId || !taskRunId) {
            throw new Error("Failed to prepare workspace metadata");
          }

          if (!descriptor) {
            const descriptorBase = projectFullName
              ? `Local workspace ${workspaceName} (${projectFullName})`
              : `Local workspace ${workspaceName}`;
            descriptor =
              branch && branch.length > 0
                ? `${descriptorBase} [${branch}]`
                : descriptorBase;
          }

          const workspaceRoot = process.env.CMUX_WORKSPACE_DIR
            ? path.resolve(process.env.CMUX_WORKSPACE_DIR)
            : path.join(os.homedir(), "cmux", "local-workspaces");
          const resolvedWorkspacePath = path.join(
            workspaceRoot,
            workspaceName
          );
          workspacePath = resolvedWorkspacePath;

          await fs.mkdir(workspaceRoot, { recursive: true });
          cleanupWorkspace = async () => {
            await fs
              .rm(resolvedWorkspacePath, { recursive: true, force: true })
              .catch(() => undefined);
          };

          const writeEnvVariablesIfPresent = async (): Promise<
            Record<string, string>
          > => {
            if (!workspaceConfig || !taskRunId) {
              return {};
            }

            const envVarsContent = workspaceConfig.envVarsContent ?? "";
            const trimmedEnvVars = envVarsContent.trim();
            let parsedEnvVars: Record<string, string> = {};

            if (trimmedEnvVars.length > 0) {
              try {
                parsedEnvVars = parseDotenv(envVarsContent);
              } catch (error) {
                serverLogger.warn(
                  "[create-local-workspace] Failed to parse saved env vars for local workspace config",
                  {
                    projectFullName,
                    error,
                  }
                );
                parsedEnvVars = {};
              }

              try {
                const envFile = path.join(resolvedWorkspacePath, ".env");
                await fs.writeFile(envFile, envVarsContent, {
                  encoding: "utf8",
                  mode: 0o600,
                });
                serverLogger.info(
                  `[create-local-workspace] Wrote env vars to ${envFile}`
                );
              } catch (error) {
                serverLogger.warn(
                  "[create-local-workspace] Failed to write saved env vars to disk",
                  {
                    projectFullName,
                    error,
                  }
                );
              }
            }

            return parsedEnvVars;
          };

          // Run maintenance script asynchronously in background (doesn't block VSCode loading)
          const runMaintenanceScriptAsync = (
            parsedEnvVars: Record<string, string>
          ) => {
            if (!workspaceConfig || !taskRunId) {
              return;
            }

            const maintenanceScript =
              workspaceConfig.maintenanceScript?.trim() ?? "";
            if (!maintenanceScript) {
              return;
            }

            // Fire and forget - run in background without blocking
            void (async () => {
              const scriptPreamble = "set -euo pipefail";
              const maintenancePayload = `${scriptPreamble}\n${maintenanceScript}`;
              const loginShell = getUserLoginShell();
              const shellArgs = buildLoginShellArgs(
                loginShell,
                maintenancePayload
              );

              serverLogger.info(
                `[create-local-workspace] Running local maintenance script for ${workspaceName} in background (shell: ${loginShell})`
              );

              try {
                await execFileAsync(loginShell, shellArgs, {
                  cwd: resolvedWorkspacePath,
                  env: {
                    ...process.env,
                    ...parsedEnvVars,
                  },
                  maxBuffer: 10 * 1024 * 1024,
                });
                await convex.mutation(api.taskRuns.updateEnvironmentError, {
                  teamSlugOrId,
                  id: taskRunId,
                  maintenanceError: undefined,
                  devError: undefined,
                });
                serverLogger.info(
                  `[create-local-workspace] Maintenance script completed successfully for ${workspaceName}`
                );
              } catch (error) {
                const execErr = isExecError(error) ? error : null;
                const stderr = execErr?.stderr?.trim() ?? "";
                const stdout = execErr?.stdout?.trim() ?? "";
                const baseMessage =
                  stderr ||
                  stdout ||
                  (error instanceof Error ? error.message : String(error));

                const maintenanceErrorMessage = baseMessage
                  ? `Maintenance script failed: ${baseMessage}`
                  : "Maintenance script failed";

                serverLogger.error(
                  `[create-local-workspace] ${maintenanceErrorMessage}`,
                  error
                );

                await convex.mutation(api.taskRuns.updateEnvironmentError, {
                  teamSlugOrId,
                  id: taskRunId,
                  maintenanceError: maintenanceErrorMessage,
                  devError: undefined,
                });
              }
            })();
          };

          const normalizeBranchName = (
            value?: string | null
          ): string | null => {
            if (!value) {
              return null;
            }
            const trimmed = value.trim();
            if (!trimmed) {
              return null;
            }
            const withoutPrefix = trimmed
              .replace(/^refs\/heads\//, "")
              .replace(/^refs\/remotes\/origin\//, "")
              .replace(/^origin\//, "");
            const sanitized = withoutPrefix.replace(
              /[^a-zA-Z0-9._/-]/g,
              "-"
            );
            return sanitized || null;
          };

          const hasGitRef = (cwd: string, ref: string): Promise<boolean> =>
            new Promise((resolve) => {
              execFile(
                "git",
                ["rev-parse", "--verify", "--quiet", ref],
                { cwd },
                (error) => {
                  resolve(!error);
                }
              );
            });

          const ensureBaseBranchRefs = async (
            repoPath: string,
            baseBranchName: string,
            headBranchName?: string | null
          ) => {
            if (headBranchName && baseBranchName === headBranchName) {
              return;
            }
            const remoteRef = `refs/remotes/origin/${baseBranchName}`;
            const localRef = `refs/heads/${baseBranchName}`;

            const hasRemoteRef = await hasGitRef(repoPath, remoteRef);
            if (!hasRemoteRef) {
              try {
                await execFileAsync(
                  "git",
                  ["fetch", "origin", `${baseBranchName}:${remoteRef}`],
                  { cwd: repoPath }
                );
              } catch (error) {
                serverLogger.warn(
                  `[create-local-workspace] Failed to fetch base branch ${baseBranchName}`,
                  error
                );
                console.error(error);
              }
            }

            const hasLocalRef = await hasGitRef(repoPath, localRef);
            if (!hasLocalRef) {
              const refreshedRemoteRef = await hasGitRef(repoPath, remoteRef);
              if (refreshedRemoteRef) {
                try {
                  await execFileAsync(
                    "git",
                    ["branch", baseBranchName, `origin/${baseBranchName}`],
                    { cwd: repoPath }
                  );
                } catch (error) {
                  serverLogger.warn(
                    `[create-local-workspace] Failed to create local base branch ${baseBranchName}`,
                    error
                  );
                  console.error(error);
                }
              }
            }
          };

          const baseServeWebUrl =
            (await waitForVSCodeServeWebBaseUrl()) ??
            getVSCodeServeWebBaseUrl();
          if (!baseServeWebUrl) {
            throw new Error("VS Code serve-web proxy is not ready");
          }

          const folderForUrl = resolvedWorkspacePath.replace(/\\/g, "/");
          const placeholderWorkspaceUrl =
            buildPlaceholderWorkspaceUrl(folderForUrl);
          const now = Date.now();

          try {
            await convex.mutation(api.tasks.updateWorktreePath, {
              teamSlugOrId,
              id: taskId,
              worktreePath: resolvedWorkspacePath,
            });
          } catch (error) {
            serverLogger.warn(
              `Unable to update worktree path for task ${taskId}:`,
              error
            );
          }

          await convex.mutation(api.taskRuns.updateVSCodeInstance, {
            teamSlugOrId,
            id: taskRunId,
            vscode: {
              provider: "other",
              status: "starting",
              url: LOCAL_VSCODE_PLACEHOLDER_ORIGIN,
              workspaceUrl: placeholderWorkspaceUrl,
              startedAt: now,
            },
          });

          await convex.mutation(api.taskRuns.updateStatusPublic, {
            teamSlugOrId,
            id: taskRunId,
            status: "pending",
          });

          callback({
            success: true,
            pending: true,
            taskId,
            taskRunId,
            workspaceName,
            workspacePath: resolvedWorkspacePath,
            workspaceUrl: placeholderWorkspaceUrl,
          });
          responded = true;

          if (repoUrl) {
            if (cleanupWorkspace) {
              await cleanupWorkspace();
            }
            const cloneArgs = ["clone"];
            if (branch) {
              cloneArgs.push("--branch", branch, "--single-branch");
            }
            cloneArgs.push(repoUrl, resolvedWorkspacePath);
            try {
              await execFileAsync("git", cloneArgs, { cwd: workspaceRoot });
            } catch (error) {
              if (cleanupWorkspace) {
                await cleanupWorkspace();
              }
              const execErr = isExecError(error) ? error : null;
              const rawMessage =
                execErr?.stderr?.trim() ||
                (error instanceof Error ? error.message : "Git clone failed");

              // Check if this is a repository access/not found error
              const isAccessError =
                rawMessage.includes("Repository not found") ||
                rawMessage.includes("repository not found") ||
                rawMessage.includes("Authentication failed") ||
                rawMessage.includes("Permission denied") ||
                rawMessage.includes("could not read Username") ||
                rawMessage.includes("Invalid username or password") ||
                rawMessage.includes("403");

              let message: string;
              if (isAccessError) {
                // Extract repo URL from clone args for the error message
                const repoUrlArg = cloneArgs[cloneArgs.length - 2]; // URL is second to last arg
                message = `Unable to access repository${repoUrlArg ? ` '${repoUrlArg}'` : ''}. This repository may be private or you may not have permission to access it. If this is a teammate's task, they may need to make the repository public or grant you access.`;
              } else {
                message = rawMessage ? `Git clone failed: ${rawMessage}` : "Git clone failed";
              }

              throw new Error(message);
            }

            try {
              await execFileAsync(
                "git",
                ["rev-parse", "--verify", "HEAD"],
                {
                  cwd: resolvedWorkspacePath,
                }
              );
            } catch (error) {
              if (cleanupWorkspace) {
                await cleanupWorkspace();
              }
              throw new Error(
                error instanceof Error
                  ? `Git clone failed to produce a checkout: ${error.message}`
                  : "Git clone failed to produce a checkout"
              );
            }

            const normalizedHeadBranch = normalizeBranchName(branch);
            let baseBranchName = normalizeBranchName(baseBranch);
            if (!baseBranchName) {
              try {
                const repoMgr = RepositoryManager.getInstance();
                baseBranchName = await repoMgr.getDefaultBranch(
                  resolvedWorkspacePath
                );
              } catch (error) {
                serverLogger.warn(
                  "[create-local-workspace] Failed to detect default base branch",
                  error
                );
                console.error(error);
              }
            }
            if (baseBranchName) {
              await ensureBaseBranchRefs(
                resolvedWorkspacePath,
                baseBranchName,
                normalizedHeadBranch
              );
            }
          } else {
            try {
              await fs.mkdir(resolvedWorkspacePath, { recursive: false });
            } catch (error) {
              if (
                error &&
                typeof error === "object" &&
                "code" in error &&
                (error as NodeJS.ErrnoException).code === "EEXIST"
              ) {
                throw new Error(
                  `Workspace directory already exists: ${workspacePath}`
                );
              }
              throw error;
            }

            await execFileAsync("git", ["init"], {
              cwd: resolvedWorkspacePath,
            });
          }

          const parsedEnvVars = await writeEnvVariablesIfPresent();

          await convex.mutation(api.taskRuns.updateWorktreePath, {
            teamSlugOrId,
            id: taskRunId,
            worktreePath: resolvedWorkspacePath,
          });

          await convex.mutation(api.taskRuns.updateStatusPublic, {
            teamSlugOrId,
            id: taskRunId,
            status: "running",
          });

          await convex.mutation(api.taskRuns.updateVSCodeStatus, {
            teamSlugOrId,
            id: taskRunId,
            status: "running",
          });

          // Run maintenance script in background after status updates (doesn't block)
          runMaintenanceScriptAsync(parsedEnvVars);

          try {
            void gitDiffManager.watchWorkspace(
              resolvedWorkspacePath,
              (changedPath: string) => {
                rt.emit("git-file-changed", {
                  workspacePath: resolvedWorkspacePath,
                  filePath: changedPath,
                });
              }
            );
          } catch (error) {
            serverLogger.warn(
              "Could not set up file watching for workspace:",
              error
            );
          }

          if (linkedFromCloudTaskRunId) {
            // When creating a local workspace linked to a cloud task run,
            // we need to first download all existing cloud changes before
            // starting the local-to-cloud sync. Otherwise, the local-to-cloud
            // sync would overwrite the cloud changes with the fresh git clone.
            const cloudInstance = VSCodeInstance.getInstance(linkedFromCloudTaskRunId);
            if (cloudInstance && cloudInstance.isWorkerConnected()) {
              try {
                const workerSocket = cloudInstance.getWorkerSocket();

                // First, tell the cloud worker to start watching files and prepare for syncing
                workerSocket.emit("worker:start-cloud-sync", {
                  taskRunId: linkedFromCloudTaskRunId,
                  workspacePath: "/workspace", // Default cloud workspace path
                });

                // Request a full sync of all existing cloud files
                // Wait for the callback to ensure files are sent before starting local-to-cloud sync
                await new Promise<void>((resolve) => {
                  workerSocket.emit(
                    "worker:request-full-cloud-sync",
                    { taskRunId: linkedFromCloudTaskRunId },
                    (result: { filesSent: number }) => {
                      serverLogger.info(
                        `[create-local-workspace] Full cloud sync completed: ${result.filesSent} files received from cloud`
                      );
                      resolve();
                    }
                  );

                  // Timeout after 30 seconds in case of issues
                  setTimeout(() => {
                    serverLogger.warn(
                      "[create-local-workspace] Full cloud sync timed out after 30s"
                    );
                    resolve();
                  }, 30000);
                });
              } catch (error) {
                serverLogger.warn(
                  "[create-local-workspace] Failed to perform initial cloud sync, starting local-to-cloud sync anyway",
                  error
                );
              }
            } else {
              serverLogger.info(
                "[create-local-workspace] Cloud worker not connected, skipping initial cloud download"
              );
            }

            // Now start the local-to-cloud sync
            void localCloudSyncManager.startSync({
              localWorkspacePath: resolvedWorkspacePath,
              cloudTaskRunId: linkedFromCloudTaskRunId,
            });
          }
        } catch (error) {
          serverLogger.error("Error creating local workspace:", error);
          const message =
            error instanceof Error
              ? error.message
              : "Failed to create local workspace";

          if (!responded) {
            callback({
              success: false,
              error: message,
            });
          } else if (taskRunId) {
            try {
              await convex.mutation(api.taskRuns.fail, {
                teamSlugOrId,
                id: taskRunId,
                errorMessage: message,
              });
            } catch (failError) {
              serverLogger.error(
                "Failed to mark task run as failed:",
                failError
              );
            }
            try {
              await convex.mutation(api.taskRuns.updateVSCodeStatus, {
                teamSlugOrId,
                id: taskRunId,
                status: "stopped",
                stoppedAt: Date.now(),
              });
            } catch (statusError) {
              serverLogger.warn(
                "Failed to update VS Code status after failure:",
                statusError
              );
            }
          }

          if (cleanupWorkspace) {
            try {
              await cleanupWorkspace();
            } catch (cleanupError) {
              serverLogger.warn(
                "Failed to clean up workspace after error:",
                cleanupError
              );
            }
          }
        }
      }
    );

    socket.on(
      "create-cloud-workspace",
      async (
        rawData,
        callback: (response: CreateCloudWorkspaceResponse) => void
      ) => {
        const parsed = CreateCloudWorkspaceSchema.safeParse(rawData);
        if (!parsed.success) {
          serverLogger.error(
            "Invalid create-cloud-workspace payload:",
            parsed.error
          );
          callback({
            success: false,
            error: "Invalid cloud workspace request",
          });
          return;
        }

        const {
          teamSlugOrId: requestedTeamSlugOrId,
          environmentId,
          projectFullName,
          repoUrl,
          taskId: providedTaskId,
        } = parsed.data;
        const teamSlugOrId = requestedTeamSlugOrId || safeTeam;

        const convex = getConvex();
        const taskId: Id<"tasks"> | undefined = providedTaskId;
        let taskRunId: Id<"taskRuns"> | null = null;
        let responded = false;

        try {
          if (!taskId) {
            throw new Error("taskId is required for cloud workspace creation");
          }

          // Create a taskRun for the workspace
          const now = Date.now();
          const taskRunResult = await convex.mutation(api.taskRuns.create, {
            teamSlugOrId,
            taskId,
            prompt: "Cloud Workspace",
            agentName: "cloud-workspace",
            environmentId,
          });
          taskRunId = taskRunResult.taskRunId;
          const taskRunJwt = taskRunResult.jwt;

          serverLogger.info(
            `[create-cloud-workspace] Created taskRun ${taskRunId} for task ${taskId}`
          );

          // Update initial VSCode status
          await convex.mutation(api.taskRuns.updateVSCodeInstance, {
            teamSlugOrId,
            id: taskRunId,
            vscode: {
              provider: "morph",
              status: "starting",
              startedAt: now,
            },
          });

          await convex.mutation(api.taskRuns.updateStatusPublic, {
            teamSlugOrId,
            id: taskRunId,
            status: "pending",
          });

          callback({
            success: true,
            pending: true,
            taskId,
            taskRunId,
          });
          responded = true;

          // Spawn Morph instance via www API
          const { postApiSandboxesStart } = await getWwwOpenApiModule();

          serverLogger.info(
            environmentId
              ? `[create-cloud-workspace] Starting Morph sandbox for environment ${environmentId}`
              : `[create-cloud-workspace] Starting Morph sandbox for repo ${projectFullName}`
          );

          const startRes = await postApiSandboxesStart({
            client: getWwwClient(),
            body: {
              teamSlugOrId,
              ttlSeconds: 60 * 60,
              metadata: {
                instance: `cmux-workspace-${taskRunId}`,
                agentName: "cloud-workspace",
              },
              taskRunId,
              taskRunJwt,
              isCloudWorkspace: true,
              ...(environmentId
                ? { environmentId }
                : { projectFullName, repoUrl }),
            },
          });

          const data = startRes.data;
          if (!data) {
            const errorMessage = extractSandboxStartError(startRes);
            throw new Error(errorMessage);
          }

          const sandboxId = data.instanceId;
          const vscodeBaseUrl = data.vscodeUrl;
          const workspaceUrl = `${vscodeBaseUrl}?folder=/root/workspace`;

          serverLogger.info(
            `[create-cloud-workspace] Sandbox started: ${sandboxId}, VSCode URL: ${workspaceUrl}`
          );

          // For cloud workspaces, update VSCode instance immediately with the URL
          // No need to wait for VSCode readiness - the frontend will handle loading states
          serverLogger.info(
            `[create-cloud-workspace] Updating VSCode instance with URL (no readiness check)`
          );

          // Update taskRun with actual VSCode info immediately
          await convex.mutation(api.taskRuns.updateVSCodeInstance, {
            teamSlugOrId,
            id: taskRunId,
            vscode: {
              provider: "morph",
              status: "running",
              url: vscodeBaseUrl,
              workspaceUrl,
              startedAt: now,
            },
          });

          await convex.mutation(api.taskRuns.updateStatusPublic, {
            teamSlugOrId,
            id: taskRunId,
            status: "running",
          });

          await convex.mutation(api.taskRuns.updateVSCodeStatus, {
            teamSlugOrId,
            id: taskRunId,
            status: "running",
          });

          // Emit vscode-spawned event to the client
          rt.emit("vscode-spawned", {
            instanceId: sandboxId,
            url: vscodeBaseUrl,
            workspaceUrl,
            provider: "morph",
          });

          serverLogger.info(
            environmentId
              ? `Cloud workspace created successfully: ${taskId} for environment ${environmentId}`
              : `Cloud workspace created successfully: ${taskId} for repo ${projectFullName}`
          );
        } catch (error) {
          serverLogger.error("Error creating cloud workspace:", error);
          const message =
            error instanceof Error
              ? error.message
              : "Failed to create cloud workspace";

          if (!responded) {
            callback({
              success: false,
              error: message,
            });
          } else if (taskRunId) {
            try {
              await convex.mutation(api.taskRuns.fail, {
                teamSlugOrId,
                id: taskRunId,
                errorMessage: message,
              });
            } catch (failError) {
              serverLogger.error(
                "Failed to mark task run as failed:",
                failError
              );
            }
            try {
              await convex.mutation(api.taskRuns.updateVSCodeStatus, {
                teamSlugOrId,
                id: taskRunId,
                status: "stopped",
                stoppedAt: Date.now(),
              });
            } catch (statusError) {
              serverLogger.warn(
                "Failed to update VS Code status after failure:",
                statusError
              );
            }
          }
        }
      }
    );

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

        const githubToken = await getGitHubOAuthToken();
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
          safeTeam
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
            (record) => [record.repoFullName, record] as const
          )
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
          })
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

        const githubToken = await getGitHubOAuthToken();
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
                  : record
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
      // In web mode, opening local editors is not supported
      if (env.NEXT_PUBLIC_WEB_MODE) {
        callback?.({ success: false, error: "Opening local editors is not available in the web version." });
        return;
      }

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
          baseDir: string
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
                  minimatch(fullPath, ignorePattern)
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
          // Use unauthenticated URL for path derivation (consistent folder names)
          const projectPaths = await getProjectPaths(targetRepoUrl, safeTeam);

          await fs.mkdir(projectPaths.projectPath, { recursive: true });
          await fs.mkdir(projectPaths.worktreesPath, { recursive: true });

          // Inject GitHub OAuth token for private repo access
          // Use authenticated URL for git operations, but store clean URL as remote
          let authenticatedRepoUrl = targetRepoUrl;
          const githubToken = await getGitHubOAuthToken();
          if (githubToken && targetRepoUrl.startsWith("https://github.com/")) {
            authenticatedRepoUrl = targetRepoUrl.replace(
              "https://github.com/",
              `https://x-access-token:${githubToken}@github.com/`
            );
          }

          // Pass clean URL as remoteUrl to avoid persisting OAuth token in .git/config
          // If branchOverride is undefined, ensureRepository auto-detects and fetches default branch
          await repoManager.ensureRepository(
            authenticatedRepoUrl,
            projectPaths.originPath,
            branchOverride,
            targetRepoUrl // clean URL for remote storage
          );

          // Get the branch name for worktree path (either override or detected default)
          const baseBranch =
            branchOverride ||
            (await repoManager.getDefaultBranch(projectPaths.originPath));

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
              worktreeInfo.originPath
            );
            return [];
          }

          let fileList = await walkDir(
            worktreeInfo.originPath,
            worktreeInfo.originPath
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
                error
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
      // In web mode, this debug feature is not available
      if (env.NEXT_PUBLIC_WEB_MODE) {
        callback({
          authStatus: "Not available in web mode",
          whoami: "N/A",
          home: "N/A",
          ghConfig: "N/A",
        });
        return;
      }

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
        const { taskId } = await getConvex().mutation(api.tasks.create, {
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
            // Use provided selectedAgents or default to claude/sonnet-4 and codex/gpt-5.1-codex-high
            selectedAgents: selectedAgents || [
              "claude/sonnet-4",
              "codex/gpt-5.1-codex-high",
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

        const githubToken = await getGitHubOAuthToken();
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
          safeTeam
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
            (record) => [record.repoFullName, record] as const
          )
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
                  body
                );
                detail =
                  (await fetchPrDetail(
                    githubToken,
                    owner,
                    repo,
                    created.number
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
          })
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
        // In web mode, only check API keys from Convex (no local files/keychains)
        const status = env.NEXT_PUBLIC_WEB_MODE
          ? await checkAllProvidersStatusWebMode({ teamSlugOrId: safeTeam })
          : await checkAllProvidersStatus({ teamSlugOrId: safeTeam });
        callback({ success: true, ...status });
      } catch (error) {
        serverLogger.error("Error checking provider status:", error);
        callback({
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    });

    socket.on("docker-pull-image", async (callback) => {
      // In web mode, Docker operations are not supported
      if (env.NEXT_PUBLIC_WEB_MODE) {
        callback({
          success: false,
          error: "Docker operations are not available in the web version.",
        });
        return;
      }

      try {
        const { checkDockerStatus } = await import(
          "@cmux/shared/providers/common/check-docker"
        );
        const docker = await checkDockerStatus();

        if (!docker.isRunning) {
          callback({
            success: false,
            error: "Docker is not running. Please start Docker Desktop first.",
          });
          return;
        }

        const imageName =
          docker.workerImage?.name ||
          process.env.WORKER_IMAGE_NAME ||
          "docker.io/manaflow/cmux:latest";

        // Check if already pulling
        if (docker.workerImage?.isPulling) {
          rt.emit("docker-pull-progress", {
            imageName,
            status: "Waiting for existing pull",
            phase: "waiting",
          });
          const dockerClient = DockerVSCodeInstance.getDocker();
          const deadline = Date.now() + DOCKER_PULL_TIMEOUT_MS;
          while (Date.now() < deadline) {
            try {
              await dockerClient.getImage(imageName).inspect();
              rt.emit("docker-pull-progress", {
                imageName,
                status: "Pull complete",
                percent: 100,
                phase: "complete",
              });
              callback({ success: true, imageName });
              return;
            } catch {
              await sleep(2_000);
            }
          }
          callback({
            success: false,
            error: `Timed out waiting for Docker image "${imageName}" to finish pulling.`,
          });
          return;
        }

        // Check if already available
        if (docker.workerImage?.isAvailable) {
          callback({
            success: true,
            imageName,
          });
          return;
        }

        serverLogger.info(`Starting Docker pull for image: ${imageName}`);
        rt.emit("docker-pull-progress", {
          imageName,
          status: "Starting pull",
          phase: "pulling",
        });

        // Use dockerode to pull the image
        const dockerClient = DockerVSCodeInstance.getDocker();
        const stream = await dockerClient.pull(imageName);
        let lastProgressUpdate = 0;
        let lastStatus = "";
        let lastAggregatePercent = -1;
        let lastAggregateProgress = "";
        const layerStats = new Map<string, { current: number; total: number }>();

        // Wait for the pull to complete
        await new Promise<void>((resolve, reject) => {
          dockerClient.modem.followProgress(
            stream,
            (err: Error | null) => {
              if (err) {
                reject(err);
              } else {
                resolve();
              }
            },
            (event: DockerPullProgressEvent) => {
              if (!event.status) {
                return;
              }

              const now = Date.now();
              if (
                event.id &&
                typeof event.progressDetail?.current === "number" &&
                typeof event.progressDetail?.total === "number" &&
                event.progressDetail.total > 0
              ) {
                const previous = layerStats.get(event.id);
                const current = Math.max(
                  previous?.current ?? 0,
                  event.progressDetail.current
                );
                layerStats.set(event.id, {
                  current,
                  total: event.progressDetail.total,
                });
              }

              let aggregateCurrent = 0;
              let aggregateTotal = 0;
              for (const layer of layerStats.values()) {
                aggregateTotal += layer.total;
                aggregateCurrent += Math.min(layer.current, layer.total);
              }

              let percent =
                aggregateTotal > 0
                  ? Math.round((aggregateCurrent / aggregateTotal) * 100)
                  : undefined;
              if (percent !== undefined && percent >= 100) {
                percent = 99;
              }
              const safePercent =
                percent !== undefined
                  ? Math.max(percent, lastAggregatePercent)
                  : undefined;
              const aggregateProgress =
                aggregateTotal > 0
                  ? `${formatBytes(aggregateCurrent)}/${formatBytes(
                      aggregateTotal
                    )}`
                  : "";

              const shouldEmit =
                event.status !== lastStatus ||
                (safePercent !== undefined &&
                  safePercent !== lastAggregatePercent) ||
                aggregateProgress !== lastAggregateProgress ||
                now - lastProgressUpdate > DOCKER_PULL_PROGRESS_THROTTLE_MS;

              if (shouldEmit) {
                lastStatus = event.status;
                lastProgressUpdate = now;
                if (safePercent !== undefined) {
                  lastAggregatePercent = safePercent;
                }
                if (aggregateProgress) {
                  lastAggregateProgress = aggregateProgress;
                }
                rt.emit("docker-pull-progress", {
                  imageName,
                  status: event.status,
                  progress: aggregateProgress || event.progress,
                  id: event.id,
                  current: aggregateTotal > 0 ? aggregateCurrent : undefined,
                  total: aggregateTotal > 0 ? aggregateTotal : undefined,
                  percent: safePercent,
                  phase: "pulling",
                });
              }
            }
          );
        });

        serverLogger.info(`Successfully pulled Docker image: ${imageName}`);
        rt.emit("docker-pull-progress", {
          imageName,
          status: "Pull complete",
          percent: 100,
          phase: "complete",
        });
        callback({ success: true, imageName });
        return;
      } catch (error) {
        serverLogger.error("Error pulling Docker image:", error);
        rt.emit("docker-pull-progress", {
          imageName:
            process.env.WORKER_IMAGE_NAME || "docker.io/manaflow/cmux:latest",
          status: "Pull failed",
          phase: "error",
        });
        const errorMessage =
          error instanceof Error ? error.message : "Unknown error";

        // Provide user-friendly error messages
        let userFriendlyError: string;
        if (
          errorMessage.includes("timeout") ||
          errorMessage.includes("stalled")
        ) {
          userFriendlyError =
            "Docker image pull timed out. This may be due to slow network or Docker registry issues.";
        } else if (
          errorMessage.includes("not found") ||
          errorMessage.includes("manifest unknown")
        ) {
          userFriendlyError =
            "Docker image not found. Please check if the image name is correct.";
        } else if (
          errorMessage.includes("unauthorized") ||
          errorMessage.includes("authentication")
        ) {
          userFriendlyError =
            "Docker authentication failed. Please ensure you have access to the Docker registry.";
        } else if (
          errorMessage.includes("ECONNREFUSED") ||
          errorMessage.includes("connection refused")
        ) {
          userFriendlyError =
            "Cannot connect to Docker daemon. Please ensure Docker is running.";
        } else {
          userFriendlyError = `Failed to pull Docker image: ${errorMessage}`;
        }

        callback({
          success: false,
          error: userFriendlyError,
        });
      }
    });

    socket.on("archive-task", async (data, callback) => {
      try {
        const { taskId } = ArchiveTaskSchema.parse(data);

        // In web mode, skip Docker container operations (managed by cloud provider)
        if (env.NEXT_PUBLIC_WEB_MODE) {
          serverLogger.info(`Skipping container cleanup for task ${taskId} in web mode`);
          callback({ success: true });
          return;
        }

        // Stop/pause all containers via helper (handles querying + logging)
        const results = await stopContainersForRuns(taskId, safeTeam);

        try {
          const runsTree = await getConvex().query(api.taskRuns.getByTask, {
            teamSlugOrId: safeTeam,
            taskId,
          });
          const worktreePaths = collectWorktreePaths(runsTree);
          if (worktreePaths.length > 0) {
            for (const worktreePath of worktreePaths) {
              gitDiffManager.unwatchWorkspace(worktreePath);
              localCloudSyncManager.stopSync(worktreePath);
            }
            serverLogger.info(
              `Stopped git diff watchers for archived task ${taskId}: ${worktreePaths.join(", ")}`
            );
          }
        } catch (error) {
          serverLogger.error(
            `Failed to clean up git diff watchers for archived task ${taskId}:`,
            error
          );
        }

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

    socket.on("trigger-local-cloud-sync", async (data, callback) => {
      serverLogger.info(
        `[trigger-local-cloud-sync] RECEIVED event:`,
        JSON.stringify(data)
      );
      try {
        const parsed = TriggerLocalCloudSyncSchema.safeParse(data);
        if (!parsed.success) {
          const response: TriggerLocalCloudSyncResponse = {
            success: false,
            error: `Invalid request: ${parsed.error.message}`,
          };
          callback(response);
          return;
        }

        const { localWorkspacePath, cloudTaskRunId } = parsed.data;

        // Basic path validation - must be absolute and not contain traversal
        if (!path.isAbsolute(localWorkspacePath)) {
          const response: TriggerLocalCloudSyncResponse = {
            success: false,
            error: "Invalid workspace path: must be absolute",
          };
          callback(response);
          return;
        }

        // Check for path traversal attempts (.. in the path after normalization)
        const normalizedPath = path.resolve(localWorkspacePath);
        if (normalizedPath.includes("/../") || normalizedPath.endsWith("/..")) {
          serverLogger.warn(
            `[trigger-local-cloud-sync] Path traversal attempt: ${localWorkspacePath}`
          );
          const response: TriggerLocalCloudSyncResponse = {
            success: false,
            error: "Invalid workspace path",
          };
          callback(response);
          return;
        }

        serverLogger.info(
          `[trigger-local-cloud-sync] Manual sync requested: ${localWorkspacePath} -> ${cloudTaskRunId}`
        );
        console.log(
          `[trigger-local-cloud-sync] Manual sync requested: ${localWorkspacePath} -> ${cloudTaskRunId}`
        );

        // Check if sync session exists (use original path for lookup)
        const status = localCloudSyncManager.getStatus(localWorkspacePath);

        // Always check if we need to reconnect to the cloud workspace
        // This handles server restarts where VSCodeInstance is lost but cloud workspace is still running
        const existingInstance = VSCodeInstance.getInstance(cloudTaskRunId);
        console.log(
          `[trigger-local-cloud-sync] Reconnect check: existingInstance=${!!existingInstance}, workerConnected=${existingInstance?.isWorkerConnected() ?? "N/A"}`
        );
        if (!existingInstance || !existingInstance.isWorkerConnected()) {
          // Query task run to get worker URL for reconnection
          const taskRun = await getConvex().query(api.taskRuns.get, {
            teamSlugOrId: safeTeam,
            id: cloudTaskRunId,
          });

          if (!taskRun) {
            serverLogger.warn(
              `[trigger-local-cloud-sync] Task run not found or unauthorized: ${cloudTaskRunId}`
            );
            const response: TriggerLocalCloudSyncResponse = {
              success: false,
              error: "Task run not found or unauthorized",
            };
            callback(response);
            return;
          }

          let workerUrl = taskRun.vscode?.ports?.worker;
          const vscodeStatus = taskRun.vscode?.status;
          const vscodeUrl = taskRun.vscode?.url;

          // For Morph instances, derive worker URL from VSCode URL if not stored
          // VSCode is on port 39378, worker is on port 39377
          if (
            !workerUrl &&
            vscodeUrl &&
            taskRun.vscode?.provider === "morph"
          ) {
            workerUrl = vscodeUrl.replace("port-39378", "port-39377");
            serverLogger.info(
              `[trigger-local-cloud-sync] Derived worker URL from VSCode URL: ${workerUrl}`
            );
          }

          if (
            workerUrl &&
            vscodeStatus === "running" &&
            taskRun.vscode?.provider !== "docker"
          ) {
            serverLogger.info(
              `[trigger-local-cloud-sync] No VSCodeInstance or worker disconnected, attempting to reconnect to worker at ${workerUrl}`
            );
            try {
              const reconnectedInstance = await CmuxVSCodeInstance.reconnect({
                config: {
                  taskRunId: cloudTaskRunId,
                  taskId: taskRun.taskId,
                  teamSlugOrId: safeTeam,
                },
                workerUrl,
                sandboxId: taskRun.vscode?.containerName,
              });
              serverLogger.info(
                `[trigger-local-cloud-sync] Successfully reconnected to cloud workspace`
              );

              // Start file watch and cloud sync after reconnecting
              // This is critical - without this, the cloud-to-local sync won't work
              reconnectedInstance.startFileWatch("/root/workspace");
              reconnectedInstance.startCloudSync();
              serverLogger.info(
                `[trigger-local-cloud-sync] Started file watch and cloud sync for reconnected instance`
              );

              // Set up sync-files event handler for cloud-to-local sync
              reconnectedInstance.on(
                "sync-files",
                async (data: WorkerSyncFiles) => {
                  serverLogger.info(
                    `[trigger-local-cloud-sync] Sync files received after reconnect:`,
                    { fileCount: data.files.length, taskRunId: data.taskRunId }
                  );
                  await localCloudSyncManager.handleCloudSync(data);
                }
              );
            } catch (reconnectError) {
              serverLogger.warn(
                `[trigger-local-cloud-sync] Failed to reconnect to worker, will use lazy sync`,
                reconnectError
              );
              // Continue anyway - lazy sync will handle it when worker becomes available
            }
          }
        }

        if (!status.found) {
          // Start a new sync session if none exists
          serverLogger.info(
            `[trigger-local-cloud-sync] No existing session, starting new sync`
          );
          await localCloudSyncManager.startSync({
            localWorkspacePath,
            cloudTaskRunId,
          });
        }

        // Trigger the sync (use original path for lookup)
        const result =
          await localCloudSyncManager.triggerSync(localWorkspacePath);

        if (result.success) {
          const response: TriggerLocalCloudSyncResponse = {
            success: true,
            message: `Queued ${result.filesQueued} files for sync`,
            filesQueued: result.filesQueued,
          };
          callback(response);
        } else {
          const response: TriggerLocalCloudSyncResponse = {
            success: false,
            error: result.error,
          };
          callback(response);
        }
      } catch (error) {
        serverLogger.error("[trigger-local-cloud-sync] Error:", error);
        console.error("[trigger-local-cloud-sync] Error:", error);
        const response: TriggerLocalCloudSyncResponse = {
          success: false,
          error: error instanceof Error ? error.message : "Unknown error",
        };
        callback(response);
      }
    });
  });
}
