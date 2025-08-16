import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import {
  AGENT_CONFIGS,
  type AgentConfig,
  type EnvironmentResult,
} from "@cmux/shared/agentConfig";
import type { WorkerCreateTerminal } from "@cmux/shared/worker-schemas";
import * as path from "node:path";
import { captureGitDiff } from "./captureGitDiff.js";
import { evaluateCrownWithClaudeCode } from "./crownEvaluator.js";
import { sanitizeTmuxSessionName } from "./sanitizeTmuxSessionName.js";
import { storeGitDiffs } from "./storeGitDiffs.js";
import {
  generateNewBranchName,
  generateUniqueBranchNames,
  generateUniqueBranchNamesFromTitle,
} from "./utils/branchNameGenerator.js";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";
import { MorphVSCodeInstance } from "./vscode/MorphVSCodeInstance.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { getWorktreePath, setupProjectWorkspace } from "./workspace.js";

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
    repoUrl: string;
    branch?: string;
    taskDescription: string;
    isCloudMode?: boolean;
    images?: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
    theme?: "dark" | "light" | "system";
    newBranch?: string; // Optional pre-generated branch name
  }
): Promise<AgentSpawnResult> {
  try {
    // Use provided branch name or generate a new one
    const newBranch =
      options.newBranch ||
      (await generateNewBranchName(options.taskDescription));
    serverLogger.info(`[AgentSpawner] Using branch name: ${newBranch}`);

    // Create a task run for this specific agent
    const taskRunId = await convex.mutation(api.taskRuns.create, {
      taskId: taskId,
      prompt: `${options.taskDescription} (${agent.name})`,
      agentName: agent.name,
      newBranch,
    });

    // Fetch the task to get image storage IDs
    const task = await convex.query(api.tasks.getById, {
      id: taskId,
    });

    // Process prompt to handle images
    let processedTaskDescription = options.taskDescription;
    const imageFiles: Array<{ path: string; base64: string }> = [];

    // Handle images from either the options (for backward compatibility) or from the task
    let imagesToProcess = options.images || [];

    // If task has images with storage IDs, download them
    if (task && task.images && task.images.length > 0) {
      const downloadedImages = await Promise.all(
        task.images.map(async (image: any) => {
          if (image.url) {
            // Download image from Convex storage
            const response = await fetch(image.url);
            const buffer = await response.arrayBuffer();
            const base64 = Buffer.from(buffer).toString("base64");
            return {
              src: `data:image/png;base64,${base64}`,
              fileName: image.fileName,
              altText: image.altText,
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
        fileName = fileName.replace(/[^\x00-\x7F]/g, "_").replace(/\s+/g, "_");
        serverLogger.info(`[AgentSpawner] Sanitized filename: ${fileName}`);

        const imagePath = `/root/prompt/${fileName}`;
        imageFiles.push({
          path: imagePath,
          base64: image.src.split(",")[1] || image.src, // Remove data URL prefix if present
        });

        // Replace image reference in prompt with file path
        // First try to replace the original filename
        if (image.fileName) {
          const beforeReplace = processedTaskDescription;
          processedTaskDescription = processedTaskDescription.replace(
            new RegExp(
              `\\b${image.fileName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`,
              "g"
            ),
            imagePath
          );
          if (beforeReplace !== processedTaskDescription) {
            serverLogger.info(
              `[AgentSpawner] Replaced "${image.fileName}" with "${imagePath}"`
            );
          }
        }

        // Also replace just the filename without extension in case it appears that way
        const nameWithoutExt = image.fileName?.replace(/\.[^/.]+$/, "");
        if (nameWithoutExt) {
          const beforeReplace = processedTaskDescription;
          processedTaskDescription = processedTaskDescription.replace(
            new RegExp(
              `\\b${nameWithoutExt.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`,
              "g"
            ),
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

    // Build environment variables (use CMUX_PROMPT to avoid huge argv)
    let envVars: Record<string, string> = {
      CMUX_PROMPT: processedTaskDescription,
      // Keep PROMPT for backward compatibility if any consumer uses it
      PROMPT: processedTaskDescription,
    };

    let authFiles: EnvironmentResult["files"] = [];
    let startupCommands: string[] = [];

    // Use environment property if available
    if (agent.environment) {
      const envResult = await agent.environment();
      envVars = {
        ...envVars,
        ...envResult.env,
      };
      authFiles = envResult.files;
      startupCommands = envResult.startupCommands || [];
    }

    // Fetch API keys from Convex
    const apiKeys = await convex.query(api.apiKeys.getAllForAgents);

    // Add required API keys from Convex
    if (agent.apiKeys) {
      for (const keyConfig of agent.apiKeys) {
        const key = apiKeys[keyConfig.envVar];
        if (key && key.trim().length > 0) {
          envVars[keyConfig.envVar] = key;
        }
      }
    }

    // If running a Gemini agent and an API key is available, ensure
    // the CLI auto-selects API key auth without prompting.
    // We do this by providing a minimal settings.json that sets
    // selectedAuthType to USE_GEMINI when one isn't already supplied
    // via environment preparation.
    if (
      agent.name.startsWith("gemini/") &&
      typeof envVars.GEMINI_API_KEY === "string" &&
      envVars.GEMINI_API_KEY.trim().length > 0
    ) {
      const hasGeminiSettings = authFiles.some(
        (f) =>
          f.destinationPath === "$HOME/.gemini/settings.json" ||
          f.destinationPath.endsWith("/.gemini/settings.json")
      );
      if (!hasGeminiSettings) {
        const settingsJson = JSON.stringify({ selectedAuthType: "USE_GEMINI" });
        authFiles.push({
          destinationPath: "$HOME/.gemini/settings.json",
          contentBase64: Buffer.from(settingsJson).toString("base64"),
          mode: "644",
        });
      }
      // Also hint the default via env for good measure
      envVars.GEMINI_DEFAULT_AUTH_TYPE = "USE_GEMINI";
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
    const tmuxSessionName = sanitizeTmuxSessionName(
      `${agent.name}-${taskRunId.slice(-8)}`
    );

    serverLogger.info(
      `[AgentSpawner] Building command for agent ${agent.name}:`
    );
    serverLogger.info(`  Raw command: ${agent.command}`);
    serverLogger.info(`  Processed args: ${processedArgs.join(" ")}`);
    serverLogger.info(`  Agent command: ${agentCommand}`);
    serverLogger.info(`  Tmux session name: ${tmuxSessionName}`);
    serverLogger.info(
      `  Environment vars to pass:`,
      Object.keys(envVars).filter(
        (k) => k.startsWith("ANTHROPIC_") || k.startsWith("GEMINI_")
      )
    );

    let vscodeInstance: VSCodeInstance;
    let worktreePath: string;

    if (options.isCloudMode) {
      // For Morph, create the instance and we'll clone the repo via socket command
      vscodeInstance = new MorphVSCodeInstance({
        agentName: agent.name,
        taskRunId,
        taskId,
        theme: options.theme,
      });

      worktreePath = "/root/workspace";
    } else {
      // For Docker, set up worktree as before
      const worktreeInfo = await getWorktreePath({
        repoUrl: options.repoUrl,
        branch: options.branch,
      });

      // Use the newBranch name for both the git branch and worktree directory
      worktreeInfo.branchName = newBranch;
      worktreeInfo.worktreePath = worktreeInfo.worktreePath.replace(
        /worktree-[^/]+$/,
        `worktree-${newBranch.replace(/[^a-zA-Z0-9-]/g, "-")}`
      );

      // Setup workspace
      const workspaceResult = await setupProjectWorkspace({
        repoUrl: options.repoUrl,
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
      });
    }

    // Update the task run with the worktree path
    await convex.mutation(api.taskRuns.updateWorktreePath, {
      id: taskRunId,
      worktreePath: worktreePath,
    });

    // Store the VSCode instance
    // VSCodeInstance.getInstances().set(vscodeInstance.getInstanceId(), vscodeInstance);

    serverLogger.info(`Starting VSCode instance for agent ${agent.name}...`);

    // Start the VSCode instance
    const vscodeInfo = await vscodeInstance.start();
    const vscodeUrl = vscodeInfo.workspaceUrl;

    serverLogger.info(
      `VSCode instance spawned for agent ${agent.name}: ${vscodeUrl}`
    );

    // Start file watching for real-time diff updates
    serverLogger.info(
      `[AgentSpawner] Starting file watch for ${agent.name} at ${worktreePath}`
    );
    vscodeInstance.startFileWatch(worktreePath);

    // Handler for completing the task
    const handleTaskCompletion = async (exitCode: number = 0) => {
      try {
        // Capture git diff before marking as complete
        serverLogger.info(
          `[AgentSpawner] ============================================`
        );
        serverLogger.info(
          `[AgentSpawner] CAPTURING GIT DIFF FOR ${agent.name}`
        );
        serverLogger.info(`[AgentSpawner] Task Run ID: ${taskRunId}`);
        serverLogger.info(`[AgentSpawner] Worktree Path: ${worktreePath}`);
        serverLogger.info(
          `[AgentSpawner] VSCode Instance Connected: ${vscodeInstance.isWorkerConnected()}`
        );
        serverLogger.info(
          `[AgentSpawner] ============================================`
        );

        // Use the original captureGitDiff function which uses worker:exec
        const gitDiff = await captureGitDiff(vscodeInstance, worktreePath);
        serverLogger.info(
          `[AgentSpawner] Captured git diff for ${agent.name}: ${gitDiff.length} chars`
        );
        serverLogger.info(
          `[AgentSpawner] First 100 chars of diff: ${gitDiff.substring(0, 100)}`
        );

        // Append git diff to the log AND store in gitDiffs table
        if (gitDiff && gitDiff.length > 0) {
          await convex.mutation(api.taskRuns.appendLogPublic, {
            id: taskRunId as Id<"taskRuns">,
            content: `\n\n=== GIT DIFF ===\n${gitDiff}\n=== END GIT DIFF ===\n`,
          });
          serverLogger.info(
            `[AgentSpawner] Successfully appended ${gitDiff.length} chars of git diff to log for ${taskRunId}`
          );

          // Parse and store the diff in the gitDiffs table
          await storeGitDiffs(
            taskRunId as Id<"taskRuns">,
            gitDiff,
            vscodeInstance,
            worktreePath
          );
        } else {
          serverLogger.error(
            `[AgentSpawner] NO GIT DIFF TO APPEND for ${agent.name} (${taskRunId})`
          );
          serverLogger.error(
            `[AgentSpawner] This will cause crown evaluation to fail!`
          );
        }

        await convex.mutation(api.taskRuns.complete, {
          id: taskRunId as Id<"taskRuns">,
          exitCode,
        });

        serverLogger.info(
          `[AgentSpawner] Updated taskRun ${taskRunId} as completed with exit code ${exitCode}`
        );

        // Check if all runs are complete and evaluate crown
        const taskRunData = await convex.query(api.taskRuns.get, {
          id: taskRunId as Id<"taskRuns">,
        });

        serverLogger.info(
          `[AgentSpawner] Task run data retrieved: ${taskRunData ? "found" : "not found"}`
        );

        if (taskRunData) {
          serverLogger.info(
            `[AgentSpawner] Calling checkAndEvaluateCrown for task ${taskRunData.taskId}`
          );

          const winnerId = await convex.mutation(
            api.tasks.checkAndEvaluateCrown,
            {
              taskId: taskRunData.taskId,
            }
          );

          serverLogger.info(
            `[AgentSpawner] checkAndEvaluateCrown returned: ${winnerId}`
          );

          // If winnerId is "pending", trigger Claude Code evaluation
          if (winnerId === "pending") {
            serverLogger.info(
              `[AgentSpawner] ==========================================`
            );
            serverLogger.info(
              `[AgentSpawner] CROWN EVALUATION NEEDED - TRIGGERING NOW`
            );
            serverLogger.info(`[AgentSpawner] Task ID: ${taskRunData.taskId}`);
            serverLogger.info(
              `[AgentSpawner] ==========================================`
            );

            // Trigger crown evaluation immediately for faster response
            // The periodic checker will also handle retries if this fails
            serverLogger.info(
              `[AgentSpawner] Triggering immediate crown evaluation`
            );

            // Small delay to ensure git diff is fully persisted in Convex
            setTimeout(async () => {
              try {
                // Check if evaluation is already in progress
                const task = await convex.query(api.tasks.getById, {
                  id: taskRunData.taskId,
                });
                if (task?.crownEvaluationError === "in_progress") {
                  serverLogger.info(
                    `[AgentSpawner] Crown evaluation already in progress for task ${taskRunData.taskId}`
                  );
                  return;
                }

                await evaluateCrownWithClaudeCode(convex, taskRunData.taskId);
                serverLogger.info(
                  `[AgentSpawner] Crown evaluation completed successfully`
                );

                // Check if this task run won
                const updatedTaskRun = await convex.query(api.taskRuns.get, {
                  id: taskRunId as Id<"taskRuns">,
                });

                if (updatedTaskRun?.isCrowned) {
                  serverLogger.info(
                    `[AgentSpawner] 🏆 This task run won the crown! ${agent.name} is the winner!`
                  );
                }
              } catch (error) {
                serverLogger.error(
                  `[AgentSpawner] Crown evaluation failed:`,
                  error
                );
                // The periodic checker will retry
              }
            }, 3000); // 3 second delay to ensure data persistence
          } else if (winnerId) {
            serverLogger.info(
              `[AgentSpawner] Task completed with winner: ${winnerId}`
            );

            // For single agent scenario, trigger auto-PR if enabled
            const taskRuns = await convex.query(api.taskRuns.getByTask, {
              taskId: taskRunData.taskId,
            });

            if (taskRuns.length === 1) {
              serverLogger.info(
                `[AgentSpawner] Single agent scenario - checking auto-PR settings`
              );

              // Check if auto-PR is enabled
              const ws = await convex.query(api.workspaceSettings.get);
              const autoPrEnabled =
                (ws as unknown as { autoPrEnabled?: boolean })?.autoPrEnabled ??
                false;

              if (autoPrEnabled && winnerId) {
                serverLogger.info(
                  `[AgentSpawner] Triggering auto-PR for single agent completion`
                );

                // Import and call the createPullRequestForWinner function
                const { createPullRequestForWinner } = await import(
                  "./crownEvaluator.js"
                );
                const { getGitHubTokenFromKeychain } = await import(
                  "./utils/getGitHubToken.js"
                );
                const githubToken = await getGitHubTokenFromKeychain(convex);

                // Small delay to ensure git diff is persisted
                setTimeout(async () => {
                  try {
                    await createPullRequestForWinner(
                      convex,
                      winnerId,
                      taskRunData.taskId,
                      githubToken || undefined
                    );
                    serverLogger.info(
                      `[AgentSpawner] Auto-PR completed for single agent`
                    );
                  } catch (error) {
                    serverLogger.error(
                      `[AgentSpawner] Auto-PR failed for single agent:`,
                      error
                    );
                  }
                }, 3000);
              } else {
                serverLogger.info(
                  `[AgentSpawner] Auto-PR disabled or not applicable for single agent`
                );
              }
            }
          } else {
            serverLogger.info(
              `[AgentSpawner] No crown evaluation needed (winnerId: ${winnerId})`
            );
          }
        }

        const ENABLE_AUTO_COMMIT = false; // Disabled to ensure git diff capture works

        // Skip auto-commit - we'll let the user commit manually after crown evaluation
        if (ENABLE_AUTO_COMMIT && taskRunData) {
          serverLogger.info(
            `[AgentSpawner] Auto-commit is disabled to ensure proper crown evaluation`
          );
        }

        // Schedule container stop based on settings
        const containerSettings = await convex.query(
          api.containerSettings.getEffective
        );

        if (containerSettings.autoCleanupEnabled) {
          if (containerSettings.stopImmediatelyOnCompletion) {
            // Stop container immediately
            serverLogger.info(
              `[AgentSpawner] Stopping container immediately as per settings`
            );

            // Stop the VSCode instance
            await vscodeInstance.stop();
          } else {
            // Schedule stop after review period
            const reviewPeriodMs =
              containerSettings.reviewPeriodMinutes * 60 * 1000;
            const scheduledStopAt = Date.now() + reviewPeriodMs;

            await convex.mutation(api.taskRuns.updateScheduledStop, {
              id: taskRunId as Id<"taskRuns">,
              scheduledStopAt,
            });

            serverLogger.info(
              `[AgentSpawner] Scheduled container stop for ${new Date(scheduledStopAt).toISOString()}`
            );
          }
        }
      } catch (error) {
        serverLogger.error(
          `[AgentSpawner] Error handling task completion:`,
          error
        );
      }
    };

    // Track if this terminal already failed (to avoid completing later)
    let hasFailed = false;

    // Set up terminal-exit event handler
    vscodeInstance.on("terminal-exit", async (data) => {
      serverLogger.info(
        `[AgentSpawner] Terminal exited for ${agent.name}:`,
        data
      );

      if (data.terminalId === terminalId) {
        if (hasFailed) {
          serverLogger.warn(
            `[AgentSpawner] Not completing ${agent.name} (already marked failed)`
          );
          return;
        }
        // CRITICAL: Add a delay to ensure changes are written to disk
        serverLogger.info(
          `[AgentSpawner] Waiting 3 seconds for file system to settle before capturing git diff...`
        );
        await new Promise((resolve) => setTimeout(resolve, 3000));

        await handleTaskCompletion(data.exitCode || 0);
      }
    });

    // Set up file change event handler for real-time diff updates
    vscodeInstance.on("file-changes", async (data) => {
      serverLogger.info(
        `[AgentSpawner] File changes detected for ${agent.name}:`,
        { changeCount: data.changes.length, taskId: data.taskId }
      );

      // Store the incremental diffs in Convex
      if (data.taskId === taskRunId && data.fileDiffs.length > 0) {
        for (const fileDiff of data.fileDiffs) {
          const relativePath = path.relative(worktreePath, fileDiff.path);

          await convex.mutation(api.gitDiffs.upsertDiff, {
            taskRunId,
            filePath: relativePath,
            status: fileDiff.type as "added" | "modified" | "deleted",
            additions: (fileDiff.patch.match(/^\+[^+]/gm) || []).length,
            deletions: (fileDiff.patch.match(/^-[^-]/gm) || []).length,
            patch: fileDiff.patch,
            oldContent: fileDiff.oldContent,
            newContent: fileDiff.newContent,
            isBinary: false,
          });
        }

        // Update the timestamp
        await convex.mutation(api.gitDiffs.updateDiffsTimestamp, {
          taskRunId,
        });

        serverLogger.info(
          `[AgentSpawner] Stored ${data.fileDiffs.length} incremental diffs for ${agent.name}`
        );
      }
    });

    // Set up terminal-idle event handler
    vscodeInstance.on("terminal-idle", async (data) => {
      serverLogger.info(
        `[AgentSpawner] Terminal idle detected for ${agent.name}:`,
        data
      );
      if (hasFailed) {
        serverLogger.warn(
          `[AgentSpawner] Ignoring idle for ${agent.name} (already marked failed)`
        );
        return;
      }

      // Debug logging to understand what's being compared
      serverLogger.info(`[AgentSpawner] Terminal idle comparison:`);
      serverLogger.info(`[AgentSpawner]   data.taskId: "${data.taskId}"`);
      serverLogger.info(`[AgentSpawner]   taskRunId: "${taskRunId}"`);
      serverLogger.info(`[AgentSpawner]   Match: ${data.taskId === taskRunId}`);

      // Update the task run as completed
      if (data.taskId === taskRunId) {
        serverLogger.info(
          `[AgentSpawner] Task ID matched! Marking task as complete for ${agent.name}`
        );
        // CRITICAL: Add a delay to ensure changes are written to disk
        serverLogger.info(
          `[AgentSpawner] Waiting 3 seconds for file system to settle before capturing git diff...`
        );
        await new Promise((resolve) => setTimeout(resolve, 3000));

        // Stop file watching before completing
        vscodeInstance.stopFileWatch();
        await handleTaskCompletion(0);
      } else {
        serverLogger.warn(
          `[AgentSpawner] Task ID did not match, ignoring idle event`
        );
      }
    });

    // Set up terminal-failed event handler
    vscodeInstance.on("terminal-failed", async (data: any) => {
      try {
        serverLogger.error(
          `[AgentSpawner] Terminal failed for ${agent.name}:`,
          data
        );
        if (data.taskId !== taskRunId) {
          serverLogger.warn(
            `[AgentSpawner] Failure event taskId mismatch; ignoring`
          );
          return;
        }
        hasFailed = true;

        // Append error to log for context
        if (data.errorMessage) {
          await convex.mutation(api.taskRuns.appendLogPublic, {
            id: taskRunId as Id<"taskRuns">,
            content: `\n\n=== ERROR ===\n${data.errorMessage}\n=== END ERROR ===\n`,
          });
        }

        // Mark the run as failed with error message
        await convex.mutation(api.taskRuns.fail as any, {
          id: taskRunId as Id<"taskRuns">,
          errorMessage: data.errorMessage || "Terminal failed",
          exitCode: typeof data.exitCode === "number" ? data.exitCode : 1,
        });

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
      | { vscode: string; worker: string; extension?: string }
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
        };
      }
    }

    // Update VSCode instance information in Convex
    await convex.mutation(api.taskRuns.updateVSCodeInstance, {
      id: taskRunId,
      vscode: {
        provider: vscodeInfo.provider,
        containerName:
          vscodeInstance instanceof DockerVSCodeInstance
            ? (vscodeInstance as DockerVSCodeInstance).getContainerName()
            : undefined,
        status: "running",
        url: vscodeInfo.url,
        workspaceUrl: vscodeInfo.workspaceUrl,
        startedAt: Date.now(),
        ...(ports ? { ports } : {}),
      },
    });

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

    // Prepare the terminal creation command with auth files
    // Use the original command and args directly instead of parsing agentCommand
    // This avoids issues with quoted arguments being split incorrectly
    const actualCommand = agent.command;
    const actualArgs = processedArgs;

    // Build a shell command string so $CMUX_PROMPT expands inside tmux session
    const shellEscaped = (s: string) => {
      // If this arg references $CMUX_PROMPT, wrap in double quotes to allow expansion
      if (s.includes("$CMUX_PROMPT")) {
        return `"${s.replace(/"/g, '\\"')}"`;
      }
      // Otherwise single-quote and escape any existing single quotes
      return `'${s.replace(/'/g, "'\\''")}'`;
    };
    const commandString = [actualCommand, ...actualArgs]
      .map(shellEscaped)
      .join(" ");

    const terminalCreationCommand: WorkerCreateTerminal = {
      terminalId: tmuxSessionName,
      command: "tmux",
      args: [
        "new-session",
        "-d",
        "-s",
        tmuxSessionName,
        "bash",
        "-lc",
        `exec ${commandString}`,
      ],
      cols: 80,
      rows: 74,
      env: envVars,
      taskId: taskId,
      taskRunId,
      authFiles,
      startupCommands,
      cwd: "/root/workspace",
    };

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
    serverLogger.info(`  isCloudMode:`, options.isCloudMode);

    // For Morph instances, we need to clone the repository first
    if (options.isCloudMode) {
      serverLogger.info(
        `[AgentSpawner] Cloning repository for Morph instance...`
      );

      // Use worker:exec to clone the repository
      const cloneCommand = `git clone ${options.repoUrl} /root/workspace${
        options.branch && options.branch !== "main"
          ? ` && cd /root/workspace && git checkout ${options.branch}`
          : ""
      }`;

      const cloneResult = await new Promise<{
        success: boolean;
        error?: string;
      }>((resolve) => {
        workerSocket
          .timeout(60000) // 60 second timeout for cloning
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", cloneCommand],
              cwd: "/root",
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError) {
                serverLogger.error(
                  "Timeout waiting for git clone",
                  timeoutError
                );
                resolve({
                  success: false,
                  error: "Timeout waiting for git clone",
                });
                return;
              }
              if (result.error) {
                resolve({ success: false, error: result.error.message });
                return;
              }

              const { stdout, stderr, exitCode } = result.data!;
              serverLogger.info(`[AgentSpawner] Git clone stdout:`, stdout);
              if (stderr) {
                serverLogger.info(`[AgentSpawner] Git clone stderr:`, stderr);
              }

              if (exitCode === 0) {
                serverLogger.info(
                  `[AgentSpawner] Repository cloned successfully`
                );
                resolve({ success: true });
              } else {
                serverLogger.error(
                  `[AgentSpawner] Git clone failed with exit code ${exitCode}`
                );
                resolve({
                  success: false,
                  error: `Git clone failed with exit code ${exitCode}`,
                });
              }
            }
          );
      });

      if (!cloneResult.success) {
        return {
          agentName: agent.name,
          terminalId,
          taskRunId,
          worktreePath,
          vscodeUrl,
          success: false,
          error: cloneResult.error || "Failed to clone repository",
        };
      }
    }

    // Create image files if any
    if (imageFiles.length > 0) {
      serverLogger.info(
        `[AgentSpawner] Creating ${imageFiles.length} image files...`
      );

      // First create the prompt directory
      await new Promise<void>((resolve) => {
        workerSocket.timeout(10000).emit(
          "worker:exec",
          {
            command: "mkdir",
            args: ["-p", "/root/prompt"],
            cwd: "/root",
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              serverLogger.error(
                "Failed to create prompt directory",
                timeoutError || result.error
              );
            }
            resolve();
          }
        );
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
          } else {
            serverLogger.info("Terminal created successfully", result);
            resolve(result.data);
          }
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
    repoUrl: string;
    branch?: string;
    taskDescription: string;
    prTitle?: string;
    selectedAgents?: string[];
    isCloudMode?: boolean;
    images?: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
    theme?: "dark" | "light" | "system";
  }
): Promise<AgentSpawnResult[]> {
  // If selectedAgents is provided, filter AGENT_CONFIGS to only include selected agents
  const agentsToSpawn = options.selectedAgents
    ? AGENT_CONFIGS.filter((agent) =>
        options.selectedAgents!.includes(agent.name)
      )
    : AGENT_CONFIGS;

  // Generate unique branch names for all agents at once to ensure no collisions
  const branchNames = options.prTitle
    ? generateUniqueBranchNamesFromTitle(options.prTitle!, agentsToSpawn.length)
    : await generateUniqueBranchNames(
        options.taskDescription,
        agentsToSpawn.length
      );

  serverLogger.info(
    `[AgentSpawner] Generated ${branchNames.length} unique branch names for agents`
  );

  // Spawn all agents in parallel with their pre-generated branch names
  const results = await Promise.all(
    agentsToSpawn.map((agent, index) =>
      spawnAgent(agent, taskId, {
        ...options,
        newBranch: branchNames[index],
      })
    )
  );

  return results;
}
