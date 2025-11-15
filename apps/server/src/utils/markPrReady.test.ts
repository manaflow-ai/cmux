import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { getGitHubToken } from "./getGitHubToken";
import { markPrReady } from "./markPrReady";
import { getOctokit } from "./octokit";

// Temporarily disabled due to external GitHub API rate limits.
// Re-enable when sufficient quota is available.
describe.skip("markPrReady E2E Tests", () => {
  let githubToken: string;
  const TEST_REPO_OWNER = "manaflow-ai";
  const TEST_REPO_NAME = "cmux-testing";
  let octokit: ReturnType<typeof getOctokit>;
  let defaultBranch = "main";
  const testPrsToCleanup: number[] = [];

  beforeAll(async () => {
    // Get GitHub token
    githubToken = (await getGitHubToken()) || "";
    if (!githubToken) {
      throw new Error("GitHub token not found. Please configure it first.");
    }
    octokit = getOctokit(githubToken);

    // Get the default branch for the test repo
    try {
      const { data: repo } = await octokit.rest.repos.get({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
      });
      defaultBranch = repo.default_branch;
      console.log(`Using default branch: ${defaultBranch}`);

      // Ensure the repo has at least one commit
      try {
        await octokit.rest.repos.getContent({
          owner: TEST_REPO_OWNER,
          repo: TEST_REPO_NAME,
          path: "",
        });
      } catch (_error) {
        // If the repo is empty, create an initial commit
        console.log("Creating initial commit in test repo...");
        const testContent = Buffer.from(
          "# Test Repository\n\nThis is a test repository for cmux e2e tests."
        ).toString("base64");
        await octokit.rest.repos.createOrUpdateFileContents({
          owner: TEST_REPO_OWNER,
          repo: TEST_REPO_NAME,
          path: "README.md",
          message: "Initial commit",
          content: testContent,
          branch: defaultBranch,
        });
      }
    } catch (error) {
      console.error("Error setting up test repository:", error);
      throw error;
    }
  }, 60000);

  afterAll(async () => {
    // Clean up all test PRs
    if (testPrsToCleanup.length > 0 && githubToken) {
      await Promise.all(
        testPrsToCleanup.map(async (prNumber) => {
          try {
            await octokit.rest.pulls.update({
              owner: TEST_REPO_OWNER,
              repo: TEST_REPO_NAME,
              pull_number: prNumber,
              state: "closed",
            });
            console.log(`Cleaned up test PR #${prNumber}`);
          } catch (error) {
            console.error(`Failed to clean up test PR #${prNumber}:`, error);
          }
        })
      );
    }
  });

  it.concurrent("should handle non-existent PR with 404 error", async () => {
    const result = await markPrReady(
      githubToken,
      TEST_REPO_OWNER,
      TEST_REPO_NAME,
      99999 // Non-existent PR number
    );

    expect(result.success).toBe(false);
    expect(result.error).toContain("not found");
  });

  it("should mark a draft PR as ready for review", async () => {
    // Create a test branch and draft PR with unique timestamp
    const uniqueId = `${Date.now()}-${Math.random().toString(36).substring(7)}`;
    const testBranch = `test-mark-pr-ready-draft-${uniqueId}`;

    try {
      // Get the default branch's SHA
      const { data: branchData } = await octokit.rest.repos.getBranch({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        branch: defaultBranch,
      });

      // Create a new branch
      await octokit.rest.git.createRef({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        ref: `refs/heads/${testBranch}`,
        sha: branchData.commit.sha,
      });

      // Create a test file
      const testContent = Buffer.from(
        `Test content for markPrReady test\n${new Date().toISOString()}`
      ).toString("base64");
      await octokit.rest.repos.createOrUpdateFileContents({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        path: `test-files/mark-pr-ready-${Date.now()}.txt`,
        message: "Test commit for markPrReady",
        content: testContent,
        branch: testBranch,
      });

      // Create a draft PR
      const { data: pr } = await octokit.rest.pulls.create({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        title: `Test PR for markPrReady - ${Date.now()}`,
        body: "This is a test PR for the markPrReady function",
        head: testBranch,
        base: defaultBranch,
        draft: true,
      });

      testPrsToCleanup.push(pr.number); // For cleanup in afterAll
      expect(pr.draft).toBe(true);

      // Test marking it as ready
      const result = await markPrReady(
        githubToken,
        TEST_REPO_OWNER,
        TEST_REPO_NAME,
        pr.number
      );

      expect(result.success).toBe(true);
      expect(result.error).toBeUndefined();

      // Verify the PR is no longer a draft
      const { data: updatedPr } = await octokit.rest.pulls.get({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        pull_number: pr.number,
      });

      expect(updatedPr.draft).toBe(false);
    } finally {
      // Clean up the branch
      try {
        await octokit.rest.git.deleteRef({
          owner: TEST_REPO_OWNER,
          repo: TEST_REPO_NAME,
          ref: `heads/${testBranch}`,
        });
      } catch (error) {
        console.error(`Failed to delete test branch ${testBranch}:`, error);
      }
    }
  }, 30000); // 30 second timeout for this test

  it("should handle already-ready PR gracefully", async () => {
    // Create a non-draft PR with unique timestamp
    const uniqueId = `${Date.now()}-${Math.random().toString(36).substring(7)}`;
    const testBranch = `test-mark-pr-ready-ready-${uniqueId}`;

    try {
      // Get the default branch's SHA
      const { data: branchData } = await octokit.rest.repos.getBranch({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        branch: defaultBranch,
      });

      // Create a new branch
      await octokit.rest.git.createRef({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        ref: `refs/heads/${testBranch}`,
        sha: branchData.commit.sha,
      });

      // Create a test file
      const testContent = Buffer.from(
        `Test content for already-ready PR\n${new Date().toISOString()}`
      ).toString("base64");
      await octokit.rest.repos.createOrUpdateFileContents({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        path: `test-files/already-ready-${Date.now()}.txt`,
        message: "Test commit for already-ready PR",
        content: testContent,
        branch: testBranch,
      });

      // Create a non-draft PR
      const { data: pr } = await octokit.rest.pulls.create({
        owner: TEST_REPO_OWNER,
        repo: TEST_REPO_NAME,
        title: `Test Ready PR for markPrReady - ${Date.now()}`,
        body: "This is a test PR that's already ready",
        head: testBranch,
        base: defaultBranch,
        draft: false,
      });

      testPrsToCleanup.push(pr.number); // For cleanup in afterAll
      expect(pr.draft).toBe(false);

      // Test marking an already-ready PR as ready
      const result = await markPrReady(
        githubToken,
        TEST_REPO_OWNER,
        TEST_REPO_NAME,
        pr.number
      );

      expect(result.success).toBe(true);
      expect(result.error).toBeUndefined();
    } finally {
      // Clean up the branch
      try {
        await octokit.rest.git.deleteRef({
          owner: TEST_REPO_OWNER,
          repo: TEST_REPO_NAME,
          ref: `heads/${testBranch}`,
        });
      } catch (error) {
        console.error(`Failed to delete test branch ${testBranch}:`, error);
      }
    }
  }, 30000);

  it.concurrent("should handle invalid repository gracefully", async () => {
    const result = await markPrReady(
      githubToken,
      "invalid-owner-that-does-not-exist",
      "invalid-repo-that-does-not-exist",
      1
    );

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
  });

  it.concurrent("should handle invalid token gracefully", async () => {
    const result = await markPrReady(
      "invalid-token",
      TEST_REPO_OWNER,
      TEST_REPO_NAME,
      1
    );

    expect(result.success).toBe(false);
    expect(result.error).toContain("Authentication failed");
  });
});
