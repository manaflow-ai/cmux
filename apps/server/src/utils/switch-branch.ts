#!/usr/bin/env bun

import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { $ } from "bun";

const workspaceDir = process.env.CMUX_WORKSPACE_DIR ?? "/root/workspace";
const branchName = process.env.CMUX_BRANCH_NAME;

const logPrefix = "[cmux switch-branch]";
const log = (...parts: Array<string>) => {
  if (parts.length === 0) {
    console.error(logPrefix);
    return;
  }
  console.error(`${logPrefix} ${parts.join(" ")}`);
};

const formatError = (error: unknown) => {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
};

const textDecoder = new TextDecoder();

const decodeShellOutput = (value: unknown): string | null => {
  if (typeof value === "string") {
    return value;
  }
  if (value instanceof Uint8Array) {
    return textDecoder.decode(value);
  }
  return null;
};

type ShellErrorOutputs = { stderr?: unknown; stdout?: unknown };

const hasShellOutputs = (value: unknown): value is ShellErrorOutputs =>
  typeof value === "object" && value !== null;

const extractShellOutputs = (
  error: unknown,
): { stderr: string | null; stdout: string | null } => {
  if (!hasShellOutputs(error)) {
    return { stderr: null, stdout: null };
  }
  return {
    stderr: decodeShellOutput(error.stderr ?? null),
    stdout: decodeShellOutput(error.stdout ?? null),
  };
};

const getCurrentBranch = async (repoPath: string): Promise<string | null> => {
  try {
    const output = await $`git -C ${repoPath} rev-parse --abbrev-ref HEAD`.text();
    const branch = output.trim();
    if (branch.length === 0 || branch === "HEAD") {
      return null;
    }
    return branch;
  } catch {
    return null;
  }
};

if (!branchName) {
  log("missing branch name");
  process.exit(1);
}

async function detectRepositories(): Promise<Array<string>> {
  const found = new Set<string>();

  if (!existsSync(workspaceDir)) {
    log("workspace directory missing", workspaceDir);
    return Array.from(found);
  }

  const workspaceGit = join(workspaceDir, ".git");

  if (existsSync(workspaceGit)) {
    try {
      await $`git -C ${workspaceDir} rev-parse --is-inside-work-tree`.quiet();
      found.add(resolve(workspaceDir));
    } catch (error) {
      log("workspace has .git but is not a valid repo:", formatError(error));
    }
    return Array.from(found);
  }

  let dirEntries;
  try {
    dirEntries = await readdir(workspaceDir, { withFileTypes: true });
  } catch (error) {
    log("failed to read workspace entries:", formatError(error));
    return Array.from(found);
  }

  for (const entry of dirEntries) {
    if (!entry.isDirectory()) {
      continue;
    }
    const repoDir = join(workspaceDir, entry.name);
    const gitDir = join(repoDir, ".git");
    if (!existsSync(gitDir)) {
      continue;
    }

    try {
      await $`git -C ${repoDir} rev-parse --is-inside-work-tree`.quiet();
      found.add(resolve(repoDir));
    } catch (error) {
      log("subdirectory has .git but is not a valid repo:", repoDir, formatError(error));
    }
  }

  return Array.from(found);
}

const repoPaths = await detectRepositories();

if (repoPaths.length === 0) {
  log("no git repositories detected");
  process.exit(0);
}

let failureCount = 0;

for (const repoPath of repoPaths) {
  log("repo=", repoPath, "-> switching to", branchName ?? "(missing)");

  const currentBranch = await getCurrentBranch(repoPath);
  if (currentBranch === branchName) {
    log("repo=", repoPath, "-> already on branch", branchName ?? "(missing)");
    continue;
  }

  try {
    await $`git -C ${repoPath} switch ${branchName}`.quiet();
    log("repo=", repoPath, "-> switched to existing branch", branchName ?? "(missing)");
    continue;
  } catch (switchError) {
    const { stderr } = extractShellOutputs(switchError);
    const message = stderr?.trim() ?? formatError(switchError);
    log(
      "repo=",
      repoPath,
      "-> existing branch missing, attempting to create:",
      message,
    );
  }

  try {
    await $`git -C ${repoPath} switch -c ${branchName}`.quiet();
    log("repo=", repoPath, "-> created branch", branchName ?? "(missing)");
  } catch (createError) {
    const { stderr } = extractShellOutputs(createError);
    const message = stderr?.trim() ?? formatError(createError);
    log(
      "repo=",
      repoPath,
      "-> failed to create branch:",
      message,
    );

    const branchAfterFailure = await getCurrentBranch(repoPath);
    if (branchAfterFailure === branchName) {
      log(
        "repo=",
        repoPath,
        "-> branch already active despite creation error",
        branchName ?? "(missing)",
      );
      continue;
    }

    failureCount += 1;
  }
}

if (failureCount > 0) {
  log("completed with failures:", String(failureCount));
  process.exit(1);
}

log("completed successfully for", String(repoPaths.length), "repo(s)");
