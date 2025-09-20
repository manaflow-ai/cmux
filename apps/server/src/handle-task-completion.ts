import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { type AgentConfig } from "@cmux/shared/agentConfig";
import { captureGitDiff } from "./captureGitDiff.js";
import { createPullRequestForWinner, evaluateCrown } from "./crownEvaluator.js";
import performAutoCommitAndPush from "./performAutoCommitAndPush.js";
import { getConvex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken.js";
import type { VSCodeInstance } from "./vscode/VSCodeInstance.js";
import { retryOnOptimisticConcurrency } from "./utils/convexRetry.js";

// Handler for completing the task
export async function handleTaskCompletion({
  taskRunId,
  agent,
  exitCode = 0,
  worktreePath,
  vscodeInstance,
  teamSlugOrId,
}: {
  taskRunId: Id<"taskRuns">;
  agent: AgentConfig;
  exitCode: number;
  worktreePath: string;
  vscodeInstance: VSCodeInstance;
  teamSlugOrId: string;
}) {
  try {
    // Mark task as complete (retry on OCC)
    await retryOnOptimisticConcurrency(() =>
      getConvex().mutation(api.taskRuns.complete, {
        teamSlugOrId,
        id: taskRunId,
        exitCode,
      })
    );

    // Capture git diff before marking as complete
    serverLogger.info(
      `[AgentSpawner] ============================================`
    );
    serverLogger.info(`[AgentSpawner] CAPTURING GIT DIFF FOR ${agent.name}`);
    serverLogger.info(`[AgentSpawner] Task Run ID: ${taskRunId}`);
    serverLogger.info(`[AgentSpawner] Worktree Path: ${worktreePath}`);
    serverLogger.info(
      `[AgentSpawner] VSCode Instance Connected: ${vscodeInstance.isWorkerConnected()}`
    );
    serverLogger.info(
      `[AgentSpawner] ============================================`
    );

    // Collect the relevant diff via the shared worker script
    const gitDiff = await captureGitDiff(vscodeInstance, worktreePath);
    serverLogger.info(
      `[AgentSpawner] Captured git diff for ${agent.name}: ${gitDiff.length} chars`
    );
    serverLogger.info(
      `[AgentSpawner] First 100 chars of diff: ${gitDiff.substring(0, 100)}`
    );

    // Do not write diffs to Convex logs; crown and UI fetch diffs directly.
    if (!gitDiff || gitDiff.length === 0) {
      serverLogger.warn(
        `[AgentSpawner] No git diff captured for ${agent.name} (${taskRunId})`
      );
    }

    serverLogger.info(
      `[AgentSpawner] Updated taskRun ${taskRunId} as completed with exit code ${exitCode}`
    );

    // Check if all runs are complete and evaluate crown
    const taskRunData = await getConvex().query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    serverLogger.info(
      `[AgentSpawner] Task run data retrieved: ${taskRunData ? "found" : "not found"}`
    );

    if (taskRunData) {
      const task = await getConvex().query(api.tasks.getById, {
        teamSlugOrId,
        id: taskRunData.taskId,
      });

      if (!task) {
        serverLogger.error(
          `[AgentSpawner] Task ${taskRunData.taskId} not found for completion flow`
        );
        throw new Error(`Task ${taskRunData.taskId} not found`);
      }

      const autoCommitPromise: Promise<void> = (async () => {
        serverLogger.info(
          `[AgentSpawner] Performing auto-commit for ${agent.name}`
        );

        try {
          await performAutoCommitAndPush(
            vscodeInstance,
            agent,
            taskRunId,
            task.text,
            teamSlugOrId,
            gitDiff
          );
          serverLogger.info(
            `[AgentSpawner] Auto-commit completed successfully for ${agent.name}`
          );
        } catch (error) {
          serverLogger.error(
            `[AgentSpawner] Auto-commit failed for ${agent.name}:`,
            error
          );
        }
      })();

      const crownEvaluationPromise: Promise<void> = (async () => {
        serverLogger.info(
          `[AgentSpawner] Calling checkAndEvaluateCrown for task ${taskRunData.taskId}`
        );

        const winnerId = await getConvex().mutation(
          api.tasks.checkAndEvaluateCrown,
          {
            teamSlugOrId,
            taskId: taskRunData.taskId,
          }
        );

        serverLogger.info(
          `[AgentSpawner] checkAndEvaluateCrown returned: ${winnerId}`
        );

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

          serverLogger.info(
            `[AgentSpawner] Triggering immediate crown evaluation`
          );

          try {
            const latestTask = await getConvex().query(api.tasks.getById, {
              teamSlugOrId,
              id: taskRunData.taskId,
            });
            if (latestTask?.crownEvaluationError === "in_progress") {
              serverLogger.info(
                `[AgentSpawner] Crown evaluation already in progress for task ${taskRunData.taskId}`
              );
            } else {
              await autoCommitPromise.catch((error) => {
                serverLogger.warn(
                  `[AgentSpawner] Auto-commit did not complete before crown evaluation; proceeding with available repository state`,
                  {
                    error:
                      error instanceof Error ? error.message : String(error),
                  }
                );
              });
              await evaluateCrown({
                taskId: taskRunData.taskId,
                teamSlugOrId,
              });

              serverLogger.info(
                `[AgentSpawner] Crown evaluation completed successfully`
              );

              const updatedTaskRun = await getConvex().query(api.taskRuns.get, {
                teamSlugOrId,
                id: taskRunId,
              });

              if (updatedTaskRun?.isCrowned) {
                serverLogger.info(
                  `[AgentSpawner] 🏆 This task run won the crown! ${agent.name} is the winner!`
                );
              }
            }
          } catch (error) {
            serverLogger.error(
              `[AgentSpawner] Crown evaluation failed:`,
              error
            );
          }
        } else if (winnerId) {
          serverLogger.info(
            `[AgentSpawner] Task completed with winner: ${winnerId}`
          );

          const taskRuns = await getConvex().query(api.taskRuns.getByTask, {
            teamSlugOrId,
            taskId: taskRunData.taskId,
          });

          if (taskRuns.length === 1) {
            serverLogger.info(
              `[AgentSpawner] Single agent scenario - checking auto-PR settings`
            );

            const ws = await getConvex().query(api.workspaceSettings.get, {
              teamSlugOrId,
            });
            const autoPrEnabled = ws?.autoPrEnabled ?? false;

            if (autoPrEnabled) {
              serverLogger.info(
                `[AgentSpawner] Triggering auto-PR for single agent completion`
              );

              const githubToken = await getGitHubTokenFromKeychain();

              try {
                await createPullRequestForWinner(
                  winnerId,
                  taskRunData.taskId,
                  githubToken || undefined,
                  teamSlugOrId
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
      })();

      await Promise.all([autoCommitPromise, crownEvaluationPromise]);
    }

    // Schedule container stop based on settings
    const containerSettings = await getConvex().query(
      api.containerSettings.getEffective,
      { teamSlugOrId }
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

        await retryOnOptimisticConcurrency(() =>
          getConvex().mutation(api.taskRuns.updateScheduledStop, {
            teamSlugOrId,
            id: taskRunId,
            scheduledStopAt,
          })
        );

        serverLogger.info(
          `[AgentSpawner] Scheduled container stop for ${new Date(scheduledStopAt).toISOString()}`
        );
      }
    }
  } catch (error) {
    serverLogger.error(`[AgentSpawner] Error handling task completion:`, error);
  }
}
