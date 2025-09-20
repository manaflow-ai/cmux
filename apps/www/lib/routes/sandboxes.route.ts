import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import {
  generateGitHubInstallationToken,
  getInstallationForRepo,
} from "@/lib/utils/github-app-token";
import { fetchGithubUserInfoForRequest } from "@/lib/utils/githubUserInfo";
import { selectGitIdentity } from "@/lib/utils/gitIdentity";
import { DEFAULT_MORPH_SNAPSHOT_ID } from "@/lib/utils/morph-defaults";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { MorphCloudClient } from "morphcloud";
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
      .default(20 * 60),
    metadata: z.record(z.string(), z.string()).optional(),
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
    // Require authentication (via access token header/cookie)
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

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
      // Verify team access
      const team = await verifyTeamAccess({
        req: c.req.raw,
        teamSlugOrId: body.teamSlugOrId,
      });

      // Determine snapshotId with access checks
      const convex = getConvex({ accessToken });

      let resolvedSnapshotId: string | null = null;
      let environmentDataVaultKey: string | undefined;

      if (body.environmentId) {
        const environmentId = typedZid("environments").parse(
          body.environmentId
        );
        // Verify the environment belongs to this team
        const envDoc = await convex.query(api.environments.get, {
          teamSlugOrId: body.teamSlugOrId,
          id: environmentId,
        });
        if (!envDoc) {
          return c.text("Environment not found or not accessible", 403);
        }
        resolvedSnapshotId = envDoc.morphSnapshotId;
        environmentDataVaultKey = envDoc.dataVaultKey;
      } else if (body.snapshotId) {
        // Ensure the provided snapshotId belongs to one of the team's environments
        const envs = await convex.query(api.environments.list, {
          teamSlugOrId: body.teamSlugOrId,
        });
        const match = envs.find((e) => e.morphSnapshotId === body.snapshotId);
        if (!match) {
          return c.text(
            "Forbidden: Snapshot does not belong to this team",
            403
          );
        }
        resolvedSnapshotId = match.morphSnapshotId;
      } else {
        // Fall back to default snapshot if nothing provided
        resolvedSnapshotId = DEFAULT_MORPH_SNAPSHOT_ID;
      }

      let environmentEnvVarsContent: string | null = null;
      if (environmentDataVaultKey) {
        try {
          const store =
            await stackServerAppJs.getDataVaultStore("cmux-snapshot-envs");
          environmentEnvVarsContent = await store.getValue(
            environmentDataVaultKey,
            {
              secret: env.STACK_DATA_VAULT_SECRET,
            }
          );
          try {
            const length = environmentEnvVarsContent?.length ?? 0;
            console.log(
              `[sandboxes.start] Loaded environment env vars (chars=${length})`
            );
          } catch {
            /* noop */
          }
        } catch (error) {
          console.error(
            "[sandboxes.start] Failed to fetch environment env vars",
            error
          );
        }
      }

      const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
      const instance = await client.instances.start({
        snapshotId: resolvedSnapshotId,
        ttlSeconds: body.ttlSeconds ?? 20 * 60,
        ttlAction: "pause",
        metadata: {
          app: "cmux",
          teamId: team.uuid,
          ...(body.environmentId ? { environmentId: body.environmentId } : {}),
          ...(body.metadata || {}),
        },
      });

      const exposed = instance.networking.httpServices;
      const vscodeService = exposed.find((s) => s.port === 39378);
      const workerService = exposed.find((s) => s.port === 39377);
      if (!vscodeService || !workerService) {
        await instance.stop().catch(() => {});
        return c.text("VSCode or worker service not found", 500);
      }

      if (
        environmentEnvVarsContent &&
        environmentEnvVarsContent.trim().length > 0
      ) {
        try {
          const encodedEnv = encodeEnvContentForEnvctl(
            environmentEnvVarsContent
          );
          const loadRes = await instance.exec(envctlLoadCommand(encodedEnv));
          if (loadRes.exit_code === 0) {
            console.log(
              `[sandboxes.start] Applied environment env vars via envctl`
            );
          } else {
            console.error(
              `[sandboxes.start] Env var bootstrap failed exit=${loadRes.exit_code} stderr=${(loadRes.stderr || "").slice(0, 200)}`
            );
          }
        } catch (error) {
          console.error(
            "[sandboxes.start] Failed to apply environment env vars",
            error
          );
        }
      }

      // Configure git identity from Convex + GitHub user info so commits don't fail
      try {
        const accessToken = await getAccessTokenFromRequest(c.req.raw);
        if (accessToken) {
          const convex = getConvex({ accessToken });
          const [who, gh] = await Promise.all([
            convex.query(api.users.getCurrentBasic, {}),
            fetchGithubUserInfoForRequest(c.req.raw),
          ]);

          const { name, email } = selectGitIdentity(who, gh);

          // Safe single-quote for shell (we'll wrap the whole -lc string in double quotes)
          const shq = (v: string) => `'${v.replace(/'/g, "\\'")}'`;

          const gitCfgRes = await instance.exec(
            `bash -lc "git config --global user.name ${shq(name)} && git config --global user.email ${shq(email)} && git config --global init.defaultBranch main && echo NAME:$(git config --global --get user.name) && echo EMAIL:$(git config --global --get user.email) || true"`
          );
          console.log(
            `[sandboxes.start] git identity configured exit=${gitCfgRes.exit_code} (${name} <${email}>)`
          );
        } else {
          console.log(
            `[sandboxes.start] No access token; skipping git identity configuration`
          );
        }
      } catch (e) {
        console.log(
          `[sandboxes.start] Failed to configure git identity; continuing...`,
          e
        );
      }

      // Optional: Hydrate repo inside the sandbox
      if (body.repoUrl) {
        console.log(`[sandboxes.start] Hydrating repo for ${instance.id}`);
        const match = body.repoUrl.match(
          /github\.com\/?([^\s/]+)\/([^\s/.]+)(?:\.git)?/i
        );
        if (!match) {
          return c.text("Unsupported repo URL; expected GitHub URL", 400);
        }
        const owner = match[1]!;
        const repo = match[2]!;
        const repoFull = `${owner}/${repo}`;
        console.log(`[sandboxes.start] Parsed owner/repo: ${repoFull}`);

        try {
          const installationId = await getInstallationForRepo(repoFull);
          if (!installationId) {
            return c.text(
              `No GitHub App installation found for ${owner}. Install the app for this org/user.`,
              400
            );
          }
          console.log(`[sandboxes.start] installationId: ${installationId}`);
          const githubToken = await generateGitHubInstallationToken({
            installationId,
            repositories: [repoFull],
          });
          console.log(
            `[sandboxes.start] Generated GitHub token (len=${githubToken.length})`
          );

          // Best-effort envctl for compatibility with gh and other tools
          try {
            const envctlRes = await instance.exec(
              `envctl set GITHUB_TOKEN=${githubToken}`
            );
            console.log(
              `[sandboxes.start] envctl set exit=${envctlRes.exit_code} stderr=${(envctlRes.stderr || "").slice(0, 200)}`
            );
          } catch (_e) {
            console.log(
              `[sandboxes.start] envctl not available; continuing without it`
            );
          }

          // gh auth for CLI tools
          const ghRes = await instance.exec(
            `bash -lc "echo '${githubToken}' | gh auth login --with-token 2>&1 || true"`
          );
          console.log(
            `[sandboxes.start] gh auth login exit=${ghRes.exit_code} stderr=${(ghRes.stderr || "").slice(0, 200)}`
          );

          // Git credential store for HTTPS operations
          const credRes = await instance.exec(
            `bash -lc "git config --global credential.helper store && printf '%s\\n' 'https://x-access-token:${githubToken}@github.com' > /root/.git-credentials && (git config --global --get credential.helper || true) && (test -f /root/.git-credentials && wc -c /root/.git-credentials || true)"`
          );
          console.log(
            `[sandboxes.start] git creds configured exit=${credRes.exit_code} out=${(credRes.stdout || "").replace(/:[^@]*@/g, ":***@").slice(0, 200)}`
          );

          const depth = body.depth ?? 1;
          const workspace = "/root/workspace";
          await instance.exec(`mkdir -p ${workspace}`);

          // Check remote
          const remoteRes = await instance.exec(
            `bash -lc "cd ${workspace} && test -d .git && git remote get-url origin || echo 'no-remote'"`
          );
          const remoteUrl = (remoteRes.stdout || "").trim();

          if (!remoteUrl || !remoteUrl.includes(`${owner}/${repo}`)) {
            await instance.exec(
              `bash -lc "rm -rf ${workspace}/* ${workspace}/.[!.]* ${workspace}/..?* 2>/dev/null || true"`
            );
            const maskedUrl = `https://x-access-token:***@github.com/${owner}/${repo}.git`;
            console.log(
              `[sandboxes.start] Cloning ${maskedUrl} depth=${depth} -> ${workspace}`
            );
            const cloneRes = await instance.exec(
              `bash -lc "git clone --depth ${depth} https://x-access-token:${githubToken}@github.com/${owner}/${repo}.git ${workspace}"`
            );
            console.log(
              `[sandboxes.start] clone exit=${cloneRes.exit_code} stderr=${(cloneRes.stderr || "").slice(0, 300)}`
            );
            if (cloneRes.exit_code !== 0) {
              return c.text("Failed to clone repository", 500);
            }
          } else {
            const fetchRes = await instance.exec(
              `bash -lc "cd ${workspace} && git fetch --all --prune"`
            );
            console.log(
              `[sandboxes.start] fetch exit=${fetchRes.exit_code} stderr=${(fetchRes.stderr || "").slice(0, 200)}`
            );
          }

          const baseBranch = body.branch || "main";
          const coRes = await instance.exec(
            `bash -lc "cd ${workspace} && (git checkout ${baseBranch} || git checkout -b ${baseBranch} origin/${baseBranch}) && git pull --ff-only || true"`
          );
          console.log(
            `[sandboxes.start] checkout ${baseBranch} exit=${coRes.exit_code} stderr=${(coRes.stderr || "").slice(0, 200)}`
          );
          if (body.newBranch) {
            const nbRes = await instance.exec(
              `bash -lc "cd ${workspace} && git switch -C ${body.newBranch}"`
            );
            console.log(
              `[sandboxes.start] switch -C ${body.newBranch} exit=${nbRes.exit_code} stderr=${(nbRes.stderr || "").slice(0, 200)}`
            );
          }

          const lsRes = await instance.exec(
            `bash -lc "ls -la ${workspace} | head -50"`
          );
          console.log(
            `[sandboxes.start] workspace listing:\n${lsRes.stdout || ""}`
          );
        } catch (e) {
          console.error(`[sandboxes.start] Hydration failed:`, e);
          await instance.stop().catch(() => {});
          return c.text("Failed to hydrate sandbox", 500);
        }
      }

      return c.json({
        instanceId: instance.id,
        vscodeUrl: vscodeService.url,
        workerUrl: workerService.url,
        provider: "morph",
      });
    } catch (error) {
      console.error("Failed to start sandbox:", error);
      return c.text("Failed to start sandbox", 500);
    }
  }
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
          `[sandboxes.env] envctl load failed exit=${execResult.exit_code} stderr=${(execResult.stderr || "").slice(0, 200)}`
        );
        return c.text("Failed to apply environment variables", 500);
      }

      return c.json({ applied: true as const });
    } catch (error) {
      console.error(
        "[sandboxes.env] Failed to apply environment variables",
        error
      );
      return c.text("Failed to apply environment variables", 500);
    }
  }
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
  }
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
        (s) => s.port === 39378
      );
      const workerService = instance.networking.httpServices.find(
        (s) => s.port === 39377
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
  }
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
              })
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

      const CMUX_PORTS = new Set([39376, 39377, 39378]);

      // Attempt to read devcontainer.json for declared forwarded ports
      const devcontainerJson = await instance.exec(
        "cat /root/workspace/.devcontainer/devcontainer.json"
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
        if (pn > 0 && !CMUX_PORTS.has(pn)) allowedPorts.add(pn);
      };

      // Prefer environment.exposedPorts if available; otherwise use devcontainer forwardPorts
      (environmentPorts && environmentPorts.length > 0
        ? environmentPorts
        : devcontainerPorts
      ).forEach(addAllowed);

      // Expose each allowed port in Morph (best-effort)
      await Promise.all(
        Array.from(allowedPorts).map(async (p) => {
          try {
            await instance.exposeHttpService(`port-${p}` as const, p);
          } catch {
            // continue exposing other ports
          }
        })
      );

      // Intersect exposed HTTP services with allowed ports
      const networking = instance.networking.httpServices
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
  }
);
