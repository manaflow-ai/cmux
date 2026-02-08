import { exec, execFile, type ExecFileOptions } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { promisify } from "node:util";
import {
  generatePreCommitHook,
  generatePrePushHook,
  type GitHooksConfig,
} from "./gitHooks";
import { serverLogger } from "./utils/fileLogger";
import { getGitHubOAuthToken } from "./utils/getGitHubToken";

const execAsync = promisify(exec);
const execFileAsync = promisify(execFile);

/**
 * Sanitize a URL or command string by removing credentials.
 * Replaces patterns like `https://user:token@host` with `https://***@host`
 */
function sanitizeForLogging(str: string): string {
  // Match URLs with credentials: protocol://user:password@host
  return str.replace(
    /(\w+:\/\/)([^:]+):([^@]+)@/g,
    "$1***:***@"
  );
}

/**
 * Validate a git branch name to prevent command injection.
 * Git branch names must follow git's ref naming rules:
 * - Cannot start with a dot or hyphen
 * - Cannot contain .., @{, \, or control characters
 * - Cannot end with .lock
 * - Cannot contain shell metacharacters that could lead to injection
 *
 * @throws Error if the branch name is invalid
 */
export function validateBranchName(branch: string): void {
  if (!branch || typeof branch !== "string") {
    throw new Error("Branch name must be a non-empty string");
  }

  // Maximum length check (git allows up to 256 bytes typically)
  if (branch.length > 255) {
    throw new Error("Branch name exceeds maximum length of 255 characters");
  }

  // Disallow shell metacharacters and dangerous patterns that could enable injection
  // These characters could break out of quoted strings or execute commands
  const dangerousPatterns = [
    /[`$(){}|;&<>!#*?\[\]\\'"]/,  // Shell metacharacters
    /\x00-\x1f/,                   // Control characters
    /\x7f/,                        // DEL character
    /\.\./,                        // Double dots (path traversal)
    /@\{/,                         // Git reflog syntax
    /\.lock$/,                     // Cannot end with .lock
    /^-/,                          // Cannot start with hyphen (interpreted as option)
    /^\./,                         // Cannot start with dot
    /\/\//,                        // Double slashes
    /\/$/,                         // Cannot end with slash
    /^\/$/,                        // Cannot be just a slash
  ];

  for (const pattern of dangerousPatterns) {
    if (pattern.test(branch)) {
      throw new Error(
        `Invalid branch name "${branch.slice(0, 50)}": contains disallowed pattern ${pattern.toString()}`
      );
    }
  }

  // Validate it matches git's ref naming convention (alphanumeric, dots, hyphens, underscores, slashes)
  // This is the positive allowlist after filtering out dangerous patterns
  const validBranchPattern = /^[a-zA-Z0-9][a-zA-Z0-9._/-]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$/;
  if (!validBranchPattern.test(branch)) {
    throw new Error(
      `Invalid branch name "${branch.slice(0, 50)}": must contain only alphanumeric characters, dots, hyphens, underscores, and forward slashes`
    );
  }
}

interface RepositoryOperation {
  promise: Promise<void>;
  timestamp: number;
}

interface GitConfig {
  pullStrategy: "merge" | "rebase" | "ff-only";
  fetchDepth: number;
  operationCacheTime: number;
}

// Default timeout for git commands (2 minutes)
const DEFAULT_GIT_TIMEOUT_MS = 120_000;
// Longer timeout for clone/fetch operations (5 minutes)
const CLONE_FETCH_TIMEOUT_MS = 300_000;

interface GitCommandOptions {
  cwd: string;
  encoding?: "utf8" | "ascii" | "base64" | "hex" | "binary" | "latin1";
  // When true, suppress logging for expected failures (e.g., existence checks)
  suppressErrorLogging?: boolean;
  // Timeout in milliseconds (defaults to DEFAULT_GIT_TIMEOUT_MS)
  timeout?: number;
}

interface QueuedOperation {
  execute: () => Promise<unknown>;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
}

export class RepositoryManager {
  private static instance: RepositoryManager;
  private operations = new Map<string, RepositoryOperation>();
  private worktreeLocks = new Map<string, Promise<void>>();
  private resolvedGitPath: string | null = null;

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
    // Include the operation details (which may embed paths/branches) to avoid
    // accidental cross-repo or cross-directory reuse. This method is kept for
    // consistency should we later want to normalize keys.
    return `${repoUrl}:${operation}`;
  }

  private cleanupStaleOperations(): void {
    const now = Date.now();
    for (const [key, op] of this.operations) {
      if (now - op.timestamp > this.config.operationCacheTime) {
        this.operations.delete(key);
      }
    }
  }

  private async queueOperation<T>(operation: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      this.operationQueue.push({
        execute: operation,
        // Wrap resolve/reject to satisfy the queue's unknown-typed callbacks
        resolve: (value: unknown) => resolve(value as T),
        reject: (error: unknown) => reject(error),
      });
      this.processQueue();
    });
  }

  private async processQueue(): Promise<void> {
    if (this.isProcessingQueue || this.operationQueue.length === 0) {
      return;
    }

    this.isProcessingQueue = true;

    try {
      while (this.operationQueue.length > 0) {
        const operation = this.operationQueue.shift()!;
        try {
          const result = await operation.execute();
          // Wrap resolve in try-catch to prevent breaking the queue
          try {
            operation.resolve(result);
          } catch (resolveErr) {
            serverLogger.error(`Error in operation resolve callback:`, resolveErr);
          }
        } catch (error) {
          // Wrap reject in try-catch to prevent breaking the queue
          try {
            operation.reject(error);
          } catch (rejectErr) {
            serverLogger.error(`Error in operation reject callback:`, rejectErr);
          }
        }
      }
    } finally {
      // Always reset the flag to prevent permanent queue stall
      this.isProcessingQueue = false;
    }
  }

  // Note: Keep all git invocations using executeGitCommand with a shell, as some CI envs lack direct execFile PATH resolution.

  // Attempt to extract a stderr string from an unknown error shape
  private extractStderr(err: unknown): string | null {
    if (typeof err === "object" && err !== null && "stderr" in err) {
      const candidate = (err as { stderr?: unknown }).stderr;
      if (typeof candidate === "string") return candidate;
      if (
        candidate &&
        typeof (candidate as { toString?: () => string }).toString ===
        "function"
      ) {
        try {
          return (candidate as { toString: () => string }).toString();
        } catch {
          return null;
        }
      }
    }
    return null;
  }

  async executeGitCommand(
    command: string,
    options?: GitCommandOptions
  ): Promise<{ stdout: string; stderr: string }> {
    // Commands that modify git config, create worktrees, or clone should be serialized
    const needsQueue =
      command.includes("git config") ||
      command.includes("git worktree add") ||
      command.includes("git clone");

    // Use longer timeout for clone/fetch operations
    const isLongOperation =
      command.includes("git clone") ||
      command.includes("git fetch") ||
      command.includes("git pull");
    const timeout = options?.timeout ?? (isLongOperation ? CLONE_FETCH_TIMEOUT_MS : DEFAULT_GIT_TIMEOUT_MS);

    if (needsQueue) {
      return this.queueOperation(async () => {
        try {
          const result = await execAsync(command, {
            shell: process.platform === "win32" ? "cmd.exe" : "/bin/sh",
            timeout,
            maxBuffer: 50 * 1024 * 1024, // 50MB buffer for large repos
            ...options,
          });
          return {
            stdout: result.stdout.toString(),
            stderr: result.stderr.toString(),
          };
        } catch (error) {
          // Log only if not suppressed (some failures are expected)
          if (!options?.suppressErrorLogging) {
            serverLogger.error(`Git command failed: ${sanitizeForLogging(command)}`);
            if (error instanceof Error) {
              serverLogger.error(`Error: ${sanitizeForLogging(error.message)}`);
              const stderrMsg = this.extractStderr(error);
              if (stderrMsg) serverLogger.error(`Stderr: ${sanitizeForLogging(stderrMsg)}`);
            }
          }
          throw error;
        }
      });
    }

    // Prefer execFile with an absolute git path when invoking non-queued git commands
    if (command.startsWith("git ")) {
      const gitPath = await this.getGitPath();
      const args = this.tokenizeGitArgs(command.slice(4));
      try {
        const execOptions: ExecFileOptions = {
          cwd: options?.cwd,
          // Ensure string output for easier logging; fall back to utf8
          encoding: options?.encoding ?? "utf8",
          windowsHide: true,
          timeout,
          maxBuffer: 50 * 1024 * 1024, // 50MB buffer for large repos
        };
        const result = await execFileAsync(gitPath, args, execOptions);
        return {
          stdout: result.stdout.toString(),
          stderr: result.stderr?.toString?.() || "",
        };
      } catch (error) {
        // Log and fall through to shell execution unless suppressed
        if (!options?.suppressErrorLogging) {
          serverLogger.error(
            `Git command failed: ${gitPath} ${sanitizeForLogging(args.join(" "))}`
          );
          if (error instanceof Error) {
            serverLogger.error(`Error: ${sanitizeForLogging(error.message)}`);
            const stderrMsg = this.extractStderr(error);
            if (stderrMsg) serverLogger.error(`Stderr: ${sanitizeForLogging(stderrMsg)}`);
          }
        }
      }
    }

    // Non-conflicting commands can run immediately via shell
    try {
      const result = await execAsync(command, {
        shell: process.platform === "win32" ? "cmd.exe" : "/bin/sh",
        timeout,
        maxBuffer: 50 * 1024 * 1024, // 50MB buffer for large repos
        ...options,
      });
      return {
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      };
    } catch (error) {
      // Log only if not suppressed
      if (!options?.suppressErrorLogging) {
        serverLogger.error(`Git command failed: ${sanitizeForLogging(command)}`);
        if (error instanceof Error) {
          serverLogger.error(`Error: ${sanitizeForLogging(error.message)}`);
          const stderrMsg = this.extractStderr(error);
          if (stderrMsg) serverLogger.error(`Stderr: ${sanitizeForLogging(stderrMsg)}`);
        }
      }
      throw error;
    }
  }

  // Remove a stale git lock file (e.g., shallow.lock or index.lock) if it looks abandoned.
  // This is a safety valve for cases where a previous git process crashed and left a lock behind.
  private async removeStaleGitLock(
    repoPath: string,
    relLockPath: string,
    maxAgeMs: number = 60_000,
    force: boolean = false
  ): Promise<boolean> {
    try {
      const lockPath = path.join(repoPath, ".git", relLockPath);
      const stat = await fs.stat(lockPath).catch(() => null);
      if (!stat) return false;
      const age = Date.now() - stat.mtimeMs;
      if (force || age > maxAgeMs) {
        await fs.rm(lockPath, { force: true });
        serverLogger.warn(
          `Removed ${relLockPath} at ${lockPath} (age=${Math.round(age)}ms, force=${force})`
        );
        return true;
      }
      // Too new; leave it for the other process to complete
      serverLogger.info(
        `${relLockPath} exists but is recent (${Math.round(age)}ms); not removing`
      );
      return false;
    } catch (e) {
      serverLogger.warn(`Failed removing stale lock ${relLockPath}:`, e);
      return false;
    }
  }

  private async getGitPath(): Promise<string> {
    if (this.resolvedGitPath) return this.resolvedGitPath;
    const candidates = [
      process.env.GIT_PATH,
      process.platform === "win32" ? "git.exe" : undefined,
      "/opt/homebrew/bin/git",
      "/usr/local/bin/git",
      "/usr/bin/git",
      "/bin/git",
      "git",
    ].filter(Boolean) as string[];

    for (const p of candidates) {
      try {
        await fs.access(p);
        this.resolvedGitPath = p;
        return p;
      } catch {
        // try next
      }
    }
    // Last resort
    this.resolvedGitPath = process.platform === "win32" ? "git.exe" : "git";
    return this.resolvedGitPath;
  }

  private tokenizeGitArgs(s: string): string[] {
    const args: string[] = [];
    const re = /\s*("([^"]*)"|'([^']*)'|[^\s"']+)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(s)) !== null) {
      args.push(m[2] ?? m[3] ?? m[1]);
    }
    return args;
  }

  async getGitDir(repoPath: string): Promise<string> {
    try {
      const { stdout } = await this.executeGitCommand(
        `git rev-parse --git-dir`,
        {
          cwd: repoPath,
        }
      );
      const p = stdout.trim();
      return path.isAbsolute(p) ? p : path.join(repoPath, p);
    } catch {
      return path.join(repoPath, ".git");
    }
  }

  async isShallow(repoPath: string): Promise<boolean> {
    try {
      const shallowPath = path.join(repoPath, ".git", "shallow");
      await fs.access(shallowPath);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Get the fetch source for git commands.
   * If authenticatedUrl is provided, use it directly.
   * Otherwise, try to get a GitHub OAuth token and inject it into the origin URL.
   * Falls back to "origin" if no authentication is available.
   */
  private async getFetchSource(
    repoPath: string,
    authenticatedUrl?: string
  ): Promise<string> {
    if (authenticatedUrl) {
      return `"${authenticatedUrl}"`;
    }

    // Try to get the origin URL and inject auth token if available
    try {
      const { stdout } = await this.executeGitCommand(
        `git remote get-url origin`,
        { cwd: repoPath, suppressErrorLogging: true }
      );
      const originUrl = stdout.trim();

      // Only try to authenticate GitHub URLs
      if (originUrl.startsWith("https://github.com/")) {
        const token = await getGitHubOAuthToken();
        if (token) {
          const authenticatedOrigin = originUrl.replace(
            "https://github.com/",
            `https://x-access-token:${token}@github.com/`
          );
          return `"${authenticatedOrigin}"`;
        }
      }
    } catch (err) {
      serverLogger.error("Failed to get authenticated origin URL:", err);
    }

    return "origin";
  }

  /**
   * Prewarm commit history for fast ancestry (merge-base) operations.
   * Uses partial clone filter to avoid fetching blobs, and writes commit-graph.
   * Idempotent and rate-limited via a timestamp file under .git.
   * @param authenticatedUrl - Optional authenticated URL for private repos
   */
  async prewarmCommitHistory(
    repoPath: string,
    branch: string,
    ttlMs = 30 * 60 * 1000,
    authenticatedUrl?: string
  ): Promise<void> {
    // Validate branch name early to prevent injection attacks
    validateBranchName(branch);

    const gitDir = await this.getGitDir(repoPath);
    const stamp = path.join(gitDir, "cmux-prewarm.stamp");
    try {
      const s = await fs.stat(stamp).catch(() => null);
      if (s && Date.now() - s.mtimeMs < ttlMs) return;
    } catch {
      // ignore
    }

    try {
      // Configure partial clone promisor settings (safe if already set)
      await this.executeGitCommand(
        `git config core.partialclonefilter blob:none`,
        { cwd: repoPath }
      );
      await this.executeGitCommand(`git config remote.origin.promisor true`, {
        cwd: repoPath,
      });
    } catch (e) {
      serverLogger.warn("Failed to set partial clone promisor config:", e);
    }

    // Get authenticated fetch source for private repo support
    const fetchSource = await this.getFetchSource(repoPath, authenticatedUrl);

    const shallow = await this.isShallow(repoPath);
    try {
      if (shallow) {
        // Unshallow commit history, but keep blobs filtered
        await this.executeGitCommand(
          `git fetch --filter=blob:none --unshallow --prune ${fetchSource} ${branch}`,
          { cwd: repoPath }
        );
      } else {
        // Ensure we have latest commit graph for branch history
        await this.executeGitCommand(
          `git fetch --filter=blob:none --prune ${fetchSource} ${branch}`,
          { cwd: repoPath }
        );
      }
    } catch (e) {
      serverLogger.warn("Prewarm fetch failed:", e);
    }

    try {
      // Commit-graph speeds ancestry queries significantly
      await this.executeGitCommand(`git commit-graph write --reachable`, {
        cwd: repoPath,
      });
    } catch (e) {
      // Non-fatal
      serverLogger.warn("Commit-graph write failed:", e);
    }

    try {
      await fs.writeFile(stamp, `${new Date().toISOString()}\n`, "utf8");
    } catch {
      // ignore
    }
  }

  async updateRemoteBranchIfStale(
    repoPath: string,
    branch: string,
    ttlMs = 20_000,
    authenticatedUrl?: string
  ): Promise<void> {
    // Validate branch name early to prevent injection attacks
    validateBranchName(branch);

    const safeBranch = branch.replace(/[^a-zA-Z0-9._-]/g, "_");
    const gitDir = await this.getGitDir(repoPath);
    const stamp = path.join(gitDir, `cmux-fetch-${safeBranch}.stamp`);
    try {
      const s = await fs.stat(stamp).catch(() => null);
      if (s && Date.now() - s.mtimeMs < ttlMs) return;
    } catch {
      // ignore
    }
    try {
      // Get authenticated fetch source for private repo support
      const fetchSource = await this.getFetchSource(repoPath, authenticatedUrl);
      await this.removeStaleGitLock(repoPath, "shallow.lock", 15_000);
      await this.executeGitCommand(
        `git fetch --depth 1 ${fetchSource} +refs/heads/${branch}:refs/remotes/origin/${branch}`,
        { cwd: repoPath }
      );
      await fs.writeFile(stamp, `${Date.now()}\n`, "utf8");
    } catch (e) {
      serverLogger.warn(`Stale fetch for ${branch} failed:`, e);
    }
  }

  private async configureGitPullStrategy(repoPath: string): Promise<void> {
    const strategy =
      this.config.pullStrategy === "ff-only"
        ? "only"
        : this.config.pullStrategy;
    const cmd = `git config pull.${this.config.pullStrategy === "ff-only" ? "ff" : this.config.pullStrategy
      } ${strategy === "only" ? "only" : "true"}`;

    // Retry a few times to avoid transient .git/config lock contention
    const maxAttempts = 3;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await this.executeGitCommand(cmd, { cwd: repoPath });
        return;
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        const isLock = msg.includes("could not lock config file");
        if (attempt < maxAttempts && isLock) {
          await new Promise((r) => setTimeout(r, 100 * attempt));
          continue;
        }
        serverLogger.warn("Failed to configure git pull strategy:", error);
        return;
      }
    }
  }

  /**
   * Ensure a repository is cloned/fetched and ready to use.
   * @param repoUrl - URL used for git operations (may include auth token)
   * @param originPath - Local path for the bare/origin repository
   * @param branch - Optional branch to fetch
   * @param remoteUrl - Optional clean URL to store as the remote origin (without auth tokens).
   *                    If not provided, repoUrl is used. Use this to avoid persisting tokens in .git/config.
   */
  async ensureRepository(
    repoUrl: string,
    originPath: string,
    branch?: string,
    remoteUrl?: string
  ): Promise<void> {
    // Validate branch name early to prevent injection attacks
    if (branch) {
      validateBranchName(branch);
    }

    this.cleanupStaleOperations();

    // Use remoteUrl for storage if provided, otherwise use repoUrl
    const urlForRemote = remoteUrl ?? repoUrl;

    // Check if repo exists
    const repoExists = await this.checkIfRepoExists(originPath);

    if (!repoExists) {
      await this.handleCloneOperation(repoUrl, originPath, urlForRemote);
      // After cloning, set the remote HEAD reference
      try {
        await this.executeGitCommand(`git remote set-head origin -a`, {
          cwd: originPath,
        });
      } catch (error) {
        serverLogger.warn("Failed to set remote HEAD after clone:", error);
      }
    } else {
      // Configure git pull strategy for existing repos
      await this.configureGitPullStrategy(originPath);
      // Ensure a usable remote named 'origin' exists and points to the clean URL
      await this.ensureRemoteOrigin(originPath, urlForRemote);
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

  private async ensureRemoteOrigin(
    repoPath: string,
    repoUrl: string
  ): Promise<void> {
    try {
      // Check if 'origin' remote exists
      const { stdout } = await this.executeGitCommand(
        `git remote get-url origin`,
        { cwd: repoPath }
      );
      const currentUrl = stdout.trim();
      if (!currentUrl) {
        // Add 'origin' if missing
        await this.executeGitCommand(`git remote add origin "${repoUrl}"`, {
          cwd: repoPath,
        });
      } else if (currentUrl !== repoUrl) {
        // Keep remote up to date with expected URL
        await this.executeGitCommand(`git remote set-url origin "${repoUrl}"`, {
          cwd: repoPath,
        });
      }
    } catch (_e) {
      // If 'origin' does not exist, add it
      await this.executeGitCommand(`git remote add origin "${repoUrl}"`, {
        cwd: repoPath,
      });
    }

    // Best-effort: set remote HEAD so default branch detection works
    try {
      await this.executeGitCommand(`git remote set-head origin -a`, {
        cwd: repoPath,
      });
    } catch (err) {
      serverLogger.warn(
        `Failed to set remote HEAD for origin at ${repoPath}: ${String(err)}`
      );
    }
  }

  private async handleCloneOperation(
    repoUrl: string,
    originPath: string,
    remoteUrl: string
  ): Promise<void> {
    // Key the clone operation by both repo URL and destination path to avoid
    // reusing a clone into a different directory, which can cause ENOENT when
    // subsequent commands run in a non-existent cwd.
    const cloneKey = this.getCacheKey(repoUrl, `clone:${originPath}`);
    const existingClone = this.operations.get(cloneKey);

    if (
      existingClone &&
      Date.now() - existingClone.timestamp < this.config.operationCacheTime
    ) {
      serverLogger.info(`Reusing existing clone operation for ${sanitizeForLogging(repoUrl)}`);
      try {
        await existingClone.promise;
        // Existing operation succeeded, verify the repo actually exists
        const repoExists = await this.checkIfRepoExists(originPath);
        if (repoExists) {
          return; // Clone succeeded, we're done
        }
        // Clone "succeeded" but repo doesn't exist - fall through to retry
        serverLogger.warn(`Clone operation completed but repo not found at ${originPath}, retrying...`);
      } catch (err) {
        // Existing operation failed, fall through to retry
        serverLogger.warn(`Existing clone operation failed, retrying: ${err}`);
      } finally {
        // Remove the failed/stale entry
        this.operations.delete(cloneKey);
      }
    }

    // Either no existing operation, or existing operation failed - do the clone
    const clonePromise = this.cloneRepository(repoUrl, originPath, remoteUrl);
    this.operations.set(cloneKey, {
      promise: clonePromise,
      timestamp: Date.now(),
    });
    try {
      await clonePromise;
    } finally {
      // Remove entry so subsequent operations aren't skipped
      this.operations.delete(cloneKey);
    }
  }

  private async handleFetchOperation(
    repoUrl: string,
    originPath: string,
    branch: string
  ): Promise<void> {
    // Similarly, key fetch operations by branch and destination path so that
    // concurrent clones of the same repo in different origins don't conflict.
    const fetchKey = this.getCacheKey(repoUrl, `fetch:${branch}:${originPath}`);
    const existingFetch = this.operations.get(fetchKey);

    if (
      existingFetch &&
      Date.now() - existingFetch.timestamp < this.config.operationCacheTime
    ) {
      serverLogger.info(
        `Reusing existing fetch operation for branch ${branch}`
      );
      try {
        await existingFetch.promise;
        // Existing operation succeeded, verify we're on the right branch
        try {
          const currentBranch = await this.getCurrentBranch(originPath);
          if (currentBranch === branch) {
            return; // Fetch succeeded and we're on the right branch
          }
          // On wrong branch - fall through to retry
          serverLogger.warn(`Fetch completed but on branch ${currentBranch} instead of ${branch}, retrying...`);
        } catch {
          // Can't verify branch - fall through to retry
          serverLogger.warn(`Fetch completed but couldn't verify branch, retrying...`);
        }
      } catch (err) {
        // Existing operation failed, fall through to retry
        serverLogger.warn(`Existing fetch operation failed, retrying: ${err}`);
      } finally {
        // Remove the failed/stale entry
        this.operations.delete(fetchKey);
      }
    }

    // Either no existing operation, or existing operation failed - do the fetch
    const fetchPromise = this.fetchAndCheckoutBranch(originPath, branch, repoUrl);
    this.operations.set(fetchKey, {
      promise: fetchPromise,
      timestamp: Date.now(),
    });
    try {
      await fetchPromise;
    } finally {
      // Ensure the operation does not block subsequent real fetches
      this.operations.delete(fetchKey);
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
    originPath: string,
    remoteUrl: string
  ): Promise<void> {
    serverLogger.info(
      `Cloning repository with depth ${this.config.fetchDepth}...`
    );
    try {
      await this.executeGitCommand(
        `git clone --depth ${this.config.fetchDepth} "${repoUrl}" "${originPath}"`
      );
      serverLogger.info(`Successfully cloned repository`);

      // SECURITY: Reset the remote URL to the clean URL (without auth tokens)
      // to avoid persisting credentials in .git/config
      if (remoteUrl !== repoUrl) {
        try {
          await this.executeGitCommand(
            `git remote set-url origin "${remoteUrl}"`,
            { cwd: originPath }
          );
          serverLogger.info("Reset remote origin to clean URL");
        } catch (error) {
          serverLogger.warn("Failed to reset remote origin URL:", error);
        }
      }

      // Set the remote HEAD reference explicitly
      try {
        await this.executeGitCommand(`git remote set-head origin -a`, {
          cwd: originPath,
        });
      } catch (error) {
        serverLogger.warn("Failed to set remote HEAD reference:", error);
      }

      // Configure git pull strategy for the newly cloned repo
      await this.configureGitPullStrategy(originPath);

      // Set up git hooks
      await this.setupGitHooks(originPath);
    } catch (error) {
      serverLogger.error(`Failed to clone repository:`, error);
      throw error;
    }
  }

  async getCurrentBranch(repoPath: string): Promise<string> {
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
    } catch (_error) {
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
        serverLogger.warn(
          "Could not determine default branch, trying common names"
        );
      }

      // Try common default branch names
      const commonDefaults = ["main", "master", "dev", "develop"];
      for (const branch of commonDefaults) {
        try {
          await this.executeGitCommand(
            `git rev-parse --verify origin/${branch}`,
            { cwd: repoPath, encoding: "utf8", suppressErrorLogging: true }
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
    branch: string,
    authenticatedUrl?: string
  ): Promise<void> {
    // Defense in depth: validate branch name even in private methods
    validateBranchName(branch);

    const pullFlags =
      this.config.pullStrategy === "rebase"
        ? "--rebase"
        : this.config.pullStrategy === "ff-only"
          ? "--ff-only"
          : "";

    // Use authenticated URL if provided to support private repos
    const fetchSource = await this.getFetchSource(repoPath, authenticatedUrl);

    try {
      // Clear any stale shallow.lock before invoking a pull (pull may fetch)
      await this.removeStaleGitLock(repoPath, "shallow.lock", 15_000);
      await this.executeGitCommand(
        `git pull ${pullFlags} --depth ${this.config.fetchDepth} ${fetchSource} ${branch}`,
        { cwd: repoPath }
      );
      serverLogger.info(`Successfully pulled latest changes for ${branch}`);
    } catch (error) {
      // If pull fails due to conflicts, divergent or unrelated histories, try to recover
      if (
        error instanceof Error &&
        (error.message.includes("divergent branches") ||
          error.message.includes("conflict") ||
          error.message.includes("unrelated histories"))
      ) {
        serverLogger.warn(
          `Pull failed (likely conflicts/divergence). Attempting hard reset to ${branch}`
        );
        try {
          // Fetch the latest state using authenticated URL if provided
          await this.removeStaleGitLock(repoPath, "shallow.lock", 15_000);
          await this.executeGitCommand(
            `git fetch --depth ${this.config.fetchDepth} ${fetchSource} ${branch}`,
            { cwd: repoPath }
          );
          // Reset to FETCH_HEAD since fetching from a URL only updates FETCH_HEAD,
          // not the origin/<branch> remote-tracking ref
          await this.executeGitCommand(`git reset --hard FETCH_HEAD`, {
            cwd: repoPath,
          });
          serverLogger.info(`Successfully reset to FETCH_HEAD for ${branch}`);
        } catch (resetError) {
          serverLogger.error(
            `Failed to reset to FETCH_HEAD for ${branch}:`,
            resetError
          );
          throw resetError;
        }
      } else {
        throw error;
      }
    }
  }

  private async fetchAndCheckoutBranch(
    originPath: string,
    branch: string,
    authenticatedUrl?: string
  ): Promise<void> {
    serverLogger.info(`Fetching and checking out branch ${branch}...`);
    try {
      // Always fetch and checkout explicitly to reduce reliance on shell availability for rev-parse
      await this.switchToBranch(originPath, branch, authenticatedUrl);
      // Then pull latest changes for safety (fast and idempotent)
      await this.pullLatestChanges(originPath, branch, authenticatedUrl);
      serverLogger.info(`Successfully on branch ${branch}`);
    } catch (error) {
      serverLogger.error(`Failed to fetch/checkout branch ${branch}:`, error);
      // Propagate error so callers can surface it to users
      throw error;
    }
  }

  private async switchToBranch(
    repoPath: string,
    branch: string,
    authenticatedUrl?: string
  ): Promise<void> {
    // Defense in depth: validate branch name even in private methods
    validateBranchName(branch);

    // Fetch the specific branch and explicitly update the remote-tracking ref
    // even if the clone was created with --single-branch.
    // Force-update the remote-tracking ref to tolerate non-fast-forward updates
    // (e.g., when the remote branch was force-pushed). Using a leading '+'
    // mirrors the default fetch refspec behavior: +refs/heads/*:refs/remotes/origin/*
    // Use the authenticated URL if provided to support private repos (tokens not stored in .git/config)
    const fetchSource = authenticatedUrl ? `"${authenticatedUrl}"` : "origin";
    const fetchCmd = `git fetch --depth ${this.config.fetchDepth} ${fetchSource} +refs/heads/${branch}:refs/remotes/origin/${branch}`;
    // First, proactively clear stale shallow.lock if present (older than 15s)
    await this.removeStaleGitLock(repoPath, "shallow.lock", 15_000);
    try {
      await this.executeGitCommand(fetchCmd, { cwd: repoPath });
    } catch (e) {
      const msg = e instanceof Error ? `${e.message}\n${e || ""}` : String(e);
      const lockHit =
        msg.includes("shallow.lock") ||
        msg.includes("could not lock shallow") ||
        msg.includes("Another git process seems to be running");
      if (lockHit) {
        // Force-remove lock and retry with small backoff
        await this.removeStaleGitLock(repoPath, "shallow.lock", 0, true);
        await new Promise((r) => setTimeout(r, 150));
        await this.executeGitCommand(fetchCmd, { cwd: repoPath });
      } else {
        throw e;
      }
    }

    // Checkout the branch from the updated remote-tracking ref
    await this.executeGitCommand(`git checkout -B ${branch} origin/${branch}`, {
      cwd: repoPath,
    });
  }

  async worktreeExists(
    originPath: string,
    worktreePath: string
  ): Promise<boolean> {
    try {
      const { stdout } = await this.executeGitCommand(
        `git worktree list --porcelain`,
        { cwd: originPath }
      );
      // Parse worktree list properly to avoid false positives from partial path matching
      // e.g., "/path/to/foo" should not match "/path/to/foobar"
      const normalizedTargetPath = path.resolve(worktreePath);
      const lines = stdout.split("\n");
      for (const line of lines) {
        if (line.startsWith("worktree ")) {
          const registeredPath = path.resolve(line.substring(9)); // Remove 'worktree ' prefix
          if (registeredPath === normalizedTargetPath) {
            return true;
          }
        }
      }
      return false;
    } catch {
      return false;
    }
  }

  async removeWorktree(
    originPath: string,
    worktreePath: string
  ): Promise<void> {
    try {
      await this.executeGitCommand(
        `git worktree remove "${worktreePath}" --force`,
        { cwd: originPath }
      );
      serverLogger.info(`Removed worktree at ${worktreePath}`);
    } catch (error) {
      serverLogger.warn(`Failed to remove worktree at ${worktreePath}:`, error);
    }
  }

  async findWorktreeUsingBranch(
    originPath: string,
    branchName: string
  ): Promise<string | null> {
    try {
      const { stdout } = await this.executeGitCommand(
        `git worktree list --porcelain`,
        { cwd: originPath }
      );

      // Parse worktree list to find which worktree uses this branch
      const lines = stdout.split("\n");
      let currentWorktreePath: string | null = null;

      for (const line of lines) {
        if (line.startsWith("worktree ")) {
          // Normalize the path to resolve symlinks and ensure consistent comparison
          currentWorktreePath = path.resolve(line.substring(9)); // Remove 'worktree ' prefix
        } else if (
          line.startsWith("branch refs/heads/") &&
          currentWorktreePath
        ) {
          const branch = line.substring(18); // Remove 'branch refs/heads/' prefix
          if (branch === branchName) {
            return currentWorktreePath;
          }
        }
      }

      return null;
    } catch {
      return null;
    }
  }

  async createWorktree(
    originPath: string,
    worktreePath: string,
    branchName: string,
    baseBranch: string = "main",
    authenticatedUrl?: string
  ): Promise<string> {
    // Validate branch names early to prevent injection attacks
    validateBranchName(branchName);
    validateBranchName(baseBranch);

    // In-process lock keyed by repo+branch to avoid concurrent add for same branch
    const inProcessLockKey = `${originPath}::${branchName}`;
    const existingLock = this.worktreeLocks.get(inProcessLockKey);
    if (existingLock) {
      serverLogger.info(
        `Waiting for existing worktree operation on ${originPath} (${branchName})...`
      );
      // Wait for existing lock with timeout to prevent indefinite waits
      const lockTimeout = CLONE_FETCH_TIMEOUT_MS; // 5 minutes max wait
      const timeoutPromise = new Promise<void>((_, reject) => {
        setTimeout(() => reject(new Error(`Worktree lock timeout after ${lockTimeout}ms for ${branchName}`)), lockTimeout);
      });
      try {
        await Promise.race([existingLock, timeoutPromise]);
      } catch (err) {
        serverLogger.warn(`Worktree lock wait failed or timed out, proceeding anyway: ${err}`);
        // Remove the stale lock to prevent future waits
        this.worktreeLocks.delete(inProcessLockKey);
      }
    }

    let releaseInProcessLock: () => void;
    const lockPromise = new Promise<void>((resolve) => {
      releaseInProcessLock = () => {
        this.worktreeLocks.delete(inProcessLockKey);
        resolve();
      };
    });
    this.worktreeLocks.set(inProcessLockKey, lockPromise);

    serverLogger.info(`Creating worktree with branch ${branchName}...`);
    try {
      // Get authenticated fetch source for private repo support
      const fetchSource = await this.getFetchSource(originPath, authenticatedUrl);

      // Before creating the worktree, try to fetch the remote branch ref for this branch
      // so that if the agent pushed it, we base the worktree on the pushed commits
      // rather than creating a fresh branch off the base.
      const fetchRemoteBranchRef = async (): Promise<boolean> => {
        // Proactively clear shallow.lock to avoid fetch contention
        await this.removeStaleGitLock(originPath, "shallow.lock", 15_000);
        const fetchCmd = `git fetch --depth ${this.config.fetchDepth} ${fetchSource} +refs/heads/${branchName}:refs/remotes/origin/${branchName}`;
        try {
          await this.executeGitCommand(fetchCmd, { cwd: originPath });
        } catch (e) {
          const msg =
            e instanceof Error ? `${e.message}\n${e || ""}` : String(e);
          const lockHit =
            msg.includes("shallow.lock") ||
            msg.includes("could not lock shallow") ||
            msg.includes("Another git process seems to be running");
          if (lockHit) {
            // Force-remove lock and retry once with a short backoff
            await this.removeStaleGitLock(originPath, "shallow.lock", 0, true);
            await new Promise((r) => setTimeout(r, 150));
            await this.executeGitCommand(fetchCmd, { cwd: originPath });
          } else {
            // If fetch fails for other reasons (e.g., branch does not exist remotely),
            // just continue and fall back to base branch creation below.
            return false;
          }
        }
        // Validate that the remote-tracking ref exists now
        try {
          await this.executeGitCommand(
            `git rev-parse --verify refs/remotes/origin/${branchName}`,
            { cwd: originPath, suppressErrorLogging: true }
          );
          return true;
        } catch {
          return false;
        }
      };

      const remoteBranchAvailable = await fetchRemoteBranchRef();
      // If the branch is already attached to a worktree, reuse that path to avoid duplicates
      const preexistingPath = await this.findWorktreeUsingBranch(
        originPath,
        branchName
      );
      if (preexistingPath) {
        if (preexistingPath !== worktreePath) {
          serverLogger.info(
            `Branch ${branchName} is attached to ${preexistingPath}; moving to ${worktreePath}`
          );
          try {
            await this.removeWorktree(originPath, preexistingPath);
          } catch (e) {
            serverLogger.warn(
              `Failed to remove old worktree ${preexistingPath} for ${branchName}:`,
              e
            );
          }
          try {
            await fs.rm(preexistingPath, { recursive: true, force: true });
          } catch {
            // ignore
          }
        } else {
          serverLogger.info(
            `Branch ${branchName} already attached to worktree at ${preexistingPath}; reusing`
          );
          // Best-effort ensure branch tracking + hooks
          await this.ensureWorktreeConfigured(preexistingPath, branchName);
          return preexistingPath;
        }
      }
      // First check if the branch is already used by another worktree
      const existingWorktreePath = await this.findWorktreeUsingBranch(
        originPath,
        branchName
      );
      if (existingWorktreePath && existingWorktreePath !== worktreePath) {
        // Another process may have just created it while we were waiting on lock
        // Align with requested path by removing the other worktree and creating ours
        serverLogger.info(
          `Branch ${branchName} attached at ${existingWorktreePath}; replacing with ${worktreePath}`
        );
        try {
          await this.removeWorktree(originPath, existingWorktreePath);
        } catch (e) {
          serverLogger.warn(
            `Failed to remove concurrent worktree ${existingWorktreePath}:`,
            e
          );
        }
        try {
          await fs.rm(existingWorktreePath, { recursive: true, force: true });
        } catch {
          // Do not block the other worktree from being created
        }
      }

      // Check if the local branch already exists
      let branchExists = false;
      try {
        await this.executeGitCommand(
          `git rev-parse --verify refs/heads/${branchName}`,
          { cwd: originPath, suppressErrorLogging: true }
        );
        branchExists = true;
      } catch {
        // Branch doesn't exist, which is fine
      }

      if (branchExists) {
        // Branch exists. If the intended worktree path already exists/registered,
        // treat this as a no-op and proceed to configure.
        const alreadyRegistered = await this.worktreeExists(
          originPath,
          worktreePath
        );
        if (alreadyRegistered) {
          serverLogger.info(
            `Worktree for ${branchName} already exists at ${worktreePath}; skipping add`
          );
        } else {
          // Create worktree without -b flag
          serverLogger.info(
            `Branch ${branchName} already exists, creating worktree without new branch`
          );
          await this.executeGitCommand(
            `git worktree add "${worktreePath}" ${branchName}`,
            { cwd: originPath }
          );
        }
      } else if (remoteBranchAvailable) {
        // No local branch yet, but we do have a remote-tracking branch.
        // Create/reset the local branch to that remote and attach the worktree.
        serverLogger.info(
          `Remote branch origin/${branchName} found; creating worktree tracking remote`
        );
        await this.executeGitCommand(
          `git worktree add -B "${branchName}" "${worktreePath}" origin/${branchName}`,
          { cwd: originPath }
        );
      } else {
        // Neither local nor remote branch exists; create a new branch from base
        await this.executeGitCommand(
          `git worktree add -b "${branchName}" "${worktreePath}" origin/${baseBranch}`,
          { cwd: originPath }
        );
      }
      serverLogger.info(`Successfully created worktree at ${worktreePath}`);

      // Set up branch configuration to push to the same name on remote
      // Use a serial approach for config commands to avoid lock conflicts
      await this.configureWorktreeBranch(worktreePath, branchName);

      // Set up git hooks in the worktree
      await this.setupGitHooks(worktreePath);
      return worktreePath;
    } catch (error) {
      // If another process just created the worktree, treat as success.
      if (error instanceof Error) {
        const msg = error.message.toLowerCase();
        const alreadyExists =
          msg.includes("already exists") ||
          msg.includes("is already checked out") ||
          (msg.includes("worktree add") && msg.includes("file exists"));
        if (alreadyExists) {
          // Re-verify actual worktree location for this branch and reuse it
          const actualPath =
            (await this.findWorktreeUsingBranch(originPath, branchName)) ||
            worktreePath;
          serverLogger.info(
            `Worktree already present at ${actualPath}; ensuring configuration`
          );
          try {
            await this.ensureWorktreeConfigured(actualPath, branchName);
          } catch (e) {
            serverLogger.warn(
              `Post-existence configuration failed for ${actualPath}:`,
              e
            );
          }
          return actualPath;
        }
      }
      // Provide a clearer error message when the base branch does not exist
      if (error instanceof Error) {
        const msg = error.message.toLowerCase();
        if (
          msg.includes("invalid reference") ||
          msg.includes("couldn't find remote ref") ||
          msg.includes("not a valid object name") ||
          msg.includes("fatal: invalid reference")
        ) {
          throw new Error(
            `Base branch 'origin/${baseBranch}' not found. Please select an existing branch.`
          );
        }
      }
      throw error;
    } finally {
      releaseInProcessLock!();
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

      // Configure VS Code git extension to show diffs from main branch
      await this.executeGitCommand(
        `git config vscode.gitSCM.defaultViewMode tree`,
        { cwd: worktreePath }
      );
      await this.executeGitCommand(
        `git config vscode.gitSCM.showChangesSinceLastPublish true`,
        { cwd: worktreePath }
      );
      // Set main as the base branch for comparisons
      await this.executeGitCommand(`git config diff.base main`, {
        cwd: worktreePath,
      });
      await this.executeGitCommand(`git config merge.base main`, {
        cwd: worktreePath,
      });

      serverLogger.info(
        `Configured branch ${branchName} to track origin/${branchName} when pushed and show diffs from main`
      );
    } catch (error) {
      serverLogger.warn(
        `Failed to configure branch tracking for ${branchName}:`,
        error
      );
    }
  }

  // Method to update configuration at runtime
  updateConfig(config: Partial<GitConfig>): void {
    this.config = { ...this.config, ...config };
  }

  // Public helper to ensure a worktree has proper branch tracking and hooks
  async ensureWorktreeConfigured(
    worktreePath: string,
    branchName: string
  ): Promise<void> {
    await this.configureWorktreeBranch(worktreePath, branchName);
    await this.setupGitHooks(worktreePath);
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
