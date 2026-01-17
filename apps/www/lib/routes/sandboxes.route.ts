import {
  getAccessTokenFromRequest,
  getUserFromRequest,
} from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import { selectGitIdentity } from "@/lib/utils/gitIdentity";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { RESERVED_CMUX_PORT_SET } from "@cmux/shared/utils/reserved-cmux-ports";
import { parseGithubRepoUrl } from "@cmux/shared/utils/parse-github-repo-url";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { MorphCloudClient } from "morphcloud";
import { loadEnvironmentEnvVars } from "./sandboxes/environment";
import {
  configureGithubAccess,
  configureGitIdentity,
  fetchGitIdentityInputs,
} from "./sandboxes/git";
import type { HydrateRepoConfig } from "./sandboxes/hydration";
import { hydrateWorkspace } from "./sandboxes/hydration";
import { resolveTeamAndSnapshot } from "./sandboxes/snapshot";
import {
  allocateScriptIdentifiers,
  runMaintenanceAndDevScripts,
} from "./sandboxes/startDevAndMaintenanceScript";
import {
  encodeEnvContentForEnvctl,
  envctlLoadCommand,
} from "./utils/ensure-env-vars";
import { VM_CLEANUP_COMMANDS } from "./sandboxes/cleanup";

/**
 * Wait for the VSCode server to be ready by polling the service URL.
 * This prevents "upstream connect error" when the iframe loads before the server is ready.
 */
async function waitForVSCodeReady(
  vscodeUrl: string,
  options: { timeoutMs?: number; intervalMs?: number } = {}
): Promise<boolean> {
  const { timeoutMs = 15_000, intervalMs = 500 } = options;
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      // Use a simple HEAD request to check if the server is responding
      const response = await fetch(vscodeUrl, {
        method: "HEAD",
        signal: AbortSignal.timeout(3_000),
      });
      // OpenVSCode server returns 200 for the root path when ready
      if (response.ok || response.status === 302 || response.status === 301) {
        return true;
      }
    } catch {
      // Connection refused or timeout - server not ready yet
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  return false;
}

/**
 * Extract a safe, descriptive error message from sandbox start errors.
 * Avoids leaking sensitive information like API keys, tokens, or internal paths.
 */
function getSandboxStartErrorMessage(error: unknown): string {
  const baseMessage = "Failed to start sandbox";

  if (!(error instanceof Error)) {
    return baseMessage;
  }

  const message = error.message.toLowerCase();

  // Check for common error patterns and provide helpful context
  // Network/connectivity issues
  if (message.includes("timeout") || message.includes("timed out")) {
    return `${baseMessage}: request timed out while provisioning instance`;
  }
  if (message.includes("econnrefused") || message.includes("connection refused")) {
    return `${baseMessage}: could not connect to sandbox provider`;
  }
  if (message.includes("enotfound") || message.includes("getaddrinfo")) {
    return `${baseMessage}: could not resolve sandbox provider address`;
  }
  if (message.includes("network") || message.includes("socket")) {
    return `${baseMessage}: network error while provisioning instance`;
  }

  // Quota/resource issues (common with cloud providers)
  if (message.includes("quota") || message.includes("limit") || message.includes("exceeded")) {
    return `${baseMessage}: resource quota exceeded`;
  }
  if (message.includes("capacity") || message.includes("unavailable")) {
    return `${baseMessage}: sandbox provider capacity unavailable`;
  }

  // Snapshot issues
  if (message.includes("snapshot") && (message.includes("not found") || message.includes("invalid"))) {
    return `${baseMessage}: snapshot not found or invalid`;
  }

  // Authentication/authorization (without revealing details)
  if (message.includes("unauthorized") || message.includes("401")) {
    return `${baseMessage}: authentication failed with sandbox provider`;
  }
  if (message.includes("forbidden") || message.includes("403")) {
    return `${baseMessage}: access denied by sandbox provider`;
  }

  // Rate limiting
  if (message.includes("rate limit") || message.includes("429") || message.includes("too many")) {
    return `${baseMessage}: rate limited by sandbox provider`;
  }

  // Instance startup issues
  if (message.includes("instance") && message.includes("start")) {
    return `${baseMessage}: instance failed to start`;
  }

  // If error message is reasonably safe (no obvious secrets patterns), include part of it
  const sensitivePatterns = [
    /api[_-]?key/i,
    /token/i,
    /secret/i,
    /password/i,
    /credential/i,
    /bearer/i,
    /authorization/i,
    /sk[_-][a-z0-9]/i,
    /pk[_-][a-z0-9]/i,
  ];

  const hasSensitiveContent = sensitivePatterns.some((pattern) =>
    pattern.test(error.message)
  );

  if (!hasSensitiveContent && error.message.length < 200) {
    // Sanitize the message: remove potential file paths and URLs
    const sanitized = error.message
      .replace(/\/[^\s]+/g, "[path]") // Replace file paths
      .replace(/https?:\/\/[^\s]+/g, "[url]") // Replace URLs
      .trim();

    if (sanitized.length > 0 && sanitized !== "[path]" && sanitized !== "[url]") {
      return `${baseMessage}: ${sanitized}`;
    }
  }

  return baseMessage;
}

/**
 * Cmux instance metadata stored in Morph instance.metadata
 */
interface CmuxInstanceMetadata {
  app?: string;
  userId?: string;
  teamId?: string;
}

/**
 * Result of instance ownership verification
 */
type VerifyInstanceOwnershipResult =
  | { authorized: true; instanceId: string }
  | { authorized: false; status: 403 | 404; message: string };

/**
 * Verify that a user owns or has team access to a Morph instance.
 * Checks instance metadata for cmux app prefix and user/team ownership.
 */
async function verifyInstanceOwnership(
  morphClient: MorphCloudClient,
  instanceId: string,
  userId: string,
  checkTeamMembership: () => Promise<{ teamId: string }[]>
): Promise<VerifyInstanceOwnershipResult> {
  let instance;
  try {
    instance = await morphClient.instances.get({ instanceId });
  } catch {
    return { authorized: false, status: 404, message: "Instance not found" };
  }

  const meta = instance.metadata as CmuxInstanceMetadata | undefined;

  // Verify the instance belongs to cmux (accepts cmux, cmux-dev, cmux-preview, etc.)
  if (!meta?.app?.startsWith("cmux")) {
    return { authorized: false, status: 404, message: "Instance not found" };
  }

  // Check direct ownership
  const isOwner = meta.userId === userId;
  if (isOwner) {
    return { authorized: true, instanceId };
  }

  // Check team membership if instance has a teamId
  if (meta.teamId) {
    try {
      const memberships = await checkTeamMembership();
      const isTeamMember = memberships.some((m) => m.teamId === meta.teamId);
      if (isTeamMember) {
        return { authorized: true, instanceId };
      }
    } catch {
      // Failed to check team membership - continue to deny
    }
  }

  return {
    authorized: false,
    status: 403,
    message: "Forbidden - not authorized to access this instance",
  };
}

export const sandboxesRouter = new OpenAPIHono();

const StartSandboxBody = z
  .object({
    teamSlugOrId: z.string(),
    environmentId: z.string().optional(),
    snapshotId: z.string().optional(),
    ttlSeconds: z
      .number()
      .optional()
      .default(60 * 60),
    metadata: z.record(z.string(), z.string()).optional(),
    taskRunId: z.string().optional(),
    taskRunJwt: z.string().optional(),
    isCloudWorkspace: z.boolean().optional(),
    // Optional hydration parameters to clone a repo into the sandbox on start
    repoUrl: z.string().optional(),
    branch: z.string().optional(),
    newBranch: z.string().optional(),
    depth: z.number().optional().default(1),
  })
  .openapi("StartSandboxBody");

const StartSandboxResponse = z
  .object({
    instanceId: z.string(),
    vscodeUrl: z.string(),
    workerUrl: z.string(),
    provider: z.enum(["morph"]).default("morph"),
    vscodePersisted: z.boolean().optional(),
  })
  .openapi("StartSandboxResponse");

const UpdateSandboxEnvBody = z
  .object({
    teamSlugOrId: z.string(),
    envVarsContent: z.string(),
  })
  .openapi("UpdateSandboxEnvBody");

const UpdateSandboxEnvResponse = z
  .object({
    applied: z.literal(true),
  })
  .openapi("UpdateSandboxEnvResponse");

// Start a new sandbox (currently Morph-backed)
sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/start",
    tags: ["Sandboxes"],
    summary: "Start a sandbox environment",
    request: {
      body: {
        content: {
          "application/json": {
            schema: StartSandboxBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: StartSandboxResponse,
          },
        },
        description: "Sandbox started successfully",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to start sandbox" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }
    const githubAccessTokenPromise = (async () => {
      const githubAccount = await user.getConnectedAccount("github");
      if (!githubAccount) {
        return {
          githubAccessTokenError: "GitHub account not found",
          githubAccessToken: null,
        } as const;
      }
      const { accessToken: githubAccessToken } =
        await githubAccount.getAccessToken();
      if (!githubAccessToken) {
        return {
          githubAccessTokenError: "GitHub access token not found",
          githubAccessToken: null,
        } as const;
      }

      return { githubAccessTokenError: null, githubAccessToken } as const;
    })();

    const body = c.req.valid("json");
    try {
      console.log("[sandboxes.start] incoming", {
        teamSlugOrId: body.teamSlugOrId,
        hasEnvId: Boolean(body.environmentId),
        hasSnapshotId: Boolean(body.snapshotId),
        repoUrl: body.repoUrl,
        branch: body.branch,
      });
    } catch {
      /* noop */
    }

    try {
      const convex = getConvex({ accessToken });

      const {
        team,
        resolvedSnapshotId,
        environmentDataVaultKey,
        environmentMaintenanceScript,
        environmentDevScript,
      } = await resolveTeamAndSnapshot({
        req: c.req.raw,
        convex,
        teamSlugOrId: body.teamSlugOrId,
        environmentId: body.environmentId,
        snapshotId: body.snapshotId,
      });

      const environmentEnvVarsPromise = environmentDataVaultKey
        ? loadEnvironmentEnvVars(environmentDataVaultKey)
        : Promise.resolve<string | null>(null);

      // Parse repo URL once if provided
      const parsedRepoUrl = body.repoUrl ? parseGithubRepoUrl(body.repoUrl) : null;

      // Load workspace config if we're in cloud mode with a repository (not an environment)
      let workspaceConfig: { maintenanceScript?: string; envVarsContent?: string } | null = null;
      if (parsedRepoUrl && !body.environmentId) {
        try {
          const config = await convex.query(api.workspaceConfigs.get, {
            teamSlugOrId: body.teamSlugOrId,
            projectFullName: parsedRepoUrl.fullName,
          });
          if (config) {
            const envVarsContent = config.dataVaultKey
              ? await loadEnvironmentEnvVars(config.dataVaultKey)
              : null;
            workspaceConfig = {
              maintenanceScript: config.maintenanceScript ?? undefined,
              envVarsContent: envVarsContent ?? undefined,
            };
            console.log(`[sandboxes.start] Loaded workspace config for ${parsedRepoUrl.fullName}`, {
              hasMaintenanceScript: Boolean(workspaceConfig.maintenanceScript),
              hasEnvVars: Boolean(workspaceConfig.envVarsContent),
            });
          }
        } catch (error) {
          console.error(`[sandboxes.start] Failed to load workspace config for ${parsedRepoUrl.fullName}`, error);
        }
      }

      const maintenanceScript = environmentMaintenanceScript ?? workspaceConfig?.maintenanceScript ?? null;
      const devScript = environmentDevScript ?? null;

      const isCloudWorkspace =
        body.isCloudWorkspace !== undefined
          ? body.isCloudWorkspace
          : !body.taskRunId;

      const scriptIdentifiers =
        maintenanceScript || devScript
          ? allocateScriptIdentifiers()
          : null;

      const gitIdentityPromise = githubAccessTokenPromise.then(
        ({ githubAccessToken }) => {
          if (!githubAccessToken) {
            throw new Error("GitHub access token not found");
          }
          return fetchGitIdentityInputs(convex, githubAccessToken);
        },
      );

      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });

      const instance = await client.instances.start({
        snapshotId: resolvedSnapshotId,
        ttlSeconds: body.ttlSeconds ?? 60 * 60,
        ttlAction: "pause",
        metadata: {
          app: "cmux",
          teamId: team.uuid,
          ...(body.environmentId ? { environmentId: body.environmentId } : {}),
          ...(body.metadata || {}),
        },
      });
      void (async () => {
        await instance.setWakeOn(true, true);
      })();

      const exposed = instance.networking.httpServices;
      const vscodeService = exposed.find((s) => s.port === 39378);
      const workerService = exposed.find((s) => s.port === 39377);
      if (!vscodeService || !workerService) {
        await instance.stop().catch(() => { });
        return c.text("VSCode or worker service not found", 500);
      }

      // Wait for VSCode server to be ready before persisting URL
      // This prevents "upstream connect error" when the frontend loads the iframe
      // before the OpenVSCode server is actually listening
      const vscodeReady = await waitForVSCodeReady(vscodeService.url);
      if (!vscodeReady) {
        console.warn(
          `[sandboxes.start] VSCode server did not become ready within timeout for ${instance.id}, proceeding anyway`,
        );
      } else {
        console.log(
          `[sandboxes.start] VSCode server ready for ${instance.id}`,
        );
      }

      // Persist VSCode URLs to Convex once the server is ready
      // Status is "starting" to indicate hydration is still in progress
      let vscodePersisted = false;
      if (body.taskRunId) {
        try {
          await convex.mutation(api.taskRuns.updateVSCodeInstance, {
            teamSlugOrId: body.teamSlugOrId,
            id: body.taskRunId as Id<"taskRuns">,
            vscode: {
              provider: "morph",
              containerName: instance.id,
              status: "starting",
              url: vscodeService.url,
              workspaceUrl: `${vscodeService.url}/?folder=/root/workspace`,
              startedAt: Date.now(),
            },
          });
          vscodePersisted = true;
          console.log(
            `[sandboxes.start] Persisted VSCode info for ${body.taskRunId}`,
          );
        } catch (error) {
          console.error(
            "[sandboxes.start] Failed to persist VSCode info (non-fatal):",
            error,
          );
        }
      }

      // Get environment variables from the environment if configured
      const environmentEnvVarsContent = await environmentEnvVarsPromise;

      // Prepare environment variables including task JWT if present
      // Workspace env vars take precedence if no environment is configured
      let envVarsToApply = environmentEnvVarsContent || workspaceConfig?.envVarsContent || "";

      // Add CMUX task-related env vars if present
      if (body.taskRunId) {
        envVarsToApply += `\nCMUX_TASK_RUN_ID="${body.taskRunId}"`;
      }
      if (body.taskRunJwt) {
        envVarsToApply += `\nCMUX_TASK_RUN_JWT="${body.taskRunJwt}"`;
      }

      // Apply all environment variables if any
      if (envVarsToApply.trim().length > 0) {
        try {
          const encodedEnv = encodeEnvContentForEnvctl(envVarsToApply);
          const loadRes = await instance.exec(envctlLoadCommand(encodedEnv));
          if (loadRes.exit_code === 0) {
            console.log(
              `[sandboxes.start] Applied environment variables via envctl`,
              {
                hasEnvironmentVars: Boolean(environmentEnvVarsContent),
                hasWorkspaceVars: Boolean(workspaceConfig?.envVarsContent),
                hasTaskRunId: Boolean(body.taskRunId),
                hasTaskRunJwt: Boolean(body.taskRunJwt),
              },
            );
          } else {
            console.error(
              `[sandboxes.start] Env var bootstrap failed exit=${loadRes.exit_code} stderr=${(loadRes.stderr || "").slice(0, 200)}`,
            );
          }
        } catch (error) {
          console.error(
            "[sandboxes.start] Failed to apply environment variables",
            error,
          );
        }
      }

      const configureGitIdentityTask = gitIdentityPromise
        .then(([who, gh]) => {
          const { name, email } = selectGitIdentity(who, gh);
          return configureGitIdentity(instance, { name, email });
        })
        .catch((error) => {
          console.log(
            `[sandboxes.start] Failed to configure git identity; continuing...`,
            error,
          );
        });

      const { githubAccessToken, githubAccessTokenError } =
        await githubAccessTokenPromise;
      if (githubAccessTokenError) {
        console.error(
          `[sandboxes.start] GitHub access token error: ${githubAccessTokenError}`,
        );
        return c.text("Failed to resolve GitHub credentials", 401);
      }

      // Sandboxes run as the requesting user, so prefer their OAuth scope over GitHub App installation tokens.
      await configureGithubAccess(instance, githubAccessToken);

      let repoConfig: HydrateRepoConfig | undefined;
      if (body.repoUrl) {
        console.log(`[sandboxes.start] Hydrating repo for ${instance.id}`);
        if (!parsedRepoUrl) {
          return c.text("Unsupported repo URL; expected GitHub URL", 400);
        }
        console.log(`[sandboxes.start] Parsed owner/repo: ${parsedRepoUrl.fullName}`);

        repoConfig = {
          owner: parsedRepoUrl.owner,
          name: parsedRepoUrl.repo,
          repoFull: parsedRepoUrl.fullName,
          cloneUrl: parsedRepoUrl.gitUrl,
          maskedCloneUrl: parsedRepoUrl.gitUrl,
          depth: Math.max(1, Math.floor(body.depth ?? 1)),
          baseBranch: body.branch || "main",
          newBranch: body.newBranch ?? "",
        };
      }

      try {
        await hydrateWorkspace({
          instance,
          repo: repoConfig,
        });
      } catch (error) {
        console.error(`[sandboxes.start] Hydration failed:`, error);
        await instance.stop().catch(() => { });
        return c.text("Failed to hydrate sandbox", 500);
      }

      // Update status to "running" after hydration completes
      if (body.taskRunId && vscodePersisted) {
        void convex
          .mutation(api.taskRuns.updateVSCodeStatus, {
            teamSlugOrId: body.teamSlugOrId,
            id: body.taskRunId as Id<"taskRuns">,
            status: "running",
          })
          .catch((error) => {
            console.error(
              "[sandboxes.start] Failed to update VSCode status to running:",
              error,
            );
          });
      }

      if (maintenanceScript || devScript) {
        if (!body.taskRunJwt) {
          console.warn(
            "[sandboxes.start] Skipping maintenance/dev scripts (missing taskRunJwt)",
          );
        } else {
          (async () => {
            await runMaintenanceAndDevScripts({
              instance,
              maintenanceScript: maintenanceScript || undefined,
              devScript: devScript || undefined,
              identifiers: scriptIdentifiers ?? undefined,
              convexUrl: env.NEXT_PUBLIC_CONVEX_URL,
              taskRunJwt: body.taskRunJwt,
              isCloudWorkspace,
            });
          })().catch((error) => {
            console.error(
              "[sandboxes.start] Background script execution failed:",
              error,
            );
          });
        }
      }

      await configureGitIdentityTask;

      return c.json({
        instanceId: instance.id,
        vscodeUrl: vscodeService.url,
        workerUrl: workerService.url,
        provider: "morph",
        vscodePersisted,
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        const message =
          typeof error.message === "string" && error.message.length > 0
            ? error.message
            : "Request failed";
        return c.text(message, error.status);
      }
      console.error("Failed to start sandbox:", error);
      // Provide a more descriptive error message without leaking sensitive details
      const errorMessage = getSandboxStartErrorMessage(error);
      return c.text(errorMessage, 500);
    }
  },
);

sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/{id}/env",
    tags: ["Sandboxes"],
    summary: "Apply environment variables to a running sandbox",
    request: {
      params: z.object({ id: z.string() }),
      body: {
        content: {
          "application/json": {
            schema: UpdateSandboxEnvBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: UpdateSandboxEnvResponse,
          },
        },
        description: "Environment variables applied",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Sandbox not found" },
      500: { description: "Failed to apply environment variables" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId, envVarsContent } = c.req.valid("json");

    try {
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId,
      });

      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances
        .get({ instanceId: id })
        .catch((error) => {
          console.error("[sandboxes.env] Failed to load instance", error);
          return null;
        });

      if (!instance) {
        return c.text("Sandbox not found", 404);
      }

      const metadataTeamId = (
        instance as unknown as {
          metadata?: { teamId?: string };
        }
      ).metadata?.teamId;

      if (metadataTeamId && metadataTeamId !== team.uuid) {
        return c.text("Forbidden", 403);
      }

      const encodedEnv = encodeEnvContentForEnvctl(envVarsContent);
      const command = envctlLoadCommand(encodedEnv);
      const execResult = await instance.exec(command);
      if (execResult.exit_code !== 0) {
        console.error(
          `[sandboxes.env] envctl load failed exit=${execResult.exit_code} stderr=${(execResult.stderr || "").slice(0, 200)}`,
        );
        return c.text("Failed to apply environment variables", 500);
      }

      return c.json({ applied: true as const });
    } catch (error) {
      console.error(
        "[sandboxes.env] Failed to apply environment variables",
        error,
      );
      return c.text("Failed to apply environment variables", 500);
    }
  },
);

// Run maintenance and dev scripts in a sandbox
const RunScriptsBody = z
  .object({
    teamSlugOrId: z.string(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
  })
  .openapi("RunScriptsBody");

const RunScriptsResponse = z
  .object({
    started: z.literal(true),
  })
  .openapi("RunScriptsResponse");

sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/{id}/run-scripts",
    tags: ["Sandboxes"],
    summary: "Run maintenance and dev scripts in a sandbox",
    description:
      "Runs maintenance and/or dev scripts in tmux sessions within the sandbox. " +
      "This ensures scripts run in a managed way that can be properly cleaned up before snapshotting.",
    request: {
      params: z.object({ id: z.string() }),
      body: {
        content: {
          "application/json": {
            schema: RunScriptsBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: RunScriptsResponse,
          },
        },
        description: "Scripts started successfully",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Sandbox not found" },
      500: { description: "Failed to run scripts" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId, maintenanceScript, devScript } = c.req.valid("json");

    // Need at least one script to run
    if (!maintenanceScript && !devScript) {
      return c.json({ started: true as const });
    }

    try {
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId,
      });

      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances
        .get({ instanceId: id })
        .catch((error) => {
          console.error("[sandboxes.run-scripts] Failed to load instance", error);
          return null;
        });

      if (!instance) {
        return c.text("Sandbox not found", 404);
      }

      const metadataTeamId = (
        instance as unknown as {
          metadata?: { teamId?: string };
        }
      ).metadata?.teamId;

      if (metadataTeamId && metadataTeamId !== team.uuid) {
        return c.text("Forbidden", 403);
      }

      // Allocate script identifiers for tracking
      const scriptIdentifiers = allocateScriptIdentifiers();

      // Run scripts in background (don't await)
      (async () => {
        await runMaintenanceAndDevScripts({
          instance,
          maintenanceScript: maintenanceScript || undefined,
          devScript: devScript || undefined,
          identifiers: scriptIdentifiers,
          convexUrl: env.NEXT_PUBLIC_CONVEX_URL,
          isCloudWorkspace: true,
        });
      })().catch((error) => {
        console.error(
          "[sandboxes.run-scripts] Background script execution failed:",
          error,
        );
      });

      return c.json({ started: true as const });
    } catch (error) {
      console.error(
        "[sandboxes.run-scripts] Failed to run scripts",
        error,
      );
      return c.text("Failed to run scripts", 500);
    }
  },
);

// Stop/pause a sandbox
sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/{id}/stop",
    tags: ["Sandboxes"],
    summary: "Stop or pause a sandbox instance",
    request: {
      params: z.object({ id: z.string() }),
    },
    responses: {
      204: { description: "Sandbox stopped" },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
      500: { description: "Failed to stop sandbox" },
    },
  }),
  async (c) => {
    const id = c.req.valid("param").id;
    const token = await getAccessTokenFromRequest(c.req.raw);
    if (!token) return c.text("Unauthorized", 401);

    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId: id });
      // Kill all dev servers and user processes before pausing to avoid port conflicts on resume
      await instance.exec(VM_CLEANUP_COMMANDS);
      await instance.pause();
      return c.body(null, 204);
    } catch (error) {
      console.error("Failed to stop sandbox:", error);
      return c.text("Failed to stop sandbox", 500);
    }
  },
);

// Query status of sandbox
sandboxesRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/sandboxes/{id}/status",
    tags: ["Sandboxes"],
    summary: "Get sandbox status and URLs",
    request: {
      params: z.object({ id: z.string() }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: z.object({
              running: z.boolean(),
              vscodeUrl: z.string().optional(),
              workerUrl: z.string().optional(),
              provider: z.enum(["morph"]).optional(),
            }),
          },
        },
        description: "Sandbox status",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to get status" },
    },
  }),
  async (c) => {
    const id = c.req.valid("param").id;
    const token = await getAccessTokenFromRequest(c.req.raw);
    if (!token) return c.text("Unauthorized", 401);
    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId: id });
      const vscodeService = instance.networking.httpServices.find(
        (s) => s.port === 39378,
      );
      const workerService = instance.networking.httpServices.find(
        (s) => s.port === 39377,
      );
      const running = Boolean(vscodeService);
      return c.json({
        running,
        vscodeUrl: vscodeService?.url,
        workerUrl: workerService?.url,
        provider: "morph",
      });
    } catch (error) {
      console.error("Failed to get sandbox status:", error);
      return c.text("Failed to get status", 500);
    }
  },
);

// Publish devcontainer forwarded ports (read devcontainer.json inside instance, expose, persist to Convex)
sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/{id}/publish-devcontainer",
    tags: ["Sandboxes"],
    summary:
      "Expose forwarded ports from devcontainer.json and persist networking info",
    request: {
      params: z.object({ id: z.string() }),
      body: {
        content: {
          "application/json": {
            schema: z.object({
              teamSlugOrId: z.string(),
              taskRunId: z.string(),
            }),
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: z.array(
              z.object({
                status: z.enum(["running"]).default("running"),
                port: z.number(),
                url: z.string(),
              }),
            ),
          },
        },
        description: "Exposed ports list",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to publish devcontainer networking" },
    },
  }),
  async (c) => {
    const token = await getAccessTokenFromRequest(c.req.raw);
    if (!token) return c.text("Unauthorized", 401);
    const { id } = c.req.valid("param");
    const { teamSlugOrId, taskRunId } = c.req.valid("json");
    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId: id });

      const reservedPorts = RESERVED_CMUX_PORT_SET;

      // Attempt to read devcontainer.json for declared forwarded ports
      const devcontainerJson = await instance.exec(
        "cat /root/workspace/.devcontainer/devcontainer.json",
      );
      const parsed =
        devcontainerJson.exit_code === 0
          ? (JSON.parse(devcontainerJson.stdout || "{}") as {
            forwardPorts?: number[];
          })
          : { forwardPorts: [] as number[] };

      const devcontainerPorts = Array.isArray(parsed.forwardPorts)
        ? (parsed.forwardPorts as number[])
        : [];

      // Read environmentId from instance metadata (set during start)
      const instanceMeta = (
        instance as unknown as {
          metadata?: { environmentId?: string };
        }
      ).metadata;

      // Resolve environment-exposed ports (preferred)
      const convex = getConvex({ accessToken: token });
      let environmentPorts: number[] | undefined;
      if (instanceMeta?.environmentId) {
        try {
          const envDoc = await convex.query(api.environments.get, {
            teamSlugOrId,
            id: instanceMeta.environmentId as string & {
              __tableName: "environments";
            },
          });
          environmentPorts = envDoc?.exposedPorts ?? undefined;
        } catch {
          // ignore lookup errors; fall back to devcontainer ports
        }
      }

      // Build the set of ports we want to expose and persist
      const allowedPorts = new Set<number>();
      const addAllowed = (p: number) => {
        if (!Number.isFinite(p)) return;
        const pn = Math.floor(p);
        if (pn > 0 && !reservedPorts.has(pn)) allowedPorts.add(pn);
      };

      // Prefer environment.exposedPorts if available; otherwise use devcontainer forwardPorts
      (environmentPorts && environmentPorts.length > 0
        ? environmentPorts
        : devcontainerPorts
      ).forEach(addAllowed);

      const desiredPorts = Array.from(allowedPorts.values()).sort(
        (a, b) => a - b,
      );
      const serviceNameForPort = (port: number) => `port-${port}`;

      let workingInstance = instance;
      const reloadInstance = async () => {
        workingInstance = await client.instances.get({
          instanceId: instance.id,
        });
      };

      await reloadInstance();

      for (const service of workingInstance.networking.httpServices) {
        if (!service.name.startsWith("port-")) {
          continue;
        }
        if (reservedPorts.has(service.port)) {
          continue;
        }
        if (!allowedPorts.has(service.port)) {
          await workingInstance.hideHttpService(service.name);
        }
      }

      await reloadInstance();

      for (const port of desiredPorts) {
        const serviceName = serviceNameForPort(port);
        const alreadyExposed = workingInstance.networking.httpServices.some(
          (service) => service.name === serviceName,
        );
        if (alreadyExposed) {
          continue;
        }
        try {
          await workingInstance.exposeHttpService(serviceName, port);
        } catch (error) {
          console.error(
            `[sandboxes.publishNetworking] Failed to expose ${serviceName}`,
            error,
          );
        }
      }

      await reloadInstance();

      const networking = workingInstance.networking.httpServices
        .filter((s) => allowedPorts.has(s.port))
        .map((s) => ({ status: "running" as const, port: s.port, url: s.url }));

      // Persist to Convex
      await convex.mutation(api.taskRuns.updateNetworking, {
        teamSlugOrId,
        id: taskRunId as unknown as string & { __tableName: "taskRuns" },
        networking,
      });

      return c.json(networking);
    } catch (error) {
      console.error("Failed to publish devcontainer networking:", error);
      return c.text("Failed to publish devcontainer networking", 500);
    }
  },
);

// SSH connection info response schema
const SandboxSshResponse = z
  .object({
    morphInstanceId: z.string(),
    sshCommand: z.string().describe("Full SSH command to connect to this sandbox"),
    accessToken: z.string().describe("SSH access token for this sandbox"),
    user: z.string(),
    status: z.enum(["running", "paused"]).describe("Current instance status"),
  })
  .openapi("SandboxSshResponse");

// Get SSH connection details for a sandbox
sandboxesRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/sandboxes/{id}/ssh",
    tags: ["Sandboxes"],
    summary: "Get SSH connection details for a sandbox",
    description:
      "Returns SSH connection info for a sandbox. Use the returned sshCommand or accessToken to connect.",
    request: {
      params: z.object({ id: z.string() }),
      query: z.object({
        teamSlugOrId: z.string().optional(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: SandboxSshResponse,
          },
        },
        description: "SSH connection details",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden - not a team member" },
      404: { description: "Sandbox not found" },
      500: { description: "Failed to get SSH info" },
    },
  }),
  async (c) => {
    const user = await getUserFromRequest(c.req.raw);
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      const convex = getConvex({ accessToken });

      let morphInstanceId: string | null = null;

      // Check if the id is a Morph instance ID (starts with "morphvm_")
      if (id.startsWith("morphvm_")) {
        // Direct Morph instance ID - verify ownership via instance metadata
        const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });

        // First try to find in task runs if team is provided
        if (teamSlugOrId) {
          let taskRun = null;
          try {
            taskRun = await convex.query(api.taskRuns.getByContainerName, {
              teamSlugOrId,
              containerName: id,
            });
          } catch (convexError) {
            console.log(
              `[sandboxes.ssh] Convex query failed for ${id}:`,
              convexError,
            );
          }

          if (taskRun) {
            // Found in task runs - verify team access and that it's a Morph instance
            await verifyTeamAccess({
              req: c.req.raw,
              teamSlugOrId,
            });
            if (taskRun.vscode?.provider !== "morph") {
              return c.text("Sandbox type not supported for SSH", 404);
            }
            morphInstanceId = id;
          }
        }

        // If not found via task run, verify ownership via instance metadata
        if (!morphInstanceId) {
          const result = await verifyInstanceOwnership(
            morphClient,
            id,
            user.id,
            async () => {
              const memberships = await convex.query(api.teams.listTeamMemberships, {});
              return memberships.map((m) => ({ teamId: m.team.teamId }));
            }
          );
          if (!result.authorized) {
            return c.text(result.message, result.status);
          }
          morphInstanceId = result.instanceId;
        }
      } else {
        // For task-run IDs, team is required to look up the task run
        if (!teamSlugOrId) {
          return c.text("teamSlugOrId is required for task-run IDs", 400);
        }

        // Verify team access
        const team = await verifyTeamAccess({
          req: c.req.raw,
          teamSlugOrId,
        });
        // Assume it's a task-run ID - look up the sandbox
        let taskRun: Doc<"taskRuns"> | null = null;

        try {
          taskRun = await convex.query(api.taskRuns.get, {
            teamSlugOrId,
            id: id as Id<"taskRuns">,
          });
        } catch {
          // Not a valid task run ID
          return c.text("Invalid sandbox or task-run ID", 404);
        }

        if (!taskRun) {
          return c.text("Task run not found", 404);
        }

        // Verify the task run is in the correct team
        if (taskRun.teamId !== team.uuid) {
          return c.text("Forbidden", 403);
        }

        // Check if this task run has an active Morph sandbox
        if (!taskRun.vscode) {
          return c.text("No sandbox associated with this task run", 404);
        }

        if (taskRun.vscode.provider !== "morph") {
          return c.text("Sandbox type not supported for SSH", 404);
        }

        if (!taskRun.vscode.containerName) {
          return c.text("Sandbox container name not found", 404);
        }

        // Only return SSH info for running/starting sandboxes
        if (
          taskRun.vscode.status !== "running" &&
          taskRun.vscode.status !== "starting"
        ) {
          return c.text("Sandbox is not running", 404);
        }

        morphInstanceId = taskRun.vscode.containerName;
      }

      if (!morphInstanceId) {
        return c.text("Could not resolve sandbox instance", 404);
      }

      // Get SSH access token from Morph API
      const sshKeyResponse = await fetch(
        `https://cloud.morph.so/api/instance/${morphInstanceId}/ssh/key`,
        {
          method: "GET",
          headers: {
            Authorization: `Bearer ${env.MORPH_API_KEY}`,
            "Content-Type": "application/json",
          },
        }
      );

      if (!sshKeyResponse.ok) {
        const errorText = await sshKeyResponse.text();
        console.error(
          `[sandboxes.ssh] Morph API returned ${sshKeyResponse.status}: ${errorText}`
        );
        // Return 404 if the instance doesn't exist in Morph
        if (sshKeyResponse.status === 404 || errorText.includes("not found")) {
          return c.text("Sandbox not found", 404);
        }
        return c.text("Failed to get SSH credentials", 500);
      }

      const sshKeyData = (await sshKeyResponse.json()) as {
        private_key: string;
        public_key: string;
        password: string;
        access_token: string;
      };

      if (!sshKeyData.access_token) {
        console.error("[sandboxes.ssh] Morph API did not return access_token");
        return c.text("Failed to get SSH credentials", 500);
      }

      // Get instance status from Morph
      const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await morphClient.instances.get({ instanceId: morphInstanceId });
      const status = instance.status === "paused" ? "paused" : "running";

      const sshCommand = `ssh ${sshKeyData.access_token}@ssh.cloud.morph.so`;
      return c.json({
        morphInstanceId,
        sshCommand,
        accessToken: sshKeyData.access_token,
        user: "root",
        status,
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        return c.text(error.message || "Request failed", error.status);
      }
      console.error("[sandboxes.ssh] Failed to get SSH info:", error);
      return c.text("Failed to get SSH info", 500);
    }
  },
);

// Resume a paused sandbox
const SandboxResumeResponse = z
  .object({
    resumed: z.literal(true),
  })
  .openapi("SandboxResumeResponse");

sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/{id}/resume",
    tags: ["Sandboxes"],
    summary: "Resume a paused sandbox",
    description: "Resumes a paused sandbox so it can accept SSH connections.",
    request: {
      params: z.object({ id: z.string() }),
      query: z.object({
        teamSlugOrId: z.string().optional(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: SandboxResumeResponse,
          },
        },
        description: "Sandbox resumed successfully",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden - not a team member" },
      404: { description: "Sandbox not found" },
      500: { description: "Failed to resume sandbox" },
    },
  }),
  async (c) => {
    const user = await getUserFromRequest(c.req.raw);
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      const convex = getConvex({ accessToken });
      let morphInstanceId: string | null = null;

      // Check if the id is a direct VM ID
      if (id.startsWith("morphvm_")) {
        // Direct Morph instance ID - verify ownership via instance metadata
        const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });

        // First try to find in task runs if team is provided
        if (teamSlugOrId) {
          let taskRun = null;
          try {
            taskRun = await convex.query(api.taskRuns.getByContainerName, {
              teamSlugOrId,
              containerName: id,
            });
          } catch (convexError) {
            console.log(
              `[sandboxes.resume] Convex query failed for ${id}:`,
              convexError,
            );
          }

          if (taskRun) {
            // Found in task runs - verify team access
            await verifyTeamAccess({
              req: c.req.raw,
              teamSlugOrId,
            });
            morphInstanceId = id;
          }
        }

        // If not found via task run, verify ownership via instance metadata
        if (!morphInstanceId) {
          const result = await verifyInstanceOwnership(
            morphClient,
            id,
            user.id,
            async () => {
              const memberships = await convex.query(api.teams.listTeamMemberships, {});
              return memberships.map((m) => ({ teamId: m.team.teamId }));
            }
          );
          if (!result.authorized) {
            return c.text(result.message, result.status);
          }
          morphInstanceId = result.instanceId;
        }
      } else {
        // Task-run ID - team is required
        if (!teamSlugOrId) {
          return c.text("teamSlugOrId is required for task-run IDs", 400);
        }

        await verifyTeamAccess({
          req: c.req.raw,
          teamSlugOrId,
        });

        const taskRun = await convex.query(api.taskRuns.get, {
          teamSlugOrId,
          id: id as Id<"taskRuns">,
        });

        if (!taskRun || !taskRun.vscode?.containerName) {
          return c.text("Sandbox not found", 404);
        }

        if (taskRun.vscode.provider !== "morph") {
          return c.text("Sandbox type not supported", 404);
        }

        morphInstanceId = taskRun.vscode.containerName;
      }

      if (!morphInstanceId) {
        return c.text("Could not resolve sandbox instance", 404);
      }

      // Resume the instance using Morph API
      const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await morphClient.instances.get({ instanceId: morphInstanceId });

      if (instance.status !== "paused") {
        // Already running, just return success
        return c.json({ resumed: true });
      }

      await instance.resume();

      // Record the resume for activity tracking (used by cleanup cron)
      // Get teamSlugOrId from request or fall back to instance metadata
      const instanceMetadata = instance.metadata as Record<string, unknown> | undefined;
      const effectiveTeamSlugOrId = teamSlugOrId ?? (instanceMetadata?.teamId as string | undefined);
      if (effectiveTeamSlugOrId && morphInstanceId) {
        try {
          await convex.mutation(api.morphInstances.recordResume, {
            instanceId: morphInstanceId,
            teamSlugOrId: effectiveTeamSlugOrId,
          });
        } catch (recordError) {
          // Don't fail the resume if recording fails
          console.error("[sandboxes.resume] Failed to record resume activity:", recordError);
        }
      }

      return c.json({ resumed: true });
    } catch (error) {
      if (error instanceof HTTPException) {
        return c.text(error.message || "Request failed", error.status);
      }
      console.error("[sandboxes.resume] Failed to resume sandbox:", error);
      return c.text("Failed to resume sandbox", 500);
    }
  },
);
