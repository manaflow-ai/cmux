import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import {
  AGENT_CONFIGS,
  type AgentConfig,
  type EnvironmentResult,
} from "@cmux/shared/agentConfig";
import type {
  WorkerCreateTerminal,
  WorkerTerminalFailed,
} from "@cmux/shared/worker-schemas";
import { parseGithubRepoUrl } from "@cmux/shared/utils/parse-github-repo-url";
import { parse as parseDotenv } from "dotenv";
import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { sanitizeTmuxSessionName } from "./sanitizeTmuxSessionName";
import {
  generateNewBranchName,
  generateUniqueBranchNames,
  generateUniqueBranchNamesFromTitle,
} from "./utils/branchNameGenerator";
import { getConvex } from "./utils/convexClient";
import { retryOnOptimisticConcurrency } from "./utils/convexRetry";
import { serverLogger } from "./utils/fileLogger";
import {
  getAuthHeaderJson,
  getAuthToken,
  runWithAuth,
} from "./utils/requestContext";
import {
  getEditorSettingsUpload,
  type UserUploadedEditorSettings,
} from "./utils/editorSettings";
import { env } from "./utils/server-env";
import { getWwwClient } from "./utils/wwwClient";
import { getWwwOpenApiModule } from "./utils/wwwOpenApiModule";
import { CmuxVSCodeInstance } from "./vscode/CmuxVSCodeInstance";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance";
import { VSCodeInstance } from "./vscode/VSCodeInstance";
import { getWorktreePath, setupProjectWorkspace } from "./workspace";
import { workerExec } from "./utils/workerExec";
import rawSwitchBranchScript from "./utils/switch-branch.ts?raw";

const SWITCH_BRANCH_BUN_SCRIPT = rawSwitchBranchScript;

const { getApiEnvironmentsByIdVars } = await getWwwOpenApiModule();

/**
 * Upload the user's zsh history to the sandbox for autosuggestions.
 * This is a non-blocking operation that should be called after the terminal is created.
 * Only runs when NOT in web mode (i.e., when running locally with access to user's home dir).
 */
async function uploadZshHistory(params: {
  workerUrl: string;
  taskRunJwt: string;
}): Promise<void> {
  const { workerUrl, taskRunJwt } = params;

  try {
    const zshHistoryPath = join(homedir(), ".zsh_history");

    // Check if the file exists
    try {
      await fs.access(zshHistoryPath);
    } catch {
      serverLogger.info("[AgentSpawner] No zsh history file found, skipping upload");
      return;
    }

    // Read the zsh history file
    const historyContent = await fs.readFile(zshHistoryPath);

    // Create form data for upload
    const formData = new FormData();
    const blob = new Blob([historyContent], { type: "application/octet-stream" });
    formData.append("file", blob, ".zsh_history");
    formData.append("path", "/root/.zsh_history");

    const uploadUrl = `${workerUrl}/upload-file`;

    serverLogger.info(`[AgentSpawner] Uploading zsh history to ${uploadUrl}`);

    const response = await fetch(uploadUrl, {
      method: "POST",
      headers: {
        "x-cmux-token": taskRunJwt,
      },
      body: formData,
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Upload failed: ${error}`);
    }

    const result = await response.json();
    serverLogger.info(
      `[AgentSpawner] Successfully uploaded zsh history: ${result.path} (${result.size} bytes)`
    );
  } catch (error) {
    // Log error but don't throw - this is a non-blocking enhancement
    serverLogger.error("[AgentSpawner] Failed to upload zsh history:", error);
  }
}

export interface AgentSpawnResult {
  agentName: string;
  terminalId: string;
  taskRunId: string | Id<"taskRuns">;
  worktreePath: string;
  vscodeUrl?: string;
  success: boolean;
  error?: string;
}

export async function spawnAgent(
  agent: AgentConfig,
  taskId: Id<"tasks">,
  options: {
    repoUrl?: string;
    branch?: string;
    taskDescription: string;
    isCloudMode?: boolean;
    environmentId?: Id<"environments">;
    images?: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
    theme?: "dark" | "light" | "system";
    newBranch?: string; // Optional pre-generated branch name
    taskRunId?: Id<"taskRuns">; // Optional pre-created task run ID
  },
  teamSlugOrId: string
): Promise<AgentSpawnResult> {
  // Declare taskRunId outside try block so it's accessible in catch for error reporting
  let taskRunId: Id<"taskRuns"> | null = options.taskRunId ?? null;

  try {
    // Capture the current auth token and header JSON from AsyncLocalStorage so we can
    // re-enter the auth context inside async event handlers later.
    const capturedAuthToken = getAuthToken();
    const capturedAuthHeaderJson = getAuthHeaderJson();

    const newBranch =
      options.newBranch ||
      (await generateNewBranchName(options.taskDescription, teamSlugOrId));
    serverLogger.info(
      `[AgentSpawner] New Branch: ${newBranch}, Base Branch: ${
        options.branch ?? "(auto)"
      }`
    );

    let taskRunJwt: string;

    if (options.taskRunId) {
      // Task run was pre-created - get JWT and update branch
      const [jwtResult] = await Promise.all([
        getConvex().mutation(api.taskRuns.getJwt, {
          teamSlugOrId,
          taskRunId: options.taskRunId,
        }),
        getConvex().mutation(api.taskRuns.updateBranch, {
          teamSlugOrId,
          id: options.taskRunId,
          newBranch,
        }),
      ]);
      taskRunJwt = jwtResult.jwt;
      taskRunId = options.taskRunId;
      serverLogger.info(
        `[AgentSpawner] Using pre-created task run ${taskRunId}, updated branch to ${newBranch}`
      );
    } else {
      // Create a task run for this specific agent (legacy path)
      const { taskRunId: createdTaskRunId, jwt } =
        await getConvex().mutation(api.taskRuns.create, {
          teamSlugOrId,
          taskId: taskId,
          prompt: options.taskDescription,
          agentName: agent.name,
          newBranch,
          environmentId: options.environmentId,
        });
      taskRunId = createdTaskRunId;
      taskRunJwt = jwt;
    }

    // After this point, taskRunId is guaranteed to be non-null
    const runId = taskRunId;

    // Fetch the task to get image storage IDs
    const task = await getConvex().query(api.tasks.getById, {
      teamSlugOrId,
      id: taskId,
    });

    // Process prompt to handle images
    let processedTaskDescription = options.taskDescription;
    const imageFiles: Array<{ path: string; base64: string }> = [];

    // Handle images from either the options (for backward compatibility) or from the task
    let imagesToProcess = options.images || [];

    // If task has images with storage IDs, download them
    if (task && task.images && task.images.length > 0) {
      const imageUrlsResult = await getConvex().query(api.storage.getUrls, {
        teamSlugOrId,
        storageIds: task.images.map((image) => image.storageId),
      });
      const downloadedImages = await Promise.all(
        task.images.map(async (taskImage) => {
          const imageUrl = imageUrlsResult.find(
            (url) => url.storageId === taskImage.storageId
          );
          if (imageUrl) {
            // Download image from Convex storage
            const response = await fetch(imageUrl.url);
            const buffer = await response.arrayBuffer();
            const base64 = Buffer.from(buffer).toString("base64");
            return {
              src: `data:image/png;base64,${base64}`,
              fileName: taskImage.fileName,
              altText: taskImage.altText,
            };
          }
          return null;
        })
      );
      const filteredImages = downloadedImages.filter((img) => img !== null);
      imagesToProcess = filteredImages as Array<{
        src: string;
        fileName?: string;
        altText: string;
      }>;
    }

    if (imagesToProcess.length > 0) {
      serverLogger.info(
        `[AgentSpawner] Processing ${imagesToProcess.length} images`
      );
      serverLogger.info(
        `[AgentSpawner] Original task description: ${options.taskDescription}`
      );

      // Create image files and update prompt
      imagesToProcess.forEach((image, index) => {
        // Sanitize filename to remove special characters
        let fileName = image.fileName || `image_${index + 1}.png`;
        serverLogger.info(`[AgentSpawner] Original filename: ${fileName}`);
        // Replace non-ASCII characters and spaces with underscores
        fileName = fileName.replace(/[^\x20-\x7E]/g, "_").replace(/\s+/g, "_");
        serverLogger.info(`[AgentSpawner] Sanitized filename: ${fileName}`);

        const imagePath = `/root/prompt/${fileName}`;
        imageFiles.push({
          path: imagePath,
          base64: image.src.split(",")[1] || image.src, // Remove data URL prefix if present
        });

        // Replace image reference in prompt with file path
        // First try to replace the original filename (exact match, no word boundaries)
        if (image.fileName) {
          const beforeReplace = processedTaskDescription;
          // Escape special regex characters in the filename
          const escapedFileName = image.fileName.replace(
            /[.*+?^${}()|[\]\\]/g,
            "\\$&"
          );
          processedTaskDescription = processedTaskDescription.replace(
            new RegExp(escapedFileName, "g"),
            imagePath
          );
          if (beforeReplace !== processedTaskDescription) {
            serverLogger.info(
              `[AgentSpawner] Replaced "${image.fileName}" with "${imagePath}"`
            );
          } else {
            serverLogger.warn(
              `[AgentSpawner] Failed to find "${image.fileName}" in prompt text`
            );
          }
        }

        // Also replace just the filename without extension in case it appears that way
        const nameWithoutExt = image.fileName?.replace(/\.[^/.]+$/, "");
        if (
          nameWithoutExt &&
          processedTaskDescription.includes(nameWithoutExt)
        ) {
          const beforeReplace = processedTaskDescription;
          const escapedName = nameWithoutExt.replace(
            /[.*+?^${}()|[\]\\]/g,
            "\\$&"
          );
          processedTaskDescription = processedTaskDescription.replace(
            new RegExp(escapedName, "g"),
            imagePath
          );
          if (beforeReplace !== processedTaskDescription) {
            serverLogger.info(
              `[AgentSpawner] Replaced "${nameWithoutExt}" with "${imagePath}"`
            );
          }
        }
      });

      serverLogger.info(
        `[AgentSpawner] Processed task description: ${processedTaskDescription}`
      );
    }

    // Callback URL for stop hooks to call crown/complete (Convex site URL)
    const callbackUrl = env.NEXT_PUBLIC_CONVEX_URL.replace('.convex.cloud', '.convex.site');

    let envVars: Record<string, string> = {
      CMUX_PROMPT: processedTaskDescription,
      CMUX_TASK_RUN_ID: taskRunId,
      CMUX_TASK_RUN_JWT: taskRunJwt,
      CMUX_CALLBACK_URL: callbackUrl,
      PROMPT: processedTaskDescription,
    };

    if (options.environmentId) {
      try {
        const envRes = await getApiEnvironmentsByIdVars({
          client: getWwwClient(),
          path: { id: String(options.environmentId) },
          query: { teamSlugOrId },
        });
        const envContent = envRes.data?.envVarsContent;
        if (envContent && envContent.trim().length > 0) {
          const parsed = parseDotenv(envContent);
          if (Object.keys(parsed).length > 0) {
            const preserved = {
              CMUX_PROMPT: envVars.CMUX_PROMPT,
              CMUX_TASK_RUN_ID: envVars.CMUX_TASK_RUN_ID,
              PROMPT: envVars.PROMPT,
            };
            envVars = {
              ...envVars,
              ...parsed,
              ...preserved,
            };
            serverLogger.info(
              `[AgentSpawner] Injected ${Object.keys(parsed).length} env vars from environment ${String(
                options.environmentId
              )}`
            );
          }
        }
      } catch (error) {
        serverLogger.error(
          `[AgentSpawner] Failed to load environment env vars for ${String(
            options.environmentId
          )}`,
          error
        );
      }
    }

    let authFiles: EnvironmentResult["files"] = [];
    let startupCommands: string[] = [];
    let postStartCommands: EnvironmentResult["postStartCommands"] = [];
    let unsetEnvVars: string[] = [];

    // Fetch API keys from Convex BEFORE calling agent.environment()
    // so agents can access them in their environment configuration
    const userApiKeys = await getConvex().query(api.apiKeys.getAllForAgents, {
      teamSlugOrId,
    });

    const apiKeys: Record<string, string> = {
      ...userApiKeys,
    };

    // Use environment property if available
    if (agent.environment) {
      const envResult = await agent.environment({
        taskRunId: taskRunId,
        prompt: processedTaskDescription,
        taskRunJwt,
        apiKeys,
        callbackUrl,
      });
      envVars = {
        ...envVars,
        ...envResult.env,
      };
      authFiles = envResult.files;
      startupCommands = envResult.startupCommands || [];
      postStartCommands = envResult.postStartCommands || [];
      unsetEnvVars = envResult.unsetEnv || [];
    }

    // Apply API keys: prefer agent-provided hook if present; otherwise default env injection
    if (typeof agent.applyApiKeys === "function") {
      const applied = await agent.applyApiKeys(apiKeys);
      if (applied.env) envVars = { ...envVars, ...applied.env };
      if (applied.files && applied.files.length > 0) {
        authFiles.push(...applied.files);
      }
      if (applied.startupCommands && applied.startupCommands.length > 0) {
        startupCommands.push(...applied.startupCommands);
      }
      if (applied.postStartCommands && applied.postStartCommands.length > 0) {
        postStartCommands = [...(postStartCommands || []), ...applied.postStartCommands];
      }
      if (applied.unsetEnv && applied.unsetEnv.length > 0) {
        unsetEnvVars.push(...applied.unsetEnv);
      }
    } else if (agent.apiKeys) {
      for (const keyConfig of agent.apiKeys) {
        const key = apiKeys[keyConfig.envVar];
        if (key && key.trim().length > 0) {
          const injectName = keyConfig.mapToEnvVar || keyConfig.envVar;
          envVars[injectName] = key;
        }
      }
    }

    // Fetch user-uploaded editor settings from Convex (for web mode users)
    let userUploadedSettings: UserUploadedEditorSettings | null = null;
    try {
      const userEditorSettingsFromDb = await getConvex().query(
        api.userEditorSettings.get,
        { teamSlugOrId }
      );
      if (userEditorSettingsFromDb) {
        userUploadedSettings = {
          settingsJson: userEditorSettingsFromDb.settingsJson ?? undefined,
          keybindingsJson: userEditorSettingsFromDb.keybindingsJson ?? undefined,
          snippets: userEditorSettingsFromDb.snippets ?? undefined,
          extensions: userEditorSettingsFromDb.extensions ?? undefined,
        };
      }
    } catch (error) {
      serverLogger.warn(
        "[AgentSpawner] Failed to fetch user editor settings from Convex",
        error
      );
    }

    // Get editor settings (user-uploaded overrides auto-detected)
    const editorSettings = await getEditorSettingsUpload(userUploadedSettings);
    if (editorSettings) {
      if (editorSettings.authFiles.length > 0) {
        authFiles = [...authFiles, ...editorSettings.authFiles];
      }
      if (editorSettings.startupCommands.length > 0) {
        startupCommands = [
          ...editorSettings.startupCommands,
          ...startupCommands,
        ];
      }
    }

    // Remove environment variables specified by the agent
    for (const envVar of unsetEnvVars) {
      if (envVar in envVars) {
        delete envVars[envVar];
        serverLogger.info(
          `[AgentSpawner] Removed ${envVar} from environment for ${agent.name} as requested by agent config`
        );
      }
    }

    // Replace $PROMPT placeholders in args with $CMUX_PROMPT token for shell-time expansion
    const processedArgs = agent.args.map((arg) => {
      if (arg.includes("$PROMPT")) {
        return arg.replace(/\$PROMPT/g, "$CMUX_PROMPT");
      }
      return arg;
    });

    const usesDangerousPermissions = processedArgs.includes(
      "--dangerously-skip-permissions"
    );
    if (usesDangerousPermissions && envVars.IS_SANDBOX !== "1") {
      const previousValue = envVars.IS_SANDBOX;
      envVars.IS_SANDBOX = "1";
      serverLogger.info(
        `[AgentSpawner] Setting IS_SANDBOX=1 for ${agent.name} (was ${previousValue ?? "unset"})`
      );
    }

    const agentCommand = `${agent.command} ${processedArgs.join(" ")}`;

    // Build the tmux session command that will be sent via socket.io
    const tmuxSessionName = sanitizeTmuxSessionName("cmux");

    serverLogger.info(
      `[AgentSpawner] Building command for agent ${agent.name}:`
    );
    serverLogger.info(`  Raw command: ${agent.command}`);
    serverLogger.info(`  Processed args: ${processedArgs.join(" ")}`);
    serverLogger.info(`  Agent command: ${agentCommand}`);
    serverLogger.info(`  Tmux session name: ${tmuxSessionName}`);

    let vscodeInstance: VSCodeInstance;
    let worktreePath: string;

    console.log("[AgentSpawner] [isCloudMode]", options.isCloudMode);

    if (options.isCloudMode) {
      // For remote sandboxes (Morph-backed via www API)
      vscodeInstance = new CmuxVSCodeInstance({
        agentName: agent.name,
        taskRunId,
        taskId,
        theme: options.theme,
        teamSlugOrId,
        repoUrl: options.repoUrl,
        branch: options.branch,
        newBranch,
        environmentId: options.environmentId,
        taskRunJwt,
      });

      worktreePath = "/root/workspace";
    } else {
      // For Docker, set up worktree as before
      const worktreeInfo = await getWorktreePath(
        {
          repoUrl: options.repoUrl!,
          branch: newBranch,
        },
        teamSlugOrId
      );

      // Setup workspace
      const workspaceResult = await setupProjectWorkspace({
        repoUrl: options.repoUrl!,
        // If not provided, setupProjectWorkspace detects default from origin
        branch: options.branch,
        worktreeInfo,
      });

      if (!workspaceResult.success || !workspaceResult.worktreePath) {
        return {
          agentName: agent.name,
          terminalId: "",
          taskRunId,
          worktreePath: "",
          success: false,
          error: workspaceResult.error || "Failed to setup workspace",
        };
      }

      worktreePath = workspaceResult.worktreePath;

      serverLogger.info(
        `[AgentSpawner] Creating DockerVSCodeInstance for ${agent.name}`
      );
      vscodeInstance = new DockerVSCodeInstance({
        workspacePath: worktreePath,
        agentName: agent.name,
        taskRunId,
        taskId,
        theme: options.theme,
        teamSlugOrId,
        envVars,
      });
    }

    // Update the task run with the worktree path (retry on OCC)
    await retryOnOptimisticConcurrency(() =>
      getConvex().mutation(api.taskRuns.updateWorktreePath, {
        teamSlugOrId,
        id: runId,
        worktreePath: worktreePath,
      })
    );

    // Store the VSCode instance
    // VSCodeInstance.getInstances().set(vscodeInstance.getInstanceId(), vscodeInstance);

    serverLogger.info(`Starting VSCode instance for agent ${agent.name}...`);

    // Start the VSCode instance
    const vscodeInfo = await vscodeInstance.start();
    const vscodeUrl = vscodeInfo.workspaceUrl;

    serverLogger.info(
      `VSCode instance spawned for agent ${agent.name}: ${vscodeUrl}`
    );

    if (options.isCloudMode && vscodeInstance instanceof CmuxVSCodeInstance) {
      console.log("[AgentSpawner] [isCloudMode] Setting up devcontainer");
      void vscodeInstance
        .setupDevcontainer()
        .catch((err) =>
          serverLogger.error(
            "[AgentSpawner] setupDevcontainer encountered an error",
            err
          )
        );
    }

    // Start file watching for real-time diff updates
    serverLogger.info(
      `[AgentSpawner] Starting file watch for ${agent.name} at ${worktreePath}`
    );
    vscodeInstance.startFileWatch(worktreePath);

    // Set up file change event handler for real-time diff updates
    vscodeInstance.on("file-changes", async (data) => {
      serverLogger.info(
        `[AgentSpawner] File changes detected for ${agent.name}:`,
        { changeCount: data.changes.length, taskRunId: data.taskRunId }
      );
    });

    // Set up terminal-failed event handler
    vscodeInstance.on("terminal-failed", async (data: WorkerTerminalFailed) => {
      try {
        serverLogger.error(
          `[AgentSpawner] Terminal failed for ${agent.name}:`,
          data
        );
        if (data.taskRunId !== taskRunId) {
          serverLogger.warn(
            `[AgentSpawner] Failure event taskRunId mismatch; ignoring`
          );
          return;
        }

        // Mark the run as failed with error message
        await runWithAuth(capturedAuthToken, capturedAuthHeaderJson, async () =>
          retryOnOptimisticConcurrency(() =>
            getConvex().mutation(api.taskRuns.fail, {
              teamSlugOrId,
              id: runId,
              errorMessage: data.errorMessage || "Terminal failed",
              // WorkerTerminalFailed does not include exitCode in schema; default to 1
              exitCode: 1,
            })
          )
        );

        serverLogger.info(
          `[AgentSpawner] Marked taskRun ${runId} as failed`
        );
      } catch (error) {
        serverLogger.error(
          `[AgentSpawner] Error handling terminal-failed:`,
          error
        );
      }
    });

    // Get ports if it's a Docker instance
    let ports:
      | {
          vscode: string;
          worker: string;
          extension?: string;
          proxy?: string;
          vnc?: string;
        }
      | undefined;
    if (vscodeInstance instanceof DockerVSCodeInstance) {
      const dockerPorts = vscodeInstance.getPorts();
      if (dockerPorts && dockerPorts.vscode && dockerPorts.worker) {
        ports = {
          vscode: dockerPorts.vscode,
          worker: dockerPorts.worker,
          ...(dockerPorts.extension
            ? { extension: dockerPorts.extension }
            : {}),
          ...(dockerPorts.proxy ? { proxy: dockerPorts.proxy } : {}),
          ...(dockerPorts.vnc ? { vnc: dockerPorts.vnc } : {}),
        };
      }
    }

    // Update VSCode instance information in Convex (retry on OCC)
    // Skip if www already persisted the VSCode info (cloud mode optimization)
    if (!vscodeInfo.vscodePersisted) {
      await retryOnOptimisticConcurrency(() =>
        getConvex().mutation(api.taskRuns.updateVSCodeInstance, {
          teamSlugOrId,
          id: runId,
          vscode: {
            provider: vscodeInfo.provider,
            containerName: vscodeInstance.getName(),
            status: "running",
            url: vscodeInfo.url,
            workspaceUrl: vscodeInfo.workspaceUrl,
            startedAt: Date.now(),
            ...(ports ? { ports } : {}),
          },
        })
      );
    } else {
      serverLogger.info(
        `[AgentSpawner] Skipping updateVSCodeInstance - already persisted by www`
      );
    }

    // Use runId as terminal ID for compatibility
    const terminalId = runId;

    // Log auth files if any
    if (authFiles.length > 0) {
      serverLogger.info(
        `[AgentSpawner] Prepared ${authFiles.length} auth files for agent ${agent.name}`
      );
    }

    // After VSCode instance is started, create the terminal with tmux session
    serverLogger.info(
      `[AgentSpawner] Preparing to send terminal creation command for ${agent.name}`
    );

    // Start fetching workspace config early (for maintenance script) - runs in parallel with worker connection
    const workspaceConfigPromise = (async () => {
      if (options.isCloudMode || !options.repoUrl) return null;
      const parsedRepo = parseGithubRepoUrl(options.repoUrl);
      if (!parsedRepo) return null;
      try {
        const config = await getConvex().query(api.workspaceConfigs.get, {
          teamSlugOrId,
          projectFullName: parsedRepo.fullName,
        });
        return { config, projectFullName: parsedRepo.fullName };
      } catch (error) {
        serverLogger.warn(`[AgentSpawner] Failed to fetch workspace config`, error);
        return null;
      }
    })();

    // Wait for worker connection if not already connected
    if (!vscodeInstance.isWorkerConnected()) {
      serverLogger.info(`[AgentSpawner] Waiting for worker connection...`);
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(() => {
          serverLogger.error(
            `[AgentSpawner] Timeout waiting for worker connection`
          );
          resolve();
        }, 30000); // 30 second timeout

        vscodeInstance.once("worker-connected", () => {
          clearTimeout(timeout);
          resolve();
        });
      });
    }

    // Get the worker socket
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket) {
      serverLogger.error(
        `[AgentSpawner] No worker socket available for ${agent.name}`
      );
      return {
        agentName: agent.name,
        terminalId,
        taskRunId,
        worktreePath,
        vscodeUrl,
        success: false,
        error: "No worker connection available",
      };
    }
    if (!vscodeInstance.isWorkerConnected()) {
      throw new Error("Worker socket not available");
    }

    // Run maintenance script for Docker containers in a cmux-pty session (fire-and-forget)
    if (!options.isCloudMode && vscodeInstance instanceof DockerVSCodeInstance) {
      void (async () => {
        try {
          // Use pre-fetched workspace config
          const workspaceConfigResult = await workspaceConfigPromise;
          if (!workspaceConfigResult?.config?.maintenanceScript?.trim()) {
            return;
          }

          const { config: workspaceConfig, projectFullName } = workspaceConfigResult;
          serverLogger.info(
            `[AgentSpawner] Running maintenance script for ${projectFullName} via cmux-pty`
          );

          // Write maintenance script to a file first (like cloud mode does)
          const CMUX_RUNTIME_DIR = "/var/tmp/cmux-scripts";
          const maintenanceScriptPath = `${CMUX_RUNTIME_DIR}/maintenance.sh`;
          const maintenanceScriptContent = `#!/bin/zsh
set -eu

cd /root/workspace

echo "=== Maintenance Script Started at \\$(date) ==="
${workspaceConfig.maintenanceScript}
echo "=== Maintenance Script Completed at \\$(date) ==="
`;

          // Create directory and write script file using heredoc
          const writeScriptCommand = `mkdir -p ${CMUX_RUNTIME_DIR} && cat > ${maintenanceScriptPath} <<'MAINTENANCE_SCRIPT_EOF'
${maintenanceScriptContent}
MAINTENANCE_SCRIPT_EOF
chmod +x ${maintenanceScriptPath}`;

          const writeScriptResult = await workerExec({
            workerSocket,
            command: "bash",
            args: ["-c", writeScriptCommand],
            cwd: "/root/workspace",
            env: {},
            timeout: 10000,
          });

          if (writeScriptResult.exitCode !== 0) {
            serverLogger.error(
              `[AgentSpawner] Failed to write maintenance script file`,
              { exitCode: writeScriptResult.exitCode, stdout: writeScriptResult.stdout, stderr: writeScriptResult.stderr }
            );
            return;
          }

          serverLogger.info(`[AgentSpawner] Wrote maintenance script to ${maintenanceScriptPath}`);

          // Create a cmux-pty session for the maintenance script
          const createResult = await workerExec({
            workerSocket,
            command: "cmux-pty",
            args: ["new", "--name", "maintenance", "--cwd", "/root/workspace", "--detached"],
            cwd: "/root/workspace",
            env: {},
            timeout: 10000,
          });

          if (createResult.exitCode !== 0) {
            serverLogger.error(
              `[AgentSpawner] Failed to create maintenance PTY session`,
              { exitCode: createResult.exitCode, stdout: createResult.stdout, stderr: createResult.stderr }
            );
            return;
          }

          serverLogger.info(`[AgentSpawner] Created maintenance PTY session`);

          // Send command to run the script file
          const sendResult = await workerExec({
            workerSocket,
            command: "cmux-pty",
            args: ["send-keys", "maintenance", maintenanceScriptPath, "Enter"],
            cwd: "/root/workspace",
            env: {},
            timeout: 10000,
          });

          if (sendResult.exitCode !== 0) {
            serverLogger.error(
              `[AgentSpawner] Failed to send maintenance script to PTY`,
              { exitCode: sendResult.exitCode, stdout: sendResult.stdout, stderr: sendResult.stderr }
            );
            await getConvex().mutation(api.taskRuns.updateEnvironmentError, {
              teamSlugOrId,
              id: runId,
              maintenanceError: `Failed to send maintenance script: ${sendResult.stderr || sendResult.stdout}`,
              devError: undefined,
            });
          } else {
            serverLogger.info(
              `[AgentSpawner] Maintenance script sent to PTY for ${projectFullName}`
            );
            // Clear any previous error (script is now running in PTY)
            await getConvex().mutation(api.taskRuns.updateEnvironmentError, {
              teamSlugOrId,
              id: runId,
              maintenanceError: undefined,
              devError: undefined,
            });
          }
        } catch (error) {
          serverLogger.error(
            `[AgentSpawner] Failed to run maintenance script`,
            error
          );
        }
      })();
    }

    const actualCommand = agent.command;
    const actualArgs = processedArgs;

    // Build a shell command string so CMUX env vars expand inside tmux session
    const shellEscaped = (s: string) => {
      // If this arg references any CMUX env var (e.g., $CMUX_PROMPT, $CMUX_TASK_RUN_ID),
      // wrap in double quotes to allow shell expansion.
      if (s.includes("$CMUX_")) {
        return `"${s.replace(/"/g, '\\"')}"`;
      }
      // Otherwise single-quote and escape any existing single quotes
      return `'${s.replace(/'/g, "'\\''")}'`;
    };
    const commandString = [actualCommand, ...actualArgs]
      .map(shellEscaped)
      .join(" ");

    // Log the actual command for Codex agents to debug notify command
    if (agent.name.toLowerCase().includes("codex")) {
      serverLogger.info(
        `[AgentSpawner] Codex command string: ${commandString}`
      );
      serverLogger.info(`[AgentSpawner] Codex raw args:`, actualArgs);
    }

    // Build unset command for environment variables
    const unsetCommand =
      unsetEnvVars.length > 0 ? `unset ${unsetEnvVars.join(" ")}; ` : "";

    // For Codex agents, use direct command execution to preserve notify argument
    // The notify command contains complex JSON that gets mangled through shell layers
    const tmuxArgs = agent.name.toLowerCase().includes("codex")
      ? [
          "new-session",
          "-d",
          "-s",
          tmuxSessionName,
          "-c",
          "/root/workspace",
          actualCommand,
          ...actualArgs.map((arg) => {
            // Replace $CMUX_PROMPT with actual prompt value
            if (arg === "$CMUX_PROMPT") {
              return processedTaskDescription;
            }
            return arg;
          }),
        ]
      : [
          "new-session",
          "-d",
          "-s",
          tmuxSessionName,
          "bash",
          "-lc",
          `${unsetCommand}exec ${commandString}`,
        ];

    // Build cmux-pty specific command (the actual agent command without tmux/bash wrapper)
    // For Codex agents, replace $CMUX_PROMPT with actual prompt value (matching tmux behavior)
    // This avoids relying on shell expansion which can fail due to timing or env setup issues
    let ptyCommandString: string;
    if (agent.name.toLowerCase().includes("codex")) {
      // For Codex: build command with prompt value directly embedded (like tmuxArgs does)
      const ptyArgs = actualArgs.map((arg) => {
        if (arg === "$CMUX_PROMPT") {
          return processedTaskDescription;
        }
        return arg;
      });
      // Shell-escape all args with single quotes (no env var expansion needed)
      const ptyShellEscaped = (s: string) =>
        `'${s.replace(/'/g, "'\\''")}'`;
      const ptyCommandStr = [actualCommand, ...ptyArgs]
        .map(ptyShellEscaped)
        .join(" ");
      ptyCommandString = `${unsetCommand}${ptyCommandStr}`;
      serverLogger.info(
        `[AgentSpawner] Codex ptyCommand (prompt embedded): ${ptyCommandString.slice(0, 200)}...`
      );
    } else {
      // For other agents: use env var expansion as before
      ptyCommandString = `${unsetCommand}${commandString}`;
    }

    // Use cmux-pty backend - worker will fall back to tmux if cmux-pty server unavailable
    const terminalCreationCommand: WorkerCreateTerminal = {
      terminalId: tmuxSessionName,
      backend: "cmux-pty",
      // tmux command/args for fallback when cmux-pty is unavailable
      command: "tmux",
      args: tmuxArgs,
      // cmux-pty specific: the actual command to run in the PTY shell
      ptyCommand: ptyCommandString,
      cols: 80,
      rows: 74,
      env: envVars,
      taskRunContext: {
        taskRunToken: taskRunJwt,
        prompt: processedTaskDescription,
        convexUrl: env.NEXT_PUBLIC_CONVEX_URL,
      },
      taskRunId,
      agentModel: agent.name,
      authFiles,
      startupCommands,
      postStartCommands,
      cwd: "/root/workspace",
    };

    const switchBranch = async () => {
      const scriptPath = `/tmp/cmux-switch-branch-${Date.now()}.ts`;
      const command = `
set -eu
cat <<'CMUX_SWITCH_BRANCH_EOF' > ${scriptPath}
${SWITCH_BRANCH_BUN_SCRIPT}
CMUX_SWITCH_BRANCH_EOF
bun run ${scriptPath}
EXIT_CODE=$?
rm -f ${scriptPath}
exit $EXIT_CODE
`;

      const { exitCode, stdout, stderr } = await workerExec({
        workerSocket,
        command: "bash",
        args: ["-lc", command],
        cwd: "/root/workspace",
        env: {
          CMUX_BRANCH_NAME: newBranch,
        },
        timeout: 60000,
      });

      if (exitCode !== 0) {
        const truncatedStdout = stdout?.slice(0, 2000) ?? "";
        const truncatedStderr = stderr?.slice(0, 2000) ?? "";
        serverLogger.error(
          `[AgentSpawner] Branch switch script failed for ${newBranch} (exit ${exitCode})`,
          {
            stdout: truncatedStdout,
            stderr: truncatedStderr,
          }
        );

        const trimmedStderr = truncatedStderr.trim();
        const trimmedStdout = truncatedStdout.trim();
        const detailParts = [
          trimmedStderr ? `stderr: ${trimmedStderr}` : null,
          trimmedStdout ? `stdout: ${trimmedStdout}` : null,
        ].filter((part): part is string => part !== null);

        const detailText = detailParts.join(" | ");
        const summarizedDetails =
          detailText.length > 600 ? `${detailText.slice(0, 600)}…` : detailText;

        const errorMessage =
          detailParts.length > 0
            ? `Branch switch script failed for ${newBranch} (exit ${exitCode}): ${summarizedDetails}`
            : `Branch switch script failed for ${newBranch} (exit ${exitCode}) with no output`;

        throw new Error(errorMessage);
      }

      serverLogger.info(
        `[AgentSpawner] Branch switch script completed for ${newBranch}`
      );
    };

    try {
      await switchBranch();
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      serverLogger.error(
        `[AgentSpawner] Branch switch command errored for ${newBranch}`,
        err
      );
      await vscodeInstance.stop().catch((stopError) => {
        serverLogger.error(
          `[AgentSpawner] Failed to stop VSCode instance after branch switch failure`,
          stopError
        );
      });
      throw err;
    }

    serverLogger.info(
      `[AgentSpawner] Sending terminal creation command at ${new Date().toISOString()}:`
    );
    serverLogger.info(`  Terminal ID: ${tmuxSessionName}`);
    // serverLogger.info(
    //   `  Full terminal command object:`,
    //   JSON.stringify(
    //     terminalCreationCommand,
    //     (_key, value) => {
    //       if (typeof value === "string" && value.length > 1000) {
    //         return value.slice(0, 1000) + "...";
    //       }
    //       return value;
    //     },
    //     2
    //   )
    // );

    // Create image files if any
    if (imageFiles.length > 0) {
      serverLogger.info(
        `[AgentSpawner] Creating ${imageFiles.length} image files...`
      );

      // First create the prompt directory
      await new Promise<void>((resolve) => {
        try {
          workerSocket.timeout(10000).emit(
            "worker:exec",
            {
              command: "mkdir",
              args: ["-p", "/root/prompt"],
              cwd: "/root",
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError) {
                // Handle timeout errors gracefully
                if (
                  timeoutError instanceof Error &&
                  timeoutError.message === "operation has timed out"
                ) {
                  serverLogger.error(
                    "Socket timeout while creating prompt directory",
                    timeoutError
                  );
                } else {
                  serverLogger.error(
                    "Failed to create prompt directory",
                    timeoutError
                  );
                }
              } else if (result?.error) {
                serverLogger.error(
                  "Failed to create prompt directory",
                  result.error
                );
              }
              resolve();
            }
          );
        } catch (err) {
          serverLogger.error(
            "Error emitting command to create prompt directory",
            err
          );
          resolve();
        }
      });

      // Upload each image file using HTTP endpoint
      for (const imageFile of imageFiles) {
        try {
          // Convert base64 to buffer
          const base64Data = imageFile.base64.includes(",")
            ? imageFile.base64.split(",")[1]
            : imageFile.base64;
          const buffer = Buffer.from(base64Data, "base64");

          // Create form data
          const formData = new FormData();
          const blob = new Blob([buffer], { type: "image/png" });
          formData.append("image", blob, "image.png");
          formData.append("path", imageFile.path);

          // Get upload URL from VSCode instance
          let uploadUrl: string;
          if (vscodeInstance instanceof DockerVSCodeInstance) {
            const workerPort = vscodeInstance.getPorts()?.worker;
            uploadUrl = `http://localhost:${workerPort}/upload-image`;
          } else if (vscodeInstance instanceof CmuxVSCodeInstance) {
            const workerUrl = vscodeInstance.getWorkerUrl();
            if (!workerUrl) {
              throw new Error("Worker URL not available for cloud instance");
            }
            uploadUrl = `${workerUrl}/upload-image`;
          } else {
            throw new Error("Unknown VSCode instance type");
          }

          serverLogger.info(`[AgentSpawner] Uploading image to ${uploadUrl}`);

          const response = await fetch(uploadUrl, {
            method: "POST",
            headers: {
              "x-cmux-token": taskRunJwt,
            },
            body: formData,
          });

          if (!response.ok) {
            const error = await response.text();
            throw new Error(`Upload failed: ${error}`);
          }

          const result = await response.json();
          serverLogger.info(
            `[AgentSpawner] Successfully uploaded image: ${result.path} (${result.size} bytes)`
          );
        } catch (error) {
          serverLogger.error(
            `[AgentSpawner] Failed to upload image ${imageFile.path}:`,
            error
          );
        }
      }
    }

    // Send the terminal creation command
    serverLogger.info(
      `[AgentSpawner] About to emit worker:create-terminal at ${new Date().toISOString()}`
    );
    serverLogger.info(
      `[AgentSpawner] Socket connected:`,
      workerSocket.connected
    );
    serverLogger.info(`[AgentSpawner] Socket id:`, workerSocket.id);

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        serverLogger.error(
          `[AgentSpawner] Timeout waiting for terminal creation response after 30s`
        );
        reject(new Error("Timeout waiting for terminal creation"));
      }, 30000);

      workerSocket.emit(
        "worker:create-terminal",
        terminalCreationCommand,
        (result) => {
          clearTimeout(timeout);
          serverLogger.info(
            `[AgentSpawner] Got response from worker:create-terminal at ${new Date().toISOString()}:`,
            result
          );
          if (result.error) {
            reject(result.error);
            return;
          }
          serverLogger.info("Terminal created successfully", result);
          resolve(result.data);
        }
      );
      serverLogger.info(
        `[AgentSpawner] Emitted worker:create-terminal at ${new Date().toISOString()}`
      );
    });

    // Upload zsh history for autosuggestions (non-blocking, only when NOT in web mode)
    // In web mode, we don't have access to the user's local files
    if (!env.NEXT_PUBLIC_WEB_MODE) {
      // Get the worker URL for the upload
      let workerUrl: string | null = null;
      if (vscodeInstance instanceof CmuxVSCodeInstance) {
        workerUrl = vscodeInstance.getWorkerUrl();
      } else if (vscodeInstance instanceof DockerVSCodeInstance) {
        const workerPort = vscodeInstance.getPorts()?.worker;
        if (workerPort) {
          workerUrl = `http://localhost:${workerPort}`;
        }
      }

      if (workerUrl) {
        // Fire-and-forget: don't await, don't block the return
        void uploadZshHistory({
          workerUrl,
          taskRunJwt,
        }).catch((err) => {
          serverLogger.error("[AgentSpawner] Zsh history upload failed:", err);
        });
      }
    }

    return {
      agentName: agent.name,
      terminalId,
      taskRunId,
      worktreePath,
      vscodeUrl,
      success: true,
    };
  } catch (error) {
    serverLogger.error("Error spawning agent", error);
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";

    // Mark the task run as failed in Convex so the UI shows the failure
    if (taskRunId) {
      const failedRunId = taskRunId; // Capture for TypeScript narrowing
      try {
        await retryOnOptimisticConcurrency(() =>
          getConvex().mutation(api.taskRuns.fail, {
            teamSlugOrId,
            id: failedRunId,
            errorMessage: `Agent spawn failed: ${errorMessage}`,
            exitCode: 1,
          })
        );
        serverLogger.info(
          `[AgentSpawner] Marked taskRun ${failedRunId} as failed due to spawn error`
        );
      } catch (failError) {
        serverLogger.error(
          `[AgentSpawner] Failed to mark taskRun as failed`,
          failError
        );
      }
    }

    return {
      agentName: agent.name,
      terminalId: "",
      taskRunId: taskRunId ?? "",
      worktreePath: "",
      success: false,
      error: errorMessage,
    };
  }
}

export async function spawnAllAgents(
  taskId: Id<"tasks">,
  options: {
    repoUrl?: string;
    branch?: string;
    taskDescription: string;
    prTitle?: string;
    branchNames?: string[]; // Pre-generated branch names (one per agent)
    selectedAgents?: string[];
    taskRunIds?: Id<"taskRuns">[]; // Pre-created task run IDs (one per agent)
    isCloudMode?: boolean;
    environmentId?: Id<"environments">;
    images?: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
    theme?: "dark" | "light" | "system";
  },
  teamSlugOrId: string
): Promise<AgentSpawnResult[]> {
  // If selectedAgents is provided, map each entry to an AgentConfig to preserve duplicates
  const agentsToSpawn = options.selectedAgents
    ? options.selectedAgents
        .map((name) => AGENT_CONFIGS.find((agent) => agent.name === name))
        .filter((a): a is AgentConfig => Boolean(a))
    : AGENT_CONFIGS;

  // Validate taskRunIds count matches agents count if provided
  if (options.taskRunIds && options.taskRunIds.length !== agentsToSpawn.length) {
    serverLogger.warn(
      `[AgentSpawner] taskRunIds count (${options.taskRunIds.length}) doesn't match agents count (${agentsToSpawn.length})`
    );
  }

  // Use pre-generated branch names if provided, otherwise generate them
  let branchNames: string[];
  if (options.branchNames && options.branchNames.length >= agentsToSpawn.length) {
    branchNames = options.branchNames;
    serverLogger.info(
      `[AgentSpawner] Using ${branchNames.length} pre-generated branch names`
    );
  } else {
    // Generate unique branch names for all agents at once to ensure no collisions
    branchNames = options.prTitle
      ? await generateUniqueBranchNamesFromTitle(
          options.prTitle,
          agentsToSpawn.length,
          teamSlugOrId
        )
      : await generateUniqueBranchNames(
          options.taskDescription,
          agentsToSpawn.length,
          teamSlugOrId
        );
    serverLogger.info(
      `[AgentSpawner] Generated ${branchNames.length} unique branch names for agents`
    );
  }

  // Spawn all agents in parallel with their pre-generated branch names
  const results = await Promise.all(
    agentsToSpawn.map((agent, index) =>
      spawnAgent(
        agent,
        taskId,
        {
          ...options,
          newBranch: branchNames[index],
          taskRunId: options.taskRunIds?.[index],
        },
        teamSlugOrId
      )
    )
  );

  return results;
}
