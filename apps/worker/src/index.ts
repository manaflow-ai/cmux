import {
  SERVER_TERMINAL_CONFIG,
  WorkerConfigureGitSchema,
  WorkerCreateTerminalSchema,
  WorkerExecSchema,
  type ClientToServerEvents,
  type InterServerEvents,
  type ServerToClientEvents,
  type ServerToWorkerEvents,
  type SocketData,
  type WorkerHeartbeat,
  type WorkerRegister,
  type WorkerToServerEvents,
} from "@cmux/shared";
import { SerializeAddon } from "@xterm/addon-serialize";
import * as xtermHeadless from "@xterm/headless";
import express from "express";
import multer from "multer";
import {
  exec,
  spawn,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { EventEmitter } from "node:events";
import { promises as fs } from "node:fs";
import { createServer } from "node:http";
import { cpus, platform, totalmem } from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { runWorkerExec } from "./execRunner.js";
import { Server, type Namespace, type Socket } from "socket.io";
import { checkDockerReadiness } from "./checkDockerReadiness.js";
import { detectTerminalIdle } from "./detectTerminalIdle.js";
import { FileWatcher, computeGitDiff, getFileWithDiff } from "./fileWatcher.js";
import { startAmpProxy } from "@cmux/shared/src/providers/amp/proxy";
import { log } from "./logger.js";

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
    pendingEvents: pendingEvents.map((e) => ({
      event: e.event,
      age: Date.now() - e.timestamp,
      taskId: e.data.taskId,
      taskRunId: e.data.taskRunId,
    })),
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
const io = new Server(httpServer, {
  cors: {
    origin: "*", // In production, restrict this
    methods: ["GET", "POST"],
  },
  maxHttpBufferSize: 50 * 1024 * 1024, // 50MB to handle large images
  pingTimeout: 240000, // 120 seconds - increased for long tasks
  pingInterval: 30000, // 30 seconds
  upgradeTimeout: 30000, // 30 seconds
});

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
interface PendingEvent {
  event: string;
  data: any;
  timestamp: number;
}
const pendingEvents: PendingEvent[] = [];

/**
 * Emit an event to the main server, queuing it if not connected
 */
function emitToMainServer(event: string, data: any) {
  if (mainServerSocket && mainServerSocket.connected) {
    log("DEBUG", `Emitting ${event} to main server`, { event, data });
    mainServerSocket.emit(event as any, data);
  } else {
    log("WARNING", `Main server not connected, queuing ${event} event`, {
      event,
      data,
      pendingEventsCount: pendingEvents.length + 1,
    });
    pendingEvents.push({
      event,
      data,
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

  log("INFO", `Sending ${pendingEvents.length} pending events to main server`);

  const eventsToSend = [...pendingEvents];
  pendingEvents.length = 0; // Clear the queue

  for (const pendingEvent of eventsToSend) {
    const age = Date.now() - pendingEvent.timestamp;
    log(
      "DEBUG",
      `Sending pending ${pendingEvent.event} event (age: ${age}ms)`,
      {
        event: pendingEvent.event,
        data: pendingEvent.data,
        age,
      }
    );
    mainServerSocket.emit(pendingEvent.event as any, pendingEvent.data);
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

      // Execute startup commands if provided
      if (validated.startupCommands && validated.startupCommands.length > 0) {
        log(
          "INFO",
          `Executing ${validated.startupCommands.length} startup commands...`,
          undefined,
          WORKER_ID
        );

        for (const command of validated.startupCommands) {
          try {
            log(
              "INFO",
              `Executing startup command: ${command}`,
              undefined,
              WORKER_ID
            );
            const { stdout, stderr } = await execAsync(command, {
              env: { ...process.env, ...validated.env },
            });
            if (stdout) {
              log(
                "INFO",
                `Startup command stdout: ${stdout}`,
                undefined,
                WORKER_ID
              );
            }
            if (stderr) {
              log(
                "INFO",
                `Startup command stderr: ${stderr}`,
                undefined,
                WORKER_ID
              );
            }
            log(
              "INFO",
              `Successfully executed startup command`,
              undefined,
              WORKER_ID
            );
          } catch (error) {
            log(
              "ERROR",
              `Failed to execute startup command: ${command}`,
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
        agentModel: (validated as any).agentModel,
        startupCommands: validated.startupCommands,
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

  socket.on("worker:configure-git", async (data) => {
    try {
      const validated = WorkerConfigureGitSchema.parse(data);
      console.log(`Worker ${WORKER_ID} configuring git...`);

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
                configSections.get(currentSection)!.set(key, value);
              }
            }
          }
        }
      } catch {
        // No mounted config
      }

      // Add the store credential helper
      if (!configSections.has("credential")) {
        configSections.set("credential", new Map());
      }
      configSections.get("credential")!.set("helper", "store");

      // Create .git-credentials file if GitHub token is provided
      if (validated.githubToken) {
        const credentialsPath = "/root/.git-credentials";
        const credentialsContent = `https://oauth:${validated.githubToken}@github.com\n`;
        await fs.writeFile(credentialsPath, credentialsContent);
        await fs.chmod(credentialsPath, 0o600);
        console.log("GitHub credentials stored in .git-credentials");
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
            configSections.get(section)!.set(configKey, value);
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
    taskRunId?: string;
    agentModel?: string;
    startupCommands?: string[];
  } = {}
): Promise<void> {
  const {
    cols = SERVER_TERMINAL_CONFIG.cols,
    rows = SERVER_TERMINAL_CONFIG.rows,
    cwd = process.env.HOME || "/",
    env = {},
    command,
    args = [],
  } = options;

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

  const ptyEnv = {
    ...process.env,
    ...env, // Override with provided env vars
    WORKER_ID,
    TERM: "xterm-256color",
    PS1: "\\u@\\h:\\w\\$ ", // Basic prompt
    SHELL: "/bin/bash",
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
  let opencodeStdoutBuf = "";
  const providerResolved = resolveProviderFromModel(options.agentModel);
  childProcess.stdout.on("data", (data: Buffer) => {
    const chunk = data.toString();
    headlessTerminal.write(chunk);
    // Parse OpenCode stdout for deterministic completion events
    if (providerResolved === "opencode" && options.taskRunId) {
      try {
        opencodeStdoutBuf += chunk;
        // Process complete lines only
        const lines = opencodeStdoutBuf.split(/\r?\n/);
        opencodeStdoutBuf = lines.pop() || ""; // keep last partial
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          // Debug: log lines with likely markers (limited preview)
          if (/finish|Done|done|response|summarize/i.test(trimmed)) {
            log("DEBUG", "[OpenCode stdout] line", {
              sample: trimmed.substring(0, 200),
            });
          }

          let detected = false;
          let reason = "";
          // Try JSON first
          if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
            try {
              const obj = JSON.parse(trimmed) as any;
              const payload = obj.payload || obj.event || obj;
              const done = payload?.Done === true || payload?.done === true;
              const type = String(
                payload?.Type || payload?.type || ""
              ).toLowerCase();
              const isResponse = type.includes("response");
              const isSummarize = type.includes("summarize");
              const finish =
                payload?.finish || obj?.finish || obj?.response?.finish;
              reason = String(finish?.reason || "").toLowerCase();
              if (
                (done && (isResponse || isSummarize)) ||
                (finish && reason !== "tool_use" && reason !== "")
              ) {
                detected = true;
                log("INFO", "[OpenCode stdout] Detected JSON completion", {
                  done,
                  type,
                  finish,
                });
              }
            } catch {
              // fall through to regex
            }
          }
          if (!detected) {
            // Regex fallback for non-JSON lines
            const doneRe = /"?done"?\s*:\s*true/i;
            const typeRe = /"?type"?\s*:\s*"?([a-zA-Z_\-]+)"?/i;
            const finishReasonRe =
              /finish[^\n\r]*?reason\s*[:=]\s*"?([a-zA-Z_\-]+)"?/i;
            const hasDone = doneRe.test(trimmed);
            const typeMatch = typeRe.exec(trimmed);
            const typeStr = (typeMatch?.[1] || "").toLowerCase();
            const isResponse = typeStr.includes("response");
            const isSummarize = typeStr.includes("summarize");
            const fr = finishReasonRe.exec(trimmed);
            reason = (fr?.[1] || reason || "").toLowerCase();
            if (
              (hasDone && (isResponse || isSummarize)) ||
              (reason && reason !== "tool_use")
            ) {
              detected = true;
            }
          }
          if (detected) {
            log("INFO", "[OpenCode stdout] Detected completion event", {
              reason,
            });
            emitToMainServer("worker:task-complete", {
              workerId: WORKER_ID,
              terminalId,
              taskRunId: options.taskRunId,
              agentModel: options.agentModel,
              elapsedMs: Date.now() - processStartTime,
            });
          }
        }
      } catch (e) {
        log("ERROR", "[OpenCode stdout] Error parsing output", e);
      }
    }
  });

  childProcess.stderr.on("data", (data: Buffer) => {
    // Accumulate stderr during startup window for diagnostic error reporting
    if (Date.now() <= stopErrorCaptureAt && initialStderrBuffer.length < 8000) {
      try {
        initialStderrBuffer += data.toString();
      } catch {}
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

    // Notify via management socket
    emitToMainServer("worker:terminal-exit", {
      workerId: WORKER_ID,
      terminalId,
      exitCode: code ?? 0,
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
      spawnCommand,
      originalCommand: command,
      agentModel: options.agentModel,
      taskRunId: options.taskRunId,
    });

    // Track if detection completed successfully
    let idleDetectionCompleted = false;

    // Use new task completion detection if agentModel is provided
    if (options.agentModel && options.taskRunId) {
      // For Claude, Codex, and Gemini use project/log detection only; allow idle fallback for OpenCode
      const useTerminalIdleFallback = !(
        providerResolved === "claude" ||
        providerResolved === "codex" ||
        providerResolved === "gemini" ||
        providerResolved === "cursor"
      );

      log(
        "INFO",
        `Setting up task completion detection for ${options.agentModel}`,
        {
          useTerminalIdleFallback,
          taskRunId: options.taskRunId,
          workingDir: cwd,
        }
      );

      if (providerResolved === "gemini") {
        const telemetryPath = `/tmp/gemini-telemetry-${options.taskRunId}.log`;
        const { watchGeminiTelemetryForCompletion } = await getGeminiHelpers();
        const stopWatching = watchGeminiTelemetryForCompletion({
          telemetryPath,
          onComplete: async () => {
            if (!idleDetectionCompleted) {
              idleDetectionCompleted = true;
              const elapsedMs = Date.now() - processStartTime;
              log("INFO", "[Gemini] Completion event detected via telemetry", {
                telemetryPath,
                elapsedMs,
              });
              emitToMainServer("worker:task-complete", {
                workerId: WORKER_ID,
                taskRunId: options.taskRunId!,
                agentModel: options.agentModel,
                elapsedMs,
                detectionMethod: "telemetry-log",
              });
              stopWatching();
            }
          },
          onError: (error) => {
            log("ERROR", `[Gemini] Telemetry watcher error: ${error.message}`);
          },
        });
      } else {
        const detector = await createTaskCompletionDetector(
          {
            taskRunId: options.taskRunId!,
            agentType: providerResolved!,
            agentModel: options.agentModel,
            workingDir: cwd,
            maxRuntimeMs: 20 * 60 * 1000,
            minRuntimeMs: 30000,
          },
          buildDetectorConfig({
            agentType: providerResolved || undefined,
            agentModel: options.agentModel,
            workingDir: cwd,
            startTime: processStartTime,
            terminalId: useTerminalIdleFallback
              ? sessionName || terminalId
              : undefined,
            onTerminalIdle: useTerminalIdleFallback
              ? () => {
                  if (!idleDetectionCompleted) {
                    idleDetectionCompleted = true;
                    const elapsedMs = Date.now() - processStartTime;
                    log(
                      "INFO",
                      "Task completion detected (fallback to terminal idle)",
                      {
                        terminalId,
                        taskRunId: options.taskRunId,
                        agentModel: options.agentModel,
                        elapsedMs,
                      }
                    );
                    if (options.taskRunId) {
                      emitToMainServer("worker:task-complete", {
                        workerId: WORKER_ID,
                        taskRunId: options.taskRunId,
                        agentModel: options.agentModel,
                        elapsedMs,
                      });
                    }
                  }
                }
              : undefined,
          })
        );

        // Listen for task completion from project/log detectors
        detector.on("task-complete", (data) => {
          if (!idleDetectionCompleted) {
            idleDetectionCompleted = true;
            log("INFO", "Task completion detected from project files", data);
            const detectionMethod = "project-file";
            emitToMainServer("worker:task-complete", {
              workerId: WORKER_ID,
              taskRunId: options.taskRunId,
              agentModel: options.agentModel,
              elapsedMs: data.elapsedMs,
              detectionMethod,
            });
          }
        });

        // On timeout, do NOT mark complete; mark as failed for deterministic behavior
        detector.on("task-timeout", (data) => {
          if (!idleDetectionCompleted) {
            idleDetectionCompleted = true;
            log("WARN", "Task timeout detected", data);
            emitToMainServer("worker:terminal-failed", {
              workerId: WORKER_ID,
              terminalId,
              taskRunId: options.taskRunId,
              errorMessage: `Detector timeout after ${data.elapsedMs}ms`,
              elapsedMs: data.elapsedMs,
            });
          }
        });
      }
    } else {
      // Fallback to original terminal idle detection
      detectTerminalIdle({
        sessionName: sessionName || terminalId,
        idleTimeoutMs: 15000, // 15 seconds - for longer tasks that may pause
        onIdle: () => {
          log("INFO", "Terminal idle detected", {
            terminalId,
            taskRunId: options.taskRunId,
          });

          idleDetectionCompleted = true;
          const elapsedMs = Date.now() - processStartTime;
          // Emit idle event via management socket
          log("DEBUG", "Attempting to emit worker:terminal-idle", {
            terminalId,
            taskRunId: options.taskRunId,
            hasMainServerSocket: !!mainServerSocket,
            mainServerSocketConnected: mainServerSocket?.connected,
            elapsedMs,
          });

          if (options.taskRunId) {
            log("INFO", "Sending worker:terminal-idle event", {
              workerId: WORKER_ID,
              terminalId,
              taskRunId: options.taskRunId,
              elapsedMs,
            });
            emitToMainServer("worker:terminal-idle", {
              workerId: WORKER_ID,
              terminalId,
              taskRunId: options.taskRunId,
              elapsedMs,
            });
          } else {
            log(
              "WARNING",
              "Cannot emit worker:terminal-idle - missing taskRunId",
              {
                terminalId,
                taskRunId: options.taskRunId,
              }
            );
          }
        },
      })
        .then(async ({ elapsedMs }) => {
          log(
            "INFO",
            `Terminal ${terminalId} completed successfully after ${elapsedMs}ms`,
            {
              terminalId,
              taskRunId: options.taskRunId,
              idleDetectionCompleted,
            }
          );
        })
        .catch((error) => {
          const errMsg =
            (initialStderrBuffer && initialStderrBuffer.trim()) ||
            (error instanceof Error ? error.message : String(error));
          log(
            "WARNING",
            `Terminal ${terminalId} exited early or failed idle detection`,
            {
              error: errMsg,
              terminalId,
              taskRunId: options.taskRunId,
            }
          );
          // Inform main server so it can mark the task run as failed
          emitToMainServer("worker:terminal-failed", {
            workerId: WORKER_ID,
            terminalId,
            taskRunId: options.taskRunId,
            errorMessage: errMsg,
            elapsedMs: Date.now() - processStartTime,
          });
          // Don't emit idle event for early exits/failures
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
startAmpProxy({
  ampUrl: process.env.AMP_URL,
  workerId: WORKER_ID,
  emitToMainServer: emitToMainServer,
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
      log(
        "WARNING",
        `Dropping old pending ${event.event} event (age: ${age}ms)`,
        {
          event: event.event,
          age,
          taskRunId: event.data.taskRunId,
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
        events: pendingEvents.map((e) => ({
          event: e.event,
          age: now - e.timestamp,
          taskRunId: e.data.taskRunId,
        })),
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

// ==============================
// Task Completion (DI approach)
// ==============================

type AgentType = "claude" | "codex" | "gemini" | "amp" | "opencode" | "cursor";

interface TaskCompletionOptionsDI {
  taskRunId: string;
  agentType: AgentType;
  agentModel?: string;
  workingDir: string;
  maxRuntimeMs?: number;
  minRuntimeMs?: number;
}

interface DetectorDeps {
  checkCompletion: (ctx: {
    startTime: number;
    options: TaskCompletionOptionsDI;
  }) => Promise<boolean>;
  allowTerminalIdleFallback?: boolean;
  terminalId?: string;
  idleTimeoutMs?: number;
  onTerminalIdle?: () => void;
}

class TaskCompletionDetectorDI extends EventEmitter {
  private startTime: number;
  private isRunning = false;
  private watchers: any[] = [];
  constructor(
    private options: TaskCompletionOptionsDI,
    private deps: DetectorDeps
  ) {
    super();
    this.startTime = Date.now();
    this.options.maxRuntimeMs = this.options.maxRuntimeMs || 20 * 60 * 1000;
    this.options.minRuntimeMs = this.options.minRuntimeMs || 30000;
  }
  async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;
    log(
      "INFO",
      `TaskCompletionDetector started for ${this.options.agentType} task ${this.options.taskRunId}`
    );

    // Set up file watchers based on agent type
    if (this.options.agentType === "claude") {
      // Watch for Claude stop hook marker file
      this.watchClaudeMarkerFile();
    } else if (this.options.agentType === "codex") {
      // Watch for Codex completion files
      this.watchCodexCompletionFiles();
    } else if (this.options.agentType === "cursor") {
      // Watch for Cursor stream-json result events in lifecycle file
      this.watchCursorStreamJsonFile();
    } else if (this.options.agentType === "opencode") {
      // OpenCode completion is handled via stdout parsing in createTerminal
      // But also set up file watching as well
      this.watchOpenCodeFiles();
    }
  }

  private async watchClaudeMarkerFile(): Promise<void> {
    const markerPath = `/root/lifecycle/claude-complete-${this.options.taskRunId}`;
    const { watch } = await import("node:fs");
    const { access } = await import("node:fs/promises");

    // Check if file already exists
    try {
      await access(markerPath);
      this.handleCompletion();
      return;
    } catch {
      // File doesn't exist yet, set up watcher
    }

    // Watch the directory for the marker file
    const watcher = watch("/root/lifecycle", (eventType, filename) => {
      if (filename === `claude-complete-${this.options.taskRunId}`) {
        log("INFO", `Claude stop hook marker detected: ${markerPath}`);
        this.handleCompletion();
      }
    });
    this.watchers.push(watcher);
  }

  private async watchCodexCompletionFiles(): Promise<void> {
    const { createCodexDetector } = await import(
      "@cmux/shared/src/providers/openai/completion-detector.ts"
    );

    log("INFO", "[Codex] Setting up completion detector", {
      workingDir: this.options.workingDir,
      taskRunId: this.options.taskRunId,
      startTime: new Date(this.startTime).toISOString(),
    });

    const detector = await createCodexDetector({
      taskRunId: this.options.taskRunId,
      startTime: this.startTime,
      workingDir: this.options.workingDir,
      onComplete: (data: any) => {
        log("INFO", "[Codex] ✅ Completion detected", data);
        this.handleCompletion();
      },
      onError: (error: any) => {
        log("ERROR", `[Codex] Detector error: ${error.message}`);
      },
    });

    // Store the detector so we can stop it later
    this.watchers.push({
      close: () => detector.stop(),
    } as any);
  }

  private async watchOpenCodeFiles(): Promise<void> {
    // OpenCode completion is handled via stdout parsing in createTerminal
    // We don't need file watching for OpenCode since it doesn't have a notify mechanism like Codex
    log(
      "INFO",
      "[OpenCode] Relying on stdout parsing for completion detection"
    );
  }

  private async watchCursorStreamJsonFile(): Promise<void> {
    const { createCursorDetector } = await import(
      "@cmux/shared/src/providers/cursor/completion-detector.ts"
    );

    const detector = await createCursorDetector({
      taskRunId: this.options.taskRunId,
      startTime: this.startTime,
      onComplete: () => {
        this.handleCompletion();
      },
      onError: (_err) => {
        // No-op; avoid stdout logging per project policy
      },
    });

    this.watchers.push({ close: () => detector.stop() } as any);
  }

  private handleCompletion(): void {
    if (!this.isRunning) return;
    this.stop();
    this.emit("task-complete", {
      taskRunId: this.options.taskRunId,
      agentType: this.options.agentType,
      elapsedMs: Date.now() - this.startTime,
    });
  }
  stop(): void {
    this.isRunning = false;
    // Close all file watchers
    this.watchers.forEach((w) => {
      try {
        w.close();
      } catch (e) {
        // Ignore errors when closing watchers
      }
    });
    this.watchers = [];
  }
}

async function createTaskCompletionDetector(
  options: TaskCompletionOptionsDI,
  deps: DetectorDeps
): Promise<TaskCompletionDetectorDI> {
  const detector = new TaskCompletionDetectorDI(options, deps);
  await detector.start();

  // Optional terminal idle fallback
  // const allowFallback = deps.allowTerminalIdleFallback !== false; // default true unless explicitly false
  // if (allowFallback && deps.terminalId && deps.onTerminalIdle) {
  //   detectTerminalIdle({
  //     sessionName: deps.terminalId,
  //     idleTimeoutMs: deps.idleTimeoutMs || 15000,
  //     onIdle: () => {
  //       log("INFO", "Terminal idle detected (fallback)");
  //       detector.stop();
  //       deps.onTerminalIdle && deps.onTerminalIdle();
  //     },
  //   });
  // }

  return detector;
}

// ---- Provider helpers (dynamic imports kept local) ----
const getClaudeHelpers = async () => {
  const module = await import(
    "@cmux/shared/src/providers/anthropic/completion-detector.ts"
  );
  return {
    checkClaudeStopHookCompletion: module.checkClaudeStopHookCompletion,
  };
};
// Codex helpers are now handled by the detector module
const getGeminiHelpers = async () => {
  const module = await import(
    "@cmux/shared/src/providers/gemini/completion-detector.ts"
  );
  return {
    watchGeminiTelemetryForCompletion: module.watchGeminiTelemetryForCompletion,
  };
};

// ---- Provider-specific checkers composed via config ----
function resolveProviderFromModel(model?: string): AgentType | undefined {
  if (!model) return undefined;

  // Extract provider from model name (e.g., "claude/sonnet-4" -> "claude")
  // Special case: "amp" doesn't have a slash
  if (model === "amp") return "amp";

  // Handle cursor models
  if (model.startsWith("cursor/")) return "cursor";

  // Extract prefix before the slash
  const prefix = model.split("/")[0] as AgentType;
  return ["claude", "codex", "gemini", "amp", "opencode"].includes(prefix)
    ? prefix
    : undefined;
}

function buildDetectorConfig(params: {
  agentType?: AgentType;
  agentModel?: string;
  workingDir: string;
  startTime: number;
  terminalId?: string;
  onTerminalIdle?: () => void;
}): DetectorDeps {
  const agentType =
    params.agentType || resolveProviderFromModel(params.agentModel)!;
  const { workingDir } = params;

  const byAgent: Record<AgentType, DetectorDeps> = {
    claude: {
      allowTerminalIdleFallback: false,
      async checkCompletion({ startTime, options }) {
        try {
          const { checkClaudeStopHookCompletion } = await getClaudeHelpers();

          // Check for stop hook marker (ONLY method - hook MUST work)
          const done = await checkClaudeStopHookCompletion(options.taskRunId);
          if (done) {
            log(
              "INFO",
              `Claude task complete via stop hook for task: ${options.taskRunId}`
            );
            return true;
          }

          return false;
        } catch (e) {
          log("ERROR", `Claude completion error: ${e}`);
          return false;
        }
      },
    },
    codex: {
      allowTerminalIdleFallback: false,
      async checkCompletion() {
        // Codex completion is handled by the event-driven detector in watchCodexCompletionFiles
        // This function is not used for Codex
        return false;
      },
    },
    gemini: {
      allowTerminalIdleFallback: false,
      async checkCompletion() {
        // Gemini completion is handled by the event-driven watcher above.
        // Do not poll here.
        return false;
      },
    },
    amp: {
      // Not implemented yet; keep fallback enabled so terminal idle can be used by caller
      allowTerminalIdleFallback: true,
      async checkCompletion() {
        return false;
      },
    },
    opencode: {
      allowTerminalIdleFallback: true,
      async checkCompletion({ startTime, options }) {
        try {
          const module = await import(
            "@cmux/shared/src/providers/opencode/completion-detector.ts"
          );
          const done = await module.checkOpencodeCompletionSince(
            startTime,
            options.workingDir
          );
          if (!done) log("DEBUG", "[Opencode] Not complete yet");
          return done;
        } catch (e) {
          log("ERROR", `Opencode completion error: ${e}`);
          return false;
        }
      },
    },
    cursor: {
      allowTerminalIdleFallback: false,
      async checkCompletion() {
        // Cursor detection is event-driven via stream-json watcher
        return false;
      },
    },
  };

  const base = byAgent[agentType];
  return {
    ...base,
    terminalId: params.terminalId,
    onTerminalIdle: params.onTerminalIdle,
  };
}
