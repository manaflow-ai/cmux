import { api } from "@cmux/convex/api";
import { ghApi } from "../ghApi.js";
import { listRemoteBranches } from "../native/git.js";
import { getConvex } from "./convexClient.js";
import { serverLogger } from "./fileLogger.js";
import { getAuthToken } from "./requestContext.js";

export async function refreshGitHubData({
  teamSlugOrId,
}: {
  teamSlugOrId: string;
}) {
  try {
    serverLogger.info("Starting GitHub data refresh...");
    
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
    } else {
      serverLogger.info("No repositories found");
    }

    // Optionally refresh branches for existing repos
    // This could be done on-demand or periodically instead
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
    // Check if we have auth context
    const authToken = getAuthToken();
    if (!authToken) {
      serverLogger.error("No auth token in context for refreshBranchesForRepo");
      throw new Error("Authentication required for branch refresh");
    }
    // Prefer local git via Rust (gitoxide) for branch listing, sorted by recency
    let branches: { name: string; lastCommitSha?: string; lastActivityAt?: number }[];
    try {
      branches = await listRemoteBranches({ repoFullName: repo });
    } catch (e) {
      // Fallback to GitHub API if native unavailable or errors
      const nativeMsg = e instanceof Error ? e.message : String(e);
      serverLogger.info(
        `Native branch listing failed for ${repo}; falling back to GitHub API: ${nativeMsg}`
      );
      branches = await ghApi.getRepoBranchesWithActivity(repo);
    }

    if (branches.length > 0) {
      await getConvex().mutation(api.github.bulkUpsertBranchesWithActivity, {
        teamSlugOrId,
        repo,
        branches,
      });
    }

    // Return names to callers (legacy shape)
    return branches.map((b) => b.name);
  } catch (error) {
    if (error instanceof Error && "status" in error && error.status === 401) {
      serverLogger.info(
        "No GitHub authentication found, skipping branch refresh"
      );
      return [];
    }
    throw error;
  }
}
