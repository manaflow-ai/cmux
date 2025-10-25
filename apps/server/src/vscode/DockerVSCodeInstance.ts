import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import Docker from "dockerode";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getDockerSocketCandidates } from "@cmux/shared/providers/common/check-docker";
import { getConvex } from "../utils/convexClient";
import { cleanupGitCredentials } from "../utils/dockerGitSetup";
import { dockerLogger } from "../utils/fileLogger";
import { getGitHubTokenFromKeychain } from "../utils/getGitHubToken";
import { getAuthToken, runWithAuthToken } from "../utils/requestContext";
import {
  VSCodeInstance,
  type VSCodeInstanceConfig,
  type VSCodeInstanceInfo,
} from "./VSCodeInstance";

// Global port mapping storage
export interface ContainerMapping {
  containerName: string;
  instanceId: Id<"taskRuns">;
  teamSlugOrId: string;
  authToken?: string;
  ports: {
    vscode: string;
    worker: string;
    extension?: string;
    proxy?: string;
    vnc?: string;
  };
  status: "starting" | "running" | "stopped";
  workspacePath?: string;
}

export const containerMappings = new Map<string, ContainerMapping>();

interface DockerEvent {
  status?: string;
  id: string;
  Actor?: {
    Attributes?: Record<string, string>;
  };
}

type HostConfigWithCgroupns =
  Docker.ContainerCreateOptions["HostConfig"] & {
    CgroupnsMode?: "host" | "private";
  };

export class DockerVSCodeInstance extends VSCodeInstance {
  private containerName: string;
  private imageName: string;
  private container: Docker.Container | null = null;
  private authToken: string | undefined;
  private portCache: {
    ports: { [key: string]: string } | null;
    timestamp: number;
  } | null = null;
  private static readonly PORT_CACHE_DURATION = 2000; // 2 seconds
  private static eventsStream: NodeJS.ReadableStream | null = null;
  private static dockerInstance: Docker | null = null;
  private static eventStreamRetryTimer: NodeJS.Timeout | null = null;
  private static eventStreamBackoffMs = 1000;

  // Get or create the Docker singleton
  static getDocker(): Docker {
    if (!DockerVSCodeInstance.dockerInstance) {
      const socketPath = DockerVSCodeInstance.getDockerSocketPath();
      DockerVSCodeInstance.dockerInstance = socketPath
        ? new Docker({ socketPath })
        : new Docker();
    }
    return DockerVSCodeInstance.dockerInstance;
  }

  constructor(config: VSCodeInstanceConfig) {
    super(config);
    this.containerName = `cmux-${this.taskRunId}`;
    this.imageName = process.env.WORKER_IMAGE_NAME || "cmux-worker:0.0.1";
    dockerLogger.info(`WORKER_IMAGE_NAME: ${process.env.WORKER_IMAGE_NAME}`);
    dockerLogger.info(`this.imageName: ${this.imageName}`);
    // Register this instance
    VSCodeInstance.getInstances().set(this.instanceId, this);
  }

  private async ensureImageExists(docker: Docker): Promise<void> {
    try {
      // Check if image exists locally
      await docker.getImage(this.imageName).inspect();
      dockerLogger.info(`Image ${this.imageName} found locally`);
    } catch (_error) {
      // Image doesn't exist locally, try to pull it
      dockerLogger.info(
        `Image ${this.imageName} not found locally, pulling...`
      );

      try {
        const stream = await docker.pull(this.imageName);
        await new Promise((resolve, reject) => {
          docker.modem.followProgress(
            stream,
            (err: Error | null, res: unknown[]) => {
              if (err) {
                reject(err);
              } else {
                resolve(res);
              }
            },
            (event: { status: string; progress: string }) => {
              // Log pull progress
              if (event.status) {
                dockerLogger.info(
                  `Pull progress: ${event.status} ${event.progress || ""}`
                );
              }
            }
          );
        });
        dockerLogger.info(`Successfully pulled image ${this.imageName}`);
      } catch (pullError) {
        dockerLogger.error(
          `Failed to pull image ${this.imageName}:`,
          pullError
        );
        throw new Error(
          `Failed to pull Docker image ${this.imageName}: ${pullError}`
        );
      }
    }
  }

  /**
   * Get the actual host port for a given container port
   * @param containerPort The port inside the container (e.g., "39378", "39377", "39376", "39379", "39380")
   * @returns The actual host port or null if not found
   */
  async getActualPort(containerPort: string): Promise<string | null> {
    // Check cache first
    if (
      this.portCache &&
      Date.now() - this.portCache.timestamp <
        DockerVSCodeInstance.PORT_CACHE_DURATION
    ) {
      return this.portCache.ports?.[containerPort] || null;
    }

    const docker = DockerVSCodeInstance.getDocker();

    try {
      // Get container if we don't have it
      if (!this.container) {
        const containers = await docker.listContainers({
          all: true,
          filters: { name: [this.containerName] },
        });

        if (containers.length === 0) {
          return null;
        }

        this.container = docker.getContainer(containers[0].Id);
      }

      // Get container info with port mappings
      const containerInfo = await this.container.inspect();

      if (!containerInfo.State.Running) {
        // Clear cache for stopped containers
        this.portCache = null;
        return null;
      }

      const ports = containerInfo.NetworkSettings.Ports;
      const portMapping: { [key: string]: string } = {};

      // Map container ports to host ports
      if (ports[`${containerPort}/tcp`]?.[0]?.HostPort) {
        portMapping[containerPort] = ports[`${containerPort}/tcp`][0].HostPort;
      }

      // Also cache other known ports while we're at it
      if (ports["39375/tcp"]?.[0]?.HostPort) {
        portMapping["39375"] = ports["39375/tcp"][0].HostPort;
      }
      if (ports["39378/tcp"]?.[0]?.HostPort) {
        portMapping["39378"] = ports["39378/tcp"][0].HostPort;
      }
      if (ports["39377/tcp"]?.[0]?.HostPort) {
        portMapping["39377"] = ports["39377/tcp"][0].HostPort;
      }
      if (ports["39376/tcp"]?.[0]?.HostPort) {
        portMapping["39376"] = ports["39376/tcp"][0].HostPort;
      }
      if (ports["39379/tcp"]?.[0]?.HostPort) {
        portMapping["39379"] = ports["39379/tcp"][0].HostPort;
      }
      if (ports["39380/tcp"]?.[0]?.HostPort) {
        portMapping["39380"] = ports["39380/tcp"][0].HostPort;
      }
      if (ports["39381/tcp"]?.[0]?.HostPort) {
        portMapping["39381"] = ports["39381/tcp"][0].HostPort;
      }

      // Update cache
      this.portCache = {
        ports: portMapping,
        timestamp: Date.now(),
      };

      return portMapping[containerPort] || null;
    } catch (error) {
      dockerLogger.error(
        `Failed to get port mapping for container ${this.containerName}:`,
        error
      );
      return null;
    }
  }

  async start(): Promise<VSCodeInstanceInfo> {
    dockerLogger.info(`Starting Docker VSCode instance: ${this.containerName}`);
    dockerLogger.info(`  Image: ${this.imageName}`);
    dockerLogger.info(`  Workspace: ${this.config.workspacePath}`);
    dockerLogger.info(`  Agent name: ${this.config.agentName}`);

    const docker = DockerVSCodeInstance.getDocker();

    // Check if image exists and pull if missing
    await this.ensureImageExists(docker);

    // Capture current auth token for this instance and mapping
    this.authToken = getAuthToken();

    // Set initial mapping status
    containerMappings.set(this.containerName, {
      containerName: this.containerName,
      instanceId: this.instanceId,
      teamSlugOrId: this.teamSlugOrId,
      authToken: this.authToken,
      ports: { vscode: "", worker: "", extension: "", proxy: "", vnc: "" },
      status: "starting",
      workspacePath: this.config.workspacePath,
    });

    // Stop and remove any existing container with same name
    try {
      const existingContainer = docker.getContainer(this.containerName);
      const info = await existingContainer.inspect().catch(() => null);
      if (info) {
        dockerLogger.info(`Removing existing container ${this.containerName}`);
        await existingContainer.stop().catch(() => {});
        await existingContainer.remove().catch(() => {});
      }
    } catch (_error) {
      // Container doesn't exist, which is fine
    }

    const envVars = ["NODE_ENV=production", "WORKER_PORT=39377"];

    // Add theme environment variable if provided
    if (this.config.theme) {
      envVars.push(`VSCODE_THEME=${this.config.theme}`);
    }

    // Create container configuration
    const hostConfig: HostConfigWithCgroupns = {
      AutoRemove: true,
      Privileged: true,
      CgroupnsMode: "host",
      PortBindings: {
        "39375/tcp": [{ HostPort: "0" }], // Exec service port
        "39378/tcp": [{ HostPort: "0" }], // VS Code port
        "39377/tcp": [{ HostPort: "0" }], // Worker port
        "39376/tcp": [{ HostPort: "0" }], // Extension socket port
        "39379/tcp": [{ HostPort: "0" }], // cmux-proxy port
        "39380/tcp": [{ HostPort: "0" }], // VNC websocket proxy port
        "39381/tcp": [{ HostPort: "0" }], // Chrome DevTools port
      },
      Tmpfs: {
        "/run": "rw,mode=755",
        "/run/lock": "rw,mode=755",
      },
      Binds: ["/sys/fs/cgroup:/sys/fs/cgroup:rw"],
    };

    const createOptions: Docker.ContainerCreateOptions = {
      name: this.containerName,
      Image: this.imageName,
      Env: envVars,
      HostConfig: hostConfig,
      ExposedPorts: {
        "39375/tcp": {},
        "39378/tcp": {},
        "39377/tcp": {},
        "39376/tcp": {},
        "39379/tcp": {},
        "39380/tcp": {},
        "39381/tcp": {},
      },
    };
    dockerLogger.info(
      `Container create options: ${JSON.stringify(createOptions)}`
    );

    // Add volume mount if workspace path is provided
    if (this.config.workspacePath) {
      // Extract the origin path from the workspace path
      // Workspace path is like: ~/cmux/<repoName>/worktrees/<branchName>
      // Origin path is: ~/cmux/<repoName>/origin
      const pathParts = this.config.workspacePath.split("/");
      const worktreesIndex = pathParts.lastIndexOf("worktrees");

      if (worktreesIndex > 0) {
        // Build the origin path
        const originPath = [
          ...pathParts.slice(0, worktreesIndex),
          "origin",
        ].join("/");

        // Get the user's home directory for git config
        const homeDir = os.homedir();
        const gitConfigPath = path.join(homeDir, ".gitconfig");

        const binds =
          createOptions.HostConfig?.Binds ??
          ["/sys/fs/cgroup:/sys/fs/cgroup:rw"];
        if (!createOptions.HostConfig?.Binds) {
          createOptions.HostConfig!.Binds = binds;
        }
        binds.push(`${this.config.workspacePath}:/root/workspace`);
        // Mount the origin directory at the same absolute path to preserve git references
        binds.push(`${originPath}:${originPath}:rw`); // Read-write mount for git operations

        // Mount SSH directory for git authentication
        const sshDir = path.join(homeDir, ".ssh");
        try {
          await fs.promises.access(sshDir);
          binds.push(`${sshDir}:/root/.ssh:ro`);
          dockerLogger.info(`  SSH mount: ${sshDir} -> /root/.ssh (read-only)`);
        } catch {
          dockerLogger.info(`  No SSH directory found at ${sshDir}`);
        }

        // Mount git config if it exists
        try {
          await fs.promises.access(gitConfigPath);

          // Read and filter the git config to remove macOS-specific settings
          const gitConfigContent = await fs.promises.readFile(
            gitConfigPath,
            "utf8"
          );
          const filteredConfig = this.filterGitConfig(gitConfigContent);

          // Write filtered config to a temporary location
          const tempDir = path.join(os.tmpdir(), "cmux-git-configs");
          await fs.promises.mkdir(tempDir, { recursive: true });
          const tempGitConfigPath = path.join(
            tempDir,
            `gitconfig-${this.instanceId}`
          );
          await fs.promises.writeFile(tempGitConfigPath, filteredConfig);

          binds.push(`${tempGitConfigPath}:/root/.gitconfig:ro`);
          dockerLogger.info(
            `  Git config mount: ${tempGitConfigPath} -> /root/.gitconfig (filtered, read-only)`
          );
        } catch {
          // Git config doesn't exist, which is fine
          dockerLogger.info(`  No git config found at ${gitConfigPath}`);
        }

        createOptions.HostConfig!.Binds = binds;

        dockerLogger.info(
          `  Origin mount: ${originPath} -> ${originPath} (read-write)`
        );
      } else {
        // Fallback to just mounting the workspace
        const homeDir = os.homedir();
        const gitConfigPath = path.join(homeDir, ".gitconfig");

        const binds =
          createOptions.HostConfig?.Binds ??
          ["/sys/fs/cgroup:/sys/fs/cgroup:rw"];
        if (!createOptions.HostConfig?.Binds) {
          createOptions.HostConfig!.Binds = binds;
        }
        binds.push(`${this.config.workspacePath}:/root/workspace`);

        // Mount SSH directory for git authentication
        const sshDir = path.join(homeDir, ".ssh");
        try {
          await fs.promises.access(sshDir);
          binds.push(`${sshDir}:/root/.ssh:ro`);
          dockerLogger.info(`  SSH mount: ${sshDir} -> /root/.ssh (read-only)`);
        } catch {
          dockerLogger.info(`  No SSH directory found at ${sshDir}`);
        }

        // Mount GitHub CLI config for authentication
        const ghConfigDir = path.join(homeDir, ".config", "gh");
        try {
          await fs.promises.access(ghConfigDir);
          binds.push(`${ghConfigDir}:/root/.config/gh:rw`);
          dockerLogger.info(
            `  GitHub CLI config mount: ${ghConfigDir} -> /root/.config/gh (read-write)`
          );
        } catch {
          dockerLogger.info(`  No GitHub CLI config found at ${ghConfigDir}`);
        }

        // Mount git config if it exists
        try {
          await fs.promises.access(gitConfigPath);

          // Read and filter the git config to remove macOS-specific settings
          const gitConfigContent = await fs.promises.readFile(
            gitConfigPath,
            "utf8"
          );
          const filteredConfig = this.filterGitConfig(gitConfigContent);

          // Write filtered config to a temporary location
          const tempDir = path.join(os.tmpdir(), "cmux-git-configs");
          await fs.promises.mkdir(tempDir, { recursive: true });
          const tempGitConfigPath = path.join(
            tempDir,
            `gitconfig-${this.instanceId}`
          );
          await fs.promises.writeFile(tempGitConfigPath, filteredConfig);

          binds.push(`${tempGitConfigPath}:/root/.gitconfig:ro`);
          dockerLogger.info(
            `  Git config mount: ${tempGitConfigPath} -> /root/.gitconfig (filtered, read-only)`
          );
        } catch {
          // Git config doesn't exist, which is fine
          dockerLogger.info(`  No git config found at ${gitConfigPath}`);
        }

        createOptions.HostConfig!.Binds = binds;
      }
    }

    dockerLogger.info(`Creating container...`);

    // Create and start the container
    this.container = await docker.createContainer(createOptions);
    dockerLogger.info(`Container created: ${this.container.id}`);

    await this.container.start();
    dockerLogger.info(`Container started`);

    // Fire-and-forget: bootstrap GitHub auth and devcontainer in background
    // Do not block agent startup
    this.bootstrapContainerEnvironment().catch((err) => {
      dockerLogger.warn(
        `Container bootstrap skipped or failed for ${this.containerName}:`,
        err
      );
    });

    // Get container info including port mappings
    const containerInfo = await this.container.inspect();
    const ports = containerInfo.NetworkSettings.Ports;

    const vscodePort = ports["39378/tcp"]?.[0]?.HostPort;
    const workerPort = ports["39377/tcp"]?.[0]?.HostPort;
    const extensionPort = ports["39376/tcp"]?.[0]?.HostPort;
    const proxyPort = ports["39379/tcp"]?.[0]?.HostPort;
    const vncPort = ports["39380/tcp"]?.[0]?.HostPort;

    if (!vscodePort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get VS Code port mapping for port 39378");
    }

    if (!workerPort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get worker port mapping for port 39377");
    }

    if (!proxyPort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get proxy port mapping for port 39379");
    }

    if (!vncPort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get VNC port mapping for port 39380");
    }

    // Update the container mapping with actual ports
    const mapping = containerMappings.get(this.containerName);
    if (mapping) {
      mapping.ports = {
        vscode: vscodePort,
        worker: workerPort,
        extension: extensionPort,
        proxy: proxyPort,
        vnc: vncPort,
      };
      mapping.status = "running";
    }

    // Update VSCode ports in Convex
    try {
      await getConvex().mutation(api.taskRuns.updateVSCodePorts, {
        teamSlugOrId: this.teamSlugOrId,
        id: this.taskRunId,
        ports: {
          vscode: vscodePort,
          worker: workerPort,
          extension: extensionPort,
          proxy: proxyPort,
          vnc: vncPort,
        },
      });
    } catch (error) {
      dockerLogger.error("Failed to update VSCode ports in Convex:", error);
    }

    // Wait for worker to be ready by polling
    dockerLogger.info(
      `Waiting for worker to be ready on port ${workerPort}...`
    );
    const maxAttempts = 30; // 15 seconds max
    const delayMs = 500;

    for (let i = 0; i < maxAttempts; i++) {
      try {
        const response = await fetch(
          `http://localhost:${workerPort}/socket.io/?EIO=4&transport=polling`
        );
        if (response.ok) {
          dockerLogger.info(`Worker is ready!`);
          break;
        }
      } catch {
        // Connection refused, worker not ready yet
      }

      if (i < maxAttempts - 1) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      } else {
        dockerLogger.warn("Worker may not be fully ready, but continuing...");
      }
    }

    const baseUrl = `http://localhost:${vscodePort}`;
    const workspaceUrl = this.getWorkspaceUrl(baseUrl);
    const workerUrl = `http://localhost:${workerPort}`;

    // Generate the proxy URL that clients will use
    dockerLogger.info(`Docker VSCode instance started:`);
    dockerLogger.info(`  VS Code URL: ${workspaceUrl}`);
    dockerLogger.info(`  Worker URL: ${workerUrl}`);

    // Monitor container events
    this.setupContainerEventMonitoring();

    // Connect to the worker
    try {
      await this.connectToWorker(workerUrl);
      dockerLogger.info(
        `Successfully connected to worker for container ${this.containerName}`
      );

      // Configure git in the worker
      await this.configureGitInWorker();
    } catch (error) {
      dockerLogger.error(
        `Failed to connect to worker for container ${this.containerName}:`,
        error
      );
      // Capture recent container logs to aid debugging worker startup issues
      try {
        const recentLogs = await this.getLogs(300);
        dockerLogger.error(
          `Recent container logs for ${this.containerName}:\n${recentLogs.trim()}`
        );
      } catch (e) {
        dockerLogger.error(
          `Unable to fetch logs for ${this.containerName}:`,
          e
        );
      }
      // Continue anyway - the instance is running even if we can't connect to the worker
    }

    return {
      url: baseUrl, // Store the actual localhost URL
      workspaceUrl: workspaceUrl, // Store the actual localhost workspace URL
      instanceId: this.instanceId,
      taskRunId: this.taskRunId,
      provider: "docker",
    };
  }

  private setupContainerEventMonitoring() {
    if (!this.container) return;

    // Monitor container events
    this.container.wait(
      async (err: Error | null, data: { StatusCode: number }) => {
        if (err) {
          dockerLogger.error(`Container wait error:`, err);
        } else {
          dockerLogger.info(
            `Container ${this.containerName} exited with status:`,
            data
          );
          // Attempt to capture recent logs on exit to aid debugging
          try {
            const recentLogs = await this.getLogs(300);
            dockerLogger.error(
              `Recent container logs for ${this.containerName} (on exit):\n${recentLogs.trim()}`
            );
          } catch (e) {
            dockerLogger.error(
              `Unable to fetch logs for ${this.containerName} on exit:`,
              e
            );
          }
          // Update mapping status to stopped
          const mapping = containerMappings.get(this.containerName);
          if (mapping) {
            mapping.status = "stopped";
          }

          // Update VSCode status in Convex
          try {
            await runWithAuthToken(this.authToken, async () =>
              getConvex().mutation(api.taskRuns.updateVSCodeStatus, {
                teamSlugOrId: this.teamSlugOrId,
                id: this.taskRunId,
                status: "stopped",
                stoppedAt: Date.now(),
              })
            );
          } catch (error) {
            dockerLogger.error(
              "Failed to update VSCode status in Convex:",
              error
            );
          }

          this.emit("exit", data.StatusCode);
        }
      }
    );

    // Attach to container streams for logs (only if DEBUG is enabled)
    if (process.env.DEBUG) {
      this.container.attach(
        { stream: true, stdout: true, stderr: true },
        (err: Error | null, stream?: NodeJS.ReadWriteStream) => {
          if (err) {
            dockerLogger.error(`Failed to attach to container streams:`, err);
            return;
          }

          // Demultiplex the stream
          this.container!.modem.demuxStream(
            stream!,
            process.stdout,
            process.stderr
          );
        }
      );
    }
  }

  async stop(): Promise<void> {
    dockerLogger.info(`Stopping Docker VSCode instance: ${this.containerName}`);

    // Update mapping status
    const mapping = containerMappings.get(this.containerName);
    if (mapping) {
      mapping.status = "stopped";
    }

    // Update VSCode status in Convex
    try {
      await runWithAuthToken(this.authToken, async () =>
        getConvex().mutation(api.taskRuns.updateVSCodeStatus, {
          teamSlugOrId: this.teamSlugOrId,
          id: this.taskRunId,
          status: "stopped",
          stoppedAt: Date.now(),
        })
      );
    } catch (error) {
      console.error("Failed to update VSCode status in Convex:", error);
    }

    if (this.container) {
      try {
        await this.container.stop();
        dockerLogger.info(`Container ${this.containerName} stopped`);
      } catch (error) {
        if ((error as { statusCode?: number }).statusCode !== 304) {
          // 304 means container already stopped
          dockerLogger.error(
            `Error stopping container ${this.containerName}:`,
            error
          );
        }
      }
    }

    // Clean up temporary git config file
    try {
      const tempGitConfigPath = path.join(
        os.tmpdir(),
        "cmux-git-configs",
        `gitconfig-${this.instanceId}`
      );
      await fs.promises.unlink(tempGitConfigPath);
      dockerLogger.info(`Cleaned up temporary git config file`);
    } catch {
      // File might not exist, which is fine
    }

    // Clean up git credentials file if we created one
    await cleanupGitCredentials(this.instanceId);

    // Call base stop to disconnect from worker and remove from registry
    await this.baseStop();
  }

  async getStatus(): Promise<{ running: boolean; info?: VSCodeInstanceInfo }> {
    try {
      const docker = DockerVSCodeInstance.getDocker();
      if (!this.container) {
        // Try to find container by name
        const containers = await docker.listContainers({
          all: true,
          filters: { name: [this.containerName] },
        });

        if (containers.length > 0) {
          this.container = docker.getContainer(containers[0].Id);
        } else {
          return { running: false };
        }
      }

      const containerInfo = await this.container.inspect();
      const running = containerInfo.State.Running;

      if (running) {
        const ports = containerInfo.NetworkSettings.Ports;
        const vscodePort = ports["39378/tcp"]?.[0]?.HostPort;

        if (vscodePort) {
          const baseUrl = `http://localhost:${vscodePort}`;
          const workspaceUrl = this.getWorkspaceUrl(baseUrl);

          return {
            running: true,
            info: {
              url: baseUrl,
              workspaceUrl: workspaceUrl,
              instanceId: this.instanceId,
              taskRunId: this.taskRunId,
              provider: "docker",
            },
          };
        }
      }

      return { running };
    } catch (_error) {
      return { running: false };
    }
  }

  async getLogs(tail = 100): Promise<string> {
    if (!this.container) {
      throw new Error("Container not initialized");
    }

    const stream = await this.container.logs({
      stdout: true,
      stderr: true,
      tail,
      timestamps: true,
    });

    // Convert the stream to string
    const logs = stream.toString("utf8");
    return logs;
  }

  // Bootstrap container environment including GitHub auth and devcontainer
  private async bootstrapContainerEnvironment(): Promise<void> {
    // First, set up GitHub authentication
    await this.bootstrapGitHubAuth();

    // Then, bootstrap devcontainer if present
    await this.bootstrapDevcontainerIfPresent();
  }

  // Authenticate GitHub CLI using token from host
  private async bootstrapGitHubAuth(): Promise<void> {
    try {
      if (!this.container) {
        dockerLogger.debug(
          `bootstrapGitHubAuth: container not available for ${this.containerName}`
        );
        return;
      }

      // Get GitHub token from host
      const githubToken = await getGitHubTokenFromKeychain();
      if (!githubToken) {
        dockerLogger.info(
          "No GitHub token found on host (Convex, gh, or keychain) - skipping gh auth setup"
        );
        return;
      }

      dockerLogger.info(
        `Setting up GitHub CLI authentication in container ${this.containerName}...`
      );

      // Prepare command to authenticate gh CLI with token
      const authCmd = [
        "bash",
        "-lc",
        `echo '${githubToken}' | gh auth login --with-token 2>&1`,
      ];

      const exec = await this.container.exec({
        Cmd: authCmd,
        AttachStdout: true,
        AttachStderr: true,
      });

      await new Promise<void>((resolve, reject) => {
        exec.start({}, (err: Error | null, stream?: NodeJS.ReadableStream) => {
          if (err) {
            reject(err);
            return;
          }
          if (stream) {
            let output = "";
            stream.on("data", (chunk) => {
              output += chunk.toString();
            });
            stream.on("end", () => {
              if (
                output.includes("Logged in as") ||
                output.includes("already logged in")
              ) {
                dockerLogger.info(
                  `GitHub CLI authenticated successfully in container ${this.containerName}`
                );
              } else {
                dockerLogger.warn(
                  `GitHub CLI authentication output for ${this.containerName}: ${output}`
                );
              }
              resolve();
            });
          } else {
            resolve();
          }
        });
      });
    } catch (error) {
      dockerLogger.warn(
        `GitHub CLI authentication error for ${this.containerName}:`,
        error
      );
    }
  }

  // Detect and start devcontainer tooling inside the running OpenVSCode container
  // Runs in background and writes output to /root/workspace/.cmux/devcontainer.log
  private async bootstrapDevcontainerIfPresent(): Promise<void> {
    try {
      if (!this.container) {
        dockerLogger.debug(
          `bootstrapDevcontainerIfPresent: container not available for ${this.containerName}`
        );
        return;
      }

      // Only attempt when workspace is mounted
      const workspaceHostPath = this.config.workspacePath;
      if (!workspaceHostPath) {
        dockerLogger.debug(
          `bootstrapDevcontainerIfPresent: no workspacePath for ${this.containerName}`
        );
        return;
      }

      // Check host for .devcontainer/devcontainer.json
      const devcontainerFile = path.join(
        workspaceHostPath,
        ".devcontainer",
        "devcontainer.json"
      );
      try {
        await fs.promises.access(devcontainerFile, fs.constants.F_OK);
      } catch {
        dockerLogger.info(
          `No devcontainer found at ${devcontainerFile}; skipping setup.`
        );
        return;
      }

      dockerLogger.info(
        `Devcontainer detected. Bootstrapping inside ${this.containerName} (non-blocking)...`
      );

      // Prepare background command inside the container
      const bootstrapCmd = [
        "bash",
        "-lc",
        [
          "set -euo pipefail",
          "mkdir -p /root/workspace/.cmux",
          // Only run if devcontainer file exists in container mount as well
          "if [ -f /root/workspace/.devcontainer/devcontainer.json ]; then",
          // Run in background; redirect output to a log inside workspace
          "  (cd /root/workspace && nohup bunx @devcontainers/cli up --workspace-folder . >> /root/workspace/.cmux/devcontainer.log 2>&1 &)",
          "  echo 'devcontainer up triggered in background' >> /root/workspace/.cmux/devcontainer.log",
          "else",
          "  echo 'devcontainer.json not found in container' >> /root/workspace/.cmux/devcontainer.log",
          "fi",
        ].join(" && "),
      ];

      const exec = await this.container.exec({
        Cmd: bootstrapCmd,
        AttachStdout: true,
        AttachStderr: true,
      });

      await new Promise<void>((resolve, reject) => {
        exec.start({}, (err: Error | null, stream?: NodeJS.ReadableStream) => {
          if (err) {
            reject(err);
            return;
          }
          if (stream) {
            // Drain and detach immediately; the actual work is backgrounded
            stream.on("end", () => resolve());
            stream.resume();
          } else {
            resolve();
          }
        });
      });

      dockerLogger.info(
        `Devcontainer bootstrap command issued for ${this.containerName}`
      );
    } catch (error) {
      dockerLogger.warn(
        `Devcontainer bootstrap error for ${this.containerName}:`,
        error
      );
    }
  }

  getName() {
    return `docker-${this.containerName}`;
  }

  getPorts(): {
    vscode?: string;
    worker?: string;
    extension?: string;
    proxy?: string;
    vnc?: string;
  } | null {
    const mapping = containerMappings.get(this.containerName);
    return mapping?.ports || null;
  }

  private filterGitConfig(gitConfigContent: string): string {
    // Filter out macOS-specific credential helpers and other incompatible settings
    const lines = gitConfigContent.split("\n");
    const filteredLines: string[] = [];
    let inCredentialSection = false;
    let skipNextLine = false;

    for (const line of lines) {
      // Skip continuation of previous line
      if (skipNextLine && line.match(/^\s+/)) {
        continue;
      }
      skipNextLine = false;

      // Check if we're entering a credential section
      if (line.trim().match(/^\[credential/)) {
        inCredentialSection = true;
        // Keep the section header but we'll filter its contents
        filteredLines.push(line);
        continue;
      }

      // Check if we're entering a new section
      if (line.trim().match(/^\[/) && inCredentialSection) {
        inCredentialSection = false;
      }

      // In credential section, only skip macOS/Windows specific helpers
      if (inCredentialSection) {
        if (
          line.trim().includes("helper = osxkeychain") ||
          line.trim().includes("helper = manager-core") ||
          line.trim().includes("helper = manager") ||
          line.trim().includes("helper = wincred")
        ) {
          skipNextLine = true; // Skip any continuation lines
          continue;
        }
      }

      // Skip specific problematic settings outside credential sections
      if (
        !inCredentialSection &&
        (line.trim().includes("credential.helper = osxkeychain") ||
          line.trim().includes("credential.helper = manager"))
      ) {
        continue;
      }

      // Skip SSL backend settings that may not be compatible with container
      if (
        line.trim().includes("http.sslbackend") ||
        line.trim().includes("http.sslcert") ||
        line.trim().includes("http.sslkey") ||
        line.trim().includes("http.sslcainfo") ||
        line.trim().includes("http.sslverify")
      ) {
        continue;
      }

      filteredLines.push(line);
    }

    // Add store credential helper config if no credential section exists
    const hasCredentialSection = filteredLines.some((line) =>
      line.trim().match(/^\[credential/)
    );
    if (!hasCredentialSection) {
      filteredLines.push("");
      filteredLines.push("[credential]");
      filteredLines.push("\thelper = store");
    }

    return filteredLines.join("\n");
  }

  private async configureGitInWorker(): Promise<void> {
    const workerSocket = this.getWorkerSocket();
    if (!workerSocket) {
      dockerLogger.warn("No worker socket available for git configuration");
      return;
    }

    try {
      // Get GitHub token from host
      const githubToken = await getGitHubTokenFromKeychain();

      // Read SSH keys if available
      const homeDir = os.homedir();
      const sshDir = path.join(homeDir, ".ssh");
      let sshKeys:
        | { privateKey?: string; publicKey?: string; knownHosts?: string }
        | undefined = undefined;

      try {
        const privateKeyPath = path.join(sshDir, "id_rsa");
        const publicKeyPath = path.join(sshDir, "id_rsa.pub");
        const knownHostsPath = path.join(sshDir, "known_hosts");

        sshKeys = {};

        try {
          const privateKey = await fs.promises.readFile(privateKeyPath);
          sshKeys.privateKey = privateKey.toString("base64");
        } catch {
          // Private key not found
        }

        try {
          const publicKey = await fs.promises.readFile(publicKeyPath);
          sshKeys.publicKey = publicKey.toString("base64");
        } catch {
          // Public key not found
        }

        try {
          const knownHosts = await fs.promises.readFile(knownHostsPath);
          sshKeys.knownHosts = knownHosts.toString("base64");
        } catch {
          // Known hosts not found
        }

        // Only include sshKeys if at least one key was found
        if (!sshKeys.privateKey && !sshKeys.publicKey && !sshKeys.knownHosts) {
          sshKeys = undefined;
        }
      } catch {
        // SSH directory not accessible
      }

      // Send git configuration to worker
      const gitConfig: Record<string, string> = {};
      const userName = await this.getGitConfigValue("user.name");
      const userEmail = await this.getGitConfigValue("user.email");

      if (userName) gitConfig["user.name"] = userName;
      if (userEmail) gitConfig["user.email"] = userEmail;

      workerSocket.emit("worker:configure-git", {
        githubToken: githubToken || undefined,
        gitConfig: Object.keys(gitConfig).length > 0 ? gitConfig : undefined,
        sshKeys,
      });

      dockerLogger.info("Git configuration sent to worker");
    } catch (error) {
      dockerLogger.error("Failed to configure git in worker:", error);
    }
  }

  private async getGitConfigValue(key: string): Promise<string | undefined> {
    try {
      const { execSync } = await import("child_process");
      const value = execSync(`git config --global ${key}`).toString().trim();
      return value || undefined;
    } catch {
      return undefined;
    }
  }

  // Static method to start the container state sync
  static startContainerStateSync(): void {
    DockerVSCodeInstance.stopContainerStateSync();
    DockerVSCodeInstance.syncDockerContainerStates();
  }

  // Static method to stop the container state sync
  static stopContainerStateSync(): void {
    DockerVSCodeInstance.clearEventStreamRetryTimer();
    DockerVSCodeInstance.closeEventStream();
  }

  private static syncDockerContainerStates(): void {
    dockerLogger.info("Starting docker event stream for container state sync");
    void DockerVSCodeInstance.startDockerodeEventStream();
  }

  // Try to stream events using the Docker socket (no CLI dependency)
  private static async startDockerodeEventStream(
    retryDelayMs = 1000
  ): Promise<void> {
    if (DockerVSCodeInstance.eventsStream) {
      return;
    }

    DockerVSCodeInstance.clearEventStreamRetryTimer();
    DockerVSCodeInstance.eventStreamBackoffMs = retryDelayMs;

    const socketPath = DockerVSCodeInstance.getDockerSocketPath();
    if (socketPath && !fs.existsSync(socketPath)) {
      DockerVSCodeInstance.scheduleEventStreamRestart(
        `Docker socket not found at ${socketPath}`
      );
      return;
    }

    try {
      const docker = DockerVSCodeInstance.getDocker();
      docker.getEvents({}, (err, stream) => {
        if (err) {
          DockerVSCodeInstance.scheduleEventStreamRestart(
            "Failed to attach to docker events stream",
            err
          );
          return;
        }
        if (!stream) {
          DockerVSCodeInstance.scheduleEventStreamRestart(
            "No stream returned by docker.getEvents"
          );
          return;
        }

        DockerVSCodeInstance.eventsStream = stream;
        DockerVSCodeInstance.eventStreamBackoffMs = 1000;

        let buffer = "";
        stream.on("data", (chunk: Buffer | string) => {
          buffer += chunk.toString();
          for (;;) {
            const idx = buffer.indexOf("\n");
            if (idx === -1) break;
            const line = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 1);
            if (!line.trim()) continue;
            try {
              const event = JSON.parse(line) as DockerEvent;
              void DockerVSCodeInstance.handleDockerEvent(event);
            } catch (e) {
              dockerLogger.error(
                "[docker events] Failed to parse socket event:",
                e
              );
            }
          }
        });

        stream.on("error", (e) => {
          DockerVSCodeInstance.logEventStreamError(
            "Socket stream error",
            e
          );
          DockerVSCodeInstance.closeEventStream();
          DockerVSCodeInstance.scheduleEventStreamRestart(
            "Socket stream error",
            e
          );
        });

        stream.on("close", () => {
          dockerLogger.info("docker socket events stream closed");
          DockerVSCodeInstance.closeEventStream();
          DockerVSCodeInstance.scheduleEventStreamRestart(
            "Docker socket events stream closed"
          );
        });
      });
    } catch (e) {
      DockerVSCodeInstance.scheduleEventStreamRestart(
        "Unable to start Dockerode event stream",
        e
      );
    }
  }

  private static logEventStreamError(message: string, error: unknown): void {
    const code =
      error &&
      typeof error === "object" &&
      "code" in error &&
      (typeof error.code === "string" || typeof error.code === "number")
        ? error.code
        : undefined;
    const isConnectionReset =
      code === "ECONNRESET" ||
      (error instanceof Error && error.message.includes("aborted"));

    if (isConnectionReset) {
      dockerLogger.warn(`[docker events] ${message}:`, error);
      return;
    }

    dockerLogger.error(`[docker events] ${message}:`, error);
  }

  private static clearEventStreamRetryTimer(): void {
    if (DockerVSCodeInstance.eventStreamRetryTimer) {
      clearTimeout(DockerVSCodeInstance.eventStreamRetryTimer);
      DockerVSCodeInstance.eventStreamRetryTimer = null;
    }
  }

  private static scheduleEventStreamRestart(
    reason: string,
    error?: unknown
  ): void {
    const delay = Math.min(
      Math.max(DockerVSCodeInstance.eventStreamBackoffMs, 500),
      30_000
    );
    DockerVSCodeInstance.eventStreamBackoffMs = Math.min(delay * 2, 30_000);

    if (error) {
      DockerVSCodeInstance.logEventStreamError(
        `${reason}. Retrying in ${delay}ms`,
        error
      );
    } else {
      dockerLogger.warn(`[docker events] ${reason}. Retrying in ${delay}ms`);
    }

    DockerVSCodeInstance.clearEventStreamRetryTimer();
    DockerVSCodeInstance.eventStreamRetryTimer = setTimeout(() => {
      DockerVSCodeInstance.eventStreamRetryTimer = null;
      void DockerVSCodeInstance.startDockerodeEventStream(
        DockerVSCodeInstance.eventStreamBackoffMs
      );
    }, delay);
  }

  private static closeEventStream(): void {
    if (!DockerVSCodeInstance.eventsStream) {
      return;
    }

    try {
      const stream = DockerVSCodeInstance.eventsStream;
      if (
        stream &&
        "removeAllListeners" in stream &&
        typeof stream.removeAllListeners === "function"
      ) {
        stream.removeAllListeners();
      }
      if (stream && "destroy" in stream && typeof stream.destroy === "function") {
        stream.destroy();
      }
    } catch {
      // ignore cleanup errors
    }

    DockerVSCodeInstance.eventsStream = null;
  }

  private static getDockerSocketPath(): string | null {
    const { remoteHost, candidates } = getDockerSocketCandidates();
    if (remoteHost) {
      return null;
    }

    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }

    return candidates[0] ?? null;
  }

  private static async handleDockerEvent(event: DockerEvent): Promise<void> {
    const containerName = event.Actor?.Attributes?.name;
    const status = event.status;
    if (!containerName || !status || !containerName.startsWith("cmux-")) {
      return;
    }

    const mapping = containerMappings.get(containerName);
    if (!mapping) {
      return;
    }

    const docker = DockerVSCodeInstance.getDocker();
    const taskRunId = mapping.instanceId;

    if (status === "start") {
      try {
        const container = docker.getContainer(event.id);
        const info = await container.inspect();
        const ports = info.NetworkSettings.Ports;
        const vscodePort = ports["39378/tcp"]?.[0]?.HostPort;
        const workerPort = ports["39377/tcp"]?.[0]?.HostPort;
        const extensionPort = ports["39376/tcp"]?.[0]?.HostPort;
        const proxyPort = ports["39379/tcp"]?.[0]?.HostPort;
        const vncPort = ports["39380/tcp"]?.[0]?.HostPort;
        if (vscodePort && workerPort && proxyPort && vncPort) {
          mapping.ports = {
            vscode: vscodePort,
            worker: workerPort,
            extension: extensionPort,
            proxy: proxyPort,
            vnc: vncPort,
          };
        }
        mapping.status = "running";
        try {
          if (!mapping.authToken) {
            dockerLogger.warn(
              `[docker events] No auth token for container ${containerName}; deferring Convex updates`
            );
            return;
          }
          await runWithAuthToken(mapping.authToken, async () => {
            if (vscodePort && workerPort && proxyPort && vncPort) {
              await getConvex().mutation(api.taskRuns.updateVSCodePorts, {
                teamSlugOrId: mapping.teamSlugOrId,
                id: taskRunId,
                ports: {
                  vscode: vscodePort,
                  worker: workerPort,
                  extension: extensionPort,
                  proxy: proxyPort,
                  vnc: vncPort,
                },
              });
            }
            await getConvex().mutation(api.taskRuns.updateVSCodeStatus, {
              teamSlugOrId: mapping.teamSlugOrId,
              id: taskRunId,
              status: "running",
            });
          });
        } catch (error) {
          dockerLogger.error(
            `[docker events] Failed to update Convex state for container ${containerName}:`,
            error
          );
        }
      } catch (error) {
        dockerLogger.error(
          `[docker events] Failed to inspect container ${containerName}:`,
          error
        );
      }
    } else if (status === "stop" || status === "die" || status === "destroy") {
      mapping.status = "stopped";
      try {
        if (!mapping.authToken) {
          dockerLogger.warn(
            `[docker events] No auth token for container ${containerName}; skipping stopped status update`
          );
        } else {
          await runWithAuthToken(mapping.authToken, async () =>
            getConvex().mutation(api.taskRuns.updateVSCodeStatus, {
              teamSlugOrId: mapping.teamSlugOrId,
              id: taskRunId,
              status: "stopped",
              stoppedAt: Date.now(),
            })
          );
        }
      } catch (error) {
        dockerLogger.error(
          `[docker events] Failed to update stopped status for ${containerName}:`,
          error
        );
      }

      try {
        if (!mapping.authToken) {
          dockerLogger.warn(
            `[docker events] No auth token for container ${containerName}; skipping cleanup checks`
          );
        } else {
          await runWithAuthToken(mapping.authToken, async () => {
            const containerSettings = await getConvex().query(
              api.containerSettings.getEffective,
              { teamSlugOrId: mapping.teamSlugOrId }
            );
            if (containerSettings.autoCleanupEnabled) {
              await DockerVSCodeInstance.performContainerCleanup(
                containerSettings,
                mapping.teamSlugOrId
              );
            }
          });
        }
      } catch (error) {
        dockerLogger.error(
          `[docker events] Failed to perform cleanup after ${containerName} stopped:`,
          error
        );
      }
    }
  }

  private static async performContainerCleanup(
    settings: {
      maxRunningContainers: number;
      reviewPeriodMinutes: number;
      autoCleanupEnabled: boolean;
    },
    teamSlugOrId: string
  ): Promise<void> {
    try {
      dockerLogger.info(
        "[performContainerCleanup] Starting container cleanup..."
      );

      // 1. Check for containers that have exceeded their TTL
      const containersToStop = await getConvex().query(
        api.taskRuns.getContainersToStop,
        { teamSlugOrId }
      );

      for (const taskRun of containersToStop) {
        if (taskRun.vscode?.containerName) {
          const instance = VSCodeInstance.getInstance(taskRun._id);
          if (instance) {
            dockerLogger.info(
              `[performContainerCleanup] Stopping container ${taskRun.vscode.containerName} due to TTL expiry`
            );
            await instance.stop();
          }
        }
      }

      // 2. Enforce max running containers limit with smart prioritization
      const containerPriority = await getConvex().query(
        api.taskRuns.getRunningContainersByCleanupPriority,
        { teamSlugOrId }
      );

      if (containerPriority.total > settings.maxRunningContainers) {
        const containersToStop =
          containerPriority.total - settings.maxRunningContainers;
        const toRemove = containerPriority.prioritizedForCleanup.slice(
          0,
          containersToStop
        );

        for (const taskRun of toRemove) {
          if (taskRun.vscode?.containerName) {
            const instance = VSCodeInstance.getInstance(taskRun._id);
            if (instance) {
              const isReview = containerPriority.reviewContainers.some(
                (r) => r._id === taskRun._id
              );
              dockerLogger.info(
                `[performContainerCleanup] Stopping ${isReview ? "review-period" : "active"} container ${taskRun.vscode.containerName} to maintain max containers limit`
              );
              await instance.stop();
            }
          }
        }
      }

      dockerLogger.info(
        "[performContainerCleanup] Container cleanup completed"
      );
    } catch (error) {
      dockerLogger.error(
        "[performContainerCleanup] Error during cleanup:",
        error
      );
    }
  }
}
