import {
  getCachedGitHubToken,
  authenticateWithGitHub,
  verifyGitHubToken,
  setCachedGitHubToken,
  clearCachedGitHubToken,
} from "./githubAuth.js";
import { serverLogger } from "./fileLogger.js";

function resolveEnvGitHubToken(): string | null {
  const tokenFromEnv = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (tokenFromEnv && tokenFromEnv.trim().length > 0) {
    return tokenFromEnv.trim();
  }
  return null;
}

/**
 * Get GitHub token without touching host keychain helpers.
 * Prioritizes cached/device-flow tokens, then environment variables.
 */
export async function getGitHubToken(): Promise<string | null> {
  try {
    const cachedToken = getCachedGitHubToken();
    if (cachedToken) {
      const isValid = await verifyGitHubToken(cachedToken);
      if (isValid) {
        return cachedToken;
      }
      serverLogger.info("Cached GitHub token is invalid, clearing cache");
      clearCachedGitHubToken();
    }

    const envToken = resolveEnvGitHubToken();
    if (envToken) {
      const isValid = await verifyGitHubToken(envToken);
      if (isValid) {
        setCachedGitHubToken(envToken);
        return envToken;
      }
      serverLogger.warn("Environment GitHub token failed verification");
    }

    serverLogger.info("No GitHub token found in cache or environment");
    return null;
  } catch (error) {
    serverLogger.error("Failed to load GitHub token:", error);
    return null;
  }
}

/**
 * Ensure GitHub token exists, authenticating if necessary
 * This version will trigger the authentication flow if no token exists
 */
export async function ensureGitHubToken(): Promise<string | null> {
  const existingToken = await getGitHubToken();
  if (existingToken) {
    return existingToken;
  }

  // No token found, start authentication flow
  serverLogger.info("Starting GitHub authentication...");
  const newToken = await authenticateWithGitHub();
  return newToken;
}

export async function getGitCredentialsFromHost(): Promise<{
  username?: string;
  password?: string;
} | null> {
  const token = await getGitHubToken();

  if (token) {
    // GitHub tokens use 'oauth' as username
    return {
      username: "oauth",
      password: token,
    };
  }

  return null;
}
