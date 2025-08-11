import * as fs from "fs/promises";
import * as os from "os";
import * as path from "path";
import { getGitHubTokenFromKeychain } from "./getGitHubToken.js";
import { serverLogger } from "./fileLogger.js";
import type { ConvexHttpClient } from "convex/browser";

export async function setupGitCredentialsForDocker(
  instanceId: string,
  convex?: ConvexHttpClient
): Promise<string | null> {
  try {
    const githubToken = await getGitHubTokenFromKeychain(convex);
    if (!githubToken) {
      return null;
    }

    // Create a temporary git config file with the token
    const tempDir = path.join(os.tmpdir(), "cmux-git-configs");
    await fs.mkdir(tempDir, { recursive: true });

    const gitCredentialsPath = path.join(
      tempDir,
      `git-credentials-${instanceId}`
    );

    // Write credentials in git-credentials format
    // Format: https://username:password@host
    const credentialsContent = `https://oauth:${githubToken}@github.com\n`;

    await fs.writeFile(gitCredentialsPath, credentialsContent, { mode: 0o600 });

    return gitCredentialsPath;
  } catch (error) {
    serverLogger.error("Failed to setup git credentials:", error);
    return null;
  }
}

export async function cleanupGitCredentials(instanceId: string): Promise<void> {
  try {
    const tempDir = path.join(os.tmpdir(), "cmux-git-configs");
    const gitCredentialsPath = path.join(
      tempDir,
      `git-credentials-${instanceId}`
    );

    await fs.unlink(gitCredentialsPath);
  } catch {
    // File might not exist, which is fine
  }
}
