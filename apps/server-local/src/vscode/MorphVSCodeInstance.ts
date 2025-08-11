import { type Instance, MorphCloudClient } from "morphcloud";
import {
  VSCodeInstance,
  type VSCodeInstanceConfig,
  type VSCodeInstanceInfo,
} from "./VSCodeInstance.js";
import { dockerLogger } from "../utils/fileLogger.js";

export class MorphVSCodeInstance extends VSCodeInstance {
  private morphClient: MorphCloudClient;
  private instance: Instance | null = null; // Morph instance type
  private snapshotId = "snapshot_gn1wmycs"; // Default snapshot ID

  constructor(config: VSCodeInstanceConfig) {
    super(config);
    this.morphClient = new MorphCloudClient();
  }

  async start(): Promise<VSCodeInstanceInfo> {
    dockerLogger.info(`Starting Morph VSCode instance with ID: ${this.instanceId}`);

    // Start the Morph instance
    this.instance = await this.morphClient.instances.start({
      snapshotId: this.snapshotId,
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
}
