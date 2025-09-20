import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { MorphCloudClient } from "morphcloud";
import { randomBytes } from "node:crypto";

export const environmentsRouter = new OpenAPIHono();

const CreateEnvironmentBody = z
  .object({
    teamSlugOrId: z.string(),
    name: z.string(),
    morphInstanceId: z.string(),
    envVarsContent: z.string(), // The entire .env file content
    selectedRepos: z.array(z.string()).optional(),
    description: z.string().optional(),
    maintenanceScript: z.string().optional(),
    devScript: z.string().optional(),
    exposedPorts: z.array(z.number()).optional(),
  })
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
    envVarsContent: z.string(),
  })
  .openapi("GetEnvironmentVarsResponse");

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

      // Create Morph snapshot from instance
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({
        instanceId: body.morphInstanceId,
      });

      // Ensure instance belongs to this team (when metadata exists)
      const meta = (instance as unknown as { metadata?: { teamId?: string } })
        .metadata;
      const instanceTeamId = meta?.teamId;
      if (instanceTeamId && instanceTeamId !== team.uuid) {
        return c.text("Forbidden: Instance does not belong to this team", 403);
      }

      try {
        const gitPullSweep = await instance.exec(
          `if [ -d /root/workspaces ]; then
  have_repos="false"
  for dir in /root/workspaces/*; do
    if [ ! -d "$dir" ]; then
      continue
    fi
    if [ -d "$dir/.git" ]; then
      have_repos="true"
      echo "[environments.create] git pull $dir"
      (
        if cd "$dir"; then
          if ! git pull --ff-only; then
            echo "[environments.create] git pull failed $dir" >&2
          fi
        else
          echo "[environments.create] failed to enter $dir" >&2
        fi
      ) &
    fi
  done

  if [ "$have_repos" = "true" ]; then
    wait || true
  fi
else
  echo "[environments.create] /root/workspaces missing"
fi`
        );

        const stdout = gitPullSweep.stdout?.trim();
        if (stdout) {
          console.log(
            `[environments.create] git pull sweep stdout: ${stdout.slice(0, 500)}`
          );
        }

        const stderr = gitPullSweep.stderr?.trim();
        if (stderr) {
          console.log(
            `[environments.create] git pull sweep stderr: ${stderr.slice(0, 500)}`
          );
        }

        if (gitPullSweep.exit_code !== 0) {
          console.warn(
            `[environments.create] git pull sweep exit code: ${gitPullSweep.exit_code}`
          );
        }
      } catch (error) {
        console.error(
          "[environments.create] Failed to run git pull sweep for /root/workspaces",
          error
        );
      }

      const snapshot = await instance.snapshot();

      // Generate a unique key for this environment's data vault entry
      const dataVaultKey = `env_${randomBytes(16).toString("hex")}`;

      // Store environment variables in StackAuth DataBook
      const store =
        await stackServerAppJs.getDataVaultStore("cmux-snapshot-envs");
      await store.setValue(dataVaultKey, body.envVarsContent, {
        secret: env.STACK_DATA_VAULT_SECRET,
      });

      // Create environment record in Convex
      const convexClient = getConvex({ accessToken });
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
          exposedPorts: body.exposedPorts,
        }
      );

      return c.json({
        id: environmentId,
        snapshotId: snapshot.id,
      });
    } catch (error) {
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
        id: (env as unknown as { _id: string })._id,
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
      const environment = await convexClient.query(api.environments.get, {
        teamSlugOrId,
        id: id as string & { __tableName: "environments" },
      });

      if (!environment) {
        return c.text("Environment not found", 404);
      }
      // Map Convex document to API response shape
      const mapped = {
        id: (environment as unknown as { _id: string })._id,
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
      const environment = await convexClient.query(api.environments.get, {
        teamSlugOrId,
        id: id as string & { __tableName: "environments" },
      });

      if (!environment) {
        return c.text("Environment not found", 404);
      }

      // Retrieve environment variables from StackAuth DataBook
      const store =
        await stackServerAppJs.getDataVaultStore("cmux-snapshot-envs");
      const envVarsContent = await store.getValue(environment.dataVaultKey, {
        secret: env.STACK_DATA_VAULT_SECRET,
      });

      if (!envVarsContent) {
        return c.json({ envVarsContent: "" });
      }

      return c.json({ envVarsContent });
    } catch (error) {
      console.error("Failed to get environment variables:", error);
      return c.text("Failed to get environment variables", 500);
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
        id: id as string & { __tableName: "environments" },
      });

      return c.body(null, 204);
    } catch (error) {
      console.error("Failed to delete environment:", error);
      return c.text("Failed to delete environment", 500);
    }
  }
);
