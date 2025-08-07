import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { spawn } from "node:child_process";
import { serverLogger } from "./utils/fileLogger.js";
import type { ConvexHttpClient } from "convex/browser";
import { z } from "zod";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance.js";

// Define schemas for structured output
const ImplementationSchema = z.object({
  modelName: z.string(),
  gitDiff: z.string(),
  index: z.number(),
});

const CrownEvaluationRequestSchema = z.object({
  implementations: z.array(ImplementationSchema),
});

const CrownEvaluationResponseSchema = z.object({
  winner: z.number().int().min(0),
  reason: z.string(),
});

type CrownEvaluationResponse = z.infer<typeof CrownEvaluationResponseSchema>;

async function createPullRequestForWinner(
  convex: ConvexHttpClient,
  taskRunId: Id<"taskRuns">,
  taskId: Id<"tasks">,
  githubToken?: string | null
): Promise<void> {
  try {
    serverLogger.info(`[CrownEvaluator] Creating pull request for winner ${taskRunId}`);
    
    // Get the task run details
    const taskRun = await convex.query(api.taskRuns.get, { id: taskRunId });
    if (!taskRun || !taskRun.vscode?.containerName) {
      serverLogger.error(`[CrownEvaluator] No VSCode instance found for task run ${taskRunId}`);
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
    for (const [id, instance] of instances) {
      if (instance.getTaskRunId() === taskRunId) {
        vscodeInstance = instance;
        break;
      }
    }
    
    if (!vscodeInstance) {
      serverLogger.error(`[CrownEvaluator] VSCode instance not found for task run ${taskRunId}`);
      return;
    }
    
    // Extract agent name from prompt
    const agentMatch = taskRun.prompt.match(/\(([^)]+)\)$/);
    const agentName = agentMatch ? agentMatch[1] : "Unknown";
    
    // Create PR title and body
    const prTitle = task.text || "Task completed by cmux";
    const prBody = `## Summary
- Task completed by ${agentName} agent 🏆
- ${taskRun.crownReason || "Selected as the best implementation"}

## Details
- Task ID: ${taskId}
- Agent: ${agentName}
- Completed: ${new Date().toISOString()}

---
🤖 Generated with [cmux](https://github.com/lawrencecchen/cmux)`;
    
    // Create sanitized branch name
    const sanitizedTaskDesc = (task.text || "task")
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, "")
      .trim()
      .split(/\s+/)
      .slice(0, 5)
      .join("-")
      .substring(0, 30);
    
    const branchName = `cmux-${agentName}-${sanitizedTaskDesc}-${taskRunId}`
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/--+/g, "-");
    
    // Create commit message
    const truncatedDescription = prTitle.length > 72
      ? prTitle.substring(0, 69) + "..."
      : prTitle;
    
    const commitMessage = `${truncatedDescription}

Task completed by ${agentName} agent 🏆
${taskRun.crownReason ? `\nReason: ${taskRun.crownReason}` : ''}

🤖 Generated with cmux
Agent: ${agentName}
Task Run ID: ${taskRunId}
Branch: ${branchName}
Completed: ${new Date().toISOString()}`;
    
    // Use worker sockets directly (more reliable than VSCode extension)
    serverLogger.info(`[CrownEvaluator] Using worker sockets for git operations`);
    
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.error(`[CrownEvaluator] No worker connection available`);
      return;
    }
    
    // Execute git commands via worker:exec (more reliable than terminal-input)
    const gitCommands = [
      // Add all changes
      { cmd: "git add .", desc: "Staging changes" },
      // Create and switch to new branch
      { cmd: `git checkout -b ${branchName}`, desc: "Creating branch" },
      // Commit
      { cmd: `git commit -m "${commitMessage.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$")}"`, desc: "Committing" },
      // Push
      { cmd: `git push -u origin ${branchName}`, desc: "Pushing branch" },
    ];
    
    // Only add PR creation command if GitHub token is available
    if (githubToken) {
      gitCommands.push({
        cmd: `GH_TOKEN="${githubToken}" gh pr create --title "${prTitle.replace(/"/g, '\\"')}" --body "${prBody.replace(/"/g, '\\"').replace(/\n/g, '\\n')}" --head "${branchName}"`,
        desc: "Creating PR"
      });
    } else {
      serverLogger.info(`[CrownEvaluator] Skipping PR creation - no GitHub token configured`);
      serverLogger.info(`[CrownEvaluator] Branch '${branchName}' has been pushed. You can manually create a PR from GitHub.`);
    }
    
    for (const { cmd, desc } of gitCommands) {
      serverLogger.info(`[CrownEvaluator] ${desc}...`);
      
      const result = await new Promise<{ success: boolean; error?: string; stdout?: string; stderr?: string }>((resolve) => {
        workerSocket
          .timeout(30000)
          .emit(
            "worker:exec",
            {
              command: "/bin/bash",
              args: ["-c", cmd],
              cwd: "/root/workspace",
              env: githubToken ? { GH_TOKEN: githubToken } : {},
            },
            (timeoutError: any, result: any) => {
              if (timeoutError) {
                resolve({ success: false, error: "Command timeout" });
                return;
              }
              if (result.error) {
                resolve({ success: false, error: result.error.message });
                return;
              }
              
              const { stdout, stderr, exitCode } = result.data;
              serverLogger.info(`[CrownEvaluator] ${desc} - stdout:`, stdout);
              if (stderr) {
                serverLogger.info(`[CrownEvaluator] ${desc} - stderr:`, stderr);
              }
              
              resolve({ success: exitCode === 0, stdout, stderr });
            }
          );
      });
      
      if (!result.success) {
        serverLogger.error(`[CrownEvaluator] Failed at step: ${desc}`, result.error);
        
        // If gh pr create fails, log more details
        if (cmd.includes("gh pr create")) {
          serverLogger.error(`[CrownEvaluator] PR creation failed. stdout: ${result.stdout}, stderr: ${result.stderr}`);
          
          // Try to check gh auth status
          const authCheckResult = await new Promise<{ success: boolean; stdout?: string; stderr?: string }>((resolve) => {
            workerSocket
              .timeout(10000)
              .emit(
                "worker:exec",
                {
                  command: "/bin/bash",
                  args: ["-c", githubToken ? `GH_TOKEN="${githubToken}" gh auth status` : "gh auth status"],
                  cwd: "/root/workspace",
                  env: githubToken ? { GH_TOKEN: githubToken } : {},
                },
                (timeoutError: any, authResult: any) => {
                  if (timeoutError || authResult.error) {
                    resolve({ success: false, stdout: "", stderr: timeoutError ? "timeout" : authResult.error.message });
                    return;
                  }
                  const { stdout, stderr, exitCode } = authResult.data;
                  resolve({ success: exitCode === 0, stdout, stderr });
                }
              );
          });
          
          serverLogger.error(`[CrownEvaluator] gh auth status - stdout: ${authCheckResult.stdout}, stderr: ${authCheckResult.stderr}`);
        }
        
        // Continue anyway for some commands
        if (!cmd.includes("git checkout") && !cmd.includes("gh pr create")) {
          return;
        }
      } else {
        // If successful and it's the PR creation command, log the URL
        if (cmd.includes("gh pr create") && result.stdout) {
          serverLogger.info(`[CrownEvaluator] PR created successfully!`);
          serverLogger.info(`[CrownEvaluator] PR URL: ${result.stdout.trim()}`);
        }
      }
    }
    
    serverLogger.info(`[CrownEvaluator] Pull request creation completed`);
    
  } catch (error) {
    serverLogger.error(`[CrownEvaluator] Error creating pull request:`, error);
  }
}


export async function evaluateCrownWithClaudeCode(
  convex: ConvexHttpClient,
  taskId: Id<"tasks">
): Promise<void> {
  serverLogger.info(`[CrownEvaluator] =================================================`);
  serverLogger.info(`[CrownEvaluator] STARTING CROWN EVALUATION FOR TASK ${taskId}`);
  serverLogger.info(`[CrownEvaluator] =================================================`);

  try {
    // Get GitHub token
    const { getGitHubTokenFromKeychain } = await import("./utils/getGitHubToken.js");
    const githubToken = await getGitHubTokenFromKeychain(convex);
    
    // Get task and runs
    const task = await convex.query(api.tasks.getById, { id: taskId });
    if (!task) {
      throw new Error("Task not found");
    }

    const taskRuns = await convex.query(api.taskRuns.getByTask, { taskId });
    const completedRuns = taskRuns.filter((run: any) => run.status === "completed");

  if (completedRuns.length < 2) {
    serverLogger.info(`[CrownEvaluator] Not enough completed runs (${completedRuns.length})`);
    return;
  }
  
  // Double-check if evaluation already exists
  const existingEvaluation = await convex.query(api.crown.getCrownEvaluation, {
    taskId: taskId,
  });
  
  if (existingEvaluation) {
    serverLogger.info(`[CrownEvaluator] Crown evaluation already exists for task ${taskId}, skipping`);
    // Clear the pending status
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: undefined,
    });
    return;
  }

  // Prepare evaluation data
  const candidateData = completedRuns.map((run, idx) => {
    // Extract agent name from prompt
    const agentMatch = run.prompt.match(/\(([^)]+)\)$/);
    const agentName = agentMatch ? agentMatch[1] : "Unknown";

    // Extract git diff from log - look for the dedicated GIT DIFF section
    let gitDiff = "No changes detected";
    
    // Look for our well-defined git diff section
    const gitDiffMatch = run.log.match(/=== GIT DIFF ===\n([\s\S]*?)\n=== END GIT DIFF ===/);
    if (gitDiffMatch && gitDiffMatch[1]) {
      gitDiff = gitDiffMatch[1].trim();
      serverLogger.info(`[CrownEvaluator] Found git diff in standard format for ${agentName}: ${gitDiff.length} chars`);
    } else {
      // If no git diff section found, this is a serious problem
      serverLogger.error(`[CrownEvaluator] NO GIT DIFF SECTION FOUND for ${agentName}!`);
      serverLogger.error(`[CrownEvaluator] Log length: ${run.log.length}`);
      serverLogger.error(`[CrownEvaluator] Log contains "=== GIT DIFF ==="?: ${run.log.includes("=== GIT DIFF ===")}`)
      serverLogger.error(`[CrownEvaluator] Log contains "=== END GIT DIFF ==="?: ${run.log.includes("=== END GIT DIFF ===")}`)
      
      // As a last resort, check if there's any indication of changes
      if (run.log.includes("=== ALL STAGED CHANGES") || 
          run.log.includes("=== AGGRESSIVE DIFF CAPTURE") ||
          run.log.includes("ERROR: git diff --cached was empty")) {
        // Use whatever we can find
        const lastPart = run.log.slice(-3000);
        gitDiff = `ERROR: Git diff not properly captured. Last part of log:\n${lastPart}`;
      }
    }
    
    // Limit to 5000 chars for the prompt
    if (gitDiff.length > 5000) {
      gitDiff = gitDiff.substring(0, 5000) + "\n... (truncated)";
    }

    serverLogger.info(`[CrownEvaluator] Implementation ${idx} (${agentName}): ${gitDiff.length} chars of diff`);
    
    // Log last 500 chars of the run log to debug
    serverLogger.info(`[CrownEvaluator] ${agentName} log tail: ...${run.log.slice(-500)}`);

    return {
      index: idx,
      runId: run._id,
      agentName,
      exitCode: run.exitCode || 0,
      gitDiff,
    };
  });

  // Log what we found for debugging
  for (const c of candidateData) {
    serverLogger.info(`[CrownEvaluator] ${c.agentName} diff preview: ${c.gitDiff.substring(0, 200)}...`);
    
    if (c.gitDiff === "No changes detected" || c.gitDiff.startsWith("ERROR:")) {
      serverLogger.error(`[CrownEvaluator] WARNING: ${c.agentName} has no valid git diff!`);
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

Analyze these implementations and select the best one based on:
1. Code quality and correctness
2. Completeness of the solution
3. Following best practices
4. Actually having changes (if one has no changes, prefer the one with changes)

Respond with a JSON object containing:
- "winner": the index (0-based) of the best implementation
- "reason": a brief explanation of why this implementation was chosen

Example response:
{"winner": 0, "reason": "Model claude/sonnet-4 provided a more complete implementation with better error handling and cleaner code structure."}

IMPORTANT: Respond ONLY with the JSON object, no other text.`;

  serverLogger.info(`[CrownEvaluator] Evaluation prompt length: ${evaluationPrompt.length} characters`);
  
  // Log prompt structure for debugging
  const promptLines = evaluationPrompt.split('\n');
  serverLogger.info(`[CrownEvaluator] Prompt has ${promptLines.length} lines`);
  serverLogger.info(`[CrownEvaluator] First 5 lines of prompt:`);
  promptLines.slice(0, 5).forEach((line, idx) => {
    serverLogger.info(`[CrownEvaluator]   ${idx}: ${line.substring(0, 100)}${line.length > 100 ? '...' : ''}`);
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
    
    // Pass the prompt as a command-line argument and use --print for non-interactive output
    const args = [
      "@anthropic-ai/claude-code",
      "--model", "claude-sonnet-4-20250514", 
      "--dangerously-skip-permissions",
      "--print",
      "--output-format", "text",
      evaluationPrompt
    ];
    
    serverLogger.info(`[CrownEvaluator] Command: bunx ${args.slice(0, -1).join(' ')} [prompt]`);
    
    const bunxProcess = spawn("bunx", args, {
      env: { ...process.env },
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false
    });

    serverLogger.info(`[CrownEvaluator] Process spawned with PID: ${bunxProcess.pid}`);
    
    // Don't write to stdin since we're passing prompt as argument
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
      serverLogger.info(`[CrownEvaluator] stdout (${chunk.length} chars): ${chunk.substring(0, 200)}`);
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
      serverLogger.info(`[CrownEvaluator] Process exited with code ${code} and signal ${signal}`);
      serverLogger.info(`[CrownEvaluator] Exit occurred after ${Date.now() - startTime}ms`);
    });
    
    bunxProcess.on("error", (error) => {
      serverLogger.error(`[CrownEvaluator] Process spawn error:`, error);
    });

    exitCode = await new Promise<number>((resolve, reject) => {
      let processExited = false;
      
      bunxProcess.on("close", (code) => {
        processExited = true;
        serverLogger.info(`[CrownEvaluator] Process closed with code: ${code}`);
        serverLogger.info(`[CrownEvaluator] Received stdout: ${receivedStdout}, Received stderr: ${receivedStderr}`);
        serverLogger.info(`[CrownEvaluator] Total stdout length: ${stdout.length}, stderr length: ${stderr.length}`);
        
        if (stderr.length > 0) {
          serverLogger.info(`[CrownEvaluator] Full stderr output:`);
          stderr.split('\n').forEach((line, idx) => {
            if (line.trim()) {
              serverLogger.info(`[CrownEvaluator]   stderr[${idx}]: ${line}`);
            }
          });
        }
        
        if (lastStderr.includes("Saved lockfile") && stdout.length === 0) {
          serverLogger.error(`[CrownEvaluator] Process failed after saving lockfile with no output`);
          serverLogger.error(`[CrownEvaluator] This suggests Claude Code started but failed to execute`);
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
          serverLogger.error(`[CrownEvaluator] Process timeout after 60 seconds, killing...`);
          bunxProcess.kill('SIGKILL');
          reject(new Error("Timeout"));
        }
      }, 60000); // Reduce timeout to 60 seconds
    });

    serverLogger.info(`[CrownEvaluator] bunx completed with exit code ${exitCode}`);
  } catch (bunxError) {
    serverLogger.error(`[CrownEvaluator] bunx failed:`, bunxError);
    
    // Fallback: Pick the first completed run as winner if Claude Code fails
    serverLogger.warn(`[CrownEvaluator] Falling back to selecting first completed run as winner`);
    
    const fallbackWinner = candidateData[0];
    await convex.mutation(api.crown.setCrownWinner, {
      taskRunId: fallbackWinner.runId,
      reason: "Selected as fallback winner (crown evaluation failed to run)",
    });
    
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: undefined,
    });
    
    serverLogger.info(`[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`);
    await createPullRequestForWinner(convex, fallbackWinner.runId, taskId, githubToken || undefined);
    return;
  }

  serverLogger.info(`[CrownEvaluator] Process completed after ${Date.now() - startTime}ms`);
  serverLogger.info(`[CrownEvaluator] Exit code: ${exitCode}`);
  serverLogger.info(`[CrownEvaluator] Stdout length: ${stdout.length}`);
  serverLogger.info(`[CrownEvaluator] Full stdout:\n${stdout}`);

  if (exitCode !== 0) {
    serverLogger.error(`[CrownEvaluator] Claude Code exited with error code ${exitCode}. Stderr: ${stderr}`);
    
    // Fallback: Pick the first completed run as winner if Claude Code fails
    serverLogger.warn(`[CrownEvaluator] Falling back to selecting first completed run as winner due to non-zero exit code`);
    
    const fallbackWinner = candidateData[0];
    await convex.mutation(api.crown.setCrownWinner, {
      taskRunId: fallbackWinner.runId,
      reason: "Selected as fallback winner (crown evaluation exited with error)",
    });
    
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: undefined,
    });
    
    serverLogger.info(`[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`);
    await createPullRequestForWinner(convex, fallbackWinner.runId, taskId, githubToken || undefined);
    return;
  }

  // Parse the response
  let jsonResponse: CrownEvaluationResponse;
  
  // Try to extract JSON from stdout - look for any JSON object with winner and reason
  const jsonMatch = stdout.match(/\{[^{}]*"winner"\s*:\s*\d+[^{}]*"reason"\s*:\s*"[^"]*"[^{}]*\}/) ||
                    stdout.match(/\{[^{}]*"reason"\s*:\s*"[^"]*"[^{}]*"winner"\s*:\s*\d+[^{}]*\}/);
  
  if (!jsonMatch) {
    serverLogger.error(`[CrownEvaluator] No JSON found in output. Full stdout:\n${stdout}`);
    
    // Try to find a complete JSON object anywhere in the output
    try {
      // Remove any non-JSON content before/after
      const possibleJson = stdout.substring(
        stdout.indexOf('{'), 
        stdout.lastIndexOf('}') + 1
      );
      const parsed = JSON.parse(possibleJson);
      jsonResponse = CrownEvaluationResponseSchema.parse(parsed);
      serverLogger.info(`[CrownEvaluator] Extracted JSON from output: ${JSON.stringify(jsonResponse)}`);
    } catch {
      // Last resort - try to find just a number
      const numberMatch = stdout.match(/\b([01])\b/);
      if (numberMatch) {
        const index = parseInt(numberMatch[1], 10);
        jsonResponse = {
          winner: index,
          reason: `Selected ${candidateData[index].agentName} based on implementation quality`
        };
        serverLogger.info(`[CrownEvaluator] Extracted winner index ${index} from output`);
      } else {
        serverLogger.error(`[CrownEvaluator] Could not extract valid response from output`);
        
        // Fallback: Pick the first completed run as winner
        const fallbackWinner = candidateData[0];
        await convex.mutation(api.crown.setCrownWinner, {
          taskRunId: fallbackWinner.runId,
          reason: "Selected as fallback winner (no valid response from evaluator)",
        });
        
        await convex.mutation(api.tasks.updateCrownError, {
          id: taskId,
          crownEvaluationError: undefined,
        });
        
        serverLogger.info(`[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`);
        await createPullRequestForWinner(convex, fallbackWinner.runId, taskId, githubToken || undefined);
        return;
      }
    }
  } else {
    try {
      const parsed = JSON.parse(jsonMatch[0]);
      jsonResponse = CrownEvaluationResponseSchema.parse(parsed);
      serverLogger.info(`[CrownEvaluator] Successfully parsed JSON response: ${JSON.stringify(jsonResponse)}`);
    } catch (parseError) {
      serverLogger.error(`[CrownEvaluator] Failed to parse JSON:`, parseError);
      
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
      
      serverLogger.info(`[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`);
      await createPullRequestForWinner(convex, fallbackWinner.runId, taskId, githubToken || undefined);
      return;
    }
  }

  // Validate winner index
  if (jsonResponse.winner >= candidateData.length) {
    serverLogger.error(`[CrownEvaluator] Invalid winner index ${jsonResponse.winner}, must be less than ${candidateData.length}`);
    
    // Fallback: Pick the first completed run as winner
    const fallbackWinner = candidateData[0];
    await convex.mutation(api.crown.setCrownWinner, {
      taskRunId: fallbackWinner.runId,
      reason: "Selected as fallback winner (invalid winner index from evaluator)",
    });
    
    await convex.mutation(api.tasks.updateCrownError, {
      id: taskId,
      crownEvaluationError: undefined,
    });
    
    serverLogger.info(`[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`);
    await createPullRequestForWinner(convex, fallbackWinner.runId, taskId, githubToken || undefined);
    return;
  }

  const winner = candidateData[jsonResponse.winner];
  serverLogger.info(`[CrownEvaluator] WINNER SELECTED: ${winner.agentName} (index ${jsonResponse.winner})`);
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

  serverLogger.info(`[CrownEvaluator] Crown evaluation completed successfully for task ${taskId}`);
  
  // Create pull request for the winner
  await createPullRequestForWinner(convex, winner.runId, taskId, githubToken || undefined);
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