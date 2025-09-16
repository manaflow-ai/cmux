import { api } from "@cmux/convex/api";
import { ghApi } from "../ghApi.js";
import { listRemoteBranches } from "../native/git.js";
import { getConvex } from "./convexClient.js";
import { serverLogger } from "./fileLogger.js";
import { getAuthToken } from "./requestContext.js";

export async function refreshGitHubData({
  teamSlugOrId,
  fetchBranches = false,
}: {
  teamSlugOrId: string;
  fetchBranches?: boolean;
}) {
  try {
    serverLogger.info(
      `Starting GitHub data refresh (fetchBranches: ${fetchBranches})...`
    );

    // Check if we have auth context
    const authToken = getAuthToken();
    if (!authToken) {
      serverLogger.error("No auth token in context for refreshGitHubData");
      throw new Error("Authentication required for GitHub data refresh");
    }

    // Try to get current user info
    let username: string;
    let userRepos: string[];
    let orgs: string[];

    try {
      [username, userRepos, orgs] = await Promise.all([
        ghApi.getUser(),
        ghApi.getUserRepos(),
        ghApi.getUserOrgs(),
      ]);
    } catch (error) {
      // Check if this is an authentication error
      if (error instanceof Error && "status" in error && error.status === 401) {
        serverLogger.info(
          "No GitHub authentication found, skipping repository refresh"
        );
        return;
      }
      throw error;
    }

    // Fetch repos for all orgs in parallel
    const orgReposPromises = orgs.map(async (org) => ({
      org,
      repos: await ghApi.getOrgRepos(org),
    }));

    const orgReposResults = await Promise.all(orgReposPromises);

    // Combine all repos
    const allRepos: { org: string; repos: string[] }[] = [
      {
        org: username,
        repos: userRepos.filter((repo) => repo.startsWith(`${username}/`)),
      },
      ...orgReposResults,
    ];

    // Prepare all repos for insertion
    const reposToInsert = allRepos.flatMap((orgData) =>
      orgData.repos.map((repo) => ({
        fullName: repo,
        org: orgData.org,
        name: repo.split("/")[1],
        gitRemote: `https://github.com/${repo}.git`,
        provider: "github" as const,
      }))
    );

    if (reposToInsert.length > 0) {
      serverLogger.info(
        `Refreshing repository data with ${reposToInsert.length} repos...`
      );
      // The mutation now handles deduplication
      await getConvex().mutation(api.github.bulkInsertRepos, {
        teamSlugOrId,
        repos: reposToInsert,
      });
      serverLogger.info("Repository data refreshed successfully");

      // Optionally fetch branches for all repos
      if (fetchBranches) {
        serverLogger.info("Fetching branches for all repositories...");
        const branchPromises = reposToInsert.map(async (repo) => {
          try {
            const branches = await refreshBranchesForRepo(
              repo.fullName,
              teamSlugOrId
            );
            serverLogger.info(
              `Fetched ${branches.length} branches for ${repo.fullName}`
            );
          } catch (error) {
            serverLogger.error(
              `Failed to fetch branches for ${repo.fullName}:`,
              error
            );
          }
        });

        // Fetch branches in batches to avoid rate limiting
        const batchSize = 5;
        for (let i = 0; i < branchPromises.length; i += batchSize) {
          await Promise.all(branchPromises.slice(i, i + batchSize));
        }

        serverLogger.info("Branch fetching completed for all repositories");
      }
    } else {
      serverLogger.info("No repositories found");
    }

    serverLogger.info("GitHub data refresh completed");
  } catch (error) {
    serverLogger.error("Error refreshing GitHub data:", error);
    throw error;
  }
}

// Optional: Add a function to refresh branches for specific repos
export async function refreshBranchesForRepo(
  repo: string,
  teamSlugOrId: string
) {
  try {
    serverLogger.info(
      `[refreshBranchesForRepo] Starting branch refresh for ${repo}`
    );

    // Check if we have auth context
    const authToken = getAuthToken();
    if (!authToken) {
      serverLogger.error("No auth token in context for refreshBranchesForRepo");
      throw new Error("Authentication required for branch refresh");
    }

    // Prefer local git via Rust (gitoxide) for branch listing, sorted by recency
    let branches: {
      name: string;
      lastCommitSha?: string;
      lastActivityAt?: number;
    }[];
    try {
      serverLogger.info(
        `[refreshBranchesForRepo] Attempting native branch listing for ${repo}`
      );
      branches = await listRemoteBranches({ repoFullName: repo });
      serverLogger.info(
        `[refreshBranchesForRepo] Native listing returned ${branches.length} branches`
      );
    } catch (e) {
      // Fallback to GitHub API if native unavailable or errors
      const nativeMsg = e instanceof Error ? e.message : String(e);
      serverLogger.info(
        `Native branch listing failed for ${repo}; falling back to GitHub API: ${nativeMsg}`
      );
      branches = await ghApi.getRepoBranchesWithActivity(repo);
      serverLogger.info(
        `[refreshBranchesForRepo] GitHub API returned ${branches.length} branches`
      );
    }

    if (branches.length > 0) {
      serverLogger.info(
        `[refreshBranchesForRepo] Upserting ${branches.length} branches to database for ${repo}`
      );

      // Create a new Convex client with the auth token to ensure auth context is preserved
      const convexClient = getConvex();
      if (!convexClient) {
        throw new Error("Failed to create authenticated Convex client");
      }

      // Batch branches to avoid hitting Convex limits (max 50 per batch to be safe)
      const BATCH_SIZE = 20;
      const batches = [];
      for (let i = 0; i < branches.length; i += BATCH_SIZE) {
        batches.push(branches.slice(i, i + BATCH_SIZE));
      }

      serverLogger.info(
        `[refreshBranchesForRepo] Processing ${batches.length} batches of branches`
      );

      // Process batches sequentially to avoid overwhelming Convex
      for (let i = 0; i < batches.length; i++) {
        const batch = batches[i];
        serverLogger.info(
          `[refreshBranchesForRepo] Upserting batch ${i + 1}/${batches.length} with ${batch.length} branches`
        );

        try {
          await convexClient.mutation(
            api.github.bulkUpsertBranchesWithActivity,
            {
              teamSlugOrId,
              repo,
              branches: batch,
            }
          );
        } catch (batchError) {
          serverLogger.error(
            `[refreshBranchesForRepo] Failed to upsert batch ${i + 1}:`,
            batchError
          );
          // Continue with other batches even if one fails
        }
      }

      serverLogger.info(
        `[refreshBranchesForRepo] Successfully processed all branch batches for ${repo}`
      );
    } else {
      serverLogger.warn(
        `[refreshBranchesForRepo] No branches found for ${repo}`
      );
    }

    // Return names to callers (legacy shape)
    return branches.map((b) => b.name);
  } catch (error) {
    // Provide more detailed error logging
    if (error instanceof Error) {
      serverLogger.error(
        `[refreshBranchesForRepo] Error refreshing branches for ${repo}:`,
        {
          message: error.message,
          stack: error.stack,
          name: error.name,
        }
      );

      // Check for specific error types
      if ("status" in error && error.status === 401) {
        serverLogger.info(
          "No GitHub authentication found, skipping branch refresh"
        );
        return [];
      }

      // Check if it's a Convex auth error
      if (
        error.message.includes("No auth token found") ||
        error.message.includes("Server Error")
      ) {
        serverLogger.error(
          `[refreshBranchesForRepo] Authentication error with Convex. Auth token present: ${!!getAuthToken()}`
        );
      }
    } else {
      serverLogger.error(
        `[refreshBranchesForRepo] Unknown error refreshing branches for ${repo}:`,
        error
      );
    }

    throw error;
  }
}
