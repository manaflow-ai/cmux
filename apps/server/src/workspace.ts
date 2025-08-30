import { api } from "@cmux/convex/api";
import fs from "fs/promises";
import os from "os";
import path from "path";
import { RepositoryManager } from "./repositoryManager.js";
import { getConvex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";

interface WorkspaceResult {
  success: boolean;
  worktreePath?: string;
  error?: string;
}

interface WorktreeInfo {
  appDataPath: string;
  projectsPath: string;
  projectPath: string;
  originPath: string;
  worktreesPath: string;
  worktreePath: string;
  repoName: string;
  branch: string;
}

async function getAppDataPath(): Promise<string> {
  const appName = "manaflow3";
  const platform = process.platform;

  if (platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", appName);
  } else if (platform === "win32") {
    return path.join(process.env.APPDATA || "", appName);
  } else {
    return path.join(os.homedir(), ".config", appName);
  }
}

function extractRepoName(repoUrl: string): string {
  const match = repoUrl.match(/([^/]+)\.git$/);
  if (match) {
    return match[1];
  }

  const parts = repoUrl.split("/");
  return parts[parts.length - 1] || "unknown-repo";
}

export async function getWorktreePath(
  args: {
    repoUrl: string;
    branch: string;
  },
  teamSlugOrId: string
): Promise<WorktreeInfo> {
  // Check for custom worktree path setting
  const settings = await getConvex().query(api.workspaceSettings.get, {
    teamSlugOrId,
  });

  let projectsPath: string;

  if (settings?.worktreePath) {
    // Use custom path, expand ~ to home directory
    const expandedPath = settings.worktreePath.replace(/^~/, os.homedir());
    projectsPath = expandedPath;
  } else {
    // Use default path: ~/cmux
    projectsPath = path.join(os.homedir(), "cmux");
  }

  const repoName = extractRepoName(args.repoUrl);
  const projectPath = path.join(projectsPath, repoName);
  const originPath = path.join(projectPath, "origin");
  const worktreesPath = path.join(projectPath, "worktrees");

  const worktreePath = path.join(worktreesPath, args.branch);

  // For consistency, still return appDataPath even if not used for custom paths
  const appDataPath = await getAppDataPath();

  return {
    appDataPath,
    projectsPath,
    projectPath,
    originPath,
    worktreesPath,
    worktreePath,
    repoName,
    branch: args.branch,
  };
}

export async function getProjectPaths(
  repoUrl: string,
  teamSlugOrId: string
): Promise<{
  appDataPath: string;
  projectsPath: string;
  projectPath: string;
  originPath: string;
  worktreesPath: string;
  repoName: string;
}> {
  const settings = await getConvex().query(api.workspaceSettings.get, {
    teamSlugOrId,
  });

  let projectsPath: string;
  if (settings?.worktreePath) {
    const expandedPath = settings.worktreePath.replace(/^~/, os.homedir());
    projectsPath = expandedPath;
  } else {
    projectsPath = path.join(os.homedir(), "cmux");
  }

  const repoName = extractRepoName(repoUrl);
  const projectPath = path.join(projectsPath, repoName);
  const originPath = path.join(projectPath, "origin");
  const worktreesPath = path.join(projectPath, "worktrees");
  const appDataPath = await getAppDataPath();

  return {
    appDataPath,
    projectsPath,
    projectPath,
    originPath,
    worktreesPath,
    repoName,
  };
}

export async function setupProjectWorkspace(args: {
  repoUrl: string;
  branch?: string;
  worktreeInfo: WorktreeInfo;
}): Promise<WorkspaceResult> {
  try {
    const { worktreeInfo } = args;
    const repoManager = RepositoryManager.getInstance();
    // Normalize worktree path to avoid accidental extra folders like "cmux/<branch>"
    const normalizedWorktreePath = path.join(
      worktreeInfo.worktreesPath,
      worktreeInfo.branch
    );
    if (worktreeInfo.worktreePath !== normalizedWorktreePath) {
      serverLogger.info(
        `Normalizing worktree path from ${worktreeInfo.worktreePath} to ${normalizedWorktreePath}`
      );
      worktreeInfo.worktreePath = normalizedWorktreePath;
    }

    // Check if the projects path exists and has non-git content
    try {
      const stats = await fs.stat(worktreeInfo.projectsPath);
      if (stats.isDirectory()) {
        // Check if it contains non-git repositories
        const entries = await fs.readdir(worktreeInfo.projectsPath);
        for (const entry of entries) {
          const entryPath = path.join(worktreeInfo.projectsPath, entry);
          const entryStats = await fs.stat(entryPath);
          if (entryStats.isDirectory()) {
            // Check if it's a git repository structure we expect
            const hasOrigin = await fs
              .access(path.join(entryPath, "origin"))
              .then(() => true)
              .catch(() => false);
            const hasWorktrees = await fs
              .access(path.join(entryPath, "worktrees"))
              .then(() => true)
              .catch(() => false);

            if (!hasOrigin && !hasWorktrees) {
              // This directory has unexpected content
              return {
                success: false,
                error: `The directory ${worktreeInfo.projectsPath} contains existing files that are not git worktrees. Please choose a different location in settings or move the existing files.`,
              };
            }
          }
        }
      }
    } catch {
      // Directory doesn't exist, which is fine
    }

    await fs.mkdir(worktreeInfo.projectPath, { recursive: true });
    await fs.mkdir(worktreeInfo.worktreesPath, { recursive: true });

    // Use RepositoryManager to handle clone/fetch with deduplication
    await repoManager.ensureRepository(
      args.repoUrl,
      worktreeInfo.originPath,
      args.branch
    );

    // Get the default branch if not specified
    const baseBranch =
      args.branch ||
      (await repoManager.getDefaultBranch(worktreeInfo.originPath));

    // If a worktree for this branch already exists anywhere, reuse it
    try {
      const existingByBranch = await repoManager.findWorktreeUsingBranch(
        worktreeInfo.originPath,
        worktreeInfo.branch
      );
      if (existingByBranch) {
        if (existingByBranch !== worktreeInfo.worktreePath) {
          serverLogger.info(
            `Reusing existing worktree for ${worktreeInfo.branch} at ${existingByBranch}`
          );
          worktreeInfo.worktreePath = existingByBranch;
        } else {
          serverLogger.info(
            `Worktree for ${worktreeInfo.branch} already registered at ${existingByBranch}`
          );
        }
        // Ensure configuration and hooks are present
        await repoManager.ensureWorktreeConfigured(
          worktreeInfo.worktreePath,
          worktreeInfo.branch
        );
      }
    } catch (e) {
      serverLogger.warn(
        `Failed checking for existing worktree for ${worktreeInfo.branch}:`,
        e
      );
    }

    // Check if worktree already exists in git
    const worktreeRegistered = await repoManager.worktreeExists(
      worktreeInfo.originPath,
      worktreeInfo.worktreePath
    );

    if (worktreeRegistered) {
      // Check if the directory actually exists
      try {
        await fs.access(worktreeInfo.worktreePath);
        serverLogger.info(
          `Worktree already exists at ${worktreeInfo.worktreePath}, using existing`
        );
      } catch {
        // Worktree is registered but directory doesn't exist, remove and recreate
        serverLogger.info(
          `Worktree registered but directory missing, recreating...`
        );
        await repoManager.removeWorktree(
          worktreeInfo.originPath,
          worktreeInfo.worktreePath
        );
        const actualPath = await repoManager.createWorktree(
          worktreeInfo.originPath,
          worktreeInfo.worktreePath,
          worktreeInfo.branch,
          baseBranch
        );
        if (actualPath && actualPath !== worktreeInfo.worktreePath) {
          serverLogger.info(
            `Worktree path resolved to ${actualPath} for branch ${worktreeInfo.branch}`
          );
          worktreeInfo.worktreePath = actualPath;
        }
      }
    } else {
      // Create the worktree
      const actualPath = await repoManager.createWorktree(
        worktreeInfo.originPath,
        worktreeInfo.worktreePath,
        worktreeInfo.branch,
        baseBranch
      );
      if (actualPath && actualPath !== worktreeInfo.worktreePath) {
        serverLogger.info(
          `Worktree path resolved to ${actualPath} for branch ${worktreeInfo.branch}`
        );
        worktreeInfo.worktreePath = actualPath;
      }
    }

    return { success: true, worktreePath: worktreeInfo.worktreePath };
  } catch (error) {
    serverLogger.error("Failed to setup workspace:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unknown error",
    };
  }
}
