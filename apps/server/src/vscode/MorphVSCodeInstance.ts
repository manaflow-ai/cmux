import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { type Instance, MorphCloudClient } from "morphcloud";
import z from "zod";
import { getConvex } from "../utils/convexClient.js";
import { dockerLogger } from "../utils/fileLogger.js";
import { workerExec } from "../utils/workerExec.js";
import {
  VSCodeInstance,
  type VSCodeInstanceConfig,
  type VSCodeInstanceInfo,
} from "./VSCodeInstance.js";

interface MorphVSCodeInstanceConfig extends VSCodeInstanceConfig {
  morphSnapshotId?: string;
}

export class MorphVSCodeInstance extends VSCodeInstance {
  private morphClient: MorphCloudClient;
  private instance: Instance | null = null; // Morph instance type
  private morphSnapshotId: string;

  constructor(config: MorphVSCodeInstanceConfig) {
    super(config);
    this.morphClient = new MorphCloudClient();
    // this.morphSnapshotId = config.morphSnapshotId || "snapshot_xf8w00is";
    this.morphSnapshotId = config.morphSnapshotId || "snapshot_hwmk73mg";
  }

  async start(): Promise<VSCodeInstanceInfo> {
    dockerLogger.info(
      `Starting Morph VSCode instance with ID: ${this.instanceId}`
    );

    // Start the Morph instance
    this.instance = await this.morphClient.instances.start({
      snapshotId: this.morphSnapshotId,
      // 30 minutes
      ttlSeconds: 60 * 30,
      ttlAction: "pause",
      metadata: {
        app: "cmux-dev-local  ",
      },
    });

    dockerLogger.info(`Morph instance created: ${this.instance.id}`);

    // Get exposed services
    const exposedServices = this.instance.networking.httpServices;
    const vscodeService = exposedServices.find(
      (service) => service.port === 39378
    );
    const workerService = exposedServices.find(
      (service) => service.port === 39377
    );

    if (!vscodeService || !workerService) {
      throw new Error("VSCode or worker service not found in Morph instance");
    }

    const workspaceUrl = this.getWorkspaceUrl(vscodeService.url);
    dockerLogger.info(`Morph VSCode instance started:`);
    dockerLogger.info(`  VS Code URL: ${workspaceUrl}`);
    dockerLogger.info(`  Worker URL: ${workerService.url}`);

    // Connect to the worker
    try {
      console.log("[MorphVSCodeInstance] Connecting to worker");
      await this.connectToWorker(workerService.url);
      dockerLogger.info(
        `Successfully connected to worker for Morph instance ${this.instance.id}`
      );
    } catch (error) {
      dockerLogger.error(
        `Failed to connect to worker for Morph instance ${this.instance.id}:`,
        error
      );
      // Continue anyway - the instance is running even if we can't connect to the worker
    }

    return {
      url: vscodeService.url,
      workspaceUrl,
      instanceId: this.instanceId,
      taskRunId: this.taskRunId,
      provider: "morph",
    };
  }

  async stop(): Promise<void> {
    dockerLogger.info(`Stopping Morph VSCode instance: ${this.instanceId}`);

    // Disconnect from worker first
    await this.disconnectFromWorker();

    // Stop the Morph instance
    if (this.instance) {
      await this.instance.stop();
      dockerLogger.info(`Morph instance ${this.instance.id} stopped`);
    }
  }

  async getStatus(): Promise<{ running: boolean; info?: VSCodeInstanceInfo }> {
    if (!this.instance) {
      return { running: false };
    }

    try {
      // Check if instance is still running
      // Note: You might need to adjust this based on Morph's API
      const exposedServices = this.instance.networking.httpServices;
      const vscodeService = exposedServices.find(
        (service) => service.port === 39378
      );

      if (vscodeService) {
        return {
          running: true,
          info: {
            url: vscodeService.url,
            workspaceUrl: this.getWorkspaceUrl(vscodeService.url),
            instanceId: this.instanceId,
            taskRunId: this.taskRunId,
            provider: "morph",
          },
        };
      }

      return { running: false };
    } catch (_error) {
      return { running: false };
    }
  }

  async setupDevcontainer(): Promise<Doc<"taskRuns">["networking"]> {
    const instance = this.instance;
    if (!instance) {
      throw new Error("Morph instance not started");
    }
    const CMUX_PORTS = new Set([39376, 39377, 39378]);

    console.log("[MorphVSCodeInstance] Reading devcontainer.json");
    // first, try to read /root/workspace/.devcontainer/devcontainer.json
    const devcontainerJson = await workerExec({
      workerSocket: this.getWorkerSocket(),
      command: "cat",
      args: ["/root/workspace/.devcontainer/devcontainer.json"],
      cwd: "/root",
      env: {},
    });
    if (devcontainerJson.error) {
      throw new Error("Failed to read devcontainer.json");
    }

    const parsedDevcontainerJson = JSON.parse(devcontainerJson.stdout);

    console.log(
      "[MorphVSCodeInstance] Forward ports:",
      parsedDevcontainerJson.forwardPorts
    );
    console.log("[MorphVSCodeInstance] Exposing network...");
    const forwardPorts = z
      .array(z.number())
      .safeParse(parsedDevcontainerJson.forwardPorts);
    if (!forwardPorts.success) {
      return;
    }
    const forwardPortsArray = forwardPorts.data;
    // if port conflict, throw error
    for (const port of forwardPortsArray) {
      if (CMUX_PORTS.has(port)) {
        throw new Error(`Port ${port} is reserved by cmux`);
      }
    }
    await Promise.all(
      forwardPortsArray
        .filter((port) => !CMUX_PORTS.has(port))
        .map(async (port) => {
          try {
            const result = await instance.exposeHttpService(
              `port-${port}`,
              port
            );
            console.log(
              `[MorphVSCodeInstance] Exposed port ${port} on ${instance.id}`
            );
            return {
              status: "running",
              port: result.port,
              url: result.url,
            };
          } catch (_error) {
            console.error(
              `[MorphVSCodeInstance] Failed to expose port ${port}`
            );
          }
          return null;
        })
        .filter((item): item is NonNullable<typeof item> => item !== null)
    );

    const devcontainerNetwork: Doc<"taskRuns">["networking"] =
      instance.networking.httpServices
        .filter((service) => !CMUX_PORTS.has(service.port))
        .map((service) => ({
          status: "running",
          port: service.port,
          url: service.url,
        }));

    console.log("[MorphVSCodeInstance] Networking:", devcontainerNetwork);

    // Persist networking information to Convex
    await getConvex().mutation(api.taskRuns.updateNetworking, {
      teamSlugOrId: this.teamSlugOrId,
      id: this.taskRunId,
      networking: devcontainerNetwork,
    });

    console.log("[MorphVSCodeInstance] Starting devcontainer");
    const HACK_DEMO_DEVCONTAINER = true;
    if (HACK_DEMO_DEVCONTAINER) {
      // await workerExec({
      //   workerSocket: this.getWorkerSocket(),
      //   command: "bash",
      //   args: [
      //     "-c",
      //     "pnpm install --frozen-lockfile --prefer-offline && bash /root/workspace/scripts/dev.sh",
      //   ],
      //   cwd: "/root/workspace",
      //   env: {
      //     FORCE_INSTALL: "true",
      //   },
      // });
      return devcontainerNetwork;
    }

    // Start the devcontainer
    const devcontainerStart = await workerExec({
      workerSocket: this.getWorkerSocket(),
      // 5 minutes
      timeout: 5 * 60 * 1000,
      command: "bash",
      args: [
        "-c",
        "bunx @devcontainers/cli up --workspace-folder . >> /var/log/cmux/devcontainer.log 2>&1",
      ],
      cwd: "/root/workspace",
      env: {},
    });

    console.log(
      "[MorphVSCodeInstance] Devcontainer start output:",
      devcontainerStart
    );

    return devcontainerNetwork;
  }

  getName(): string {
    const instance = this.instance;
    if (!instance) {
      throw new Error("Morph instance not started");
    }
    return instance.id;
  }
}
