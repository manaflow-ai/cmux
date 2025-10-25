import * as fs from "node:fs/promises";
import * as path from "node:path";

import type { Id } from "@cmux/convex/dataModel";
import type {
  RunBranchStatus,
  RunBranchSyncStatus,
  RunSyncLogs,
  RunSyncResponse,
} from "@cmux/shared";

import { RepositoryManager } from "../repositoryManager";
import { serverLogger } from "./fileLogger";
import {
  ensureRunWorktreeAndBranch,
  type EnsureWorktreeResult,
} from "./ensureRunWorktree";

interface RunSyncParams {
  taskRunId: Id<"taskRuns">;
  teamSlugOrId: string;
}

function toTrackingRef(branch: string): string {
  if (!branch) {
    return branch;
  }
  if (branch.startsWith("refs/")) {
    return branch;
  }
  return branch.startsWith("origin/") ? branch : `origin/${branch}`;
}

function extractStderr(error: unknown): string | undefined {
  if (typeof error === "object" && error && "stderr" in error) {
    const value = (error as { stderr?: unknown }).stderr;
    if (typeof value === "string") {
      return value;
    }
    if (
      value &&
      typeof (value as { toString?: () => string }).toString === "function"
    ) {
      try {
        return (value as { toString: () => string }).toString();
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

function formatGitError(error: unknown): string {
  if (error instanceof Error) {
    const stderr = extractStderr(error);
    if (stderr) {
      const trimmed = stderr.trim();
      if (!error.message.includes(trimmed)) {
        return `${error.message}: ${trimmed}`;
      }
      return error.message;
    }
    return error.message || "Unknown error";
  }
  const stderr = extractStderr(error);
  if (stderr) {
    return stderr.trim();
  }
  if (typeof error === "string") {
    return error;
  }
  return "Unknown error";
}

async function checkMergeInProgress(worktreePath: string): Promise<boolean> {
  try {
    await fs.access(path.join(worktreePath, ".git", "MERGE_HEAD"));
    return true;
  } catch {
    return false;
  }
}

async function computeStatusForEnsure(
  ensure: EnsureWorktreeResult,
): Promise<RunBranchStatus> {
  const repoMgr = RepositoryManager.getInstance();
  const warnings: string[] = [];
  const cwd = ensure.worktreePath;
  const timestamp = Date.now();

  const { stdout: headOut } = await repoMgr.executeGitCommand(
    "git rev-parse HEAD",
    { cwd },
  );
  const headCommit = headOut.trim();

  let dirty = false;
  try {
    const { stdout: statusOut } = await repoMgr.executeGitCommand(
      "git status --porcelain",
      { cwd },
    );
    dirty = statusOut.trim().length > 0;
  } catch (error) {
    warnings.push(`Failed to inspect working tree status: ${formatGitError(error)}`);
  }

  const mergeInProgress = await checkMergeInProgress(cwd);

  const baseBranch = ensure.baseBranch?.trim() ?? "";
  if (!baseBranch) {
    warnings.push("Task run does not have an associated base branch.");
    return {
      baseBranch,
      headBranch: ensure.branchName,
      headCommit,
      ahead: 0,
      behind: 0,
      status: "unknown",
      dirty,
      mergeInProgress,
      warnings,
      timestamp,
    };
  }

  const tracking = toTrackingRef(baseBranch);

  try {
    await repoMgr.updateRemoteBranchIfStale(cwd, baseBranch);
  } catch (error) {
    warnings.push(`Failed to refresh origin/${baseBranch}: ${formatGitError(error)}`);
  }

  let baseCommit: string | undefined;
  try {
    const { stdout: baseOut } = await repoMgr.executeGitCommand(
      `git rev-parse ${tracking}`,
      { cwd, suppressErrorLogging: true },
    );
    baseCommit = baseOut.trim();
  } catch (error) {
    warnings.push(`Unable to resolve ${tracking}: ${formatGitError(error)}`);
  }

  let mergeBase: string | undefined;
  if (baseCommit) {
    try {
      const { stdout: mergeBaseOut } = await repoMgr.executeGitCommand(
        `git merge-base HEAD ${tracking}`,
        { cwd },
      );
      mergeBase = mergeBaseOut.trim();
    } catch (error) {
      warnings.push(
        `Failed to compute merge base with ${tracking}: ${formatGitError(error)}`,
      );
    }
  }

  let ahead = 0;
  let behind = 0;
  if (baseCommit) {
    try {
      const { stdout: aheadBehindOut } = await repoMgr.executeGitCommand(
        `git rev-list --left-right --count HEAD...${tracking}`,
        { cwd },
      );
      const parts = aheadBehindOut.trim().split(/\s+/);
      ahead = Number.parseInt(parts[0] ?? "0", 10) || 0;
      behind = Number.parseInt(parts[1] ?? "0", 10) || 0;
    } catch (error) {
      warnings.push(
        `Failed to compute ahead/behind counts: ${formatGitError(error)}`,
      );
    }
  }

  if (dirty) {
    warnings.push("Working tree has uncommitted changes.");
  }
  if (mergeInProgress) {
    warnings.push("A merge conflict is currently in progress.");
  }

  const status: RunBranchSyncStatus = !baseCommit
    ? "unknown"
    : behind > 0
      ? "behind"
      : "up_to_date";

  return {
    baseBranch,
    headBranch: ensure.branchName,
    headCommit,
    baseCommit,
    mergeBase,
    ahead,
    behind,
    status,
    dirty,
    mergeInProgress,
    warnings,
    timestamp,
  };
}

async function safeComputeStatus(
  ensure: EnsureWorktreeResult,
): Promise<RunBranchStatus | undefined> {
  try {
    return await computeStatusForEnsure(ensure);
  } catch (error) {
    serverLogger.warn(
      `[runSync] Failed to compute branch status: ${formatGitError(error)}`,
    );
    return undefined;
  }
}

export async function getRunBranchStatus({
  taskRunId,
  teamSlugOrId,
}: RunSyncParams): Promise<RunBranchStatus> {
  const ensure = await ensureRunWorktreeAndBranch(taskRunId, teamSlugOrId);
  return await computeStatusForEnsure(ensure);
}

export async function syncRunWithBase({
  taskRunId,
  teamSlugOrId,
}: RunSyncParams): Promise<RunSyncResponse> {
  let ensure: EnsureWorktreeResult;
  try {
    ensure = await ensureRunWorktreeAndBranch(taskRunId, teamSlugOrId);
  } catch (error) {
    return {
      ok: false,
      error: formatGitError(error),
    };
  }

  const repoMgr = RepositoryManager.getInstance();
  const cwd = ensure.worktreePath;
  const baseBranch = ensure.baseBranch?.trim();

  if (!baseBranch) {
    return {
      ok: false,
      error: "Base branch is not configured for this task run.",
      previousStatus: await safeComputeStatus(ensure),
    };
  }

  const previousStatus = await safeComputeStatus(ensure);

  let syncStdout = "";
  let syncStderr = "";

  try {
    const { stdout, stderr } = await repoMgr.executeGitCommand(
      `git pull origin ${baseBranch}`,
      { cwd },
    );
    syncStdout = stdout;
    syncStderr = stderr;
  } catch (error) {
    syncStdout =
      typeof (error as { stdout?: unknown }).stdout === "string"
        ? (error as { stdout: string }).stdout
        : syncStdout;
    syncStderr = extractStderr(error) ?? syncStderr;

    const status = await safeComputeStatus(ensure);
    return {
      ok: false,
      error: formatGitError(error),
      previousStatus,
      status,
      logs: {
        stdout: syncStdout,
        stderr: syncStderr,
      },
    };
  }

  const status = await safeComputeStatus(ensure);

  if (!status) {
    return {
      ok: true,
      status: await computeStatusForEnsure(ensure),
      previousStatus,
      logs: {
        stdout: syncStdout,
        stderr: syncStderr,
      },
    };
  }

  return {
    ok: true,
    status,
    previousStatus,
    logs: {
      stdout: syncStdout,
      stderr: syncStderr,
    },
  };
}
