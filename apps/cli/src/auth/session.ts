import type { CLIConfig } from "../config";
import {
  StackAuthClient,
  type PromptLoginOptions,
  type StackUser,
} from "./stackAuth";
import {
  fetchTeamMemberships,
  type TeamMembership,
  type AuthenticatedContext,
} from "../cmuxClient";
import {
  loadSavedRefreshToken,
  persistRefreshToken,
  clearStoredRefreshToken,
} from "./tokenStore";

export interface AuthenticationCallbacks
  extends Omit<PromptLoginOptions, "onStatus"> {
  onStatus?: (status: string) => void;
}

export interface AuthenticatedSession {
  context: AuthenticatedContext;
  memberships: TeamMembership[];
}

export async function authenticateUser(
  config: CLIConfig,
  callbacks: AuthenticationCallbacks = {},
): Promise<AuthenticatedSession> {
  const stackClient = new StackAuthClient(config.stack);
  const updateStatus = callbacks.onStatus ?? (() => {});

  updateStatus("Checking for existing Stack Auth session…");
  const existingRefresh = await loadSavedRefreshToken(
    config.stack.projectId,
  );

  let refreshToken = existingRefresh ?? null;
  let accessToken: string | null = null;

  if (refreshToken) {
    try {
      updateStatus("Refreshing Stack Auth session…");
      accessToken = await stackClient.getAccessToken(refreshToken);
    } catch (_error) {
      updateStatus(
        "Stored Stack Auth session is no longer valid. Resetting…",
      );
      try {
        await clearStoredRefreshToken(config.stack.projectId);
      } catch (clearError) {
        const message =
          clearError instanceof Error
            ? clearError.message
            : "Failed to clear saved token";
        updateStatus(
          `Warning: Unable to clear saved token (${message}). Continuing…`,
        );
      }
      refreshToken = null;
      accessToken = null;
    }
  }

  if (!refreshToken) {
    updateStatus("Launching Stack Auth login flow…");
    const { refreshToken: newRefreshToken } =
      await stackClient.promptCliLogin({
        onBrowserUrl: callbacks.onBrowserUrl,
        onStatus: callbacks.onStatus,
      });
    refreshToken = newRefreshToken;
    updateStatus("Exchanging refresh token for access token…");
    accessToken = await stackClient.getAccessToken(refreshToken);
  }

  if (!accessToken) {
    throw new Error("Failed to acquire Stack Auth access token.");
  }

  updateStatus("Fetching Stack user profile…");
  const user: StackUser = await stackClient.getUser(accessToken);

  // Persist refresh token for next runs but do not crash if it fails.
  try {
    await persistRefreshToken(config.stack.projectId, refreshToken);
  } catch (error) {
    const err =
      error instanceof Error ? error.message : "Failed to persist token";
    updateStatus(
      `Warning: Unable to persist refresh token (${err}). Continuing…`,
    );
  }

  updateStatus("Loading team memberships…");
  const memberships = await fetchTeamMemberships(config, accessToken);

  return {
    context: {
      refreshToken,
      accessToken,
      user,
    },
    memberships,
  };
}
