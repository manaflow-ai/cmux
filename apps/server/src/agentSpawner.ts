import { api } from "@cmux/convex/api";

import type { Id } from "@cmux/convex/dataModel";
import {
  AGENT_CONFIGS,
  type AgentConfig,
  type EnvironmentResult,
} from "@cmux/shared/agentConfig";
import type { WorkerCreateTerminal } from "@cmux/shared/worker-schemas";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";
import { MorphVSCodeInstance } from "./vscode/MorphVSCodeInstance.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { getWorktreePath, setupProjectWorkspace } from "./workspace.js";
import { evaluateCrownWithClaudeCode } from "./crownEvaluator.js";
import { captureGitDiffViaTerminal } from "./gitDiffCapture.js";
import { suggestBranchAndWorktree } from "./utils/llmNamer.js";

/**
 * Sanitize a string to be used as a tmux session name.
 * Tmux session names cannot contain: periods (.), colons (:), spaces, or other special characters.
 * We'll replace them with underscores to ensure compatibility.
 */
function sanitizeTmuxSessionName(name: string): string {
  // Replace all invalid characters with underscores
  // Allow only alphanumeric characters, hyphens, and underscores
  return name.replace(/[^a-zA-Z0-9_-]/g, "_");
}

/**
 * Automatically commit and push changes when a task completes
 */
async function performAutoCommitAndPush(
  vscodeInstance: VSCodeInstance,
  agent: AgentConfig,
  taskRunId: string | Id<"taskRuns">,
  taskDescription: string,
  worktreePath: string
): Promise<void> {
  try {
    serverLogger.info(
      `[AgentSpawner] Starting auto-commit for ${agent.name}`
    );

    // Check if this run is crowned
    const taskRun = await convex.query(api.taskRuns.get, {
      id: taskRunId as Id<"taskRuns">,
    });
    const isCrowned = taskRun?.isCrowned || false;
    
    serverLogger.info(
      `[AgentSpawner] Task run ${taskRunId} crowned status: ${isCrowned}`
    );

    // Create a unique branch name for this task run
    // Include a sanitized version of the task description for better clarity
    const sanitizedTaskDesc = taskDescription
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, "") // Remove special chars except spaces and hyphens
      .trim()
      .split(/\s+/) // Split by whitespace
      .slice(0, 5) // Take first 5 words max
      .join("-")
      .substring(0, 30); // Limit length

    const branchName = `cmux-${agent.name}-${sanitizedTaskDesc}-${taskRunId}`
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/--+/g, "-");

    // Use task description as the main commit message
    // Truncate if too long (git has limits on commit message length)
    const truncatedDescription =
      taskDescription.length > 72
        ? taskDescription.substring(0, 69) + "..."
        : taskDescription;

    const commitMessage = `${truncatedDescription}

Task completed by ${agent.name} agent${isCrowned ? " 🏆" : ""}

🤖 Generated with cmux
Agent: ${agent.name}
Task Run ID: ${taskRunId}
Branch: ${branchName}
Completed: ${new Date().toISOString()}`;

    // Try to use VSCode extension API first (more reliable)
    const extensionResult = await tryVSCodeExtensionCommit(
      vscodeInstance,
      branchName,
      commitMessage,
      agent.name
    );

    if (extensionResult.success) {
      serverLogger.info(
        `[AgentSpawner] Successfully committed via VSCode extension`
      );
      serverLogger.info(`[AgentSpawner] Branch: ${branchName}`);
      serverLogger.info(
        `[AgentSpawner] Commit message: ${commitMessage.split("\n")[0]}`
      );
      return;
    }

    serverLogger.info(
      `[AgentSpawner] VSCode extension method failed, falling back to git commands:`,
      extensionResult.error
    );

    // Fallback to direct git commands
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.info(
        `[AgentSpawner] No worker connection for auto-commit fallback`
      );
      return;
    }

    // Execute git commands in sequence
    const gitCommands = [
      // Add all changes
      `git add .`,
      // Create and switch to new branch
      `git checkout -b ${branchName}`,
      // Commit with a descriptive message (escape properly for shell)
      `git commit -m "${commitMessage
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\$/g, "\\$")
        .replace(/`/g, "\\`")}"`,
    ];

    // Only push if this is a crowned run
    if (isCrowned) {
      gitCommands.push(`git push -u origin ${branchName}`);
    }

    for (const command of gitCommands) {
      serverLogger.info(`[AgentSpawner] Executing: ${command}`);

      const result = await new Promise<{
        success: boolean;
        stdout?: string;
        stderr?: string;
        exitCode?: number;
        error?: string;
      }>((resolve) => {
        workerSocket
          .timeout(30000) // 30 second timeout
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", command],
              cwd: "/root/workspace",
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError) {
                serverLogger.error(
                  `[AgentSpawner] Timeout executing: ${command}`,
                  timeoutError
                );
                resolve({
                  success: false,
                  error: "Timeout waiting for git command",
                });
                return;
              }
              if (result.error) {
                resolve({ success: false, error: result.error.message });
                return;
              }

              const { stdout, stderr, exitCode } = result.data!;
              serverLogger.info(`[AgentSpawner] Command output:`, {
                stdout,
                stderr,
                exitCode,
              });

              if (exitCode === 0) {
                resolve({ success: true, stdout, stderr, exitCode });
              } else {
                resolve({
                  success: false,
                  stdout,
                  stderr,
                  exitCode,
                  error: `Command failed with exit code ${exitCode}`,
                });
              }
            }
          );
      });

      if (!result.success) {
        serverLogger.error(
          `[AgentSpawner] Git command failed: ${command}`,
          result.error
        );
        // Don't stop on individual command failures - some might be expected (e.g., no changes to commit)
        continue;
      }
    }

    if (isCrowned) {
      serverLogger.info(
        `[AgentSpawner] 🏆 Crown winner! Auto-commit and push completed for ${agent.name} on branch ${branchName}`
      );
      
      // Create PR for crowned run
      try {
        if (!taskRun) {
          serverLogger.error(`[AgentSpawner] Task run not found for PR creation`);
          return;
        }
        const task = await convex.query(api.tasks.getById, { id: taskRun.taskId });
        if (task) {
          const prTitle = `[Crown] ${task.text}`;
          const prBody = `## 🏆 Crown Winner: ${agent.name}

### Task Description
${task.text}
${task.description ? `\n${task.description}` : ""}

### Crown Evaluation
${taskRun.crownReason || "This implementation was selected as the best solution."}

### Implementation Details
- **Agent**: ${agent.name}
- **Task ID**: ${task._id}
- **Run ID**: ${taskRun._id}
- **Branch**: ${branchName}
- **Completed**: ${new Date(taskRun.completedAt || Date.now()).toISOString()}

---
*This PR was automatically created by cmux crown feature after evaluating implementations from multiple AI coding assistants.*`;

          const prCommand = `gh pr create --title "${prTitle.replace(/"/g, '\\"')}" --body "${prBody.replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
          
          const prResult = await new Promise<{
            success: boolean;
            output?: string;
            error?: string;
          }>((resolve) => {
            workerSocket
              .timeout(30000)
              .emit(
                "worker:exec",
                {
                  command: prCommand,
                  cwd: "/root/workspace",
                },
                (response: any) => {
                  if (response.error) {
                    resolve({ success: false, error: response.error });
                  } else {
                    // Extract PR URL from output
                    const output = response.stdout || "";
                    const prUrlMatch = output.match(/https:\/\/github\.com\/[\w-]+\/[\w-]+\/pull\/\d+/);
                    resolve({
                      success: true,
                      output: prUrlMatch ? prUrlMatch[0] : output,
                    });
                  }
                }
              );
          });

          if (prResult.success && prResult.output) {
            serverLogger.info(`[AgentSpawner] Pull request created: ${prResult.output}`);
            await convex.mutation(api.taskRuns.updatePullRequestUrl, {
              id: taskRunId as Id<"taskRuns">,
              pullRequestUrl: prResult.output,
            });
          } else {
            serverLogger.error(`[AgentSpawner] Failed to create PR: ${prResult.error}`);
          }
        }
      } catch (error) {
        serverLogger.error(`[AgentSpawner] Error creating PR:`, error);
      }
    } else {
      serverLogger.info(
        `[AgentSpawner] Auto-commit completed for ${agent.name} on branch ${branchName} (not crowned - branch not pushed)`
      );
    }
  } catch (error) {
    serverLogger.error(`[AgentSpawner] Error in auto-commit and push:`, error);
  }
}

/**
 * Capture the full git diff including untracked files
 */
async function captureGitDiff(
  vscodeInstance: VSCodeInstance,
  worktreePath: string
): Promise<string> {
  try {
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.error(`[AgentSpawner] No worker connection for git diff capture`);
      return "";
    }

    serverLogger.info(`[AgentSpawner] ========================================`);
    serverLogger.info(`[AgentSpawner] STARTING GIT DIFF CAPTURE`);
    serverLogger.info(`[AgentSpawner] Local worktree path: ${worktreePath}`);
    serverLogger.info(`[AgentSpawner] Container workspace: /root/workspace`);
    serverLogger.info(`[AgentSpawner] ========================================`);
    
    // IMPORTANT: Use /root/workspace as the working directory, not the local filesystem path
    const containerWorkspace = "/root/workspace";
    
    // First check if we're in the right directory and git repo
    const pwdResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      workerSocket
        .timeout(5000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "pwd && git rev-parse --show-toplevel"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({ 
              success: true, 
              stdout: result.data?.stdout || ""
            });
          }
        );
    });
    
    serverLogger.info(`[AgentSpawner] Working directory check: ${pwdResult.stdout}`);
    
    // First check git status to understand the repo state
    const gitStatusVerbose = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      workerSocket
        .timeout(5000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "git status --verbose"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false, stderr: String(result?.error || "timeout") });
              return;
            }
            resolve({ 
              success: true, 
              stdout: result.data?.stdout || "",
              stderr: result.data?.stderr || ""
            });
          }
        );
    });
    
    serverLogger.info(`[AgentSpawner] Git status verbose: ${gitStatusVerbose.stdout?.substring(0, 500) || gitStatusVerbose.stderr}`);

    // First, let's see what files exist
    const lsResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      workerSocket
        .timeout(5000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "ls -la"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({ 
              success: true, 
              stdout: result.data?.stdout || ""
            });
          }
        );
    });

    serverLogger.info(`[AgentSpawner] Directory listing: ${lsResult.stdout?.split('\n').length || 0} files`);

    // Run git status to see all changes including untracked files
    const statusResult = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      workerSocket
        .timeout(10000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "git status --porcelain"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({ 
              success: true, 
              stdout: result.data?.stdout || "",
              stderr: result.data?.stderr || ""
            });
          }
        );
    });

    let fullDiff = "";
    
    if (statusResult.success && statusResult.stdout) {
      fullDiff += `=== Git Status (porcelain) ===\n${statusResult.stdout}\n\n`;
      serverLogger.info(`[AgentSpawner] Git status shows ${statusResult.stdout.split('\n').filter(l => l.trim()).length} changed files`);
    } else {
      serverLogger.warn(`[AgentSpawner] Git status failed or empty`);
    }

    // First get regular diff of tracked files
    const diffResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      workerSocket
        .timeout(10000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "git diff"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({ 
              success: true, 
              stdout: result.data?.stdout || ""
            });
          }
        );
    });

    if (diffResult.success && diffResult.stdout) {
      fullDiff += `=== Tracked file changes (git diff) ===\n${diffResult.stdout}\n\n`;
      serverLogger.info(`[AgentSpawner] Git diff length: ${diffResult.stdout.length} chars`);
    }

    // CRITICAL: Add ALL files including untracked ones
    serverLogger.info(`[AgentSpawner] Running git add -A to stage ALL files (including deletions)`);
    const addResult = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      workerSocket
        .timeout(10000)
        .emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "cd /root/workspace && git add -A && git status --short"],  // Use -A to add everything including deletions
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false, stderr: String(result?.error || "timeout") });
              return;
            }
            resolve({ 
              success: true,
              stdout: result.data?.stdout || "",
              stderr: result.data?.stderr || ""
            });
          }
        );
    });

    if (addResult.success) {
      serverLogger.info(`[AgentSpawner] Git add completed. Output: ${addResult.stdout || "no output"}, Stderr: ${addResult.stderr || "no stderr"}`);
      
      // Now get diff against HEAD - this MUST show all changes
      serverLogger.info(`[AgentSpawner] Running git diff HEAD to get ALL changes`);
      const stagedDiffResult = await new Promise<{
        success: boolean;
        stdout?: string;
        stderr?: string;
      }>((resolve) => {
        workerSocket
          .timeout(20000)  // Increase timeout for large diffs
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", "cd /root/workspace && git diff --cached 2>&1"],  // Use --cached to show staged changes
              cwd: containerWorkspace,
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError || result.error) {
                resolve({ success: false, stderr: String(result?.error || "timeout") });
                return;
              }
              resolve({ 
                success: true, 
                stdout: result.data?.stdout || "",
                stderr: result.data?.stderr || ""
              });
            }
          );
      });

      if (stagedDiffResult.success) {
        serverLogger.info(`[AgentSpawner] Git diff HEAD completed. Length: ${stagedDiffResult.stdout?.length || 0}, Stderr: ${stagedDiffResult.stderr || "no stderr"}`);
        
        if (stagedDiffResult.stdout && stagedDiffResult.stdout.length > 0) {
          fullDiff = `=== ALL CHANGES (git diff HEAD) ===\n${stagedDiffResult.stdout}\n=== END ALL CHANGES ===`;
          serverLogger.info(`[AgentSpawner] Successfully captured diff against HEAD: ${stagedDiffResult.stdout.length} chars`);
        } else {
          serverLogger.error(`[AgentSpawner] git diff HEAD returned empty! This should not happen after git add .`);
          
          // Debug: Check what git thinks is staged
          const debugStatusResult = await new Promise<{
            success: boolean;
            stdout?: string;
          }>((resolve) => {
            workerSocket
              .timeout(5000)
              .emit(
                "worker:exec",
                {
                  command: "bash",
                  args: ["-c", "git status --short"],
                  cwd: containerWorkspace,
                  env: {},
                },
                (timeoutError, result) => {
                  if (timeoutError || result.error) {
                    resolve({ success: false });
                    return;
                  }
                  resolve({ 
                    success: true, 
                    stdout: result.data?.stdout || ""
                  });
                }
              );
          });
          
          serverLogger.error(`[AgentSpawner] Git status after add: ${debugStatusResult.stdout}`);
          fullDiff = `ERROR: git diff --cached was empty. Git status:\n${debugStatusResult.stdout}`;
        }
      } else {
        serverLogger.error(`[AgentSpawner] Git diff --cached failed: ${stagedDiffResult.stderr}`);
      }

      // IMPORTANT: Keep files staged so crown evaluation can see them
      serverLogger.info(`[AgentSpawner] Keeping files staged for crown evaluation`);
    } else {
      serverLogger.error(`[AgentSpawner] Git add . failed: ${addResult.stderr}`);
    }

    // If still no diff, try to show what files are in the directory
    if (!fullDiff || fullDiff === "No changes detected") {
      const findResult = await new Promise<{
        success: boolean;
        stdout?: string;
      }>((resolve) => {
        workerSocket
          .timeout(5000)
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", "find . -type f -name '*.md' -o -name '*.txt' -o -name '*.js' -o -name '*.ts' -o -name '*.json' | head -20"],
              cwd: containerWorkspace,
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError || result.error) {
                resolve({ success: false });
                return;
              }
              resolve({ 
                success: true, 
                stdout: result.data?.stdout || ""
              });
            }
          );
      });

      if (findResult.success && findResult.stdout) {
        fullDiff = `No git changes detected. Files in directory:\n${findResult.stdout}`;
      }
    }

    // AGGRESSIVE FINAL CHECK - Get ALL changes by any means necessary
    if (!fullDiff || fullDiff.length < 50 || !fullDiff.includes("diff --git")) {
      serverLogger.warn(`[AgentSpawner] No meaningful diff found, using AGGRESSIVE capture`);
      
      // Method 1: Get list of all changed files from git status
      const changedFilesResult = await new Promise<{
        success: boolean;
        stdout?: string;
      }>((resolve) => {
        workerSocket
          .timeout(10000)
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", "git status --porcelain | awk '{print $2}'"],
              cwd: containerWorkspace,
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError || result.error) {
                resolve({ success: false });
                return;
              }
              resolve({ 
                success: true, 
                stdout: result.data?.stdout || ""
              });
            }
          );
      });
      
      if (changedFilesResult.success && changedFilesResult.stdout) {
        const files = changedFilesResult.stdout.split('\n').filter(f => f.trim());
        serverLogger.info(`[AgentSpawner] Found ${files.length} changed files to capture`);
        
        fullDiff = "=== AGGRESSIVE DIFF CAPTURE ===\n";
        
        // For each file, get its content
        for (const file of files) {
          if (!file) continue;
          
          // Check if file exists
          const fileExistsResult = await new Promise<{
            success: boolean;
            stdout?: string;
          }>((resolve) => {
            workerSocket
              .timeout(5000)
              .emit(
                "worker:exec",
                {
                  command: "bash",
                  args: ["-c", `test -f "${file}" && echo "exists" || echo "not found"`],
                  cwd: containerWorkspace,
                  env: {},
                },
                (timeoutError, result) => {
                  if (timeoutError || result.error) {
                    resolve({ success: false });
                    return;
                  }
                  resolve({ 
                    success: true, 
                    stdout: result.data?.stdout || ""
                  });
                }
              );
          });
          
          if (fileExistsResult.success && fileExistsResult.stdout?.includes("exists")) {
            // Get file content
            const fileContentResult = await new Promise<{
              success: boolean;
              stdout?: string;
            }>((resolve) => {
              workerSocket
                .timeout(5000)
                .emit(
                  "worker:exec",
                  {
                    command: "bash",
                    args: ["-c", `cat "${file}" 2>/dev/null | head -1000`],
                    cwd: containerWorkspace,
                    env: {},
                  },
                  (timeoutError, result) => {
                    if (timeoutError || result.error) {
                      resolve({ success: false });
                      return;
                    }
                    resolve({ 
                      success: true, 
                      stdout: result.data?.stdout || ""
                    });
                  }
                );
            });
            
            if (fileContentResult.success && fileContentResult.stdout) {
              fullDiff += `\n=== NEW FILE: ${file} ===\n${fileContentResult.stdout}\n=== END FILE ===\n`;
            }
          }
        }
      }
      
      // Method 2: If still nothing, just list all files
      if (!fullDiff || fullDiff.length < 100) {
        const allFilesResult = await new Promise<{
          success: boolean;
          stdout?: string;
        }>((resolve) => {
          workerSocket
            .timeout(5000)
            .emit(
              "worker:exec",
              {
                command: "bash",
                args: ["-c", "find . -type f -name '*.txt' -o -name '*.md' -o -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.py' -o -name '*.java' -o -name '*.c' -o -name '*.cpp' -o -name '*.go' -o -name '*.rs' | grep -v node_modules | grep -v .git | head -50"],
                cwd: containerWorkspace,
                env: {},
              },
              (timeoutError, result) => {
                if (timeoutError || result.error) {
                  resolve({ success: false });
                  return;
                }
                resolve({ 
                  success: true, 
                  stdout: result.data?.stdout || ""
                });
              }
            );
        });
        
        if (allFilesResult.success && allFilesResult.stdout) {
          fullDiff = `=== NO GIT DIFF FOUND - SHOWING ALL FILES ===\n${allFilesResult.stdout}\n`;
        }
      }
    }
    
    serverLogger.info(`[AgentSpawner] Total diff captured: ${fullDiff.length} chars`);
    serverLogger.info(`[AgentSpawner] First 200 chars: ${fullDiff.substring(0, 200)}`);
    return fullDiff || "No changes detected";
  } catch (error) {
    serverLogger.error(`[AgentSpawner] Error capturing git diff:`, error);
    return "";
  }
}

/**
 * Try to use VSCode extension API for git operations
 */
async function tryVSCodeExtensionCommit(
  vscodeInstance: VSCodeInstance,
  branchName: string,
  commitMessage: string,
  agentName: string
): Promise<{ success: boolean; error?: string; message?: string }> {
  try {
    // For Docker instances, get the extension port
    let extensionPort: string | undefined;
    if (vscodeInstance instanceof DockerVSCodeInstance) {
      const ports = (vscodeInstance as DockerVSCodeInstance).getPorts();
      extensionPort = ports?.extension;
    }

    if (!extensionPort) {
      return { success: false, error: "Extension port not available" };
    }

    // Connect to VSCode extension socket
    const { io } = await import("socket.io-client");
    const extensionSocket = io(`http://localhost:${extensionPort}`, {
      timeout: 10000,
    });

    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        extensionSocket.disconnect();
        resolve({
          success: false,
          error: "Timeout connecting to VSCode extension",
        });
      }, 15000);

      extensionSocket.on("connect", () => {
        serverLogger.info(
          `[AgentSpawner] Connected to VSCode extension on port ${extensionPort}`
        );

        extensionSocket.emit(
          "vscode:auto-commit-push",
          {
            branchName,
            commitMessage,
            agentName,
          },
          (response: any) => {
            clearTimeout(timeout);
            extensionSocket.disconnect();

            if (response.success) {
              resolve({ success: true, message: response.message });
            } else {
              resolve({ success: false, error: response.error });
            }
          }
        );
      });

      extensionSocket.on("connect_error", (error) => {
        clearTimeout(timeout);
        extensionSocket.disconnect();
        resolve({
          success: false,
          error: `Connection error: ${error.message}`,
        });
      });
    });
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unknown error",
    };
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
  taskId: string | Id<"tasks">,
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
  }
): Promise<AgentSpawnResult> {
  try {
    // Create a task run for this specific agent
    const taskRunId = await convex.mutation(api.taskRuns.create, {
      taskId: taskId as Id<"tasks">,
      prompt: `${options.taskDescription} (${agent.name})`,
    });

    // Fetch API keys from Convex first
    const apiKeys = await convex.query(api.apiKeys.getAllForAgents);

    // Fetch the task to get image storage IDs
    const task = await convex.query(api.tasks.getById, {
      id: taskId as Id<"tasks">,
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

    // Add required API keys from Convex
    if (agent.apiKeys) {
      for (const keyConfig of agent.apiKeys) {
        const key = apiKeys[keyConfig.envVar];
        if (key && key.trim().length > 0) {
          envVars[keyConfig.envVar] = key;
        }
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
        taskRunId: taskRunId as string,
        theme: options.theme,
      });

      worktreePath = "/root/workspace";
    } else {
      // For Docker, set up worktree as before
      const worktreeInfo = await getWorktreePath({
        repoUrl: options.repoUrl,
        branch: options.branch,
      });

      // Generate a better branch/worktree name using task description and ensure uniqueness
      try {
        // Fetch branch prefix from settings
        const settings = await convex.query(api.workspaceSettings.get);
        const { branchName, worktreePath } = await suggestBranchAndWorktree({
          taskDescription: options.taskDescription,
          repoName: worktreeInfo.repoName,
          worktreesPath: worktreeInfo.worktreesPath,
          branchPrefix: settings?.branchPrefix ?? undefined,
          originPath: worktreeInfo.originPath,
        });
        // Append agent name at the end to separate agents on the same task
        const sanitizedAgentName = agent.name.replace(/\//g, '-');
        worktreeInfo.branchName = `${branchName}-${sanitizedAgentName}`;
        worktreeInfo.worktreePath = `${worktreePath}-${sanitizedAgentName}`;
      } catch (e) {
        // Fallback to the existing scheme
        const sanitizedAgentName = agent.name.replace(/\//g, '-');
        worktreeInfo.branchName = `${worktreeInfo.branchName}-${sanitizedAgentName}`;
        worktreeInfo.worktreePath = `${worktreeInfo.worktreePath}-${sanitizedAgentName}`;
      }

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
        taskRunId: taskRunId as string,
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

    // Handler for completing the task
    const handleTaskCompletion = async (exitCode: number = 0) => {
      try {
        // Capture git diff before marking as complete
        serverLogger.info(`[AgentSpawner] ============================================`);
        serverLogger.info(`[AgentSpawner] CAPTURING GIT DIFF FOR ${agent.name}`);
        serverLogger.info(`[AgentSpawner] Task Run ID: ${taskRunId}`);
        serverLogger.info(`[AgentSpawner] Worktree Path: ${worktreePath}`);
        serverLogger.info(`[AgentSpawner] VSCode Instance Connected: ${vscodeInstance.isWorkerConnected()}`);
        serverLogger.info(`[AgentSpawner] ============================================`);
        
        // Use the original captureGitDiff function which uses worker:exec
        const gitDiff = await captureGitDiff(vscodeInstance, worktreePath);
        serverLogger.info(`[AgentSpawner] Captured git diff for ${agent.name}: ${gitDiff.length} chars`);
        serverLogger.info(`[AgentSpawner] First 100 chars of diff: ${gitDiff.substring(0, 100)}`);
        
        // Append git diff to the log
        if (gitDiff && gitDiff.length > 0) {
          await convex.mutation(api.taskRuns.appendLogPublic, {
            id: taskRunId as Id<"taskRuns">,
            content: `\n\n=== GIT DIFF ===\n${gitDiff}\n=== END GIT DIFF ===\n`,
          });
          serverLogger.info(`[AgentSpawner] Successfully appended ${gitDiff.length} chars of git diff to log for ${taskRunId}`);
        } else {
          serverLogger.error(`[AgentSpawner] NO GIT DIFF TO APPEND for ${agent.name} (${taskRunId})`);
          serverLogger.error(`[AgentSpawner] This will cause crown evaluation to fail!`);
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
        
        serverLogger.info(`[AgentSpawner] Task run data retrieved: ${taskRunData ? 'found' : 'not found'}`);
        
        if (taskRunData) {
          serverLogger.info(`[AgentSpawner] Calling checkAndEvaluateCrown for task ${taskRunData.taskId}`);
          
          const winnerId = await convex.mutation(api.tasks.checkAndEvaluateCrown, {
            taskId: taskRunData.taskId,
          });
          
          serverLogger.info(`[AgentSpawner] checkAndEvaluateCrown returned: ${winnerId}`);
          
          // If winnerId is "pending", trigger Claude Code evaluation
          if (winnerId === "pending") {
            serverLogger.info(`[AgentSpawner] ==========================================`);
            serverLogger.info(`[AgentSpawner] CROWN EVALUATION NEEDED - TRIGGERING NOW`);
            serverLogger.info(`[AgentSpawner] Task ID: ${taskRunData.taskId}`);
            serverLogger.info(`[AgentSpawner] ==========================================`);
            
            // Trigger crown evaluation immediately for faster response
            // The periodic checker will also handle retries if this fails
            serverLogger.info(`[AgentSpawner] Triggering immediate crown evaluation`);
            
            // Small delay to ensure git diff is fully persisted in Convex
            setTimeout(async () => {
              try {
                // Check if evaluation is already in progress
                const task = await convex.query(api.tasks.getById, { id: taskRunData.taskId });
                if (task?.crownEvaluationError === "in_progress") {
                  serverLogger.info(`[AgentSpawner] Crown evaluation already in progress for task ${taskRunData.taskId}`);
                  return;
                }
                
                await evaluateCrownWithClaudeCode(convex, taskRunData.taskId);
                serverLogger.info(`[AgentSpawner] Crown evaluation completed successfully`);
                
                // Check if this task run won
                const updatedTaskRun = await convex.query(api.taskRuns.get, {
                  id: taskRunId as Id<"taskRuns">,
                });
                
                if (updatedTaskRun?.isCrowned) {
                  serverLogger.info(`[AgentSpawner] 🏆 This task run won the crown! ${agent.name} is the winner!`);
                }
              } catch (error) {
                serverLogger.error(`[AgentSpawner] Crown evaluation failed:`, error);
                // The periodic checker will retry
              }
            }, 3000); // 3 second delay to ensure data persistence
          } else if (winnerId) {
            serverLogger.info(`[AgentSpawner] Crown winner already selected: ${winnerId}`);
          } else {
            serverLogger.info(`[AgentSpawner] No crown evaluation needed (winnerId: ${winnerId})`);
          }
        }

        const ENABLE_AUTO_COMMIT = false; // Disabled to ensure git diff capture works

        // Skip auto-commit - we'll let the user commit manually after crown evaluation
        if (ENABLE_AUTO_COMMIT && taskRunData) {
          serverLogger.info(`[AgentSpawner] Auto-commit is disabled to ensure proper crown evaluation`);
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
        serverLogger.info(`[AgentSpawner] Waiting 3 seconds for file system to settle before capturing git diff...`);
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        await handleTaskCompletion(data.exitCode || 0);
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
        serverLogger.info(`[AgentSpawner] Task ID matched! Marking task as complete for ${agent.name}`);
        // CRITICAL: Add a delay to ensure changes are written to disk
        serverLogger.info(`[AgentSpawner] Waiting 3 seconds for file system to settle before capturing git diff...`);
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        await handleTaskCompletion(0);
      } else {
        serverLogger.warn(`[AgentSpawner] Task ID did not match, ignoring idle event`);
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
        serverLogger.error(`[AgentSpawner] Error handling terminal-failed:`, error);
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
    const commandString = [actualCommand, ...actualArgs].map(shellEscaped).join(" ");

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
      taskId: taskRunId,
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
  taskId: string | Id<"tasks">,
  options: {
    repoUrl: string;
    branch?: string;
    taskDescription: string;
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
  // Spawn agents sequentially to avoid git lock conflicts

  // If selectedAgents is provided, filter AGENT_CONFIGS to only include selected agents
  const agentsToSpawn = options.selectedAgents
    ? AGENT_CONFIGS.filter((agent) =>
        options.selectedAgents!.includes(agent.name)
      )
    : AGENT_CONFIGS;

  // const results: AgentSpawnResult[] = [];
  // for (const agent of agentsToSpawn) {
  //   const result = await spawnAgent(agent, taskId, options);
  //   results.push(result);
  // }
  const results = await Promise.all(
    agentsToSpawn.map((agent) => spawnAgent(agent, taskId, options))
  );

  return results;
}
