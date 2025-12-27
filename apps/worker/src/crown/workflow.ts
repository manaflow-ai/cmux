import { existsSync } from "node:fs";
import { join } from "node:path";

import type { Id } from "@cmux/convex/dataModel";

import { log } from "../logger";
import { convexRequest } from "./convex";
import {
  autoCommitAndPush,
  buildCommitMessage,
  collectDiffForRun,
  detectGitRepoPath,
  ensureBranchesAvailable,
  getCurrentBranch,
  runGitCommand,
} from "./git";
import { createPullRequest } from "./pullRequest";
import {
  type CandidateData,
  type CrownEvaluationResponse,
  type CrownSummarizationResponse,
  type CrownWorkerCheckResponse,
  type WorkerAllRunsCompleteResponse,
  type WorkerRunContext,
  type WorkerTaskRunResponse,
} from "./types";
import { WORKSPACE_ROOT } from "./utils";
import { runTaskScreenshots } from "../screenshotCollector/runTaskScreenshots";
import type { RunTaskScreenshotsOptions } from "../screenshotCollector/runTaskScreenshots";

async function uploadScreenshotsWithLogging(
  options: RunTaskScreenshotsOptions | null,
  taskRunId: string
): Promise<void> {
  if (!options) {
    log("WARN", "Skipping screenshot workflow due to missing task id", {
      taskRunId,
    });
    return;
  }

  try {
    await runTaskScreenshots(options);
  } catch (screenshotError) {
    log("ERROR", "Automated screenshot workflow encountered an error", {
      taskRunId,
      error:
        screenshotError instanceof Error
          ? screenshotError.message
          : String(screenshotError),
    });
  }
}

type WorkerCompletionOptions = {
  taskRunId: string;
  token: string;
  prompt: string;
  convexUrl?: string;
  agentModel?: string;
  teamId?: string;
  taskId?: string;
  elapsedMs?: number;
  exitCode?: number;
};

export async function handleWorkerTaskCompletion(
  options: WorkerCompletionOptions
): Promise<void> {
  const {
    taskRunId,
    token,
    prompt,
    convexUrl,
    agentModel,
    teamId,
    taskId,
    elapsedMs,
    exitCode = 0,
  } = options;

  if (!token) {
    log("ERROR", "Missing worker token for task run completion", { taskRunId });
    return;
  }

  const detectedGitPath = await detectGitRepoPath();

  log("INFO", "Worker task completion handler started", {
    taskRunId,
    workspacePath: WORKSPACE_ROOT,
    gitRepoPath: detectedGitPath,
    envWorkspacePath: process.env.CMUX_WORKSPACE_PATH,
    agentModel,
    elapsedMs,
    exitCode,
    convexUrl,
  });

  const runContext: WorkerRunContext = {
    token,
    prompt,
    agentModel,
    teamId,
    taskId,
    convexUrl,
  };

  const baseUrlOverride = runContext.convexUrl;

  const info = await convexRequest<WorkerTaskRunResponse>(
    "/api/crown/check",
    runContext.token,
    {
      taskRunId,
      checkType: "info",
    },
    baseUrlOverride
  );

  if (!info) {
    log(
      "ERROR",
      "Failed to load task run info - endpoint not found or network error",
      {
        taskRunId,
        info,
        convexUrl: baseUrlOverride,
      }
    );
    return;
  } else if (!info.ok || !info.taskRun) {
    log("ERROR", "Task run info response invalid", {
      taskRunId,
      response: info,
      hasOk: info?.ok,
      hasTaskRun: info?.taskRun,
    });
    return;
  }

  const taskRunInfo = info.taskRun;

  void uploadScreenshotsWithLogging(
    {
      taskId: info.taskRun.taskId as Id<"tasks">,
      taskRunId: taskRunId as Id<"taskRuns">,
      token: runContext.token,
      convexUrl: runContext.convexUrl,
    },
    taskRunId
  );

  const hasGitRepo = existsSync(join(detectedGitPath, ".git"));

  log("INFO", "[AUTOCOMMIT] Git operations check", {
    taskRunId,
    hasGitRepo,
    workspaceRoot: WORKSPACE_ROOT,
    gitDirPath: join(detectedGitPath, ".git"),
  });

  if (!hasGitRepo) {
    log("ERROR", "[AUTOCOMMIT] No git repository found, cannot autocommit", {
      taskRunId,
      detectedGitPath,
    });
  } else {
    const promptForCommit = info.task?.text ?? runContext.prompt ?? "cmux task";

    const commitMessage = buildCommitMessage({
      prompt: promptForCommit,
      agentName: agentModel ?? runContext.agentModel ?? "cmux-agent",
    });

    // Branch should already be created by startup commands
    let branchForCommit = taskRunInfo.newBranch;
    if (!branchForCommit) {
      // Fallback to current branch if newBranch not available
      branchForCommit = await getCurrentBranch();
      log("INFO", "[AUTOCOMMIT] Using current branch as newBranch not set", {
        taskRunId,
        currentBranch: branchForCommit,
      });
    } else {
      // Verify we're on the expected branch
      const currentBranch = await getCurrentBranch();
      if (currentBranch !== branchForCommit) {
        log(
          "WARN",
          "[AUTOCOMMIT] Current branch differs from expected branch",
          {
            taskRunId,
            expectedBranch: branchForCommit,
            currentBranch,
          }
        );
        // Try to checkout to the expected branch
        const checkoutResult = await runGitCommand(
          `git checkout ${branchForCommit}`,
          true
        );
        if (checkoutResult && checkoutResult.exitCode === 0) {
          log("INFO", "[AUTOCOMMIT] Checked out to expected branch", {
            taskRunId,
            branch: branchForCommit,
          });
        } else {
          log(
            "WARN",
            "[AUTOCOMMIT] Failed to checkout to expected branch, will use current branch",
            {
              taskRunId,
              expectedBranch: branchForCommit,
              currentBranch,
              error: checkoutResult?.stderr,
            }
          );
          branchForCommit = currentBranch;
        }
      }
    }

    log("INFO", "[AUTOCOMMIT] Preparing to autocommit and push", {
      taskRunId,
      branchForCommit,
      projectFullName: info?.task?.projectFullName,
      hasInfo: Boolean(info),
      hasTask: Boolean(info?.task),
      hasTaskRun: Boolean(taskRunInfo),
      taskRunNewBranch: taskRunInfo.newBranch,
    });

    if (!branchForCommit) {
      log("ERROR", "[AUTOCOMMIT] Unable to resolve branch name", {
        taskRunId,
        taskRunNewBranch: taskRunInfo.newBranch,
      });
    } else {
      const remoteUrl = info?.task?.projectFullName
        ? `https://github.com/${info.task.projectFullName}.git`
        : undefined;

      log("INFO", "[AUTOCOMMIT] Starting autoCommitAndPush", {
        taskRunId,
        branchForCommit,
        remoteUrl: remoteUrl || "using existing remote",
        commitMessage,
        hasGitRepo,
        gitRepoPath: detectedGitPath,
      });

      try {
        await autoCommitAndPush({
          branchName: branchForCommit,
          commitMessage,
          remoteUrl,
        });
        log("INFO", "[AUTOCOMMIT] autoCommitAndPush completed successfully", {
          taskRunId,
          branch: branchForCommit,
        });
      } catch (error) {
        log("ERROR", "[AUTOCOMMIT] Worker auto-commit failed", {
          taskRunId,
          branch: branchForCommit,
          error,
          errorMessage: error instanceof Error ? error.message : String(error),
          errorStack: error instanceof Error ? error.stack : undefined,
        });
      }
    }
  }

  const completion = await convexRequest<WorkerTaskRunResponse>(
    "/api/crown/complete",
    runContext.token,
    {
      taskRunId,
      exitCode,
    },
    baseUrlOverride
  );

  if (!completion?.ok) {
    log("ERROR", "Worker completion request failed", { taskRunId });
    return;
  }

  log("INFO", "Worker marked as complete, preparing for crown check", {
    taskRunId,
    taskId: runContext.taskId,
  });

  const completedRunInfo = completion.taskRun ?? taskRunInfo;
  const realTaskId = completedRunInfo?.taskId;

  if (!realTaskId) {
    log("ERROR", "Missing real task ID from task run after worker completion", {
      taskRunId,
      hasCompletedRunInfo: Boolean(completedRunInfo),
      hasInfoTaskRun: Boolean(taskRunInfo),
    });
    return;
  }

  runContext.taskId = realTaskId;
  runContext.teamId = completedRunInfo.teamId ?? runContext.teamId;

  await startCrownEvaluation({
    taskRunId,
    currentTaskId: realTaskId,
    runContext,
    baseUrlOverride,
    agentModel,
    elapsedMs,
  });
}

async function startCrownEvaluation({
  taskRunId,
  currentTaskId,
  runContext,
  baseUrlOverride,
  agentModel,
  elapsedMs,
}: {
  taskRunId: string;
  currentTaskId: string;
  runContext: WorkerRunContext;
  baseUrlOverride?: string;
  agentModel?: string;
  elapsedMs?: number;
}): Promise<void> {
  log("INFO", "Starting crown evaluation attempt", {
    taskRunId,
    taskId: currentTaskId,
  });

  let allComplete = false;
  let completionState: WorkerAllRunsCompleteResponse | null = null;

  completionState = await convexRequest<WorkerAllRunsCompleteResponse>(
    "/api/crown/check",
    runContext.token,
    {
      taskId: currentTaskId,
      checkType: "all-complete",
    },
    baseUrlOverride
  );

  if (!completionState?.ok) {
    log("ERROR", "Failed to verify task run completion state", {
      taskRunId,
      taskId: currentTaskId,
    });
    return;
  }

  log("INFO", "Task completion state check", {
    taskRunId,
    taskId: currentTaskId,
    allComplete: completionState.allComplete,
    totalStatuses: completionState.statuses.length,
    completedCount: completionState.statuses.filter(
      (status) => status.status === "completed"
    ).length,
  });

  if (completionState.allComplete) {
    allComplete = true;
  }

  if (!allComplete || !completionState) {
    log(
      "INFO",
      "Task runs still pending after retries; deferring crown evaluation",
      {
        taskRunId,
        taskId: currentTaskId,
        statuses: completionState?.statuses || [],
      }
    );
    return;
  }

  log("INFO", "All task runs complete; checking if evaluation needed", {
    taskRunId,
    taskId: currentTaskId,
  });

  const crownData = await convexRequest<CrownWorkerCheckResponse>(
    "/api/crown/check",
    runContext.token,
    {
      taskId: currentTaskId,
    },
    baseUrlOverride
  );

  if (!crownData?.ok) {
    log("ERROR", "Crown check request failed or returned not ok", {
      taskRunId,
      taskId: currentTaskId,
      hasResponse: Boolean(crownData),
      okValue: crownData?.ok,
    });
    return;
  }

  if (!crownData.task) {
    log("ERROR", "Missing task in crown check response", {
      taskRunId,
      taskId: currentTaskId,
    });
    return;
  }

  if (crownData.existingEvaluation) {
    log(
      "INFO",
      "Crown evaluation already exists (another worker completed it)",
      {
        taskRunId,
        winnerRunId: crownData.existingEvaluation.winnerRunId,
        evaluatedAt: new Date(
          crownData.existingEvaluation.evaluatedAt
        ).toISOString(),
      }
    );
    return;
  }

  if (!crownData.shouldEvaluate && !crownData.singleRunWinnerId) {
    log("INFO", "Evaluation not needed at this time", {
      taskRunId,
      taskId: currentTaskId,
    });
    return;
  }

  const completedRuns = crownData.runs.filter(
    (run) => run.status === "completed"
  );
  const totalRuns = crownData.runs.length;
  const allRunsCompleted = totalRuns > 0 && completedRuns.length === totalRuns;

  log("INFO", "Crown readiness status", {
    taskRunId,
    taskId: currentTaskId,
    totalRuns,
    completedRuns: completedRuns.length,
    allRunsCompleted,
  });

  if (!allRunsCompleted) {
    log("INFO", "Not all task runs completed; deferring crown evaluation", {
      taskRunId,
      taskId: currentTaskId,
      runStatuses: crownData.runs.map((run) => ({
        id: run.id,
        status: run.status,
      })),
    });
    return;
  }

  const baseBranch = crownData.task.baseBranch ?? "main";

  if (crownData.singleRunWinnerId) {
    if (crownData.singleRunWinnerId !== taskRunId) {
      log("INFO", "Single-run winner already handled by another run", {
        taskRunId,
        winnerRunId: crownData.singleRunWinnerId,
      });
      return;
    }

    const singleRun = crownData.runs.find((run) => run.id === taskRunId);
    if (!singleRun) {
      log("ERROR", "Single-run entry missing during crown", { taskRunId });
      return;
    }

    const gitDiff = await collectDiffForRun(baseBranch, singleRun.newBranch);

    log("INFO", "Built crown candidate", {
      runId: singleRun.id,
      branch: singleRun.newBranch,
    });

    const candidate: CandidateData = {
      runId: singleRun.id,
      agentName: singleRun.agentName ?? "unknown agent",
      gitDiff,
      newBranch: singleRun.newBranch,
    };

    const branchesReady = await ensureBranchesAvailable(
      [{ id: candidate.runId, newBranch: candidate.newBranch }],
      baseBranch
    );
    if (!branchesReady) {
      log("WARN", "Branches not ready for single-run crown; aborting crown evaluation", {
        taskRunId,
        elapsedMs,
        baseBranch,
        candidateBranch: candidate.newBranch,
      });
      return;
    }

    log("INFO", "Single run detected, skipping evaluation", {
      taskRunId,
      runId: candidate.runId,
      agentName: candidate.agentName,
    });

    const summarizationResponse =
      await convexRequest<CrownSummarizationResponse>(
        "/api/crown/summarize",
        runContext.token,
        {
          prompt: crownData.task?.text || "Task description not available",
          gitDiff: candidate.gitDiff,
          teamSlugOrId: runContext.teamId,
        },
        baseUrlOverride
      );

    const summary = summarizationResponse?.summary
      ? summarizationResponse.summary.slice(0, 8000)
      : undefined;

    log("INFO", "Single-run summarization response", {
      taskRunId,
      summaryPreview: summary?.slice(0, 120),
    });

    await convexRequest(
      "/api/crown/finalize",
      runContext.token,
      {
        taskId: crownData.taskId,
        winnerRunId: candidate.runId,
        reason: "Single run automatically selected (no competition)",
        evaluationPrompt: "Single run - no evaluation needed",
        evaluationResponse: JSON.stringify({
          winner: 0,
          reason: "Single run - no competition",
        }),
        candidateRunIds: [candidate.runId],
        summary,
      },
      baseUrlOverride
    );

    log("INFO", "Crowned task with single-run winner", {
      taskId: crownData.taskId,
      winnerRunId: candidate.runId,
      agentModel: agentModel ?? runContext.agentModel,
      elapsedMs,
    });
    return;
  }

  const completedRunsWithDiff = await Promise.all(
    completedRuns.map(async (run) => {
      const gitDiff = await collectDiffForRun(baseBranch, run.newBranch);
      log("INFO", "Built crown candidate", {
        runId: run.id,
        branch: run.newBranch,
      });
      return {
        runId: run.id,
        agentName: run.agentName ?? "unknown agent",
        gitDiff,
        newBranch: run.newBranch,
      } satisfies CandidateData;
    })
  );

  const candidates = completedRunsWithDiff.filter(
    (candidate): candidate is CandidateData => Boolean(candidate)
  );

  if (candidates.length === 0) {
    log("ERROR", "No candidates available for crown evaluation", {
      taskRunId,
    });
    return;
  }

  if (!runContext.teamId) {
    log("ERROR", "Missing teamId for crown evaluation", { taskRunId });
    return;
  }

  if (!crownData.task?.text) {
    log("ERROR", "Missing task text for crown evaluation", {
      taskRunId,
      hasTask: !!crownData.task,
      hasText: !!crownData.task?.text,
    });
    return;
  }

  const promptText = crownData.task.text;

  log("INFO", "Preparing crown evaluation request", {
    taskRunId,
    hasPrompt: true,
    promptPreview: promptText.slice(0, 100),
    candidatesCount: candidates.length,
    teamId: runContext.teamId,
  });

  const evaluationResponse = await convexRequest<CrownEvaluationResponse>(
    "/api/crown/evaluate-agents",
    runContext.token,
    {
      prompt: promptText,
      candidates,
      teamSlugOrId: runContext.teamId,
    },
    baseUrlOverride
  );

  if (!evaluationResponse) {
    log("ERROR", "Crown evaluation response missing", {
      taskRunId,
    });
    return;
  }

  log("INFO", "Crown evaluation response", {
    taskRunId,
    winner: evaluationResponse.winner,
    reason: evaluationResponse.reason,
  });

  const winnerIndex =
    typeof evaluationResponse.winner === "number"
      ? evaluationResponse.winner
      : 0;
  const winnerCandidate = candidates[winnerIndex] ?? candidates[0];
  if (!winnerCandidate) {
    log("ERROR", "Unable to determine crown winner", {
      taskRunId,
      winnerIndex,
    });
    return;
  }

  const summaryResponse = await convexRequest<CrownSummarizationResponse>(
    "/api/crown/summarize",
    runContext.token,
    {
      prompt: promptText,
      gitDiff: winnerCandidate.gitDiff,
      teamSlugOrId: runContext.teamId,
    },
    baseUrlOverride
  );

  log("INFO", "Crown summarization response", {
    taskRunId,
    summaryPreview: summaryResponse?.summary?.slice(0, 120),
  });

  const summary = summaryResponse?.summary
    ? summaryResponse.summary.slice(0, 8000)
    : undefined;

  const prMetadata = await createPullRequest({
    check: crownData,
    winner: winnerCandidate,
    summary,
    context: runContext,
  });

  const reason =
    evaluationResponse.reason || `Selected ${winnerCandidate.agentName}`;

  await convexRequest(
    "/api/crown/finalize",
    runContext.token,
    {
      taskId: crownData.taskId,
      winnerRunId: winnerCandidate.runId,
      reason,
      evaluationPrompt: `Task: ${promptText}\nCandidates: ${JSON.stringify(candidates)}`,
      evaluationResponse: JSON.stringify(
        evaluationResponse ?? {
          winner: candidates.indexOf(winnerCandidate),
          reason,
          fallback: true,
        }
      ),
      candidateRunIds: candidates.map((candidate) => candidate.runId),
      summary,
      pullRequest: prMetadata?.pullRequest,
      pullRequestTitle: prMetadata?.title,
      pullRequestDescription: prMetadata?.description,
    },
    baseUrlOverride
  );

  log("INFO", "Crowned task after evaluation", {
    taskId: crownData.taskId,
    winnerRunId: winnerCandidate.runId,
    winnerAgent: winnerCandidate.agentName,
    agentModel: agentModel ?? runContext.agentModel,
    elapsedMs,
  });
}
