import { PostHog } from "posthog-node";
import { env } from "@/lib/utils/www-env";

type TeamContext = {
  uuid: string;
  slug: string | null;
  displayName: string | null;
  name: string | null;
};

type BaseEventProperties = Record<string, unknown>;

let posthogClient: PostHog | null = null;

function getPosthogClient(): PostHog | null {
  if (!env.POSTHOG_API_KEY) {
    return null;
  }
  if (!posthogClient) {
    posthogClient = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST ?? "https://app.posthog.com",
      flushAt: 1,
    });
  }
  return posthogClient;
}

function captureTeamEvent(
  event: string,
  team: TeamContext,
  properties?: BaseEventProperties,
): void {
  const client = getPosthogClient();
  if (!client) {
    return;
  }

  try {
    client.capture({
      distinctId: team.uuid,
      event,
      properties: {
        teamId: team.uuid,
        teamSlug: team.slug ?? null,
        teamName: team.name ?? team.displayName ?? null,
        ...properties,
      },
    });
  } catch (error) {
    console.warn(`[posthog] Failed to capture event "${event}"`, error);
  }
}

export function trackSandboxStarted({
  team,
  instanceId,
  snapshotId,
  environmentId,
  ttlSeconds,
  metadata,
  repoUrl,
  branch,
  newBranch,
  depth,
  taskRunIdProvided,
  environmentVarsApplied,
  maintenanceScriptConfigured,
  devScriptConfigured,
  provider = "morph",
}: {
  team: TeamContext;
  instanceId: string;
  snapshotId: string;
  environmentId?: string;
  ttlSeconds?: number;
  metadata?: Record<string, unknown> | null;
  repoUrl?: string | null;
  branch?: string | null;
  newBranch?: string | null;
  depth?: number | null;
  taskRunIdProvided: boolean;
  environmentVarsApplied: boolean;
  maintenanceScriptConfigured: boolean;
  devScriptConfigured: boolean;
  provider?: string;
}): void {
  captureTeamEvent("sandbox_started", team, {
    morphInstanceId: instanceId,
    morphSnapshotId: snapshotId,
    provider,
    environmentId: environmentId ?? null,
    environmentAttached: Boolean(environmentId),
    ttlSeconds: ttlSeconds ?? null,
    repoHydrationRequested: Boolean(repoUrl),
    repoUrl: repoUrl ?? null,
    repoBranch: branch ?? null,
    repoNewBranch: newBranch ?? null,
    repoDepth: depth ?? null,
    taskRunIdProvided,
    environmentVarsApplied,
    maintenanceScriptConfigured,
    devScriptConfigured,
    metadataKeys: metadata ? Object.keys(metadata) : [],
  });
}

export function trackEnvironmentCreated({
  team,
  environmentId,
  snapshotId,
  exposedPorts,
  selectedRepos,
  maintenanceScript,
  devScript,
}: {
  team: TeamContext;
  environmentId: string;
  snapshotId: string;
  exposedPorts?: readonly number[] | null;
  selectedRepos?: readonly string[] | null;
  maintenanceScript?: string | null;
  devScript?: string | null;
}): void {
  captureTeamEvent("environment_created", team, {
    environmentId,
    morphSnapshotId: snapshotId,
    exposedPortsCount: exposedPorts?.length ?? 0,
    selectedReposCount: selectedRepos?.length ?? 0,
    maintenanceScriptConfigured: Boolean(maintenanceScript),
    devScriptConfigured: Boolean(devScript),
  });
}

export function trackModelUsage({
  team,
  modelProvider,
  usedFallback,
  branchCount,
  taskDescriptionLength,
  taskDescriptionProvided,
  prTitleProvided,
  uniqueIdProvided,
  source,
}: {
  team: TeamContext;
  modelProvider: string | null;
  usedFallback: boolean;
  branchCount: number;
  taskDescriptionLength?: number | null;
  taskDescriptionProvided: boolean;
  prTitleProvided: boolean;
  uniqueIdProvided: boolean;
  source: "branch.generate" | "branch.generateUnique" | "branch.fromTitle";
}): void {
  captureTeamEvent("model_usage", team, {
    source,
    modelProvider: modelProvider ?? "fallback",
    usedFallback,
    branchCount,
    taskDescriptionLength: taskDescriptionLength ?? null,
    taskDescriptionProvided,
    prTitleProvided,
    uniqueIdProvided,
  });
}
