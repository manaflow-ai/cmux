/**
 * GitHub OAuth Device Flow Authentication
 *
 * This module implements GitHub's device flow for OAuth authentication,
 * storing tokens in memory only (session-based) to avoid macOS keychain prompts.
 * Users will need to re-authenticate when the server restarts.
 */

import { serverLogger } from "./fileLogger.js";

interface DeviceCodeResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval: number;
}

interface AccessTokenResponse {
  access_token: string;
  token_type: string;
  scope: string;
}

interface TokenErrorResponse {
  error: string;
  error_description?: string;
  error_uri?: string;
}

// In-memory token storage (cleared on server restart)
let cachedToken: string | null = null;
let tokenExpiresAt: number | null = null;

// GitHub App credentials (for device flow)
// These would typically come from environment variables
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID || "Ov23liIdwLFgOLSJtg3D"; // Default to cmux client ID if available

/**
 * Get the currently cached GitHub token
 */
export function getCachedGitHubToken(): string | null {
  // Check if token is expired (if we track expiry)
  if (tokenExpiresAt && Date.now() > tokenExpiresAt) {
    cachedToken = null;
    tokenExpiresAt = null;
  }
  return cachedToken;
}

/**
 * Set the cached GitHub token
 */
export function setCachedGitHubToken(token: string, expiresIn?: number): void {
  cachedToken = token;
  if (expiresIn) {
    tokenExpiresAt = Date.now() + expiresIn * 1000;
  }
}

/**
 * Clear the cached token (for logout)
 */
export function clearCachedGitHubToken(): void {
  cachedToken = null;
  tokenExpiresAt = null;
}

/**
 * Check if we have a valid cached token
 */
export function hasValidToken(): boolean {
  return getCachedGitHubToken() !== null;
}

/**
 * Start GitHub OAuth device flow
 * Returns the user code and verification URL to display to the user
 */
export async function startGitHubDeviceFlow(): Promise<{
  userCode: string;
  verificationUrl: string;
  deviceCode: string;
  expiresIn: number;
  interval: number;
} | null> {
  try {
    const response = await fetch(
      "https://github.com/login/device/code",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({
          client_id: GITHUB_CLIENT_ID,
          scope: "repo read:user",
        }),
      }
    );

    if (!response.ok) {
      serverLogger.error("Failed to start device flow:", await response.text());
      return null;
    }

    const data = (await response.json()) as DeviceCodeResponse;

    return {
      userCode: data.user_code,
      verificationUrl: data.verification_uri,
      deviceCode: data.device_code,
      expiresIn: data.expires_in,
      interval: data.interval,
    };
  } catch (error) {
    serverLogger.error("Error starting GitHub device flow:", error);
    return null;
  }
}

/**
 * Poll for GitHub OAuth device flow completion
 * Returns the access token when user completes authorization
 */
export async function pollGitHubDeviceFlow(
  deviceCode: string,
  interval: number,
  expiresIn: number
): Promise<string | null> {
  const startTime = Date.now();
  const pollInterval = interval * 1000; // Convert to milliseconds
  const timeout = expiresIn * 1000;

  while (Date.now() - startTime < timeout) {
    await new Promise((resolve) => setTimeout(resolve, pollInterval));

    try {
      const response = await fetch(
        "https://github.com/login/oauth/access_token",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            client_id: GITHUB_CLIENT_ID,
            device_code: deviceCode,
            grant_type: "urn:ietf:params:oauth:grant-type:device_code",
          }),
        }
      );

      if (!response.ok) {
        serverLogger.error("Device flow poll failed:", await response.text());
        continue;
      }

      const data = (await response.json()) as AccessTokenResponse | TokenErrorResponse;

      if ("access_token" in data) {
        // Success! Cache the token and return it
        setCachedGitHubToken(data.access_token);
        serverLogger.info("Successfully authenticated with GitHub");
        return data.access_token;
      }

      if ("error" in data) {
        const error = data.error;

        if (error === "authorization_pending") {
          // User hasn't authorized yet, continue polling
          continue;
        }

        if (error === "slow_down") {
          // We're polling too fast, increase interval
          await new Promise((resolve) => setTimeout(resolve, 5000));
          continue;
        }

        if (error === "expired_token") {
          serverLogger.error("Device code expired");
          return null;
        }

        if (error === "access_denied") {
          serverLogger.error("User denied authorization");
          return null;
        }

        serverLogger.error("Unknown error during device flow:", data);
        return null;
      }
    } catch (error) {
      serverLogger.error("Error polling GitHub device flow:", error);
      // Continue polling despite errors
    }
  }

  serverLogger.error("Device flow timed out");
  return null;
}

/**
 * Complete authentication flow (start + poll)
 * Returns the access token or null if authentication failed
 */
export async function authenticateWithGitHub(): Promise<string | null> {
  // Start the device flow
  const deviceFlow = await startGitHubDeviceFlow();
  if (!deviceFlow) {
    return null;
  }

  serverLogger.info("GitHub Authentication Required");
  serverLogger.info(`Please visit: ${deviceFlow.verificationUrl}`);
  serverLogger.info(`And enter code: ${deviceFlow.userCode}`);

  // Poll for completion
  const token = await pollGitHubDeviceFlow(
    deviceFlow.deviceCode,
    deviceFlow.interval,
    deviceFlow.expiresIn
  );

  return token;
}

/**
 * Verify a token is valid by making a test API call
 */
export async function verifyGitHubToken(token: string): Promise<boolean> {
  try {
    const response = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github.v3+json",
      },
    });

    return response.ok;
  } catch (error) {
    serverLogger.error("Error verifying GitHub token:", error);
    return false;
  }
}
