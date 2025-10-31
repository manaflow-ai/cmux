import { Buffer } from "node:buffer";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio";
import * as StackframeJs from "@stackframe/js";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { ConvexHttpClient } from "@cmux/shared/node/convex-cache";
import { z } from "zod";

import {
  type CreateTaskInput,
  CreateTaskInputSchema,
  CmuxWorkspaceResultSchema,
  PollTaskInputSchema,
  PollTaskResultSchema,
  type CmuxWorkspaceResult,
  type PollTaskResult,
} from "../../shared/schemas";

type TaskRunDoc = Doc<"taskRuns">;

const { StackAdminApp } = StackframeJs;

const modulePath = fileURLToPath(import.meta.url);
const moduleDir = dirname(modulePath);
loadEnv({ path: resolve(moduleDir, "../../../../.env") });
loadEnv();

type PollTokenPayload = {
  teamSlugOrId: string;
  taskId: Id<"tasks">;
  taskRunId: Id<"taskRuns">;
  instanceId: string;
  openPreview: boolean;
};

const serverInfo = {
  name: "cmux-chatgpt-app",
  version: "0.1.0",
  title: "cmux Workspace Orchestrator",
  websiteUrl: "https://cmux.sh",
} as const;

const config = resolveConfig();

let stackAdmin: InstanceType<typeof StackAdminApp> | null = null;
let cachedAccessToken: { value: string; expiresAt: number } | null = null;
let pendingAccessToken: Promise<string> | null = null;

async function getServiceAccessToken(): Promise<string> {
  if (config.manualAccessToken) {
    return config.manualAccessToken;
  }

  if (!config.stack) {
    throw new Error(
      "Stack credentials missing. Set CMUX_CHATGPT_ACCESS_TOKEN or provide Stack keys plus CMUX_CHATGPT_STACK_USER_ID.",
    );
  }

  const now = Date.now();
  if (cachedAccessToken && cachedAccessToken.expiresAt > now + 30_000) {
    return cachedAccessToken.value;
  }

  if (pendingAccessToken) {
    return pendingAccessToken;
  }

  pendingAccessToken = (async () => {
    if (!stackAdmin) {
      stackAdmin = new StackAdminApp({
        projectId: config.stack!.projectId,
        publishableClientKey: config.stack!.publishableClientKey,
        secretServerKey: config.stack!.secretServerKey,
        superSecretAdminKey: config.stack!.superSecretAdminKey,
        tokenStore: "memory",
      });
    }

    const user = await stackAdmin.getUser(config.stack!.userId);
    if (!user) {
      throw new Error(
        `Stack user ${config.stack!.userId} not found; update CMUX_CHATGPT_STACK_USER_ID.`,
      );
    }

    const session = await user.createSession({
      expiresInMillis: 15 * 60 * 1000,
    });
    const tokens = await session.getTokens();
    if (!tokens.accessToken) {
      throw new Error("Stack did not return an access token for the ChatGPT app.");
    }

    cachedAccessToken = {
      value: tokens.accessToken,
      expiresAt: Date.now() + 14 * 60 * 1000,
    };

    return tokens.accessToken;
  })();

  try {
    return await pendingAccessToken;
  } finally {
    pendingAccessToken = null;
  }
}

const mcpServer = new McpServer(serverInfo, {
  instructions:
    "Call `cmux.create_task` whenever the user types '@cmux …'. Use `cmux.poll_task` to refresh status.",
});

const startSandboxResponseSchema = z.object({
  instanceId: z.string(),
  vscodeUrl: z.string().url(),
  workerUrl: z.string().url(),
  provider: z.enum(["morph", "daytona", "other"]).default("morph"),
});

const publishNetworkingResponseSchema = z.array(
  z.object({
    status: z.literal("running"),
    port: z.number(),
    url: z.string().url(),
  }),
);

const sandboxStatusSchema = z.object({
  running: z.boolean(),
  vscodeUrl: z.string().url().optional(),
  workerUrl: z.string().url().optional(),
  provider: z.enum(["morph", "daytona", "other"]).optional(),
});

mcpServer.tool(
  "cmux.create_task",
  "Create a cmux task and launch a development workspace",
  CreateTaskInputSchema.shape,
  async (rawArgs: unknown) => {
    const args = CreateTaskInputSchema.parse(rawArgs);
    const { teamSlugOrId } = args;

    const accessToken = await getServiceAccessToken();
    const convex = buildConvexClient(accessToken);

    const repoFullName = args.repoFullName ?? config.defaultRepoFullName;
    if (!repoFullName) {
      throw new Error(
        "No repository provided. Set CMUX_CHATGPT_DEFAULT_REPO or pass repoFullName in the tool call.",
      );
    }

    const repoUrl = `https://github.com/${repoFullName}.git`;
    const branch = config.defaultRepoBranch;

    const taskId = await convex.mutation(api.tasks.create, {
      teamSlugOrId,
      text: args.taskText,
      projectFullName: repoFullName,
      baseBranch: branch,
    });

    const { taskRunId, jwt } = await convex.mutation(api.taskRuns.create, {
      teamSlugOrId,
      taskId,
      prompt: args.taskText,
      agentName: presetAgentName(args.agentPreset),
      environmentId: args.environmentId as Id<"environments"> | undefined,
    });

    const sandbox = await startSandbox({
      teamSlugOrId,
      taskRunId,
      taskRunJwt: jwt,
      repoUrl,
      branch,
      environmentId: args.environmentId,
      authToken: accessToken,
    });

    if (args.openPreview) {
      await publishDevcontainerNetworking({
        instanceId: sandbox.instanceId,
        teamSlugOrId,
        taskRunId,
        authToken: accessToken,
      });
    }

    await upsertVSCodeInstance(convex, {
      teamSlugOrId,
      taskRunId,
      vscodeUrl: sandbox.vscodeUrl,
    });

    const runDoc = await fetchTaskRun(convex, { teamSlugOrId, taskRunId });

    const workspaceResult = buildWorkspaceResult({
      taskId,
      taskTitle: args.taskText,
      teamSlugOrId,
      run: runDoc,
      sandboxInstanceId: sandbox.instanceId,
      fallbackVscodeUrl: sandbox.vscodeUrl,
      openPreview: args.openPreview,
    });

    const pollToken = encodePollToken({
      teamSlugOrId,
      taskId,
      taskRunId,
      instanceId: sandbox.instanceId,
      openPreview: args.openPreview,
    });

    const structuredContent: CmuxWorkspaceResult = {
      ...workspaceResult,
      pollToken,
    };

    const parsedStructured = CmuxWorkspaceResultSchema.parse(structuredContent);

    return {
      content: [
        {
          type: "text" as const,
          text: `cmux workspace launched for ${repoFullName} (${teamSlugOrId}). VS Code will open shortly.`,
        },
      ],
      structuredContent: parsedStructured,
    };
  },
);

mcpServer.tool(
  "cmux.poll_task",
  "Fetch the latest status for a cmux task run",
  PollTaskInputSchema.shape,
  async (rawArgs: unknown) => {
    const args = PollTaskInputSchema.parse(rawArgs);
    const payload = decodePollToken(args.pollToken);

    const accessToken = await getServiceAccessToken();
    const convex = buildConvexClient(accessToken);
    const runDoc = await fetchTaskRun(convex, {
      teamSlugOrId: payload.teamSlugOrId,
      taskRunId: payload.taskRunId,
    });

    const sandboxStatus = await fetchSandboxStatus({
      instanceId: payload.instanceId,
      authToken: accessToken,
    });

    const workspaceResult = buildWorkspaceResult({
      taskId: payload.taskId,
      taskTitle: runDoc.prompt,
      teamSlugOrId: payload.teamSlugOrId,
      run: runDoc,
      sandboxInstanceId: payload.instanceId,
      fallbackVscodeUrl: sandboxStatus.vscodeUrl,
      openPreview: payload.openPreview,
    });

    const structuredContent: PollTaskResult = {
      type: "cmux_workspace_status",
      run: workspaceResult.run,
      workspace: workspaceResult.workspace,
      message: workspaceResult.message,
    };

    return {
      content: [
        {
          type: "text" as const,
          text: workspaceResult.message ?? "Workspace updated.",
        },
      ],
      structuredContent: PollTaskResultSchema.parse(structuredContent),
    };
  },
);

async function startServer(): Promise<void> {
  console.log("cmux ChatGPT MCP server starting...");
  const transport = new StdioServerTransport();
  transport.onerror = (error: unknown) => {
    console.error("cmux ChatGPT MCP transport error", error);
  };
  const closed = new Promise<void>((resolve) => {
    transport.onclose = () => {
      console.log("cmux ChatGPT MCP transport closed");
      resolve();
    };
  });
  await mcpServer.connect(transport);
  const keepAlive = setInterval(() => {
    // noop timer to keep event loop alive while waiting for stdio
  }, 1_000_000);
  console.log("cmux ChatGPT MCP server ready (stdio)");
  await closed;
  clearInterval(keepAlive);
}

export { mcpServer, getServiceAccessToken, config, startServer };

const entryPath = process.argv[1]
  ? resolve(process.cwd(), process.argv[1])
  : undefined;

if (entryPath === modulePath) {
  startServer().catch((error) => {
    console.error("cmux MCP server failed", error);
    process.exitCode = 1;
  });
}

type StackTokenConfig = {
  projectId: string;
  publishableClientKey: string;
  secretServerKey: string;
  superSecretAdminKey: string;
  userId: string;
};

type Config = {
  convexUrl: string;
  defaultRepoFullName?: string;
  defaultRepoBranch: string;
  wwwBaseUrl: string;
  clientBaseUrl: string;
  manualAccessToken?: string;
  stack?: StackTokenConfig;
};

function resolveConfig(): Config {
  const manualAccessToken = process.env.CMUX_CHATGPT_ACCESS_TOKEN ?? undefined;

  const convexUrl =
    process.env.NEXT_PUBLIC_CONVEX_URL || process.env.CMUX_CONVEX_URL;
  if (!convexUrl) {
    throw new Error("Set NEXT_PUBLIC_CONVEX_URL (Convex deployment URL).");
  }

  const defaultRepoFullName = process.env.CMUX_CHATGPT_DEFAULT_REPO;
  const defaultRepoBranch = process.env.CMUX_CHATGPT_DEFAULT_BRANCH ?? "main";
  const wwwBaseUrl = removeTrailingSlash(
    process.env.CMUX_CHATGPT_WWW_BASE_URL ?? "https://app.cmux.sh",
  );
  const clientBaseUrl = removeTrailingSlash(
    process.env.CMUX_CHATGPT_CLIENT_BASE_URL ?? wwwBaseUrl,
  );

  let stack: StackTokenConfig | undefined;
  if (!manualAccessToken) {
    const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
    const publishableClientKey =
      process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
    const secretServerKey = process.env.STACK_SECRET_SERVER_KEY;
    const superSecretAdminKey = process.env.STACK_SUPER_SECRET_ADMIN_KEY;
    const userId = process.env.CMUX_CHATGPT_STACK_USER_ID;

    if (
      projectId &&
      publishableClientKey &&
      secretServerKey &&
      superSecretAdminKey &&
      userId
    ) {
      stack = {
        projectId,
        publishableClientKey,
        secretServerKey,
        superSecretAdminKey,
        userId,
      };
    } else {
      throw new Error(
        "Provide either CMUX_CHATGPT_ACCESS_TOKEN or the Stack credentials (NEXT_PUBLIC_STACK_PROJECT_ID, NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY, STACK_SECRET_SERVER_KEY, STACK_SUPER_SECRET_ADMIN_KEY, CMUX_CHATGPT_STACK_USER_ID) so the ChatGPT app can authenticate.",
      );
    }
  }

  return {
    manualAccessToken,
    convexUrl,
    defaultRepoFullName,
    defaultRepoBranch,
    wwwBaseUrl,
    clientBaseUrl,
    stack,
  };
}

function removeTrailingSlash(input: string): string {
  return input.endsWith("/") ? input.slice(0, -1) : input;
}

function buildConvexClient(accessToken: string): ConvexHttpClient {
  const client = new ConvexHttpClient(config.convexUrl);
  client.setAuth(accessToken);
  return client;
}

async function startSandbox({
  teamSlugOrId,
  taskRunId,
  taskRunJwt,
  repoUrl,
  branch,
  environmentId,
  authToken,
}: {
  teamSlugOrId: string;
  taskRunId: Id<"taskRuns">;
  taskRunJwt: string;
  repoUrl: string;
  branch: string;
  environmentId?: string;
  authToken: string;
}): Promise<z.infer<typeof startSandboxResponseSchema>> {
  const response = await fetch(`${config.wwwBaseUrl}/api/sandboxes/start`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${authToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      teamSlugOrId,
      repoUrl,
      branch,
      taskDescription: `ChatGPT cmux workspace for task ${String(taskRunId)}`,
      taskRunId,
      taskRunJwt,
      metadata: {
        source: "chatgpt-app",
      },
      environmentId,
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    throw new Error(
      `Failed to start sandbox (status ${response.status}): ${errorBody}`,
    );
  }

  const json = await response.json();
  return startSandboxResponseSchema.parse(json);
}

async function publishDevcontainerNetworking({
  instanceId,
  teamSlugOrId,
  taskRunId,
  authToken,
}: {
  instanceId: string;
  teamSlugOrId: string;
  taskRunId: Id<"taskRuns">;
  authToken: string;
}): Promise<void> {
  const response = await fetch(
    `${config.wwwBaseUrl}/api/sandboxes/${instanceId}/publish-devcontainer`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${authToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        teamSlugOrId,
        taskRunId,
      }),
    },
  );

  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Failed to publish devcontainer networking (status ${response.status}): ${body}`,
    );
  }

  // Validate response even though we do not use the payload directly.
  const payload = await response.json();
  publishNetworkingResponseSchema.parse(payload);
}

async function fetchSandboxStatus({
  instanceId,
  authToken,
}: {
  instanceId: string;
  authToken: string;
}): Promise<z.infer<typeof sandboxStatusSchema>> {
  const response = await fetch(
    `${config.wwwBaseUrl}/api/sandboxes/${instanceId}/status`,
    {
      headers: {
        Authorization: `Bearer ${authToken}`,
      },
    },
  );

  if (!response.ok) {
    return { running: false };
  }

  const json = await response.json();
  return sandboxStatusSchema.parse(json);
}

async function fetchTaskRun(
  convex: ConvexHttpClient,
  {
    teamSlugOrId,
    taskRunId,
  }: {
    teamSlugOrId: string;
    taskRunId: Id<"taskRuns">;
  },
): Promise<TaskRunDoc> {
  const run = await convex.query(api.taskRuns.get, {
    teamSlugOrId,
    id: taskRunId,
  });
  if (!run) {
    throw new Error(`Task run ${taskRunId} not found`);
  }
  return run;
}

async function upsertVSCodeInstance(
  convex: ConvexHttpClient,
  {
    teamSlugOrId,
    taskRunId,
    vscodeUrl,
  }: {
    teamSlugOrId: string;
    taskRunId: Id<"taskRuns">;
    vscodeUrl: string;
  },
): Promise<void> {
  const baseUrl = vscodeUrl.replace(/\/?\?folder=.*$/, "");
  await convex.mutation(api.taskRuns.updateVSCodeInstance, {
    teamSlugOrId,
    id: taskRunId,
    vscode: {
      provider: "morph",
      status: "running",
      url: baseUrl,
      workspaceUrl: vscodeUrl,
      startedAt: Date.now(),
    },
  });

  await convex.mutation(api.taskRuns.updateVSCodeStatus, {
    teamSlugOrId,
    id: taskRunId,
    status: "running",
  });
}

function buildWorkspaceResult({
  taskId,
  taskTitle,
  teamSlugOrId,
  run,
  sandboxInstanceId,
  fallbackVscodeUrl,
  openPreview,
}: {
  taskId: Id<"tasks">;
  taskTitle: string;
  teamSlugOrId: string;
  run: TaskRunDoc;
  sandboxInstanceId: string;
  fallbackVscodeUrl?: string;
  openPreview: boolean;
}): CmuxWorkspaceResult {
  const vscodeUrl = run.vscode?.workspaceUrl ?? fallbackVscodeUrl;
  if (!vscodeUrl) {
    throw new Error("VS Code URL is unavailable after sandbox start");
  }

  const previewServices = openPreview
    ? (run.networking ?? []).map((service) => ({
        url: service.url,
        port: service.port,
        label: `Port ${service.port}`,
        preflightStatus: "ready" as const,
      }))
    : [];

  const agentStatus = mapAgentStatus(run.vscode?.status);

  const workspaceResult: CmuxWorkspaceResult = {
    type: "cmux_workspace",
    task: {
      id: String(taskId),
      url: `${config.clientBaseUrl}/${teamSlugOrId}/task/${taskId}`,
      title: taskTitle,
    },
    run: {
      id: String(run._id),
      agents: [
        {
          name: "vscode",
          status: agentStatus,
          summary: agentSummary(agentStatus, run.newBranch ?? undefined),
        },
        ...previewServices.map((preview) => ({
          name: preview.label ?? `port-${preview.port ?? ""}`,
          status: "running" as const,
          summary: preview.url,
        })),
      ],
      lastUpdatedAt: run.updatedAt
        ? new Date(run.updatedAt).toISOString()
        : undefined,
    },
    workspace: {
      vscode: {
        url: vscodeUrl,
        label: "VS Code",
        preflightStatus: "ready",
      },
      previews: previewServices,
      instanceId: sandboxInstanceId,
    },
    message:
      agentStatus === "running"
        ? "Workspace ready. VS Code is running."
        : "Provisioning workspace…",
  };

  return workspaceResult;
}

function mapAgentStatus(
  vscodeStatus: TaskRunDoc["vscode"] extends infer V
    ? V extends { status?: infer S }
      ? S
      : undefined
    : undefined,
): "pending" | "running" | "succeeded" | "failed" {
  switch (vscodeStatus) {
    case "running":
      return "running";
    case "stopped":
      return "succeeded";
    case "starting":
      return "pending";
    default:
      return "pending";
  }
}

function agentSummary(
  status: "pending" | "running" | "succeeded" | "failed",
  branch?: string,
): string | undefined {
  const branchSuffix = branch ? ` (branch ${branch})` : "";
  switch (status) {
    case "running":
      return `VS Code running${branchSuffix}`;
    case "pending":
      return `VS Code starting${branchSuffix}`;
    case "succeeded":
      return `VS Code stopped${branchSuffix}`;
    case "failed":
      return `VS Code failed${branchSuffix}`;
    default:
      return undefined;
  }
}

function presetAgentName(preset: CreateTaskInput["agentPreset"]): string {
  switch (preset) {
    case "stack":
      return "stack-default";
    case "llm-heavy":
      return "llm-heavy";
    default:
      return "default";
  }
}

function encodePollToken(payload: PollTokenPayload): string {
  const json = JSON.stringify({
    ...payload,
    taskId: payload.taskId,
    taskRunId: payload.taskRunId,
  });
  return Buffer.from(json, "utf8").toString("base64url");
}

function decodePollToken(token: string): PollTokenPayload {
  try {
    const json = Buffer.from(token, "base64url").toString("utf8");
    const parsed = JSON.parse(json) as PollTokenPayload;
    return parsed;
  } catch (error) {
    throw new Error(`Invalid poll token: ${error instanceof Error ? error.message : String(error)}`);
  }
}
