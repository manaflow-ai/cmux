import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import { EventEmitter } from "node:events";
import { io, type Socket } from "socket.io-client";
import { dockerLogger } from "../utils/fileLogger.js";

export interface VSCodeInstanceConfig {
  workspacePath?: string;
  initialCommand?: string;
  agentName?: string;
  taskRunId: string; // Required: Convex taskRun ID
  theme?: "dark" | "light" | "system";
}

export interface VSCodeInstanceInfo {
  url: string;
  workspaceUrl: string;
  instanceId: string;
  taskRunId: string;
  provider: "docker" | "morph" | "daytona";
}

export abstract class VSCodeInstance extends EventEmitter {
  // Static registry of all VSCode instances
  protected static instances = new Map<string, VSCodeInstance>();

  protected config: VSCodeInstanceConfig;
  protected instanceId: string;
  protected taskRunId: string;
  protected workerSocket: Socket<
    WorkerToServerEvents,
    ServerToWorkerEvents
  > | null = null;
  protected workerConnected: boolean = false;

  constructor(config: VSCodeInstanceConfig) {
    super();
    this.config = config;
    this.taskRunId = config.taskRunId;
    // Use taskRunId as instanceId for backward compatibility
    this.instanceId = config.taskRunId;

    // Register this instance
    VSCodeInstance.instances.set(this.instanceId, this);
  }

  // Static methods to manage instances
  static getInstances(): Map<string, VSCodeInstance> {
    return VSCodeInstance.instances;
  }

  static getInstance(instanceId: string): VSCodeInstance | undefined {
    return VSCodeInstance.instances.get(instanceId);
  }

  static clearInstances(): void {
    VSCodeInstance.instances.clear();
  }

  abstract start(): Promise<VSCodeInstanceInfo>;
  abstract stop(): Promise<void>;
  abstract getStatus(): Promise<{
    running: boolean;
    info?: VSCodeInstanceInfo;
  }>;

  async connectToWorker(workerUrl: string): Promise<void> {
    dockerLogger.info(
      `[VSCodeInstance ${this.instanceId}] Connecting to worker at ${workerUrl}`
    );

    return new Promise((resolve, reject) => {
      this.workerSocket = io(`${workerUrl}/management`, {
        reconnection: true,
        reconnectionAttempts: 10, // Keep trying 10 times
        reconnectionDelay: 2000,
        reconnectionDelayMax: 10000,
        timeout: 30000, // 30 seconds timeout
        transports: ["websocket"], // Allow fallback to polling
        upgrade: false,
        forceNew: true, // Force new connection
      });

      this.workerSocket.on("connect", () => {
        dockerLogger.info(`[VSCodeInstance ${this.instanceId}] Connected to worker`);
        this.workerConnected = true;
        this.emit("worker-connected");
        resolve();
      });

      this.workerSocket.on("disconnect", (reason) => {
        dockerLogger.warn(
          `[VSCodeInstance ${this.instanceId}] Disconnected from worker: ${reason}`
        );
        this.workerConnected = false;
        this.emit("worker-disconnected");
      });

      this.workerSocket.on("connect_error", (error) => {
        dockerLogger.error(
          `[VSCodeInstance ${this.instanceId}] Worker connection error:`,
          error.message
        );
        // Don't reject on connection errors after initial connection
        if (!this.workerConnected) {
          reject(error);
        }
      });

      // Set up worker event handlers
      this.workerSocket.on("worker:terminal-created", (data) => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Terminal created:`,
          data
        );
        this.emit("terminal-created", data);
      });

      this.workerSocket.on("worker:terminal-output", (data) => {
        this.emit("terminal-output", data);
      });

      this.workerSocket.on("worker:terminal-exit", (data) => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Terminal exited:`,
          data
        );
        this.emit("terminal-exit", data);
      });

      this.workerSocket.on("worker:terminal-idle", (data) => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Terminal idle detected:`,
          data
        );
        this.emit("terminal-idle", data);
      });

      this.workerSocket.on("worker:terminal-failed", (data) => {
        dockerLogger.error(
          `[VSCodeInstance ${this.instanceId}] Terminal failed:`,
          data
        );
        this.emit("terminal-failed", data);
      });

      this.workerSocket.on("worker:error", (data) => {
        dockerLogger.error(
          `[VSCodeInstance ${this.instanceId}] Worker error:`,
          data
        );
        this.emit("worker-error", data);
      });
    });
  }

  getWorkerSocket(): Socket<WorkerToServerEvents, ServerToWorkerEvents> | null {
    return this.workerSocket;
  }

  isWorkerConnected(): boolean {
    return this.workerConnected;
  }

  getInstanceId(): string {
    return this.instanceId;
  }

  getTaskRunId(): string {
    return this.taskRunId;
  }

  protected getWorkspaceUrl(baseUrl: string): string {
    return `${baseUrl}/?folder=/root/workspace`;
  }

  protected async disconnectFromWorker(): Promise<void> {
    if (this.workerSocket) {
      dockerLogger.info(
        `[VSCodeInstance ${this.instanceId}] Disconnecting from worker`
      );
      this.workerSocket.disconnect();
      this.workerSocket = null;
      this.workerConnected = false;
    }
  }

  // Override stop to also remove from registry
  protected async baseStop(): Promise<void> {
    await this.disconnectFromWorker();
    VSCodeInstance.instances.delete(this.instanceId);
  }
}
