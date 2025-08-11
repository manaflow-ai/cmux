import { 
  AGENT_CONFIGS, 
  checkDockerStatus, 
  checkGitStatus,
  type DockerStatus,
  type GitStatus,
  type GitHubStatus,
  type ProviderStatus as SharedProviderStatus
} from "@cmux/shared";
import { getGitHubTokenFromKeychain } from "./getGitHubToken.js";
import { api } from "@cmux/convex/api";
import { ConvexHttpClient } from "convex/browser";

const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL || "";
const convex = convexUrl ? new ConvexHttpClient(convexUrl) : null;

async function checkGitHubStatus(): Promise<GitHubStatus> {
  try {
    const token = await getGitHubTokenFromKeychain(convex || undefined);
    return {
      isConfigured: !!token,
      hasToken: !!token,
    };
  } catch (error) {
    return {
      isConfigured: false,
      hasToken: false,
      error: error instanceof Error ? error.message : "Unknown error",
    };
  }
}

export async function checkAllProvidersStatus(): Promise<{
  providers: SharedProviderStatus[];
  dockerStatus: DockerStatus;
  gitStatus: GitStatus;
  githubStatus: GitHubStatus;
}> {
  // Check Docker, Git, and GitHub status once
  const [dockerStatus, gitStatus, githubStatus] = await Promise.all([
    checkDockerStatus(),
    checkGitStatus(),
    checkGitHubStatus(),
  ]);

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
    gitStatus,
    githubStatus,
  };
}
