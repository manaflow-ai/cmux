import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { getShortId } from "@cmux/shared";
import Docker from "dockerode";
import * as os from "os";
import * as path from "path";
import { convex } from "../utils/convexClient.js";
import { cleanupGitCredentials } from "../utils/dockerGitSetup.js";
import { dockerLogger } from "../utils/fileLogger.js";
import { getGitHubTokenFromKeychain } from "../utils/getGitHubToken.js";
import { createExtensionInstallScript } from "../utils/vscodeExtensions.js";
import {
  VSCodeInstance,
  type VSCodeInstanceConfig,
  type VSCodeInstanceInfo,
} from "./VSCodeInstance.js";

// Global port mapping storage
export interface ContainerMapping {
  containerName: string;
  instanceId: string;
  ports: {
    vscode: string;
    worker: string;
    extension?: string;
  };
  status: "starting" | "running" | "stopped";
  workspacePath?: string;
}

const containerMappings = new Map<string, ContainerMapping>();

export class DockerVSCodeInstance extends VSCodeInstance {
  private containerName: string;
  private imageName: string;
  private container: Docker.Container | null = null;
  private portCache: {
    ports: { [key: string]: string } | null;
    timestamp: number;
  } | null = null;
  private static readonly PORT_CACHE_DURATION = 2000; // 2 seconds
  private static syncInterval: ReturnType<typeof setTimeout> | null = null;
  private static dockerInstance: Docker | null = null;

  // Get or create the Docker singleton
  static getDocker(): Docker {
    if (!DockerVSCodeInstance.dockerInstance) {
      DockerVSCodeInstance.dockerInstance = new Docker({
        socketPath: "/var/run/docker.sock",
      });
    }
    return DockerVSCodeInstance.dockerInstance;
  }

  constructor(config: VSCodeInstanceConfig) {
    super(config);
    // Use a simplified container name based on taskRunId
    // Since taskRunId is a Convex ID like "jb74m5s2g9d6c5w6qkbmxsm7sh744d"
    // We'll take the first 12 chars for a shorter container name
    const shortId = getShortId(this.taskRunId);
    this.containerName = `cmux-${shortId}`;
    this.imageName = process.env.WORKER_IMAGE_NAME || "cmux-worker:0.0.1";
    // this.imageName =
    //   process.env.WORKER_IMAGE_NAME || "lawrencecchen/cmux:0.2.16";
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
    } catch (error) {
      // Image doesn't exist locally, try to pull it
      dockerLogger.info(
        `Image ${this.imageName} not found locally, pulling...`
      );

      try {
        const stream = await docker.pull(this.imageName);

        // Wait for pull to complete
        await new Promise((resolve, reject) => {
          docker.modem.followProgress(
            stream,
            (err: Error | null, res: any[]) => {
              if (err) {
                reject(err);
              } else {
                resolve(res);
              }
            },
            (event: any) => {
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
   * @param containerPort The port inside the container (e.g., "39378", "39377", "39376")
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
      if (ports["39378/tcp"]?.[0]?.HostPort) {
        portMapping["39378"] = ports["39378/tcp"][0].HostPort;
      }
      if (ports["39377/tcp"]?.[0]?.HostPort) {
        portMapping["39377"] = ports["39377/tcp"][0].HostPort;
      }
      if (ports["39376/tcp"]?.[0]?.HostPort) {
        portMapping["39376"] = ports["39376/tcp"][0].HostPort;
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

    // Set initial mapping status
    containerMappings.set(this.containerName, {
      containerName: this.containerName,
      instanceId: this.instanceId,
      ports: { vscode: "", worker: "" },
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
    const createOptions: Docker.ContainerCreateOptions = {
      name: this.containerName,
      Image: this.imageName,
      Env: envVars,
      HostConfig: {
        AutoRemove: true,
        Privileged: true,
        PortBindings: {
          "39378/tcp": [{ HostPort: "0" }], // VS Code port
          "39377/tcp": [{ HostPort: "0" }], // Worker port
          "39376/tcp": [{ HostPort: "0" }], // Extension socket port
        },
      },
      ExposedPorts: {
        "39378/tcp": {},
        "39377/tcp": {},
        "39376/tcp": {},
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

        const binds = [
          `${this.config.workspacePath}:/root/workspace`,
          // Mount the origin directory at the same absolute path to preserve git references
          `${originPath}:${originPath}:rw`, // Read-write mount for git operations
        ];

        // Mount SSH directory for git authentication
        const sshDir = path.join(homeDir, ".ssh");
        try {
          const fs = await import("fs");
          await fs.promises.access(sshDir);
          binds.push(`${sshDir}:/root/.ssh:ro`);
          dockerLogger.info(`  SSH mount: ${sshDir} -> /root/.ssh (read-only)`);
        } catch {
          dockerLogger.info(`  No SSH directory found at ${sshDir}`);
        }

        // Mount GitHub CLI config for authentication
        const ghConfigDir = path.join(homeDir, ".config", "gh");
        try {
          const fs = await import("fs");
          await fs.promises.access(ghConfigDir);
          binds.push(`${ghConfigDir}:/root/.config/gh:ro`);
          dockerLogger.info(
            `  GitHub CLI config mount: ${ghConfigDir} -> /root/.config/gh (read-only)`
          );
        } catch {
          dockerLogger.info(`  No GitHub CLI config found at ${ghConfigDir}`);
        }

        // Mount git config if it exists
        try {
          const fs = await import("fs");
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

        // Mount VS Code settings if they exist
        const cmuxDir = path.join(homeDir, ".cmux");
        const vscodeSettingsDir = path.join(cmuxDir, "vscode-settings");
        try {
          const fs = await import("fs");
          await fs.promises.access(vscodeSettingsDir);
          
          // Mount settings files
          const settingsPath = path.join(vscodeSettingsDir, "settings.json");
          if (await fs.promises.access(settingsPath).then(() => true).catch(() => false)) {
            binds.push(`${settingsPath}:/root/.vscode-server/data/Machine/settings.json:ro`);
            dockerLogger.info(`  VS Code settings mount: ${settingsPath} -> /root/.vscode-server/data/Machine/settings.json`);
          }
          
          const keybindingsPath = path.join(vscodeSettingsDir, "keybindings.json");
          if (await fs.promises.access(keybindingsPath).then(() => true).catch(() => false)) {
            binds.push(`${keybindingsPath}:/root/.vscode-server/data/Machine/keybindings.json:ro`);
            dockerLogger.info(`  VS Code keybindings mount: ${keybindingsPath} -> /root/.vscode-server/data/Machine/keybindings.json`);
          }
          
          const snippetsDir = path.join(vscodeSettingsDir, "snippets");
          if (await fs.promises.access(snippetsDir).then(() => true).catch(() => false)) {
            binds.push(`${snippetsDir}:/root/.vscode-server/data/Machine/snippets:ro`);
            dockerLogger.info(`  VS Code snippets mount: ${snippetsDir} -> /root/.vscode-server/data/Machine/snippets`);
          }
          
          // Create and mount extension install script
          const tempDir = path.join(os.tmpdir(), "cmux-extensions");
          await fs.promises.mkdir(tempDir, { recursive: true });
          const scriptPath = path.join(tempDir, `install-extensions-${this.instanceId}.sh`);
          
          if (await createExtensionInstallScript(vscodeSettingsDir, scriptPath)) {
            binds.push(`${scriptPath}:/root/install-extensions.sh:ro`);
            dockerLogger.info(`  Extension install script mount: ${scriptPath} -> /root/install-extensions.sh`);
            
            // Create a post-startup script that will run the extension installer
            const postStartupScript = `#!/bin/bash
# Run extension installer in background after VS Code starts
(
  sleep 10
  if [ -f /root/install-extensions.sh ]; then
    echo "Installing VS Code extensions..." >> /var/log/cmux/extensions.log
    bash /root/install-extensions.sh >> /var/log/cmux/extensions.log 2>&1
    echo "Extension installation complete" >> /var/log/cmux/extensions.log
  fi
) &
`;
            const postStartupPath = path.join(tempDir, `post-startup-${this.instanceId}.sh`);
            await fs.promises.writeFile(postStartupPath, postStartupScript, { mode: 0o755 });
            binds.push(`${postStartupPath}:/root/post-startup.sh:ro`);
            
            // Set environment variable to trigger post-startup script
            createOptions.Env = createOptions.Env || [];
            createOptions.Env.push("RUN_POST_STARTUP=true");
          }
        } catch {
          dockerLogger.info("  No VS Code settings found to mount");
        }

        createOptions.HostConfig!.Binds = binds;

        dockerLogger.info(
          `  Origin mount: ${originPath} -> ${originPath} (read-write)`
        );
      } else {
        // Fallback to just mounting the workspace
        const homeDir = os.homedir();
        const gitConfigPath = path.join(homeDir, ".gitconfig");

        const binds = [`${this.config.workspacePath}:/root/workspace`];

        // Mount SSH directory for git authentication
        const sshDir = path.join(homeDir, ".ssh");
        try {
          const fs = await import("fs");
          await fs.promises.access(sshDir);
          binds.push(`${sshDir}:/root/.ssh:ro`);
          dockerLogger.info(`  SSH mount: ${sshDir} -> /root/.ssh (read-only)`);
        } catch {
          dockerLogger.info(`  No SSH directory found at ${sshDir}`);
        }

        // Mount GitHub CLI config for authentication
        const ghConfigDir = path.join(homeDir, ".config", "gh");
        try {
          const fs = await import("fs");
          await fs.promises.access(ghConfigDir);
          binds.push(`${ghConfigDir}:/root/.config/gh:ro`);
          dockerLogger.info(
            `  GitHub CLI config mount: ${ghConfigDir} -> /root/.config/gh (read-only)`
          );
        } catch {
          dockerLogger.info(`  No GitHub CLI config found at ${ghConfigDir}`);
        }

        // Mount git config if it exists
        try {
          const fs = await import("fs");
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

        // Mount VS Code settings if they exist (same as above)
        const cmuxDir = path.join(homeDir, ".cmux");
        const vscodeSettingsDir = path.join(cmuxDir, "vscode-settings");
        try {
          const fs = await import("fs");
          await fs.promises.access(vscodeSettingsDir);
          
          // Mount settings files
          const settingsPath = path.join(vscodeSettingsDir, "settings.json");
          if (await fs.promises.access(settingsPath).then(() => true).catch(() => false)) {
            binds.push(`${settingsPath}:/root/.vscode-server/data/Machine/settings.json:ro`);
            dockerLogger.info(`  VS Code settings mount: ${settingsPath} -> /root/.vscode-server/data/Machine/settings.json`);
          }
          
          const keybindingsPath = path.join(vscodeSettingsDir, "keybindings.json");
          if (await fs.promises.access(keybindingsPath).then(() => true).catch(() => false)) {
            binds.push(`${keybindingsPath}:/root/.vscode-server/data/Machine/keybindings.json:ro`);
            dockerLogger.info(`  VS Code keybindings mount: ${keybindingsPath} -> /root/.vscode-server/data/Machine/keybindings.json`);
          }
          
          const snippetsDir = path.join(vscodeSettingsDir, "snippets");
          if (await fs.promises.access(snippetsDir).then(() => true).catch(() => false)) {
            binds.push(`${snippetsDir}:/root/.vscode-server/data/Machine/snippets:ro`);
            dockerLogger.info(`  VS Code snippets mount: ${snippetsDir} -> /root/.vscode-server/data/Machine/snippets`);
          }
          
          // Create and mount extension install script
          const tempDir = path.join(os.tmpdir(), "cmux-extensions");
          await fs.promises.mkdir(tempDir, { recursive: true });
          const scriptPath = path.join(tempDir, `install-extensions-${this.instanceId}.sh`);
          
          if (await createExtensionInstallScript(vscodeSettingsDir, scriptPath)) {
            binds.push(`${scriptPath}:/root/install-extensions.sh:ro`);
            dockerLogger.info(`  Extension install script mount: ${scriptPath} -> /root/install-extensions.sh`);
            
            // Create a post-startup script that will run the extension installer
            const postStartupScript = `#!/bin/bash
# Run extension installer in background after VS Code starts
(
  sleep 10
  if [ -f /root/install-extensions.sh ]; then
    echo "Installing VS Code extensions..." >> /var/log/cmux/extensions.log
    bash /root/install-extensions.sh >> /var/log/cmux/extensions.log 2>&1
    echo "Extension installation complete" >> /var/log/cmux/extensions.log
  fi
) &
`;
            const postStartupPath = path.join(tempDir, `post-startup-${this.instanceId}.sh`);
            await fs.promises.writeFile(postStartupPath, postStartupScript, { mode: 0o755 });
            binds.push(`${postStartupPath}:/root/post-startup.sh:ro`);
            
            // Set environment variable to trigger post-startup script
            createOptions.Env = createOptions.Env || [];
            createOptions.Env.push("RUN_POST_STARTUP=true");
          }
        } catch {
          dockerLogger.info("  No VS Code settings found to mount");
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

    // Get container info including port mappings
    const containerInfo = await this.container.inspect();
    const ports = containerInfo.NetworkSettings.Ports;

    const vscodePort = ports["39378/tcp"]?.[0]?.HostPort;
    const workerPort = ports["39377/tcp"]?.[0]?.HostPort;
    const extensionPort = ports["39376/tcp"]?.[0]?.HostPort;

    if (!vscodePort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get VS Code port mapping for port 39378");
    }

    if (!workerPort) {
      dockerLogger.error(`Available ports:`, ports);
      throw new Error("Failed to get worker port mapping for port 39377");
    }

    // Update the container mapping with actual ports
    const mapping = containerMappings.get(this.containerName);
    if (mapping) {
      mapping.ports = {
        vscode: vscodePort,
        worker: workerPort,
        extension: extensionPort,
      };
      mapping.status = "running";
    }

    // Update VSCode ports in Convex
    try {
      await convex.mutation(api.taskRuns.updateVSCodePorts, {
        id: this.taskRunId as Id<"taskRuns">,
        ports: {
          vscode: vscodePort,
          worker: workerPort,
          extension: extensionPort,
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
    const shortId = getShortId(this.taskRunId);
    const proxyBaseUrl = `http://${shortId}.39378.localhost:9776`;
    const proxyWorkspaceUrl = `${proxyBaseUrl}/?folder=/root/workspace`;

    dockerLogger.info(`Docker VSCode instance started:`);
    dockerLogger.info(`  VS Code URL: ${workspaceUrl}`);
    dockerLogger.info(`  Worker URL: ${workerUrl}`);
    dockerLogger.info(`  Proxy URL: ${proxyWorkspaceUrl}`);

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
          // Update mapping status to stopped
          const mapping = containerMappings.get(this.containerName);
          if (mapping) {
            mapping.status = "stopped";
          }

          // Update VSCode status in Convex
          try {
            await convex.mutation(api.taskRuns.updateVSCodeStatus, {
              id: this.taskRunId as Id<"taskRuns">,
              status: "stopped",
              stoppedAt: Date.now(),
            });
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
      await convex.mutation(api.taskRuns.updateVSCodeStatus, {
        id: this.taskRunId as Id<"taskRuns">,
        status: "stopped",
        stoppedAt: Date.now(),
      });
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
      const fs = await import("fs");
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

  getContainerName(): string {
    return this.containerName;
  }

  getPorts(): { vscode?: string; worker?: string; extension?: string } | null {
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
        const fs = await import("fs");
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
    // Stop any existing sync
    if (DockerVSCodeInstance.syncInterval) {
      clearInterval(DockerVSCodeInstance.syncInterval);
    }

    // Run sync immediately
    DockerVSCodeInstance.syncDockerContainerStates().catch((error) => {
      dockerLogger.error("Failed to sync container states:", error);
    });

    // Then run every minute
    DockerVSCodeInstance.syncInterval = setInterval(() => {
      DockerVSCodeInstance.syncDockerContainerStates().catch((error) => {
        dockerLogger.error("Failed to sync container states:", error);
      });
    }, 60000); // 60 seconds
  }

  // Static method to stop the container state sync
  static stopContainerStateSync(): void {
    if (DockerVSCodeInstance.syncInterval) {
      clearInterval(DockerVSCodeInstance.syncInterval);
      DockerVSCodeInstance.syncInterval = null;
    }
  }

  private static async syncDockerContainerStates(): Promise<void> {
    const docker = DockerVSCodeInstance.getDocker();

    try {
      dockerLogger.info("Syncing Docker container states with Convex...");

      // Get all running cmux containers
      const containers = await docker.listContainers({
        all: true,
        filters: {
          name: ["cmux-"],
        },
      });

      // Get all active VSCode instances from Convex
      const activeVSCodeInstances = await convex.query(
        api.taskRuns.getActiveVSCodeInstances
      );

      // Get container settings
      const containerSettings = await convex.query(
        api.containerSettings.getEffective
      );

      // Create a set of existing container names for quick lookup
      const existingContainerNames = new Set(
        containers.map((c) => c.Names[0]?.replace(/^\//, "")).filter(Boolean)
      );

      // Update container mappings and Convex state
      for (const containerInfo of containers) {
        const containerName = containerInfo.Names[0]?.replace(/^\//, "");
        if (!containerName) continue;

        // Extract task run ID from container name
        // Container name format: cmux-<shortId>
        const match = containerName.match(/^cmux-(.{12})/);
        if (!match) continue;

        // Find the full taskRunId from container mappings
        const mapping = containerMappings.get(containerName);
        if (!mapping) {
          continue;
        }

        // Get the taskRunId from the mapping
        // The instanceId is the same as taskRunId
        const taskRunId = mapping.instanceId;

        const isRunning = containerInfo.State === "running";
        const ports = containerInfo.Ports || [];

        // Extract port mappings
        const vscodePort = ports
          .find((p) => p.PrivatePort === 39378)
          ?.PublicPort?.toString();
        const workerPort = ports
          .find((p) => p.PrivatePort === 39377)
          ?.PublicPort?.toString();
        const extensionPort = ports
          .find((p) => p.PrivatePort === 39376)
          ?.PublicPort?.toString();

        // Update local mapping
        mapping.status = isRunning ? "running" : "stopped";
        if (vscodePort && workerPort) {
          mapping.ports = {
            vscode: vscodePort,
            worker: workerPort,
            extension: extensionPort,
          };
        }

        // Update Convex state
        try {
          if (isRunning) {
            // Update status to running with ports if available
            if (vscodePort && workerPort) {
              await convex.mutation(api.taskRuns.updateVSCodePorts, {
                id: taskRunId as Id<"taskRuns">,
                ports: {
                  vscode: vscodePort,
                  worker: workerPort,
                  extension: extensionPort,
                },
              });
            }
            await convex.mutation(api.taskRuns.updateVSCodeStatus, {
              id: taskRunId as Id<"taskRuns">,
              status: "running",
            });
          } else {
            // Update status to stopped
            await convex.mutation(api.taskRuns.updateVSCodeStatus, {
              id: taskRunId as Id<"taskRuns">,
              status: "stopped",
              stoppedAt: Date.now(),
            });
          }
        } catch (error) {
          dockerLogger.error(
            `[syncDockerContainerStates] Failed to update Convex state for container ${containerName}:`,
            error
          );
        }
      }

      // Check for containers in our mappings that are no longer in Docker
      for (const [containerName, mapping] of containerMappings.entries()) {
        const exists = containers.some(
          (c) => c.Names[0]?.replace(/^\//, "") === containerName
        );
        if (!exists && mapping.status !== "stopped") {
          // Container no longer exists, mark as stopped
          mapping.status = "stopped";

          try {
            const taskRunId = mapping.instanceId; // instanceId is the taskRunId
            await convex.mutation(api.taskRuns.updateVSCodeStatus, {
              id: taskRunId as Id<"taskRuns">,
              status: "stopped",
              stoppedAt: Date.now(),
            });
          } catch (error) {
            dockerLogger.error(
              `[syncDockerContainerStates] Failed to update stopped status for ${containerName}:`,
              error
            );
          }
        }
      }

      // Check for VSCode instances in Convex that don't have corresponding Docker containers
      for (const taskRun of activeVSCodeInstances) {
        if (!taskRun.vscode || taskRun.vscode.provider !== "docker") {
          continue; // Skip non-docker providers
        }

        // Derive the container name from the task run ID
        const shortId = getShortId(taskRun._id);
        const expectedContainerName = `cmux-${shortId}`;

        // Check if this container exists in Docker
        if (!existingContainerNames.has(expectedContainerName)) {
          dockerLogger.info(
            `[syncDockerContainerStates] Found orphaned VSCode instance in Convex: ${taskRun._id} (container: ${expectedContainerName})`
          );

          // Mark it as stopped in Convex
          try {
            await convex.mutation(api.taskRuns.updateVSCodeStatus, {
              id: taskRun._id,
              status: "stopped",
              stoppedAt: Date.now(),
            });
            dockerLogger.info(
              `[syncDockerContainerStates] Marked orphaned VSCode instance ${taskRun._id} as stopped`
            );
          } catch (error) {
            dockerLogger.error(
              `[syncDockerContainerStates] Failed to update orphaned VSCode instance ${taskRun._id}:`,
              error
            );
          }
        }
      }

      // Now handle container cleanup based on settings
      if (containerSettings.autoCleanupEnabled) {
        await DockerVSCodeInstance.performContainerCleanup(containerSettings);
      }
    } catch (error) {
      dockerLogger.error(
        "[syncDockerContainerStates] Error syncing container states:",
        error
      );
    }
  }

  private static async performContainerCleanup(settings: {
    maxRunningContainers: number;
    reviewPeriodMinutes: number;
    autoCleanupEnabled: boolean;
  }): Promise<void> {
    try {
      dockerLogger.info(
        "[performContainerCleanup] Starting container cleanup..."
      );

      // 1. Check for containers that have exceeded their TTL
      const containersToStop = await convex.query(
        api.taskRuns.getContainersToStop
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
      const containerPriority = await convex.query(
        api.taskRuns.getRunningContainersByCleanupPriority
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
