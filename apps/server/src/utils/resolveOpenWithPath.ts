import { exec } from "node:child_process";
import { promisify } from "node:util";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import { serverLogger } from "./fileLogger";
import { getConvex } from "./convexClient";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";

const execAsync = promisify(exec);

interface ResolveOpenWithPathOptions {
  requestedPath: string;
  taskRunId?: Id<"taskRuns"> | string;
  environmentId?: Id<"environments"> | string;
  repoFullName?: string;
  teamSlugOrId?: string;
}

interface PathResolution {
  resolvedPath: string;
  needsClone: string[];
  repositories: Array<{
    fullName: string;
    localPath: string;
    exists: boolean;
  }>;
}

/**
 * Resolves the actual path to open based on the context (cloud task, environment, etc.)
 * This handles edge cases like:
 * - Default /root/workspace path for cloud tasks
 * - Multiple repositories in environments
 * - Missing repositories that need cloning
 */
export async function resolveOpenWithPath({
  requestedPath,
  taskRunId,
  environmentId,
  repoFullName,
  teamSlugOrId,
}: ResolveOpenWithPathOptions): Promise<PathResolution> {
  const repositories: PathResolution["repositories"] = [];
  const needsClone: string[] = [];
  let resolvedPath = requestedPath;

  // For cloud tasks, we need to check if repos exist and possibly clone them
  if (taskRunId || environmentId) {
    const baseDir = requestedPath || "/root/workspace";

    // Get environment details if available
    let selectedRepos: string[] = [];

    if (environmentId && teamSlugOrId) {
      try {
        const convex = getConvex();
        const environment = await convex.query(api.environments.get, {
          teamSlugOrId,
          id: environmentId as Id<"environments">,
        });

        if (environment?.selectedRepos) {
          selectedRepos = environment.selectedRepos;
          serverLogger.info(
            `[resolveOpenWithPath] Environment has ${selectedRepos.length} repositories`
          );
        }
      } catch (error) {
        serverLogger.warn(
          `[resolveOpenWithPath] Failed to fetch environment details:`,
          error
        );
      }
    }

    // Determine which repos to check
    const reposToCheck: string[] = [];

    if (selectedRepos.length > 0) {
      reposToCheck.push(...selectedRepos);
    } else if (repoFullName) {
      reposToCheck.push(repoFullName);
    }

    // Check each repository
    for (const repo of reposToCheck) {
      const repoName = repo.split("/").pop() || repo;
      const localPath = path.join(baseDir, repoName);

      try {
        const stats = await fs.stat(localPath);
        const exists = stats.isDirectory();

        // Check if it's a git repo
        if (exists) {
          try {
            const gitPath = path.join(localPath, ".git");
            await fs.stat(gitPath);
            repositories.push({
              fullName: repo,
              localPath,
              exists: true,
            });
          } catch {
            // Directory exists but not a git repo
            serverLogger.warn(
              `[resolveOpenWithPath] Directory ${localPath} exists but is not a git repo`
            );
            repositories.push({
              fullName: repo,
              localPath,
              exists: true,
            });
          }
        } else {
          repositories.push({
            fullName: repo,
            localPath,
            exists: false,
          });
          needsClone.push(repo);
        }
      } catch {
        // Directory doesn't exist
        repositories.push({
          fullName: repo,
          localPath,
          exists: false,
        });
        needsClone.push(repo);
      }
    }

    // Determine the best path to open
    if (repositories.length === 1 && repositories[0].exists) {
      // Single repo that exists - open that specific directory
      resolvedPath = repositories[0].localPath;
    } else if (repositories.length > 1) {
      // Multiple repos - open the base workspace directory
      resolvedPath = baseDir;
    } else if (repositories.length === 1 && !repositories[0].exists) {
      // Single repo that doesn't exist - we'll clone it
      resolvedPath = repositories[0].localPath;
    } else {
      // No specific repos, use base directory
      resolvedPath = baseDir;
    }

    // Ensure base directory exists
    try {
      await fs.mkdir(baseDir, { recursive: true });
    } catch (error) {
      serverLogger.error(
        `[resolveOpenWithPath] Failed to create base directory ${baseDir}:`,
        error
      );
    }
  } else {
    // Local context - try to detect git repo
    try {
      const { stdout } = await execAsync("git rev-parse --show-toplevel", {
        cwd: requestedPath,
      });
      const gitRoot = stdout.trim();
      if (gitRoot) {
        resolvedPath = gitRoot;
        serverLogger.info(
          `[resolveOpenWithPath] Detected git root: ${gitRoot}`
        );
      }
    } catch {
      // Not in a git repo, use the requested path as-is
    }
  }

  return {
    resolvedPath,
    needsClone,
    repositories,
  };
}

/**
 * Attempts to clone missing repositories
 */
export async function cloneMissingRepos(
  repos: string[],
  baseDir: string = "/root/workspace"
): Promise<{ success: boolean; cloned: string[]; failed: string[] }> {
  const cloned: string[] = [];
  const failed: string[] = [];

  for (const repoFullName of repos) {
    const repoName = repoFullName.split("/").pop() || repoFullName;
    const localPath = path.join(baseDir, repoName);
    const gitUrl = `https://github.com/${repoFullName}.git`;

    try {
      serverLogger.info(
        `[cloneMissingRepos] Cloning ${repoFullName} to ${localPath}`
      );

      const { stderr } = await execAsync(
        `git clone "${gitUrl}" "${localPath}"`,
        {
          cwd: baseDir,
          timeout: 60000, // 1 minute timeout
        }
      );

      if (stderr && !stderr.includes("Cloning into")) {
        throw new Error(stderr);
      }

      cloned.push(repoFullName);
      serverLogger.info(
        `[cloneMissingRepos] Successfully cloned ${repoFullName}`
      );
    } catch (error) {
      failed.push(repoFullName);
      serverLogger.error(
        `[cloneMissingRepos] Failed to clone ${repoFullName}:`,
        error
      );
    }
  }

  return {
    success: failed.length === 0,
    cloned,
    failed,
  };
}