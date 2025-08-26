import { exec } from "node:child_process";
import type { ConvexHttpClient } from "convex/browser";
import { promisify } from "node:util";

const execAsync = promisify(exec);

export async function getGitHubTokenFromKeychain(
  convex?: ConvexHttpClient
): Promise<string | null> {
  try {
    // Try to get GitHub token from gh CLI
    try {
      const { stdout: ghToken } = await execAsync("gh auth token 2>/dev/null");
      if (ghToken.trim()) {
        return ghToken.trim();
      }
    } catch {
      // gh not available or not authenticated
    }

    // Fallback to environment variables
    if (process.env.GH_TOKEN && process.env.GH_TOKEN.trim()) {
      return process.env.GH_TOKEN.trim();
    }
    if (process.env.GITHUB_TOKEN && process.env.GITHUB_TOKEN.trim()) {
      return process.env.GITHUB_TOKEN.trim();
    }

    return null;
  } catch {
    return null;
  }
}

export async function getGitCredentialsFromHost(): Promise<{
  username?: string;
  password?: string;
} | null> {
  const token = await getGitHubTokenFromKeychain();

  if (token) {
    // GitHub tokens use 'oauth' as username
    return {
      username: "oauth",
      password: token,
    };
  }

  return null;
}
