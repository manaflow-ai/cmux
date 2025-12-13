import { api } from "@cmux/convex/api";
import {
  AGENT_CONFIGS,
  type DockerStatus,
  type ProviderRequirementsContext,
  type ProviderStatus as SharedProviderStatus,
} from "@cmux/shared";
import { checkDockerStatus } from "@cmux/shared/providers/common/check-docker";
import { getConvex } from "./convexClient.js";

type CheckAllProvidersStatusOptions = {
  teamSlugOrId?: string;
};

export async function checkAllProvidersStatus(
  options: CheckAllProvidersStatusOptions = {}
): Promise<{
  providers: SharedProviderStatus[];
  dockerStatus: DockerStatus;
}> {
  // Check Docker status
  const dockerStatus = await checkDockerStatus();

  let apiKeys: ProviderRequirementsContext["apiKeys"] = undefined;

  if (options.teamSlugOrId) {
    try {
      apiKeys = await getConvex().query(api.apiKeys.getAllForAgents, {
        teamSlugOrId: options.teamSlugOrId,
      });
    } catch (error) {
      console.warn(
        `Failed to load API keys for team ${options.teamSlugOrId}:`,
        error
      );
    }
  }

  // Check each provider's specific requirements
  const providerChecks = await Promise.all(
    AGENT_CONFIGS.map(async (agent) => {
      // Use the agent's checkRequirements function if available
      const missingRequirements = agent.checkRequirements
        ? await agent.checkRequirements({
            apiKeys,
            teamSlugOrId: options.teamSlugOrId,
          })
        : [];

      return {
        name: agent.name,
        isAvailable: missingRequirements.length === 0,
        missingRequirements:
          missingRequirements.length > 0 ? missingRequirements : undefined,
      };
    })
  );

  return {
    providers: providerChecks,
    dockerStatus,
  };
}

/**
 * Web-mode variant of checkAllProvidersStatus.
 * Only checks if required API keys are present in Convex - does not check
 * local files, keychains, or Docker status (which don't exist in web deployments).
 */
export async function checkAllProvidersStatusWebMode(options: {
  teamSlugOrId: string;
}): Promise<{
  providers: SharedProviderStatus[];
  dockerStatus: DockerStatus;
}> {
  // In web mode, Docker is managed by cloud provider - always report as ready
  const dockerStatus: DockerStatus = { isRunning: true, version: "web-mode" };

  let apiKeys: Record<string, string> = {};

  try {
    apiKeys =
      (await getConvex().query(api.apiKeys.getAllForAgents, {
        teamSlugOrId: options.teamSlugOrId,
      })) ?? {};
  } catch (error) {
    console.warn(
      `Failed to load API keys for team ${options.teamSlugOrId}:`,
      error
    );
  }

  // Check each agent's required API keys (skip local file checks)
  const providerChecks = AGENT_CONFIGS.map((agent) => {
    const missingRequirements: string[] = [];

    // Check if required API keys are present
    if (agent.apiKeys && agent.apiKeys.length > 0) {
      // Special handling for Claude agents: CLAUDE_CODE_OAUTH_TOKEN OR ANTHROPIC_API_KEY
      // (OAuth token is preferred, but API key works too)
      const isClaudeAgent = agent.name.startsWith("claude/");
      if (isClaudeAgent) {
        const hasOAuthToken =
          apiKeys.CLAUDE_CODE_OAUTH_TOKEN &&
          apiKeys.CLAUDE_CODE_OAUTH_TOKEN.trim() !== "";
        const hasApiKey =
          apiKeys.ANTHROPIC_API_KEY && apiKeys.ANTHROPIC_API_KEY.trim() !== "";
        if (!hasOAuthToken && !hasApiKey) {
          missingRequirements.push(
            "Claude OAuth Token or Anthropic API Key"
          );
        }
      } else {
        // For other agents, check all required keys
        for (const keyConfig of agent.apiKeys) {
          const keyValue = apiKeys[keyConfig.envVar];
          if (!keyValue || keyValue.trim() === "") {
            missingRequirements.push(keyConfig.displayName);
          }
        }
      }
    }

    return {
      name: agent.name,
      isAvailable: missingRequirements.length === 0,
      missingRequirements:
        missingRequirements.length > 0 ? missingRequirements : undefined,
    };
  });

  return {
    providers: providerChecks,
    dockerStatus,
  };
}
