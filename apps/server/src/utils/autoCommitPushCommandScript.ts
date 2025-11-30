#!/usr/bin/env bun

import { $ } from "bun";
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const branchName = process.env.CMUX_BRANCH_NAME;
const commitMessage = process.env.CMUX_COMMIT_MESSAGE;
if (!branchName || !commitMessage) {
  console.error("[cmux auto-commit] missing branch name or commit message");
  console.error("[cmux auto-commit] branch name:", branchName);
  console.error("[cmux auto-commit] commit message:", commitMessage);
  process.exit(1);
}

const resolveHomeDirectory = (): string => {
  const envHome = process.env.HOME?.trim();
  if (envHome) {
    return envHome;
  }

  try {
    const osHome = homedir();
    if (osHome) {
      return osHome;
    }
  } catch {
    // ignore and fall back to default
  }

  return "/root";
};

process.env.HOME = resolveHomeDirectory();

const formatError = (error: unknown) => {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
};

async function runRepo(repoPath: string) {
  console.error(`[cmux auto-commit] repo=${repoPath} -> enter directory`);

  try {
    // Get repo info
    const origin = await $`git -C ${repoPath} config --get remote.origin.url`
      .text()
      .catch(() => "");
    console.error(
      `[cmux auto-commit] repo=${repoPath} -> origin=${origin.trim()}`
    );

    // Determine protected branch information before checking out
    const remoteHeadRef = await $`git -C ${repoPath} symbolic-ref --short refs/remotes/origin/HEAD`
      .text()
      .then((value) => value.trim())
      .catch(() => "");
    const remoteDefaultBranch = remoteHeadRef.includes("/")
      ? remoteHeadRef.split("/").pop() ?? ""
      : remoteHeadRef;

    if (remoteDefaultBranch) {
      console.error(
        `[cmux auto-commit] repo=${repoPath} -> origin default branch ${remoteDefaultBranch}`
      );
    } else {
      console.error(
        `[cmux auto-commit] repo=${repoPath} -> origin default branch unavailable`
      );
    }

    if (remoteDefaultBranch && remoteDefaultBranch === branchName) {
      const message = `[cmux auto-commit] repo=${repoPath} refusing to push protected branch ${branchName}`;
      console.error(message);
      throw new Error(message);
    }

    // Add all changes
    console.error(`[cmux auto-commit] repo=${repoPath} -> git add -A`);
    await $`git -C ${repoPath} add -A`;

    // Checkout branch (create or switch)
    console.error(
      `[cmux auto-commit] repo=${repoPath} -> ensure branch ${branchName}`
    );

    const branchExists = await $`git -C ${repoPath} rev-parse --verify ${branchName}`
      .quiet()
      .then(() => true)
      .catch(() => false);

    if (branchExists) {
      console.error(
        `[cmux auto-commit] repo=${repoPath} branch already exists -> checkout ${branchName}`
      );
      await $`git -C ${repoPath} checkout ${branchName}`;
    } else {
      try {
        await $`git -C ${repoPath} checkout -b ${branchName}`.quiet();
        console.error(
          `[cmux auto-commit] repo=${repoPath} created branch ${branchName}`
        );
      } catch (createError) {
        console.error(
          `[cmux auto-commit] repo=${repoPath} failed to create branch ${branchName}: ${formatError(createError)}`
        );
        console.error(
          `[cmux auto-commit] repo=${repoPath} attempting checkout ${branchName}`
        );
        await $`git -C ${repoPath} checkout ${branchName}`;
      }
    }

    // Commit
    console.error(`[cmux auto-commit] repo=${repoPath} -> git commit`);
    try {
      await $`git -C ${repoPath} commit -m ${commitMessage}`;
      console.error(`[cmux auto-commit] repo=${repoPath} commit created`);
    } catch (e) {
      const hasChanges = await $`git -C ${repoPath} status --short`.text();
      if (hasChanges.trim()) {
        console.error(
          `[cmux auto-commit] repo=${repoPath} commit failed with pending changes`
        );
        throw e;
      } else {
        console.error(`[cmux auto-commit] repo=${repoPath} nothing to commit`);
      }
    }

    // Check if remote branch exists
    const remoteBranch =
      await $`git -C ${repoPath} ls-remote --heads origin ${branchName}`
        .text()
        .catch(() => "");

    if (remoteBranch.trim()) {
      console.error(
        `[cmux auto-commit] repo=${repoPath} -> git pull --rebase origin ${branchName}`
      );
      await $`git -C ${repoPath} pull --rebase origin ${branchName}`;
    } else {
      console.error(
        `[cmux auto-commit] repo=${repoPath} remote branch missing; skip pull --rebase`
      );
    }

    // Push
    console.error(
      `[cmux auto-commit] repo=${repoPath} -> git push -u origin ${branchName}`
    );
    await $`git -C ${repoPath} push -u origin ${branchName}`;
  } catch (error) {
    console.error(`[cmux auto-commit] repo=${repoPath} failed:`, error);
    throw error; // Will be caught by Promise.allSettled
  }
}

async function main() {
  console.error(`[cmux auto-commit] script start cwd=${process.cwd()}`);

  console.error("[cmux auto-commit] detecting repositories");

  // Always scan from the workspace directory regardless of current directory
  const workspaceDir = process.env.CMUX_WORKSPACE_DIR ?? "/root/workspace";
  console.error(`[cmux auto-commit] scanning repos from ${workspaceDir}`);

  const repoPaths: string[] = [];

  if (existsSync(workspaceDir)) {
    // First check if the workspace directory itself is a git repo
    const workspaceGitPath = join(workspaceDir, ".git");

    if (existsSync(workspaceGitPath)) {
      // Workspace directory is itself a git repo
      try {
        await $`git -C ${workspaceDir} rev-parse --is-inside-work-tree`.quiet();
        const repoPath = resolve(workspaceDir);

        console.error(
          `[cmux auto-commit] ${workspaceDir} is a git repo: ${repoPath}`
        );
        repoPaths.push(repoPath);
      } catch {
        console.error(
          "[cmux auto-commit] ${workspaceDir} has .git but is not a valid repo"
        );
      }
    } else {
      // Workspace is not a git repo, check for sub-repos
      console.error(
        "[cmux auto-commit] ${workspaceDir} is not a git repo, checking for sub-repos"
      );

      const dirEntries = await readdir(workspaceDir, {
        withFileTypes: true,
      }).catch(() => []);

      console.error(`[cmux auto-commit] found ${dirEntries.length} sub-repos`);

      const checkPromises = dirEntries
        .filter((entry) => entry.isDirectory())
        .map(async (entry) => {
          const repoDir = join(workspaceDir, entry.name);
          const gitPath = join(repoDir, ".git");

          if (existsSync(gitPath)) {
            // Verify it's a git repo
            try {
              await $`git -C ${repoDir} rev-parse --is-inside-work-tree`.quiet();
              const repoPath = resolve(repoDir);
              console.error(`[cmux auto-commit] found sub-repo: ${repoPath}`);
              return repoPath;
            } catch {
              // Not a valid git repo, skip
              return null;
            }
          }
          return null;
        });

      const results = await Promise.all(checkPromises);
      repoPaths.push(
        ...results.filter((path): path is string => path !== null)
      );
    }
  }

  if (repoPaths.length === 0) {
    console.error(
      "[cmux auto-commit] No git repositories found for auto-commit"
    );
  } else {
    console.error(
      `[cmux auto-commit] processing ${repoPaths.length} repos in parallel`
    );

    // Process all repos in parallel
    const results = await Promise.allSettled(
      repoPaths.map((repoPath) => runRepo(repoPath))
    );

    // Report results
    let successCount = 0;
    let failCount = 0;

    results.forEach((result, index) => {
      const repoPath = repoPaths[index];
      if (result.status === "fulfilled") {
        successCount++;
        console.error(`[cmux auto-commit] ✓ ${repoPath} succeeded`);
      } else {
        failCount++;
        console.error(
          `[cmux auto-commit] ✗ ${repoPath} failed: ${result.reason}`
        );
      }
    });

    console.error(
      `[cmux auto-commit] completed: ${successCount} succeeded, ${failCount} failed`
    );

    // Exit with error if any repos failed
    if (failCount > 0) {
      process.exit(1);
    }
  }
}

await main().catch((error) => {
  console.error("[cmux auto-commit] Fatal error:", error);
  process.exit(1);
});
