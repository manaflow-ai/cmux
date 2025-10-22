import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import { selectGitIdentity } from "@/lib/utils/gitIdentity";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { RESERVED_CMUX_PORT_SET } from "@cmux/shared/utils/reserved-cmux-ports";
import { typedZid } from "@cmux/shared/utils/typed-zid";
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

const hasNewReservedPort = (
  services: { port: number }[],
  requiredPorts: number[],
): boolean => {
  return requiredPorts.some((port) =>
    !services.some((service) => service.port === port),
  );
};

// Start a new sandbox (currently Morph-backed)
sandboxesRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/sandboxes/start",
    tags: ["Sandboxes"],
    summary: "Start a sandbox environment (Morph-backed)",
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

      const taskRunConvexId = body.taskRunId
        ? typedZid("taskRuns").parse(body.taskRunId)
        : null;

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

      const maintenanceScript = environmentMaintenanceScript ?? null;
      const devScript = environmentDevScript ?? null;

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

      const exposed = instance.networking.httpServices;
      const requiredPorts = [39375, 39376, 39377, 39378, 39379, 39380, 39381, 39383];

      for (const port of requiredPorts) {
        const hasService = exposed.some((service) => service.port === port);
        if (!hasService) {
          try {
            await instance.exposeHttpService(`port-${port}`, port);
          } catch (error) {
            console.error(
              `[sandboxes.start] Failed to expose reserved port ${port}`,
              error,
            );
          }
        }
      }

      const refreshedServices = hasNewReservedPort(
        exposed,
        requiredPorts,
      )
        ? (await client.instances.get({ instanceId: instance.id }))
            .networking.httpServices
        : exposed;
      const vscodeService = refreshedServices.find((s) => s.port === 39378);
      const workerService = refreshedServices.find((s) => s.port === 39377);
      if (!vscodeService || !workerService) {
        await instance.stop().catch(() => { });
        return c.text("VSCode or worker service not found", 500);
      }

      // Get environment variables from the environment if configured
      const environmentEnvVarsContent = await environmentEnvVarsPromise;

      // Prepare environment variables including task JWT if present
      let envVarsToApply = environmentEnvVarsContent || "";

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
        const match = body.repoUrl.match(
          /github\.com\/?([^\s/]+)\/([^\s/.]+)(?:\.git)?/i,
        );
        if (!match) {
          return c.text("Unsupported repo URL; expected GitHub URL", 400);
        }
        const owner = match[1]!;
        const name = match[2]!;
        const repoFull = `${owner}/${name}`;
        console.log(`[sandboxes.start] Parsed owner/repo: ${repoFull}`);

        repoConfig = {
          owner,
          name,
          repoFull,
          cloneUrl: `https://github.com/${owner}/${name}.git`,
          maskedCloneUrl: `https://github.com/${owner}/${name}.git`,
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

      if (maintenanceScript || devScript) {
        (async () => {
          const result = await runMaintenanceAndDevScripts({
            instance,
            maintenanceScript: maintenanceScript || undefined,
            devScript: devScript || undefined,
            identifiers: scriptIdentifiers ?? undefined,
          });
          if (taskRunConvexId && (result.maintenanceError || result.devError)) {
            try {
              await convex.mutation(api.taskRuns.updateEnvironmentError, {
                teamSlugOrId: body.teamSlugOrId,
                id: taskRunConvexId,
                maintenanceError: result.maintenanceError ?? undefined,
                devError: result.devError ?? undefined,
              });
            } catch (mutationError) {
              console.error(
                "[sandboxes.start] Failed to record environment error to taskRun",
                mutationError,
              );
            }
          }
        })().catch((error) => {
          console.error(
            "[sandboxes.start] Background script execution failed:",
            error,
          );
        });
      }

      await configureGitIdentityTask;

      return c.json({
        instanceId: instance.id,
        vscodeUrl: vscodeService.url,
        workerUrl: workerService.url,
        provider: "morph",
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
      return c.text("Failed to start sandbox", 500);
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
