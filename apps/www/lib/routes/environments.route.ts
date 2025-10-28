import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import {
  legacyContentToNestedEnvVars,
  NestedEnvVarsSchema,
} from "@cmux/shared/environment-vars";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { validateExposedPorts } from "@cmux/shared/utils/validate-exposed-ports";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { MorphCloudClient } from "morphcloud";
import { randomBytes } from "node:crypto";
import { determineHttpServiceUpdates } from "./determine-http-service-updates";

export const environmentsRouter = new OpenAPIHono();

const sanitizePortsOrThrow = (ports: readonly number[]): number[] => {
  const validation = validateExposedPorts(ports);
  if (validation.reserved.length > 0) {
    throw new HTTPException(400, {
      message: `Reserved ports cannot be exposed: ${validation.reserved.join(", ")}`,
    });
  }
  if (validation.invalid.length > 0) {
    throw new HTTPException(400, {
      message: `Invalid ports provided: ${validation.invalid.join(", ")}`,
    });
  }
  return validation.sanitized;
};

const serviceNameForPort = (port: number): string => `port-${port}`;

const CreateEnvironmentBody = z
  .object({
    teamSlugOrId: z.string(),
    name: z.string(),
    morphInstanceId: z.string(),
    // Support both legacy string format and new nested format
    envVarsContent: z.string().optional(), // Legacy: .env file content
    nestedEnvVars: NestedEnvVarsSchema.optional(), // New: nested structure
    selectedRepos: z.array(z.string()).optional(),
    description: z.string().optional(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
    exposedPorts: z.array(z.number()).optional(),
  })
  .refine(
    (data) => data.envVarsContent !== undefined || data.nestedEnvVars !== undefined,
    { message: "Either envVarsContent or nestedEnvVars must be provided" }
  )
  .openapi("CreateEnvironmentBody");

const CreateEnvironmentResponse = z
  .object({
    id: z.string(),
    snapshotId: z.string(),
  })
  .openapi("CreateEnvironmentResponse");

const GetEnvironmentResponse = z
  .object({
    id: z.string(),
    name: z.string(),
    morphSnapshotId: z.string(),
    dataVaultKey: z.string(),
    selectedRepos: z.array(z.string()).optional(),
    description: z.string().optional(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
    exposedPorts: z.array(z.number()).optional(),
    createdAt: z.number(),
    updatedAt: z.number(),
  })
  .openapi("GetEnvironmentResponse");

const ListEnvironmentsResponse = z
  .array(GetEnvironmentResponse)
  .openapi("ListEnvironmentsResponse");

const GetEnvironmentVarsResponse = z
  .object({
    envVarsContent: z.string(), // Legacy format for backward compatibility
    nestedEnvVars: NestedEnvVarsSchema, // New nested format
  })
  .openapi("GetEnvironmentVarsResponse");

const UpdateEnvironmentBody = z
  .object({
    teamSlugOrId: z.string(),
    name: z.string().trim().min(1).optional(),
    description: z.string().optional(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
  })
  .refine(
    (value) =>
      value.name !== undefined ||
      value.description !== undefined ||
      value.maintenanceScript !== undefined ||
      value.devScript !== undefined,
    "At least one field must be provided",
  )
  .openapi("UpdateEnvironmentBody");

const ExposedService = z
  .object({
    port: z.number(),
    url: z.string(),
  })
  .openapi("ExposedService");

const UpdateEnvironmentPortsBody = z
  .object({
    teamSlugOrId: z.string(),
    ports: z.array(z.number()),
    morphInstanceId: z.string().optional(),
  })
  .openapi("UpdateEnvironmentPortsBody");

const UpdateEnvironmentPortsResponse = z
  .object({
    exposedPorts: z.array(z.number()),
    services: z.array(ExposedService).optional(),
  })
  .openapi("UpdateEnvironmentPortsResponse");

const SnapshotVersionResponse = z
  .object({
    id: z.string(),
    version: z.number(),
    morphSnapshotId: z.string(),
    createdAt: z.number(),
    createdByUserId: z.string(),
    label: z.string().optional(),
    isActive: z.boolean(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
  })
  .openapi("SnapshotVersionResponse");

const ListSnapshotVersionsResponse = z
  .array(SnapshotVersionResponse)
  .openapi("ListSnapshotVersionsResponse");

const CreateSnapshotVersionBody = z
  .object({
    teamSlugOrId: z.string(),
    morphInstanceId: z.string(),
    label: z.string().optional(),
    activate: z.boolean().optional(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
  })
  .openapi("CreateSnapshotVersionBody");

const CreateSnapshotVersionResponse = z
  .object({
    snapshotVersionId: z.string(),
    snapshotId: z.string(),
    version: z.number(),
  })
  .openapi("CreateSnapshotVersionResponse");

const ActivateSnapshotVersionBody = z
  .object({
    teamSlugOrId: z.string(),
  })
  .openapi("ActivateSnapshotVersionBody");

const ActivateSnapshotVersionResponse = z
  .object({
    morphSnapshotId: z.string(),
    version: z.number(),
  })
  .openapi("ActivateSnapshotVersionResponse");

// Create a new environment
environmentsRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/environments",
    tags: ["Environments"],
    summary: "Create a new environment with snapshot",
    request: {
      body: {
        content: {
          "application/json": {
            schema: CreateEnvironmentBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: CreateEnvironmentResponse,
          },
        },
        description: "Environment created successfully",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to create environment" },
    },
  }),
  async (c) => {
    // Require authentication
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const body = c.req.valid("json");

    try {
      // Verify team access
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      const sanitizedPorts =
        body.exposedPorts && body.exposedPorts.length > 0
          ? sanitizePortsOrThrow(body.exposedPorts)
          : [];

      // Create Morph snapshot from instance
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({
        instanceId: body.morphInstanceId,
      });

      // Ensure instance belongs to this team (when metadata exists)
      const instanceTeamId = instance.metadata?.teamId;
      if (instanceTeamId && instanceTeamId !== team.uuid) {
        return c.text("Forbidden: Instance does not belong to this team", 403);
      }

      const persistDataVaultPromise = (async () => {
        const dataVaultKey = `env_${randomBytes(16).toString("hex")}`;
        const store =
          await stackServerAppJs.getDataVaultStore("cmux-snapshot-envs");

        // Convert to nested format if legacy content is provided
        const nestedEnvVars = body.nestedEnvVars
          ? body.nestedEnvVars
          : body.envVarsContent
            ? legacyContentToNestedEnvVars(body.envVarsContent)
            : { global: [], paths: [] };

        // Store as JSON string in DataVault
        await store.setValue(dataVaultKey, JSON.stringify(nestedEnvVars), {
          secret: env.STACK_DATA_VAULT_SECRET,
        });
        return { dataVaultKey };
      })();

      await instance.exec(
        [
          "git config --global --unset user.name 2>/dev/null || true",
          "git config --global --unset user.email 2>/dev/null || true",
          "git config --global --unset credential.helper 2>/dev/null || true",
          "git credential-cache exit 2>/dev/null || true",
          "gh auth logout 2>/dev/null || true",
        ].join(" && ")
      );

      const snapshot = await instance.snapshot();

      const convexClient = getConvex({ accessToken });
      const { dataVaultKey } = await persistDataVaultPromise;
      const environmentId = await convexClient.mutation(
        api.environments.create,
        {
          teamSlugOrId: body.teamSlugOrId,
          name: body.name,
          morphSnapshotId: snapshot.id,
          dataVaultKey,
          selectedRepos: body.selectedRepos,
          description: body.description,
          maintenanceScript: body.maintenanceScript,
          devScript: body.devScript,
          exposedPorts: sanitizedPorts.length > 0 ? sanitizedPorts : undefined,
        }
      );

      return c.json({
        id: environmentId,
        snapshotId: snapshot.id,
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      console.error("Failed to create environment:", error);
      return c.text("Failed to create environment", 500);
    }
  }
);

// List environments for a team
environmentsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/environments",
    tags: ["Environments"],
    summary: "List environments for a team",
    request: {
      query: z.object({
        teamSlugOrId: z.string(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ListEnvironmentsResponse,
          },
        },
        description: "Environments retrieved successfully",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to list environments" },
    },
  }),
  async (c) => {
    // Require authentication
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { teamSlugOrId } = c.req.valid("query");

    try {
      const convexClient = getConvex({ accessToken });
      const environments = await convexClient.query(api.environments.list, {
        teamSlugOrId,
      });

      // Map Convex documents to API response shape
      const result = environments.map((env) => ({
        id: env._id,
        name: env.name,
        morphSnapshotId: env.morphSnapshotId,
        dataVaultKey: env.dataVaultKey,
        selectedRepos: env.selectedRepos,
        description: env.description,
        maintenanceScript: env.maintenanceScript,
        devScript: env.devScript,
        exposedPorts: env.exposedPorts,
        createdAt: env.createdAt,
        updatedAt: env.updatedAt,
      }));

      return c.json(result);
    } catch (error) {
      console.error("Failed to list environments:", error);
      return c.text("Failed to list environments", 500);
    }
  }
);

// Get a specific environment
environmentsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/environments/{id}",
    tags: ["Environments"],
    summary: "Get a specific environment",
    request: {
      params: z.object({
        id: z.string(),
      }),
      query: z.object({
        teamSlugOrId: z.string(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: GetEnvironmentResponse,
          },
        },
        description: "Environment retrieved successfully",
      },
      401: { description: "Unauthorized" },
      404: { description: "Environment not found" },
      500: { description: "Failed to get environment" },
    },
  }),
  async (c) => {
    // Require authentication
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      const convexClient = getConvex({ accessToken });
      const environmentId = typedZid("environments").parse(id);
      const environment = await convexClient.query(api.environments.get, {
        teamSlugOrId,
        id: environmentId,
      });

      if (!environment) {
        return c.text("Environment not found", 404);
      }
      // Map Convex document to API response shape
      const mapped = {
        id: environment._id,
        name: environment.name,
        morphSnapshotId: environment.morphSnapshotId,
        dataVaultKey: environment.dataVaultKey,
        selectedRepos: environment.selectedRepos,
        description: environment.description,
        maintenanceScript: environment.maintenanceScript,
        devScript: environment.devScript,
        exposedPorts: environment.exposedPorts,
        createdAt: environment.createdAt,
        updatedAt: environment.updatedAt,
      };

      return c.json(mapped);
    } catch (error) {
      console.error("Failed to get environment:", error);
      return c.text("Failed to get environment", 500);
    }
  }
);

// Get environment variables for a specific environment
environmentsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/environments/{id}/vars",
    tags: ["Environments"],
    summary: "Get environment variables for a specific environment",
    request: {
      params: z.object({
        id: z.string(),
      }),
      query: z.object({
        teamSlugOrId: z.string(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: GetEnvironmentVarsResponse,
          },
        },
        description: "Environment variables retrieved successfully",
      },
      401: { description: "Unauthorized" },
      404: { description: "Environment not found" },
      500: { description: "Failed to get environment variables" },
    },
  }),
  async (c) => {
    // Require authentication
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      // Get the environment to retrieve the dataVaultKey
      const convexClient = getConvex({ accessToken });
      const environmentId = typedZid("environments").parse(id);
      const environment = await convexClient.query(api.environments.get, {
        teamSlugOrId,
        id: environmentId,
      });

      if (!environment) {
        return c.text("Environment not found", 404);
      }

      // Retrieve environment variables from StackAuth DataVault
      const store =
        await stackServerAppJs.getDataVaultStore("cmux-snapshot-envs");
      const storedValue = await store.getValue(environment.dataVaultKey, {
        secret: env.STACK_DATA_VAULT_SECRET,
      });

      if (!storedValue) {
        return c.json({
          envVarsContent: "",
          nestedEnvVars: { global: [], paths: [] },
        });
      }

      // Try to parse as nested format (JSON)
      let nestedEnvVars;
      try {
        nestedEnvVars = JSON.parse(storedValue);
        // Validate it's a nested structure
        if (typeof nestedEnvVars !== "object" || !Array.isArray(nestedEnvVars.global)) {
          throw new Error("Invalid nested format");
        }
      } catch {
        // If parsing fails or validation fails, treat as legacy format
        nestedEnvVars = legacyContentToNestedEnvVars(storedValue);
      }

      // Return both formats for compatibility
      return c.json({
        envVarsContent: storedValue, // Keep raw value for backward compatibility
        nestedEnvVars,
      });
    } catch (error) {
      console.error("Failed to get environment variables:", error);
      return c.text("Failed to get environment variables", 500);
    }
  }
);

// Update metadata for an environment
environmentsRouter.openapi(
  createRoute({
    method: "patch" as const,
    path: "/environments/{id}",
    tags: ["Environments"],
    summary: "Update environment metadata",
    request: {
      params: z.object({
        id: z.string(),
      }),
      body: {
        content: {
          "application/json": {
            schema: UpdateEnvironmentBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: GetEnvironmentResponse,
          },
        },
        description: "Environment updated successfully",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Environment not found" },
      500: { description: "Failed to update environment" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const environmentId = typedZid("environments").parse(id);

    try {
      await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      const convexClient = getConvex({ accessToken });
      await convexClient.mutation(api.environments.update, {
        teamSlugOrId: body.teamSlugOrId,
        id: environmentId,
        name: body.name,
        description: body.description,
        maintenanceScript: body.maintenanceScript,
        devScript: body.devScript,
      });

      const updated = await convexClient.query(api.environments.get, {
        teamSlugOrId: body.teamSlugOrId,
        id: environmentId,
      });

      if (!updated) {
        return c.text("Environment not found", 404);
      }

      return c.json({
        id: updated._id,
        name: updated.name,
        morphSnapshotId: updated.morphSnapshotId,
        dataVaultKey: updated.dataVaultKey,
        selectedRepos: updated.selectedRepos ?? undefined,
        description: updated.description ?? undefined,
        maintenanceScript: updated.maintenanceScript ?? undefined,
        devScript: updated.devScript ?? undefined,
        exposedPorts: updated.exposedPorts ?? undefined,
        createdAt: updated.createdAt,
        updatedAt: updated.updatedAt,
      });
    } catch (error) {
      if (error instanceof Error && error.message === "Environment not found") {
        return c.text("Environment not found", 404);
      }

      console.error("Failed to update environment:", error);
      return c.text("Failed to update environment", 500);
    }
  }
);

// Update exposed ports for an environment
environmentsRouter.openapi(
  createRoute({
    method: "patch" as const,
    path: "/environments/{id}/ports",
    tags: ["Environments"],
    summary: "Update exposed ports for an environment",
    request: {
      params: z.object({
        id: z.string(),
      }),
      body: {
        content: {
          "application/json": {
            schema: UpdateEnvironmentPortsBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: UpdateEnvironmentPortsResponse,
          },
        },
        description: "Exposed ports updated successfully",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Environment not found" },
      500: { description: "Failed to update environment ports" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const environmentId = typedZid("environments").parse(id);

    try {
      const sanitizedPorts = sanitizePortsOrThrow(body.ports);
      const convexClient = getConvex({ accessToken });
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      let services:
        | Array<{
            port: number;
            url: string;
          }>
        | undefined;

      if (body.morphInstanceId) {
        const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
        const instance = await morphClient.instances.get({
          instanceId: body.morphInstanceId,
        });

        const metadata = instance.metadata;
        const instanceTeamId = metadata?.teamId;
        if (instanceTeamId && instanceTeamId !== team.uuid) {
          return c.text(
            "Forbidden: Instance does not belong to this team",
            403
          );
        }
        const metadataEnvironmentId = metadata?.environmentId;
        if (metadataEnvironmentId && metadataEnvironmentId !== id) {
          return c.text(
            "Forbidden: Instance does not belong to this environment",
            403
          );
        }

        const workingInstance = instance;
        const { servicesToHide, portsToExpose, servicesToKeep } =
          determineHttpServiceUpdates(
            workingInstance.networking.httpServices,
            sanitizedPorts
          );

        const hidePromises = servicesToHide.map((service) =>
          workingInstance.hideHttpService(service.name)
        );

        const exposePromises = portsToExpose.map((port) => {
          const serviceName = serviceNameForPort(port);
          return (async () => {
            try {
              return await workingInstance.exposeHttpService(serviceName, port);
            } catch (error) {
              console.error(
                `[environments.updatePorts] Failed to expose ${serviceName}`,
                error
              );
              throw new HTTPException(500, {
                message: `Failed to expose ${serviceName}`,
              });
            }
          })();
        });

        const [_, newlyExposedServices] = await Promise.all([
          Promise.all(hidePromises),
          Promise.all(exposePromises),
        ]);

        const serviceUrls = new Map<number, string>();

        for (const service of servicesToKeep) {
          serviceUrls.set(service.port, service.url);
        }

        for (const service of newlyExposedServices) {
          serviceUrls.set(service.port, service.url);
        }

        services = Array.from(serviceUrls.entries())
          .sort((a, b) => a[0] - b[0])
          .map(([port, url]) => ({ port, url }));
      }

      const updatedPorts = await convexClient.mutation(
        api.environments.updateExposedPorts,
        {
          teamSlugOrId: body.teamSlugOrId,
          id: environmentId,
          ports: sanitizedPorts,
        }
      );

      return c.json({
        exposedPorts: updatedPorts,
        ...(services ? { services } : {}),
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      if (error instanceof Error && error.message === "Environment not found") {
        return c.text("Environment not found", 404);
      }
      console.error("Failed to update environment ports:", error);
      return c.text("Failed to update environment ports", 500);
    }
  }
);

// List snapshot versions for an environment
environmentsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/environments/{id}/snapshots",
    tags: ["Environments"],
    summary: "List snapshot versions for an environment",
    request: {
      params: z.object({
        id: z.string(),
      }),
      query: z.object({
        teamSlugOrId: z.string(),
      }),
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ListSnapshotVersionsResponse,
          },
        },
        description: "Snapshot versions retrieved successfully",
      },
      401: { description: "Unauthorized" },
      404: { description: "Environment not found" },
      500: { description: "Failed to list snapshot versions" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      const environmentId = typedZid("environments").parse(id);
      const convexClient = getConvex({ accessToken });
      const [environment, versions] = await Promise.all([
        convexClient.query(api.environments.get, {
          teamSlugOrId,
          id: environmentId,
        }),
        convexClient.query(api.environmentSnapshots.list, {
          teamSlugOrId,
          environmentId,
        }),
      ]);

      if (!environment) {
        return c.text("Environment not found", 404);
      }

      const mapped = versions.map((version) => ({
        id: String(version._id),
        version: version.version,
        morphSnapshotId: version.morphSnapshotId,
        createdAt: version.createdAt,
        createdByUserId: version.createdByUserId,
        label: version.label ?? undefined,
        isActive: version.isActive,
        maintenanceScript: version.maintenanceScript ?? undefined,
        devScript: version.devScript ?? undefined,
      }));

      return c.json(mapped);
    } catch (error) {
      console.error("Failed to list snapshot versions:", error);
      return c.text("Failed to list snapshot versions", 500);
    }
  }
);

// Create a new snapshot version from a running instance
environmentsRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/environments/{id}/snapshots",
    tags: ["Environments"],
    summary: "Create a new snapshot version from a running instance",
    request: {
      params: z.object({
        id: z.string(),
      }),
      body: {
        content: {
          "application/json": {
            schema: CreateSnapshotVersionBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: CreateSnapshotVersionResponse,
          },
        },
        description: "Snapshot version created successfully",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Environment not found" },
      500: { description: "Failed to create snapshot version" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const environmentId = typedZid("environments").parse(id);

    try {
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      const convexClient = getConvex({ accessToken });
      const morphClient = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await morphClient.instances.get({
        instanceId: body.morphInstanceId,
      });

      const metadata = instance.metadata;
      const instanceTeamId = metadata?.teamId;
      if (instanceTeamId && instanceTeamId !== team.uuid) {
        return c.text("Forbidden: Instance does not belong to this team", 403);
      }
      const metadataEnvironmentId = metadata?.environmentId;
      if (metadataEnvironmentId && metadataEnvironmentId !== id) {
        return c.text(
          "Forbidden: Instance does not belong to this environment",
          403
        );
      }

      const snapshot = await instance.snapshot();

      const creation = await convexClient.mutation(
        api.environmentSnapshots.create,
        {
          teamSlugOrId: body.teamSlugOrId,
          environmentId,
          morphSnapshotId: snapshot.id,
          label: body.label,
          activate: body.activate,
          maintenanceScript: body.maintenanceScript,
          devScript: body.devScript,
        }
      );

      return c.json({
        snapshotVersionId: String(creation.snapshotVersionId),
        snapshotId: snapshot.id,
        version: creation.version,
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      if (error instanceof Error && error.message === "Environment not found") {
        return c.text("Environment not found", 404);
      }
      console.error("Failed to create snapshot version:", error);
      return c.text("Failed to create snapshot version", 500);
    }
  }
);

// Activate a specific snapshot version
environmentsRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/environments/{id}/snapshots/{snapshotVersionId}/activate",
    tags: ["Environments"],
    summary: "Activate a snapshot version for an environment",
    request: {
      params: z.object({
        id: z.string(),
        snapshotVersionId: z.string(),
      }),
      body: {
        content: {
          "application/json": {
            schema: ActivateSnapshotVersionBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ActivateSnapshotVersionResponse,
          },
        },
        description: "Snapshot version activated successfully",
      },
      401: { description: "Unauthorized" },
      404: { description: "Snapshot version not found" },
      500: { description: "Failed to activate snapshot version" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id, snapshotVersionId } = c.req.valid("param");
    const body = c.req.valid("json");

    try {
      const environmentId = typedZid("environments").parse(id);
      const versionId = typedZid("environmentSnapshotVersions").parse(
        snapshotVersionId
      );
      const convexClient = getConvex({ accessToken });

      await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      const result = await convexClient.mutation(
        api.environmentSnapshots.activate,
        {
          teamSlugOrId: body.teamSlugOrId,
          environmentId,
          snapshotVersionId: versionId,
        }
      );

      return c.json(result);
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      if (
        error instanceof Error &&
        error.message === "Snapshot version not found"
      ) {
        return c.text("Snapshot version not found", 404);
      }
      if (error instanceof Error && error.message === "Environment not found") {
        return c.text("Environment not found", 404);
      }
      console.error("Failed to activate snapshot version:", error);
      return c.text("Failed to activate snapshot version", 500);
    }
  }
);

// Delete an environment
environmentsRouter.openapi(
  createRoute({
    method: "delete" as const,
    path: "/environments/{id}",
    tags: ["Environments"],
    summary: "Delete an environment",
    request: {
      params: z.object({
        id: z.string(),
      }),
      query: z.object({
        teamSlugOrId: z.string(),
      }),
    },
    responses: {
      204: { description: "Environment deleted successfully" },
      401: { description: "Unauthorized" },
      404: { description: "Environment not found" },
      500: { description: "Failed to delete environment" },
    },
  }),
  async (c) => {
    // Require authentication
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { id } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("query");

    try {
      const convexClient = getConvex({ accessToken });
      await convexClient.mutation(api.environments.remove, {
        teamSlugOrId,
        id: typedZid("environments").parse(id),
      });

      return c.body(null, 204);
    } catch (error) {
      console.error("Failed to delete environment:", error);
      return c.text("Failed to delete environment", 500);
    }
  }
);
