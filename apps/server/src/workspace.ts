import { api } from "@cmux/convex/api";
import fs from "fs/promises";
import os from "os";
import path from "path";
import { RepositoryManager } from "./repositoryManager.js";
import { convex } from "./utils/convexClient.js";
import { serverLogger } from "./utils/fileLogger.js";
import { generateAIName } from "@cmux/shared/aiNamingService";

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
  folderName: string;
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

  // Generate branch name using AI if enabled and task description is available
  let branchName: string;
  
  if (settings?.enableAINaming !== false && args.taskDescription) {
    try {
      // Get API keys for AI naming
      const apiKeys = await convex.query(api.apiKeys.getAllForAgents);
      const prefix = settings?.branchPrefix || "";
      
      branchName = await generateAIName(
        args.taskDescription, 
        "branch", 
        apiKeys, 
        prefix
      );
      
      serverLogger.info(`Generated AI branch name: ${branchName} for task: ${args.taskDescription.substring(0, 50)}...`);
    } catch (error) {
      serverLogger.warn(`Failed to generate AI branch name, falling back to timestamp: ${error}`);
      const timestamp = Date.now();
      branchName = `cmux-${timestamp}`;
    }
  } else {
    // Fallback to timestamp-based naming
    const timestamp = Date.now();
    branchName = `cmux-${timestamp}`;
  }

  // Generate folder name using same logic as branch name if AI naming is enabled
  let folderName: string;
  
  if (settings?.enableAINaming !== false && args.taskDescription) {
    try {
      // Get API keys for AI naming (reuse from previous call if available)
      const apiKeys = await convex.query(api.apiKeys.getAllForAgents);
      const prefix = settings?.branchPrefix || "";
      
      folderName = await generateAIName(
        args.taskDescription, 
        "folder", 
        apiKeys, 
        prefix
      );
      
      serverLogger.info(`Generated AI folder name: ${folderName}`);
    } catch (error) {
      serverLogger.warn(`Failed to generate AI folder name, using branch name: ${error}`);
      folderName = branchName;
    }
  } else {
    // Use branch name as folder name for consistency
    folderName = branchName;
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
    folderName,
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
