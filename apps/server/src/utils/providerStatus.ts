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
  const [dockerStatus] = await Promise.all([checkDockerStatus()]);

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
