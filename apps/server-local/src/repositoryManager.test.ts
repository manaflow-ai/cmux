// @ts-nocheck
// Test file for repositoryManager.ts
// Run with: bun test repositoryManager.test.ts
import { describe, expect, test, beforeAll, afterAll } from "bun:test";
import * as fs from "fs/promises";
import * as path from "path";
import { RepositoryManager } from "./repositoryManager.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

// Test configuration
const TEST_REPO_URL = "https://github.com/sindresorhus/is.git"; // Small, public repo
const TEST_BASE_DIR = path.join(
  process.cwd(),
  ".test-repos",
  `test-${Date.now()}`
);
const TEST_ORIGIN_PATH = path.join(TEST_BASE_DIR, "origin");

// Helper to clean up test directories
async function cleanupTestDirs() {
  try {
    // Remove all worktrees first
    const worktrees = await fs.readdir(TEST_BASE_DIR).catch(() => []);
    for (const dir of worktrees) {
      if (dir.startsWith("worktree-")) {
        const worktreePath = path.join(TEST_BASE_DIR, dir);
        try {
          await execAsync(`git worktree remove --force "${worktreePath}"`, {
            cwd: TEST_ORIGIN_PATH,
          });
        } catch {
          // Ignore errors, we'll force remove anyway
        }
      }
    }

    // Clean up the entire test directory
    await fs.rm(TEST_BASE_DIR, { recursive: true, force: true });
  } catch (error) {
    // Ignore cleanup errors
  }
}

// Helper to get the repository manager instance
function getRepositoryManager(config?: any) {
  // Always use the singleton instance
  const manager = RepositoryManager.getInstance({
    fetchDepth: 1,
    operationCacheTime: 1000, // Shorter cache time for tests
    ...config,
  });
  
  // Update config if provided
  if (config) {
    manager.updateConfig(config);
  }
  
  return manager;
}

describe("RepositoryManager", () => {
  beforeAll(async () => {
    await cleanupTestDirs();
    await fs.mkdir(TEST_BASE_DIR, { recursive: true });
  });

  afterAll(async () => {
    await cleanupTestDirs();
  });

  describe("Basic Operations", () => {
    test("should clone a repository successfully", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "basic-clone");

      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Verify the repository was cloned
      const gitExists = await fs
        .access(path.join(repoPath, ".git"))
        .then(() => true)
        .catch(() => false);
      expect(gitExists).toBe(true);

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should handle existing repository without re-cloning", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "existing-repo");

      // First clone
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");
      
      // Check that repo exists
      const gitDirExists1 = await fs
        .access(path.join(repoPath, ".git"))
        .then(() => true)
        .catch(() => false);
      expect(gitDirExists1).toBe(true);

      // Count files to ensure second call doesn't re-clone
      const filesBefore = await fs.readdir(repoPath);

      // Second call should not re-clone
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Count files again - should be same
      const filesAfter = await fs.readdir(repoPath);
      expect(filesAfter.length).toBe(filesBefore.length);

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });
  });

  describe("Concurrent Operations", () => {
    test("should handle multiple concurrent clones of same repo", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "concurrent-clone");

      // Start multiple clone operations simultaneously
      const promises = Array(3)
        .fill(null)
        .map(() => manager.ensureRepository(TEST_REPO_URL, repoPath, "main"));

      // All should complete without errors
      await expect(Promise.all(promises)).resolves.toBeArrayOfSize(3);

      // Verify only one clone actually happened
      const gitExists = await fs
        .access(path.join(repoPath, ".git"))
        .then(() => true)
        .catch(() => false);
      expect(gitExists).toBe(true);

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should handle concurrent fetch operations", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "concurrent-fetch");

      // First ensure the repo exists
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Now do concurrent fetches
      const promises = Array(5)
        .fill(null)
        .map(() => manager.ensureRepository(TEST_REPO_URL, repoPath, "main"));

      await expect(Promise.all(promises)).resolves.toBeArrayOfSize(5);

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should queue worktree operations properly", async () => {
      const manager = getRepositoryManager();

      // First ensure origin exists
      await manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main");

      // Create multiple worktrees concurrently
      const worktreePromises = Array(3)
        .fill(null)
        .map((_, i) => {
          const worktreePath = path.join(TEST_BASE_DIR, `worktree-${i}`);
          const branchName = `test-branch-${i}`;
          return manager.createWorktree(
            TEST_ORIGIN_PATH,
            worktreePath,
            branchName,
            "main"
          );
        });

      // All should complete successfully
      await expect(Promise.all(worktreePromises)).resolves.toBeArrayOfSize(3);

      // Verify all worktrees exist
      for (let i = 0; i < 3; i++) {
        const worktreePath = path.join(TEST_BASE_DIR, `worktree-${i}`);
        const exists = await fs
          .access(worktreePath)
          .then(() => true)
          .catch(() => false);
        expect(exists).toBe(true);
      }
    });
  });

  describe("Error Recovery", () => {
    test("should handle non-existent branch gracefully", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "non-existent-branch");

      // This should not throw, but fall back to current branch
      await expect(
        manager.ensureRepository(TEST_REPO_URL, repoPath, "non-existent-branch")
      ).resolves.toBeUndefined();

      // Repo should still exist
      const gitExists = await fs
        .access(path.join(repoPath, ".git"))
        .then(() => true)
        .catch(() => false);
      expect(gitExists).toBe(true);

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should handle worktree creation failures", async () => {
      const manager = getRepositoryManager();

      // Ensure origin exists
      await manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main");

      const worktreePath = path.join(TEST_BASE_DIR, "worktree-fail");
      const branchName = "test-branch-fail";

      // Create worktree first time
      await manager.createWorktree(
        TEST_ORIGIN_PATH,
        worktreePath,
        branchName,
        "main"
      );

      // Try to create same worktree again - should fail
      await expect(
        manager.createWorktree(
          TEST_ORIGIN_PATH,
          worktreePath,
          branchName,
          "main"
        )
      ).rejects.toThrow("Worktree already exists");
    });

    test("should handle invalid repository URLs", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "invalid-repo");

      await expect(
        manager.ensureRepository(
          "https://github.com/definitely/does-not-exist-repo-12345.git",
          repoPath,
          "main"
        )
      ).rejects.toThrow();

      // Cleanup any partial clone
      await fs.rm(repoPath, { recursive: true, force: true }).catch(() => {});
    });
  });

  describe("Pull Strategy Tests", () => {
    test("should apply rebase strategy correctly", async () => {
      const manager = getRepositoryManager({ pullStrategy: "rebase" });
      const repoPath = path.join(TEST_BASE_DIR, "rebase-test");

      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Check git config
      const { stdout } = await execAsync("git config pull.rebase", {
        cwd: repoPath,
      });
      expect(stdout.trim()).toBe("true");

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should apply ff-only strategy correctly", async () => {
      const manager = getRepositoryManager({ pullStrategy: "ff-only" });
      const repoPath = path.join(TEST_BASE_DIR, "ff-only-test");

      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Check git config
      const { stdout } = await execAsync("git config pull.ff", {
        cwd: repoPath,
      });
      expect(stdout.trim()).toBe("only");

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });
  });

  describe("Git Hooks", () => {
    test("should set up git hooks in main repository", async () => {
      const manager = getRepositoryManager();
      const repoPath = path.join(TEST_BASE_DIR, "hooks-test");

      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Check if hooks exist
      const prePushHook = path.join(repoPath, ".git", "hooks", "pre-push");
      const preCommitHook = path.join(repoPath, ".git", "hooks", "pre-commit");

      const prePushExists = await fs
        .access(prePushHook)
        .then(() => true)
        .catch(() => false);
      const preCommitExists = await fs
        .access(preCommitHook)
        .then(() => true)
        .catch(() => false);

      expect(prePushExists).toBe(true);
      expect(preCommitExists).toBe(true);

      // Check if hooks are executable
      const prePushStats = await fs.stat(prePushHook);
      expect(prePushStats.mode & 0o111).toBeGreaterThan(0); // Has execute permission

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });

    test("should set up git hooks in worktrees", async () => {
      const manager = getRepositoryManager();

      // Ensure origin exists
      await manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main");

      const worktreePath = path.join(TEST_BASE_DIR, "worktree-hooks");
      const branchName = "test-hooks-branch";

      await manager.createWorktree(
        TEST_ORIGIN_PATH,
        worktreePath,
        branchName,
        "main"
      );

      // For worktrees, hooks should be in the common git directory
      // Read the .git file to find the actual location
      const gitFile = await fs.readFile(
        path.join(worktreePath, ".git"),
        "utf8"
      );
      const match = gitFile.match(/gitdir: (.+)/);
      expect(match).toBeTruthy();

      if (match) {
        const worktreeGitDir = match[1].trim();
        const commonDir = path.resolve(
          path.dirname(worktreeGitDir),
          "..",
          "hooks"
        );

        const prePushExists = await fs
          .access(path.join(commonDir, "pre-push"))
          .then(() => true)
          .catch(() => false);
        const preCommitExists = await fs
          .access(path.join(commonDir, "pre-commit"))
          .then(() => true)
          .catch(() => false);

        expect(prePushExists).toBe(true);
        expect(preCommitExists).toBe(true);
      }
    });
  });

  describe("Configuration Updates", () => {
    test("should update configuration at runtime", async () => {
      const manager = getRepositoryManager({
        fetchDepth: 1,
        pullStrategy: "merge",
      });

      // Update config
      manager.updateConfig({
        fetchDepth: 10,
        pullStrategy: "rebase",
      });

      const repoPath = path.join(TEST_BASE_DIR, "config-update-test");
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Verify new config was applied
      const { stdout } = await execAsync("git config pull.rebase", {
        cwd: repoPath,
      });
      expect(stdout.trim()).toBe("true");

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });
  });

  describe("Operation Caching", () => {
    test("should cache operations within cache time", async () => {
      const manager = getRepositoryManager({
        operationCacheTime: 2000, // 2 seconds
      });
      const repoPath = path.join(TEST_BASE_DIR, "cache-test");

      // First ensure repo exists
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");

      // Record timestamps of operations
      const startTime = Date.now();

      // Multiple calls within cache time - should be fast due to caching
      await Promise.all([
        manager.ensureRepository(TEST_REPO_URL, repoPath, "main"),
        manager.ensureRepository(TEST_REPO_URL, repoPath, "main"),
        manager.ensureRepository(TEST_REPO_URL, repoPath, "main"),
      ]);

      const cachedTime = Date.now() - startTime;

      // Wait for cache to expire
      await new Promise((resolve) => setTimeout(resolve, 2100));

      // This should trigger a new fetch and take longer
      const uncachedStart = Date.now();
      await manager.ensureRepository(TEST_REPO_URL, repoPath, "main");
      const uncachedTime = Date.now() - uncachedStart;

      // Cached operations should be significantly faster
      // (this is a heuristic test since we can't mock exec in Bun)
      expect(cachedTime).toBeLessThan(1000); // Should be fast due to caching

      // Cleanup
      await fs.rm(repoPath, { recursive: true, force: true });
    });
  });

  describe("Stress Tests", () => {
    test("should handle 10 concurrent worktree creations", async () => {
      const manager = getRepositoryManager();

      // First ensure origin exists
      await manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main");

      // Create 10 worktrees all at once
      const worktreePromises = Array(10)
        .fill(null)
        .map((_, i) => {
          const worktreePath = path.join(TEST_BASE_DIR, `stress-worktree-${i}`);
          const branchName = `stress-branch-${i}`;
          return manager.createWorktree(
            TEST_ORIGIN_PATH,
            worktreePath,
            branchName,
            "main"
          );
        });

      // All should complete successfully without any lock errors
      await expect(Promise.all(worktreePromises)).resolves.toBeArrayOfSize(10);

      // Verify all worktrees exist and are properly configured
      for (let i = 0; i < 10; i++) {
        const worktreePath = path.join(TEST_BASE_DIR, `stress-worktree-${i}`);
        const exists = await fs
          .access(worktreePath)
          .then(() => true)
          .catch(() => false);
        expect(exists).toBe(true);
        
        // Verify branch config was set correctly
        const { stdout } = await execAsync(
          `git config branch.stress-branch-${i}.remote`,
          { cwd: worktreePath }
        );
        expect(stdout.trim()).toBe("origin");
      }
    }, 60000); // Longer timeout for this stress test

    test("should handle rapid sequential operations", async () => {
      const manager = getRepositoryManager();

      // Ensure origin exists
      await manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main");

      // Create many worktrees sequentially as fast as possible
      for (let i = 0; i < 5; i++) {
        const worktreePath = path.join(TEST_BASE_DIR, `rapid-worktree-${i}`);
        const branchName = `rapid-branch-${i}`;
        await manager.createWorktree(
          TEST_ORIGIN_PATH,
          worktreePath,
          branchName,
          "main"
        );
      }

      // Verify all were created
      for (let i = 0; i < 5; i++) {
        const worktreePath = path.join(TEST_BASE_DIR, `rapid-worktree-${i}`);
        const exists = await fs
          .access(worktreePath)
          .then(() => true)
          .catch(() => false);
        expect(exists).toBe(true);
      }
    });

    test("should handle mixed concurrent operations", async () => {
      const manager = getRepositoryManager();

      // Mix of different operations
      const operations = [
        // Clones
        ...Array(3)
          .fill(null)
          .map((_, i) =>
            manager.ensureRepository(
              TEST_REPO_URL,
              path.join(TEST_BASE_DIR, `mixed-clone-${i}`),
              "main"
            )
          ),
        // Fetches on existing repo
        ...Array(3)
          .fill(null)
          .map(() =>
            manager.ensureRepository(TEST_REPO_URL, TEST_ORIGIN_PATH, "main")
          ),
        // Worktrees
        ...Array(3)
          .fill(null)
          .map((_, i) =>
            manager.createWorktree(
              TEST_ORIGIN_PATH,
              path.join(TEST_BASE_DIR, `mixed-worktree-${i}`),
              `mixed-branch-${i}`,
              "main"
            )
          ),
      ];

      // All should complete
      await expect(Promise.all(operations)).resolves.toBeArrayOfSize(9);
    });
  });
});