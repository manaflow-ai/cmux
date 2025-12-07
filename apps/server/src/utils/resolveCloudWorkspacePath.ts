import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import type { Socket } from "@cmux/shared/socket";
import { serverLogger } from "./fileLogger";
import { workerExec } from "./workerExec";
import path from "node:path";

interface ResolveCloudWorkspacePathParams {
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>;
  repoFullName?: string;
  environmentId?: string;
  selectedRepos?: string[];
  baseDir?: string;
}

interface WorkspaceInfo {
  mainPath: string;
  repositories: Array<{
    fullName: string;
    localPath: string;
    exists: boolean;
  }>;
  needsClone: string[];
}

/**
 * Resolves workspace paths for cloud tasks, handling both single repo and multi-repo environments
 * This handles the edge cases where:
 * 1. Cloud tasks always start with /root/workspace
 * 2. Environments may have multiple repositories
 * 3. Repos might not be cloned yet
 */
export async function resolveCloudWorkspacePath({
  workerSocket,
  repoFullName,
  environmentId,
  selectedRepos = [],
  baseDir = "/root/workspace",
}: ResolveCloudWorkspacePathParams): Promise<WorkspaceInfo> {
  const repositories: WorkspaceInfo["repositories"] = [];
  const needsClone: string[] = [];

  // Determine which repos we need to check
  const reposToCheck: string[] = [];

  if (environmentId && selectedRepos.length > 0) {
    // Environment with multiple repos
    reposToCheck.push(...selectedRepos);
  } else if (repoFullName) {
    // Single repo task
    reposToCheck.push(repoFullName);
  }

  // Check each repository
  for (const repo of reposToCheck) {
    const repoName = repo.split("/").pop() || repo;
    const localPath = path.join(baseDir, repoName);

    try {
      // Check if the directory exists and is a git repo
      const checkScript = `
        if [ -d "${localPath}" ]; then
          if [ -d "${localPath}/.git" ]; then
            echo "git"
          else
            echo "dir"
          fi
        else
          echo "missing"
        fi
      `.trim();

      const { stdout } = await workerExec({
        workerSocket,
        command: "bash",
        args: ["-c", checkScript],
        cwd: baseDir,
        env: {},
        timeout: 5000,
      });

      const status = stdout.trim();
      const exists = status === "git" || status === "dir";

      repositories.push({
        fullName: repo,
        localPath,
        exists,
      });

      if (!exists) {
        needsClone.push(repo);
      } else if (status === "dir") {
        serverLogger.warn(
          `[resolveCloudWorkspacePath] Directory ${localPath} exists but is not a git repo`
        );
      }
    } catch (error) {
      serverLogger.warn(
        `[resolveCloudWorkspacePath] Error checking ${localPath}:`,
        error
      );
      repositories.push({
        fullName: repo,
        localPath,
        exists: false,
      });
      needsClone.push(repo);
    }
  }

  // Determine the main path to open
  let mainPath = baseDir;

  if (repositories.length === 1) {
    // Single repo - open that specific directory
    mainPath = repositories[0].localPath;
  } else if (repositories.length > 1) {
    // Multiple repos - open the base workspace directory
    // This allows the user to see all repos in the file explorer
    mainPath = baseDir;
  }

  // If nothing exists, check if the base dir at least exists
  if (repositories.length === 0 || repositories.every(r => !r.exists)) {
    try {
      const { stdout } = await workerExec({
        workerSocket,
        command: "bash",
        args: ["-c", `[ -d "${baseDir}" ] && echo "exists" || echo "missing"`],
        cwd: "/",
        env: {},
        timeout: 5000,
      });

      if (stdout.trim() === "missing") {
        // Create the base directory
        await workerExec({
          workerSocket,
          command: "mkdir",
          args: ["-p", baseDir],
          cwd: "/",
          env: {},
          timeout: 5000,
        });
        serverLogger.info(
          `[resolveCloudWorkspacePath] Created base directory ${baseDir}`
        );
      }
    } catch (error) {
      serverLogger.error(
        `[resolveCloudWorkspacePath] Failed to check/create base directory:`,
        error
      );
    }
  }

  return {
    mainPath,
    repositories,
    needsClone,
  };
}

/**
 * Clones missing repositories for cloud workspaces
 */
export async function cloneCloudRepositories({
  workerSocket,
  repositories,
  baseDir = "/root/workspace",
}: {
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>;
  repositories: Array<{ fullName: string; gitUrl?: string }>;
  baseDir?: string;
}): Promise<{ success: boolean; cloned: string[]; failed: string[] }> {
  const cloned: string[] = [];
  const failed: string[] = [];

  for (const repo of repositories) {
    const repoName = repo.fullName.split("/").pop() || repo.fullName;
    const localPath = path.join(baseDir, repoName);

    try {
      // Construct git URL if not provided
      const gitUrl = repo.gitUrl || `https://github.com/${repo.fullName}.git`;

      serverLogger.info(
        `[cloneCloudRepositories] Cloning ${repo.fullName} to ${localPath}`
      );

      // Clone the repository
      const { exitCode } = await workerExec({
        workerSocket,
        command: "git",
        args: ["clone", gitUrl, localPath],
        cwd: baseDir,
        env: {},
        timeout: 60000, // 1 minute timeout for cloning
      });

      if (exitCode === 0) {
        cloned.push(repo.fullName);
        serverLogger.info(
          `[cloneCloudRepositories] Successfully cloned ${repo.fullName}`
        );
      } else {
        failed.push(repo.fullName);
        serverLogger.error(
          `[cloneCloudRepositories] Failed to clone ${repo.fullName}: exit code ${exitCode}`
        );
      }
    } catch (error) {
      failed.push(repo.fullName);
      serverLogger.error(
        `[cloneCloudRepositories] Error cloning ${repo.fullName}:`,
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