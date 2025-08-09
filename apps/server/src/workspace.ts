import { api } from "@cmux/convex/api";
import fs from "fs/promises";
import os from "os";
import path from "path";
import { RepositoryManager } from "./repositoryManager.js";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { generateBetterNames, ensureUniqueBranchName } from "@cmux/shared/nameGeneration";

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
  branchName: string;
  worktreePath: string;
  repoName: string;
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

export async function getWorktreePath(args: {
  repoUrl: string;
  branch?: string;
  taskDescription?: string;
}): Promise<WorktreeInfo> {
  // Check for custom worktree path setting
  const settings = await convex.query(api.workspaceSettings.get);

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

  let branchName: string;
  let folderName: string;

  // Use smart naming if enabled and task description is provided
  if (args.taskDescription && (settings?.enableSmartNaming !== false)) {
    try {
      serverLogger.info(`[Workspace] Generating smart names for task: ${args.taskDescription.substring(0, 100)}...`);
      
      const generatedNames = await generateBetterNames(args.taskDescription, {
        prefix: settings?.branchPrefix || "",
        maxLength: 50,
        includeTimestamp: true,
      });

      folderName = generatedNames.folderName;
      branchName = generatedNames.branchName;
      
      serverLogger.info(`[Workspace] Generated names - Folder: ${folderName}, Branch: ${branchName}`);
    } catch (error) {
      serverLogger.warn(`[Workspace] Failed to generate smart names, falling back to timestamp:`, error);
      // Fallback to timestamp-based naming
      const timestamp = Date.now();
      branchName = `${settings?.branchPrefix || ""}cmux-${timestamp}`;
      folderName = `cmux-${timestamp}`;
    }
  } else {
    // Use timestamp-based naming (existing behavior)
    const timestamp = Date.now();
    branchName = `${settings?.branchPrefix || ""}cmux-${timestamp}`;
    folderName = `cmux-${timestamp}`;
  }

  const worktreePath = path.join(worktreesPath, folderName);

  // For consistency, still return appDataPath even if not used for custom paths
  const appDataPath = await getAppDataPath();

  return {
    appDataPath,
    projectsPath,
    projectPath,
    originPath,
    worktreesPath,
    branchName,
    worktreePath,
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
    const baseBranch = args.branch || await repoManager.getDefaultBranch(worktreeInfo.originPath);

    // Ensure branch name is unique
    try {
      const uniqueBranchName = await ensureUniqueBranchName(
        worktreeInfo.branchName,
        worktreeInfo.originPath,
        ""
      );
      
      if (uniqueBranchName !== worktreeInfo.branchName) {
        serverLogger.info(`[Workspace] Branch name adjusted for uniqueness: ${worktreeInfo.branchName} -> ${uniqueBranchName}`);
        worktreeInfo.branchName = uniqueBranchName;
        // Also update the worktree path to match
        const folderName = path.basename(worktreeInfo.worktreePath);
        if (folderName.includes(worktreeInfo.branchName.split('-').slice(-1)[0])) {
          // If folder name contains the timestamp/suffix, update it too
          worktreeInfo.worktreePath = path.join(path.dirname(worktreeInfo.worktreePath), uniqueBranchName);
        }
      }
    } catch (error) {
      serverLogger.warn(`[Workspace] Failed to check branch uniqueness:`, error);
      // Continue with original name if check fails
    }

    // Create the worktree
    await repoManager.createWorktree(
      worktreeInfo.originPath,
      worktreeInfo.worktreePath,
      worktreeInfo.branchName,
      baseBranch
    );

    return { success: true, worktreePath: worktreeInfo.worktreePath };
  } catch (error) {
    serverLogger.error("Failed to setup workspace:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unknown error",
    };
  }
}
