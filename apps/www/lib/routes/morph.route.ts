import {
  DEFAULT_MORPH_SNAPSHOT_ID,
  MORPH_SNAPSHOT_PRESETS,
  type MorphSnapshotId,
} from "@/lib/utils/morph-defaults";
import { getAccessTokenFromRequest, getUserFromRequest } from "@/lib/utils/auth";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { type Instance, MorphCloudClient } from "morphcloud";
import { getConvex } from "../utils/get-convex";
import { selectGitIdentity } from "../utils/gitIdentity";
import { stackServerAppJs } from "../utils/stack";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import {
  configureGithubAccess,
  configureGitIdentity,
  fetchGitIdentityInputs,
} from "./sandboxes/git";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import * as Sentry from "@sentry/nextjs";

export const morphRouter = new OpenAPIHono();

const morphSnapshotIds = MORPH_SNAPSHOT_PRESETS.map(
  (preset) => preset.id
) as MorphSnapshotId[];

const SnapshotIdSchema = z.enum(
  morphSnapshotIds as [MorphSnapshotId, ...MorphSnapshotId[]]
);

const SetupInstanceBody = z
  .object({
    teamSlugOrId: z.string(),
    instanceId: z.string().optional(), // Existing instance ID to reuse
    selectedRepos: z.array(z.string()).optional(), // Repositories to clone
    ttlSeconds: z.number().default(60 * 30), // 30 minutes default
    // TODO: This is a temporary solution to allow both string and enum values since client values are diff from backend values
    snapshotId: z.union([z.string(), SnapshotIdSchema]).optional(),
  })
  .openapi("SetupInstanceBody");

const SetupInstanceResponse = z
  .object({
    instanceId: z.string(),
    vscodeUrl: z.string(),
    clonedRepos: z.array(z.string()),
    removedRepos: z.array(z.string()),
  })
  .openapi("SetupInstanceResponse");

const ResumeTaskRunBody = z
  .object({
    teamSlugOrId: z.string(),
  })
  .openapi("ResumeTaskRunBody");

const CheckTaskRunPausedBody = z
  .object({
    teamSlugOrId: z.string(),
  })
  .openapi("CheckTaskRunPausedBody");

const ResumeTaskRunResponse = z
  .object({
    resumed: z.literal(true),
  })
  .openapi("ResumeTaskRunResponse");

const CheckTaskRunPausedResponse = z
  .object({
    paused: z.boolean(),
  })
  .openapi("CheckTaskRunPausedResponse");

morphRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/morph/task-runs/{taskRunId}/resume",
    tags: ["Morph"],
    summary: "Resume the Morph instance backing a task run",
    request: {
      params: z.object({
        taskRunId: typedZid("taskRuns"),
      }),
      body: {
        content: {
          "application/json": {
            schema: ResumeTaskRunBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ResumeTaskRunResponse,
          },
        },
        description: "Morph instance resumed",
      },
      400: { description: "Task run is not backed by a Morph instance" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Task run or instance not found" },
      500: { description: "Failed to resume instance" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { taskRunId } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("json");

    const convex = getConvex({ accessToken });
    const team = await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const taskRun = await convex.query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    if (!taskRun) {
      return c.text("Task run not found", 404);
    }

    const instanceId = taskRun.vscode?.containerName;
    const isMorphProvider = taskRun.vscode?.provider === "morph";

    if (!isMorphProvider || !instanceId) {
      return c.text("Task run is not backed by a Morph instance", 400);
    }

    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId });
      void (async () => {
        try {
          await instance.setWakeOn(true, true);
        } catch (error) {
          console.error("[morph.resume-task-run] Failed to set wake on", error);
        }
      })();

      const metadataTeamId = (
        instance as unknown as {
          metadata?: { teamId?: string };
        }
      ).metadata?.teamId;

      if (metadataTeamId && metadataTeamId !== team.uuid) {
        return c.text("Forbidden", 403);
      }

      await instance.resume();

      await convex.mutation(api.taskRuns.updateVSCodeStatus, {
        teamSlugOrId,
        id: taskRunId as Id<"taskRuns">,
        status: "running",
      });

      return c.json({ resumed: true });
    } catch (error) {
      console.error("[morph.resume-task-run] Failed to resume instance", error);
      return c.text("Failed to resume instance", 500);
    }
  }
);

morphRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/morph/task-runs/{taskRunId}/is-paused",
    tags: ["Morph"],
    summary: "Check if the Morph instance backing a task run is paused",
    request: {
      params: z.object({
        taskRunId: typedZid("taskRuns"),
      }),
      body: {
        content: {
          "application/json": {
            schema: CheckTaskRunPausedBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: CheckTaskRunPausedResponse,
          },
        },
        description: "Morph instance status returned",
      },
      400: { description: "Task run is not backed by a Morph instance" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Task run or instance not found" },
      500: { description: "Failed to check instance status" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { taskRunId } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("json");

    const convex = getConvex({ accessToken });
    const team = await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const taskRun = await convex.query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    if (!taskRun) {
      return c.text("Task run not found", 404);
    }

    const instanceId = taskRun.vscode?.containerName;
    const isMorphProvider = taskRun.vscode?.provider === "morph";

    if (!isMorphProvider || !instanceId) {
      return c.text("Task run is not backed by a Morph instance", 400);
    }

    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId });

      const metadataTeamId = (
        instance as unknown as {
          metadata?: { teamId?: string };
        }
      ).metadata?.teamId;

      if (metadataTeamId && metadataTeamId !== team.uuid) {
        return c.text("Forbidden", 403);
      }

      return c.json({ paused: instance.status === "paused" });
    } catch (error) {
      console.error(
        "[morph.check-task-run-paused] Failed to check instance status",
        error
      );
      return c.text("Failed to check instance status", 500);
    }
  }
);

const RefreshGitHubAuthBody = z
  .object({
    teamSlugOrId: z.string(),
  })
  .openapi("RefreshGitHubAuthBody");

const RefreshGitHubAuthResponse = z
  .object({
    refreshed: z.literal(true),
  })
  .openapi("RefreshGitHubAuthResponse");

/**
 * Fetches a fresh GitHub access token for the authenticated user.
 * This is a reusable helper to avoid duplicating token retrieval logic.
 */
async function getFreshGitHubToken(
  user: Awaited<ReturnType<typeof stackServerAppJs.getUser>>
): Promise<{ token: string } | { error: string; status: 401 }> {
  if (!user) {
    return { error: "Unauthorized", status: 401 };
  }
  const githubAccount = await user.getConnectedAccount("github");
  if (!githubAccount) {
    return { error: "GitHub account not connected", status: 401 };
  }
  const { accessToken: githubAccessToken } =
    await githubAccount.getAccessToken();
  if (!githubAccessToken) {
    return { error: "Failed to get GitHub access token", status: 401 };
  }
  return { token: githubAccessToken };
}

morphRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/morph/task-runs/{taskRunId}/refresh-github-auth",
    tags: ["Morph"],
    summary: "Refresh GitHub authentication on a Morph instance",
    description:
      "Re-authenticates the GitHub CLI inside a running Morph VM with a fresh token. " +
      "Useful when the token has expired or the user has re-connected their GitHub account.",
    request: {
      params: z.object({
        taskRunId: typedZid("taskRuns"),
      }),
      body: {
        content: {
          "application/json": {
            schema: RefreshGitHubAuthBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: RefreshGitHubAuthResponse,
          },
        },
        description: "GitHub authentication refreshed successfully",
      },
      400: { description: "Task run is not backed by a Morph instance" },
      401: { description: "Unauthorized or GitHub not connected" },
      403: { description: "Forbidden - instance does not belong to this team" },
      404: { description: "Task run not found" },
      409: { description: "Instance is paused - resume it first" },
      500: { description: "Failed to refresh GitHub authentication" },
    },
  }),
  async (c) => {
    // Authenticate user via Stack Auth (server-side token retrieval)
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { taskRunId } = c.req.valid("param");
    const { teamSlugOrId } = c.req.valid("json");

    // Verify team access
    const convex = getConvex({ accessToken });
    const team = await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    // Get task run
    const taskRun = await convex.query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    if (!taskRun) {
      return c.text("Task run not found", 404);
    }

    const instanceId = taskRun.vscode?.containerName;
    const isMorphProvider = taskRun.vscode?.provider === "morph";

    if (!isMorphProvider || !instanceId) {
      return c.text("Task run is not backed by a Morph instance", 400);
    }

    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.get({ instanceId });

      // Security: ensure the instance belongs to the requested team
      const metadataTeamId = (
        instance as unknown as {
          metadata?: { teamId?: string };
        }
      ).metadata?.teamId;

      if (metadataTeamId && metadataTeamId !== team.uuid) {
        return c.text("Forbidden", 403);
      }

      // Check if instance is paused - auth refresh requires running instance
      if (instance.status === "paused") {
        return c.text("Instance is paused - resume it first", 409);
      }

      // Get fresh GitHub token (server-side, never from client)
      const tokenResult = await getFreshGitHubToken(user);
      if ("error" in tokenResult) {
        return c.text(tokenResult.error, tokenResult.status);
      }

      // Use the existing configureGithubAccess function to refresh auth
      await configureGithubAccess(instance, tokenResult.token);

      console.log(
        `[morph.refresh-github-auth] Successfully refreshed GitHub auth for instance ${instanceId}`
      );

      return c.json({ refreshed: true });
    } catch (error) {
      console.error(
        "[morph.refresh-github-auth] Failed to refresh GitHub auth:",
        error
      );
      return c.text("Failed to refresh GitHub authentication", 500);
    }
  }
);

morphRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/morph/setup-instance",
    tags: ["Morph"],
    summary: "Setup a Morph instance with optional repository cloning",
    request: {
      body: {
        content: {
          "application/json": {
            schema: SetupInstanceBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: SetupInstanceResponse,
          },
        },
        description: "Instance setup successfully",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to setup instance" },
    },
  }),
  async (c) => {
    // Use getUserFromRequest which supports both cookie-based (web) and Bearer token (CLI) auth
    const user = await Sentry.startSpan(
      { name: "getUserFromRequest", op: "auth" },
      () => getUserFromRequest(c.req.raw)
    );
    if (!user) {
      return c.text("Unauthorized", 401);
    }
    const { accessToken } = await Sentry.startSpan(
      { name: "user.getAuthJson", op: "auth" },
      () => user.getAuthJson()
    );
    if (!accessToken) return c.text("Unauthorized", 401);
    const {
      teamSlugOrId,
      instanceId: existingInstanceId,
      selectedRepos,
      ttlSeconds,
      snapshotId,
    } = c.req.valid("json");

    const convex = getConvex({ accessToken });

    const verifyTeamPromise = Sentry.startSpan(
      { name: "verifyTeamAccess", op: "auth" },
      () => verifyTeamAccess({ req: c.req.raw, teamSlugOrId })
    );

    const githubAccessTokenPromise = Sentry.startSpan(
      { name: "getGithubAccessToken", op: "auth" },
      async () => {
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
      }
    );

    const gitIdentityPromise = githubAccessTokenPromise.then(
      ({ githubAccessToken }) => {
        if (!githubAccessToken) {
          throw new Error("GitHub access token not found");
        }
        return Sentry.startSpan(
          { name: "fetchGitIdentityInputs", op: "db" },
          () => fetchGitIdentityInputs(convex, githubAccessToken)
        );
      }
    );

    try {
      const client = new MorphCloudClient({
        apiKey: env.MORPH_API_KEY,
      });

      let instance: Instance;
      let instanceId = existingInstanceId;
      const selectedSnapshotId = snapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID;

      if (!instanceId) {
        const team = await verifyTeamPromise;

        console.log(
          `Creating new Morph instance (snapshot: ${selectedSnapshotId})`
        );
        instance = await Sentry.startSpan(
          { name: "client.instances.start", op: "morph" },
          () =>
            client.instances.start({
              snapshotId: selectedSnapshotId,
              ttlSeconds,
              ttlAction: "pause",
              metadata: {
                app: "cmux-dev",
                userId: user.id,
                teamId: team.uuid,
              },
            })
        );
        instanceId = instance.id;
        void Sentry.startSpan(
          { name: "instance.setWakeOn", op: "morph" },
          () => instance.setWakeOn(true, true)
        );
      } else {
        console.log(`Using existing Morph instance: ${instanceId}`);

        const [team, inst] = await Promise.all([
          verifyTeamPromise,
          Sentry.startSpan({ name: "client.instances.get", op: "morph" }, () =>
            client.instances.get({ instanceId: instanceId! })
          ),
        ]);

        instance = inst;

        const meta = instance.metadata;
        const instanceTeamId = meta?.teamId;
        if (!instanceTeamId || instanceTeamId !== team.uuid) {
          return c.text(
            "Forbidden: Instance does not belong to this team",
            403
          );
        }
      }

      const vscodeUrl = instance.networking.httpServices.find(
        (service) => service.port === 39378
      )?.url;

      if (!vscodeUrl) {
        throw new Error("VSCode URL not found");
      }

      const { githubAccessToken, githubAccessTokenError } =
        await githubAccessTokenPromise;
      if (githubAccessTokenError) {
        console.error(
          `[sandboxes.start] GitHub access token error: ${githubAccessTokenError}`
        );
        return c.text("Failed to resolve GitHub credentials", 401);
      }

      const configureGithubPromise = Sentry.startSpan(
        { name: "configureGithubAccess", op: "morph.exec" },
        () => configureGithubAccess(instance, githubAccessToken)
      );

      void gitIdentityPromise
        .then(([who, gh]) => {
          const { name, email } = selectGitIdentity(who, gh);
          return Sentry.startSpan(
            { name: "configureGitIdentity", op: "morph.exec" },
            () => configureGitIdentity(instance, { name, email })
          );
        })
        .catch((error) => {
          console.log(
            `[sandboxes.start] Failed to configure git identity; continuing...`,
            error
          );
        });

      await configureGithubPromise;

      const url = `${vscodeUrl}/?folder=/root/workspace`;

      const removedRepos: string[] = [];
      const clonedRepos: string[] = [];
      const failedClones: { repo: string; error: string; isAuth: boolean }[] =
        [];

      if (selectedRepos && selectedRepos.length > 0) {
        const repoNames = new Map<string, string>();
        const reposByOwner = new Map<string, string[]>();
        for (const repo of selectedRepos) {
          if (!repo.includes("/") || repo.split("/").length !== 2) {
            return c.text(
              `Invalid repository format: ${repo}. Expected format: owner/repo`,
              400
            );
          }

          const [owner, repoName] = repo.split("/");
          if (!repoName) {
            return c.text(`Invalid repository: ${repo}`, 400);
          }

          if (repoNames.has(repoName)) {
            return c.text(
              `Duplicate repository name detected: '${repoName}' from both '${repoNames.get(repoName)}' and '${repo}'. ` +
                `Repositories with the same name cannot be cloned to the same workspace.`,
              400
            );
          }
          repoNames.set(repoName, repo);

          if (!reposByOwner.has(owner)) {
            reposByOwner.set(owner, []);
          }
          reposByOwner.get(owner)!.push(repo);
        }

        const listReposCmd = await Sentry.startSpan(
          { name: "instance.exec (list repos)", op: "morph.exec" },
          () =>
            instance.exec(
              "for dir in /root/workspace/*/; do " +
                'if [ -d "$dir/.git" ]; then ' +
                'basename "$dir"; ' +
                "cd \"$dir\" && git remote get-url origin 2>/dev/null || echo 'no-remote'; " +
                "fi; done"
            )
        );

        const lines = listReposCmd.stdout.split("\n").filter(Boolean);
        const existingRepos = new Map<string, string>();

        for (let i = 0; i < lines.length; i += 2) {
          const repoName = lines[i]?.trim();
          const remoteUrl = lines[i + 1]?.trim();
          if (repoName && remoteUrl && remoteUrl !== "no-remote") {
            existingRepos.set(repoName, remoteUrl);
          } else if (repoName) {
            existingRepos.set(repoName, "");
          }
        }

        for (const [existingName, existingUrl] of existingRepos) {
          const selectedRepo = repoNames.get(existingName);

          if (!selectedRepo) {
            console.log(`Removing repository: ${existingName}`);
            await Sentry.startSpan(
              { name: `instance.exec (rm ${existingName})`, op: "morph.exec" },
              () => instance.exec(`rm -rf /root/workspace/${existingName}`)
            );
            removedRepos.push(existingName);
          } else if (existingUrl && !existingUrl.includes(selectedRepo)) {
            console.log(
              `Repository ${existingName} points to different remote, removing for re-clone`
            );
            await Sentry.startSpan(
              { name: `instance.exec (rm ${existingName})`, op: "morph.exec" },
              () => instance.exec(`rm -rf /root/workspace/${existingName}`)
            );
            removedRepos.push(existingName);
            existingRepos.delete(existingName);
          }
        }

        for (const [, repos] of reposByOwner) {
          const clonePromises = repos.map(async (repo) => {
            const repoName = repo.split("/").pop()!;
            if (!existingRepos.has(repoName)) {
              console.log(`Cloning repository: ${repo}`);

              const maxRetries = 3;
              let lastError: string | undefined;
              let isAuthError = false;

              for (let attempt = 1; attempt <= maxRetries; attempt++) {
                const cloneCmd = await Sentry.startSpan(
                  {
                    name: `instance.exec (clone ${repoName})`,
                    op: "morph.exec",
                    attributes: { attempt },
                  },
                  () =>
                    instance.exec(
                      `mkdir -p /root/workspace && cd /root/workspace && git clone https://github.com/${repo}.git ${repoName} 2>&1`
                    )
                );

                if (cloneCmd.exit_code === 0) {
                  return { success: true as const, repo };
                } else {
                  lastError = cloneCmd.stderr || cloneCmd.stdout;

                  isAuthError =
                    lastError.includes("Authentication failed") ||
                    lastError.includes("could not read Username") ||
                    lastError.includes("could not read Password") ||
                    lastError.includes("Invalid username or password") ||
                    lastError.includes("Permission denied") ||
                    lastError.includes("Repository not found") ||
                    lastError.includes("403");

                  if (isAuthError) {
                    console.error(
                      `Authentication failed for ${repo}: ${lastError}`
                    );
                    break;
                  }

                  if (attempt < maxRetries) {
                    console.log(
                      `Clone attempt ${attempt} failed for ${repo}, retrying...`
                    );
                    await instance.exec(`rm -rf /root/workspace/${repoName}`);
                    await new Promise((resolve) =>
                      setTimeout(resolve, attempt * 1000)
                    );
                  }
                }
              }

              const errorMsg = isAuthError
                ? `Authentication failed - check repository access permissions`
                : `Failed after ${maxRetries} attempts`;

              console.error(
                `Failed to clone ${repo}: ${errorMsg}\nDetails: ${lastError}`
              );
              return {
                success: false as const,
                repo,
                error: lastError || "Unknown error",
                isAuth: isAuthError,
              };
            } else {
              console.log(
                `Repository ${repo} already exists with correct remote, skipping clone`
              );
              return null;
            }
          });

          const results = await Promise.all(clonePromises);

          for (const result of results) {
            if (result && "success" in result) {
              if (result.success) {
                clonedRepos.push(result.repo);
              } else {
                failedClones.push({
                  repo: result.repo,
                  error: result.error,
                  isAuth: result.isAuth,
                });
              }
            }
          }
        }
      }

      console.log(`VSCode Workspace URL: ${url}`);

      return c.json({
        instanceId,
        vscodeUrl: url,
        clonedRepos,
        removedRepos,
        failedClones,
      });
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      console.error("Failed to setup Morph instance:", error);
      return c.text("Failed to setup instance", 500);
    }
  }
);

// =============================================================================
// List Morph Instances
// =============================================================================

const ListInstancesQuery = z
  .object({
    teamId: z.string().optional(),
  })
  .openapi("ListInstancesQuery");

const InstanceInfo = z
  .object({
    id: z.string(),
    status: z.string(),
    createdAt: z.string().optional(),
    metadata: z
      .object({
        app: z.string().optional(),
        userId: z.string().optional(),
        teamId: z.string().optional(),
      })
      .optional(),
  })
  .openapi("InstanceInfo");

const ListInstancesResponse = z.array(InstanceInfo).openapi("ListInstancesResponse");

morphRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/morph/instances",
    tags: ["Morph"],
    summary: "List Morph instances for the authenticated user",
    request: {
      query: ListInstancesQuery,
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: ListInstancesResponse,
          },
        },
        description: "List of Morph instances",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to list instances" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    const { teamId } = c.req.valid("query");

    try {
      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });

      // List all instances from Morph
      const instances = await client.instances.list();

      // Filter instances that belong to cmux and optionally by team
      const filteredInstances = instances.filter((instance) => {
        const meta = instance.metadata as
          | { app?: string; teamId?: string; userId?: string }
          | undefined;

        // Only show cmux instances
        if (meta?.app !== "cmux-dev") {
          return false;
        }

        // Filter by team if specified
        if (teamId && meta?.teamId !== teamId) {
          return false;
        }

        return true;
      });

      // Map to response format
      const response = filteredInstances.map((instance) => ({
        id: instance.id,
        status: instance.status,
        createdAt: (instance as unknown as { created?: string }).created,
        metadata: instance.metadata as
          | { app?: string; userId?: string; teamId?: string }
          | undefined,
      }));

      return c.json(response);
    } catch (error) {
      console.error("[morph.list-instances] Failed to list instances:", error);
      return c.text("Failed to list instances", 500);
    }
  }
);
