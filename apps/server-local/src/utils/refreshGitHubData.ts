import { api } from "@cmux/convex-local/api";
import { ghApi } from "../ghApi.js";
import { convex } from "./convexClient.js";
import { serverLogger } from "./fileLogger.js";

export async function refreshGitHubData() {
  try {
    serverLogger.info("Starting GitHub data refresh...");

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
      if (error instanceof Error && 'status' in error && error.status === 401) {
        serverLogger.info("No GitHub authentication found, skipping repository refresh");
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
      serverLogger.info(`Refreshing repository data with ${reposToInsert.length} repos...`);
      // The mutation now handles deduplication
      await convex.mutation(api.github.bulkInsertRepos, {
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
export async function refreshBranchesForRepo(repo: string) {
  try {
    const branches = await ghApi.getRepoBranches(repo);
    
    if (branches.length > 0) {
      await convex.mutation(api.github.bulkInsertBranches, {
        repo,
        branches,
      });
    }
    
    return branches;
  } catch (error) {
    if (error instanceof Error && 'status' in error && error.status === 401) {
      serverLogger.info("No GitHub authentication found, skipping branch refresh");
      return [];
    }
    throw error;
  }
}