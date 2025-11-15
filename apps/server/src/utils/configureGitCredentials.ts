import { exec } from "node:child_process";
import { promisify } from "node:util";
import { serverLogger } from "./fileLogger.js";
import { getGitHubToken } from "./getGitHubToken.js";

const execAsync = promisify(exec);

let isConfigured = false;

/**
 * Configure git credential helper to use GitHub token
 * This allows all git operations (including native Rust code) to authenticate
 */
export async function configureGitCredentialsGlobally(): Promise<void> {
  if (isConfigured) {
    return;
  }

  try {
    const githubToken = await getGitHubToken();
    if (!githubToken) {
      serverLogger.info(
        "No GitHub token available, skipping git credential configuration"
      );
      return;
    }

    // Configure git to use a credential helper that provides the token
    // This works by setting up a credential.helper that returns the token for GitHub URLs
    const helperScript = `
#!/bin/sh
if [ "$1" = "get" ]; then
  echo "protocol=https"
  echo "host=github.com"
  echo "username=oauth"
  echo "password=${githubToken}"
fi
`.trim();

    // For now, we'll use the approach of injecting the token into URLs
    // A more sophisticated approach would be to write a credential helper script
    // but that requires file system operations and permissions

    serverLogger.info(
      "Git credential configuration skipped - using URL-based authentication"
    );
    isConfigured = true;
  } catch (error) {
    serverLogger.error("Failed to configure git credentials:", error);
  }
}

/**
 * Create an authenticated GitHub URL for git operations
 */
export function createAuthenticatedGitHubUrl(
  repoUrl: string,
  token: string
): string {
  if (repoUrl.includes("github.com")) {
    // Convert https://github.com/owner/repo.git to https://TOKEN@github.com/owner/repo.git
    return repoUrl.replace(
      /^https:\/\/github\.com\//,
      `https://${token}@github.com/`
    );
  }
  return repoUrl;
}

/**
 * Remove authentication token from a GitHub URL
 */
export function removeTokenFromUrl(url: string): string {
  return url.replace(/^https:\/\/[^@]+@github\.com\//, "https://github.com/");
}
