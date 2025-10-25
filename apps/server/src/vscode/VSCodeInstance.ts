import { Id } from "@cmux/convex/dataModel";
import { connectToWorkerManagement } from "@cmux/shared/socket";
import { EventEmitter } from "node:events";
import { dockerLogger } from "../utils/fileLogger";
import {
  detectPreferredEditorSettings,
  syncEditorSettingsToWorker,
} from "../utils/editorSettingsSync";

export interface VSCodeInstanceConfig {
  workspacePath?: string;
  initialCommand?: string;
  agentName?: string;
  taskRunId: Id<"taskRuns">;
  taskId: Id<"tasks">;
  theme?: "dark" | "light" | "system";
  teamSlugOrId: string;
  // Optional: for CmuxVSCodeInstance to hydrate repo on start
  repoUrl?: string;
  branch?: string;
  newBranch?: string;
  // Optional: when starting from an environment
  environmentId?: Id<"environments"> | string;
  // Optional: JWT token for crown workflow authentication
  taskRunJwt?: string;
}

export interface VSCodeInstanceInfo {
  url: string;
  workspaceUrl: string;
  instanceId: string;
  taskRunId: Id<"taskRuns">;
  provider: "docker" | "morph" | "daytona";
}

export abstract class VSCodeInstance extends EventEmitter {
  // Static registry of all VSCode instances
  protected static instances = new Map<Id<"taskRuns">, VSCodeInstance>();

  protected config: VSCodeInstanceConfig;
  protected instanceId: Id<"taskRuns">;
  protected taskRunId: Id<"taskRuns">;
  protected taskId: Id<"tasks">;
  protected workerSocket: ReturnType<typeof connectToWorkerManagement> | null =
    null;
  protected workerConnected: boolean = false;
  protected teamSlugOrId: string;

  constructor(config: VSCodeInstanceConfig) {
    super();
    this.config = config;
    this.taskRunId = config.taskRunId;
    this.taskId = config.taskId;
    this.teamSlugOrId = config.teamSlugOrId;
    // Use taskRunId as instanceId for backward compatibility
    this.instanceId = config.taskRunId;

    // Register this instance
    VSCodeInstance.instances.set(this.instanceId, this);
  }

  // Static methods to manage instances
  static getInstances(): Map<string, VSCodeInstance> {
    return VSCodeInstance.instances;
  }

  static getInstance(instanceId: Id<"taskRuns">): VSCodeInstance | undefined {
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
      this.workerSocket = connectToWorkerManagement({
        url: workerUrl,
        timeoutMs: 30_000,
        reconnectionAttempts: 10,
        forceNew: true,
      });

      this.workerSocket.on("connect", () => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Connected to worker`
        );
        this.workerConnected = true;
        this.emit("worker-connected");
        // Fire and forget settings sync; errors are logged downstream
        this.syncHostEditorSettings().catch((error) => {
          dockerLogger.warn(
            `[VSCodeInstance ${this.instanceId}] Failed to queue settings sync`,
            error
          );
        });
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

      this.workerSocket.on("worker:task-complete", (data) => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Task complete detected:`,
          data
        );
        this.emit("task-complete", data);
      });

      this.workerSocket.on("worker:terminal-failed", (data) => {
        dockerLogger.error(
          `[VSCodeInstance ${this.instanceId}] Terminal failed:`,
          data
        );
        this.emit("terminal-failed", data);
      });

      this.workerSocket.on("worker:file-changes", (data) => {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] File changes detected:`,
          { taskId: data.taskRunId, changeCount: data.changes.length }
        );
        this.emit("file-changes", data);
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

  protected async syncHostEditorSettings(): Promise<void> {
    if (!this.workerSocket || !this.workerConnected) {
      dockerLogger.debug(
        `[VSCodeInstance ${this.instanceId}] Skipping settings sync; worker not connected`
      );
      return;
    }

    try {
      const detection = await detectPreferredEditorSettings();
      const { selection } = detection;
      if (!selection) {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] No host editor settings found`,
          {
            candidates: detection.all.map((candidate) => ({
              id: candidate.id,
              userDir: candidate.userDir,
              hasSettings: Boolean(candidate.settings),
            })),
          }
        );
        return;
      }

      const hasFiles = Boolean(
        selection.settings ||
          selection.keybindings ||
          selection.snippets.length > 0
      );

      if (!hasFiles) {
        dockerLogger.info(
          `[VSCodeInstance ${this.instanceId}] Host editor selection has no user files; skipping sync`
        );
        return;
      }
      await syncEditorSettingsToWorker({
        workerSocket: this.workerSocket,
        selection,
        logger: {
          info: (message, metadata) =>
            dockerLogger.info(
              `[VSCodeInstance ${this.instanceId}] ${message}`,
              metadata
            ),
          warn: (message, metadata) =>
            dockerLogger.warn(
              `[VSCodeInstance ${this.instanceId}] ${message}`,
              metadata
            ),
          error: (message, metadata) =>
            dockerLogger.error(
              `[VSCodeInstance ${this.instanceId}] ${message}`,
              metadata
            ),
        },
      });
    } catch (error) {
      dockerLogger.warn(
        `[VSCodeInstance ${this.instanceId}] Error during settings detection`,
        error
      );
    }
  }

  getWorkerSocket(): ReturnType<typeof connectToWorkerManagement> {
    if (!this.workerSocket) {
      throw new Error("Worker socket not connected");
    }
    return this.workerSocket;
  }

  isWorkerConnected(): boolean {
    return this.workerConnected;
  }

  startFileWatch(worktreePath: string): void {
    if (this.workerSocket && this.workerConnected) {
      // Always watch the container workspace path; host paths are not valid inside the container
      const containerWorkspace = "/root/workspace";
      dockerLogger.info(
        `[VSCodeInstance ${this.instanceId}] Starting file watch for ${worktreePath} -> ${containerWorkspace}`
      );
      this.workerSocket.emit("worker:start-file-watch", {
        taskRunId: this.taskRunId,
        worktreePath: containerWorkspace,
      });
    } else {
      dockerLogger.warn(
        `[VSCodeInstance ${this.instanceId}] Cannot start file watch - worker not connected`
      );
    }
  }

  stopFileWatch(): void {
    if (this.workerSocket && this.workerConnected) {
      dockerLogger.info(
        `[VSCodeInstance ${this.instanceId}] Stopping file watch`
      );
      this.workerSocket.emit("worker:stop-file-watch", {
        taskRunId: this.taskRunId,
      });
    }
  }

  getInstanceId(): Id<"taskRuns"> {
    return this.instanceId;
  }

  getTaskRunId(): Id<"taskRuns"> {
    return this.taskRunId;
  }

  abstract getName(): string;

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
    // Stop file watching before disconnecting
    this.stopFileWatch();
    await this.disconnectFromWorker();
    VSCodeInstance.instances.delete(this.instanceId);
  }
}
