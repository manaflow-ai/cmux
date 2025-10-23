import {
  SERVER_TERMINAL_CONFIG,
  WorkerConfigureGitSchema,
  WorkerCreateTerminalSchema,
  WorkerExecSchema,
  WorkerStartScreenshotCollectionSchema,
  type ClientToServerEvents,
  type InterServerEvents,
  type ServerToClientEvents,
  type ServerToWorkerEvents,
  type SocketData,
  type WorkerHeartbeat,
  type WorkerRegister,
  type WorkerStartScreenshotCollection,
  type WorkerTaskRunContext,
  type WorkerToServerEventNames,
  type WorkerToServerEvents,
} from "@cmux/shared";
import { AGENT_CONFIGS } from "@cmux/shared/agentConfig";
import type { Id } from "@cmux/convex/dataModel";

import { getWorkerServerSocketOptions } from "@cmux/shared/node/socket";
import { startAmpProxy } from "@cmux/shared/src/providers/amp/start-amp-proxy.ts";
import { handleWorkerTaskCompletion } from "./crown/workflow";
import { SerializeAddon } from "@xterm/addon-serialize";
import * as xtermHeadless from "@xterm/headless";
import express from "express";
import multer from "multer";
import {
  exec,
  spawn,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { promises as fs } from "node:fs";
import { createServer } from "node:http";
import { cpus, platform, totalmem } from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { Server, type Namespace, type Socket } from "socket.io";
import { checkDockerReadiness } from "./checkDockerReadiness";
import { detectTerminalIdle } from "./detectTerminalIdle";
import { runWorkerExec } from "./execRunner";
import { FileWatcher, computeGitDiff, getFileWithDiff } from "./fileWatcher";
import { log } from "./logger";
import { startScreenshotCollection } from "./screenshotCollector/startScreenshotCollection";

const execAsync = promisify(exec);

const Terminal = xtermHeadless.Terminal;

// Configuration
const WORKER_ID = process.env.WORKER_ID || `worker-${Date.now()}`;
const WORKER_PORT = parseInt(process.env.WORKER_PORT || "39377", 10);
const CONTAINER_IMAGE = process.env.CONTAINER_IMAGE || "cmux-worker";
const CONTAINER_VERSION = process.env.CONTAINER_VERSION || "0.0.1";

// Create Express app
const app = express();

// Health check endpoint
app.get("/health", (_req, res) => {
  res.json({
    status: "healthy",
    workerId: WORKER_ID,
    uptime: process.uptime(),
    mainServerConnected: !!mainServerSocket && mainServerSocket.connected,
    pendingEventsCount: pendingEvents.length,
    pendingEvents: pendingEvents.map((pendingEvent) => {
      const payload = pendingEvent.args[0];
      return {
        event: pendingEvent.event,
        age: Date.now() - pendingEvent.timestamp,
        taskId: payload && hasTaskId(payload) ? payload.taskId : undefined,
        taskRunId:
          payload && hasTaskRunId(payload) ? payload.taskRunId : undefined,
      };
    }),
  });
});

// Configure multer for file uploads
const upload = multer({
  limits: { fileSize: 100 * 1024 * 1024 }, // 100MB limit
  storage: multer.memoryStorage(),
});

// File upload endpoint
app.post("/upload-image", upload.single("image"), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: "No file uploaded" });
    }

    const { path: imagePath } = req.body;
    if (!imagePath) {
      return res.status(400).json({ error: "No path specified" });
    }

    log("INFO", `Received image upload request for path: ${imagePath}`, {
      size: req.file.size,
      mimetype: req.file.mimetype,
      originalname: req.file.originalname,
    });

    // Ensure directory exists
    const dir = path.dirname(imagePath);
    await fs.mkdir(dir, { recursive: true });

    // Write the file
    await fs.writeFile(imagePath, req.file.buffer);

    log("INFO", `Successfully wrote image file: ${imagePath}`);

    // Verify file was created
    const stats = await fs.stat(imagePath);

    res.json({
      success: true,
      path: imagePath,
      size: stats.size,
    });
  } catch (error) {
    log("ERROR", "Failed to upload image", error);
    res.status(500).json({
      error: error instanceof Error ? error.message : "Upload failed",
    });
  }
});

// Create HTTP server with Express app
const httpServer = createServer(app);

// Socket.IO server with namespaces
const io = new Server(httpServer, getWorkerServerSocketOptions());

// Client namespace
const vscodeIO = io.of("/vscode") as Namespace<
  ClientToServerEvents,
  ServerToClientEvents,
  InterServerEvents,
  SocketData
>;

// Management namespace
const managementIO = io.of("/management") as Namespace<
  ServerToWorkerEvents,
  WorkerToServerEvents
>;

// Track connected main server
let mainServerSocket: Socket<
  ServerToWorkerEvents,
  WorkerToServerEvents
> | null = null;

// Track active file watchers by taskRunId
const activeFileWatchers: Map<string, FileWatcher> = new Map();

// Queue for pending events when mainServerSocket is not connected
interface PendingEvent<
  K extends WorkerToServerEventNames = WorkerToServerEventNames,
> {
  event: K;
  args: Parameters<WorkerToServerEvents[K]>;
  timestamp: number;
}

const hasTaskId = (value: unknown): value is { taskId?: Id<"tasks"> } =>
  typeof value === "object" && value !== null && "taskId" in value;

const hasTaskRunId = (
  value: unknown
): value is { taskRunId?: Id<"taskRuns"> } =>
  typeof value === "object" && value !== null && "taskRunId" in value;

const pendingEvents: PendingEvent[] = [];

/**
 * Emit an event to the main server, queuing it if not connected
 */
function emitToMainServer<K extends WorkerToServerEventNames>(
  event: K,
  ...args: Parameters<WorkerToServerEvents[K]>
) {
  const [payload] = args;

  if (mainServerSocket && mainServerSocket.connected) {
    log("DEBUG", `Emitting ${event} to main server`, { event, data: payload });
    mainServerSocket.emit(event, ...args);
  } else {
    log("WARNING", `Main server not connected, queuing ${event} event`, {
      event,
      data: payload,
      pendingEventsCount: pendingEvents.length + 1,
    });
    pendingEvents.push({
      event,
      args,
      timestamp: Date.now(),
    });
  }
}

/**
 * Send all pending events to the main server
 */
function sendPendingEvents() {
  if (!mainServerSocket || !mainServerSocket.connected) {
    log("WARNING", "Cannot send pending events - main server not connected");
    return;
  }

  if (pendingEvents.length === 0) {
    return;
  }

  const socket = mainServerSocket;

  log("INFO", `Sending ${pendingEvents.length} pending events to main server`);

  const eventsToSend = [...pendingEvents];
  pendingEvents.length = 0; // Clear the queue

  for (const pendingEvent of eventsToSend) {
    const age = Date.now() - pendingEvent.timestamp;
    const payload = pendingEvent.args[0];
    log(
      "DEBUG",
      `Sending pending ${pendingEvent.event} event (age: ${age}ms)`,
      {
        event: pendingEvent.event,
        data: payload,
        age,
      }
    );
    socket.emit(pendingEvent.event, ...pendingEvent.args);
  }
}

/**
 * Sanitize a string to be used as a tmux session name.
 * Tmux session names cannot contain: periods (.), colons (:), spaces, or other special characters.
 * We'll replace them with underscores to ensure compatibility.
 */
function sanitizeTmuxSessionName(name: string): string {
  // Replace all invalid characters with underscores
  // Allow only alphanumeric characters, hyphens, and underscores
  return name.replace(/[^a-zA-Z0-9_-]/g, "_");
}

// Worker statistics
function getWorkerStats(): WorkerHeartbeat {
  const totalMem = totalmem();
  const usedMem = process.memoryUsage().heapUsed;

  return {
    workerId: WORKER_ID,
    timestamp: Date.now(),
    stats: {
      cpuUsage: 0, // TODO: Implement actual CPU usage tracking
      memoryUsage: (usedMem / totalMem) * 100,
    },
  };
}

// Send registration info when main server connects
function registerWithMainServer(
  socket: Socket<ServerToWorkerEvents, WorkerToServerEvents>
) {
  const registration: WorkerRegister = {
    workerId: WORKER_ID,
    capabilities: {
      maxConcurrentTerminals: 50, // Reduced from 50 to prevent resource exhaustion
      supportedLanguages: ["javascript", "typescript", "python", "go", "rust"],
      gpuAvailable: false,
      memoryMB: Math.floor(totalmem() / 1024 / 1024),
      cpuCores: cpus().length,
    },
    containerInfo: {
      image: CONTAINER_IMAGE,
      version: CONTAINER_VERSION,
      platform: platform(),
    },
  };

  socket.emit("worker:register", registration);
  log(
    "INFO",
    `Worker ${WORKER_ID} sent registration to main server`,
    registration
  );
}

// Management socket server (main server connects to this)
managementIO.on("connection", (socket) => {
  log(
    "INFO",
    `Main server connected to worker ${WORKER_ID}`,
    {
      from: socket.handshake.headers.referer || "unknown",
      socketId: socket.id,
    },
    WORKER_ID
  );
  mainServerSocket = socket;

  // Send registration immediately
  registerWithMainServer(socket);

  // Send any pending events
  sendPendingEvents();

  // Handle terminal operations from main server
  socket.on("worker:create-terminal", async (data, callback) => {
    log(
      "INFO",
      "Management namespace: Received request to create terminal from main server",
      JSON.stringify(
        data,
        (_key, value) => {
          if (typeof value === "string" && value.length > 1000) {
            return value.slice(0, 1000) + "...";
          }
          return value;
        },
        2
      ),
      WORKER_ID
    );
    try {
      const validated = WorkerCreateTerminalSchema.parse(data);
      log("INFO", "worker:create-terminal validated", validated);

      // Handle auth files first if provided
      if (validated.authFiles && validated.authFiles.length > 0) {
        log(
          "INFO",
          `Writing ${validated.authFiles.length} auth files...`,
          undefined,
          WORKER_ID
        );
        for (const file of validated.authFiles) {
          try {
            // Expand $HOME in destination path
            const destPath = file.destinationPath.replace(
              "$HOME",
              process.env.HOME || "/root"
            );
            log(
              "INFO",
              `Writing auth file to: ${destPath}`,
              undefined,
              WORKER_ID
            );

            // Ensure directory exists
            const dir = path.dirname(destPath);
            await fs.mkdir(dir, { recursive: true });

            // Write the file
            await fs.writeFile(
              destPath,
              Buffer.from(file.contentBase64, "base64")
            );

            // Set permissions if specified
            if (file.mode) {
              await fs.chmod(destPath, parseInt(file.mode, 8));
            }

            log(
              "INFO",
              `Successfully wrote auth file: ${destPath}`,
              undefined,
              WORKER_ID
            );
          } catch (error) {
            log(
              "ERROR",
              `Failed to write auth file ${file.destinationPath}:`,
              error,
              WORKER_ID
            );
          }
        }
      }

      log(
        "INFO",
        "Creating terminal with options",
        {
          terminalId: validated.terminalId,
          cols: validated.cols,
          rows: validated.rows,
          cwd: validated.cwd,
          env: Object.keys(validated.env || {}),
          // env: validated.env,
          command: validated.command,
          args: validated.args,
          taskRunId: validated.taskRunId,
        },
        WORKER_ID
      );

      await createTerminal(validated.terminalId, {
        cols: validated.cols,
        rows: validated.rows,
        cwd: validated.cwd,
        env: validated.env,
        command: validated.command,
        args: validated.args,
        taskRunId: validated.taskRunId,
        agentModel: validated.agentModel,
        startupCommands: validated.startupCommands,
        taskRunContext: validated.taskRunContext,
      });

      callback({
        error: null,
        data: {
          workerId: WORKER_ID,
          terminalId: validated.terminalId,
        },
      });
      socket.emit("worker:terminal-created", {
        workerId: WORKER_ID,
        terminalId: validated.terminalId,
      });
    } catch (error) {
      log(
        "ERROR",
        "Error creating terminal from main server",
        error,
        WORKER_ID
      );
      callback({
        error: error instanceof Error ? error : new Error(error as string),
        data: null,
      });
      socket.emit("worker:error", {
        workerId: WORKER_ID,
        error: error instanceof Error ? error.message : "Unknown error",
      });
    }
  });

  socket.on("worker:check-docker", async (callback) => {
    console.log(`Worker ${WORKER_ID} checking Docker readiness`);

    try {
      // Check if Docker socket is accessible
      const dockerReady = await checkDockerReadiness();

      callback({
        ready: dockerReady,
        message: dockerReady ? "Docker is ready" : "Docker is not ready",
      });
    } catch (error) {
      callback({
        ready: false,
        message: `Error checking Docker: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
      });
    }
  });

  socket.on(
    "worker:start-screenshot-collection",
    async (rawData: WorkerStartScreenshotCollection | undefined) => {
      log(
        "INFO",
        `Worker ${WORKER_ID} received request to start screenshot collection`,
        undefined,
        WORKER_ID
      );
      let config: WorkerStartScreenshotCollection | null = null;
      if (rawData) {
        try {
          config = WorkerStartScreenshotCollectionSchema.parse(rawData);
        } catch (validationError) {
          log(
            "ERROR",
            "Invalid screenshot collection payload",
            {
              error:
                validationError instanceof Error
                  ? validationError.message
                  : String(validationError),
            },
            WORKER_ID
          );
        }
      }
      try {
        await startScreenshotCollection({
          openAiApiKey: config?.openAiApiKey,
        });
      } catch (error) {
        log(
          "ERROR",
          "Failed to start screenshot collection",
          {
            error: error instanceof Error ? error.message : String(error),
          },
          WORKER_ID
        );
      }
    }
  );

  socket.on("worker:configure-git", async (data) => {
    try {
      const validated = WorkerConfigureGitSchema.parse(data);
      console.log(`Worker ${WORKER_ID} configuring git...`);

      const credentialStorePath = "/root/.git-credentials";
      const normalizeCredentialHelper = (helper: string): string | null => {
        const trimmed = helper.trim();
        if (trimmed.includes("/opt/homebrew/bin/gh")) {
          return "!gh auth git-credential";
        }
        if (
          trimmed.includes("osxkeychain") ||
          trimmed.includes("wincred") ||
          trimmed.includes("manager-core")
        ) {
          return null;
        }
        return trimmed.length > 0 ? trimmed : null;
      };

      // Create a custom git config file that includes the mounted one
      const customGitConfigPath = "/root/.gitconfig.custom";

      // Parse existing config into sections
      const configSections: Map<string, Map<string, string>> = new Map();

      // Start by parsing the mounted config if it exists
      try {
        const { stdout: mountedConfig } = await execAsync(
          "cat /root/.gitconfig 2>/dev/null || true"
        );
        if (mountedConfig) {
          let currentSection = "global";
          const lines = mountedConfig.split("\n");

          for (const line of lines) {
            const trimmedLine = line.trim();
            if (!trimmedLine || trimmedLine.startsWith("#")) continue;

            // Check for section header
            const sectionMatch = trimmedLine.match(/^\[(.+)\]$/);
            if (sectionMatch) {
              currentSection = sectionMatch[1] || "global";
              if (!configSections.has(currentSection)) {
                configSections.set(currentSection, new Map());
              }
              continue;
            }

            // Parse key-value pairs
            const keyValueMatch = line.match(/^\s*(\w+)\s*=\s*(.+)$/);
            if (keyValueMatch) {
              const [, key, value] = keyValueMatch;
              if (key && value) {
                if (!configSections.has(currentSection)) {
                  configSections.set(currentSection, new Map());
                }
                configSections.get(currentSection)?.set(key, value);
              }
            }
          }
        }
      } catch {
        // No mounted config
      }

      for (const [section, settings] of configSections) {
        if (!section.startsWith("credential")) {
          continue;
        }
        const helperValue = settings.get("helper");
        if (!helperValue) {
          continue;
        }
        const normalized = normalizeCredentialHelper(helperValue);
        if (normalized) {
          settings.set("helper", normalized);
        } else {
          settings.delete("helper");
          if (settings.size === 0) {
            configSections.delete(section);
          }
        }
      }

      // Create .git-credentials file if GitHub token is provided
      if (validated.githubToken) {
        if (!configSections.has("credential")) {
          configSections.set("credential", new Map());
        }
        configSections
          .get("credential")
          ?.set("helper", `store --file ${credentialStorePath}`);

        const credentialsContent = `https://oauth:${validated.githubToken}@github.com\n`;
        await fs.writeFile(credentialStorePath, credentialsContent);
        await fs.chmod(credentialStorePath, 0o600);
        console.log("GitHub credentials stored in .git-credentials");
      } else {
        const credentialSection = configSections.get("credential");
        if (credentialSection?.get("helper")) {
          credentialSection.delete("helper");
        }
        if (credentialSection && credentialSection.size === 0) {
          configSections.delete("credential");
        }
      }

      // Add additional git settings if provided
      if (validated.gitConfig) {
        for (const [key, value] of Object.entries(validated.gitConfig)) {
          const [section, ...keyParts] = key.split(".");
          const configKey = keyParts.join(".");

          if (section && configKey) {
            if (!configSections.has(section)) {
              configSections.set(section, new Map());
            }
            configSections.get(section)?.set(configKey, value);
          }
        }
      }

      // Build the final config content
      let gitConfigContent = "";
      for (const [section, settings] of configSections) {
        if (section !== "global") {
          gitConfigContent += `[${section}]\n`;
          for (const [key, value] of settings) {
            gitConfigContent += `\t${key} = ${value}\n`;
          }
          gitConfigContent += "\n";
        }
      }

      // Write the custom config
      await fs.writeFile(customGitConfigPath, gitConfigContent);

      // Set GIT_CONFIG environment variable to use our custom config
      process.env.GIT_CONFIG_GLOBAL = customGitConfigPath;

      // Also set it for all terminals
      await execAsync(
        `echo 'export GIT_CONFIG_GLOBAL=${customGitConfigPath}' >> /etc/profile`
      );
      await execAsync(
        `echo 'export GIT_CONFIG_GLOBAL=${customGitConfigPath}' >> /root/.bashrc`
      );

      // Set up SSH keys if provided
      if (validated.sshKeys) {
        // Check if .ssh is mounted (read-only)
        const sshDir = "/root/.ssh";
        let sshDirWritable = true;

        try {
          // Try to create a test file
          await fs.writeFile(path.join(sshDir, ".test"), "test");
          // If successful, remove it
          await execAsync(`rm -f ${path.join(sshDir, ".test")}`);
        } catch {
          // SSH dir is read-only, use alternative location
          sshDirWritable = false;
          console.log(
            ".ssh directory is mounted read-only, using alternative SSH config"
          );
        }

        if (!sshDirWritable) {
          // Use alternative SSH directory
          const altSshDir = "/root/.ssh-custom";
          await fs.mkdir(altSshDir, { recursive: true });

          if (validated.sshKeys.privateKey) {
            const privateKeyPath = path.join(altSshDir, "id_rsa");
            await fs.writeFile(
              privateKeyPath,
              Buffer.from(validated.sshKeys.privateKey, "base64")
            );
            await fs.chmod(privateKeyPath, 0o600);
          }

          if (validated.sshKeys.publicKey) {
            const publicKeyPath = path.join(altSshDir, "id_rsa.pub");
            await fs.writeFile(
              publicKeyPath,
              Buffer.from(validated.sshKeys.publicKey, "base64")
            );
            await fs.chmod(publicKeyPath, 0o644);
          }

          if (validated.sshKeys.knownHosts) {
            const knownHostsPath = path.join(altSshDir, "known_hosts");
            await fs.writeFile(
              knownHostsPath,
              Buffer.from(validated.sshKeys.knownHosts, "base64")
            );
            await fs.chmod(knownHostsPath, 0o644);
          }

          // Create SSH config to use our custom directory
          const sshConfigContent = `Host *
  IdentityFile ${altSshDir}/id_rsa
  UserKnownHostsFile ${altSshDir}/known_hosts
  StrictHostKeyChecking accept-new
`;
          await fs.writeFile("/root/.ssh-config", sshConfigContent);

          // Set GIT_SSH_COMMAND to use our custom config
          process.env.GIT_SSH_COMMAND = "ssh -F /root/.ssh-config";

          // Also export it for all terminals
          await execAsync(
            `echo 'export GIT_SSH_COMMAND="ssh -F /root/.ssh-config"' >> /etc/profile`
          );
          await execAsync(
            `echo 'export GIT_SSH_COMMAND="ssh -F /root/.ssh-config"' >> /root/.bashrc`
          );
        } else {
          // SSH dir is writable, use it normally
          if (validated.sshKeys.privateKey) {
            const privateKeyPath = path.join(sshDir, "id_rsa");
            await fs.writeFile(
              privateKeyPath,
              Buffer.from(validated.sshKeys.privateKey, "base64")
            );
            await fs.chmod(privateKeyPath, 0o600);
          }

          if (validated.sshKeys.publicKey) {
            const publicKeyPath = path.join(sshDir, "id_rsa.pub");
            await fs.writeFile(
              publicKeyPath,
              Buffer.from(validated.sshKeys.publicKey, "base64")
            );
            await fs.chmod(publicKeyPath, 0o644);
          }

          if (validated.sshKeys.knownHosts) {
            const knownHostsPath = path.join(sshDir, "known_hosts");
            await fs.writeFile(
              knownHostsPath,
              Buffer.from(validated.sshKeys.knownHosts, "base64")
            );
            await fs.chmod(knownHostsPath, 0o644);
          }
        }
      }

      console.log(`Worker ${WORKER_ID} git configuration complete`);
    } catch (error) {
      console.error("Error configuring git:", error);
      socket.emit("worker:error", {
        workerId: WORKER_ID,
        error:
          error instanceof Error ? error.message : "Failed to configure git",
      });
    }
  });

  socket.on("worker:exec", async (data, callback) => {
    try {
      const validated = WorkerExecSchema.parse(data);
      log("INFO", `Worker ${WORKER_ID} executing command:`, {
        command: validated.command,
        args: validated.args,
        cwd: validated.cwd,
      });

      const result = await runWorkerExec(validated);

      const logLevel = result.exitCode === 0 ? "INFO" : "WARN";
      log(logLevel, `worker:exec completed: ${validated.command}`, {
        exitCode: result.exitCode,
        stdout: result.stdout.slice(0, 200),
        stderr: result.stderr.slice(0, 200),
      });

      callback({
        error: null,
        data: result,
      });
    } catch (error) {
      log("ERROR", "Error executing command", error, WORKER_ID);
      callback({
        error: error instanceof Error ? error : new Error(String(error)),
        data: null,
      });
    }
  });

  socket.on("worker:shutdown", () => {
    console.log(`Worker ${WORKER_ID} received shutdown command`);
    gracefulShutdown();
  });

  // Handle file watcher start request
  socket.on("worker:start-file-watch", async (data) => {
    const { taskRunId, worktreePath } = data;

    if (!taskRunId || !worktreePath) {
      log("ERROR", "Missing taskRunId or worktreePath for file watch");
      return;
    }

    // Stop existing watcher if any
    const existingWatcher = activeFileWatchers.get(taskRunId);
    if (existingWatcher) {
      existingWatcher.stop();
      activeFileWatchers.delete(taskRunId);
    }

    // Create new file watcher
    const watcher = new FileWatcher({
      watchPath: worktreePath,
      taskRunId,
      debounceMs: 2000, // 2 second debounce
      gitIgnore: true,
      onFileChange: async (changes) => {
        log("INFO", `[Worker] File changes detected for task ${taskRunId}:`, {
          changeCount: changes.length,
          taskRunId,
        });

        // Compute git diff for changed files
        const changedFiles = changes.map((c) => c.path);
        const gitDiff = await computeGitDiff(worktreePath, changedFiles);

        // Get detailed diffs for each file
        const fileDiffs = [];
        for (const change of changes) {
          const diff = await getFileWithDiff(change.path, worktreePath);
          fileDiffs.push({
            path: change.path,
            type: change.type,
            ...diff,
          });
        }

        // Emit file changes to main server
        emitToMainServer("worker:file-changes", {
          workerId: WORKER_ID,
          taskRunId,
          changes,
          gitDiff,
          fileDiffs,
          timestamp: Date.now(),
        });
      },
    });

    // Start watching
    await watcher.start();
    activeFileWatchers.set(taskRunId, watcher);

    log(
      "INFO",
      `[Worker] Started file watcher for task ${taskRunId} at ${worktreePath}`
    );
  });

  // Handle file watcher stop request
  socket.on("worker:stop-file-watch", (data) => {
    const { taskRunId } = data;

    const watcher = activeFileWatchers.get(taskRunId);
    if (watcher) {
      watcher.stop();
      activeFileWatchers.delete(taskRunId);
      log("INFO", `[Worker] Stopped file watcher for task ${taskRunId}`);
    }
  });

  socket.on("disconnect", (reason) => {
    log("WARNING", `Main server disconnected from worker ${WORKER_ID}`, {
      reason,
    });
    mainServerSocket = null;

    // Log if we have pending events that need to be sent
    if (pendingEvents.length > 0) {
      log(
        "WARNING",
        `Main server disconnected with ${pendingEvents.length} pending events`,
        {
          pendingEvents: pendingEvents.map((e) => ({
            event: e.event,
            age: Date.now() - e.timestamp,
          })),
          disconnectReason: reason,
        }
      );
    }
  });
});

// Client socket server
vscodeIO.on("connection", (socket) => {
  console.log(
    `VSCode connected to worker ${WORKER_ID}:`,
    socket.id,
    "from",
    socket.handshake.headers.referer || "unknown"
  );

  socket.on("disconnect", () => {
    console.log(`Client disconnected from worker ${WORKER_ID}:`, socket.id);
  });
});

// Create terminal helper function
async function createTerminal(
  terminalId: string,
  options: {
    cols?: number;
    rows?: number;
    cwd?: string;
    env?: Record<string, string>;
    command?: string;
    args?: string[];
    taskRunId?: Id<"taskRuns">;
    agentModel?: string;
    startupCommands?: string[];
    taskRunContext: WorkerTaskRunContext;
  }
): Promise<void> {
  const {
    cols = SERVER_TERMINAL_CONFIG.cols,
    rows = SERVER_TERMINAL_CONFIG.rows,
    cwd = process.env.HOME || "/",
    env = {},
    command,
    args = [],
    startupCommands = [],
    taskRunContext,
  } = options;

  const taskRunToken = taskRunContext.taskRunToken;
  const convexUrl = taskRunContext.convexUrl;
  const promptValue = taskRunContext.prompt;

  if (!taskRunToken) {
    log("ERROR", "[createTerminal] Missing CMUX task run token in context", {
      terminalId,
      taskRunId: options.taskRunId,
    });
  }

  if (!convexUrl) {
    log("ERROR", "[createTerminal] Missing Convex URL in task run context", {
      terminalId,
      taskRunId: options.taskRunId,
    });
  }

  const shell = command || (platform() === "win32" ? "powershell.exe" : "bash");

  log("INFO", `[createTerminal] Creating terminal ${terminalId}:`, {
    cols,
    rows,
    cwd,
    command,
    args,
    envKeys: Object.keys(env),
    shell,
  });

  // Prepare the spawn command and args
  let spawnCommand: string;
  let spawnArgs: string[];

  if (command === "tmux") {
    // Direct tmux command from agent spawner
    spawnCommand = command;
    spawnArgs = args;
    log("INFO", `[createTerminal] Using direct tmux command:`, {
      spawnCommand,
      spawnArgs,
    });
  } else {
    // Create tmux session with command
    spawnCommand = "tmux";
    spawnArgs = [
      "new-session",
      "-A",
      "-s",
      sanitizeTmuxSessionName(terminalId),
    ];
    spawnArgs.push("-x", cols.toString(), "-y", rows.toString());

    if (command) {
      spawnArgs.push(command);
      if (args.length > 0) {
        spawnArgs.push(...args);
      }
    } else {
      spawnArgs.push(shell);
    }
    log("INFO", `[createTerminal] Creating tmux session:`, {
      spawnCommand,
      spawnArgs,
    });
  }

  const inheritedEnvEntries = Object.entries(process.env).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string"
  );
  const inheritedEnv: Record<string, string> =
    Object.fromEntries(inheritedEnvEntries);

  if (!Object.prototype.hasOwnProperty.call(env, "NODE_ENV")) {
    delete inheritedEnv.NODE_ENV;
  }

  const ptyEnv: Record<string, string> = {
    ...inheritedEnv,
    ...env, // Override with provided env vars
    WORKER_ID,
    TERM: "xterm-256color",
    PS1: "\\u@\\h:\\w\\$ ", // Basic prompt
    SHELL: "/bin/zsh",
    USER: process.env.USER || "root",
    HOME: process.env.HOME || "/root",
    PATH: `/root/.bun/bin:${
      process.env.PATH ||
      "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    }`,
    // Pass through git config if set
    ...(process.env.GIT_CONFIG_GLOBAL
      ? { GIT_CONFIG_GLOBAL: process.env.GIT_CONFIG_GLOBAL }
      : {}),
    ...(process.env.GIT_SSH_COMMAND
      ? { GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND }
      : {}),
  };
  if (!Object.prototype.hasOwnProperty.call(env, "NODE_ENV")) {
    // Ensure tmux sessions do not inherit NODE_ENV unless explicitly provided
    delete ptyEnv.NODE_ENV;
  }

  // Run optional startup commands prior to spawning the agent process
  if (startupCommands && startupCommands.length > 0) {
    log(
      "INFO",
      `Running ${startupCommands.length} startup command(s) before spawn`,
      { startupCommands }
    );
    for (const cmd of startupCommands) {
      try {
        await new Promise<void>((resolve, reject) => {
          const p = spawn("bash", ["-lc", cmd], {
            cwd,
            env: ptyEnv,
            stdio: ["ignore", "pipe", "pipe"],
          });
          let stderr = "";
          p.stderr.on("data", (d) => {
            stderr += d.toString();
          });
          p.on("exit", (code) => {
            if (code === 0) resolve();
            else
              reject(
                new Error(`Startup command failed (${code}): ${cmd}\n${stderr}`)
              );
          });
          p.on("error", (e) => reject(e));
        });
      } catch (e) {
        log(
          "ERROR",
          `Startup command failed: ${cmd}`,
          e instanceof Error ? e : new Error(String(e))
        );
      }
    }
  }

  log("INFO", "Spawning process", {
    command: spawnCommand,
    args: spawnArgs,
    cwd,
    envKeys: Object.keys(ptyEnv),
  });

  let childProcess: ChildProcessWithoutNullStreams;
  const processStartTime = Date.now();

  try {
    // Add LINES and COLUMNS to environment for terminal size
    const processEnv = {
      ...ptyEnv,
      LINES: rows.toString(),
      COLUMNS: cols.toString(),
    };

    childProcess = spawn(spawnCommand, spawnArgs, {
      cwd,
      env: processEnv,
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
    });

    log("INFO", "Process spawned successfully", {
      pid: childProcess.pid,
      terminalId,
    });
  } catch (error) {
    log("ERROR", "Failed to spawn process", error);
    return;
  }

  const headlessTerminal = new Terminal({
    cols,
    rows,
    scrollback: SERVER_TERMINAL_CONFIG.scrollback,
    allowProposedApi: SERVER_TERMINAL_CONFIG.allowProposedApi,
  });

  const serializeAddon = new SerializeAddon();
  headlessTerminal.loadAddon(serializeAddon);

  // Increment active terminal count
  log("INFO", "Terminal created", {
    terminalId,
  });

  // Pipe data from child process to headless terminal
  // Capture initial stderr output for error reporting if startup fails
  let initialStderrBuffer = "";
  const INITIAL_ERROR_CAPTURE_WINDOW_MS = 30000; // capture up to first 30s
  const stopErrorCaptureAt = Date.now() + INITIAL_ERROR_CAPTURE_WINDOW_MS;

  // Config-driven completion detector
  const agentConfig = options.agentModel
    ? AGENT_CONFIGS.find((c) => c.name === options.agentModel)
    : undefined;

  if (!agentConfig && options.agentModel) {
    log("WARN", `Agent config not found for ${options.agentModel}`, {
      agentModel: options.agentModel,
      availableConfigs: AGENT_CONFIGS.map((c) => c.name),
    });
  }

  if (options.taskRunId && agentConfig?.completionDetector) {
    try {
      log(
        "INFO",
        `Setting up completion detector for task ${options.taskRunId}`,
        {
          taskRunId: options.taskRunId,
          agentModel: options.agentModel,
          hasDetector: !!agentConfig.completionDetector,
        }
      );

      agentConfig
        .completionDetector(options.taskRunId)
        .then(async () => {
          log(
            "INFO",
            `Completion detector resolved for task ${options.taskRunId}`
          );

          log(
            "INFO",
            `Starting crown evaluation for task ${options.taskRunId}`,
            {
              taskRunId: options.taskRunId,
              agentModel: options.agentModel,
              elapsedMs: Date.now() - processStartTime,
            }
          );

          if (!taskRunToken) {
            log("ERROR", "Missing task run token for crown workflow", {
              taskRunId: options.taskRunId,
            });
            return;
          }

          if (!options.taskRunId) {
            log("ERROR", "Missing task run ID for crown workflow", {
              taskRunId: options.taskRunId,
            });
            return;
          }

          // Await the crown workflow directly
          try {
            await handleWorkerTaskCompletion({
              taskRunId: options.taskRunId,
              token: taskRunToken,
              prompt: promptValue,
              convexUrl: convexUrl ?? undefined,
              agentModel: options.agentModel,
              elapsedMs: Date.now() - processStartTime,
            });

            log("INFO", `Crown workflow completed for ${options.taskRunId}`, {
              taskRunId: options.taskRunId,
              agentModel: options.agentModel,
            });
          } catch (error) {
            log(
              "ERROR",
              `Failed to handle crown workflow for ${options.taskRunId}`,
              {
                taskRunId: options.taskRunId,
                agentModel: options.agentModel,
                error: error instanceof Error ? error.message : String(error),
                stack: error instanceof Error ? error.stack : undefined,
              }
            );
          }
        })
        .catch((e) => {
          log(
            "ERROR",
            `Completion detector error for ${options.agentModel}: ${String(e)}`
          );
        });
    } catch (e) {
      log(
        "ERROR",
        `Failed to start completion detector for ${options.agentModel}: ${String(e)}`
      );
    }
  }
  childProcess.stderr.on("data", (data: Buffer) => {
    // Accumulate stderr during startup window for diagnostic error reporting
    if (Date.now() <= stopErrorCaptureAt && initialStderrBuffer.length < 8000) {
      try {
        initialStderrBuffer += data.toString();
      } catch {
        // ignore
      }
    }
    headlessTerminal.write(data.toString());
  });

  // Handle data from terminal (user input) to child process
  headlessTerminal.onData((data: string) => {
    if (childProcess.stdin.writable) {
      childProcess.stdin.write(data);
    }
  });

  // Handle process exit
  childProcess.on("exit", (code, signal) => {
    const runtime = Date.now() - processStartTime;

    log("INFO", `Process exited for terminal ${terminalId}`, {
      code,
      signal,
      runtime,
      runtimeSeconds: (runtime / 1000).toFixed(2),
      command: spawnCommand,
      args: spawnArgs.slice(0, 5), // Log first 5 args for debugging
    });
  });

  childProcess.on("error", (error) => {
    log("ERROR", `Process error for terminal ${terminalId}`, error);

    if (mainServerSocket) {
      mainServerSocket.emit("worker:error", {
        workerId: WORKER_ID,
        error: `Terminal ${terminalId} process error: ${error.message}`,
      });
    }
  });

  log("INFO", "command=", command);
  log("INFO", "args=", args);

  // detect idle - check if we're using tmux (either directly or as wrapper)
  if (spawnCommand === "tmux" && spawnArgs.length > 0) {
    // Extract session name from tmux args
    const sessionIndex = spawnArgs.indexOf("-s");
    const sessionName =
      sessionIndex !== -1 && spawnArgs[sessionIndex + 1]
        ? spawnArgs[sessionIndex + 1]
        : terminalId;

    log("INFO", "Setting up task completion detection for terminal", {
      terminalId,
      sessionName,
      agentModel: options.agentModel,
      taskRunId: options.taskRunId,
    });

    if (!(agentConfig?.completionDetector && options.taskRunId)) {
      // Legacy fallback to terminal idle when no agentModel available
      detectTerminalIdle({
        sessionName: sessionName || terminalId,
        idleTimeoutMs: 15000,
        onIdle: () => {
          const elapsedMs = Date.now() - processStartTime;
          if (options.taskRunId) {
            emitToMainServer("worker:terminal-idle", {
              workerId: WORKER_ID,
              terminalId,
              taskRunId: options.taskRunId,
              elapsedMs,
            });
          }
        },
      }).catch((error) => {
        const errMsg =
          (initialStderrBuffer && initialStderrBuffer.trim()) ||
          (error instanceof Error ? error.message : String(error));
        emitToMainServer("worker:terminal-failed", {
          workerId: WORKER_ID,
          terminalId,
          taskRunId: options.taskRunId,
          errorMessage: errMsg,
          elapsedMs: Date.now() - processStartTime,
        });
      });
    }
  }

  log("INFO", "Terminal creation complete", { terminalId });
}

const ENABLE_HEARTBEAT = false;
if (ENABLE_HEARTBEAT) {
  // Heartbeat interval (send stats every 30 seconds)
  setInterval(() => {
    const stats = getWorkerStats();

    if (mainServerSocket) {
      mainServerSocket.emit("worker:heartbeat", stats);
    } else {
      console.log(
        `Worker ${WORKER_ID} heartbeat (main server not connected):`,
        stats
      );
    }
  }, 30000);
}

// Start server
httpServer.listen(WORKER_PORT, () => {
  log(
    "INFO",
    `Worker ${WORKER_ID} starting on port ${WORKER_PORT}`,
    undefined,
    WORKER_ID
  );
  log(
    "INFO",
    "Namespaces:",
    {
      vscode: "/vscode",
      management: "/management",
    },
    WORKER_ID
  );
  log(
    "INFO",
    "Worker ready, waiting for terminal creation commands via socket.io",
    undefined,
    WORKER_ID
  );
});

// Start AMP proxy via shared provider module
const parsedAmpProxyPort = Number.parseInt(
  process.env.AMP_PROXY_PORT ?? "",
  10
);
const ampProxyPort = Number.isNaN(parsedAmpProxyPort)
  ? undefined
  : parsedAmpProxyPort;

startAmpProxy({
  ampUrl: process.env.AMP_URL,
  ampUpstreamUrl: process.env.AMP_UPSTREAM_URL,
  port: ampProxyPort,
  workerId: WORKER_ID,
  emitToMainServer,
});

// Periodic maintenance for pending events
setInterval(() => {
  const MAX_EVENT_AGE = 30 * 60 * 1000; // 30 minutes (increased to handle longer tasks)
  const now = Date.now();
  const originalCount = pendingEvents.length;

  // First, try to send any pending events if we're connected
  if (
    pendingEvents.length > 0 &&
    mainServerSocket &&
    mainServerSocket.connected
  ) {
    log("INFO", "Retrying to send pending events (periodic check)");
    sendPendingEvents();
  }

  // Then clean up very old events
  const validEvents = pendingEvents.filter((event) => {
    const age = now - event.timestamp;
    if (age > MAX_EVENT_AGE) {
      const payload = event.args[0];
      log(
        "WARNING",
        `Dropping old pending ${event.event} event (age: ${age}ms)`,
        {
          event: event.event,
          age,
          taskRunId:
            payload && hasTaskRunId(payload) ? payload.taskRunId : undefined,
        }
      );
      return false;
    }
    return true;
  });

  if (validEvents.length < originalCount) {
    pendingEvents.length = 0;
    pendingEvents.push(...validEvents);
    log(
      "INFO",
      `Cleaned up ${originalCount - validEvents.length} old pending events`
    );
  }

  // Log warning if we still have pending events
  if (pendingEvents.length > 0) {
    log(
      "WARNING",
      `Still have ${pendingEvents.length} pending events waiting to be sent`,
      {
        events: pendingEvents.map((e) => {
          const payload = e.args[0];
          return {
            event: e.event,
            age: now - e.timestamp,
            taskRunId:
              payload && hasTaskRunId(payload) ? payload.taskRunId : undefined,
          };
        }),
      }
    );
  }
}, 30000); // Run every 30 seconds

// Graceful shutdown
function gracefulShutdown() {
  console.log(`Worker ${WORKER_ID} shutting down...`);

  // Stop all file watchers
  for (const [taskRunId, watcher] of activeFileWatchers) {
    watcher.stop();
    log("INFO", `Stopped file watcher for task ${taskRunId} during shutdown`);
  }
  activeFileWatchers.clear();

  // Close server
  io.close(() => {
    console.log("Socket.IO server closed");
  });

  httpServer.close(() => {
    console.log("HTTP server closed");
    process.exit(0);
  });
}

process.on("SIGTERM", gracefulShutdown);
process.on("SIGINT", gracefulShutdown);
