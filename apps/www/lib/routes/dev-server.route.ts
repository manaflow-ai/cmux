import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { MorphCloudClient } from "morphcloud";
import { DEFAULT_MORPH_SNAPSHOT_ID } from "@/lib/utils/morph-defaults";
import { getUserFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { connectToWorkerManagement, type Socket } from "@cmux/shared/socket";
import type { WorkerToServerEvents, ServerToWorkerEvents } from "@cmux/shared";

// Define the request schema based on StartTaskSchema
const StartDevServerSchema = z.object({
  repoUrl: z.string().openapi({
    example: "https://github.com/user/repo",
    description: "GitHub repository URL",
  }),
  branch: z.string().optional().openapi({
    example: "main",
    description: "Git branch to checkout",
  }),
  taskDescription: z.string().openapi({
    example: "Fix the bug in authentication",
    description: "Description of the task to perform",
  }),
  projectFullName: z.string().openapi({
    example: "user/repo",
    description: "Full name of the project (owner/repo)",
  }),
  taskId: z.string().openapi({
    example: "task_123456",
    description: "Unique task identifier",
  }),
  selectedAgents: z
    .array(z.string())
    .optional()
    .openapi({
      example: ["claude", "opencode"],
      description: "List of AI agents to use",
    }),
  isCloudMode: z.boolean().optional().default(false).openapi({
    example: true,
    description: "Whether to run in cloud mode",
  }),
  images: z
    .array(
      z.object({
        src: z.string(),
        fileName: z.string().optional(),
        altText: z.string(),
      })
    )
    .optional()
    .openapi({
      description: "Array of images to include with the task",
    }),
  theme: z.enum(["dark", "light", "system"]).optional().openapi({
    example: "dark",
    description: "UI theme preference",
  }),
  // Morph-specific configuration
  snapshotId: z.string().optional().openapi({
    example: "snapshot_kco1jqb6",
    description: "Morph snapshot ID to use for the instance",
  }),
  ttlSeconds: z.number().optional().default(1800).openapi({
    example: 1800,
    description: "Time to live in seconds (default 30 minutes)",
  }),
});

// Response schema
const DevServerResponseSchema = z
  .object({
    instanceId: z.string().openapi({
      example: "instance_abc123",
    }),
    vscodeUrl: z.string().openapi({
      example: "https://instance.morph.cloud:39378/?folder=/root/workspace",
    }),
    workerUrl: z.string().openapi({
      example: "https://instance.morph.cloud:39377",
    }),
    vncUrl: z.string().openapi({
      example: "https://instance.morph.cloud:39380/vnc.html",
    }),
    cdpUrl: z.string().openapi({
      example: "https://instance.morph.cloud:39381/json/version",
    }),
    status: z.string().openapi({
      example: "running",
    }),
    taskId: z.string().openapi({
      example: "task_123456",
    }),
    terminalCreated: z.boolean().openapi({
      example: true,
    }),
  })
  .openapi("DevServerResponse");

const ErrorResponseSchema = z
  .object({
    code: z.number().openapi({
      example: 500,
    }),
    message: z.string().openapi({
      example: "Failed to start instance",
    }),
    error: z.string().optional().openapi({
      example: "VSCode or worker service not found",
    }),
  })
  .openapi("ErrorResponse");

export const devServerRouter = new OpenAPIHono();

const startDevServerRoute = createRoute({
  method: "post",
  path: "/dev-server/start",
  request: {
    body: {
      content: {
        "application/json": {
          schema: StartDevServerSchema,
        },
      },
      description:
        "Start a new development server instance with the specified task",
      required: true,
    },
  },
  responses: {
    200: {
      content: {
        "application/json": {
          schema: DevServerResponseSchema,
        },
      },
      description: "Development server started successfully",
    },
    401: {
      content: {
        "application/json": {
          schema: ErrorResponseSchema,
        },
      },
      description: "Unauthorized",
    },
    500: {
      content: {
        "application/json": {
          schema: ErrorResponseSchema,
        },
      },
      description: "Failed to start development server",
    },
  },
  tags: ["DevServer"],
  summary: "Start a new development server",
  description:
    "Creates a new development server instance with VSCode and worker services for running tasks",
});

devServerRouter.openapi(startDevServerRoute, async (c) => {
  const user = await getUserFromRequest(c.req.raw);
  if (!user) {
    return c.json(
      {
        code: 401,
        message: "Unauthorized",
      },
      401
    );
  }
  const { accessToken } = await user.getAuthJson();
  if (!accessToken) {
    return c.json(
      {
        code: 401,
        message: "Unauthorized",
      },
      401
    );
  }

  const body = c.req.valid("json");

  const client = new MorphCloudClient({ apiKey: env.MORPH_API_KEY });
  let instance: Awaited<ReturnType<typeof client.instances.start>> | null = null;
  let stopInstanceOnError = false;

  try {
    // Start the instance with provided or default snapshot
    instance = await client.instances.start({
      snapshotId: body.snapshotId || DEFAULT_MORPH_SNAPSHOT_ID,
      ttlSeconds: body.ttlSeconds || 60 * 30, // Default 30 minutes
      ttlAction: "pause",
      metadata: {
        app: "cmux",
        userId: user.id,
        taskId: body.taskId,
        repo: body.repoUrl,
        branch: body.branch || "main",
      },
    });
    stopInstanceOnError = true;
    void (async () => {
      await instance.setWakeOn(true, true);
    })();

    console.log(`Created dev server instance: ${instance.id}`);

    // SDK bug: instances.start() returns empty httpServices array
    // Re-fetch instance to get the actual networking data
    const refreshedInstance =
      instance.networking.httpServices.length === 0
        ? await client.instances.get({ instanceId: instance.id })
        : instance;

    const exposedServices = refreshedInstance.networking.httpServices;
    const vscodeService = exposedServices.find(
      (service) => service.port === 39378
    );
    const workerService = exposedServices.find(
      (service) => service.port === 39377
    );
    const vncService = exposedServices.find((service) => service.port === 39380);
    const cdpService = exposedServices.find((service) => service.port === 39381);

    if (!vscodeService || !workerService || !vncService || !cdpService) {
      // Stop the instance if services are not available
      await instance.stop();
      stopInstanceOnError = false;
      throw new Error("VSCode, worker, VNC, or DevTools service not found");
    }

    const vscodeUrl = `${vscodeService.url}/?folder=/root/workspace`;
    console.log(`VSCode URL: ${vscodeUrl}`);

    const vncUrl = new URL("/vnc.html", vncService.url);
    const vncSearchParams = new URLSearchParams();
    vncSearchParams.set("autoconnect", "1");
    vncSearchParams.set("resize", "scale");
    vncSearchParams.set("reconnect", "1");
    vncSearchParams.set("reconnect_delay", "1000");
    vncUrl.search = `?${vncSearchParams.toString()}`;
    const vncUrlString = vncUrl.toString();

    // Connect to the worker management namespace
    const clientSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents> =
      connectToWorkerManagement({
        url: workerService.url,
        timeoutMs: 10_000,
        reconnectionAttempts: 3,
      });

    let terminalCreated = false;

    // Set up socket connection and create terminal
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        clientSocket.disconnect();
        reject(new Error("Connection timeout"));
      }, 15000);

      clientSocket.on("connect", () => {
        console.log("Connected to worker");

        // Build the command based on selected agents
        const agents = body.selectedAgents || ["opencode"];
        const agent = agents[0]; // For now, use the first selected agent

        let command: string;
        switch (agent) {
          case "claude":
            command = `bun x claude-code '${body.taskDescription}'`;
            break;
          case "opencode":
            command = `bun x opencode-ai '${body.taskDescription}'`;
            break;
          case "amp":
            command = `bun x amp-ai '${body.taskDescription}'`;
            break;
          case "gemini":
            command = `bun x gemini-cli '${body.taskDescription}'`;
            break;
          default:
            command = `bun x opencode-ai '${body.taskDescription}'`;
        }

        // Create terminal with the task
        clientSocket.emit(
          "worker:create-terminal",
          {
            terminalId: crypto.randomUUID(),
            cols: 80,
            rows: 24,
            cwd: "/root/workspace",
            command,
            backend: "tmux",
            taskRunContext: {
              taskRunToken: "dev-server-placeholder-token",
              prompt: body.taskDescription,
              convexUrl: env.NEXT_PUBLIC_CONVEX_URL,
            },
          },
          () => {
            console.log("Terminal created with command:", command);
            terminalCreated = true;
            clearTimeout(timeout);
            clientSocket.disconnect();
            resolve();
          }
        );
      });

      clientSocket.on("disconnect", () => {
        console.log("Disconnected from worker");
      });

      clientSocket.on("connect_error", (error: Error) => {
        clearTimeout(timeout);
        clientSocket.disconnect();
        reject(error);
      });
    });

    stopInstanceOnError = false;
    return c.json(
      {
        instanceId: instance.id,
        vscodeUrl,
        workerUrl: workerService.url,
        vncUrl: vncUrlString,
        cdpUrl: `${cdpService.url}/json/version`,
        status: "running",
        taskId: body.taskId,
        terminalCreated,
      },
      200
    );
  } catch (error) {
    if (stopInstanceOnError && instance) {
      try {
        await instance.stop();
        console.warn(
          "Stopped dev server instance after startup failure:",
          instance.id
        );
      } catch (stopError) {
        console.error(
          "Failed to stop dev server instance after error:",
          stopError
        );
      }
    }
    console.error("Failed to start dev server instance:", error);
    return c.json(
      {
        code: 500,
        message: "Failed to start development server",
        error: error instanceof Error ? error.message : "Unknown error",
      },
      500
    );
  }
});
