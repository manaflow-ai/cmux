import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import Docker from "dockerode";
import { connectToWorkerManagement, type Socket } from "@cmux/shared/socket";

interface ContainerInfo {
  containerId: string;
  containerName: string;
  vscodePort: string;
  workerPort: string;
  proxyPort: string;
  cdpPort: string;
  vscodeUrl: string;
}

async function spawnVSCodeContainer(docker: Docker): Promise<ContainerInfo> {
  const containerName = `cmux-vscode-minimal-${Date.now()}`;
  const imageName = process.env.WORKER_IMAGE_NAME || "ghcr.io/manaflow-ai/cmux:latest";

  console.log(`Creating container ${containerName}...`);

  // Test Docker connection first
  try {
    const info = await docker.info();
    console.log(`Docker daemon connected: ${info.Name}`);
  } catch (error) {
    console.error("Failed to connect to Docker:", error);
    throw new Error("Docker connection failed. Make sure Docker is running.");
  }

  // Create container
  const container = await docker.createContainer({
    name: containerName,
    Image: imageName,
    Env: ["NODE_ENV=production", "WORKER_PORT=39377"],
    HostConfig: {
      AutoRemove: true,
      Privileged: true,
      PortBindings: {
        "39375/tcp": [{ HostPort: "0" }],
        "39378/tcp": [{ HostPort: "0" }],
        "39377/tcp": [{ HostPort: "0" }],
        "39379/tcp": [{ HostPort: "0" }],
        "39380/tcp": [{ HostPort: "0" }],
        "39381/tcp": [{ HostPort: "0" }],
      },
    },
    ExposedPorts: {
      "39375/tcp": {},
      "39378/tcp": {},
      "39377/tcp": {},
      "39379/tcp": {},
      "39380/tcp": {},
      "39381/tcp": {},
    },
  });

  // Start container
  await container.start();
  console.log(`Container started`);

  // Get port mappings
  const info = await container.inspect();
  const ports = info.NetworkSettings.Ports;

  const vscodePort = ports["39378/tcp"]?.[0]?.HostPort;
  const workerPort = ports["39377/tcp"]?.[0]?.HostPort;
  const proxyPort = ports["39379/tcp"]?.[0]?.HostPort;
  const vncPort = ports["39380/tcp"]?.[0]?.HostPort;
  const cdpPort = ports["39381/tcp"]?.[0]?.HostPort;

  if (!vscodePort || !workerPort || !proxyPort || !vncPort || !cdpPort) {
    throw new Error("Failed to get port mappings");
  }

  console.log(`noVNC will be available at http://localhost:${vncPort}/vnc.html`);
  console.log(`DevTools will be available at http://localhost:${cdpPort}/json/version`);

  // Wait for worker to be ready by polling
  console.log(`Waiting for worker to be ready on port ${workerPort}...`);
  const maxAttempts = 30; // 15 seconds max
  const delayMs = 500;

  for (let i = 0; i < maxAttempts; i++) {
    try {
      const response = await fetch(
        `http://localhost:${workerPort}/socket.io/?EIO=4&transport=polling`
      );
      if (response.ok) {
        console.log(`Worker is ready!`);
        break;
      }
    } catch {
      // Connection refused, worker not ready yet
    }

    if (i < maxAttempts - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    } else {
      console.warn("Worker may not be fully ready, but continuing...");
    }
  }

  const vscodeUrl = `http://localhost:${vscodePort}/?folder=/root/workspace`;

  return {
    containerId: container.id,
    containerName,
    vscodePort,
    workerPort,
    proxyPort,
    cdpPort,
    vscodeUrl,
  };
}

async function createTerminalWithPrompt(
  workerPort: string,
  prompt: string
): Promise<void> {
  const workerUrl = `http://localhost:${workerPort}`;

  console.log(`Connecting to worker at ${workerUrl}...`);

  // Connect to worker
  const socket = connectToWorkerManagement({ url: workerUrl, timeoutMs: 10_000, reconnectionAttempts: 0 });

  return new Promise((resolve, reject) => {
    socket.on("connect", () => {
      console.log("Connected to worker");

      // Create terminal
      const terminalId = "claude-terminal";
      const command = "bun";
      const args = [
        "x",
        "@anthropic-ai/claude-code",
        "--model",
        "claude-sonnet-4-20250514",
        "--dangerously-skip-permissions",
        prompt,
      ];
      const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL || "http://localhost:9777";

      console.log(
        `Creating terminal with command: ${command} ${args.join(" ")}`
      );

      socket.emit(
        "worker:create-terminal",
        {
          terminalId,
          command,
          args,
          cols: 80,
          rows: 24,
          env: {},
          backend: "tmux",
          taskRunContext: {
            taskRunToken: "spawn-vscode-minimal-token",
            prompt,
            convexUrl,
          },
        },
        (result) => {
          if (result.error) {
            reject(result.error);
          } else {
            console.log("Terminal created successfully", result);
            resolve();
          }
        }
      );

      // Wait for confirmation
      socket.on("worker:terminal-created", (data) => {
        if (data.terminalId === terminalId) {
          console.log("Terminal created successfully");
          socket.disconnect();
          resolve();
        }
      });

      socket.on("worker:error", (error) => {
        console.error("Worker error:", error);
        socket.disconnect();
        reject(new Error(error.error));
      });
    });

    socket.on("connect_error", (error) => {
      console.error("Failed to connect to worker:", error.message);
      reject(error);
    });
  });
}

async function main() {
  const prompt = process.argv[2];
  if (!prompt) {
    console.error("Usage: spawn-vscode-minimal.ts <prompt>");
    process.exit(1);
  }

  console.log(`Spawning VSCode with prompt: ${prompt}`);

  // Docker connection setup - Bun requires explicit socket path
  const docker = new Docker({ socketPath: "/var/run/docker.sock" });
  let containerInfo: ContainerInfo | null = null;

  try {
    // Spawn container
    containerInfo = await spawnVSCodeContainer(docker);

    console.log(`\nVSCode instance started:`);
    console.log(`  URL: ${containerInfo.vscodeUrl}`);
    console.log(`  Container: ${containerInfo.containerName}`);
    console.log(`  Proxy: http://localhost:${containerInfo.proxyPort}`);
    console.log(`  DevTools: http://localhost:${containerInfo.cdpPort}/json/version`);

    // Create terminal with prompt
    await createTerminalWithPrompt(containerInfo.workerPort, prompt);

    console.log(`\n✅ VSCode is running at: ${containerInfo.vscodeUrl}`);
    console.log(
      "\nClaude Code is running in the terminal. Open the URL above to interact with it."
    );
    console.log("Press Ctrl+C to stop\n");

    // Keep the process running
    process.on("SIGINT", async () => {
      console.log("\nStopping container...");
      if (containerInfo) {
        const container = docker.getContainer(containerInfo.containerId);
        await container.stop().catch(() => {});
      }
      process.exit(0);
    });

    // Prevent the process from exiting
    await new Promise(() => {});
  } catch (error) {
    console.error("Error:", error);
    if (containerInfo) {
      const container = docker.getContainer(containerInfo.containerId);
      await container.stop().catch(() => {});
    }
    process.exit(1);
  }
}

main().catch(console.error);
