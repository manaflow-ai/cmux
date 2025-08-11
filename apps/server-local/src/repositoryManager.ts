import { exec } from "child_process";
import * as fs from "fs/promises";
import * as path from "path";
import { promisify } from "util";
import {
  generatePreCommitHook,
  generatePrePushHook,
  type GitHooksConfig,
} from "./gitHooks.js";
import { serverLogger } from "./utils/fileLogger.js";

const execAsync = promisify(exec);

interface RepositoryOperation {
  promise: Promise<void>;
  timestamp: number;
}

interface GitConfig {
  pullStrategy: "merge" | "rebase" | "ff-only";
  fetchDepth: number;
  operationCacheTime: number;
}

interface GitCommandOptions {
  cwd: string;
  encoding?: "utf8" | "ascii" | "base64" | "hex" | "binary" | "latin1";
}

interface QueuedOperation {
  execute: () => Promise<any>;
  resolve: (value: any) => void;
  reject: (error: any) => void;
}

export class RepositoryManager {
  private static instance: RepositoryManager;
  private operations = new Map<string, RepositoryOperation>();
  private worktreeLocks = new Map<string, Promise<void>>();
  
  // Global operation queue to prevent any git command conflicts
  private operationQueue: QueuedOperation[] = [];
  private isProcessingQueue = false;

  private config: GitConfig = {
    pullStrategy: "rebase",
    fetchDepth: 1,
    operationCacheTime: 5000, // 5 seconds
  };

  private constructor(config?: Partial<GitConfig>) {
    if (config) {
      this.config = { ...this.config, ...config };
    }
  }

  static getInstance(config?: Partial<GitConfig>): RepositoryManager {
    if (!RepositoryManager.instance) {
      RepositoryManager.instance = new RepositoryManager(config);
    }
    return RepositoryManager.instance;
  }

  private getCacheKey(repoUrl: string, operation: string): string {
    return `${repoUrl}:${operation}`;
  }

  private cleanupStaleOperations(): void {
    const now = Date.now();
    const entries = Array.from(this.operations.entries());
    for (const [key, op] of entries) {
      if (now - op.timestamp > this.config.operationCacheTime) {
        this.operations.delete(key);
      }
    }
  }

  private async queueOperation<T>(operation: () => Promise<T>): Promise<T> {
    return new Promise((resolve, reject) => {
      this.operationQueue.push({
        execute: operation,
        resolve,
        reject,
      });
      this.processQueue();
    });
  }

  private async processQueue(): Promise<void> {
    if (this.isProcessingQueue || this.operationQueue.length === 0) {
      return;
    }

    this.isProcessingQueue = true;

    while (this.operationQueue.length > 0) {
      const operation = this.operationQueue.shift()!;
      try {
        const result = await operation.execute();
        operation.resolve(result);
      } catch (error) {
        operation.reject(error);
      }
    }

    this.isProcessingQueue = false;
  }

  private async executeGitCommand(
    command: string,
    options?: GitCommandOptions
  ): Promise<{ stdout: string; stderr: string }> {
    // Commands that modify git config or create worktrees need to be queued
    const needsQueue = 
      command.includes('git config') ||
      command.includes('git worktree add') ||
      command.includes('git clone');

    if (needsQueue) {
      return this.queueOperation(async () => {
        try {
          const result = await execAsync(command, options);
          return {
            stdout: result.stdout.toString(),
            stderr: result.stderr.toString(),
          };
        } catch (error) {
          // Log the command that failed for debugging
          serverLogger.error(`Git command failed: ${command}`);
          if (error instanceof Error) {
            serverLogger.error(`Error: ${error.message}`);
            if ("stderr" in error && error.stderr) {
              serverLogger.error(`Stderr: ${error.stderr}`);
            }
          }
          throw error;
        }
      });
    }

    // Non-conflicting commands can run immediately
    try {
      const result = await execAsync(command, options);
      return {
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      };
    } catch (error) {
      // Log the command that failed for debugging
      serverLogger.error(`Git command failed: ${command}`);
      if (error instanceof Error) {
        serverLogger.error(`Error: ${error.message}`);
        if ("stderr" in error && error.stderr) {
          serverLogger.error(`Stderr: ${error.stderr}`);
        }
      }
      throw error;
    }
  }

  private async configureGitPullStrategy(repoPath: string): Promise<void> {
    try {
      const strategy =
        this.config.pullStrategy === "ff-only"
          ? "only"
          : this.config.pullStrategy;
      await this.executeGitCommand(
        `git config pull.${
          this.config.pullStrategy === "ff-only"
            ? "ff"
            : this.config.pullStrategy
        } ${strategy === "only" ? "only" : "true"}`,
        { cwd: repoPath }
      );
    } catch (error) {
      serverLogger.warn("Failed to configure git pull strategy:", error);
    }
  }

  async ensureRepository(
    repoUrl: string,
    originPath: string,
    branch?: string
  ): Promise<void> {
    this.cleanupStaleOperations();

    // Check if repo exists
    const repoExists = await this.checkIfRepoExists(originPath);

    if (!repoExists) {
      await this.handleCloneOperation(repoUrl, originPath);
      // After cloning, set the remote HEAD reference
      try {
        await this.executeGitCommand(
          `git remote set-head origin -a`,
          { cwd: originPath }
        );
      } catch (error) {
        serverLogger.warn("Failed to set remote HEAD after clone:", error);
      }
    } else {
      // Configure git pull strategy for existing repos
      await this.configureGitPullStrategy(originPath);
    }

    // If no branch specified, detect the default branch
    let targetBranch = branch;
    if (!targetBranch) {
      targetBranch = await this.getDefaultBranch(originPath);
      serverLogger.info(`Detected default branch: ${targetBranch}`);
    }

    // Only fetch if a specific branch was requested or if we detected a branch
    if (targetBranch) {
      await this.handleFetchOperation(repoUrl, originPath, targetBranch);
    }
  }

  private async handleCloneOperation(
    repoUrl: string,
    originPath: string
  ): Promise<void> {
    const cloneKey = this.getCacheKey(repoUrl, "clone");
    const existingClone = this.operations.get(cloneKey);

    if (
      existingClone &&
      Date.now() - existingClone.timestamp < this.config.operationCacheTime
    ) {
      serverLogger.info(`Reusing existing clone operation for ${repoUrl}`);
      await existingClone.promise;
    } else {
      const clonePromise = this.cloneRepository(repoUrl, originPath);
      this.operations.set(cloneKey, {
        promise: clonePromise,
        timestamp: Date.now(),
      });

      await clonePromise;
    }
  }

  private async handleFetchOperation(
    repoUrl: string,
    originPath: string,
    branch: string
  ): Promise<void> {
    const fetchKey = this.getCacheKey(repoUrl, `fetch:${branch}`);
    const existingFetch = this.operations.get(fetchKey);

    if (
      existingFetch &&
      Date.now() - existingFetch.timestamp < this.config.operationCacheTime
    ) {
      serverLogger.info(
        `Reusing existing fetch operation for ${repoUrl} branch ${branch}`
      );
      await existingFetch.promise;
    } else {
      const fetchPromise = this.fetchAndCheckoutBranch(originPath, branch);
      this.operations.set(fetchKey, {
        promise: fetchPromise,
        timestamp: Date.now(),
      });

      await fetchPromise;
    }
  }

  private async checkIfRepoExists(repoPath: string): Promise<boolean> {
    try {
      await fs.access(path.join(repoPath, ".git"));
      return true;
    } catch {
      return false;
    }
  }

  private async cloneRepository(
    repoUrl: string,
    originPath: string
  ): Promise<void> {
    serverLogger.info(
      `Cloning repository ${repoUrl} with depth ${this.config.fetchDepth}...`
    );
    try {
      await this.executeGitCommand(
        `git clone --depth ${this.config.fetchDepth} "${repoUrl}" "${originPath}"`
      );
      serverLogger.info(`Successfully cloned ${repoUrl}`);

      // Set the remote HEAD reference explicitly
      try {
        await this.executeGitCommand(
          `git remote set-head origin -a`,
          { cwd: originPath }
        );
      } catch (error) {
        serverLogger.warn("Failed to set remote HEAD reference:", error);
      }

      // Configure git pull strategy for the newly cloned repo
      await this.configureGitPullStrategy(originPath);

      // Set up git hooks
      await this.setupGitHooks(originPath);
    } catch (error) {
      serverLogger.error(`Failed to clone ${repoUrl}:`, error);
      throw error;
    }
  }

  private async getCurrentBranch(repoPath: string): Promise<string> {
    const { stdout } = await this.executeGitCommand(
      `git rev-parse --abbrev-ref HEAD`,
      { cwd: repoPath, encoding: "utf8" }
    );
    return stdout.trim();
  }

  async getDefaultBranch(repoPath: string): Promise<string> {
    try {
      // Try to get the default branch from the remote
      const { stdout } = await this.executeGitCommand(
        `git symbolic-ref refs/remotes/origin/HEAD`,
        { cwd: repoPath, encoding: "utf8" }
      );
      // Extract branch name from refs/remotes/origin/main format
      const match = stdout.trim().match(/refs\/remotes\/origin\/(.+)$/);
      return match ? match[1] : "main";
    } catch (error) {
      // If that fails, try to get it from the remote
      try {
        const { stdout } = await this.executeGitCommand(
          `git ls-remote --symref origin HEAD`,
          { cwd: repoPath, encoding: "utf8" }
        );
        // Extract branch name from ref: refs/heads/main format
        const match = stdout.match(/ref: refs\/heads\/(\S+)\s+HEAD/);
        if (match) {
          return match[1];
        }
      } catch {
        // Fallback to common defaults
        serverLogger.warn("Could not determine default branch, trying common names");
      }
      
      // Try common default branch names
      const commonDefaults = ["main", "master", "dev", "develop"];
      for (const branch of commonDefaults) {
        try {
          await this.executeGitCommand(
            `git rev-parse --verify origin/${branch}`,
            { cwd: repoPath, encoding: "utf8" }
          );
          return branch;
        } catch {
          // Continue to next branch
        }
      }
      
      // Final fallback
      return "main";
    }
  }

  private async pullLatestChanges(
    repoPath: string,
    branch: string
  ): Promise<void> {
    const pullFlags =
      this.config.pullStrategy === "rebase"
        ? "--rebase"
        : this.config.pullStrategy === "ff-only"
          ? "--ff-only"
          : "";

    try {
      await this.executeGitCommand(
        `git pull ${pullFlags} --depth ${this.config.fetchDepth} origin ${branch}`,
        { cwd: repoPath }
      );
      serverLogger.info(`Successfully pulled latest changes for ${branch}`);
    } catch (error) {
      // If pull fails due to conflicts or divergent branches, try to recover
      if (
        error instanceof Error &&
        (error.message.includes("divergent branches") ||
          error.message.includes("conflict"))
      ) {
        serverLogger.warn(
          `Pull failed due to conflicts, attempting to reset to origin/${branch}`
        );
        try {
          // Fetch the latest state
          await this.executeGitCommand(
            `git fetch --depth ${this.config.fetchDepth} origin ${branch}`,
            { cwd: repoPath }
          );
          // Reset to the remote branch
          await this.executeGitCommand(`git reset --hard origin/${branch}`, {
            cwd: repoPath,
          });
          serverLogger.info(`Successfully reset to origin/${branch}`);
        } catch (resetError) {
          serverLogger.error(`Failed to reset to origin/${branch}:`, resetError);
          throw resetError;
        }
      } else {
        throw error;
      }
    }
  }

  private async fetchAndCheckoutBranch(
    originPath: string,
    branch: string
  ): Promise<void> {
    serverLogger.info(`Fetching and checking out branch ${branch}...`);
    try {
      const currentBranch = await this.getCurrentBranch(originPath);

      if (currentBranch === branch) {
        // Already on the requested branch, just pull latest
        serverLogger.info(`Already on branch ${branch}, pulling latest changes...`);
        await this.pullLatestChanges(originPath, branch);
      } else {
        // Fetch and checkout different branch
        await this.switchToBranch(originPath, branch);
      }

      serverLogger.info(`Successfully on branch ${branch}`);
    } catch (error) {
      serverLogger.warn(
        `Failed to fetch/checkout branch ${branch}, falling back to current branch:`,
        error
      );
      // Don't throw - we'll use whatever branch is currently checked out
    }
  }

  private async switchToBranch(
    repoPath: string,
    branch: string
  ): Promise<void> {
    try {
      // Try to fetch the branch without specifying local name
      await this.executeGitCommand(
        `git fetch --depth ${this.config.fetchDepth} origin ${branch}`,
        { cwd: repoPath }
      );

      // Checkout the branch
      await this.executeGitCommand(
        `git checkout -B ${branch} origin/${branch}`,
        { cwd: repoPath }
      );
    } catch (error) {
      // If branch doesn't exist remotely, try just checking out locally
      if (error instanceof Error && error.message.includes("not found")) {
        await this.executeGitCommand(`git checkout ${branch}`, {
          cwd: repoPath,
        });
      } else {
        throw error;
      }
    }
  }

  async createWorktree(
    originPath: string,
    worktreePath: string,
    branchName: string,
    baseBranch: string = "main"
  ): Promise<void> {
    // Wait for any existing worktree operation on this repo to complete
    const existingLock = this.worktreeLocks.get(originPath);
    if (existingLock) {
      serverLogger.info(
        `Waiting for existing worktree operation on ${originPath}...`
      );
      await existingLock;
    }

    // Create a new lock for this operation
    let releaseLock: () => void;
    const lockPromise = new Promise<void>((resolve) => {
      releaseLock = () => {
        this.worktreeLocks.delete(originPath);
        resolve();
      };
    });
    this.worktreeLocks.set(originPath, lockPromise);

    serverLogger.info(`Creating worktree with new branch ${branchName}...`);
    try {
      await this.executeGitCommand(
        `git worktree add -b "${branchName}" "${worktreePath}" origin/${baseBranch}`,
        { cwd: originPath }
      );
      serverLogger.info(`Successfully created worktree at ${worktreePath}`);

      // Set up branch configuration to push to the same name on remote
      // Use a serial approach for config commands to avoid lock conflicts
      await this.configureWorktreeBranch(worktreePath, branchName);

      // Set up git hooks in the worktree
      await this.setupGitHooks(worktreePath);
    } catch (error) {
      if (error instanceof Error && error.message.includes("already exists")) {
        throw new Error(`Worktree already exists at ${worktreePath}`);
      }
      throw error;
    } finally {
      // Always release the lock
      releaseLock!();
    }
  }

  private async configureWorktreeBranch(
    worktreePath: string,
    branchName: string
  ): Promise<void> {
    try {
      await this.executeGitCommand(
        `git config branch.${branchName}.remote origin`,
        { cwd: worktreePath }
      );
      await this.executeGitCommand(
        `git config branch.${branchName}.merge refs/heads/${branchName}`,
        { cwd: worktreePath }
      );
      serverLogger.info(
        `Configured branch ${branchName} to track origin/${branchName} when pushed`
      );
    } catch (error) {
      serverLogger.warn(`Failed to configure branch tracking for ${branchName}:`, error);
    }
  }

  // Method to update configuration at runtime
  updateConfig(config: Partial<GitConfig>): void {
    this.config = { ...this.config, ...config };
  }

  private async setupGitHooks(repoPath: string): Promise<void> {
    try {
      // Determine if this is a worktree or main repository
      const gitDir = path.join(repoPath, ".git");
      const gitDirStat = await fs.stat(gitDir);

      let hooksDir: string;
      if (gitDirStat.isDirectory()) {
        // Regular repository
        hooksDir = path.join(gitDir, "hooks");
      } else {
        // Worktree - read the .git file to find the actual git directory
        const gitFileContent = await fs.readFile(gitDir, "utf8");
        const match = gitFileContent.match(/gitdir: (.+)/);
        if (!match) {
          serverLogger.warn(`Could not parse .git file in ${repoPath}`);
          return;
        }
        const actualGitDir = match[1].trim();
        // For worktrees, hooks are in the common git directory
        const commonDir = path.join(path.dirname(actualGitDir), "commondir");
        try {
          const commonDirContent = await fs.readFile(commonDir, "utf8");
          const commonPath = commonDirContent.trim();
          // If commondir is relative, resolve it from the worktree git directory
          const resolvedCommonPath = path.isAbsolute(commonPath)
            ? commonPath
            : path.resolve(path.dirname(actualGitDir), commonPath);
          hooksDir = path.join(resolvedCommonPath, "hooks");
        } catch {
          // Fallback to the hooks in the worktree's git directory
          hooksDir = path.join(actualGitDir, "hooks");
        }
      }

      // Create hooks directory if it doesn't exist
      await fs.mkdir(hooksDir, { recursive: true });

      // Configure hooks
      const hooksConfig: GitHooksConfig = {
        protectedBranches: [
          "main",
          "master",
          "develop",
          "production",
          "staging",
        ],
        allowForcePush: false,
        allowBranchDeletion: false,
      };

      // Write pre-push hook
      const prePushPath = path.join(hooksDir, "pre-push");
      await fs.writeFile(prePushPath, generatePrePushHook(hooksConfig), {
        mode: 0o755,
      });
      serverLogger.info(`Created pre-push hook at ${prePushPath}`);

      // Write pre-commit hook
      const preCommitPath = path.join(hooksDir, "pre-commit");
      await fs.writeFile(preCommitPath, generatePreCommitHook(hooksConfig), {
        mode: 0o755,
      });
      serverLogger.info(`Created pre-commit hook at ${preCommitPath}`);
    } catch (error) {
      serverLogger.warn(`Failed to set up git hooks in ${repoPath}:`, error);
      // Don't throw - hooks are nice to have but not critical
    }
  }
}
