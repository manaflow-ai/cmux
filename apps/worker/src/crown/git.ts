import { existsSync } from "node:fs";
import { join } from "node:path";

import { log } from "../logger";
import { WORKSPACE_ROOT } from "./workspace-root";
import { execAsync, type ExecError } from "./shell";

let gitRepoPath: string | null = null;
export const branchDiffCache = new Map<string, string>();

export async function detectGitRepoPath(): Promise<string> {
  if (gitRepoPath) {
    return gitRepoPath;
  }

  if (existsSync(join(WORKSPACE_ROOT, ".git"))) {
    gitRepoPath = WORKSPACE_ROOT;
    log("INFO", "Git repository found at workspace root", {
      path: gitRepoPath,
    });
    return gitRepoPath;
  }

  try {
    const { stdout: dirs } = await execAsync(
      `ls -d ${WORKSPACE_ROOT}/*/ 2>/dev/null || true`,
      {
        cwd: WORKSPACE_ROOT,
      }
    );

    if (dirs && dirs.trim()) {
      const dirList = dirs.trim().split("\n");
      for (const dir of dirList) {
        const trimmedDir = dir.replace(/\/$/, "");
        if (existsSync(join(trimmedDir, ".git"))) {
          gitRepoPath = trimmedDir;
          log("INFO", "Git repository found in subdirectory", {
            path: gitRepoPath,
          });
          return gitRepoPath;
        }
      }
    }

    const { stdout } = await execAsync(
      `find ${WORKSPACE_ROOT} -maxdepth 2 -type d -name .git 2>/dev/null | head -1`,
      {
        cwd: WORKSPACE_ROOT,
      }
    );

    if (stdout && stdout.trim()) {
      const gitDir = stdout.trim();
      gitRepoPath = gitDir.replace(/\/.git$/, "");
      log("INFO", "Git repository found via find command", {
        path: gitRepoPath,
      });
      return gitRepoPath;
    }
  } catch (error) {
    log("WARN", "Failed to search for git repositories", {
      error: error instanceof Error ? error.message : "Unknown error",
    });
  }

  log("WARN", "No git repository found, using workspace root", {
    path: WORKSPACE_ROOT,
  });
  gitRepoPath = WORKSPACE_ROOT;
  return gitRepoPath;
}

export async function runGitCommand(
  command: string,
  allowFailure = false
): Promise<{ stdout: string; stderr: string; exitCode: number } | null> {
  const formatOutput = (value: unknown): string => {
    if (typeof value === "string") {
      return value;
    }
    if (
      value &&
      typeof (value as { toString(): string }).toString === "function"
    ) {
      try {
        return (value as { toString(): string }).toString();
      } catch {
        return "";
      }
    }
    return "";
  };

  try {
    const repoPath = await detectGitRepoPath();
    const result = await execAsync(command, {
      cwd: repoPath,
      maxBuffer: 10 * 1024 * 1024,
    });
    const stdout = formatOutput(result.stdout);
    const stderr = formatOutput(result.stderr);
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    const execError: ExecError =
      error instanceof Error
        ? error
        : new Error(
            typeof error === "string" ? error : "Unknown git command error"
          );
    const stdout = formatOutput(execError.stdout);
    const stderr = formatOutput(execError.stderr);
    const exitCode =
      typeof execError.code === "number"
        ? execError.code
        : typeof execError.status === "number"
          ? execError.status
          : 1;
    const errorPayload = {
      command,
      message: execError.message,
      exitCode,
      stdout: stdout?.slice(0, 500),
      stderr: stderr?.slice(0, 500),
    };
    if (!allowFailure) {
      log("ERROR", "Git command failed", errorPayload);
      throw error;
    }
    log("WARN", "Git command failed (ignored)", errorPayload);
    return { stdout, stderr, exitCode };
  }
}

export async function fetchRemoteRef(ref: string): Promise<boolean> {
  if (!ref) {
    return false;
  }

  const remoteBranch = ref.replace(/^origin\//, "");
  const verifyRef = `refs/remotes/origin/${remoteBranch}`;
  const fetchCommand = `git fetch --no-tags --prune origin refs/heads/${remoteBranch}:${verifyRef}`;

  log("DEBUG", "Fetching remote ref", { ref });
  const result = await runGitCommand(fetchCommand, true);

  if (!result) {
    log("WARN", "git fetch failed for ref", { ref });
    return false;
  }

  const trimmedStdout = result.stdout?.trim();
  if (trimmedStdout && trimmedStdout.length > 0) {
    log("DEBUG", "git fetch output", {
      ref,
      output: trimmedStdout.slice(0, 160),
    });
  }

  const verifyResult = await runGitCommand(
    `git rev-parse --verify --quiet ${verifyRef}`,
    true
  );

  if (verifyResult?.stdout?.trim()) {
    log("INFO", "Remote ref verified", {
      ref,
      commit: verifyResult.stdout.trim(),
    });
    return true;
  }

  log("WARN", "Remote ref missing after fetch", { ref });
  return false;
}

export function formatDiff(diff: string): string {
  if (!diff) return "No changes detected";
  const trimmed = diff.trim();
  return trimmed.length > 0 ? trimmed : "No changes detected";
}

export async function collectDiffForRun(
  baseBranch: string,
  branch: string | null
): Promise<string> {
  if (!branch) {
    return "No changes detected";
  }

  const cachedDiff = branchDiffCache.get(branch);
  if (cachedDiff) {
    log("INFO", "Using cached diff for branch", { branch });
    return formatDiff(cachedDiff);
  }

  const sanitizedBase = baseBranch || "main";
  log("INFO", "Collecting diff from remote branches", {
    baseBranch: sanitizedBase,
    branch,
  });
  await fetchRemoteRef(sanitizedBase);
  await fetchRemoteRef(branch);
  const baseRef = sanitizedBase.startsWith("origin/")
    ? sanitizedBase
    : `origin/${sanitizedBase}`;
  const branchRef = branch.startsWith("origin/") ? branch : `origin/${branch}`;

  try {
    const { stdout } = await execAsync(
      "/usr/local/bin/cmux-collect-crown-diff.sh",
      {
        cwd: WORKSPACE_ROOT,
        maxBuffer: 5 * 1024 * 1024,
        env: {
          ...process.env,
          CMUX_DIFF_BASE: baseRef,
          CMUX_DIFF_HEAD_REF: branchRef,
        },
      }
    );

    const diff = stdout.trim();
    if (!diff) {
      log("INFO", "No differences found between branches", {
        base: baseRef,
        branch: branchRef,
      });
      return "No changes detected";
    }

    branchDiffCache.set(branch, diff);
    return formatDiff(diff);
  } catch (error) {
    log("ERROR", "Failed to collect diff for run", {
      baseBranch: sanitizedBase,
      branch,
      error,
    });
    return "No changes detected";
  }
}

export async function ensureBranchesAvailable(
  completedRuns: Array<{ id: string; newBranch: string | null }>,
  baseBranch: string,
  localFallbackBranches: Set<string> = new Set()
): Promise<boolean> {
  const sanitizedBase = baseBranch || "main";
  const baseOk = await fetchRemoteRef(sanitizedBase);
  log("INFO", "Ensuring branches available", {
    baseBranch: sanitizedBase,
    baseOk,
    completedRunCount: completedRuns.length,
  });

  let allBranchesOk = true;
  for (const run of completedRuns) {
    if (!run.newBranch) {
      log("ERROR", "Run missing branch name", { runId: run.id });
      return false;
    }
    const branchOk = await fetchRemoteRef(run.newBranch);
    log("INFO", "Checked branch availability", {
      runId: run.id,
      branch: run.newBranch,
      branchOk,
    });
    if (!branchOk && !localFallbackBranches.has(run.newBranch)) {
      allBranchesOk = false;
    } else if (!branchOk) {
      log("INFO", "Using cached diff fallback for branch", {
        runId: run.id,
        branch: run.newBranch,
      });
    }
  }

  if (baseOk && allBranchesOk) {
    return true;
  }

  log("INFO", "Branches not ready for crown", {
    baseOk,
    allBranchesOk,
  });
  return false;
}

export async function captureRelevantDiff(): Promise<string> {
  try {
    const repoPath = await detectGitRepoPath();
    const { stdout } = await execAsync(
      "/usr/local/bin/cmux-collect-crown-diff.sh",
      {
        cwd: repoPath,
        maxBuffer: 5 * 1024 * 1024,
      }
    );
    const diff = stdout ? stdout.trim() : "";
    return diff.length > 0 ? diff : "No changes detected";
  } catch (error) {
    log("ERROR", "Failed to collect relevant diff", { error });
    return "No changes detected";
  }
}

export function buildCommitMessage({
  taskText,
  agentName,
}: {
  taskText: string;
  agentName: string;
}): string {
  const baseLine = taskText.trim().split("\n")[0] ?? "task";
  const subject =
    baseLine.length > 60 ? `${baseLine.slice(0, 57)}...` : baseLine;
  const sanitizedAgent = agentName.replace(/[^a-zA-Z0-9_-]/g, "-");
  return `chore(${sanitizedAgent}): ${subject}`;
}

export async function getCurrentBranch(): Promise<string | null> {
  const result = await runGitCommand("git rev-parse --abbrev-ref HEAD", true);
  const branch = result?.stdout.trim();
  if (!branch) {
    log("WARN", "Unable to determine current git branch");
    return null;
  }
  return branch;
}

export async function autoCommitAndPush({
  branchName,
  commitMessage,
  remoteUrl,
}: {
  branchName: string;
  commitMessage: string;
  remoteUrl?: string;
}): Promise<void> {
  if (!branchName) {
    log("ERROR", "Missing branch name for auto-commit");
    return;
  }

  const repoPath = await detectGitRepoPath();

  log("INFO", "Worker auto-commit starting", {
    branchName,
    remoteOverride: remoteUrl,
    workspacePath: WORKSPACE_ROOT,
    gitRepoPath: repoPath,
  });

  const gitCheck = await runGitCommand("git rev-parse --git-dir", true);
  if (!gitCheck || gitCheck.exitCode !== 0) {
    log("ERROR", "Not in a git repository", {
      branchName,
      workspacePath: WORKSPACE_ROOT,
      gitRepoPath: repoPath,
      gitCheckError: gitCheck?.stderr,
    });
    const initResult = await runGitCommand("git init", true);
    if (!initResult || initResult.exitCode !== 0) {
      log("ERROR", "Failed to initialize git repository", {
        branchName,
        gitRepoPath: repoPath,
        error: initResult?.stderr,
      });
      return;
    }
    log("INFO", "Initialized git repository", {
      branchName,
      gitRepoPath: repoPath,
    });
  }

  if (remoteUrl) {
    const currentRemote = await runGitCommand(
      "git remote get-url origin",
      true
    );
    const trimmed = currentRemote?.stdout.trim();
    if (!trimmed) {
      log("INFO", "Adding origin remote", {
        branchName,
        remoteUrl,
      });
      await runGitCommand(`git remote add origin ${remoteUrl}`);
    } else if (trimmed !== remoteUrl) {
      log("INFO", "Updating origin remote before push", {
        branchName,
        currentRemote: trimmed,
        remoteUrl,
      });
      await runGitCommand(`git remote set-url origin ${remoteUrl}`);
    }
    const updatedRemote = await runGitCommand("git remote -v", true);
    if (updatedRemote) {
      log("INFO", "Current git remotes after potential update", {
        branchName,
        remotes: updatedRemote.stdout.trim().split("\n"),
      });
    }
  }

  const addResult = await runGitCommand(`git add -A`);
  log("INFO", "git add completed", {
    branchName,
    stdout: addResult?.stdout
      ? addResult.stdout.trim().slice(0, 200)
      : undefined,
    stderr: addResult?.stderr
      ? addResult.stderr.trim().slice(0, 200)
      : undefined,
  });

  const checkoutResult = await runGitCommand(`git checkout -B ${branchName}`);
  log("INFO", "git checkout -B completed", {
    branchName,
    stdout: checkoutResult?.stdout
      ? checkoutResult.stdout.trim().slice(0, 200)
      : undefined,
    stderr: checkoutResult?.stderr
      ? checkoutResult.stderr.trim().slice(0, 200)
      : undefined,
  });

  const status = await runGitCommand(`git status --short`, true);
  const hasChanges = !!status?.stdout.trim();
  if (status) {
    const preview = status.stdout.trim().split("\n").slice(0, 10);
    log("INFO", "git status before commit", {
      branchName,
      entries: preview,
      totalLines:
        status.stdout.trim() === ""
          ? 0
          : status.stdout.trim().split("\n").length,
    });
  }

  if (hasChanges) {
    const commitResult = await runGitCommand(
      `git commit -m ${JSON.stringify(commitMessage)}`,
      true
    );
    if (commitResult) {
      log("INFO", "Created commit before push", {
        branchName,
        stdout: commitResult.stdout.trim().slice(0, 200),
        stderr: commitResult.stderr.trim().slice(0, 200),
      });
    } else {
      log("WARN", "Commit command did not produce output", { branchName });
    }
  } else {
    log("INFO", "No changes detected before commit", { branchName });
  }

  const remoteExists = await runGitCommand(
    `git ls-remote --heads origin ${branchName}`,
    true
  );

  if (remoteExists?.stdout.trim()) {
    log("INFO", "Remote branch exists before push", {
      branchName,
      remoteHead: remoteExists.stdout.trim().slice(0, 120),
    });
    const pullResult = await runGitCommand(
      `git pull --rebase origin ${branchName}`
    );
    if (pullResult) {
      log("INFO", "Rebased branch onto remote", {
        branchName,
        stdout: pullResult.stdout.trim().slice(0, 200),
        stderr: pullResult.stderr.trim().slice(0, 200),
      });
    }
  } else {
    log("INFO", "Remote branch missing before push; creating new remote ref", {
      branchName,
    });
  }

  const pushResult = await runGitCommand(`git push -u origin ${branchName}`);
  if (pushResult) {
    log("INFO", "git push output", {
      branchName,
      stdout: pushResult.stdout.trim().slice(0, 200),
      stderr: pushResult.stderr.trim().slice(0, 200),
    });
  }

  log("INFO", "Worker auto-commit finished", { branchName });
}
