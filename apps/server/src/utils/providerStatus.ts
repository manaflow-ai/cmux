import {
  AGENT_CONFIGS,
  checkDockerStatus,
  type DockerStatus,
  type ProviderStatus as SharedProviderStatus,
} from "@cmux/shared";

export async function checkAllProvidersStatus(): Promise<{
  providers: SharedProviderStatus[];
  dockerStatus: DockerStatus;
}> {
  // Check Docker status
  const [dockerStatus] = await Promise.all([checkDockerStatus()]);

  // Check each provider's specific requirements
  const providerChecks = await Promise.all(
    AGENT_CONFIGS.map(async (agent) => {
      // Use the agent's checkRequirements function if available
      const missingRequirements = agent.checkRequirements
        ? await agent.checkRequirements()
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
