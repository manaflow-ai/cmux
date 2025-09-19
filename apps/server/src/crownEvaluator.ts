import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { getConvex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken.js";
import { workerExec } from "./utils/workerExec.js";
import { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { getWwwClient } from "./utils/wwwClient.js";
import {
  postApiCrownEvaluate,
  postApiCrownSummarize,
} from "@cmux/www-openapi-client";
import { getAuthHeaderJson } from "./utils/requestContext.js";
import { getWwwBaseUrl } from "./utils/server-env.js";

const UNKNOWN_AGENT_NAME = "unknown agent";

function getAgentNameOrUnknown(agentName?: string | null): string {
  const trimmed = agentName?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : UNKNOWN_AGENT_NAME;
}

// Auto PR behavior is controlled via workspace settings in Convex
export async function createPullRequestForWinner(
  taskRunId: Id<"taskRuns">,
  taskId: Id<"tasks">,
  githubToken: string | null | undefined,
  teamSlugOrId: string
): Promise<void> {
  try {
    // Check workspace settings toggle (default: disabled)
    const ws = await getConvex().query(api.workspaceSettings.get, {
      teamSlugOrId,
    });
    const autoPrEnabled = !!ws?.autoPrEnabled;
    if (!autoPrEnabled) {
      serverLogger.info(
        `[CrownEvaluator] Auto-PR disabled in settings; skipping.`
      );
      return;
    }
    serverLogger.info(
      `[CrownEvaluator] Creating pull request for winner ${taskRunId}`
    );

    // Get the task run details
    const taskRun = await getConvex().query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });
    if (!taskRun || !taskRun.vscode?.containerName) {
      serverLogger.error(
        `[CrownEvaluator] No VSCode instance found for task run ${taskRunId}`
      );
      return;
    }

    // Get the task details
    const task = await getConvex().query(api.tasks.getById, {
      teamSlugOrId,
      id: taskId,
    });
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

    const agentName = getAgentNameOrUnknown(taskRun.agentName);

    // Create PR title and body using stored task title when available
    const prTitle =
      task.pullRequestTitle || task.text || "Task completed by cmux";
    // Persist PR title if not already set or differs
    if (!task.pullRequestTitle || task.pullRequestTitle !== prTitle) {
      try {
        await getConvex().mutation(api.tasks.setPullRequestTitle, {
          teamSlugOrId,
          id: taskId,
          pullRequestTitle: prTitle,
        });
      } catch (e) {
        serverLogger.error(`[CrownEvaluator] Failed to save PR title:`, e);
      }
    }
    const prBody = `## Summary
- Task completed by ${agentName} agent 🏆
- ${taskRun.crownReason || "Selected as the best implementation"}

## Details
- Task ID: ${taskId}
- Agent: ${agentName}
- Completed: ${new Date().toISOString()}`;

    // Persist PR description on the task in Convex
    try {
      await getConvex().mutation(api.tasks.setPullRequestDescription, {
        teamSlugOrId,
        id: taskId,
        pullRequestDescription: prBody,
      });
    } catch (e) {
      serverLogger.error(`[CrownEvaluator] Failed to save PR description:`, e);
    }

    // Use the newBranch from the task run
    const branchName = taskRun.newBranch || `cmux-crown-${taskRunId.slice(-8)}`;

    // Create commit message
    const truncatedDescription =
      prTitle.length > 72 ? prTitle.substring(0, 69) + "..." : prTitle;

    const commitMessage = `${truncatedDescription}

Task completed by ${agentName} agent 🏆
${taskRun.crownReason ? `\nReason: ${taskRun.crownReason}` : ""}

🤖 Generated with cmux
Agent: ${agentName}
Task Run ID: ${taskRunId}
Branch: ${branchName}
Completed: ${new Date().toISOString()}`;

    // Execute git operations via worker:exec only
    serverLogger.info(`[CrownEvaluator] Using worker:exec for git operations`);

    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.error(`[CrownEvaluator] No worker connection available`);
      return;
    }

    // Execute git commands via worker:exec (more reliable than terminal-input)
    const bodyFileName = `cmux_pr_body_${Date.now()}_${Math.random().toString(36).slice(2)}.md`;
    const gitCommands = [
      // Add all changes
      { cmd: "git add -A", desc: "Staging changes" },
      // Create and switch to new branch (fallback to switch if it exists)
      {
        cmd: `git checkout -b ${branchName} || git checkout ${branchName}`,
        desc: "Ensuring branch",
      },
      // Commit (tolerate no-op)
      {
        cmd: `git commit -m "${commitMessage.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$")}" || echo 'No changes to commit'`,
        desc: "Committing",
      },
      // Push
      { cmd: `git push -u origin ${branchName}`, desc: "Pushing branch" },
    ];

    // Only add PR creation command if GitHub token is available
    if (githubToken) {
      gitCommands.push({
        cmd: `cat <<'CMUX_EOF' > /tmp/${bodyFileName}\n${prBody}\nCMUX_EOF`,
        desc: "Writing PR body",
      });
      gitCommands.push({
        cmd: `GH_TOKEN="${githubToken}" gh pr create --title "${prTitle.replace(/"/g, '\\"')}" --body-file /tmp/${bodyFileName} --head "${branchName}"`,
        desc: "Creating PR",
      });
      gitCommands.push({
        cmd: `rm -f /tmp/${bodyFileName}`,
        desc: "Cleaning up PR body",
      });
    } else {
      serverLogger.info(
        `[CrownEvaluator] Skipping PR creation - no GitHub token configured`
      );
      serverLogger.info(
        `[CrownEvaluator] Branch '${branchName}' has been pushed. You can manually create a PR from GitHub.`
      );
    }

    for (const { cmd, desc } of gitCommands) {
      serverLogger.info(`[CrownEvaluator] ${desc}...`);

      const result = await new Promise<{
        success: boolean;
        error?: string;
        stdout?: string;
        stderr?: string;
      }>((resolve) => {
        workerSocket.timeout(30000).emit(
          "worker:exec",
          {
            command: "/bin/bash",
            args: ["-c", cmd],
            cwd: "/root/workspace",
            env: githubToken ? { GH_TOKEN: githubToken } : {},
          },
          (timeoutError, result) => {
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
        serverLogger.error(
          `[CrownEvaluator] Failed at step: ${desc}`,
          result.error
        );

        // If gh pr create fails, log more details
        if (cmd.includes("gh pr create")) {
          serverLogger.error(
            `[CrownEvaluator] PR creation failed. stdout: ${result.stdout}, stderr: ${result.stderr}`
          );

          // Try to check gh auth status
          const authCheckResult = await new Promise<{
            success: boolean;
            stdout?: string;
            stderr?: string;
          }>((resolve) => {
            workerSocket.timeout(10000).emit(
              "worker:exec",
              {
                command: "/bin/bash",
                args: [
                  "-c",
                  githubToken
                    ? `GH_TOKEN="${githubToken}" gh auth status`
                    : "gh auth status",
                ],
                cwd: "/root/workspace",
                env: githubToken ? { GH_TOKEN: githubToken } : {},
              },
              (timeoutError, authResult) => {
                if (timeoutError || authResult.error) {
                  resolve({
                    success: false,
                    stdout: "",
                    stderr: timeoutError
                      ? "timeout"
                      : authResult.error?.message,
                  });
                  return;
                }
                const { stdout, stderr, exitCode } = authResult.data;
                resolve({ success: exitCode === 0, stdout, stderr });
              }
            );
          });

          serverLogger.error(
            `[CrownEvaluator] gh auth status - stdout: ${authCheckResult.stdout}, stderr: ${authCheckResult.stderr}`
          );
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

type EvaluateCrownOptions = {
  taskId: Id<"tasks">;
  teamSlugOrId: string;
  crownRunId: Id<"taskRuns">;
  precollectedDiff: string;
};

export async function evaluateCrown({
  taskId,
  teamSlugOrId,
  crownRunId,
  precollectedDiff,
}: EvaluateCrownOptions): Promise<void> {
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
    // Atomically acquire crown evaluation lock to avoid duplicate runs
    try {
      const acquired = await getConvex().mutation(
        api.tasks.tryBeginCrownEvaluation,
        { teamSlugOrId, id: taskId }
      );
      if (!acquired) {
        serverLogger.info(
          `[CrownEvaluator] Another evaluation is already in progress; skipping.`
        );
        return;
      }
    } catch (lockErr) {
      serverLogger.error(
        `[CrownEvaluator] Failed to acquire evaluation lock:`,
        lockErr
      );
      // Best-effort continue; downstream guards will prevent duplicate effects
    }

    const githubToken = await getGitHubTokenFromKeychain();

    // Helper: generate and persist a system task comment summarizing the winner
    const generateSystemTaskComment = async (
      winnerRunId: Id<"taskRuns">,
      fallbackGitDiff: string
    ) => {
      try {
        // Skip if a system comment already exists for this task
        const existing = await getConvex().query(
          api.taskComments.latestSystemByTask,
          { teamSlugOrId, taskId }
        );
        if (existing) {
          serverLogger.info(
            `[CrownEvaluator] System task comment already exists; skipping generation.`
          );
          return;
        }

        // Try to collect worker diff for the winner; fall back to provided diff
        let effectiveDiff = fallbackGitDiff || "";
        const instances = VSCodeInstance.getInstances();
        let instance: VSCodeInstance | undefined;
        for (const [, inst] of instances) {
          if (inst.getTaskRunId() === winnerRunId) {
            instance = inst;
            break;
          }
        }
        if (instance && instance.isWorkerConnected()) {
          try {
            const workerSocket = instance.getWorkerSocket();
            const { stdout } = await workerExec({
              workerSocket,
              command: "/bin/bash",
              args: ["-c", "/usr/local/bin/cmux-collect-relevant-diff.sh"],
              cwd: "/root/workspace",
              env: {},
              timeout: 30000,
            });
            const diff = (stdout || "").trim();
            if (diff.length > 0) effectiveDiff = diff;
          } catch (e) {
            serverLogger.error(
              `[CrownEvaluator] Failed to collect diff for task comment:`,
              e
            );
          }
        }

        // Pull original request text for context
        const task = await getConvex().query(api.tasks.getById, {
          teamSlugOrId,
          id: taskId,
        });
        const originalRequest = task?.text || "";

        // Summarization prompt
        const summarizationPrompt = `You are an expert reviewer summarizing a pull request.\n\nGOAL\n- Explain succinctly what changed and why.\n- Call out areas the user should review carefully.\n- Provide a quick test plan to validate the changes.\n\nCONTEXT\n- User's original request:\n${originalRequest}\n- Relevant diffs (unified):\n${effectiveDiff || "<no code changes captured>"}\n\nINSTRUCTIONS\n- Base your summary strictly on the provided diffs and request.\n- Be specific about files and functions when possible.\n- Prefer clear bullet points over prose. Keep it under ~300 words.\n- If there are no code changes, say so explicitly and suggest next steps.\n\nOUTPUT FORMAT (Markdown)\n## PR Review Summary\n- What Changed: bullet list\n- Review Focus: bullet list (risks/edge cases)\n- Test Plan: bullet list of practical steps\n- Follow-ups: optional bullets if applicable\n`;

        serverLogger.info(
          `[CrownEvaluator] Generating PR summary via Anthropic (AI SDK)...`
        );

        let commentText = "";
        try {
          // Try to use worker for crown summarization if available
          const instances = VSCodeInstance.getInstances();
          let workerSummarized = false;

          for (const [, inst] of instances) {
            if (inst.getTaskRunId() === winnerRunId && inst.isWorkerConnected()) {
              const workerSocket = inst.getWorkerSocket();
              if (workerSocket) {
                try {
                  const authHeaderJson = getAuthHeaderJson();
                  const wwwBaseUrl = getWwwBaseUrl();

                  const result = await new Promise<{ success: boolean; summary?: string }>(
                    (resolve) => {
                      workerSocket.timeout(30000).emit(
                        "worker:crownSummarize" as any,
                        {
                          prompt: summarizationPrompt,
                          teamSlugOrId,
                          authToken: authHeaderJson || "",
                          wwwBaseUrl,
                        },
                        (timeoutError: any, response: any) => {
                          if (timeoutError || !response?.summary) {
                            resolve({ success: false });
                          } else {
                            resolve({ success: true, summary: response.summary });
                          }
                        }
                      );
                    }
                  );

                  if (result.success && result.summary) {
                    commentText = result.summary;
                    workerSummarized = true;
                    serverLogger.info(
                      `[CrownEvaluator] PR summary generated via worker`
                    );
                  }
                } catch (e) {
                  serverLogger.warn(
                    `[CrownEvaluator] Worker summarization failed, falling back to server:`,
                    e
                  );
                }
              }
              break;
            }
          }

          // Fallback to server-side API call if worker didn't succeed
          if (!workerSummarized) {
            const res = await postApiCrownSummarize({
              client: getWwwClient(),
              body: {
                prompt: summarizationPrompt,
                teamSlugOrId,
              },
            });

            if (!res.data) {
              serverLogger.error(`[CrownEvaluator] Crown summarize failed`);
              return;
            }
            commentText = res.data.summary;
            serverLogger.info(
              `[CrownEvaluator] PR summary generated via server`
            );
          }
        } catch (e) {
          serverLogger.error(
            `[CrownEvaluator] Failed to generate PR summary:`,
            e
          );
        }

        if (commentText.length > 8000) {
          commentText = commentText.slice(0, 8000) + "\n\n… (truncated)";
        }

        await getConvex().mutation(api.taskComments.createSystemForTask, {
          teamSlugOrId,
          taskId,
          content: commentText,
        });

        serverLogger.info(
          `[CrownEvaluator] Saved system task comment for task ${taskId}`
        );
      } catch (e) {
        serverLogger.error(
          `[CrownEvaluator] Failed to create system task comment:`,
          e
        );
      }
    };

    // Get task and runs
    const task = await getConvex().query(api.tasks.getById, {
      teamSlugOrId,
      id: taskId,
    });
    if (!task) {
      throw new Error("Task not found");
    }

    const taskRuns = await getConvex().query(api.taskRuns.getByTask, {
      teamSlugOrId,
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
    const existingEvaluation = await getConvex().query(
      api.crown.getCrownEvaluation,
      {
        teamSlugOrId,
        taskId,
      }
    );

    if (existingEvaluation) {
      serverLogger.info(
        `[CrownEvaluator] Crown evaluation already exists for task ${taskId}, skipping`
      );
      // Clear the pending status
      await getConvex().mutation(api.tasks.updateCrownError, {
        teamSlugOrId,
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
            `[CrownEvaluator] No live worker for run ${runId}; unable to collect diff`
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
            `[CrownEvaluator] Worker diff empty for run ${runId}`
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
        const agentName = getAgentNameOrUnknown(run.agentName);
        // Try to collect diff via worker
        const precollected =
          crownRunId && run._id === crownRunId
            ? (precollectedDiff?.trim() ?? "")
            : "";
        const workerDiff: string | null = precollected
          ? precollected
          : await collectDiffViaWorker(run._id);
        let gitDiff: string =
          workerDiff && workerDiff.length > 0
            ? workerDiff
            : "No changes detected";

        // Limit to 5000 chars for the prompt
        if (gitDiff.length > 5000) {
          gitDiff = gitDiff.substring(0, 5000) + "\n... (truncated)";
        }

        serverLogger.info(
          `[CrownEvaluator] Implementation ${idx} (${agentName}): ${gitDiff.length} chars of diff`
        );

        // Do not rely on logs; skip logging log tails.

        return {
          index: idx,
          runId: run._id,
          agentName,
          exitCode: run.exitCode || 0,
          gitDiff,
        };
      })
    );

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

    // Status already set by tryBeginCrownEvaluation; keep for compatibility if not set
    try {
      await getConvex().mutation(api.tasks.updateCrownError, {
        teamSlugOrId,
        id: taskId,
        crownEvaluationError: "in_progress",
      });
    } catch {
      /* empty */
    }

    let jsonResponse: { winner: number; reason: string } | undefined;

    // Try to use worker for crown evaluation if available
    const instances = VSCodeInstance.getInstances();
    let workerEvaluated = false;

    for (const [, inst] of instances) {
      // Use any available worker connection for the evaluation
      if (inst.isWorkerConnected()) {
        const workerSocket = inst.getWorkerSocket();
        if (workerSocket) {
          try {
            const authHeaderJson = getAuthHeaderJson();
            const wwwBaseUrl = getWwwBaseUrl();

            const result = await new Promise<{ success: boolean; data?: { winner: number; reason: string } }>(
              (resolve) => {
                workerSocket.timeout(60000).emit(
                  "worker:crownEvaluate" as any,
                  {
                    prompt: evaluationPrompt,
                    teamSlugOrId,
                    authToken: authHeaderJson || "",
                    wwwBaseUrl,
                  },
                  (timeoutError: any, response: any) => {
                    if (timeoutError || !response?.data) {
                      resolve({ success: false });
                    } else {
                      resolve({ success: true, data: response.data });
                    }
                  }
                );
              }
            );

            if (result.success && result.data) {
              jsonResponse = result.data;
              workerEvaluated = true;
              serverLogger.info(
                `[CrownEvaluator] Crown evaluation completed via worker`
              );
            }
          } catch (e) {
            serverLogger.warn(
              `[CrownEvaluator] Worker evaluation failed, falling back to server:`,
              e
            );
          }
        }
        break; // Use first available worker
      }
    }

    // Fallback to server-side API call if worker didn't succeed
    if (!workerEvaluated) {
      const res = await postApiCrownEvaluate({
        client: getWwwClient(),
        body: {
          prompt: evaluationPrompt,
          teamSlugOrId,
        },
      });

      if (!res.data) {
        serverLogger.error(`[CrownEvaluator] Crown evaluate failed`);
      } else {
        jsonResponse = res.data;
        serverLogger.info(
          `[CrownEvaluator] Crown evaluation completed via server`
        );
      }
    }

    if (!jsonResponse) {
      // Fallback: Pick the first completed run as winner
      const fallbackWinner = candidateData[0];
      await getConvex().mutation(api.crown.setCrownWinner, {
        teamSlugOrId,
        taskRunId: fallbackWinner.runId,
        reason: "Selected as fallback winner (evaluation failed)",
      });

      await getConvex().mutation(api.tasks.updateCrownError, {
        teamSlugOrId,
        id: taskId,
        crownEvaluationError: undefined,
      });

      serverLogger.info(
        `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
      );
      await generateSystemTaskComment(
        fallbackWinner.runId,
        fallbackWinner.gitDiff
      );
      await createPullRequestForWinner(
        fallbackWinner.runId,
        taskId,
        githubToken || undefined,
        teamSlugOrId
      );
      return;
    }

    // Validate winner index
    if (jsonResponse.winner >= candidateData.length) {
      serverLogger.error(
        `[CrownEvaluator] Invalid winner index ${jsonResponse.winner}, must be less than ${candidateData.length}`
      );

      // Fallback: Pick the first completed run as winner
      const fallbackWinner = candidateData[0];
      await getConvex().mutation(api.crown.setCrownWinner, {
        teamSlugOrId,
        taskRunId: fallbackWinner.runId,
        reason:
          "Selected as fallback winner (invalid winner index from evaluator)",
      });

      await getConvex().mutation(api.tasks.updateCrownError, {
        teamSlugOrId,
        id: taskId,
        crownEvaluationError: undefined,
      });

      serverLogger.info(
        `[CrownEvaluator] Fallback winner selected: ${fallbackWinner.agentName}`
      );
      await generateSystemTaskComment(
        fallbackWinner.runId,
        fallbackWinner.gitDiff
      );
      await createPullRequestForWinner(
        fallbackWinner.runId,
        taskId,
        githubToken || undefined,
        teamSlugOrId
      );
      return;
    }

    const winner = candidateData[jsonResponse.winner];
    serverLogger.info(
      `[CrownEvaluator] WINNER SELECTED: ${winner.agentName} (index ${jsonResponse.winner})`
    );
    serverLogger.info(`[CrownEvaluator] Reason: ${jsonResponse.reason}`);

    // Update the database
    await getConvex().mutation(api.crown.setCrownWinner, {
      teamSlugOrId,
      taskRunId: winner.runId,
      reason: jsonResponse.reason,
    });

    // Clear any error
    await getConvex().mutation(api.tasks.updateCrownError, {
      teamSlugOrId,
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
      githubToken || undefined,
      teamSlugOrId
    );
    // After choosing a winner, generate and persist a task comment (by cmux)
    await generateSystemTaskComment(winner.runId, winner.gitDiff);
  } catch (error) {
    serverLogger.error(`[CrownEvaluator] Error during evaluation:`, error);

    // Update task with error status
    await getConvex().mutation(api.tasks.updateCrownError, {
      teamSlugOrId,
      id: taskId,
      crownEvaluationError: `Failed: ${error instanceof Error ? error.message : String(error)}`,
    });

    throw error;
  }
}
