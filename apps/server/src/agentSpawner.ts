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
import { parse as parseDotenv } from "dotenv";
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
  },
  teamSlugOrId: string
): Promise<AgentSpawnResult> {
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

    // Create a task run for this specific agent
    const { taskRunId, jwt: taskRunJwt } = await getConvex().mutation(
      api.taskRuns.create,
      {
        teamSlugOrId,
        taskId: taskId,
        prompt: options.taskDescription,
        agentName: agent.name,
        newBranch,
        environmentId: options.environmentId,
      }
    );

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

    let envVars: Record<string, string> = {
      CMUX_PROMPT: processedTaskDescription,
      CMUX_TASK_RUN_ID: taskRunId,
      CMUX_TASK_RUN_JWT: taskRunJwt,
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
    let unsetEnvVars: string[] = [];

    // Fetch API keys from Convex BEFORE calling agent.environment()
    // so agents can access them in their environment configuration
    const apiKeys = await getConvex().query(api.apiKeys.getAllForAgents, {
      teamSlugOrId,
    });

    // Use environment property if available
    if (agent.environment) {
      const envResult = await agent.environment({
        taskRunId: taskRunId,
        prompt: processedTaskDescription,
        taskRunJwt,
        apiKeys,
      });
      envVars = {
        ...envVars,
        ...envResult.env,
      };
      authFiles = envResult.files;
      startupCommands = envResult.startupCommands || [];
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
      });
    }

    // Update the task run with the worktree path (retry on OCC)
    await retryOnOptimisticConcurrency(() =>
      getConvex().mutation(api.taskRuns.updateWorktreePath, {
        teamSlugOrId,
        id: taskRunId,
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
              id: taskRunId,
              errorMessage: data.errorMessage || "Terminal failed",
              // WorkerTerminalFailed does not include exitCode in schema; default to 1
              exitCode: 1,
            })
          )
        );

        serverLogger.info(
          `[AgentSpawner] Marked taskRun ${taskRunId} as failed`
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
          xterm?: string;
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
          ...(dockerPorts.xterm ? { xterm: dockerPorts.xterm } : {}),
        };
      }
    }

    // Update VSCode instance information in Convex (retry on OCC)
    await retryOnOptimisticConcurrency(() =>
      getConvex().mutation(api.taskRuns.updateVSCodeInstance, {
        teamSlugOrId,
        id: taskRunId,
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

    // Use taskRunId as terminal ID for compatibility
    const terminalId = taskRunId;

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

    const terminalCreationCommand: WorkerCreateTerminal = {
      terminalId: tmuxSessionName,
      command: "tmux",
      args: tmuxArgs,
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

          // Get worker port from VSCode instance
          const workerPort =
            vscodeInstance instanceof DockerVSCodeInstance
              ? (vscodeInstance as DockerVSCodeInstance).getPorts()?.worker
              : "39377";

          const uploadUrl = `http://localhost:${workerPort}/upload-image`;

          serverLogger.info(`[AgentSpawner] Uploading image to ${uploadUrl}`);

          const response = await fetch(uploadUrl, {
            method: "POST",
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
    return {
      agentName: agent.name,
      terminalId: "",
      taskRunId: "",
      worktreePath: "",
      success: false,
      error: error instanceof Error ? error.message : "Unknown error",
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
    selectedAgents?: string[];
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

  // Generate unique branch names for all agents at once to ensure no collisions
  const branchNames = options.prTitle
    ? await generateUniqueBranchNamesFromTitle(
        options.prTitle!,
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

  // Spawn all agents in parallel with their pre-generated branch names
  const results = await Promise.all(
    agentsToSpawn.map((agent, index) =>
      spawnAgent(
        agent,
        taskId,
        {
          ...options,
          newBranch: branchNames[index],
        },
        teamSlugOrId
      )
    )
  );

  return results;
}
