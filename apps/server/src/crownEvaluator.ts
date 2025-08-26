import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { spawn } from "node:child_process";
import { z } from "zod";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken.js";
import { getGitRepoInfo, getLatestCommitMessage } from "./utils/gitRepoInfo.js";
import { createReadyPr } from "./utils/githubPr.js";
import { workerExec } from "./utils/workerExec.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";

// Auto PR behavior is controlled via workspace settings in Convex

const CrownEvaluationResponseSchema = z.object({
  winner: z.number().int().min(0),
  reason: z.string(),
});

type CrownEvaluationResponse = z.infer<typeof CrownEvaluationResponseSchema>;

export async function createPullRequestForWinner(
  taskRunId: Id<"taskRuns">,
  taskId: Id<"tasks">,
  githubToken?: string | null
): Promise<void> {
  try {
    // Check workspace settings toggle (default: disabled)
    const ws = await convex.query(api.workspaceSettings.get);
    const autoPrEnabled = !!ws?.autoPrEnabled;
    if (!autoPrEnabled) {
      serverLogger.info(
        `[CrownEvaluator] Auto-PR disabled in settings; skipping.`
      );
      return;
    }
    
    if (!githubToken) {
      serverLogger.info(
        `[CrownEvaluator] No GitHub token configured - skipping PR creation`
      );
      return;
    }
    
    serverLogger.info(
      `[CrownEvaluator] Creating pull request for winner ${taskRunId}`
    );

    // Get the task run details
    const taskRun = await convex.query(api.taskRuns.get, { id: taskRunId });
    if (!taskRun || !taskRun.vscode?.containerName) {
      serverLogger.error(
        `[CrownEvaluator] No VSCode instance found for task run ${taskRunId}`
      );
      return;
    }

    // Get the task details
    const task = await convex.query(api.tasks.getById, { id: taskId });
    if (!task) {
      serverLogger.error(`[CrownEvaluator] Task ${taskId} not found`);
      return;
    }

    // Find the VSCode instance
    const instances = VSCodeInstance.getInstances();
    let vscodeInstance: VSCodeInstance | null = null;

    // Look for the instance by taskRunId
    for (const [_id, instance] of instances) {
      if (instance.getTaskRunId() === taskRunId) {
        vscodeInstance = instance;
        break;
      }
    }

    if (!vscodeInstance) {
      serverLogger.error(
        `[CrownEvaluator] VSCode instance not found for task run ${taskRunId}`
      );
      return;
    }

    // Extract agent name from prompt
    const agentMatch = taskRun.prompt.match(/\(([^)]+)\)$/);
    const agentName = agentMatch ? agentMatch[1] : "Unknown";

    // Use the newBranch from the task run
    const branchName = taskRun.newBranch || `cmux-crown-${taskRunId.slice(-8)}`;

    // Get repository information
    const repoInfo = await getGitRepoInfo();
    
    // Get the latest commit message to extract title and body
    const commitInfo = await getLatestCommitMessage();
    
    // Use commit message subject as PR title, fallback to task text
    const prTitle = commitInfo.subject || task.pullRequestTitle || task.text || "Task completed by cmux";
    
    // Persist PR title if not already set or differs
    if (!task.pullRequestTitle || task.pullRequestTitle !== prTitle) {
      try {
        await convex.mutation(api.tasks.setPullRequestTitle, {
          id: taskId,
          pullRequestTitle: prTitle,
        });
      } catch (e) {
        serverLogger.error(`[CrownEvaluator] Failed to save PR title:`, e);
      }
    }
    
    // Create PR body from commit message body and add metadata
    const prBody = commitInfo.body ? 
      `${commitInfo.body}

## Summary
- Task completed by ${agentName} agent 🏆
- ${taskRun.crownReason || "Selected as the best implementation"}

## Details
- Task ID: ${taskId}
- Agent: ${agentName}
- Branch: ${branchName}
- Completed: ${new Date().toISOString()}` :
      `## Summary
- Task completed by ${agentName} agent 🏆
- ${taskRun.crownReason || "Selected as the best implementation"}

## Details
- Task ID: ${taskId}
- Agent: ${agentName}
- Branch: ${branchName}
- Completed: ${new Date().toISOString()}`;

    // Persist PR description on the task in Convex
    try {
      await convex.mutation(api.tasks.setPullRequestDescription, {
        id: taskId,
        pullRequestDescription: prBody,
      });
    } catch (e) {
      serverLogger.error(`[CrownEvaluator] Failed to save PR description:`, e);
    }

    try {
      // Create PR using Octokit
      serverLogger.info(`[CrownEvaluator] Creating PR using GitHub API`);
      
      const pr = await createReadyPr(
        githubToken,
        repoInfo.owner,
        repoInfo.repo,
        prTitle,
        branchName,
        repoInfo.defaultBranch,
        prBody
      );
      
      serverLogger.info(`[CrownEvaluator] PR created successfully!`);
      serverLogger.info(`[CrownEvaluator] PR URL: ${pr.html_url}`);
      
      // Update the task run with PR URL
      await convex.mutation(api.taskRuns.updatePullRequestUrl, {
        id: taskRunId,
        pullRequestUrl: pr.html_url,
        isDraft: false,
      });
      
    } catch (error) {
      serverLogger.error(`[CrownEvaluator] Failed to create PR using GitHub API:`, error);
      
      // If PR already exists for this branch, we can try to find it
      if (error && typeof error === 'object' && 'status' in error && error.status === 422) {
        serverLogger.info(`[CrownEvaluator] PR might already exist for branch ${branchName}`);
      }
    }
    
    serverLogger.info(`[CrownEvaluator] Pull request creation completed`);
  } catch (error) {
    serverLogger.error(`[CrownEvaluator] Error creating pull request:`, error);
  }
}

// Removed VSCode extension fallback; using worker:exec exclusively

export async function evaluateCrownWithClaudeCode(
  taskId: Id<"tasks">
): Promise<void> {
  serverLogger.info(
    `[CrownEvaluator] =================================================`
  );
  serverLogger.info(
    `[CrownEvaluator] STARTING CROWN EVALUATION FOR TASK ${taskId}`
  );
  serverLogger.info(
    `[CrownEvaluator] =================================================`
  );

  try {
    const githubToken = await getGitHubTokenFromKeychain();

    // Get task and runs
    const task = await convex.query(api.tasks.getById, { id: taskId });
    if (!task) {
      throw new Error("Task not found");
    }

    const taskRuns = await convex.query(api.taskRuns.getByTask, {
      taskId,
    });
    const completedRuns = taskRuns.filter((run) => run.status === "completed");

    if (completedRuns.length < 2) {
      serverLogger.info(
        `[CrownEvaluator] Not enough completed runs (${completedRuns.length})`
      );
      return;
    }

    // Double-check if evaluation already exists
    const existingEvaluation = await convex.query(
      api.crown.getCrownEvaluation,
      {
        taskId: taskId,
      }
    );

    if (existingEvaluation) {
      serverLogger.info(
        `[CrownEvaluator] Crown evaluation already exists for task ${taskId}, skipping`
      );
      // Clear the pending status
      await convex.mutation(api.tasks.updateCrownError, {
        id: taskId,
        crownEvaluationError: undefined,
      });
      return;
    }

    // Helper to extract a relevant git diff using worker script when possible
    const collectDiffViaWorker = async (
      runId: Id<"taskRuns">
    ): Promise<string | null> => {
      try {
        // Find a live VSCode instance for this run
        const instances = VSCodeInstance.getInstances();
        let instance: VSCodeInstance | undefined;
        for (const [, inst] of instances) {
          if (inst.getTaskRunId() === runId) {
            instance = inst;
            break;
          }
        }
        if (!instance || !instance.isWorkerConnected()) {
          serverLogger.info(
            `[CrownEvaluator] No live worker for run ${runId}; falling back to log parsing`
          );
          return null;
        }
        const workerSocket = instance.getWorkerSocket();
        const { stdout } = await workerExec({
          workerSocket,
          command: "/bin/bash",
          args: ["-c", "/usr/local/bin/cmux-collect-relevant-diff.sh"],
          cwd: "/root/workspace",
          env: {},
          timeout: 30000,
        });
        const diff = stdout?.trim() || "";
        if (diff.length === 0) {
          serverLogger.info(
            `[CrownEvaluator] Worker diff empty for run ${runId}; falling back to log parsing`
          );
          return null;
        }
        serverLogger.info(
          `[CrownEvaluator] Collected worker diff for ${runId} (${diff.length} chars)`
        );
        return diff;
      } catch (err) {
        serverLogger.error(
          `[CrownEvaluator] Failed collecting worker diff for run ${runId}:`,
          err
        );
        return null;
      }
    };

    const candidateData = await Promise.all(
      completedRuns.map(async (run, idx) => {
        // Extract agent name from prompt
        const agentMatch = run.prompt.match(/\(([^)]+)\)$/);
        const agentName = agentMatch ? agentMatch[1] : "Unknown";
        // Try to collect diff via worker
        const workerDiff: string | null = await collectDiffViaWorker(run._id);
        let gitDiff: string = workerDiff ?? "";

        // Fallback: Extract git diff from log - look for the dedicated sections
        if (!gitDiff) {
          gitDiff = "No changes detected";

          // Look for our well-defined git diff section - try multiple formats
          let gitDiffMatch = run.log.match(
            /=== GIT DIFF ===\n([\s\S]*?)\n=== END GIT DIFF ===/
          );

          // Also try the new format with "ALL CHANGES"
          if (!gitDiffMatch) {
            gitDiffMatch = run.log.match(
              /=== ALL CHANGES \(git diff HEAD\) ===\n([\s\S]*?)\n=== END ALL CHANGES ===/
            );
          }

          if (gitDiffMatch && gitDiffMatch[1]) {
            gitDiff = gitDiffMatch[1].trim();

            // If the diff includes the stat summary, extract just the detailed diff part
            if (gitDiff.includes("=== DETAILED DIFF ===")) {
              const detailedPart = gitDiff.split("=== DETAILED DIFF ===")[1];
              if (detailedPart) {
                gitDiff = detailedPart.trim();
              }
            }

            serverLogger.info(
              `[CrownEvaluator] Found git diff in logs for ${agentName}: ${gitDiff.length} chars`
            );
          } else {
            // If no git diff section found, this is a serious problem
            serverLogger.error(
              `[CrownEvaluator] NO GIT DIFF SECTION FOUND for ${agentName}!`
            );
            serverLogger.error(
              `[CrownEvaluator] Log contains "=== GIT DIFF ==="?: ${run.log.includes("=== GIT DIFF ===")}`
            );
            serverLogger.error(
              `[CrownEvaluator] Log contains "=== END GIT DIFF ==="?: ${run.log.includes("=== END GIT DIFF ===")}`
            );
            serverLogger.error(
              `[CrownEvaluator] Log contains "=== ALL CHANGES"?: ${run.log.includes("=== ALL CHANGES")}`
            );

            // As a last resort, check if there's any indication of changes
            if (
              run.log.includes("=== ALL STAGED CHANGES") ||
              run.log.includes("=== AGGRESSIVE DIFF CAPTURE") ||
              run.log.includes("ERROR: git diff --cached was empty")
            ) {
              // Use whatever we can find
              const lastPart = run.log.slice(-3000);
              gitDiff = `ERROR: Git diff not properly captured. Last part of log:\n${lastPart}`;
            }
          }
        }

        // Limit to 5000 chars for the prompt
        if (gitDiff.length > 5000) {
          gitDiff = gitDiff.substring(0, 5000) + "\n... (truncated)";
        }

        serverLogger.info(
          `[CrownEvaluator] Implementation ${idx} (${agentName}): ${gitDiff.length} chars of diff`
        );

        // Log last 500 chars of the run log to debug
        serverLogger.info(
          `[CrownEvaluator] ${agentName} log tail: ...${run.log.slice(-500)}`
        );

        return {
          index: idx,
          runId: run._id,
          agentName,
          exitCode: run.exitCode || 0,
          gitDiff,
        };
      })
    );

    // Log what we found for debugging
    for (const c of candidateData) {
      serverLogger.info(
        `[CrownEvaluator] ${c.agentName} diff preview: ${c.gitDiff.substring(0, 200)}...`
      );

      if (
        c.gitDiff === "No changes detected" ||
        c.gitDiff.startsWith("ERROR:")
      ) {
        serverLogger.error(
          `[CrownEvaluator] WARNING: ${c.agentName} has no valid git diff!`
        );
      }
    }

    // Create structured data for the evaluation
    const evaluationData = {
      implementations: candidateData.map((candidate, idx) => ({
        modelName: candidate.agentName,
        gitDiff: candidate.gitDiff,
        index: idx,
      })),
    };

    // Create evaluation prompt with structured output request
    const evaluationPrompt = `You are evaluating code implementations from different AI models.

Here are the implementations to evaluate:
${JSON.stringify(evaluationData, null, 2)}

NOTE: The git diffs shown contain only actual code changes. Lock files, build artifacts, and other non-essential files have been filtered out.

Analyze these implementations and select the best one based on:
1. Code quality and correctness
2. Completeness of the solution
3. Following best practices
4. Actually having meaningful code changes (if one has no changes, prefer the one with changes)

Respond with a JSON object containing:
- "winner": the index (0-based) of the best implementation
- "reason": a brief explanation of why this implementation was chosen

Example response:
{"winner": 0, "reason": "Model claude/sonnet-4 provided a more complete implementation with better error handling and cleaner code structure."}

IMPORTANT: Respond ONLY with the JSON object, no other text.`;

    serverLogger.info(
      `[CrownEvaluator] Evaluation prompt length: ${evaluationPrompt.length} characters`
    );

    // Log prompt structure for debugging
    const promptLines = evaluationPrompt.split("\n");
    serverLogger.info(
      `[CrownEvaluator] Prompt has ${promptLines.length} lines`
    );
    serverLogger.info(`[CrownEvaluator] First 5 lines of prompt:`);
    promptLines.slice(0, 5).forEach((line, idx) => {
      serverLogger.info(
        `[CrownEvaluator]   ${idx}: ${line.substring(0, 100)}${line.length > 100 ? "..." : ""}`
      );
    });

    // Update status to in_progress
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: "in_progress",
    });

    serverLogger.info(`[CrownEvaluator] Starting Claude Code spawn...`);
    const startTime = Date.now();

    // Try multiple approaches to run claude-code
    let stdout = "";
    let stderr = "";
    let exitCode = -1;

    // Only use bunx since npx consistently times out
    try {
      serverLogger.info(`[CrownEvaluator] Attempting to run with bunx...`);

      // Remove --print flag and use stdin instead for more reliable execution
      const args = [
        "@anthropic-ai/claude-code",
        "--model",
        "claude-sonnet-4-20250514",
        "--dangerously-skip-permissions",
      ];

      serverLogger.info(`[CrownEvaluator] Command: bunx ${args.join(" ")}`);

      const bunxProcess = spawn("bunx", args, {
        env: { ...process.env },
        stdio: ["pipe", "pipe", "pipe"],
        shell: false,
      });

      serverLogger.info(
        `[CrownEvaluator] Process spawned with PID: ${bunxProcess.pid}`
      );

      // Write prompt to stdin and close
      bunxProcess.stdin.write(evaluationPrompt);
      bunxProcess.stdin.end();

      stdout = "";
      stderr = "";

      // Track if we've received any data
      let receivedStdout = false;
      let receivedStderr = false;
      let lastStderr = "";

      bunxProcess.stdout.on("data", (data) => {
        const chunk = data.toString();
        stdout += chunk;
        receivedStdout = true;
        serverLogger.info(
          `[CrownEvaluator] stdout (${chunk.length} chars): ${chunk.substring(0, 200)}`
        );
      });

      bunxProcess.stderr.on("data", (data) => {
        const chunk = data.toString();
        stderr += chunk;
        lastStderr = chunk;
        receivedStderr = true;

        // Log all stderr to debug the issue
        serverLogger.info(`[CrownEvaluator] stderr: ${chunk.trim()}`);
      });

      // Add more detailed event handlers
      bunxProcess.on("exit", (code, signal) => {
        serverLogger.info(
          `[CrownEvaluator] Process exited with code ${code} and signal ${signal}`
        );
        serverLogger.info(
          `[CrownEvaluator] Exit occurred after ${Date.now() - startTime}ms`
        );
      });

      bunxProcess.on("error", (error) => {
        serverLogger.error(`[CrownEvaluator] Process spawn error:`, error);
      });

      exitCode = await new Promise<number>((resolve, reject) => {
        let processExited = false;

        bunxProcess.on("close", (code) => {
          processExited = true;
          serverLogger.info(
            `[CrownEvaluator] Process closed with code: ${code}`
          );
          serverLogger.info(
            `[CrownEvaluator] Received stdout: ${receivedStdout}, Received stderr: ${receivedStderr}`
          );
          serverLogger.info(
            `[CrownEvaluator] Total stdout length: ${stdout.length}, stderr length: ${stderr.length}`
          );

          if (stderr.length > 0) {
            serverLogger.info(`[CrownEvaluator] Full stderr output:`);
            stderr.split("\n").forEach((line, idx) => {
              if (line.trim()) {
                serverLogger.info(`[CrownEvaluator]   stderr[${idx}]: ${line}`);
              }
            });
          }

          if (lastStderr.includes("Saved lockfile") && stdout.length === 0) {
            serverLogger.error(
              `[CrownEvaluator] Process failed after saving lockfile with no output`
            );
            serverLogger.error(
              `[CrownEvaluator] This suggests Claude Code started but failed to execute`
            );
          }

          resolve(code || 0);
        });

        bunxProcess.on("error", (err) => {
          processExited = true;
          serverLogger.error(`[CrownEvaluator] Process error: ${err.message}`);
          reject(err);
        });

        setTimeout(() => {
          if (!processExited) {
            serverLogger.error(
              `[CrownEvaluator] Process timeout after 60 seconds, killing...`
            );
            bunxProcess.kill("SIGKILL");
            reject(new Error("Timeout"));
          }
        }, 60000); // Reduce timeout to 60 seconds
      });

      serverLogger.info(
        `[CrownEvaluator] bunx completed with exit code ${exitCode}`
      );
    } catch (bunxError) {
      serverLogger.error(`[CrownEvaluator] bunx failed:`, bunxError);

      // Fallback: Pick the first completed run as winner if Claude Code fails
      serverLogger.warn(
        `[CrownEvaluator] Falling back to selecting first completed run as winner`
      );

      const fallbackWinner = candidateData[0];
      await convex.mutation(api.crown.setCrownWinner, {
        taskRunId: fallbackWinner.runId,
        reason: "Selected as fallback winner (crown evaluation failed to run)",
      });

      await convex.mutation(api.tasks.updateCrownError, {
        id: taskId,
        crownEvaluationError: undefined,
      });

      serverLogger.info(
        `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
      );
      await createPullRequestForWinner(
        fallbackWinner.runId,
        taskId,
        githubToken || undefined
      );
      return;
    }

    serverLogger.info(
      `[CrownEvaluator] Process completed after ${Date.now() - startTime}ms`
    );
    serverLogger.info(`[CrownEvaluator] Exit code: ${exitCode}`);
    serverLogger.info(`[CrownEvaluator] Stdout length: ${stdout.length}`);
    serverLogger.info(`[CrownEvaluator] Full stdout:\n${stdout}`);

    if (exitCode !== 0) {
      serverLogger.error(
        `[CrownEvaluator] Claude Code exited with error code ${exitCode}. Stderr: ${stderr}`
      );

      // Fallback: Pick the first completed run as winner if Claude Code fails
      serverLogger.warn(
        `[CrownEvaluator] Falling back to selecting first completed run as winner due to non-zero exit code`
      );

      const fallbackWinner = candidateData[0];
      await convex.mutation(api.crown.setCrownWinner, {
        taskRunId: fallbackWinner.runId,
        reason:
          "Selected as fallback winner (crown evaluation exited with error)",
      });

      await convex.mutation(api.tasks.updateCrownError, {
        id: taskId,
        crownEvaluationError: undefined,
      });

      serverLogger.info(
        `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
      );
      await createPullRequestForWinner(
        fallbackWinner.runId,
        taskId,
        githubToken || undefined
      );
      return;
    }

    // Parse the response
    let jsonResponse: CrownEvaluationResponse;

    // Try to extract JSON from stdout - look for any JSON object with winner and reason
    const jsonMatch =
      stdout.match(
        /\{[^{}]*"winner"\s*:\s*\d+[^{}]*"reason"\s*:\s*"[^"]*"[^{}]*\}/
      ) ||
      stdout.match(
        /\{[^{}]*"reason"\s*:\s*"[^"]*"[^{}]*"winner"\s*:\s*\d+[^{}]*\}/
      );

    if (!jsonMatch) {
      serverLogger.error(
        `[CrownEvaluator] No JSON found in output. Full stdout:\n${stdout}`
      );

      // Try to find a complete JSON object anywhere in the output
      try {
        // Remove any non-JSON content before/after
        const possibleJson = stdout.substring(
          stdout.indexOf("{"),
          stdout.lastIndexOf("}") + 1
        );
        const parsed = JSON.parse(possibleJson);
        jsonResponse = CrownEvaluationResponseSchema.parse(parsed);
        serverLogger.info(
          `[CrownEvaluator] Extracted JSON from output: ${JSON.stringify(jsonResponse)}`
        );
      } catch {
        // Last resort - try to find just a number
        const numberMatch = stdout.match(/\b([01])\b/);
        if (numberMatch) {
          const index = parseInt(numberMatch[1], 10);
          jsonResponse = {
            winner: index,
            reason: `Selected ${candidateData[index].agentName} based on implementation quality`,
          };
          serverLogger.info(
            `[CrownEvaluator] Extracted winner index ${index} from output`
          );
        } else {
          serverLogger.error(
            `[CrownEvaluator] Could not extract valid response from output`
          );

          // Fallback: Pick the first completed run as winner
          const fallbackWinner = candidateData[0];
          await convex.mutation(api.crown.setCrownWinner, {
            taskRunId: fallbackWinner.runId,
            reason:
              "Selected as fallback winner (no valid response from evaluator)",
          });

          await convex.mutation(api.tasks.updateCrownError, {
            id: taskId,
            crownEvaluationError: undefined,
          });

          serverLogger.info(
            `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
          );
          await createPullRequestForWinner(
            fallbackWinner.runId,
            taskId,
            githubToken || undefined
          );
          return;
        }
      }
    } else {
      try {
        const parsed = JSON.parse(jsonMatch[0]);
        jsonResponse = CrownEvaluationResponseSchema.parse(parsed);
        serverLogger.info(
          `[CrownEvaluator] Successfully parsed JSON response: ${JSON.stringify(jsonResponse)}`
        );
      } catch (parseError) {
        serverLogger.error(
          `[CrownEvaluator] Failed to parse JSON:`,
          parseError
        );

        // Fallback: Pick the first completed run as winner
        const fallbackWinner = candidateData[0];
        await convex.mutation(api.crown.setCrownWinner, {
          taskRunId: fallbackWinner.runId,
          reason: "Selected as fallback winner (invalid JSON from evaluator)",
        });

        await convex.mutation(api.tasks.updateCrownError, {
          id: taskId,
          crownEvaluationError: undefined,
        });

        serverLogger.info(
          `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
        );
        await createPullRequestForWinner(
          fallbackWinner.runId,
          taskId,
          githubToken || undefined
        );
        return;
      }
    }

    // Validate winner index
    if (jsonResponse.winner >= candidateData.length) {
      serverLogger.error(
        `[CrownEvaluator] Invalid winner index ${jsonResponse.winner}, must be less than ${candidateData.length}`
      );

      // Fallback: Pick the first completed run as winner
      const fallbackWinner = candidateData[0];
      await convex.mutation(api.crown.setCrownWinner, {
        taskRunId: fallbackWinner.runId,
        reason:
          "Selected as fallback winner (invalid winner index from evaluator)",
      });

      await convex.mutation(api.tasks.updateCrownError, {
        id: taskId,
        crownEvaluationError: undefined,
      });

      serverLogger.info(
        `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
      );
      await createPullRequestForWinner(
        fallbackWinner.runId,
        taskId,
        githubToken || undefined
      );
      return;
    }

    const winner = candidateData[jsonResponse.winner];
    serverLogger.info(
      `[CrownEvaluator] WINNER SELECTED: ${winner.agentName} (index ${jsonResponse.winner})`
    );
    serverLogger.info(`[CrownEvaluator] Reason: ${jsonResponse.reason}`);

    // Update the database
    await convex.mutation(api.crown.setCrownWinner, {
      taskRunId: winner.runId,
      reason: jsonResponse.reason,
    });

    // Clear any error
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: undefined,
    });

    serverLogger.info(
      `[CrownEvaluator] Crown evaluation completed successfully for task ${taskId}`
    );

    // Create pull request for the winner
    await createPullRequestForWinner(
      winner.runId,
      taskId,
      githubToken || undefined
    );
  } catch (error) {
    serverLogger.error(`[CrownEvaluator] Error during evaluation:`, error);

    // Update task with error status
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: `Failed: ${error instanceof Error ? error.message : String(error)}`,
    });

    throw error;
  }
}
